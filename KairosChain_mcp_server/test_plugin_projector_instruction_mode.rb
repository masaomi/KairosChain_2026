#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for PluginProjector instruction mode projection.
# See: log/20260507_plugin_projector_instruction_mode_implementation_plan.md

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp/plugin_projector'
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

def setup_project(dir, with_claudemd: true)
  FileUtils.mkdir_p(File.join(dir, '.claude'))
  FileUtils.mkdir_p(File.join(dir, '.kairos'))
  if with_claudemd
    File.write(File.join(dir, 'CLAUDE.md'), "# Project CLAUDE.md\n\nSome existing content.\n")
  end
end

def claudemd(dir) = File.join(dir, 'CLAUDE.md')
def manifest(dir) = File.join(dir, '.kairos', 'instruction_mode_manifest.json')
def artifact(dir) = File.join(dir, '.claude', 'kairos', 'instruction_mode.md')

# =========================================================================
puts "\n=== Section 1: Basic projection ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir)
  body = "# Test Mode\n\n**Version:** 0.9\n\nbody content here.\n"
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  result = projector.project_instruction_mode!('test_mode', body, mode_version: '0.9')

  assert('returns artifact path') { result[:artifact_path] == artifact(dir) }
  assert('writes artifact file') { File.exist?(artifact(dir)) }
  assert('artifact content matches body') { File.read(artifact(dir)) == body }
  assert('returns size_bytes') { result[:size_bytes] == body.bytesize }
  assert('reports region written') { result[:region_written] == true }
  assert('CLAUDE.md contains BEGIN marker') { File.read(claudemd(dir)).include?(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_BEGIN) }
  assert('CLAUDE.md contains END marker') { File.read(claudemd(dir)).include?(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_END) }
  assert('CLAUDE.md contains @-import line') { File.read(claudemd(dir)).include?('@.claude/kairos/instruction_mode.md') }
  assert('CLAUDE.md preserves existing content') { File.read(claudemd(dir)).include?('Some existing content.') }
  assert('CLAUDE.md contains identity header') { File.read(claudemd(dir)).include?('Active mode: test_mode v0.9') }
  assert('writes manifest') { File.exist?(manifest(dir)) }
  assert('manifest records mode_name') { JSON.parse(File.read(manifest(dir)))['mode_name'] == 'test_mode' }
end

# =========================================================================
puts "\n=== Section 2: Idempotency (re-projection produces stable region) ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir)
  body = "# Test Mode\n\n**Version:** 1.0\n\nbody.\n"
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)

  projector.project_instruction_mode!('test_mode', body, mode_version: '1.0')
  first = File.read(claudemd(dir))

  projector.project_instruction_mode!('test_mode', body, mode_version: '1.0')
  second = File.read(claudemd(dir))

  assert('CLAUDE.md is byte-identical after re-projection') { first == second }

  # Region count: exactly 1 BEGIN and 1 END
  assert('exactly one BEGIN marker after re-projection') do
    second.scan(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_BEGIN).length == 1
  end
  assert('exactly one END marker after re-projection') do
    second.scan(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_END).length == 1
  end
end

# =========================================================================
puts "\n=== Section 3: Mode switch (different mode replaces region) ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir)
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)

  projector.project_instruction_mode!('mode_a', "body A\n", mode_version: '1.0')
  projector.project_instruction_mode!('mode_b', "body B different content\n", mode_version: '2.0')

  content = File.read(claudemd(dir))
  assert('CLAUDE.md identity header reflects new mode') { content.include?('Active mode: mode_b v2.0') }
  assert('CLAUDE.md identity header does NOT show old mode') { !content.include?('Active mode: mode_a') }
  assert('artifact contains new body') { File.read(artifact(dir)) == "body B different content\n" }
  assert('manifest updated to new mode') { JSON.parse(File.read(manifest(dir)))['mode_name'] == 'mode_b' }

  # Still exactly one region
  assert('still exactly one BEGIN marker after switch') do
    content.scan(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_BEGIN).length == 1
  end
end

# =========================================================================
puts "\n=== Section 4: User content outside markers preserved ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir)
  original = "# CLAUDE.md\n\nUSER_CONTENT_TOP_8A3F\n\n## Section\n\nUSER_CONTENT_BOTTOM_2C7E\n"
  File.write(claudemd(dir), original)

  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project_instruction_mode!('test_mode', "body\n", mode_version: '1.0')

  content = File.read(claudemd(dir))
  assert('top user content preserved') { content.include?('USER_CONTENT_TOP_8A3F') }
  assert('bottom user content preserved') { content.include?('USER_CONTENT_BOTTOM_2C7E') }
  assert('region appended after existing content') do
    content.index('USER_CONTENT_BOTTOM_2C7E') < content.index(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_BEGIN)
  end
end

# =========================================================================
puts "\n=== Section 5: Removal ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir)
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project_instruction_mode!('test_mode', "body\n", mode_version: '1.0')

  result = projector.remove_projected_instruction_mode!

  assert('reports artifact removed') { result[:artifact_removed] == true }
  assert('reports region removed') { result[:region_removed] == true }
  assert('artifact file deleted') { !File.exist?(artifact(dir)) }
  assert('CLAUDE.md no longer contains marker') do
    !File.read(claudemd(dir)).include?(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_BEGIN)
  end
  assert('user content still preserved after removal') { File.read(claudemd(dir)).include?('Some existing content.') }
  assert('manifest cleared') { !File.exist?(manifest(dir)) }
end

# =========================================================================
puts "\n=== Section 6: Removal is idempotent ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir)
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)

  result = projector.remove_projected_instruction_mode!
  assert('removing nothing reports artifact_removed: false') { result[:artifact_removed] == false }
  assert('removing nothing reports region_removed: false') { result[:region_removed] == false }
  assert('CLAUDE.md untouched after no-op removal') { File.read(claudemd(dir)).include?('Some existing content.') }
end

# =========================================================================
puts "\n=== Section 7: Size policy (refuse > 256KB) ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir)
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  oversized = 'x' * (KairosMcp::PluginProjector::INSTRUCTION_MODE_SIZE_REFUSE + 1)

  raised = false
  begin
    projector.project_instruction_mode!('test_mode', oversized)
  rescue KairosMcp::PluginProjector::InstructionModeTooLarge
    raised = true
  end

  assert('raises InstructionModeTooLarge when body > refuse threshold') { raised }
  assert('artifact NOT written when oversized') { !File.exist?(artifact(dir)) }
  assert('CLAUDE.md NOT touched when oversized') { !File.read(claudemd(dir)).include?(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_BEGIN) }
end

# =========================================================================
puts "\n=== Section 8: Status reporting ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir)
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)

  s = projector.instruction_mode_status
  assert('status before projection: not active') { s[:active] == false }

  projector.project_instruction_mode!('masa', "# Masa Mode\n\n**Version:** 0.4\n\nbody\n", mode_version: '0.4')

  s = projector.instruction_mode_status
  assert('status after projection: active') { s[:active] == true }
  assert('status reports mode_name') { s[:mode_name] == 'masa' }
  assert('status reports mode_version') { s[:mode_version] == '0.4' }
  assert('status reports region_present: true') { s[:region_present] == true }
end

# =========================================================================
puts "\n=== Section 9: CLAUDE.md not yet existing ==="
separator

Dir.mktmpdir('test_imode') do |dir|
  setup_project(dir, with_claudemd: false)
  projector = KairosMcp::PluginProjector.new(dir, mode: :project)
  projector.project_instruction_mode!('test_mode', "body\n", mode_version: '1.0')

  assert('CLAUDE.md created') { File.exist?(claudemd(dir)) }
  assert('CLAUDE.md contains region') { File.read(claudemd(dir)).include?(KairosMcp::PluginProjector::INSTRUCTION_MODE_MARKER_BEGIN) }
end

# =========================================================================
puts "\n#{'=' * 60}"
puts "Total: #{$pass_count} passed, #{$fail_count} failed"
exit($fail_count == 0 ? 0 : 1)
