#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.0 End-to-End Integration tests —
#   MandateFactory + Planner + WalPhaseRecorder + WalRecovery wired
#   together through the existing Integration.wire! pipeline.
#
# Usage:
#   ruby KairosChain_mcp_server/test_p3_integration.rb
#
# Philosophy:
#   * Dir.mktmpdir for every filesystem fixture.
#   * Inject clocks and stubs so there is no hidden I/O.
#   * Write-ahead semantics: every lifecycle test commits the plan to WAL
#     BEFORE writing the mandate JSON.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'json'
require 'time'
require 'tmpdir'

require 'kairos_mcp/daemon'
require 'kairos_mcp/daemon/budget'
require 'kairos_mcp/daemon/canonical'
require 'kairos_mcp/daemon/chronos'
require 'kairos_mcp/daemon/heartbeat'
require 'kairos_mcp/daemon/integration'
require 'kairos_mcp/daemon/mandate_factory'
require 'kairos_mcp/daemon/planner'
require 'kairos_mcp/daemon/wal'
require 'kairos_mcp/daemon/wal_phase_recorder'
require 'kairos_mcp/daemon/wal_recovery'

# ---------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------

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

# Minimal daemon double — same shape test_integration.rb uses.
class FakeDaemon
  attr_reader :mailbox
  attr_accessor :state

  def initialize(logger:)
    @logger  = logger
    @mailbox = KairosMcp::Daemon::CommandMailbox.new
    @state   = :running
  end

  def chronos_tick; end
  def run_one_ooda_cycle; end

  def status_snapshot
    { state: @state.to_s, pid: Process.pid, mailbox_size: @mailbox.size }
  end
end

def make_fired_event(name: 'daily_summary', fired_at: '2026-04-20T12:00:00Z',
                     mandate_overrides: {})
  schedule = {
    name:          name,
    cron:          '0 12 * * *',
    concurrency:   'queue',
    project_scope: 'kairos',
    mandate: {
      goal:             "summarize_#{name}",
      max_cycles:       3,
      checkpoint_every: 1,
      risk_budget:      'low'
    }.merge(mandate_overrides)
  }
  mandate = {
    name:             name,
    source:           "chronos:#{name}",
    mode:             'daemon',
    goal:             "summarize_#{name}",
    max_cycles:       3,
    checkpoint_every: 1,
    risk_budget:      'low',
    project_scope:    'kairos',
    fired_at:         fired_at
  }.merge(mandate_overrides)
  KairosMcp::Daemon::Chronos::FiredEvent.new(
    name:     name,
    schedule: schedule,
    mandate:  mandate,
    fired_at: fired_at
  )
end

MF = KairosMcp::Daemon::MandateFactory
PL = KairosMcp::Daemon::Planner
WPR = KairosMcp::Daemon::WalPhaseRecorder
WR  = KairosMcp::Daemon::WalRecovery
WAL = KairosMcp::Daemon::WAL
CAN = KairosMcp::Daemon::Canonical

# ---------------------------------------------------------------------------
# MandateFactory
# ---------------------------------------------------------------------------

section 'MandateFactory: Hash shape'

ev = make_fired_event
m = MF.build(ev, plan_id: 'plan_abc123', now: Time.utc(2026, 4, 20, 12, 0, 0))

assert('mandate is a Hash') { m.is_a?(Hash) }
assert('mandate_id derived from plan_id') { m[:mandate_id] == 'mnd_plan_abc123' }
assert('plan_id carried through') { m[:plan_id] == 'plan_abc123' }
assert('goal_name matches schedule goal') { m[:goal_name] == 'summarize_daily_summary' }
assert('goal_hash is deterministic sha256') do
  m[:goal_hash] == CAN.sha256('summarize_daily_summary')
end
assert('status is "created"') { m[:status] == 'created' }
assert('cycles_completed starts at 0') { m[:cycles_completed] == 0 }
assert('consecutive_errors starts at 0') { m[:consecutive_errors] == 0 }
assert('cycle_history is an empty Array') { m[:cycle_history] == [] }
assert('recent_gap_descriptions is an empty Array') { m[:recent_gap_descriptions] == [] }
assert('created_at equals injected clock') { m[:created_at] == '2026-04-20T12:00:00Z' }
assert('updated_at equals injected clock') { m[:updated_at] == '2026-04-20T12:00:00Z' }
assert('source falls back to chronos:<name>') { m[:source] == 'chronos:daily_summary' }

section 'MandateFactory: clamping'

over = MF.build(
  make_fired_event(mandate_overrides: {
                     max_cycles: 50, checkpoint_every: 10, risk_budget: 'high'
                   }),
  plan_id: 'plan_over'
)
assert('max_cycles clamped to 10') { over[:max_cycles] == 10 }
assert('checkpoint_every clamped to 3') { over[:checkpoint_every] == 3 }
assert('risk_budget normalized to "low" when invalid') { over[:risk_budget] == 'low' }

under = MF.build(
  make_fired_event(mandate_overrides: {
                     max_cycles: 0, checkpoint_every: 0, risk_budget: 'medium'
                   }),
  plan_id: 'plan_under'
)
assert('max_cycles clamped up to 1') { under[:max_cycles] == 1 }
assert('checkpoint_every clamped up to 1') { under[:checkpoint_every] == 1 }
assert('risk_budget "medium" accepted') { under[:risk_budget] == 'medium' }

assert('checkpoint_every capped at max_cycles when max is 1') do
  small = MF.build(
    make_fired_event(mandate_overrides: { max_cycles: 1, checkpoint_every: 3 }),
    plan_id: 'plan_small'
  )
  small[:checkpoint_every] == 1 && small[:max_cycles] == 1
end

assert('plan_id required') do
  begin
    MF.build(ev, plan_id: nil)
    false
  rescue ArgumentError
    true
  end
end

# ---------------------------------------------------------------------------
# Planner
# ---------------------------------------------------------------------------

section 'Planner: OODA steps'

plan = PL.plan_from_fired_event(ev)
assert('plan has plan_id') { plan[:plan_id].is_a?(String) && !plan[:plan_id].empty? }
assert('plan has 5 steps') { plan[:steps].size == 5 }
assert('step ids are observe_001..reflect_001') do
  plan[:steps].map { |s| s[:step_id] } ==
    %w[observe_001 orient_001 decide_001 act_001 reflect_001]
end
assert('each step has a tool field like ooda.<phase>') do
  plan[:steps].all? { |s| s[:tool].start_with?('ooda.') }
end
assert('each step has params_hash/pre_hash/expected_post_hash') do
  plan[:steps].all? { |s|
    s[:params_hash].is_a?(String) &&
      s[:pre_hash].is_a?(String) &&
      s[:expected_post_hash].is_a?(String)
  }
end
assert('plan_id deterministic for same (name, fired_at)') do
  a = PL.plan_from_fired_event(ev)[:plan_id]
  b = PL.plan_from_fired_event(ev)[:plan_id]
  a == b
end
assert('plan_id differs when fired_at differs') do
  a = PL.plan_from_fired_event(make_fired_event(fired_at: '2026-04-20T12:00:00Z'))[:plan_id]
  b = PL.plan_from_fired_event(make_fired_event(fired_at: '2026-04-20T13:00:00Z'))[:plan_id]
  a != b
end

assert('cycle=2 step ids are observe_002..') do
  p2 = PL.plan_from_fired_event(ev, cycle: 2)
  p2[:steps].map { |s| s[:step_id] } ==
    %w[observe_002 orient_002 decide_002 act_002 reflect_002]
end
assert('step_id_for helper matches formatted id') do
  PL.step_id_for(:observe, 1) == 'observe_001' &&
    PL.step_id_for('decide', 17) == 'decide_017'
end

# ---------------------------------------------------------------------------
# WalPhaseRecorder
# ---------------------------------------------------------------------------

section 'WalPhaseRecorder: around_phase'

Dir.mktmpdir('kc-wpr-') do |root|
  path = File.join(root, 'mnd_1.wal.jsonl')
  wal = WAL.open(path: path)
  begin
    wal.commit_plan(
      plan_id: 'plan_1',
      mandate_id: 'mnd_1',
      cycle: 1,
      steps: PL::OODA_PHASES.map do |ph|
        {
          step_id: format('%s_%03d', ph, 1),
          tool: "ooda.#{ph}",
          params_hash: CAN.sha256_json({ phase: ph }),
          pre_hash:  CAN.sha256_json({ phase: ph, state: 'pre' }),
          expected_post_hash: CAN.sha256_json({ phase: ph, state: 'post' })
        }
      end
    )

    rec = WPR.new(wal: wal, cycle: 1)
    ran = []
    PL::OODA_PHASES.each do |ph|
      rec.around_phase(ph) { ran << ph; { ok: true, phase: ph } }
    end

    plans = wal.plans
    p1 = plans.first
    executing = p1.steps.map(&:status)
    assert('every phase executed') do
      ran == PL::OODA_PHASES
    end
    assert('every step marked completed') do
      executing.all? { |s| s == 'completed' }
    end
    assert('every completed step has post_hash and result_hash') do
      p1.steps.all? { |s| s.post_hash && s.result_hash }
    end
  ensure
    wal.close
  end
end

section 'WalPhaseRecorder: mark_executing precedes mark_completed'

Dir.mktmpdir('kc-wpr2-') do |root|
  path = File.join(root, 'mnd_order.wal.jsonl')
  wal = WAL.open(path: path)
  begin
    wal.commit_plan(
      plan_id: 'plan_o',
      mandate_id: 'mnd_order',
      cycle: 1,
      steps: [{
        step_id: 'observe_001',
        tool: 'ooda.observe',
        params_hash: CAN.sha256_json({ phase: 'observe' }),
        pre_hash: CAN.sha256_json({ phase: 'observe', state: 'pre' }),
        expected_post_hash: CAN.sha256_json({ phase: 'observe', state: 'post' })
      }]
    )
    WPR.new(wal: wal, cycle: 1).around_phase(:observe) { :ok }
    wal.close

    lines = File.readlines(path).map { |l| JSON.parse(l) }
    transitions = lines.select { |e| e['op'] == 'transition' && e['step_id'] == 'observe_001' }
    statuses = transitions.map { |e| e['status'] }
    assert('transitions are executing → completed in order') do
      statuses == %w[executing completed]
    end
  ensure
    wal.close unless wal.nil?
  end
end

section 'WalPhaseRecorder: failure records mark_failed and re-raises'

Dir.mktmpdir('kc-wpr3-') do |root|
  path = File.join(root, 'mnd_fail.wal.jsonl')
  wal = WAL.open(path: path)
  begin
    wal.commit_plan(
      plan_id: 'plan_f',
      mandate_id: 'mnd_fail',
      cycle: 1,
      steps: [{
        step_id: 'orient_001',
        tool: 'ooda.orient',
        params_hash: CAN.sha256_json({}),
        pre_hash:  CAN.sha256_json({ s: 'pre' }),
        expected_post_hash: CAN.sha256_json({ s: 'post' })
      }]
    )
    rec = WPR.new(wal: wal, cycle: 1)
    raised = false
    begin
      rec.around_phase(:orient) { raise 'boom' }
    rescue StandardError => e
      raised = (e.message == 'boom')
    end
    wal.close

    lines = File.readlines(path).map { |l| JSON.parse(l) }
    failed = lines.find { |e| e['op'] == 'transition' && e['status'] == 'failed' }
    assert('exception re-raised by around_phase') { raised }
    assert('wal has a failed transition for the step') do
      !failed.nil? && failed['error_class'] == 'RuntimeError'
    end
  ensure
    wal.close unless wal.nil?
  end
end

# ---------------------------------------------------------------------------
# WalRecovery
# ---------------------------------------------------------------------------

section 'WalRecovery: empty dir is a no-op'

Dir.mktmpdir('kc-rec-empty-') do |root|
  count = WR.recover_from_wal!(root, TestLogger.new)
  assert('recover returns 0 for empty dir') { count == 0 }
end

assert('recover returns 0 for nil wal_dir') { WR.recover_from_wal!(nil) == 0 }
assert('recover returns 0 for non-existent dir') do
  WR.recover_from_wal!('/tmp/definitely-not-a-real-wal-dir-xyz') == 0
end

section 'WalRecovery: resets executing to pending'

Dir.mktmpdir('kc-rec-') do |root|
  path = File.join(root, 'mnd_crash.wal.jsonl')
  wal = WAL.open(path: path)
  wal.commit_plan(
    plan_id: 'plan_c',
    mandate_id: 'mnd_crash',
    cycle: 1,
    steps: [
      { step_id: 'observe_001', tool: 'ooda.observe',
        params_hash: CAN.sha256_json({ phase: 'observe' }),
        pre_hash: CAN.sha256_json({ s: 'pre' }),
        expected_post_hash: CAN.sha256_json({ s: 'post' }) },
      { step_id: 'orient_001', tool: 'ooda.orient',
        params_hash: CAN.sha256_json({ phase: 'orient' }),
        pre_hash: CAN.sha256_json({ s: 'pre' }),
        expected_post_hash: CAN.sha256_json({ s: 'post' }) }
    ]
  )
  wal.mark_executing('observe_001', pre_hash: CAN.sha256_json({ s: 'pre' }))
  wal.mark_executing('orient_001',  pre_hash: CAN.sha256_json({ s: 'pre' }))
  # Simulate a crash: orient never completes, but observe did.
  wal.mark_completed('observe_001',
                     post_hash: CAN.sha256_json({ s: 'post' }),
                     result_hash: CAN.sha256_json({ ok: true }))
  wal.close

  logger = TestLogger.new
  count = WR.recover_from_wal!(root, logger)
  assert('recovery reset exactly 1 executing step') { count == 1 }

  # Re-open and inspect.
  wal2 = WAL.open(path: path)
  plans = wal2.plans
  statuses = plans.first.steps.map { |s| [s.step_id, s.status] }.to_h
  wal2.close

  assert('completed observe remains completed') do
    statuses['observe_001'] == 'completed'
  end
  assert('executing orient reset to pending') do
    statuses['orient_001'] == 'pending'
  end
  assert('recovery logged a reset event') do
    logger.events('wal_recovery_reset_step').size == 1
  end
  assert('recovery logged a completion event') do
    logger.events('wal_recovery_complete').size == 1
  end
end

section 'WalRecovery: leaves finalized plans alone'

Dir.mktmpdir('kc-rec-fin-') do |root|
  path = File.join(root, 'mnd_done.wal.jsonl')
  wal = WAL.open(path: path)
  wal.commit_plan(
    plan_id: 'plan_d',
    mandate_id: 'mnd_done',
    cycle: 1,
    steps: [{
      step_id: 'observe_001', tool: 'ooda.observe',
      params_hash: CAN.sha256_json({}),
      pre_hash:  CAN.sha256_json({ s: 'pre' }),
      expected_post_hash: CAN.sha256_json({ s: 'post' })
    }]
  )
  # An executing step, but the plan itself is finalized — recovery must skip.
  wal.mark_executing('observe_001', pre_hash: CAN.sha256_json({ s: 'pre' }))
  wal.finalize_plan('plan_d', status: 'succeeded')
  wal.close

  count = WR.recover_from_wal!(root)
  assert('finalized plan ignored by recovery') { count == 0 }
end

# ---------------------------------------------------------------------------
# Full lifecycle
# ---------------------------------------------------------------------------

section 'Lifecycle: chronos → plan → WAL → mandate → cycle → finalize'

Dir.mktmpdir('kc-life-') do |root|
  wal_dir = File.join(root, 'wal')
  mandates_dir = File.join(root, 'mandates')
  FileUtils.mkdir_p(wal_dir)
  FileUtils.mkdir_p(mandates_dir)

  schedules = [{
    name: 'daily_summary',
    cron: '*/1 * * * *',
    concurrency: 'queue',
    project_scope: 'kairos',
    mandate: { goal: 'summary', max_cycles: 2, checkpoint_every: 1, risk_budget: 'low' }
  }]
  base = Time.utc(2026, 4, 20, 12, 0, 0)
  now_t = base
  clock = -> { now_t }
  chronos = KairosMcp::Daemon::Chronos.new(
    schedules: schedules,
    state_path: File.join(root, 'chronos_state.yml'),
    clock: clock
  )
  # Advance clock past at least one cron interval so tick fires.
  now_t = base + 120
  budget = KairosMcp::Daemon::Budget.new(
    path: File.join(root, 'budget.json'),
    limit: 1000, clock: clock
  )

  saw = { mandate_id: nil, plan_id: nil, finalize_status: nil, phases: [] }

  cycle_runner = lambda do |mandate|
    # Write-ahead: plan → WAL first, then mandate file.
    synth_event = KairosMcp::Daemon::Chronos::FiredEvent.new(
      name: mandate[:name], schedule: {}, mandate: mandate,
      fired_at: mandate[:fired_at]
    )
    plan = PL.plan_from_fired_event(synth_event)
    m    = MF.build(synth_event, plan_id: plan[:plan_id])

    wal_path = File.join(wal_dir, "#{m[:mandate_id]}.wal.jsonl")
    wal = WAL.open(path: wal_path)

    wal.commit_plan(
      plan_id: plan[:plan_id],
      mandate_id: m[:mandate_id],
      cycle: plan[:cycle],
      steps: plan[:steps]
    )
    # Mandate persisted AFTER plan commit — strict write-ahead order.
    File.write(File.join(mandates_dir, "#{m[:mandate_id]}.json"), JSON.pretty_generate(m))

    recorder = WPR.new(wal: wal, cycle: plan[:cycle])
    PL::OODA_PHASES.each { |ph| recorder.around_phase(ph) { saw[:phases] << ph; { ok: true } } }
    wal.finalize_plan(plan[:plan_id], status: 'succeeded')
    wal.close

    saw[:mandate_id]      = m[:mandate_id]
    saw[:plan_id]         = plan[:plan_id]
    saw[:finalize_status] = 'succeeded'
    { status: 'ok', llm_calls: 1, input_tokens: 10, output_tokens: 20 }
  end

  daemon = FakeDaemon.new(logger: TestLogger.new)
  KairosMcp::Daemon::Integration.wire!(
    daemon,
    chronos: chronos,
    budget: budget,
    wal_dir: wal_dir,
    cycle_runner: cycle_runner,
    clock: clock
  )

  daemon.chronos_tick
  daemon.run_one_ooda_cycle

  assert('lifecycle: all 5 phases executed') do
    saw[:phases] == PL::OODA_PHASES
  end
  assert('lifecycle: mandate file written on disk') do
    !saw[:mandate_id].nil? &&
      File.exist?(File.join(mandates_dir, "#{saw[:mandate_id]}.json"))
  end
  assert('lifecycle: WAL file exists for the mandate') do
    File.exist?(File.join(wal_dir, "#{saw[:mandate_id]}.wal.jsonl"))
  end
  assert('lifecycle: plan finalized as succeeded') do
    saw[:finalize_status] == 'succeeded'
  end
  assert('lifecycle: budget recorded LLM usage from cycle_runner') do
    budget.llm_calls == 1 && budget.input_tokens == 10 && budget.output_tokens == 20
  end
  assert('lifecycle: chronos queue drained') do
    chronos.queue.empty?
  end

  # Write-ahead ordering check: plan_commit must appear before the
  # mandate-file mtime (we verify plan_commit is the FIRST op in WAL).
  wal_path = File.join(wal_dir, "#{saw[:mandate_id]}.wal.jsonl")
  first_op = JSON.parse(File.readlines(wal_path).first)['op']
  assert('lifecycle: WAL first entry is plan_commit (write-ahead)') do
    first_op == 'plan_commit'
  end
end

section 'Lifecycle: budget exceeded → cycle paused'

Dir.mktmpdir('kc-budget-') do |root|
  wal_dir = File.join(root, 'wal'); FileUtils.mkdir_p(wal_dir)
  schedules = [{
    name: 'hourly',
    cron: '*/1 * * * *',
    concurrency: 'queue',
    mandate: { goal: 'x', max_cycles: 2, checkpoint_every: 1, risk_budget: 'low' }
  }]
  base = Time.utc(2026, 4, 20, 12, 0, 0)
  now_t = base
  clock = -> { now_t }
  chronos = KairosMcp::Daemon::Chronos.new(
    schedules: schedules,
    state_path: File.join(root, 'chronos_state.yml'),
    clock: clock
  )
  now_t = base + 120
  budget = KairosMcp::Daemon::Budget.new(
    path: File.join(root, 'budget.json'), limit: 5, clock: clock
  )
  # Push budget over the limit BEFORE the cycle runs.
  budget.record_usage(input_tokens: 0, output_tokens: 0, calls: 10)

  ran = false
  cycle_runner = ->(_m) { ran = true; { status: 'ok', llm_calls: 0 } }

  daemon = FakeDaemon.new(logger: TestLogger.new)
  KairosMcp::Daemon::Integration.wire!(
    daemon,
    chronos: chronos, budget: budget,
    wal_dir: wal_dir, cycle_runner: cycle_runner, clock: clock
  )

  daemon.chronos_tick
  daemon.run_one_ooda_cycle

  assert('cycle_runner NOT invoked when budget exceeded') { ran == false }
  assert('mandate stays queued when budget exceeded') { chronos.queue.size == 1 }
end

section 'Lifecycle: crash recovery resumes executing steps'

Dir.mktmpdir('kc-crash-') do |root|
  wal_dir = File.join(root, 'wal'); FileUtils.mkdir_p(wal_dir)
  wal_path = File.join(wal_dir, 'mnd_crashy.wal.jsonl')
  wal = WAL.open(path: wal_path)

  plan = PL.plan_from_fired_event(make_fired_event(name: 'crashy'))
  wal.commit_plan(
    plan_id: plan[:plan_id], mandate_id: 'mnd_crashy',
    cycle: plan[:cycle], steps: plan[:steps]
  )
  rec = WPR.new(wal: wal, cycle: plan[:cycle])
  rec.around_phase(:observe) { :ok }
  # "Crash" mid-orient: mark_executing but never mark_completed.
  wal.mark_executing('orient_001', pre_hash: CAN.sha256_json({ s: 'pre' }))
  wal.close

  count = WR.recover_from_wal!(wal_dir, TestLogger.new)
  assert('crash recovery reset 1 step') { count == 1 }

  wal2 = WAL.open(path: wal_path)
  statuses = wal2.plans.first.steps.map { |s| [s.step_id, s.status] }.to_h
  wal2.close

  assert('observe remains completed after recovery') do
    statuses['observe_001'] == 'completed'
  end
  assert('orient reset to pending, ready for resume') do
    statuses['orient_001'] == 'pending'
  end
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
