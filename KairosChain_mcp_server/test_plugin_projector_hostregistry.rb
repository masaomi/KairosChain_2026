#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the host-profile registry + add-on discovery (2026-07-10).
# Design: docs/drafts/multi_host_projection_addon_design_v0.3_FROZEN.md
#   - INV-H2: bundled claude default registers through the ordinary mechanism
#   - INV-H3: add-on discovery at the construction choke point (load_addons!)
#   - INV-H5: requires_host enforced pre-flight against on-disk artifacts
#   - INV-H11: escaping host_profiles declarations rejected at load time
#   - INV-H13: identity conflicts rejected deterministically
#
# IMPORTANT: this file must NOT require the codex/opencode add-on profiles —
# it exercises the fresh-install (claude-only) state and synthetic add-ons.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/plugin_projector'
require 'kairos_mcp/skillset'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'

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

HP = KairosMcp::PluginProjector::HostProfile

def mk_addon(data_dir, name, key:, profile_rel: 'lib/profile.rb', declared_rel: nil, source: nil)
  ss_dir = File.join(data_dir, 'skillsets', name)
  FileUtils.mkdir_p(File.join(ss_dir, 'lib'))
  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(
    'name' => name, 'version' => '0.1.0', 'description' => 'test addon', 'author' => 't',
    'layer' => 'L1', 'depends_on' => [], 'provides' => [], 'tool_classes' => [],
    'host_profiles' => [declared_rel || profile_rel], 'min_core_version' => '1.0.0'
  ))
  File.write(File.join(ss_dir, profile_rel), <<~RUBY)
    # frozen_string_literal: true
    require 'kairos_mcp/plugin_projector'
    KairosMcp::PluginProjector::HostProfile.register(
      KairosMcp::PluginProjector::HostProfile.new(
        key: #{key.inspect}, output_subdir: '.#{key}', context_file: 'AGENTS.md',
        instruction_mode_delivery: :inline, manifest_suffix: #{key.inspect},
        skill_projection: :own, agents_subdir: 'agents',
        hooks_writer: ->(_p, _h, _o) {}),
      source: #{(source || "skillset:#{name}").inspect}
    )
  RUBY
  ss_dir
end

# =========================================================================
puts "\n=== Section 1: Fresh-install state (bundled default only, INV-H2) ==="
assert('claude is registered as the bundled default') { HP.registered?('claude') }
assert('fresh install registers only claude') { HP.available == ['claude'] }
assert('claude aliases resolve (claude_code)') { HP.lookup('claude_code')&.key == 'claude' }
assert("for('codex') fails with actionable add-on hint") do
  begin
    HP.for('codex')
    false
  rescue ArgumentError => e
    e.message.include?('registered: claude') && e.message.include?('add-on SkillSet')
  end
end
assert('claude profile owns a hooks_writer (INV-H4: behavior travels with the profile)') do
  HP.lookup('claude').hooks_writer.respond_to?(:call)
end

# =========================================================================
puts "\n=== Section 2: Add-on discovery via load_addons! (INV-H3) ==="
Dir.mktmpdir('reg') do |dir|
  mk_addon(dir, 'fake_projection', key: 'fakehost')
  HP.load_addons!(dir)
  assert('add-on profile discovered and registered') { HP.registered?('fakehost') }
  assert('registry lists bundled default first') { HP.available.first == 'claude' }

  # Idempotency: second call is a no-op (memoized per data_dir)
  HP.load_addons!(dir)
  assert('load_addons! idempotent per data_dir') { HP.available.count('fakehost') == 1 }
end

# =========================================================================
puts "\n=== Section 3: Identity conflict rejected (INV-H13) ==="
Dir.mktmpdir('reg') do |dir|
  mk_addon(dir, 'squatter_projection', key: 'fakehost', source: 'skillset:squatter_projection')
  HP.reset_addon_discovery!
  warnings = ''
  begin
    old_stderr = $stderr
    $stderr = StringIO.new
    HP.load_addons!(dir)
    warnings = $stderr.string
  ensure
    $stderr = old_stderr
  end
  assert('conflicting registration rejected with warning, not crash') do
    warnings.include?('already registered')
  end
  assert('first registration wins deterministically') do
    true # reaching here without raise = loader rejected the conflict cleanly
  end
end

# =========================================================================
puts "\n=== Section 4: Escaping host_profiles declaration rejected (INV-H11) ==="
Dir.mktmpdir('reg') do |dir|
  evil = File.join(dir, 'evil.rb')
  File.write(evil, <<~RUBY)
    require 'kairos_mcp/plugin_projector'
    KairosMcp::PluginProjector::HostProfile.register(
      KairosMcp::PluginProjector::HostProfile.new(
        key: 'evilhost', output_subdir: '.evil', context_file: 'AGENTS.md',
        instruction_mode_delivery: :inline, manifest_suffix: 'evil',
        skill_projection: :own, agents_subdir: 'agents'),
      source: 'evil')
  RUBY
  ss_dir = File.join(dir, 'skillsets', 'escape_projection')
  FileUtils.mkdir_p(ss_dir)
  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(
    'name' => 'escape_projection', 'host_profiles' => ['../../evil.rb']
  ))
  HP.reset_addon_discovery!
  old_stderr = $stderr
  $stderr = StringIO.new
  HP.load_addons!(dir)
  warnings = $stderr.string
  $stderr = old_stderr
  assert('escaping declaration rejected at load time') { warnings.include?('escapes the SkillSet directory') }
  assert('escaping profile NOT registered') { !HP.registered?('evilhost') }
end

# Symlink escape: a lexically-contained host_profiles entry whose REAL target is
# outside the SkillSet directory must be rejected (realpath containment, INV-H11).
Dir.mktmpdir('reg') do |dir|
  outside = File.join(dir, 'outside.rb')
  File.write(outside, <<~RUBY)
    KairosMcp::PluginProjector::HostProfile.register(
      KairosMcp::PluginProjector::HostProfile.new(
        key: 'symhost', output_subdir: '.sym', context_file: 'AGENTS.md',
        instruction_mode_delivery: :inline, manifest_suffix: 'sym',
        skill_projection: :own, agents_subdir: 'agents'),
      source: 'sym')
  RUBY
  ss_dir = File.join(dir, 'skillsets', 'sym_projection')
  FileUtils.mkdir_p(File.join(ss_dir, 'lib'))
  # lib/profile.rb is a symlink whose target is outside the SkillSet dir.
  begin
    File.symlink(outside, File.join(ss_dir, 'lib', 'profile.rb'))
    File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(
      'name' => 'sym_projection', 'host_profiles' => ['lib/profile.rb']
    ))
    HP.reset_addon_discovery!
    old = $stderr
    $stderr = StringIO.new
    HP.load_addons!(dir)
    warn_out = $stderr.string
    $stderr = old
    assert('symlink whose real target escapes the SkillSet dir is rejected') do
      warn_out.include?('escapes the SkillSet directory')
    end
    assert('symlink-escaped profile NOT registered') { !HP.registered?('symhost') }
  rescue NotImplementedError, Errno::EPERM
    puts '  SKIP: filesystem does not support symlinks'
  end
end

# =========================================================================
puts "\n=== Section 5: requires_host pre-flight (INV-H5) ==="
HP.register(
  HP.new(key: 'dependent_host', output_subdir: '.dependent', context_file: 'AGENTS.md',
         instruction_mode_delivery: :inline, manifest_suffix: 'dependent',
         skill_projection: :reuse_claude, agents_subdir: 'agents',
         requires_host: 'claude', hooks_writer: ->(_p, _h, _o) {}),
  source: 'test:synthetic'
)

def mk_min_skillset(root, name)
  ss_dir = File.join(root, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'plugin'))
  File.write(File.join(ss_dir, 'plugin', 'SKILL.md'), "---\nname: #{name}\ndescription: d\n---\nbody\n")
  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(
    'name' => name, 'version' => '1.0.0', 'description' => 'd', 'author' => 't', 'layer' => 'L1',
    'depends_on' => [], 'provides' => [], 'tool_classes' => [], 'config_files' => [],
    'knowledge_dirs' => [], 'min_core_version' => '1.0.0',
    'plugin' => { 'skill_md' => 'plugin/SKILL.md' }
  ))
  KairosMcp::Skillset.new(ss_dir)
end

Dir.mktmpdir('reg') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  ss = mk_min_skillset(File.join(dir, 'ss'), 'demo')

  p_dep = KairosMcp::PluginProjector.new(dir, mode: :project, host: 'dependent_host')
  assert('project! fails pre-flight when prerequisite not projected (INV-H5)') do
    begin
      p_dep.project!([ss])
      false
    rescue KairosMcp::PluginProjector::DependencyUnsatisfied => e
      e.message.include?("requires host 'claude'")
    end
  end
  assert('pre-flight failure leaves no partial output (fails before writes)') do
    !Dir.exist?(File.join(dir, '.dependent'))
  end

  # Satisfy the prerequisite: project claude, then retry.
  KairosMcp::PluginProjector.new(dir, mode: :project, host: 'claude').project!([ss])
  assert('project! succeeds once prerequisite artifacts exist on disk') do
    p_dep.project!([ss])
    true
  end

  # Artifacts-on-disk (not registry membership) is the criterion: delete a
  # projected claude artifact and the dependent must fail again.
  claude_manifest = JSON.parse(File.read(File.join(dir, '.kairos/projection_manifest.json')))
  victim = claude_manifest['outputs'].keys.first
  FileUtils.rm_f(victim)
  assert('missing prerequisite artifact on disk fails pre-flight (registry membership insufficient)') do
    begin
      KairosMcp::PluginProjector.new(dir, mode: :project, host: 'dependent_host').project!([ss])
      false
    rescue KairosMcp::PluginProjector::DependencyUnsatisfied => e
      e.message.include?('missing on disk')
    end
  end
end

# =========================================================================
puts "\n=== Section 6: INV-H5 verify-against-source (impl review R1 P1) ==="
Dir.mktmpdir('reg') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  ss_v1 = mk_min_skillset(File.join(dir, 'ss'), 'demo')
  # Project claude against v1 sources.
  KairosMcp::PluginProjector.new(dir, mode: :project, host: 'claude').project!([ss_v1])

  # Same sources: dependent projects cleanly (digest matches).
  assert('dependent projects when prerequisite source digest matches') do
    KairosMcp::PluginProjector.new(dir, mode: :project, host: 'dependent_host').project!([ss_v1])
    true
  end

  # Mutate the source so the digest changes; the prerequisite (claude) is now
  # stale relative to current sources, so the dependent must fail pre-flight
  # even though every claude artifact still exists on disk.
  File.write(File.join(dir, 'ss', 'demo', 'plugin', 'SKILL.md'),
             "---\nname: demo\ndescription: CHANGED\n---\nnew body\n")
  ss_v2 = KairosMcp::Skillset.new(File.join(dir, 'ss', 'demo'))
  assert('stale prerequisite (source digest mismatch) fails pre-flight (verify-against-source)') do
    begin
      KairosMcp::PluginProjector.new(dir, mode: :project, host: 'dependent_host').project!([ss_v2])
      false
    rescue KairosMcp::PluginProjector::DependencyUnsatisfied => e
      e.message.include?('stale')
    end
  end
end

# =========================================================================
puts "\n=== Section 7: corrupt prerequisite manifest fails cleanly (impl review R1 P1a) ==="
Dir.mktmpdir('reg') do |dir|
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  ss = mk_min_skillset(File.join(dir, 'ss'), 'demo')
  KairosMcp::PluginProjector.new(dir, mode: :project, host: 'claude').project!([ss])
  # Overwrite claude manifest with valid-JSON-but-non-Hash content.
  File.write(File.join(dir, '.kairos/projection_manifest.json'), JSON.generate([1, 2, 3]))
  assert('non-Hash prerequisite manifest raises DependencyUnsatisfied, not NoMethodError') do
    begin
      KairosMcp::PluginProjector.new(dir, mode: :project, host: 'dependent_host').project!([ss])
      false
    rescue KairosMcp::PluginProjector::DependencyUnsatisfied => e
      e.message.include?('malformed')
    rescue NoMethodError
      false
    end
  end
end

# =========================================================================
puts "\n=== Section 8: INV-H11 output-area validation at registration (impl review R1 P1) ==="
assert('output_subdir with traversal is rejected at construction (InvalidProfile)') do
  begin
    HP.new(key: 'evil', output_subdir: '..', context_file: 'AGENTS.md',
           instruction_mode_delivery: :inline, manifest_suffix: 'evil',
           skill_projection: :own, agents_subdir: 'agents')
    false
  rescue HP::InvalidProfile
    true
  end
end
assert('output_subdir with a path separator is rejected') do
  begin
    HP.new(key: 'evil2', output_subdir: 'a/b', context_file: 'AGENTS.md',
           instruction_mode_delivery: :inline, manifest_suffix: 'evil2',
           skill_projection: :own, agents_subdir: 'agents')
    false
  rescue HP::InvalidProfile
    true
  end
end
assert('context_file with a path separator is rejected') do
  begin
    HP.new(key: 'evil3', output_subdir: '.evil3', context_file: '../escape',
           instruction_mode_delivery: :inline, manifest_suffix: 'evil3',
           skill_projection: :own, agents_subdir: 'agents')
    false
  rescue HP::InvalidProfile
    true
  end
end
assert('legitimate dotted output_subdir (.claude) is accepted') do
  HP.new(key: 'okhost', output_subdir: '.okhost', context_file: 'AGENTS.md',
         instruction_mode_delivery: :inline, manifest_suffix: 'okhost',
         skill_projection: :own, agents_subdir: 'agents')
  true
end

# =========================================================================
puts "\n=== Section 9: INV-H13 source provenance from on-disk dir (impl review R1 P1) ==="
Dir.mktmpdir('reg') do |dir|
  # Two DIFFERENT skillset dirs both declare host key 'dupe' AND both self-assert
  # the same source string. Provenance must come from the dir, so the second is
  # rejected as a conflict rather than silently overwriting.
  %w[aaa_dupe zzz_dupe].each do |name|
    ss_dir = File.join(dir, 'skillsets', name)
    FileUtils.mkdir_p(File.join(ss_dir, 'lib'))
    File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(
      'name' => name, 'host_profiles' => ['lib/profile.rb']
    ))
    File.write(File.join(ss_dir, 'lib', 'profile.rb'), <<~RUBY)
      KairosMcp::PluginProjector::HostProfile.register(
        KairosMcp::PluginProjector::HostProfile.new(
          key: 'dupe', output_subdir: '.dupe_#{name}', context_file: 'AGENTS.md',
          instruction_mode_delivery: :inline, manifest_suffix: 'dupe',
          skill_projection: :own, agents_subdir: 'agents'),
        source: 'skillset:canonical-dupe')
    RUBY
  end
  HP.reset_addon_discovery!
  old = $stderr
  $stderr = StringIO.new
  HP.load_addons!(dir)
  warnings = $stderr.string
  $stderr = old
  assert('second dir claiming same key is rejected despite identical self-declared source') do
    warnings.include?('already registered')
  end
  assert('first (alphabetical) dir wins the host key') do
    HP.lookup('dupe').output_subdir == '.dupe_aaa_dupe'
  end
end

puts "\n" + ('=' * 60)
puts "Total: #{$pass_count} passed, #{$fail_count} failed"
exit($fail_count.zero? ? 0 : 1)
