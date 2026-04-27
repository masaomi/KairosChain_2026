#!/usr/bin/env ruby
# frozen_string_literal: true
#
# multi_llm_review v0.3.0 — detached subprocess worker (Phase 11.5).
#
# Spawned by WorkerSpawner.spawn(token:, dir:) after Phase 1
# (multi_llm_review tool w/ orchestrator_strategy: "delegate" + parallel:true)
# writes request.json / state.json into .kairos/multi_llm_review/pending/<token>/.
#
# This worker:
#   1. Requires all needed libs BEFORE setsid (v0.3.2 §2.1 / C2 fix), so the
#      setsid-failure rescue can safely use PendingState APIs.
#   2. Installs flag-only signal traps (v0.3.2 C1b) before any blocking work.
#   3. Calls Process.setsid (hard-fails on error → writes crashed marker).
#   4. Writes worker.pid (atomic JSON, includes pgid + ruby_version).
#   5. Runs four threads:
#        - pulse thread (maintains worker.tick based on MainState)
#        - heartbeat thread (touches worker.heartbeat when tick is fresh)
#        - log rotator (moves worker.log → .log.1 at 1 MiB)
#        - self-timeout watchdog (exit!(124) past self_timeout_at)
#   6. Loads request + runs Dispatcher#dispatch via LlmClient::Headless.
#   7. Writes subprocess_results.json atomically then state.subprocess_status=done.
#
# Exit codes:
#     0  normal success
#     1  generic exception rescued
#   124  self-timeout watchdog fired
#   125  setsid failed
#   130  SIGTERM/INT/HUP received

require 'json'
require 'time'
require 'fileutils'

token = ARGV[0] or abort 'usage: dispatch_worker.rb <token>'

# ── 1. Load libs BEFORE setsid so rescue can use PS (C2) ──
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'multi_llm_review/pending_state'
require 'multi_llm_review/dispatcher'
require 'multi_llm_review/main_state'

$LOAD_PATH.unshift(File.expand_path('../../llm_client/lib', __dir__))
require 'llm_client/call_router'
require 'llm_client/headless'

MLR = KairosMcp::SkillSets::MultiLlmReview
LLM = KairosMcp::SkillSets::LlmClient
PS  = MLR::PendingState

# ── 2. Flag-only signal traps (C1b) ──
SHUTDOWN_FLAG = Struct.new(:req, :reason).new(false, nil)
FATAL_FLAG    = Struct.new(:set, :error).new(false, nil)

%w[TERM INT HUP].each do |sig|
  Signal.trap(sig) do
    # Async-signal-safe: only touch two already-allocated struct fields.
    SHUTDOWN_FLAG.req    = true
    SHUTDOWN_FLAG.reason = "signal:#{sig}"
  end
end
Signal.trap('PIPE', 'IGNORE')

# ── 3. setsid hard-fail (F-PGID + C2) ──
begin
  Process.setsid
rescue SystemCallError => e
  begin
    state = PS.load_state(token) || {}
    state['subprocess_status'] = 'crashed'
    state['crash_reason']      = "setsid_failed:#{e.class}"
    state['crashed_at']        = Time.now.iso8601
    PS.write_state(token, state)
  rescue StandardError
    # Cannot even write the marker; bail out with distinct exit code.
  end
  exit!(125)
end

abort "missing token dir: #{PS.token_dir(token)}" unless Dir.exist?(PS.token_dir(token))

# ── 4. Worker.pid (atomic JSON with pgid + ruby_version for Reaper F-RSUS) ──
PS.write_worker_pid(token, {
  'pid' => Process.pid,
  'pgid' => (Process.getpgid(Process.pid) rescue Process.pid),
  'spawned_at' => Time.now.iso8601,
  'ruby_version' => RUBY_VERSION
})

# First tick so heartbeat thread has a fresh timestamp to gate against.
FileUtils.touch(PS.worker_tick_path(token))

# ── 5. Threads ──
def self_timeout_at_from_state(token, request)
  state = PS.load_state(token)
  if state && state['self_timeout_at']
    Time.iso8601(state['self_timeout_at']) rescue nil
  end || begin
    base = (request && request['timeout_seconds']) || 300
    multiplier = 1.5
    floor = 60
    Time.now + base * multiplier + floor
  end
end

# Pulse thread: touches worker.tick IFF main is alive. v3.24.3 uses the
# per-thread (counter, in_flight, oldest_ts) snapshot from MainState and
# delegates the alive decision to MainState.compute_alive (pure function,
# unit-testable). Emits a diagnostic log line every ~5s so future incidents
# can be diagnosed from worker.log without filesystem mtime archaeology.
pulse_thread = Thread.new do
  begin
    last_counter = -1
    log_emit_at = 0
    threshold = 360  # max_call_t (300) + call_margin (60)
    loop do
      counter, in_flight, oldest_ts = MLR::MainState.snapshot
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      alive = MLR::MainState.compute_alive(
        counter, last_counter, in_flight, oldest_ts, now, threshold
      )
      FileUtils.touch(PS.worker_tick_path(token)) if alive

      if now - log_emit_at >= 5
        oldest_age = oldest_ts ? (now - oldest_ts).round(1) : nil
        warn "[pulse] counter=#{counter} in_flight=#{in_flight} " \
             "oldest_age=#{oldest_age || 'nil'}s alive=#{alive}"
        log_emit_at = now
      end

      last_counter = counter
      sleep 2
    end
  rescue StandardError => e
    FATAL_FLAG.set = true
    FATAL_FLAG.error = e
    warn "[pulse] #{e.class}: #{e.message}"
  end
end

# Heartbeat thread: touches worker.heartbeat gated on tick freshness (F-MASK).
heartbeat_thread = Thread.new do
  begin
    loop do
      last_tick = (File.mtime(PS.worker_tick_path(token)) rescue nil)
      if last_tick && (Time.now - last_tick) < 30
        FileUtils.touch(PS.worker_heartbeat_path(token))
      end
      sleep 2
    end
  rescue StandardError => e
    FATAL_FLAG.set = true
    FATAL_FLAG.error = e
    warn "[heartbeat] #{e.class}: #{e.message}"
  end
end

# Log rotator: 1s interval, reopens BOTH STDOUT and STDERR after rename.
log_rotator_thread = Thread.new do
  begin
    loop do
      sleep 1
      path = PS.worker_log_path(token)
      size = (File.size(path) rescue 0)
      next unless size > 1_048_576
      begin
        File.rename(path, "#{path}.1")
      rescue Errno::ENOENT
        next
      end
      begin
        new_f = File.open(path, 'a')
        STDOUT.reopen(new_f)
        STDERR.reopen(new_f)
      rescue StandardError => e
        warn "[log_rotator] reopen failed: #{e.class}: #{e.message}"
      end
    end
  rescue StandardError => e
    # Don't elevate to FATAL_FLAG — log rotation failure is not worker death.
    warn "[log_rotator] #{e.class}: #{e.message}"
  end
end

begin
  request = JSON.parse(File.read(PS.request_path(token)))
  raise 'empty request' unless request.is_a?(Hash) && !request.empty?
rescue StandardError => e
  # Missing/malformed request.json is fatal: worker cannot dispatch without
  # reviewers + prompts. Do not silently "complete" with no work.
  PS.transition_to_terminal!(token, 'crashed',
    reason: "bad_request:#{e.class}") rescue nil
  exit!(1)
end

# Self-timeout watchdog (G8).
self_timeout_at = self_timeout_at_from_state(token, request)
watchdog_thread = Thread.new do
  begin
    loop do
      sleep 5
      if Time.now > self_timeout_at
        MLR::PendingState.transition_to_terminal!(
          token, 'self_timed_out', reason: 'self_timeout_watchdog'
        ) rescue nil
        # v0.3.1 meta-review bug #3 fix (codex 5.4): kill the entire worker
        # process group so adapter-spawned descendants (CLI subprocesses etc.)
        # don't leak past self-timeout. We are the session leader (Process.setsid
        # succeeded at boot), so our pgid == our pid and -pgid signals the
        # whole group. Own signal arrives after the kill syscall returns.
        begin
          own_pgid = Process.getpgid(Process.pid)
          Process.kill('TERM', -own_pgid)
          sleep 0.5
          Process.kill('KILL', -own_pgid)
        rescue StandardError
          nil
        end
        exit!(124)
      end
    end
  rescue StandardError => e
    warn "[watchdog] #{e.class}: #{e.message}"
  end
end

# Helper polled at main-thread boundaries.
def check_shutdown!(token)
  if FATAL_FLAG.set
    MLR::PendingState.transition_to_terminal!(
      token, 'crashed', reason: "fatal:#{FATAL_FLAG.error.class}"
    )
    exit!(1)
  end
  return unless SHUTDOWN_FLAG.req
  MLR::PendingState.transition_to_terminal!(
    token, 'crashed', reason: SHUTDOWN_FLAG.reason
  )
  exit!(130)
end

# ── 6. Main work ──
begin
  check_shutdown!(token)

  invoker    = LLM::Headless.new
  dispatcher = MLR::Dispatcher.new(
    invoker,
    timeout_seconds: request['timeout_seconds'] || 300,
    max_concurrent: request['max_concurrent'] || 2
  )

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # NOTE: Dispatcher in v0.2.3 does NOT take tick_callback. The pulse thread
  # is the authoritative tick-source; we rely on MainState bracket inside
  # LlmClient::Headless#invoke_tool (future PR to add enter/exit_call! there)
  # and on between-reviewer progress (counter advances when result arrives).
  # v0.3.0 PR3 pushes MainState ticks via a per-result hook below.

  results = dispatcher.dispatch(
    (request['reviewers'] || []).map { |r| r.transform_keys(&:to_sym) },
    request['messages'] || [],
    request['system_prompt'] || '',
    context: nil,
    review_context: request['review_context'] || 'independent'
  )

  # v3.24.3: counter-only signal (no enter_call!/exit_call! pair). bump_counter!
  # advances pulse's progress signal without touching ts_by_thread.
  MLR::MainState.bump_counter!
  check_shutdown!(token)

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  payload = {
    'schema_version' => 2,
    'token' => token,
    'completed_at' => Time.now.iso8601,
    'elapsed_seconds' => elapsed.round(2),
    'results' => results.map do |r|
      {
        'role_label' => r[:role_label], 'provider' => r[:provider], 'model' => r[:model],
        'raw_text' => r[:raw_text].to_s,
        'elapsed_seconds' => r[:elapsed_seconds],
        'error' => r[:error],
        'status' => r[:status].to_s,
        'usage' => r[:usage]     # v0.3 F-USR: preserved for Phase 2 replay
      }
    end,
    'exit_summary' => {
      'successful' => results.count { |r| r[:status] == :success },
      'errored'    => results.count { |r| r[:status] == :error },
      'skipped'    => results.count { |r| r[:status] == :skip }
    }
  }
  PS.write_subprocess_results(token, payload)
  PS.transition_to_terminal!(token, 'done')
  exit 0
rescue StandardError => e
  warn "[dispatch_worker] FATAL: #{e.class}: #{e.message}"
  warn e.backtrace.first(20).join("\n") if e.backtrace
  begin
    PS.transition_to_terminal!(token, 'crashed', reason: "exception:#{e.class}")
  rescue StandardError
    nil
  end
  exit 1
ensure
  [pulse_thread, heartbeat_thread, log_rotator_thread, watchdog_thread].each do |t|
    t&.kill rescue nil
  end
end
