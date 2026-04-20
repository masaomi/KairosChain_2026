#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Phase 2 P2.2: DaemonPolicy + InvocationContext daemon_mode.
# Usage: ruby test_daemon_policy.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'tmpdir'
require 'fileutils'

require 'kairos_mcp/safety'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/daemon/daemon_policy'
require 'kairos_mcp/daemon'

$pass = 0
$fail = 0

def assert(description, &block)
  result = block.call
  if result
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

# Clean slate between test groups; policy registry is class-global.
def with_clean_policies
  KairosMcp::Safety.clear_policies!
  yield
ensure
  KairosMcp::Safety.clear_policies!
end

# =========================================================================
# 1. DaemonPolicy — denies privileged operations for the daemon user
# =========================================================================

section 'DaemonPolicy — deny privileged operations for daemon user'

assert('apply! registers can_modify_l0 policy') do
  with_clean_policies do
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)
    KairosMcp::Safety.policy_for(:can_modify_l0).is_a?(Proc)
  end
end

assert('apply! registers can_modify_l1 policy') do
  with_clean_policies do
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)
    KairosMcp::Safety.policy_for(:can_modify_l1).is_a?(Proc)
  end
end

assert('apply! registers can_modify_l2 policy') do
  with_clean_policies do
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)
    KairosMcp::Safety.policy_for(:can_modify_l2).is_a?(Proc)
  end
end

assert('apply! registers can_manage_tokens policy') do
  with_clean_policies do
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)
    KairosMcp::Safety.policy_for(:can_manage_tokens).is_a?(Proc)
  end
end

assert('apply! registers can_manage_grants policy') do
  with_clean_policies do
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)
    KairosMcp::Safety.policy_for(:can_manage_grants).is_a?(Proc)
  end
end

assert('daemon user DENIED can_modify_l0?') do
  with_clean_policies do
    safety = KairosMcp::Safety.new
    KairosMcp::Daemon::DaemonPolicy.apply!(safety)
    safety.can_modify_l0? == false
  end
end

assert('daemon user DENIED can_modify_l1?') do
  with_clean_policies do
    safety = KairosMcp::Safety.new
    KairosMcp::Daemon::DaemonPolicy.apply!(safety)
    safety.can_modify_l1? == false
  end
end

assert('daemon user DENIED can_manage_tokens?') do
  with_clean_policies do
    safety = KairosMcp::Safety.new
    KairosMcp::Daemon::DaemonPolicy.apply!(safety)
    safety.can_manage_tokens? == false
  end
end

assert('daemon user DENIED can_manage_grants?') do
  with_clean_policies do
    safety = KairosMcp::Safety.new
    KairosMcp::Daemon::DaemonPolicy.apply!(safety)
    safety.can_manage_grants? == false
  end
end

# =========================================================================
# 2. DaemonPolicy — L2 stays permitted
# =========================================================================

section 'DaemonPolicy — L2 stays permitted'

assert('daemon user ALLOWED can_modify_l2?') do
  with_clean_policies do
    safety = KairosMcp::Safety.new
    KairosMcp::Daemon::DaemonPolicy.apply!(safety)
    safety.can_modify_l2? == true
  end
end

# =========================================================================
# 3. DaemonPolicy — non-daemon users (e.g., owner) are unaffected
# =========================================================================

section 'DaemonPolicy — non-daemon callers unaffected'

assert('owner user ALLOWED can_modify_l0? (different Safety instance)') do
  with_clean_policies do
    # Policies registered once by the daemon apply globally to any Safety
    # instance, but they key on user[:role] == 'daemon'.  Owners pass.
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)

    owner_safety = KairosMcp::Safety.new
    owner_safety.set_user(user: 'alice', role: 'owner')
    owner_safety.can_modify_l0? == true
  end
end

assert('owner user ALLOWED can_manage_tokens?') do
  with_clean_policies do
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)

    owner_safety = KairosMcp::Safety.new
    owner_safety.set_user(user: 'alice', role: 'owner')
    owner_safety.can_manage_tokens? == true
  end
end

assert('nil current_user ALLOWED (STDIO fallback path)') do
  with_clean_policies do
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)

    fresh = KairosMcp::Safety.new
    # Safety#can_modify_l0? returns true when @current_user is nil, bypassing
    # the policy.  This is the expected STDIO behaviour.
    fresh.can_modify_l0? == true
  end
end

# =========================================================================
# 4. DaemonPolicy — daemon_user? helper
# =========================================================================

section 'DaemonPolicy — daemon_user? helper'

assert('daemon_user? true for { role: "daemon" } (symbol key)') do
  KairosMcp::Daemon::DaemonPolicy.daemon_user?(role: 'daemon') == true
end

assert('daemon_user? true for { "role" => "daemon" } (string key)') do
  KairosMcp::Daemon::DaemonPolicy.daemon_user?({ 'role' => 'daemon' }) == true
end

assert('daemon_user? false for { role: "owner" }') do
  KairosMcp::Daemon::DaemonPolicy.daemon_user?(role: 'owner') == false
end

assert('daemon_user? false for nil / non-hash') do
  KairosMcp::Daemon::DaemonPolicy.daemon_user?(nil) == false &&
    KairosMcp::Daemon::DaemonPolicy.daemon_user?('daemon') == false
end

# =========================================================================
# 5. DaemonPolicy.remove! unwinds policies
# =========================================================================

section 'DaemonPolicy.remove!'

assert('remove! unregisters all policies DaemonPolicy installed') do
  with_clean_policies do
    KairosMcp::Daemon::DaemonPolicy.apply!(KairosMcp::Safety.new)
    KairosMcp::Daemon::DaemonPolicy.remove!

    (KairosMcp::Daemon::DaemonPolicy::DENIED_CAPABILITIES +
      KairosMcp::Daemon::DaemonPolicy::ALLOWED_CAPABILITIES).all? do |cap|
      KairosMcp::Safety.policy_for(cap).nil?
    end
  end
end

# =========================================================================
# 6. InvocationContext — mode / idem_key fields
# =========================================================================

section 'InvocationContext — mode / idem_key fields'

assert('mode defaults to nil for backward compatibility') do
  ctx = KairosMcp::InvocationContext.new
  ctx.mode.nil? && ctx.idem_key.nil?
end

assert('mode accepts :daemon symbol') do
  ctx = KairosMcp::InvocationContext.new(mode: :daemon)
  ctx.mode == :daemon
end

assert('mode coerces string to symbol on construction') do
  ctx = KairosMcp::InvocationContext.new(mode: 'daemon')
  ctx.mode == :daemon
end

assert('idem_key preserved as-is') do
  ctx = KairosMcp::InvocationContext.new(idem_key: 'req-42')
  ctx.idem_key == 'req-42'
end

# =========================================================================
# 7. InvocationContext — mode / idem_key round-trip via to_h / from_h
# =========================================================================

section 'InvocationContext — to_h/from_h round-trip'

assert('to_h includes mode as string') do
  ctx = KairosMcp::InvocationContext.new(mode: :daemon, idem_key: 'k1')
  h = ctx.to_h
  h['mode'] == 'daemon' && h['idem_key'] == 'k1'
end

assert('to_h emits nil mode when unset') do
  ctx = KairosMcp::InvocationContext.new
  h = ctx.to_h
  h.key?('mode') && h['mode'].nil? && h.key?('idem_key') && h['idem_key'].nil?
end

assert('from_h restores mode as symbol and idem_key as string') do
  original = KairosMcp::InvocationContext.new(mode: :daemon, idem_key: 'abc')
  restored = KairosMcp::InvocationContext.from_h(original.to_h)
  restored.mode == :daemon && restored.idem_key == 'abc'
end

assert('to_json / from_json preserves mode and idem_key') do
  ctx = KairosMcp::InvocationContext.new(
    mode: :daemon, idem_key: 'req-1', whitelist: ['knowledge_*']
  )
  json = ctx.to_json
  restored = KairosMcp::InvocationContext.from_json(json)
  restored.mode == :daemon &&
    restored.idem_key == 'req-1' &&
    restored.allowed?('knowledge_list')
end

assert('backward-compatible from_h (no mode / idem_key keys)') do
  restored = KairosMcp::InvocationContext.from_h(
    'whitelist' => ['*'], 'mandate_id' => 'mnd_01'
  )
  restored.mode.nil? && restored.idem_key.nil? && restored.mandate_id == 'mnd_01'
end

# =========================================================================
# 8. InvocationContext — mode / idem_key propagate through child / derive
# =========================================================================

section 'InvocationContext — propagation through child / derive'

assert('child inherits mode and idem_key') do
  parent = KairosMcp::InvocationContext.new(mode: :daemon, idem_key: 'k1')
  c = parent.child(caller_tool: 'x')
  c.mode == :daemon && c.idem_key == 'k1'
end

assert('derive preserves mode and idem_key') do
  parent = KairosMcp::InvocationContext.new(mode: :daemon, idem_key: 'k1',
                                            blacklist: ['agent_*'])
  d = parent.derive(blacklist_add: ['skills_evolve'])
  d.mode == :daemon && d.idem_key == 'k1'
end

assert('derive_for_phase preserves mode and idem_key') do
  parent = KairosMcp::InvocationContext.new(mode: :daemon, idem_key: 'k1')
  d = parent.derive_for_phase(whitelist: ['knowledge_*'])
  d.mode == :daemon && d.idem_key == 'k1'
end

# =========================================================================
# 9. Daemon#build_safety integration
# =========================================================================

section 'Daemon#build_safety produces restricted Safety'

assert('Daemon#build_safety returns a Safety with DaemonPolicy applied') do
  with_clean_policies do
    Dir.mktmpdir do |tmp|
      d = KairosMcp::Daemon.new(root: tmp)
      safety = d.send(:build_safety)
      safety.is_a?(KairosMcp::Safety) &&
        safety.can_modify_l0? == false &&
        safety.can_modify_l1? == false &&
        safety.can_modify_l2? == true &&
        safety.can_manage_tokens? == false &&
        safety.can_manage_grants? == false
    end
  end
end

assert('Daemon#build_safety stamps the daemon user on the Safety instance') do
  with_clean_policies do
    Dir.mktmpdir do |tmp|
      d = KairosMcp::Daemon.new(root: tmp)
      safety = d.send(:build_safety)
      u = safety.current_user
      u.is_a?(Hash) && (u[:role] || u['role']).to_s == 'daemon'
    end
  end
end

# =========================================================================
# Summary
# =========================================================================

KairosMcp::Safety.clear_policies!

puts "\n#{'=' * 60}"
puts "Results: #{$pass} passed, #{$fail} failed"
puts '=' * 60
exit($fail.zero? ? 0 : 1)
