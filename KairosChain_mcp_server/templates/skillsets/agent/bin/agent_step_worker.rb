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

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'agent/step_delegation'

delegation = KairosMcp::SkillSets::Agent::StepDelegation.new(session_dir)

shutdown = { requested: false }
%w[TERM INT HUP].each do |sig|
  Signal.trap(sig) { shutdown[:requested] = true }
end

begin
  Process.setsid
rescue Errno::EPERM
  # Already a session leader — acceptable; continue.
rescue StandardError => e
  delegation.write_result('status' => 'error',
                          'error' => "worker setsid failed: #{e.message}")
  exit 125
end

heartbeat_thread = Thread.new do
  loop do
    begin
      delegation.touch_heartbeat
    rescue StandardError
      # A transient touch failure must not kill the heartbeat thread and
      # make a live worker look crashed; retry on the next tick.
    end
    sleep KairosMcp::SkillSets::Agent::StepDelegation::HEARTBEAT_INTERVAL_SECONDS
  end
end

# Self-timeout watchdog: a hung gated call would otherwise hold the advance
# lock forever. Exiting the process releases its flock; the driver then sees
# 'crashed' and re-issues safely (the gate replays a committed advance or
# re-runs an uncommitted one exactly once).
timeout_s = KairosMcp::SkillSets::Agent::StepDelegation.worker_self_timeout_seconds
watchdog = Thread.new do
  sleep timeout_s
  begin
    delegation.write_result('status' => 'error',
                            'error' => "worker self-timeout after #{timeout_s}s")
  rescue StandardError
    # best effort
  end
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

  delegation.write_result(response)
  delegation.clear_pending
  exit 0
rescue SystemExit, SignalException
  # A deliberate exit (including our own `exit 0`) or a signal is not a
  # failure to report — let it propagate.
  raise
rescue Exception => e # rubocop:disable Lint/RescueException
  # Catch Exception, not just StandardError: LoadError/ScriptError from the
  # bootstrap require are exactly the failure class the driver must see as a
  # result rather than a silently hung handle.
  begin
    delegation.write_result('status' => 'error',
                            'error' => "worker: #{e.class}: #{e.message}")
    delegation.clear_pending
  rescue StandardError
    # best effort
  end
  exit 1
ensure
  watchdog&.kill
  heartbeat_thread&.kill
end
