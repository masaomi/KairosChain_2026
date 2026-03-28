# frozen_string_literal: true

# Test: Attestation Nudge (MMP)
# Tests: 15 (unit 13 + integration 2)

require 'tmpdir'
require 'json'
require 'fileutils'
require 'time'

# Minimal stubs for standalone testing
module KairosMcp
  def self.storage_dir
    @storage_dir || '/tmp/kairos_test'
  end

  def self.storage_dir=(dir)
    @storage_dir = dir
  end

  class ToolRegistry
    @gates = {}
    @gate_mutex = Mutex.new

    class GateDeniedError < StandardError
      attr_reader :tool_name, :role
      def initialize(tool_name, role, msg = nil)
        @tool_name = tool_name
        @role = role
        super(msg || "Access denied")
      end
    end

    def self.register_gate(name, &block)
      @gate_mutex.synchronize { @gates[name.to_sym] = block }
    end

    def self.unregister_gate(name)
      @gate_mutex.synchronize { @gates.delete(name.to_sym) }
    end

    def self.run_gates(tool_name, arguments, safety)
      @gate_mutex.synchronize { @gates.values.dup }.each do |gate|
        gate.call(tool_name, arguments, safety)
      end
    end

    def self.clear_gates!
      @gate_mutex.synchronize { @gates = {} }
    end

    def self.gates
      @gate_mutex.synchronize { @gates.dup }
    end
  end
end

# Stub MMP.load_config
module MMP
  def self.load_config
    @test_config || { 'attestation_nudge' => { 'enabled' => true, 'threshold' => 3, 'cooldown_hours' => 24, 'nudge_interval_hours' => 4 } }
  end

  def self.test_config=(config)
    @test_config = config
  end
end

require_relative 'templates/skillsets/mmp/lib/mmp/attestation_nudge'

# ===== Test Harness =====
$pass = 0
$fail = 0
$errors = []

def test_section(name)
  puts "\n===== #{name} ====="
end

def assert(desc)
  result = yield
  if result
    $pass += 1
    puts "  PASS: #{desc}"
  else
    $fail += 1
    $errors << desc
    puts "  FAIL: #{desc}"
  end
rescue StandardError => e
  $fail += 1
  $errors << "#{desc} (#{e.class}: #{e.message})"
  puts "  FAIL: #{desc} — #{e.class}: #{e.message}"
end

# ===== Setup =====
def setup_tracker
  dir = Dir.mktmpdir('nudge_test')
  MMP::AttestationNudge.reset!
  tracker = MMP::AttestationNudge.new(dir)
  [tracker, dir]
end

def cleanup(dir)
  FileUtils.rm_rf(dir) if dir && dir.start_with?('/tmp') || dir&.start_with?(Dir.tmpdir)
end

# ===== Unit Tests =====

test_section('Test 1: register_acquisition creates entry')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test Skill',
  owner_agent_id: 'agent_a', content_hash: 'hash_abc',
  file_path: '/tmp/received/test_skill.md'
)
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('entry created with composite key') { data.size == 1 }
entry = data.values.first
assert('skill_id stored') { entry['skill_id'] == 'skill_1' }
assert('use_count starts at 0') { entry['use_count'] == 0 }
assert('attested starts false') { entry['attested'] == false }
assert('file_path stored') { entry['file_path'] == '/tmp/received/test_skill.md' }
cleanup(dir)

test_section('Test 2: duplicate registration (same content_hash)')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a', content_hash: 'hash_1'
)
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test Updated', owner_agent_id: 'agent_a', content_hash: 'hash_1'
)
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('no duplicate: still 1 entry') { data.size == 1 }
assert('name not changed on same hash') { data.values.first['skill_name'] == 'Test' }
cleanup(dir)

test_section('Test 3: re-acquisition with new content_hash resets')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a', content_hash: 'hash_v1'
)
# Simulate usage
3.times { tracker.record_file_usage('/tmp/received/test_skill.md') }
# Mark attested
tracker.mark_attested(skill_id: 'skill_1', owner_agent_id: 'agent_a')
# Re-acquire with new version
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_v2', file_path: '/tmp/received/test_skill_v2.md'
)
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
entry = data.values.first
assert('still 1 entry (not duplicated)') { data.size == 1 }
assert('content_hash updated') { entry['content_hash'] == 'hash_v2' }
assert('use_count reset to 0') { entry['use_count'] == 0 }
assert('attested reset to false') { entry['attested'] == false }
cleanup(dir)

test_section('Test 4: record_tool_usage increments for matching tool')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', tool_names: ['my_tool', 'my_other_tool']
)
tracker.record_tool_usage('my_tool')
tracker.record_tool_usage('my_other_tool')
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('use_count incremented to 2') { data.values.first['use_count'] == 2 }
cleanup(dir)

test_section('Test 5: record_tool_usage ignores non-matching tool')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', tool_names: ['my_tool']
)
tracker.record_tool_usage('unrelated_tool')
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('use_count unchanged (0)') { data.values.first['use_count'] == 0 }
cleanup(dir)

test_section('Test 6: record_file_usage increments for matching path')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', file_path: '/tmp/received/test.md'
)
tracker.record_file_usage('/tmp/received/test.md')
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('use_count incremented to 1') { data.values.first['use_count'] == 1 }
cleanup(dir)

test_section('Test 7: pending_nudge returns nil when below threshold')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', file_path: '/tmp/test.md'
)
2.times { tracker.record_file_usage('/tmp/test.md') }
assert('nil below threshold (2 < 3)') { tracker.pending_nudge.nil? }
cleanup(dir)

test_section('Test 8: pending_nudge returns message when eligible')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test Skill', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', file_path: '/tmp/test.md'
)
3.times { tracker.record_file_usage('/tmp/test.md') }
msg = tracker.pending_nudge
assert('nudge message returned') { !msg.nil? }
assert('contains skill name') { msg.include?('Test Skill') }
assert('contains owner') { msg.include?('agent_a') }
assert('contains skill_id for command') { msg.include?('skill_1') }
assert('contains use count') { msg.include?('3 times') }
cleanup(dir)

test_section('Test 9: pending_nudge returns nil during per-skill cooldown')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', file_path: '/tmp/test.md'
)
3.times { tracker.record_file_usage('/tmp/test.md') }
# First nudge: should work
msg1 = tracker.pending_nudge
assert('first nudge returned') { !msg1.nil? }
# Second nudge: within cooldown
msg2 = tracker.pending_nudge
assert('second nudge nil (cooldown)') { msg2.nil? }
cleanup(dir)

test_section('Test 10: pending_nudge returns nil during global interval')
tracker, dir = setup_tracker
# Two skills, both eligible
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Skill A', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', file_path: '/tmp/a.md'
)
tracker.register_acquisition(
  skill_id: 'skill_2', skill_name: 'Skill B', owner_agent_id: 'agent_b',
  content_hash: 'hash_2', file_path: '/tmp/b.md'
)
3.times { tracker.record_file_usage('/tmp/a.md') }
3.times { tracker.record_file_usage('/tmp/b.md') }
msg1 = tracker.pending_nudge
assert('first nudge returned') { !msg1.nil? }
# Second nudge for different skill: blocked by global interval
msg2 = tracker.pending_nudge
assert('global interval blocks second skill nudge') { msg2.nil? }
cleanup(dir)

test_section('Test 11: pending_nudge sets last_nudge_at (passive decline)')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', file_path: '/tmp/test.md'
)
3.times { tracker.record_file_usage('/tmp/test.md') }
tracker.pending_nudge
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('last_nudge_at set after nudge') { !data.values.first['last_nudge_at'].nil? }
cleanup(dir)

test_section('Test 12: mark_attested stops nudges')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', file_path: '/tmp/test.md'
)
5.times { tracker.record_file_usage('/tmp/test.md') }
tracker.mark_attested(skill_id: 'skill_1', owner_agent_id: 'agent_a')
msg = tracker.pending_nudge
assert('no nudge after attestation') { msg.nil? }
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('attested is true') { data.values.first['attested'] == true }
assert('attested_at set') { !data.values.first['attested_at'].nil? }
cleanup(dir)

test_section('Test 12b: record_file_usage is no-op after attestation (P1-6)')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_1', skill_name: 'Test', owner_agent_id: 'agent_a',
  content_hash: 'hash_1', file_path: '/tmp/test.md'
)
3.times { tracker.record_file_usage('/tmp/test.md') }
tracker.mark_attested(skill_id: 'skill_1', owner_agent_id: 'agent_a')
# Usage after attestation should not increment
tracker.record_file_usage('/tmp/test.md')
tracker.record_file_usage('/tmp/test.md')
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('use_count stays at 3 after attestation') { data.values.first['use_count'] == 3 }
# Index should be cleared for attested skill (P1-4)
assert('file_path_index cleared for attested skill') { tracker.file_path_index['/tmp/test.md'].nil? }
cleanup(dir)

test_section('Test 13: different owner same skill_name = separate entries')
tracker, dir = setup_tracker
tracker.register_acquisition(
  skill_id: 'skill_x', skill_name: 'Shared Name', owner_agent_id: 'owner_1',
  content_hash: 'hash_1'
)
tracker.register_acquisition(
  skill_id: 'skill_x', skill_name: 'Shared Name', owner_agent_id: 'owner_2',
  content_hash: 'hash_2'
)
data = JSON.parse(File.read(File.join(dir, MMP::AttestationNudge::USAGE_FILE)))
assert('two separate entries') { data.size == 2 }
cleanup(dir)

# ===== Integration Tests =====

test_section('Test 14: gate registration + tool call')
KairosMcp::ToolRegistry.clear_gates!
MMP::AttestationNudge.reset!
test_dir = Dir.mktmpdir('nudge_gate_test')
tracker = MMP::AttestationNudge.new(test_dir)
tracker.register_acquisition(
  skill_id: 'skill_g', skill_name: 'Gate Test', owner_agent_id: 'agent_g',
  content_hash: 'hash_g', tool_names: ['test_tool_from_skill']
)

# Register gate (same pattern as design)
KairosMcp::ToolRegistry.register_gate(:attestation_nudge) do |tool_name, _args, _safety|
  tracker.record_tool_usage(tool_name)
rescue StandardError => e
  warn "[test] gate error: #{e.message}"
end

# Simulate tool calls
KairosMcp::ToolRegistry.run_gates('test_tool_from_skill', {}, nil)
KairosMcp::ToolRegistry.run_gates('unrelated_tool', {}, nil)
KairosMcp::ToolRegistry.run_gates('test_tool_from_skill', {}, nil)

data = JSON.parse(File.read(File.join(test_dir, MMP::AttestationNudge::USAGE_FILE)))
assert('gate incremented use_count to 2') { data.values.first['use_count'] == 2 }
KairosMcp::ToolRegistry.clear_gates!
cleanup(test_dir)

test_section('Test 15: gate error does not break tool call')
KairosMcp::ToolRegistry.clear_gates!
KairosMcp::ToolRegistry.register_gate(:attestation_nudge) do |_tool_name, _args, _safety|
  raise "simulated JSON parse error"
rescue StandardError => e
  warn "[test] gate error caught: #{e.message}"
end

# Should not raise
error_raised = false
begin
  KairosMcp::ToolRegistry.run_gates('any_tool', {}, nil)
rescue StandardError
  error_raised = true
end
assert('gate error rescued, tool call not broken') { !error_raised }
KairosMcp::ToolRegistry.clear_gates!

# ===== Summary =====
puts "\n===== RESULTS ====="
puts "  PASS: #{$pass}"
puts "  FAIL: #{$fail}"
if $fail > 0
  puts "\n  Failed tests:"
  $errors.each { |e| puts "    - #{e}" }
end
exit($fail > 0 ? 1 : 0)
