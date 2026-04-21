#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.2 M3 — PolicyElevation + ElevationToken + ExecutionContext tests.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'kairos_mcp/daemon/execution_context'
require 'kairos_mcp/daemon/elevation_token'
require 'kairos_mcp/daemon/policy_elevation'

$pass = 0
$fail = 0
$failed_names = []

def assert(description)
  ok = yield
  if ok
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    $failed_names << description
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  $failed_names << description
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

ET = KairosMcp::Daemon::ElevationToken
EC = KairosMcp::Daemon::ExecutionContext
PE = KairosMcp::Daemon::PolicyElevation

# Minimal Safety stub with push/pop_policy_override
class StubSafety
  attr_reader :overrides, :current_user

  def initialize(current_user: 'kairos_daemon')
    @overrides = {}
    @current_user = current_user
  end

  def push_policy_override(cap, &block)
    raise "override already active for #{cap}" if @overrides.key?(cap)
    @overrides[cap] = block
  end

  def pop_policy_override(cap)
    @overrides.delete(cap)
  end

  def can_modify_l0?
    check_capability(:can_modify_l0)
  end

  def can_modify_l1?
    check_capability(:can_modify_l1)
  end

  private

  def check_capability(cap)
    if @overrides.key?(cap)
      @overrides[cap].call(@current_user)
    else
      false  # daemon default-deny
    end
  end
end

# ---------------------------------------------------------------------------

section 'ElevationToken: identity'

assert('T23: token.matches? with self returns true') do
  t = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'human:masa')
  t.matches?(t)
end

assert('T23b: token.matches? with clone returns false') do
  t = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'human:masa')
  t2 = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'human:masa')
  !t.matches?(t2)
end

assert('T23c: token.matches? with nil returns false') do
  t = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'human:masa')
  !t.matches?(nil)
end

assert('T23d: token has expected attributes') do
  t = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'human:masa')
  t.proposal_id == 'p1' && t.scope == :l1 && t.granted_by == 'human:masa' &&
    t.granted_at.is_a?(String)
end

assert('T23e: token.to_h returns Hash') do
  t = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'test')
  h = t.to_h
  h[:proposal_id] == 'p1' && h[:scope] == :l1
end

section 'ExecutionContext: thread-local'

assert('T23f: starts nil') do
  EC.current_elevation_token = nil
  EC.current_elevation_token.nil?
end

assert('T23g: set and get') do
  t = ET.new(proposal_id: 'p1', scope: :l0, granted_by: 'test')
  EC.current_elevation_token = t
  result = EC.current_elevation_token.equal?(t)
  EC.current_elevation_token = nil
  result
end

assert('T23h: isolated across threads') do
  EC.current_elevation_token = nil
  t1 = ET.new(proposal_id: 'p1', scope: :l0, granted_by: 'test')
  EC.current_elevation_token = t1

  other_thread_saw_nil = false
  Thread.new do
    other_thread_saw_nil = EC.current_elevation_token.nil?
  end.join

  EC.current_elevation_token = nil
  other_thread_saw_nil
end

section 'PolicyElevation: basic elevation'

assert('T24: non-elevated daemon cannot modify L1') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  !safety.can_modify_l1?
end

assert('T24b: within with_elevation, can_modify_l1? is true') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  result = nil
  PE.with_elevation(safety, scope: :l1, proposal_id: 'p1', granted_by: 'human:masa') do
    result = safety.can_modify_l1?
  end
  result == true
end

assert('T25: after with_elevation, can_modify_l1? is false again') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  PE.with_elevation(safety, scope: :l1, proposal_id: 'p1', granted_by: 'human:masa') do
    # inside
  end
  !safety.can_modify_l1? && EC.current_elevation_token.nil?
end

assert('T26: exception in block still revokes elevation') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  begin
    PE.with_elevation(safety, scope: :l1, proposal_id: 'p1', granted_by: 'test') do
      raise 'boom'
    end
  rescue RuntimeError
    # expected
  end
  !safety.can_modify_l1? && EC.current_elevation_token.nil? && safety.overrides.empty?
end

assert('T27: nested elevation raises ElevationNestError') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  nested_error_caught = false
  PE.with_elevation(safety, scope: :l1, proposal_id: 'p1', granted_by: 'test') do
    begin
      PE.with_elevation(safety, scope: :l0, proposal_id: 'p2', granted_by: 'test') do
        # should not reach
      end
    rescue PE::ElevationNestError
      nested_error_caught = true
    end
  end
  # Outer elevation should have cleaned up normally
  nested_error_caught && !safety.can_modify_l1? && EC.current_elevation_token.nil?
end

assert('T27b: ElevationNestError does NOT leak push (R2 residual fix)') do
  EC.current_elevation_token = nil
  safety = StubSafety.new

  # Simulate: someone tries to nest with DIFFERENT scope
  # The nest check fires BEFORE push, so no leak
  begin
    # First, set up an artificial "active" token
    t_outer = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'test')
    EC.current_elevation_token = t_outer

    PE.with_elevation(safety, scope: :l0, proposal_id: 'p2', granted_by: 'test') do
      # should not reach
    end
    false
  rescue PE::ElevationNestError
    # l0 override should NOT be installed (push never happened)
    !safety.overrides.key?(:can_modify_l0)
  ensure
    EC.current_elevation_token = nil
  end
end

section 'PolicyElevation: scope validation'

assert('T28: scope :l2 raises ArgumentError (no elevation needed)') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  begin
    PE.with_elevation(safety, scope: :l2, proposal_id: 'p1', granted_by: 'test') do
    end
    false
  rescue ArgumentError => e
    e.message.include?('does not require elevation')
  end
end

assert('T29: L0 elevation works') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  result = nil
  PE.with_elevation(safety, scope: :l0, proposal_id: 'p1', granted_by: 'human:masa') do
    result = safety.can_modify_l0?
  end
  result == true && !safety.can_modify_l0?
end

section 'PolicyElevation: security — forgery resistance'

assert('S5: external Thread.current setting has no effect without push') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  # Attacker sets a fake token on the thread
  fake = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'attacker')
  EC.current_elevation_token = fake
  # Without push_policy_override, the override is not in safety
  !safety.can_modify_l1?
ensure
  EC.current_elevation_token = nil
end

assert('S5b: different token in ExecutionContext fails matches?') do
  EC.current_elevation_token = nil
  safety = StubSafety.new
  result = nil
  PE.with_elevation(safety, scope: :l1, proposal_id: 'p1', granted_by: 'human:masa') do |token|
    # Replace context with a forgery
    forgery = ET.new(proposal_id: 'p1', scope: :l1, granted_by: 'human:masa')
    EC.current_elevation_token = forgery
    result = safety.can_modify_l1?
  end
  result == false
ensure
  EC.current_elevation_token = nil
end

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

puts
puts '=' * 60
puts "Results: #{$pass} passed, #{$fail} failed"
puts '=' * 60

unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end

exit($fail.zero? ? 0 : 1)
