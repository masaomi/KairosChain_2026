#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Interruption resilience Slice A-2 — detached agent step worker (INV-A1).
#
# Spawned by StepDelegation#spawn_worker after agent_step was called with
# execution: "delegated". This worker is deliberately thin: it bootstraps a
# ToolRegistry (the same construction the MCP server uses) and re-enters the
# SAME gated agent_step path with the recorded arguments (the delegation-start
# anchor is already injected into those arguments). Every correctness property
# — per-session serialization, anchored at-most-once, side-effect intent
# bracket — is enforced by the AdvanceGate inside that call (Slice A-1), not by
# this script. If this worker dies, the driver re-issues the recorded call
# safely; if it double-runs, the gate serializes and replays.
#
# argv: <session_id> <session_dir>
# env:  KAIROS_PROJECT_ROOT (chdir target)
#       KAIROS_SERVER_LIB   (lib dir to load kairos_mcp from)
#       KAIROS_DATA_DIR     (the server's effective data dir; makes the
#                            worker resolve the SAME .kairos)
#
# Exit codes: 0 success; 1 exception; 125 setsid failed; 130 signal.
#
# NB: bootstrap failures (LoadError/ScriptError from require) are caught too,
# so the driver always sees a result rather than a silently hung handle.

require 'json'
require 'time'
require 'fileutils'

session_id  = ARGV[0] or abort 'usage: agent_step_worker.rb <session_id> <session_dir>'
session_dir = ARGV[1] or abort 'usage: agent_step_worker.rb <session_id> <session_dir>'

# Read the handle identity from the raw file first, so even a bootstrap
# failure can tag its error result with the delegation it belongs to.
def read_handle_identity(session_dir)
  raw = JSON.parse(File.read(File.join(session_dir, 'delegation.json')))
  { 'issue_anchor' => raw['issue_anchor'], 'action_key' => raw['action_key'],
    'step_token' => raw['step_token'] }
rescue StandardError
  {}
end

def write_raw_result(session_dir, identity, outcome)
  payload = identity.merge('outcome' => outcome)
  tmp = File.join(session_dir, "delegation_result.json.tmp.#{Process.pid}")
  File.write(tmp, JSON.generate(payload))
  File.rename(tmp, File.join(session_dir, 'delegation_result.json'))
rescue StandardError
  # nothing more we can do
end

boot_identity = read_handle_identity(session_dir)

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
begin
  require 'agent/step_delegation'
rescue ScriptError, StandardError => e
  # The delegation lib is co-located with this script; if even it cannot load
  # we tag a raw result with the handle identity so status can surface it as
  # 'ready' (an error outcome) rather than the driver waiting out the grace.
  write_raw_result(session_dir, boot_identity,
                   { 'status' => 'error',
                     'error' => "worker bootstrap failed: #{e.class}: #{e.message}" })
  exit 1
end

delegation = KairosMcp::SkillSets::Agent::StepDelegation.new(session_dir)
my_token = boot_identity['step_token']

shutdown = { requested: false }
%w[TERM INT HUP].each do |sig|
  Signal.trap(sig) { shutdown[:requested] = true }
end

begin
  Process.setsid
rescue Errno::EPERM
  # Already a session leader — acceptable; continue.
rescue StandardError => e
  delegation.write_result({ 'status' => 'error',
                            'error' => "worker setsid failed: #{e.message}" },
                          identity: boot_identity)
  exit 125
end

heartbeat_thread = Thread.new do
  loop do
    begin
      delegation.touch_heartbeat(my_token)
    rescue StandardError
      # A transient touch failure must not kill the heartbeat thread and
      # make a live worker look crashed; retry on the next tick.
    end
    sleep KairosMcp::SkillSets::Agent::StepDelegation::HEARTBEAT_INTERVAL_SECONDS
  end
end

# Self-timeout watchdog: a hung gated call would otherwise hold the advance
# lock forever. Exiting the process releases its flock; the driver then sees
# 'crashed' and re-issues safely. We deliberately write NO result here so the
# collector takes the crash path — if the gated advance had already committed,
# crashed_response recovers its outcome from the gate log; an error result
# would instead mask that committed advance.
timeout_s = KairosMcp::SkillSets::Agent::StepDelegation.worker_self_timeout_seconds
watchdog = Thread.new do
  sleep timeout_s
  exit!(124)
end

begin
  Dir.chdir(ENV['KAIROS_PROJECT_ROOT']) if ENV['KAIROS_PROJECT_ROOT'] &&
                                           Dir.exist?(ENV['KAIROS_PROJECT_ROOT'])
  $LOAD_PATH.unshift(ENV['KAIROS_SERVER_LIB']) if ENV['KAIROS_SERVER_LIB']
  # KAIROS_DATA_DIR was set in the worker env by spawn_worker so ToolRegistry
  # / Session resolve the server's effective .kairos even under --data-dir.
  require 'kairos_mcp/tool_registry'

  pending = delegation.pending
  raise "no pending delegation in #{session_dir}" unless pending

  # Supersession guard: run ONLY if the live handle is still ours. If a fresh
  # open_handle replaced it while we were starting up (e.g. we were declared
  # 'crashed' on a stale heartbeat and the driver re-delegated), or we could
  # not read our own identity at boot (my_token nil), do NOT run: the new
  # worker owns this delegation, and the gate would replay/serialize our stale
  # call anyway. Exiting leaves the current handle to its rightful worker.
  if my_token.nil? || pending['step_token'] != my_token
    exit 0
  end

  # Past the guard, boot_identity is non-empty and is our own handle identity
  # (also driving the per-token heartbeat); write_result tags with it.
  identity = boot_identity

  args = (pending['arguments'] || {}).merge('session_id' => session_id)
  args.delete('execution') # never recurse into another delegation

  exit 130 if shutdown[:requested]

  registry = KairosMcp::ToolRegistry.new
  raw = registry.call_tool('agent_step', args)

  # Normalize the MCP content shape to the response hash the inline call
  # would have returned.
  text = if raw.is_a?(Array) && raw.first.is_a?(Hash)
           raw.first[:text] || raw.first['text']
         end
  response = begin
    text ? JSON.parse(text) : { 'status' => 'error', 'error' => 'unrecognized tool result shape' }
  rescue JSON::ParserError
    { 'status' => 'error', 'error' => 'unparseable tool result', 'raw' => text.to_s[0, 500] }
  end

  # Write the result (tagged with our OWN startup identity) and leave the
  # pending handle in place: teardown is the collector's job (agent_wait#collect
  # clears result+handle atomically under delegation.lock), so the worker never
  # races a concurrently-opened fresh delegation by clearing state it may no
  # longer own or by mislabeling its result as a newer delegation's.
  delegation.write_result(response, identity: identity)
  exit 0
rescue SystemExit, SignalException
  # A deliberate exit (including our own `exit 0`) or a signal is not a
  # failure to report — let it propagate.
  raise
rescue Exception => e # rubocop:disable Lint/RescueException
  # Catch Exception, not just StandardError: LoadError/ScriptError from the
  # bootstrap require are exactly the failure class the driver must see as a
  # result rather than a silently hung handle. Leave teardown to the collector.
  # Tag with our OWN startup identity (boot_identity is always our handle;
  # the in-block `identity` local may be unassigned if we failed early, and
  # a re-read of pending could belong to a superseding delegation).
  begin
    delegation.write_result({ 'status' => 'error', 'error' => "worker: #{e.class}: #{e.message}" },
                            identity: (boot_identity.empty? ? nil : boot_identity))
  rescue StandardError
    # best effort
  end
  exit 1
ensure
  watchdog&.kill
  heartbeat_thread&.kill
end
