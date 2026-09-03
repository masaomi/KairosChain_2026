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
# Exit codes: 0 success (also: superseded); 1 exception / bootstrap failure;
#             124 watchdog (stall bound or hard cap); 125 setsid failed;
#             130 signal received BEFORE the gated call. A signal received
#             DURING the call is recorded but the call is left to finish (D6).
#
# Every exit path above leaves a worker_exit.json record (field defect D4).
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

# Signals are trapped, not honoured mid-flight: a TERM during a multi-minute
# gated call must not turn a sound advance into a crash-path recovery. The
# trap only records; who reads the record is decided below (field defect D6).
shutdown = { requested: false, signals: [] }
%w[TERM INT HUP].each do |sig|
  Signal.trap(sig) do
    shutdown[:requested] = true
    shutdown[:signals] << sig
  end
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
#
# Impl review R1 (2026-09-02, I5): a watchdog record is a FINAL record, so it
# carries the signals that landed during the call — otherwise the operator's
# TERM vanished from the crash report the moment the watchdog superseded the
# D6 interim record.
#
# Impl review R2 (2026-09-03, J1): clearing the phase only NARROWED the window
# in which the recorder, already past its phase check, could rename an interim
# record over the final one. Every final write now first stops the recorder
# (kill, then join — join is safe after kill) so the two writers are
# serialised, not raced. A recorder killed mid-write may leave a
# worker_exit.json.tmp.* file behind; readers ignore it (they open the
# renamed file only) and so does the activity clock (last_activity_time).
call_phase = { active: false }
signal_recorder = nil # assigned below; the watchdog closes over it
stop_recorder = lambda do
  signal_recorder&.kill
  signal_recorder&.join
end
worker_started = Time.now
stall_s = KairosMcp::SkillSets::Agent::StepDelegation.worker_stall_seconds
cap_s   = KairosMcp::SkillSets::Agent::StepDelegation.worker_hard_cap_seconds
tick_s  = KairosMcp::SkillSets::Agent::StepDelegation.worker_watchdog_tick_seconds
watchdog = Thread.new do
  loop do
    sleep tick_s
    elapsed = (Time.now - worker_started).round
    silent  = (Time.now - delegation.last_activity_time).round
    exit_class = if elapsed > cap_s
                   'self_timeout_hard_cap'
                 elsif silent > stall_s
                   'self_timeout_stalled'
                 end
    next unless exit_class

    call_phase[:active] = false
    stop_recorder.call
    detail = { 'elapsed_seconds' => elapsed, 'silent_seconds' => silent }
    detail['signals_during_call'] = shutdown[:signals].dup unless shutdown[:signals].empty?
    delegation.write_worker_exit(boot_identity, exit_class, detail)
    exit!(124)
  end
end

# Field defect D6 (2026-08-27): the shutdown flag used to be read exactly once,
# just before the gated call, so a TERM/INT/HUP that landed DURING the call —
# which can run for minutes — was trapped, set a flag nobody read again, and
# left no record; the worker then finished and reported 'normal'. The usual
# shutdown sequence is TERM, then KILL after a grace period, so that worker
# vanished with 'no_record'. The call is still left to finish (see the trap
# comment above), but the signal is now recorded the moment it lands: an
# interim 'trapped_signal' exit record with phase 'during_gated_call'. If the
# worker survives to its own exit, the final record supersedes it and carries
# the signal list; if it is killed first, the interim record is what the
# collector's crash report finds. Recording from a thread rather than inside
# the trap keeps file I/O out of trap context.
#
# Impl review R1 (I2, I3): `seen` advances ONLY while the phase is active. A
# signal that lands before the call starts (e.g. inside ToolRegistry.new) is
# not consumed here — it is either caught by the main thread's re-check below
# or recorded on the recorder's first active tick. The phase is cleared by
# the main thread around the call (ensure) and before each final write; R2 J1
# then stops this thread (stop_recorder) before every final record, which is
# what actually prevents it overwriting an `uncaught` / watchdog / normal one.
signal_recorder = Thread.new do
  seen = 0
  loop do
    sleep 0.25
    next unless call_phase[:active]
    sigs = shutdown[:signals]
    next unless sigs.size > seen
    seen = sigs.size
    delegation.write_worker_exit(boot_identity, 'trapped_signal',
                                 'phase' => 'during_gated_call',
                                 'signals' => sigs.dup,
                                 'note' => 'gated call left to finish; the final exit record supersedes this one')
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

  exit_before_call = lambda do
    delegation.write_worker_exit(boot_identity, 'trapped_signal',
                                 'phase' => 'before_gated_call',
                                 'signals' => shutdown[:signals].dup)
    exit 130
  end
  exit_before_call.call if shutdown[:requested]

  registry = KairosMcp::ToolRegistry.new
  # Re-check (I3): registry bootstrap takes long enough for a signal to land
  # in it, and the recorder deliberately does not consume signals while the
  # phase is inactive — so this check is what turns that signal into a record.
  exit_before_call.call if shutdown[:requested]

  call_phase[:active] = true
  begin
    raw = registry.call_tool('agent_step', args)
  ensure
    call_phase[:active] = false # the exception path clears it too (I2)
  end

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
  call_phase[:active] = false
  stop_recorder.call
  signal_detail = shutdown[:signals].empty? ? {} : { 'signals_during_call' => shutdown[:signals].dup }
  delegation.write_worker_exit(identity, 'normal', signal_detail)
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
    call_phase[:active] = false
    stop_recorder.call
    detail = { 'error' => "#{e.class}: #{e.message}" }
    detail['signals_during_call'] = shutdown[:signals].dup unless shutdown[:signals].empty?
    delegation.write_worker_exit(boot_identity, 'uncaught', detail)
  rescue StandardError
    # best effort
  end
  exit 1
ensure
  watchdog&.kill
  signal_recorder&.kill
  heartbeat_thread&.kill
end
