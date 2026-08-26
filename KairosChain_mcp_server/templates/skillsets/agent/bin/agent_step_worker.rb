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
  # StepDelegation itself failed to load, so write the exit record by hand
  # (field defect D4: every exit this worker can see coming leaves one).
  begin
    File.write(File.join(session_dir, 'worker_exit.json'),
               JSON.generate({ 'timestamp' => Time.now.utc.iso8601, 'pid' => Process.pid,
                               'exit_class' => 'bootstrap_failure',
                               'step_token' => boot_identity['step_token'],
                               'error' => "#{e.class}: #{e.message}" }))
  rescue StandardError
    # best effort
  end
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
  delegation.write_worker_exit(boot_identity, 'setsid_failure', 'error' => e.message)
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

# Watchdog (field defect D4, 2026-08-26): two bounds instead of one wall
# clock. A hung gated call must not hold the advance flock forever — but the
# old fixed 1500 s assumed only a hung call could reach it, and killed
# healthy LLM-bound cycles at minute 25 with nothing written. Now the worker
# dies when the session dir has gone SILENT for the stall bound (heartbeats
# and locks excluded — the heartbeat thread outlives a hung main thread), or
# when the hard cap elapses, whichever comes first. Either firing writes a
# worker_exit record BEFORE exit!(124). That record is not a result, so the
# collector still takes the crash path and a committed advance is still
# recovered from the gate log, never masked.
worker_started = Time.now
stall_s = KairosMcp::SkillSets::Agent::StepDelegation.worker_stall_seconds
cap_s   = KairosMcp::SkillSets::Agent::StepDelegation.worker_hard_cap_seconds
watchdog = Thread.new do
  loop do
    sleep 30
    elapsed = (Time.now - worker_started).round
    silent  = (Time.now - delegation.last_activity_time).round
    if elapsed > cap_s
      delegation.write_worker_exit(boot_identity, 'self_timeout_hard_cap',
                                   'elapsed_seconds' => elapsed,
                                   'silent_seconds' => silent)
      exit!(124)
    elsif silent > stall_s
      delegation.write_worker_exit(boot_identity, 'self_timeout_stalled',
                                   'elapsed_seconds' => elapsed,
                                   'silent_seconds' => silent)
      exit!(124)
    end
  end
end

begin
  Dir.chdir(ENV['KAIROS_PROJECT_ROOT']) if ENV['KAIROS_PROJECT_ROOT'] &&
                                           Dir.exist?(ENV['KAIROS_PROJECT_ROOT'])
  $LOAD_PATH.unshift(ENV['KAIROS_SERVER_LIB']) if ENV['KAIROS_SERVER_LIB']
  # KAIROS_DATA_DIR was set in the worker env by spawn_worker so ToolRegistry
  # / Session resolve the server's effective .kairos even under --data-dir.
  require 'kairos_mcp/tool_registry'
  # Host-profile add-on SkillSets (codex_projection, opencode_projection) guard
  # their lib entry point with `raise unless defined?(PluginProjector::HostProfile)`.
  # The server satisfies that guard as a side effect of protocol.rb; this worker
  # bootstraps only tool_registry, so it must load the core explicitly or
  # Skillset#load! trips the guard and the whole registry bootstrap dies.
  require 'kairos_mcp/plugin_projector'

  pending = delegation.pending
  raise "no pending delegation in #{session_dir}" unless pending

  # Supersession guard: run ONLY if the live handle is still ours. If a fresh
  # open_handle replaced it while we were starting up (e.g. we were declared
  # 'crashed' on a stale heartbeat and the driver re-delegated), or we could
  # not read our own identity at boot (my_token nil), do NOT run: the new
  # worker owns this delegation, and the gate would replay/serialize our stale
  # call anyway. Exiting leaves the current handle to its rightful worker.
  if my_token.nil? || pending['step_token'] != my_token
    delegation.write_worker_exit(boot_identity, 'superseded',
                                 'current_token' => pending['step_token'])
    exit 0
  end

  # Past the guard, boot_identity is non-empty and is our own handle identity
  # (also driving the per-token heartbeat); write_result tags with it.
  identity = boot_identity

  args = (pending['arguments'] || {}).merge('session_id' => session_id)
  args.delete('execution') # never recurse into another delegation

  if shutdown[:requested]
    delegation.write_worker_exit(boot_identity, 'trapped_signal')
    exit 130
  end

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
  delegation.write_worker_exit(identity, 'normal')
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
  begin
    delegation.write_worker_exit(boot_identity, 'uncaught', 'error' => "#{e.class}: #{e.message}")
  rescue StandardError
    # best effort
  end
  exit 1
ensure
  watchdog&.kill
  heartbeat_thread&.kill
end
