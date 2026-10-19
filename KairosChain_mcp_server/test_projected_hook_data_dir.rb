#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for PluginProjector telling projected hooks which data directory the
# projection used.
#
# The defect (2026-10-06): GenomicsChain_2025/.mcp.json starts kairos-chain with
# --data-dir pointing at KairosChain_2026/.kairos. Projection wrote that data
# dir's SkillSet hooks into GenomicsChain_2025/.claude/settings.json, and each
# hook resolved its script as ${KAIROS_DATA_DIR:-$CLAUDE_PROJECT_DIR/.kairos}/...
# with KAIROS_DATA_DIR unset — the wrong project — failing with LoadError on
# every Stop. Sections C and D reproduce it, the second with the shipped hooks.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/plugin_projector'
require 'kairos_mcp/skillset'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'

$pass_count = 0
$fail_count = 0

def assert(msg, &block)
  result = block.call
  if result
    puts "  PASS: #{msg}"
    $pass_count += 1
  else
    puts "  FAIL: #{msg}"
    $fail_count += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}"
  $fail_count += 1
end

def separator
  puts '-' * 60
end

TEMPLATES = File.expand_path('templates/skillsets', __dir__)

# Variables that would leak the outer session into a hook run.
CLEAN_ENV = { 'KAIROS_DATA_DIR' => nil, 'CLAUDE_PROJECT_DIR' => nil, 'KAIROS_PROJECT_ROOT' => nil }.freeze

# Run a command with a hard time limit, so a mutation that makes a run hang
# fails this test instead of stopping the suite.
def run_cmd(env, argv, chdir:, stdin: '', timeout: 30)
  Open3.popen3(CLEAN_ENV.merge(env), *argv, chdir: chdir) do |sin, stdout, stderr, wait|
    sin.write(stdin)
    sin.close
    out_reader = Thread.new { stdout.read }
    err_reader = Thread.new { stderr.read }
    unless wait.join(timeout)
      Process.kill('KILL', wait.pid)
      wait.join
      return ['', "timeout after #{timeout}s", :timeout]
    end
    [out_reader.value, err_reader.value, wait.value.exitstatus]
  end
end

def make_skillset(skillsets_dir, name, hooks)
  ss_dir = File.join(skillsets_dir, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'plugin'))
  File.write(File.join(ss_dir, 'plugin', 'SKILL.md'), "---\nname: #{name}\ndescription: test\n---\n\n# #{name}\n")
  File.write(File.join(ss_dir, 'plugin', 'hooks.json'), JSON.pretty_generate(hooks))
  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(
    'name' => name, 'version' => '1.0.0', 'description' => 'test', 'author' => 'test', 'layer' => 'L1',
    'depends_on' => [], 'provides' => [], 'tool_classes' => [], 'config_files' => [], 'knowledge_dirs' => [],
    'min_core_version' => '1.0.0',
    'plugin' => { 'skill_md' => 'plugin/SKILL.md', 'hooks' => 'plugin/hooks.json' }
  ))
  KairosMcp::Skillset.new(ss_dir)
end

def commands_in(hooks)
  hooks.fetch('hooks', {}).values.flatten.flat_map do |h|
    h['hooks'].is_a?(Array) ? h['hooks'].map { |i| i['command'] } : [h['command']]
  end
end

def projected_commands(settings_path)
  settings = JSON.parse(File.read(settings_path))
  settings.fetch('hooks', {}).flat_map do |_event, handlers|
    handlers.select { |h| h['_projected_by'] == 'kairos-chain' }.flat_map do |h|
      h['hooks'].is_a?(Array) ? h['hooks'].map { |i| i['command'] } : [h['command']]
    end
  end.sort
end

def user_commands(settings_path)
  settings = JSON.parse(File.read(settings_path))
  settings.fetch('hooks', {}).flat_map do |_event, handlers|
    handlers.reject { |h| h['_projected_by'] }.flat_map { |h| h['hooks'].map { |i| i['command'] } }
  end
end

RAW_FORM = 'ruby "${KAIROS_DATA_DIR:-$CLAUDE_PROJECT_DIR/.kairos}/skillsets/probe/hooks/report.rb"'

SOURCE_HOOKS = {
  'hooks' => {
    'Stop' => [{ 'hooks' => [{ 'type' => 'command', 'command' => RAW_FORM }] }],
    'PostToolUse' => [
      { 'matcher' => 'mcp__kairos-chain__skillset_acquire',
        'hooks' => [{ 'type' => 'command', 'command' => 'kairos-plugin-project --if-changed --json' }] },
      { 'matcher' => 'top_level_form', 'type' => 'command', 'command' => 'echo top' }
    ]
  }
}.freeze

SOURCE_COMMANDS = [RAW_FORM, 'kairos-plugin-project --if-changed --json', 'echo top'].sort.freeze

USER_HOOK = { 'matcher' => 'Write', 'hooks' => [{ 'type' => 'command', 'command' => 'echo user-hook' }] }.freeze

def relocated_prefix(data, project)
  "export KAIROS_DATA_DIR=#{Shellwords.escape(data)} KAIROS_PROJECT_ROOT=#{Shellwords.escape(project)}; "
end

def project_fixture(tmp)
  project = File.join(tmp, 'project')
  FileUtils.mkdir_p(File.join(project, '.claude'))
  File.write(File.join(project, '.claude', 'settings.json'),
             JSON.pretty_generate('hooks' => { 'PostToolUse' => [USER_HOOK] }))
  data = File.join(tmp, 'data')
  ss = make_skillset(File.join(data, 'skillsets'), 'probe', SOURCE_HOOKS)
  [project, data, ss]
end

# =========================================================================
puts "\n=== Section A: what the projector writes ==="
separator

Dir.mktmpdir('pin_relocated') do |tmp|
  project, data, ss = project_fixture(tmp)
  KairosMcp::PluginProjector.new(project, mode: :project, data_dir: data).project!([ss])
  settings = File.join(project, '.claude', 'settings.json')
  prefix = relocated_prefix(data, project)

  assert('relocated: every projected command carries the data dir and the project root') do
    projected_commands(settings) == SOURCE_COMMANDS.map { |c| prefix + c }.sort
  end

  assert('relocated: hand-written hooks are untouched') do
    user_commands(settings) == ['echo user-hook']
  end

  KairosMcp::PluginProjector.new(project, mode: :project, data_dir: data).project!([ss])
  assert('re-projection does not stack the prefix') do
    projected_commands(settings) == SOURCE_COMMANDS.map { |c| prefix + c }.sort
  end
end

Dir.mktmpdir('pin_default') do |tmp|
  project = File.join(tmp, 'project')
  FileUtils.mkdir_p(File.join(project, '.claude'))
  ss = make_skillset(File.join(project, '.kairos', 'skillsets'), 'probe', SOURCE_HOOKS)
  KairosMcp::PluginProjector.new(project, mode: :project).project!([ss])
  settings = File.join(project, '.claude', 'settings.json')

  assert('default (<project>/.kairos): commands are projected as written') do
    projected_commands(settings) == SOURCE_COMMANDS
  end

  assert('default: no absolute path is written into settings.json') do
    !File.read(settings).include?(tmp)
  end

  KairosMcp::PluginProjector.new(project, mode: :project,
                                          data_dir: File.join(project, '.kairos')).project!([ss])
  assert('explicit data dir equal to <project>/.kairos: treated as default') do
    projected_commands(settings) == SOURCE_COMMANDS
  end
end

Dir.mktmpdir('pin_symlink') do |tmp|
  project, data, ss = project_fixture(tmp)
  File.symlink(data, File.join(project, '.kairos'))
  KairosMcp::PluginProjector.new(project, mode: :project, data_dir: data).project!([ss])

  assert('<project>/.kairos symlinked to the data dir: treated as default') do
    projected_commands(File.join(project, '.claude', 'settings.json')) == SOURCE_COMMANDS
  end
end

Dir.mktmpdir('pin_plugin') do |tmp|
  project = File.join(tmp, 'plugin_root')
  FileUtils.mkdir_p(File.join(project, '.claude-plugin'))
  File.write(File.join(project, '.claude-plugin', 'plugin.json'), '{"name":"t","version":"1.0.0"}')
  seed = { 'hooks' => { 'SessionStart' => [{ 'hooks' => [{ 'type' => 'command', 'command' => 'echo seed' }] }] } }
  FileUtils.mkdir_p(File.join(project, '.kairos'))
  File.write(File.join(project, '.kairos', 'seed_hooks.json'), JSON.generate(seed))
  data = File.join(tmp, 'data')
  ss = make_skillset(File.join(data, 'skillsets'), 'probe', SOURCE_HOOKS)
  KairosMcp::PluginProjector.new(project, mode: :plugin, data_dir: data).project!([ss])
  hooks_text = File.read(File.join(project, 'hooks', 'hooks.json'))

  assert('plugin mode (distributable): commands and seed hooks are written as declared') do
    commands_in(JSON.parse(hooks_text)).sort == (SOURCE_COMMANDS + ['echo seed']).sort &&
      !hooks_text.include?(tmp)
  end
end

# The Codex host rewrites kairos-plugin-project after the pin; a data-dir path
# that contains that name must not be the place the rewrite lands.
require_relative 'templates/skillsets/codex_projection/lib/codex_host_profile'
# Three path shapes: the name inside a path component (R1); a component that
# ends in " kairos-plugin-project", whose escaped space looks like a command
# boundary (R2, codex and persona); a project root containing "--host", which
# used to suppress the rewrite altogether (R2, sonnet).
[
  ['name inside a component', 'kairos-plugin-project-sandbox/.kairos', 'project'],
  ['component ending in " kairos-plugin-project"', 'shared kairos-plugin-project', 'project'],
  ['project root containing --host', 'data', 'proj --host x']
].each do |label, data_rel, project_rel|
  Dir.mktmpdir('pin_codex') do |tmp|
    project = File.join(tmp, project_rel)
    FileUtils.mkdir_p(project)
    data = File.join(tmp, data_rel)
    ss = make_skillset(File.join(data, 'skillsets'), 'probe', SOURCE_HOOKS)
    KairosMcp::PluginProjector.new(project, mode: :project, data_dir: data, host: 'codex').project!([ss])
    commands = commands_in(JSON.parse(File.read(File.join(project, '.codex', 'hooks.json'))))
    prefix = relocated_prefix(data, project)

    assert("codex host, #{label}: the pin survives and --host lands on the command") do
      commands.sort == [
        prefix + RAW_FORM,
        "#{prefix}echo top",
        "#{prefix}kairos-plugin-project --host codex --if-changed --json"
      ].sort
    end
  end
end

# R3 (codex, sonnet): unpinned commands keep the rewrite they had before this
# change, including an executable named by absolute path.
Dir.mktmpdir('pin_codex_default') do |tmp|
  project = File.join(tmp, 'project')
  abs = { 'hooks' => { 'PostToolUse' => [
    { 'matcher' => 'x', 'hooks' => [{ 'type' => 'command',
                                      'command' => '/usr/local/bin/kairos-plugin-project --if-changed --json' }] }
  ] } }
  ss = make_skillset(File.join(project, '.kairos', 'skillsets'), 'probe', abs)
  KairosMcp::PluginProjector.new(project, mode: :project, host: 'codex').project!([ss])
  commands = commands_in(JSON.parse(File.read(File.join(project, '.codex', 'hooks.json'))))

  assert('codex host, default layout: an absolute-path kairos-plugin-project still gets --host') do
    commands == ['/usr/local/bin/kairos-plugin-project --host codex --if-changed --json']
  end
end

# R1 P0 (both personas): the upgrade paths projected without data_dir, so a
# shared data dir was projected as local and the pin was dropped. Every
# construction outside tests must name the data dir it projects from.
assert('every PluginProjector.new outside tests passes data_dir:') do
  sources = Dir.glob(File.join(__dir__, '{lib,bin,templates}', '**', '*'))
               .select { |f| File.file?(f) && !File.basename(f).start_with?('test_') && !f.include?('/test/') }
  calls = sources.flat_map do |f|
    File.binread(f).scrub.scan(/PluginProjector\.new\(([^)]*)\)/m).map { |(args)| [f, args] }
  end
  calls.size >= 5 && calls.all? { |_f, args| args.include?('data_dir:') }
end

# =========================================================================
puts "\n=== Section B: what the hook sees when it runs ==="
separator

# R2 P0 (persona): the agent SkillSet starts children with KAIROS_DATA_DIR and
# KAIROS_PROJECT_ROOT as a pair. In the default layout a projected hook must
# see that pair whole — clearing half of it cross-wired a re-projection.
Dir.mktmpdir('run_inherited_pair') do |tmp|
  project = File.join(tmp, 'project')
  FileUtils.mkdir_p(File.join(project, '.claude'))
  echo = { 'hooks' => { 'Stop' => [{ 'hooks' => [{ 'type' => 'command',
                                                   'command' => 'printf "%s|%s" "$KAIROS_DATA_DIR" "$KAIROS_PROJECT_ROOT"' }] }] } }
  ss = make_skillset(File.join(project, '.kairos', 'skillsets'), 'echo', echo)
  KairosMcp::PluginProjector.new(project, mode: :project).project!([ss])
  cmd = projected_commands(File.join(project, '.claude', 'settings.json')).first
  other_data = File.join(tmp, 'other', '.kairos')
  other_root = File.join(tmp, 'other')

  assert('default: an inherited KAIROS_DATA_DIR / KAIROS_PROJECT_ROOT pair reaches the hook whole') do
    env = { 'KAIROS_DATA_DIR' => other_data, 'KAIROS_PROJECT_ROOT' => other_root, 'CLAUDE_PROJECT_DIR' => project }
    out, _err, status = run_cmd(env, ['/bin/sh', '-c', cmd], chdir: project)
    status == 0 && out == "#{other_data}|#{other_root}"
  end
end

Dir.mktmpdir('run_quote') do |tmp|
  project = File.join(tmp, "project ${x}'")
  FileUtils.mkdir_p(File.join(project, '.claude'))
  data = File.join(tmp, "data dir's $HOME;x")
  echo = { 'hooks' => { 'Stop' => [{ 'hooks' => [{ 'type' => 'command',
                                                   'command' => 'printf "%s|%s" "$KAIROS_DATA_DIR" "$KAIROS_PROJECT_ROOT"' }] }] } }
  ss = make_skillset(File.join(data, 'skillsets'), 'echo', echo)
  KairosMcp::PluginProjector.new(project, mode: :project, data_dir: data).project!([ss])
  cmd = projected_commands(File.join(project, '.claude', 'settings.json')).first

  assert('paths with spaces, quotes, $, ${} and ; reach the hook intact') do
    out, _err, status = run_cmd({}, ['/bin/sh', '-c', cmd], chdir: tmp)
    status == 0 && out == "#{data}|#{project}"
  end
end

# =========================================================================
puts "\n=== Section C: the 2026-10-06 failure, before and after ==="
separator

Dir.mktmpdir('e2e') do |tmp|
  # GenomicsChain_2025 stand-in: its own .kairos, without the SkillSet.
  project = File.join(tmp, 'GenomicsChain_2025')
  FileUtils.mkdir_p(File.join(project, '.claude'))
  FileUtils.mkdir_p(File.join(project, '.kairos', 'skillsets'))
  # KairosChain_2026 stand-in: the data dir .mcp.json points at.
  data = File.join(tmp, 'KairosChain_2026', '.kairos')
  observe = "File.write(File.join(ENV.fetch('KAIROS_DATA_DIR'), 'observed.txt'), ENV['KAIROS_DATA_DIR'])\n"
  raw = 'ruby "${KAIROS_DATA_DIR:-$CLAUDE_PROJECT_DIR/.kairos}/skillsets/probe/hooks/observe.rb"'
  hooks = { 'hooks' => { 'Stop' => [{ 'hooks' => [{ 'type' => 'command', 'command' => raw }] }] } }
  ss = make_skillset(File.join(data, 'skillsets'), 'probe', hooks)
  FileUtils.mkdir_p(File.join(data, 'skillsets', 'probe', 'hooks'))
  File.write(File.join(data, 'skillsets', 'probe', 'hooks', 'observe.rb'), observe)
  hook_env = { 'CLAUDE_PROJECT_DIR' => project }

  assert('control: the command as projected on 2026-10-06 fails with LoadError') do
    _out, err, status = run_cmd(hook_env, ['/bin/sh', '-c', raw], chdir: project)
    status == 1 && err.include?('LoadError') && !File.exist?(File.join(data, 'observed.txt'))
  end

  KairosMcp::PluginProjector.new(project, mode: :project, data_dir: data).project!([ss])
  cmd = projected_commands(File.join(project, '.claude', 'settings.json')).first

  assert('after: the projected command runs and records into the data dir it came from') do
    _out, _err, status = run_cmd(hook_env, ['/bin/sh', '-c', cmd], chdir: project)
    observed = File.join(data, 'observed.txt')
    status == 0 && File.exist?(observed) && File.read(observed) == data &&
      !File.exist?(File.join(project, '.kairos', 'observed.txt'))
  end
end

# =========================================================================
puts "\n=== Section D: the shipped hooks, projected into a project sharing a data dir ==="
separator

# The real model_provenance and project_manager SkillSets, linked into a data
# directory that is not the project's. A decoy `ruby` first on PATH reports
# whether the script path each real command resolves to exists, so no hook
# script runs here and nothing is written into the templates.
Dir.mktmpdir('shipped') do |tmp|
  project = File.join(tmp, 'project')
  FileUtils.mkdir_p(File.join(project, '.claude'))
  FileUtils.mkdir_p(File.join(project, '.kairos', 'skillsets'))
  data = File.join(tmp, 'shared', '.kairos')
  FileUtils.mkdir_p(File.join(data, 'skillsets'))
  shipped = %w[model_provenance project_manager].map do |name|
    File.symlink(File.join(TEMPLATES, name), File.join(data, 'skillsets', name))
    KairosMcp::Skillset.new(File.join(data, 'skillsets', name))
  end
  decoy_dir = File.join(tmp, 'decoy_bin')
  FileUtils.mkdir_p(decoy_dir)
  File.write(File.join(decoy_dir, 'ruby'), "#!/bin/sh\n[ -f \"$1\" ] && echo \"found $1\" || echo \"missing $1\"\n")
  File.chmod(0o755, File.join(decoy_dir, 'ruby'))
  hook_env = { 'CLAUDE_PROJECT_DIR' => project, 'PATH' => "#{decoy_dir}:#{ENV.fetch('PATH', '')}" }

  raw_commands = shipped.flat_map do |ss|
    commands_in(JSON.parse(File.read(File.join(ss.path, 'plugin', 'hooks.json'))))
  end

  assert('control: unprojected, every shipped command looks in the project and misses (4 commands)') do
    outs = raw_commands.map { |c| run_cmd(hook_env, ['/bin/sh', '-c', c], chdir: project)[0] }
    raw_commands.size == 4 && outs.all? { |o| o.start_with?("missing #{project}/.kairos/") }
  end

  KairosMcp::PluginProjector.new(project, mode: :project, data_dir: data).project!(shipped)
  projected = projected_commands(File.join(project, '.claude', 'settings.json'))

  assert('projected: every shipped command finds its script under the shared data dir (4 commands)') do
    outs = projected.map { |c| run_cmd(hook_env, ['/bin/sh', '-c', c], chdir: project)[0] }
    projected.size == 4 && outs.all? { |o| o.start_with?("found #{data}/skillsets/") }
  end

  # One real run of the observer through its projected command: with
  # stdin '{}' it reaches the script and stops at the missing session id,
  # before touching any state — proof that Ruby found and loaded it.
  stop = projected.find { |c| c.include?('model_provenance/hooks/observer.rb') }
  assert('projected: the real observer runs (stops at "no session_id", not LoadError)') do
    _out, err, status = run_cmd({ 'CLAUDE_PROJECT_DIR' => project }, ['/bin/sh', '-c', stop],
                                chdir: project, stdin: '{}')
    status == 1 && err.include?('session_id') && !err.include?('LoadError')
  end
end

# =========================================================================
separator
puts "\n=== Results ==="
puts "  Total: #{$pass_count + $fail_count} (#{$pass_count} passed, #{$fail_count} failed)"
exit($fail_count > 0 ? 1 : 0)
