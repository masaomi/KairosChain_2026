#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for PluginProjector (Phase 1: SkillSet Plugin Projection)

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/plugin_projector'
require 'kairos_mcp/skillset'
require 'tmpdir'
require 'fileutils'
require 'json'

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

# Helper: create a minimal SkillSet with plugin/ directory
def create_test_skillset(dir, name:, tools: [], plugin: true, hooks: nil, agents: [])
  ss_dir = File.join(dir, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'tools'))

  json = {
    'name' => name,
    'version' => '1.0.0',
    'description' => "Test SkillSet #{name}",
    'author' => 'test',
    'layer' => 'L1',
    'depends_on' => [],
    'provides' => [],
    'tool_classes' => tools,
    'config_files' => [],
    'knowledge_dirs' => [],
    'min_core_version' => '1.0.0'
  }

  if plugin
    FileUtils.mkdir_p(File.join(ss_dir, 'plugin'))
    json['plugin'] = {
      'skill_md' => 'plugin/SKILL.md',
      'hooks' => 'plugin/hooks.json',
      'agents_dir' => 'plugin/agents'
    }

    File.write(File.join(ss_dir, 'plugin', 'SKILL.md'), <<~MD)
      ---
      name: #{name}
      description: "Test skill for #{name}"
      ---

      # #{name}

      ## Available Tools

      <!-- AUTO_TOOLS -->

      ## Workflow

      Test workflow.
    MD

    if hooks
      File.write(File.join(ss_dir, 'plugin', 'hooks.json'), JSON.pretty_generate(hooks))
    end

    agents.each do |agent_name|
      agents_dir = File.join(ss_dir, 'plugin', 'agents')
      FileUtils.mkdir_p(agents_dir)
      File.write(File.join(agents_dir, "#{agent_name}.md"), <<~MD)
        ---
        name: #{agent_name}
        description: "Test agent #{agent_name}"
        model: sonnet
        ---

        You are #{agent_name}.
      MD
    end
  end

  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(json))
  KairosMcp::Skillset.new(ss_dir)
end

# Helper: create project structure
def create_test_project(dir, mode: :project)
  if mode == :project
    FileUtils.mkdir_p(File.join(dir, '.claude'))
  else
    FileUtils.mkdir_p(File.join(dir, '.claude-plugin'))
    File.write(File.join(dir, '.claude-plugin', 'plugin.json'),
      JSON.pretty_generate({ 'name' => 'test', 'version' => '1.0.0' }))
  end
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
end

# =========================================================================
puts "\n=== Section 1: Basic Initialization ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir, mode: :project)

  assert('Project mode: output_root is .claude/') do
    p = KairosMcp::PluginProjector.new(dir, mode: :project)
    p.output_root == File.join(dir, '.claude')
  end

  assert('Plugin mode: output_root is project root') do
    p = KairosMcp::PluginProjector.new(dir, mode: :plugin)
    p.output_root == dir
  end

  assert('Auto mode defaults to project') do
    p = KairosMcp::PluginProjector.new(dir, mode: :auto)
    p.mode == :project
  end
end

# =========================================================================
puts "\n=== Section 2: Skill Projection ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir)
  ss_dir = File.join(dir, 'skillsets')

  ss1 = create_test_skillset(ss_dir, name: 'test_skill_a')
  ss2 = create_test_skillset(ss_dir, name: 'test_skill_b', plugin: false)

  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project!([ss1, ss2])

  assert('Skill with plugin/ is projected to .claude/skills/') do
    File.exist?(File.join(dir, '.claude', 'skills', 'test_skill_a', 'SKILL.md'))
  end

  assert('Skill without plugin/ is NOT projected') do
    !File.exist?(File.join(dir, '.claude', 'skills', 'test_skill_b', 'SKILL.md'))
  end

  assert('Projected SKILL.md contains template content') do
    content = File.read(File.join(dir, '.claude', 'skills', 'test_skill_a', 'SKILL.md'))
    content.include?('Test workflow')
  end

  assert('Seed skills (kairos-chain) are not projected') do
    ss_seed = create_test_skillset(ss_dir, name: 'kairos-chain')
    projector.project!([ss_seed])
    !File.exist?(File.join(dir, '.claude', 'skills', 'kairos-chain', 'SKILL.md'))
  end

  assert('Manifest is created') do
    manifest_path = File.join(dir, '.kairos', 'projection_manifest.json')
    File.exist?(manifest_path)
  end

  assert('Manifest contains output entries') do
    manifest = JSON.parse(File.read(File.join(dir, '.kairos', 'projection_manifest.json')))
    manifest['outputs'].is_a?(Hash) && !manifest['outputs'].empty?
  end
end

# =========================================================================
puts "\n=== Section 3: Agent Projection ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir)
  ss_dir = File.join(dir, 'skillsets')

  ss = create_test_skillset(ss_dir, name: 'agent_test', agents: ['monitor', 'reviewer'])
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project!([ss])

  assert('Agents are projected with skillset name prefix') do
    File.exist?(File.join(dir, '.claude', 'agents', 'agent_test-monitor.md')) &&
    File.exist?(File.join(dir, '.claude', 'agents', 'agent_test-reviewer.md'))
  end

  assert('Agent content is preserved') do
    content = File.read(File.join(dir, '.claude', 'agents', 'agent_test-monitor.md'))
    content.include?('You are monitor')
  end
end

# =========================================================================
puts "\n=== Section 4: Hooks Projection (Project Mode) ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir)
  ss_dir = File.join(dir, 'skillsets')

  hooks_data = {
    'hooks' => {
      'PostToolUse' => [
        { 'matcher' => 'mcp__kairos-chain__test', 'hooks' => [{ 'type' => 'command', 'command' => 'echo test' }] }
      ]
    }
  }
  ss = create_test_skillset(ss_dir, name: 'hooks_test', hooks: hooks_data)

  # Pre-existing user settings with permissions
  settings_path = File.join(dir, '.claude', 'settings.json')
  File.write(settings_path, JSON.pretty_generate({
    'permissions' => { 'allow' => ['Read'] },
    'hooks' => {
      'PostToolUse' => [
        { 'matcher' => 'Write', 'hooks' => [{ 'type' => 'command', 'command' => 'echo user-hook' }] }
      ]
    }
  }))

  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project!([ss])

  assert('settings.json is updated with hooks') do
    settings = JSON.parse(File.read(settings_path))
    settings.dig('hooks', 'PostToolUse')&.any? { |h| h['matcher'] == 'mcp__kairos-chain__test' }
  end

  assert('User permissions are preserved') do
    settings = JSON.parse(File.read(settings_path))
    settings.dig('permissions', 'allow')&.include?('Read')
  end

  assert('User hooks are preserved') do
    settings = JSON.parse(File.read(settings_path))
    settings.dig('hooks', 'PostToolUse')&.any? { |h| h['matcher'] == 'Write' && h['_projected_by'].nil? }
  end

  assert('Projected hooks have _projected_by tag') do
    settings = JSON.parse(File.read(settings_path))
    projected = settings.dig('hooks', 'PostToolUse')&.select { |h| h['_projected_by'] == 'kairos-chain' }
    projected&.length == 1
  end

  # Re-project: projected hooks are replaced, user hooks preserved
  projector.project!([ss])

  assert('Re-projection does not duplicate hooks') do
    settings = JSON.parse(File.read(settings_path))
    projected = settings.dig('hooks', 'PostToolUse')&.select { |h| h['_projected_by'] == 'kairos-chain' }
    projected&.length == 1
  end

  assert('Re-projection preserves user hooks') do
    settings = JSON.parse(File.read(settings_path))
    user = settings.dig('hooks', 'PostToolUse')&.select { |h| h['_projected_by'].nil? }
    user&.length == 1
  end
end

# =========================================================================
puts "\n=== Section 5: Hooks Projection (Plugin Mode) ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir, mode: :plugin)
  ss_dir = File.join(dir, 'skillsets')

  hooks_data = {
    'hooks' => {
      'PostToolUse' => [
        { 'matcher' => 'test_tool', 'hooks' => [{ 'type' => 'command', 'command' => 'echo plugin' }] }
      ]
    }
  }
  ss = create_test_skillset(ss_dir, name: 'plugin_hooks_test', hooks: hooks_data)
  projector = KairosMcp::PluginProjector.new(dir, mode: :plugin)
  projector.project!([ss])

  assert('Plugin mode: hooks/hooks.json is created') do
    File.exist?(File.join(dir, 'hooks', 'hooks.json'))
  end

  assert('Plugin mode: hooks content is correct') do
    hooks = JSON.parse(File.read(File.join(dir, 'hooks', 'hooks.json')))
    hooks.dig('hooks', 'PostToolUse')&.any? { |h| h['matcher'] == 'test_tool' }
  end
end

# =========================================================================
puts "\n=== Section 6: Knowledge Meta Skill ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir)

  knowledge_entries = [
    { name: 'multi_llm_review', description: 'Multi-LLM review workflow', version: '1.0', tags: ['workflow'] },
    { name: 'design_guide', description: 'Design guidelines', version: '2.0', tags: ['design', 'guide'] }
  ]

  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project!([], knowledge_entries: knowledge_entries)

  assert('Knowledge meta skill is projected') do
    File.exist?(File.join(dir, '.claude', 'skills', 'kairos-knowledge', 'SKILL.md'))
  end

  assert('Knowledge list contains entries') do
    content = File.read(File.join(dir, '.claude', 'skills', 'kairos-knowledge', 'SKILL.md'))
    content.include?('multi_llm_review') && content.include?('design_guide')
  end

  assert('Knowledge meta skill is NOT created when no knowledge') do
    projector2 = KairosMcp::PluginProjector.new(dir, mode: :project)
    # Clean previous
    FileUtils.rm_rf(File.join(dir, '.claude', 'skills', 'kairos-knowledge'))
    projector2.project!([], knowledge_entries: [])
    !File.exist?(File.join(dir, '.claude', 'skills', 'kairos-knowledge', 'SKILL.md'))
  end
end

# =========================================================================
puts "\n=== Section 7: Digest & No-op ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir)
  ss_dir = File.join(dir, 'skillsets')
  ss = create_test_skillset(ss_dir, name: 'digest_test')

  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project!([ss])

  assert('project_if_changed! returns false when unchanged') do
    projector2 = KairosMcp::PluginProjector.new(dir, mode: :project)
    projector2.project_if_changed!([ss]) == false
  end
end

# =========================================================================
puts "\n=== Section 8: Stale Cleanup ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir)
  ss_dir = File.join(dir, 'skillsets')
  ss = create_test_skillset(ss_dir, name: 'cleanup_test')

  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project!([ss])

  stale_path = File.join(dir, '.claude', 'skills', 'cleanup_test', 'SKILL.md')
  assert('Projected file exists before cleanup') { File.exist?(stale_path) }

  # Re-project with empty list -> stale should be cleaned up
  projector.project!([])

  assert('Stale file is removed after re-projection') do
    !File.exist?(stale_path)
  end

  assert('Empty directory is removed') do
    !Dir.exist?(File.join(dir, '.claude', 'skills', 'cleanup_test'))
  end
end

# =========================================================================
puts "\n=== Section 9: Status & Verify ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir)
  ss_dir = File.join(dir, 'skillsets')
  ss = create_test_skillset(ss_dir, name: 'status_test')

  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project!([ss])

  assert('Status returns mode and output_root') do
    s = projector.status
    s[:mode] == :project && s[:output_root] == File.join(dir, '.claude')
  end

  assert('Verify returns valid when all files exist') do
    v = projector.verify
    v[:valid] == true
  end

  assert('Verify detects missing files') do
    skill_path = File.join(dir, '.claude', 'skills', 'status_test', 'SKILL.md')
    FileUtils.rm_f(skill_path)
    v = projector.verify
    v[:valid] == false && v[:missing].include?(skill_path)
  end
end

# =========================================================================
puts "\n=== Section 10: Error Handling ==="
separator

Dir.mktmpdir('test_projector') do |dir|
  create_test_project(dir)

  assert('Broken settings.json does not crash') do
    settings_path = File.join(dir, '.claude', 'settings.json')
    File.write(settings_path, '{ broken json !!!}')
    projector = KairosMcp::PluginProjector.new(dir, mode: :project)
    hooks = { 'hooks' => { 'PostToolUse' => [{ 'matcher' => 'X', 'hooks' => [] }] } }
    # Should not raise, should warn
    projector.send(:write_hooks_to_settings!, hooks, {})
    # settings.json should NOT be overwritten
    File.read(settings_path).include?('broken')
  end
end

# =========================================================================
separator
puts "\n=== Results ==="
puts "  Total: #{$pass_count + $fail_count} (#{$pass_count} passed, #{$fail_count} failed)"
exit($fail_count > 0 ? 1 : 0)
