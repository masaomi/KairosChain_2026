#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for multi-host projection (Codex + OpenCode) — 2026-07-02.
# Covers HostProfile behavior and the P1 fixes from the multi-LLM implementation review:
#   - Codex .codex/hooks.json merge-preserve (no user-hook data loss)
#   - OpenCode agent frontmatter conversion (Hash guard + list-form disallowedTools)
#   - host separation, hook-command --host rewrite, shared-AGENTS.md live status.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/plugin_projector'
require 'kairos_mcp/skillset'
require 'tmpdir'
require 'fileutils'
require 'json'

$pass_count = 0
$fail_count = 0

def assert(msg)
  ok = yield
  puts(ok ? "  PASS: #{msg}" : "  FAIL: #{msg}")
  ok ? ($pass_count += 1) : ($fail_count += 1)
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}"
  $fail_count += 1
end

# Create a SkillSet dir with a plugin/ containing SKILL.md, optional agents (name => md body),
# and optional hooks (Ruby hash). Returns a real Skillset object.
def mk_skillset(root, name, agents: {}, hooks: nil)
  ss_dir = File.join(root, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'plugin', 'agents'))
  File.write(File.join(ss_dir, 'plugin', 'SKILL.md'),
             "---\nname: #{name}\ndescription: \"Skill #{name}\"\n---\n\n# #{name}\n<!-- AUTO_TOOLS -->\n")
  agents.each { |an, md| File.write(File.join(ss_dir, 'plugin', 'agents', "#{an}.md"), md) }
  File.write(File.join(ss_dir, 'plugin', 'hooks.json'), JSON.pretty_generate(hooks)) if hooks
  json = {
    'name' => name, 'version' => '1.0.0', 'description' => "Test #{name}", 'author' => 'test',
    'layer' => 'L1', 'depends_on' => [], 'provides' => [], 'tool_classes' => [],
    'config_files' => [], 'knowledge_dirs' => [], 'min_core_version' => '1.0.0',
    'plugin' => { 'skill_md' => 'plugin/SKILL.md', 'hooks' => 'plugin/hooks.json',
                  'agents_dir' => 'plugin/agents' }
  }
  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(json))
  KairosMcp::Skillset.new(ss_dir)
end

KAIROS_HOOK = { 'hooks' => { 'PostToolUse' => [
  { 'matcher' => 'x', 'hooks' => [{ 'type' => 'command', 'command' => 'kairos-plugin-project --if-changed' }] }
] } }.freeze

# =========================================================================
puts "\n=== Section 1: Codex projection (.codex/ + hooks.json + --host rewrite) ==="
Dir.mktmpdir('mh') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  ss = mk_skillset(File.join(dir, 'ss'), 'demo',
                   agents: { 'monitor' => "---\nname: monitor\ndescription: rev\nmodel: sonnet\n---\nbody\n" },
                   hooks: KAIROS_HOOK)
  p = KairosMcp::PluginProjector.new(dir, mode: :project, host: 'codex')
  p.project!([ss])

  assert('skills -> .codex/skills/') { File.exist?(File.join(dir, '.codex/skills/demo/SKILL.md')) }
  assert('agents -> .codex/agents/') { File.exist?(File.join(dir, '.codex/agents/demo-monitor.md')) }
  assert('hooks -> .codex/hooks.json') { File.exist?(File.join(dir, '.codex/hooks.json')) }
  assert('hook command rewritten to --host codex') do
    JSON.parse(File.read(File.join(dir, '.codex/hooks.json')))
        .dig('hooks', 'PostToolUse', 0, 'hooks', 0, 'command').include?('--host codex')
  end
  assert('codex manifest written') { File.exist?(File.join(dir, '.kairos/projection_manifest.codex.json')) }
  assert('.claude/ not created for codex host') { !Dir.exist?(File.join(dir, '.claude')) }
end

# =========================================================================
puts "\n=== Section 2: Codex hooks merge-preserve (P1 data-loss fix) ==="
Dir.mktmpdir('mh') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos', ''))
  FileUtils.mkdir_p(File.join(dir, '.codex'))
  # Pre-existing USER hook (untagged) in .codex/hooks.json
  user_hook = { 'hooks' => { 'SessionStart' => [
    { 'matcher' => '*', 'hooks' => [{ 'type' => 'command', 'command' => 'echo user-owned' }] }
  ] } }
  File.write(File.join(dir, '.codex/hooks.json'), JSON.pretty_generate(user_hook))

  ss = mk_skillset(File.join(dir, 'ss'), 'demo', hooks: KAIROS_HOOK)
  p = KairosMcp::PluginProjector.new(dir, mode: :project, host: 'codex')
  p.project!([ss])

  merged = JSON.parse(File.read(File.join(dir, '.codex/hooks.json')))
  assert('user hook preserved after projection') do
    merged.dig('hooks', 'SessionStart', 0, 'hooks', 0, 'command') == 'echo user-owned'
  end
  assert('kairos hook added and tagged _projected_by') do
    merged.dig('hooks', 'PostToolUse', 0, '_projected_by') == 'kairos-chain'
  end

  # Re-project with a skillset that has NO hooks: user hook must survive, file must NOT be deleted.
  ss2 = mk_skillset(File.join(dir, 'ss2'), 'nohooks')
  KairosMcp::PluginProjector.new(dir, mode: :project, host: 'codex').project!([ss2])
  assert('.codex/hooks.json NOT deleted when kairos has zero hooks') do
    File.exist?(File.join(dir, '.codex/hooks.json'))
  end
  assert('user hook still present after empty re-projection') do
    JSON.parse(File.read(File.join(dir, '.codex/hooks.json')))
        .dig('hooks', 'SessionStart', 0, 'hooks', 0, 'command') == 'echo user-owned'
  end
  assert('kairos hook removed on empty re-projection (only projected stripped)') do
    JSON.parse(File.read(File.join(dir, '.codex/hooks.json')))['hooks']['PostToolUse'].nil?
  end
end

# =========================================================================
puts "\n=== Section 3: OpenCode projection (skills reused, agents converted, hooks skipped) ==="
Dir.mktmpdir('mh') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  agents = {
    'monitor' => "---\nname: monitor\ndescription: rev\nmodel: sonnet\ndisallowedTools: Write, Edit, Bash\n---\n\nbody-A\n",
    'listform' => "---\nname: listform\ndescription: lf\ndisallowedTools:\n  - Write\n  - Bash\n---\n\nbody-B\n",
    'nonhash' => "---\n- just\n- a\n- list\n---\n\nbody-C\n"
  }
  ss = mk_skillset(File.join(dir, 'ss'), 'demo', agents: agents, hooks: KAIROS_HOOK)
  p = KairosMcp::PluginProjector.new(dir, mode: :project, host: 'opencode')
  assert('project! does not raise on non-Hash agent frontmatter') do
    p.project!([ss])
    true
  end

  assert('skills NOT duplicated to .opencode/skills/') { !Dir.exist?(File.join(dir, '.opencode/skills')) }
  mon = File.read(File.join(dir, '.opencode/agent/demo-monitor.md'))
  assert('agent -> .opencode/agent/ with mode: subagent') { mon.include?('mode: subagent') }
  assert('converted agent drops name:') { !mon.match?(/^name:/) }
  assert('converted agent drops model:') { !mon.match?(/^model:/) }
  assert('comma-string disallowedTools -> tools map') do
    mon.include?('write: false') && mon.include?('edit: false') && mon.include?('bash: false')
  end
  lst = File.read(File.join(dir, '.opencode/agent/demo-listform.md'))
  assert('YAML list disallowedTools -> clean tools map (no bracket keys)') do
    lst.include?('write: false') && lst.include?('bash: false') && !lst.include?('[')
  end
  non = File.read(File.join(dir, '.opencode/agent/demo-nonhash.md'))
  assert('non-Hash frontmatter agent projected verbatim (body preserved)') { non.include?('body-C') }
  assert('opencode hooks skipped (no hooks file)') { !File.exist?(File.join(dir, '.opencode/hooks.json')) }
end

# =========================================================================
puts "\n=== Section 4: Claude regression (byte-compatible defaults) ==="
Dir.mktmpdir('mh') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  ss = mk_skillset(File.join(dir, 'ss'), 'demo', hooks: KAIROS_HOOK)
  KairosMcp::PluginProjector.new(dir, mode: :project, host: 'claude').project!([ss])
  assert('claude skills -> .claude/skills/') { File.exist?(File.join(dir, '.claude/skills/demo/SKILL.md')) }
  assert('claude hooks -> .claude/settings.json') { File.exist?(File.join(dir, '.claude/settings.json')) }
  assert('claude manifest uses legacy name (no host suffix)') do
    File.exist?(File.join(dir, '.kairos/projection_manifest.json'))
  end
  assert('claude hook command NOT rewritten (no --host)') do
    !JSON.parse(File.read(File.join(dir, '.claude/settings.json')))
         .dig('hooks', 'PostToolUse', 0, 'hooks', 0, 'command').include?('--host')
  end
end

# =========================================================================
puts "\n=== Section 5: Instruction mode inline + shared-AGENTS live status ==="
Dir.mktmpdir('mh') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  body = "MODE BODY\n" * 3
  pc = KairosMcp::PluginProjector.new(dir, mode: :project, host: 'codex')
  pc.project_instruction_mode!('masa', body, mode_version: '0.4.1')
  agents_md = File.read(File.join(dir, 'AGENTS.md'))
  assert('codex AGENTS.md inlines body (not @-import)') do
    agents_md.include?('MODE BODY') && !agents_md.include?('@.codex')
  end
  # opencode shares the same AGENTS.md; its live status should report region present.
  po = KairosMcp::PluginProjector.new(dir, mode: :project, host: 'opencode')
  po.project_instruction_mode!('masa', body, mode_version: '0.4.1')
  assert('opencode status region_present true while region exists') do
    po.instruction_mode_status[:region_present] == true
  end
  # Remove via codex strips the shared region; opencode live status must flip to false.
  pc.remove_projected_instruction_mode!
  assert('opencode live status flips to false after shared region removed') do
    po.instruction_mode_status[:region_present] == false
  end
end

# =========================================================================
puts "\n=== Section 6: Codex hooks.json malformed-input robustness (A/B P1 fix) ==="
Dir.mktmpdir('mh') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  FileUtils.mkdir_p(File.join(dir, '.codex'))
  ss = mk_skillset(File.join(dir, 'ss'), 'demo', hooks: KAIROS_HOOK)

  # (a) 'hooks' is a non-Hash value
  File.write(File.join(dir, '.codex/hooks.json'), JSON.generate({ 'hooks' => 'not-a-hash' }))
  assert('non-Hash hooks: project! does not raise') do
    KairosMcp::PluginProjector.new(dir, mode: :project, host: 'codex').project!([ss])
    true
  end
  assert('non-Hash hooks: projected hook written (normalized to Hash)') do
    JSON.parse(File.read(File.join(dir, '.codex/hooks.json')))
        .dig('hooks', 'PostToolUse', 0, '_projected_by') == 'kairos-chain'
  end

  # (b) an event value is a non-Array
  File.write(File.join(dir, '.codex/hooks.json'),
             JSON.generate({ 'hooks' => { 'PostToolUse' => 'not-an-array' } }))
  assert('non-Array event value: project! does not raise') do
    KairosMcp::PluginProjector.new(dir, mode: :project, host: 'codex').project!([ss])
    true
  end
  assert('non-Array event value: projected hook present') do
    JSON.parse(File.read(File.join(dir, '.codex/hooks.json')))
        .dig('hooks', 'PostToolUse', 0, 'hooks', 0, 'command').to_s.include?('kairos-plugin-project')
  end
end

puts "\n" + ('=' * 60)
puts "Total: #{$pass_count} passed, #{$fail_count} failed"
exit($fail_count.zero? ? 0 : 1)
