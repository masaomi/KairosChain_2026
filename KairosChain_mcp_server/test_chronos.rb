#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for P2.4: Chronos scheduler.
#
# Usage:
#   ruby KairosChain_mcp_server/test_chronos.rb
#
# Design reference: docs v0.2 §4.
#
# Coverage:
#   * Cron parser: *, */N, N, N-M, N,M, N-M/S, bad input
#   * Cron.matches?: hour/minute/month; dom+dow OR semantics
#   * Cron.count_occurrences: window boundary, multi-minute, weekday-only
#   * Cron.next_occurrence: basic, at minute boundary
#   * Chronos#tick: empty schedules / disabled / due / non-due / multi-schedule
#   * apply_missed_policy: skip / catch_up_once / catch_up_bounded / stale
#   * State: last_evaluated_at vs last_fire_at separation (CF-10)
#   * State: atomic persist (CF-13), recovery from YAML, no-.tmp left behind
#   * enqueue_mandate: queue / reject (running or not)
#   * Edge case: 24h downtime + skip policy fires once
#
# All tests use Dir.mktmpdir to isolate .kairos/ from the project.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'yaml'
require 'time'

require 'kairos_mcp/daemon/chronos'

Chronos = KairosMcp::Daemon::Chronos
Cron    = Chronos::Cron

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

$pass = 0
$fail = 0
$failed_names = []

def assert(description)
  result = yield
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

def assert_raises(description, klass = StandardError)
  yield
  $fail += 1
  $failed_names << description
  puts "  FAIL: #{description} — no exception raised"
rescue Exception => e # rubocop:disable Lint/RescueException
  if e.is_a?(klass)
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    $failed_names << description
    puts "  FAIL: #{description} — expected #{klass}, got #{e.class}"
  end
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

def schedules_yml(schedules)
  YAML.dump('schedules' => schedules.map { |s| s.transform_keys(&:to_s) })
end

def write_schedules(root, schedules)
  path = File.join(root, '.kairos', 'config', 'schedules.yml')
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, schedules_yml(schedules))
  path
end

def state_path_for(root)
  File.join(root, '.kairos', 'chronos_state.yml')
end

def utc(y, mo, d, h = 0, mi = 0)
  Time.utc(y, mo, d, h, mi, 0)
end

# ---------------------------------------------------------------------------
# Cron parser
# ---------------------------------------------------------------------------

section 'Cron — parse / matches?'

assert 'parse "* * * * *" covers every value' do
  c = Cron.parse('* * * * *')
  c[:minute] == (0..59).to_a && c[:hour] == (0..23).to_a &&
    c[:mday] == (1..31).to_a && c[:month] == (1..12).to_a &&
    c[:wday] == (0..6).to_a
end

assert 'parse "0 9 * * 1-5" — weekday morning' do
  c = Cron.parse('0 9 * * 1-5')
  c[:minute] == [0] && c[:hour] == [9] && c[:wday] == [1, 2, 3, 4, 5]
end

assert 'parse "*/15 * * * *" — every 15 min' do
  c = Cron.parse('*/15 * * * *')
  c[:minute] == [0, 15, 30, 45]
end

assert 'parse "0 0,12 * * *" — midnight and noon' do
  c = Cron.parse('0 0,12 * * *')
  c[:hour] == [0, 12]
end

assert 'parse "0 0 1-7/2 * *" — range with step' do
  c = Cron.parse('0 0 1-7/2 * *')
  c[:mday] == [1, 3, 5, 7]
end

assert_raises 'parse raises on 4-field input', ArgumentError do
  Cron.parse('0 9 * *')
end

assert_raises 'parse raises on out-of-range value', ArgumentError do
  Cron.parse('60 * * * *')
end

assert_raises 'parse raises on malformed item', ArgumentError do
  Cron.parse('1..5 * * * *')
end

assert 'matches? — exact minute/hour/month' do
  c = Cron.parse('30 14 * * *')
  t = utc(2026, 4, 20, 14, 30)
  Cron.matches?(c, t)
end

assert 'matches? — minute mismatch is false' do
  c = Cron.parse('30 14 * * *')
  !Cron.matches?(c, utc(2026, 4, 20, 14, 29))
end

assert 'matches? — dom+dow OR semantics (both restricted)' do
  # "0 0 1 * 1" — fires on the 1st OR on Monday.
  c = Cron.parse('0 0 1 * 1')
  # 2026-04-01 is Wednesday (wday=3) — dom matches, dow doesn't → fire.
  dom_hit = Cron.matches?(c, utc(2026, 4, 1, 0, 0))
  # 2026-04-20 is Monday (wday=1) — dow matches, dom doesn't → fire.
  dow_hit = Cron.matches?(c, utc(2026, 4, 20, 0, 0))
  # 2026-04-15 is Wednesday — neither matches → no fire.
  no_hit = !Cron.matches?(c, utc(2026, 4, 15, 0, 0))
  dom_hit && dow_hit && no_hit
end

assert 'matches? — both wildcards, only other fields must match' do
  c = Cron.parse('0 9 * * *')
  Cron.matches?(c, utc(2026, 4, 20, 9, 0)) &&
    !Cron.matches?(c, utc(2026, 4, 20, 10, 0))
end

# ---------------------------------------------------------------------------
# count_occurrences
# ---------------------------------------------------------------------------

section 'Cron — count_occurrences / next_occurrence'

assert 'count_occurrences: hourly cron across 3-hour window' do
  # "0 * * * *" fires once per hour. Window (08:00, 11:00] → 9,10,11 = 3.
  c = Cron.count_occurrences('0 * * * *',
                             from: utc(2026, 4, 20, 8, 0),
                             to:   utc(2026, 4, 20, 11, 0))
  c == 3
end

assert 'count_occurrences: exclusive lower, inclusive upper' do
  # "0 9 * * *" at exactly 09:00. Window (09:00, 09:00] → 0.
  c1 = Cron.count_occurrences('0 9 * * *',
                              from: utc(2026, 4, 20, 9, 0),
                              to:   utc(2026, 4, 20, 9, 0))
  # Window (08:59, 09:00] → 1.
  c2 = Cron.count_occurrences('0 9 * * *',
                              from: utc(2026, 4, 20, 8, 59),
                              to:   utc(2026, 4, 20, 9, 0))
  c1.zero? && c2 == 1
end

assert 'count_occurrences: no matches returns 0' do
  c = Cron.count_occurrences('0 9 * * *',
                             from: utc(2026, 4, 20, 10, 0),
                             to:   utc(2026, 4, 20, 11, 0))
  c.zero?
end

assert 'count_occurrences: weekday-only (Mon-Fri at 09:00), 7-day window' do
  # 2026-04-20 Monday .. 2026-04-26 Sunday. Mon-Fri → 5 fires.
  c = Cron.count_occurrences('0 9 * * 1-5',
                             from: utc(2026, 4, 20, 0, 0),
                             to:   utc(2026, 4, 27, 0, 0))
  c == 5
end

assert 'count_occurrences: every-5-min cron over 1 hour' do
  # "*/5 * * * *" in (08:00, 09:00] → minutes 05,10,...,00 of next hour = 12.
  c = Cron.count_occurrences('*/5 * * * *',
                             from: utc(2026, 4, 20, 8, 0),
                             to:   utc(2026, 4, 20, 9, 0))
  c == 12
end

assert 'next_occurrence: finds next minute' do
  t = Cron.next_occurrence('0 9 * * *', after: utc(2026, 4, 20, 8, 30))
  t.utc? && t.hour == 9 && t.min == 0 && t.day == 20
end

assert 'next_occurrence: wraps to next day' do
  t = Cron.next_occurrence('0 9 * * *', after: utc(2026, 4, 20, 10, 0))
  t.day == 21 && t.hour == 9
end

# ---------------------------------------------------------------------------
# Chronos.tick — empty / disabled / basic
# ---------------------------------------------------------------------------

section 'Chronos#tick — empty / disabled / fire / non-fire'

assert 'empty schedules → no fires' do
  Dir.mktmpdir do |root|
    write_schedules(root, [])
    chronos = Chronos.new(
      schedules_path: File.join(root, '.kairos', 'config', 'schedules.yml'),
      state_path:     state_path_for(root),
      clock:          -> { utc(2026, 4, 20, 9, 0) }
    )
    chronos.tick(utc(2026, 4, 20, 9, 0)).empty?
  end
end

assert 'disabled schedule is skipped' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'nonexistent.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 'x', cron: '* * * * *', enabled: false,
                    missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 9, 0) }
    )
    # Boot time == clock; next minute must still fire if enabled, but
    # with enabled:false the tick should be empty.
    chronos.tick(utc(2026, 4, 20, 9, 5)).empty?
  end
end

assert 'due schedule fires, returns FiredEvent with mandate' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{
        name: 'hourly', cron: '0 * * * *', missed_policy: 'skip',
        timezone: 'UTC',
        mandate: { goal: 'scan', max_cycles: 20, checkpoint_every: 5, risk_budget: 'low' }
      }],
      clock: -> { utc(2026, 4, 20, 8, 55) }
    )
    # First tick at 08:55 — boot time; no fires (boot_time == now).
    first = chronos.tick(utc(2026, 4, 20, 8, 55))
    # Second tick at 09:00 — one hourly fire expected.
    second = chronos.tick(utc(2026, 4, 20, 9, 0))

    ok_first  = first.empty?
    ok_second = second.size == 1 && second.first.name == 'hourly'
    mandate   = second.first.mandate
    ok_mandate = mandate[:source] == 'chronos:hourly' &&
                 mandate[:mode] == 'daemon' &&
                 mandate[:goal] == 'scan' &&
                 mandate[:max_cycles] == 20

    ok_first && ok_second && ok_mandate
  end
end

assert 'non-due schedule does not fire' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 9 * * *', missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 10, 0) }
    )
    chronos.tick(utc(2026, 4, 20, 10, 30)).empty?
  end
end

assert 'multiple schedules in one tick both fire' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [
        { name: 'a', cron: '0 * * * *', missed_policy: 'skip', timezone: 'UTC' },
        { name: 'b', cron: '0 * * * *', missed_policy: 'skip', timezone: 'UTC' }
      ],
      clock: -> { utc(2026, 4, 20, 8, 59) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 59)) # prime
    fired = chronos.tick(utc(2026, 4, 20, 9, 0))
    fired.map(&:name).sort == %w[a b]
  end
end

# ---------------------------------------------------------------------------
# Missed policy tests
# ---------------------------------------------------------------------------

section 'Chronos — missed_policy behaviour'

assert 'skip policy: fires once, logs missed count for the rest' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 * * * *', missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 0) }
    )
    # Prime at 08:00 so last_evaluated_at = 08:00.
    chronos.tick(utc(2026, 4, 20, 8, 0))
    # Jump ahead 5 hours: cron hit 09, 10, 11, 12, 13 → due_count = 5.
    fired = chronos.tick(utc(2026, 4, 20, 13, 0))
    fired.size == 1 && chronos.missed_log.size == 1 &&
      chronos.missed_log.first.count == 4 &&
      chronos.missed_log.first.reason == 'skip_policy'
  end
end

assert 'catch_up_once: fires exactly once regardless of missed count' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 * * * *',
                    missed_policy: 'catch_up_once', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 0) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 0))
    fired = chronos.tick(utc(2026, 4, 20, 13, 0))
    fired.size == 1 && chronos.missed_log.size == 1 &&
      chronos.missed_log.first.count == 4
  end
end

assert 'catch_up_bounded: respects max_catch_up_runs cap' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 * * * *',
                    missed_policy: 'catch_up_bounded',
                    max_catch_up_runs: 3,
                    stale_after: '48h',
                    timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 0) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 0))
    # 5 missed hourly fires; cap = 3 → expect 3 fires + missed_log(count=2).
    fired = chronos.tick(utc(2026, 4, 20, 13, 0))
    fired.size == 3 && chronos.missed_log.size == 1 &&
      chronos.missed_log.first.count == 2
  end
end

assert 'catch_up_bounded: drops backlog older than stale_after' do
  Dir.mktmpdir do |root|
    # Seed state with a last_fire_at much older than stale_after.
    state_path = state_path_for(root)
    FileUtils.mkdir_p(File.dirname(state_path))
    File.write(state_path, YAML.dump(
      'schedules' => {
        's' => {
          'last_fire_at'      => utc(2026, 4, 15, 9, 0).iso8601,
          'last_evaluated_at' => utc(2026, 4, 15, 9, 0).iso8601
        }
      }
    ))
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path,
      schedules: [{ name: 's', cron: '0 9 * * *',
                    missed_policy: 'catch_up_bounded',
                    max_catch_up_runs: 10,
                    stale_after: '48h',
                    timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 15, 9, 0) }
    )
    # 5 days later → due_count ≈ 5 daily fires. Last fire was 5 days ago
    # which exceeds stale_after=48h → effective=1 (recovery marker).
    fired = chronos.tick(utc(2026, 4, 20, 10, 0))
    fired.size == 1 && chronos.stale_drops.size == 1 &&
      chronos.stale_drops.first.name == 's'
  end
end

assert_raises 'unknown missed_policy raises ArgumentError', ArgumentError do
  chronos = Chronos.new(
    schedules_path: '/nonexistent.yml',
    state_path:     Dir.mktmpdir + '/state.yml',
    schedules: [{ name: 's', cron: '0 * * * *',
                  missed_policy: 'bogus', timezone: 'UTC' }],
    clock: -> { utc(2026, 4, 20, 8, 0) }
  )
  chronos.tick(utc(2026, 4, 20, 8, 0)) # prime
  # The error is rescued at the per-schedule boundary and logged, so
  # we directly exercise the policy via send for the strict assertion.
  chronos.send(:apply_missed_policy,
               { name: 's', missed_policy: 'bogus' },
               1, utc(2026, 4, 20, 9, 0), nil, [])
end

# ---------------------------------------------------------------------------
# State: last_fire_at vs last_evaluated_at (CF-10)
# ---------------------------------------------------------------------------

section 'Chronos — state (CF-10 / CF-13)'

assert 'last_evaluated_at updated every tick, last_fire_at only on fire' do
  Dir.mktmpdir do |root|
    sp = state_path_for(root)
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     sp,
      schedules: [{ name: 's', cron: '0 9 * * *', missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 0) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 0))  # prime
    chronos.tick(utc(2026, 4, 20, 8, 30)) # no fire
    st1 = chronos.state_for('s').dup

    chronos.tick(utc(2026, 4, 20, 9, 0))  # fire
    st2 = chronos.state_for('s').dup

    st1['last_fire_at'].nil? &&
      !st1['last_evaluated_at'].nil? &&
      st2['last_fire_at'] == utc(2026, 4, 20, 9, 0).iso8601 &&
      st2['last_evaluated_at'] == utc(2026, 4, 20, 9, 0).iso8601
  end
end

assert 'state persisted to disk after fire (atomic tmp+rename)' do
  Dir.mktmpdir do |root|
    sp = state_path_for(root)
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     sp,
      schedules: [{ name: 's', cron: '0 * * * *', missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 59) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 59))
    chronos.tick(utc(2026, 4, 20, 9, 0))

    # File exists, no leftover .tmp sibling.
    file_ok  = File.exist?(sp)
    siblings = Dir.glob("#{sp}.tmp.*")
    raw      = YAML.safe_load(File.read(sp))
    state_ok = raw['schedules']['s']['last_fire_at'] ==
               utc(2026, 4, 20, 9, 0).iso8601

    file_ok && siblings.empty? && state_ok
  end
end

assert 'state recovery: reload from existing YAML preserves last_fire_at' do
  Dir.mktmpdir do |root|
    sp = state_path_for(root)
    FileUtils.mkdir_p(File.dirname(sp))
    File.write(sp, YAML.dump(
      'schedules' => {
        's' => {
          'last_fire_at'      => utc(2026, 4, 20, 8, 0).iso8601,
          'last_evaluated_at' => utc(2026, 4, 20, 8, 30).iso8601,
          'next_fire_at'      => utc(2026, 4, 20, 9, 0).iso8601
        }
      }
    ))
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     sp,
      schedules: [{ name: 's', cron: '0 9 * * *', missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 45) }
    )
    chronos.state_for('s')['last_fire_at'] == utc(2026, 4, 20, 8, 0).iso8601
  end
end

assert 'idle tick (no change) leaves existing file intact' do
  Dir.mktmpdir do |root|
    sp = state_path_for(root)
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     sp,
      schedules: [],  # no schedules → no state churn
      clock: -> { utc(2026, 4, 20, 8, 0) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 0))
    !File.exist?(sp) # no schedules → no write at all
  end
end

# ---------------------------------------------------------------------------
# Concurrency / enqueue_mandate
# ---------------------------------------------------------------------------

section 'Chronos — enqueue_mandate / concurrency'

assert 'concurrency=queue enqueues every fire' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 * * * *', missed_policy: 'skip',
                    concurrency: 'queue', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 59) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 59))
    fired = chronos.tick(utc(2026, 4, 20, 9, 0))
    result = chronos.enqueue_mandate(fired.first.to_h)
    result == :queued && chronos.queue.size == 1
  end
end

assert 'concurrency=reject blocks when same-name mandate is running' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 * * * *', missed_policy: 'skip',
                    concurrency: 'reject', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 59) }
    )
    chronos.register_running(id: 'm1', name: 's')
    chronos.tick(utc(2026, 4, 20, 8, 59))
    fired = chronos.tick(utc(2026, 4, 20, 9, 0))
    result = chronos.enqueue_mandate(fired.first.to_h)
    result == :rejected && chronos.queue.empty? &&
      chronos.rejection_log.size == 1
  end
end

assert 'concurrency=reject allows when no same-name mandate is running' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 * * * *', missed_policy: 'skip',
                    concurrency: 'reject', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 59) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 59))
    fired = chronos.tick(utc(2026, 4, 20, 9, 0))
    result = chronos.enqueue_mandate(fired.first.to_h)
    result == :queued && chronos.queue.size == 1
  end
end

assert 'pop_queued drains the queue FIFO' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 * * * *', missed_policy: 'skip',
                    concurrency: 'queue', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 59) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 59))
    fired = chronos.tick(utc(2026, 4, 20, 9, 0))
    chronos.enqueue_mandate(fired.first.to_h)
    chronos.enqueue_mandate(fired.first.to_h)
    m1 = chronos.pop_queued
    m2 = chronos.pop_queued
    m3 = chronos.pop_queued
    m1 && m2 && m3.nil? && chronos.queue.empty?
  end
end

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

section 'Chronos — edge cases'

assert 'boot after long downtime with skip: fires exactly once' do
  Dir.mktmpdir do |root|
    sp = state_path_for(root)
    # Pretend previous boot evaluated the schedule 30h ago.
    FileUtils.mkdir_p(File.dirname(sp))
    File.write(sp, YAML.dump(
      'schedules' => {
        's' => {
          'last_evaluated_at' => utc(2026, 4, 19, 3, 0).iso8601,
          'last_fire_at'      => utc(2026, 4, 19, 3, 0).iso8601
        }
      }
    ))
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     sp,
      schedules: [{ name: 's', cron: '0 * * * *', missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 9, 0) }
    )
    # Since prior last_evaluated_at is 30h ago and hourly cron ran ~30 times,
    # skip policy fires once and logs ~29 missed.
    fired = chronos.tick(utc(2026, 4, 20, 9, 0))
    fired.size == 1 && chronos.missed_log.size == 1 &&
      chronos.missed_log.first.count >= 28
  end
end

assert 'boot without prior state uses boot_time as baseline (no retro fires)' do
  Dir.mktmpdir do |root|
    sp = state_path_for(root)
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     sp,
      schedules: [{ name: 's', cron: '0 * * * *', missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 30) }
    )
    # First tick at 08:30 (same as boot_time). No prior dues. No fire expected
    # because the window (boot=08:30, now=08:30] is empty.
    fired = chronos.tick(utc(2026, 4, 20, 8, 30))
    fired.empty?
  end
end

assert 'schedules.yml is loaded from file when no inline schedules given' do
  Dir.mktmpdir do |root|
    path = write_schedules(root, [
      { name: 's', cron: '0 * * * *', missed_policy: 'skip',
        timezone: 'UTC', enabled: true }
    ])
    chronos = Chronos.new(
      schedules_path: path,
      state_path:     state_path_for(root),
      clock:          -> { utc(2026, 4, 20, 8, 59) }
    )
    chronos.schedules.size == 1 && chronos.schedules.first[:name] == 's'
  end
end

assert 'missing schedules.yml yields empty schedule list (no crash)' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'absent.yml'),
      state_path:     state_path_for(root),
      clock:          -> { utc(2026, 4, 20, 9, 0) }
    )
    chronos.schedules.empty? && chronos.tick(utc(2026, 4, 20, 9, 0)).empty?
  end
end

assert 'next_fire_at populated in state after evaluation' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [{ name: 's', cron: '0 9 * * *', missed_policy: 'skip', timezone: 'UTC' }],
      clock: -> { utc(2026, 4, 20, 8, 0) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 0))
    chronos.state_for('s')['next_fire_at'] == utc(2026, 4, 20, 9, 0).iso8601
  end
end

assert 'malformed cron in a schedule is reported, other schedules proceed' do
  Dir.mktmpdir do |root|
    chronos = Chronos.new(
      schedules_path: File.join(root, 'none.yml'),
      state_path:     state_path_for(root),
      schedules: [
        { name: 'bad', cron: 'not a cron', missed_policy: 'skip', timezone: 'UTC' },
        { name: 'good', cron: '0 * * * *', missed_policy: 'skip', timezone: 'UTC' }
      ],
      clock: -> { utc(2026, 4, 20, 8, 59) }
    )
    chronos.tick(utc(2026, 4, 20, 8, 59))
    fired = chronos.tick(utc(2026, 4, 20, 9, 0))
    fired.map(&:name) == ['good']
  end
end

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

puts
puts '=' * 60
puts "RESULTS: #{$pass} passed, #{$fail} failed"
puts '=' * 60
unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end
exit($fail.zero? ? 0 : 1)
