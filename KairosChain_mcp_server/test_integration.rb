#!/usr/bin/env ruby
# frozen_string_literal: true

# P2.8 Integration tests — Heartbeat + Budget + Integration wiring.
#
# Usage:
#   ruby KairosChain_mcp_server/test_integration.rb
#
# Philosophy:
#   * Use Dir.mktmpdir for filesystem isolation.
#   * Inject clocks so date-rollover and rate-limit logic are deterministic.
#   * Avoid depending on Chronos file I/O by passing `schedules:` inline.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'
require 'time'

require 'kairos_mcp/daemon'
require 'kairos_mcp/daemon/chronos'
require 'kairos_mcp/daemon/heartbeat'
require 'kairos_mcp/daemon/budget'
require 'kairos_mcp/daemon/integration'
require 'kairos_mcp/daemon/attach_server'

# ---------------------------------------------------------------------------
# Test harness (mirrors test_daemon.rb)
# ---------------------------------------------------------------------------

$pass = 0
$fail = 0
$failed_names = []

def assert(description, &block)
  result = block.call
  if result
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
  puts "    #{e.backtrace.first(5).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

class TestLogger
  attr_reader :entries

  def initialize
    @entries = []
  end

  %i[debug info warn error].each do |lvl|
    define_method(lvl) do |event, **fields|
      @entries << { level: lvl, event: event, **fields }
    end
  end

  def close; end

  def events(name)
    @entries.select { |e| e[:event].to_s == name.to_s }
  end
end

# A daemon-like stand-in: we need `status_snapshot`, `mailbox`, `@logger`.
# Building a real Daemon (which acquires a PID lock, installs signals) is
# more than we need — a lightweight double is enough to exercise Integration.
class FakeDaemon
  attr_reader :mailbox, :tick_count
  attr_accessor :state

  def initialize(logger:)
    @logger = logger
    @mailbox = KairosMcp::Daemon::CommandMailbox.new
    @state = :running
    @tick_count = 0
  end

  def chronos_tick; end
  def run_one_ooda_cycle; end

  def status_snapshot
    { state: @state.to_s, pid: Process.pid, tick_count: @tick_count,
      mailbox_size: @mailbox.size }
  end

  # Integration attaches: active_mandate_id, last_cycle_at, queue_depth,
  # integration_state, chronos_tick override, run_one_ooda_cycle override.
end

# ---------------------------------------------------------------------------
# HEARTBEAT
# ---------------------------------------------------------------------------

section 'Heartbeat: file writes'

Dir.mktmpdir('kc-hb-') do |root|
  hb_path = File.join(root, '.kairos', 'run', 'heartbeat.json')
  clock = -> { Time.utc(2026, 4, 20, 12, 0, 0) }
  hb = KairosMcp::Daemon::Heartbeat.new(path: hb_path, clock: clock)
  daemon = FakeDaemon.new(logger: TestLogger.new)

  at = hb.emit(daemon)

  assert('heartbeat file exists after emit') { File.exist?(hb_path) }
  assert('emit returns the clock time') { at.is_a?(Time) && at.year == 2026 }

  parsed = JSON.parse(File.read(hb_path))
  assert('heartbeat JSON parses') { parsed.is_a?(Hash) }
  assert('heartbeat has pid field') { parsed['pid'] == Process.pid }
  assert('heartbeat ts is ISO8601 for injected clock') do
    parsed['ts'] == '2026-04-20T12:00:00Z'
  end
  assert('heartbeat queue_depth defaults to 0') do
    parsed['queue_depth'] == 0
  end
  assert('heartbeat active_mandate_id is nil by default') do
    parsed['active_mandate_id'].nil?
  end
  assert('no .tmp file left behind after atomic rename') do
    Dir[File.join(File.dirname(hb_path), '*.tmp.*')].empty?
  end

  read_back = hb.read
  assert('Heartbeat#read returns parsed hash') do
    read_back.is_a?(Hash) && read_back['pid'] == Process.pid
  end
end

section 'Heartbeat: rate-limited emit_if_due'

Dir.mktmpdir('kc-hb2-') do |root|
  hb_path = File.join(root, '.kairos', 'run', 'heartbeat.json')
  t0 = Time.utc(2026, 4, 20, 12, 0, 0)
  now = t0
  clock = -> { now }
  hb = KairosMcp::Daemon::Heartbeat.new(path: hb_path, clock: clock)
  daemon = FakeDaemon.new(logger: TestLogger.new)

  first = hb.emit_if_due(daemon, nil, interval: 10)
  assert('first emit_if_due fires (last_emit_at nil)') { first == t0 }
  first_mtime = File.mtime(hb_path)

  now = t0 + 5
  sleep 0.01 # so mtime can differ if it were rewritten
  second = hb.emit_if_due(daemon, first, interval: 10)
  assert('emit_if_due within interval returns last_emit_at unchanged') do
    second == first
  end
  assert('emit_if_due within interval does not rewrite file') do
    File.mtime(hb_path) == first_mtime
  end

  now = t0 + 20
  third = hb.emit_if_due(daemon, first, interval: 10)
  assert('emit_if_due after interval fires') { third == now }
end

# ---------------------------------------------------------------------------
# BUDGET
# ---------------------------------------------------------------------------

section 'Budget: fresh ledger'

Dir.mktmpdir('kc-bg-') do |root|
  bg_path = File.join(root, '.kairos', 'state', 'budget.json')
  clock = -> { Time.utc(2026, 4, 20, 12, 0, 0) }
  bg = KairosMcp::Daemon::Budget.new(path: bg_path, limit: 100, clock: clock).load

  assert('fresh budget has today date') { bg.date == '2026-04-20' }
  assert('fresh budget calls = 0') { bg.llm_calls == 0 }
  assert('fresh budget not exceeded') { !bg.exceeded? }

  bg.record_usage(input_tokens: 50, output_tokens: 20, calls: 1)
  assert('record_usage increments llm_calls') { bg.llm_calls == 1 }
  assert('record_usage increments input_tokens') { bg.input_tokens == 50 }
  assert('record_usage increments output_tokens') { bg.output_tokens == 20 }

  bg.save
  assert('save writes budget.json') { File.exist?(bg_path) }
  assert('no budget .tmp file left after save') do
    Dir[File.join(File.dirname(bg_path), '*.tmp.*')].empty?
  end

  parsed = JSON.parse(File.read(bg_path))
  assert('saved budget.json has correct calls') { parsed['llm_calls'] == 1 }
end

section 'Budget: exceeded gate'

Dir.mktmpdir('kc-bg2-') do |root|
  bg_path = File.join(root, '.kairos', 'state', 'budget.json')
  clock = -> { Time.utc(2026, 4, 20) }
  bg = KairosMcp::Daemon::Budget.new(path: bg_path, limit: 3, clock: clock).load

  bg.record_usage(calls: 2)
  assert('2/3 not exceeded') { !bg.exceeded? }

  bg.record_usage(calls: 1)
  assert('3/3 exceeded (>=)') { bg.exceeded? }
end

section 'Budget: midnight rollover'

Dir.mktmpdir('kc-bg3-') do |root|
  bg_path = File.join(root, '.kairos', 'state', 'budget.json')
  now = Time.utc(2026, 4, 20, 23, 59, 0)
  clock = -> { now }
  bg = KairosMcp::Daemon::Budget.new(path: bg_path, limit: 100, clock: clock).load
  bg.record_usage(calls: 42, input_tokens: 10, output_tokens: 10)
  bg.save

  assert('before midnight, ledger has 42 calls') { bg.llm_calls == 42 }

  # Advance clock past midnight.
  now = Time.utc(2026, 4, 21, 0, 5, 0)
  reset = bg.reset_if_new_day!
  assert('reset_if_new_day! returns true on day change') { reset == true }
  assert('ledger date rolled over') { bg.date == '2026-04-21' }
  assert('ledger calls zeroed after rollover') { bg.llm_calls == 0 }
  assert('ledger tokens zeroed after rollover') do
    bg.input_tokens == 0 && bg.output_tokens == 0
  end

  # No-op when same day.
  reset2 = bg.reset_if_new_day!
  assert('reset_if_new_day! returns false on same day') { reset2 == false }
end

section 'Budget: reload honors previous-day ledger by rolling over'

Dir.mktmpdir('kc-bg4-') do |root|
  bg_path = File.join(root, '.kairos', 'state', 'budget.json')
  File.write(bg_path.tap { |p| FileUtils.mkdir_p(File.dirname(p)) },
             JSON.generate({ 'date' => '2026-04-19', 'llm_calls' => 77,
                             'input_tokens' => 0, 'output_tokens' => 0 }))

  clock = -> { Time.utc(2026, 4, 20) }
  bg = KairosMcp::Daemon::Budget.new(path: bg_path, limit: 100, clock: clock).load

  assert('stale ledger rolls over on load') do
    bg.date == '2026-04-20' && bg.llm_calls == 0
  end
end

# ---------------------------------------------------------------------------
# INTEGRATION WIRING
# ---------------------------------------------------------------------------

section 'Integration: chronos_tick fires and enqueues'

Dir.mktmpdir('kc-int-') do |root|
  logger = TestLogger.new
  state_path = File.join(root, 'chronos_state.yml')

  # Cron "* * * * *" (every minute) — will fire on any tick with a window > 60s.
  schedules = [
    { 'name' => 'demo',
      'cron' => '* * * * *',
      'concurrency' => 'queue',
      'mandate' => { 'goal' => 'demo goal' } }
  ]

  # Advance clock ~2 minutes after boot so at least one occurrence fires.
  base = Time.utc(2026, 4, 20, 12, 0, 30)
  now  = base
  clock = -> { now }

  chronos = KairosMcp::Daemon::Chronos.new(
    state_path: state_path, logger: logger, clock: clock, schedules: schedules
  )

  daemon = FakeDaemon.new(logger: logger)
  runs = []
  KairosMcp::Daemon::Integration.wire!(
    daemon,
    chronos: chronos,
    cycle_runner: ->(m) { runs << m; { status: 'ok', llm_calls: 1 } },
    clock: clock
  )

  # Advance past the next minute boundary.
  now = base + 120
  daemon.chronos_tick
  assert('chronos_tick enqueued at least one mandate') do
    chronos.queue.size >= 1
  end

  daemon.run_one_ooda_cycle
  assert('run_one_ooda_cycle popped the queued mandate') do
    runs.size == 1 && runs.first[:name] == 'demo'
  end
  assert('active_mandate_id is cleared after cycle') do
    daemon.active_mandate_id.nil?
  end
  assert('last_cycle_at is set after cycle') do
    daemon.last_cycle_at.is_a?(Time)
  end
end

section 'Integration: budget exceeded blocks cycle'

Dir.mktmpdir('kc-int2-') do |root|
  logger = TestLogger.new
  state_path = File.join(root, 'chronos_state.yml')
  bg_path    = File.join(root, 'budget.json')

  schedules = [
    { 'name' => 'blocked',
      'cron' => '* * * * *',
      'mandate' => { 'goal' => 'never runs' } }
  ]

  base = Time.utc(2026, 4, 20, 12, 0, 30)
  now  = base
  clock = -> { now }

  chronos = KairosMcp::Daemon::Chronos.new(
    state_path: state_path, logger: logger, clock: clock, schedules: schedules
  )
  budget = KairosMcp::Daemon::Budget.new(
    path: bg_path, limit: 5, clock: clock
  ).load
  # Pre-fill so exceeded? is true immediately.
  budget.record_usage(calls: 5)

  daemon = FakeDaemon.new(logger: logger)
  cycle_calls = 0
  KairosMcp::Daemon::Integration.wire!(
    daemon,
    chronos: chronos,
    budget: budget,
    cycle_runner: ->(_m) { cycle_calls += 1; { status: 'ok' } },
    clock: clock
  )

  now = base + 120
  daemon.chronos_tick
  assert('mandate queued even when budget exceeded') { chronos.queue.size >= 1 }

  daemon.run_one_ooda_cycle
  assert('cycle_runner NOT called when budget exceeded') { cycle_calls == 0 }
  assert('mandate still queued (not consumed by skipped cycle)') do
    chronos.queue.size >= 1
  end
  assert('logger recorded daemon_budget_exceeded') do
    logger.events(:daemon_budget_exceeded).any?
  end
end

section 'Integration: heartbeat emitted after cycle'

Dir.mktmpdir('kc-int3-') do |root|
  logger = TestLogger.new
  hb_path = File.join(root, 'hb.json')
  state_path = File.join(root, 'chronos_state.yml')

  base = Time.utc(2026, 4, 20, 12, 0, 0)
  now = base
  clock = -> { now }

  chronos = KairosMcp::Daemon::Chronos.new(
    state_path: state_path, logger: logger, clock: clock, schedules: []
  )
  hb = KairosMcp::Daemon::Heartbeat.new(path: hb_path, clock: clock)

  daemon = FakeDaemon.new(logger: logger)
  KairosMcp::Daemon::Integration.wire!(
    daemon,
    chronos: chronos,
    heartbeat: hb,
    cycle_runner: ->(_m) { { status: 'ok' } },
    clock: clock,
    heartbeat_interval: 0 # force emit every cycle
  )

  daemon.run_one_ooda_cycle
  assert('heartbeat file written after cycle') { File.exist?(hb_path) }

  parsed = JSON.parse(File.read(hb_path))
  assert('heartbeat contains pid') { parsed['pid'] == Process.pid }
  assert('heartbeat contains queue_depth') do
    parsed.key?('queue_depth') && parsed['queue_depth'] == 0
  end
end

section 'Integration: shutdown command flows through mailbox'

Dir.mktmpdir('kc-int4-') do |root|
  logger = TestLogger.new
  state_path = File.join(root, 'chronos_state.yml')

  base = Time.utc(2026, 4, 20, 12, 0, 0)
  clock = -> { base }

  chronos = KairosMcp::Daemon::Chronos.new(
    state_path: state_path, logger: logger, clock: clock, schedules: []
  )

  daemon = FakeDaemon.new(logger: logger)
  KairosMcp::Daemon::Integration.wire!(
    daemon,
    chronos: chronos,
    clock: clock
  )

  # AttachServer would enqueue this from an HTTP request. We simulate.
  daemon.mailbox.enqueue(:shutdown, reason: 'attach_client')

  drained = daemon.mailbox.drain
  assert('shutdown command arrived in mailbox') do
    drained.any? { |c| c[:type] == :shutdown }
  end

  assert('Integration.unwire! is safe to call') do
    KairosMcp::Daemon::Integration.unwire!(daemon)
    true
  end
end

section 'Integration: active_mandate_id tracks current cycle'

Dir.mktmpdir('kc-int5-') do |root|
  logger = TestLogger.new
  state_path = File.join(root, 'chronos_state.yml')

  schedules = [
    { 'name' => 'tracked',
      'cron' => '* * * * *',
      'mandate' => { 'goal' => 'g' } }
  ]

  base = Time.utc(2026, 4, 20, 12, 0, 30)
  now = base
  clock = -> { now }

  chronos = KairosMcp::Daemon::Chronos.new(
    state_path: state_path, logger: logger, clock: clock, schedules: schedules
  )

  seen_active = []
  daemon = FakeDaemon.new(logger: logger)
  KairosMcp::Daemon::Integration.wire!(
    daemon,
    chronos: chronos,
    cycle_runner: ->(_m) {
      seen_active << daemon.active_mandate_id
      { status: 'ok' }
    },
    clock: clock
  )

  now = base + 120
  daemon.chronos_tick
  daemon.run_one_ooda_cycle

  assert('active_mandate_id set during cycle_runner call') do
    seen_active.size == 1 && seen_active.first == 'tracked'
  end
  assert('queue_depth = 0 after the only mandate ran') do
    daemon.queue_depth == 0
  end
end

# ---------------------------------------------------------------------------
# Summary
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
