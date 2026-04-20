#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for P2.3: WAL writer + recovery + Canonical + IdempotencyCheck.
#
# Usage:
#   ruby KairosChain_mcp_server/test_wal.rb
#
# Design reference: docs v0.2 §5 (WAL) and §3.3 (recovery).
#
# The tests cover:
#   * file creation and parent-directory fsync invariants
#   * plan_commit / append / transition JSON-line format
#   * step lifecycle (pending → executing → completed | failed | needs_review)
#   * plans_not_finalized / finalize_plan behaviour
#   * archive (gzip + remove original)
#   * Canonical canonicalization / deterministic serialization
#   * IdempotencyCheck verdicts across the five decision branches
#   * multi-plan mandates (cross-cycle state)
#   * crash-then-recover scenarios using torn-line and interrupted-step cases
#   * concurrent write safety (mutex)
#
# Tests use Dir.mktmpdir for filesystem isolation — no state leaks to .kairos/.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'
require 'zlib'
require 'thread'

require 'kairos_mcp/daemon/canonical'
require 'kairos_mcp/daemon/wal'
require 'kairos_mcp/daemon/idempotency_check'

Canonical        = KairosMcp::Daemon::Canonical
WAL              = KairosMcp::Daemon::WAL
IdempotencyCheck = KairosMcp::Daemon::IdempotencyCheck

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

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

def wal_path(root, mandate_id = 'm_test')
  File.join(root, '.kairos', 'wal', "#{mandate_id}.wal.jsonl")
end

def read_lines(path)
  File.readlines(path).map(&:strip).reject(&:empty?)
end

def parse_lines(path)
  read_lines(path).map { |l| JSON.parse(l) }
end

def sample_step(step_id: 'c000_s000', tool: 'safe_file_write',
                params_hash: 'sha256-aaaa', pre_hash: 'sha256-pre',
                expected_post_hash: 'sha256-post')
  {
    step_id: step_id,
    tool: tool,
    params_hash: params_hash,
    pre_hash: pre_hash,
    expected_post_hash: expected_post_hash
  }
end

# ---------------------------------------------------------------------------
# Canonical tests
# ---------------------------------------------------------------------------

section 'Canonical — strip_volatile / deep_sort / serialize'

assert 'strip_volatile removes top-level volatile keys' do
  out = Canonical.strip_volatile({ 'ts' => 't', 'timestamp' => 't', 'request_id' => 'r',
                                   'trace_id' => 'x', 'nonce' => 'n', 'keep' => 1 })
  out == { 'keep' => 1 }
end

assert 'strip_volatile removes nested volatile keys' do
  input = { 'a' => { 'ts' => 'x', 'keep' => 2 }, 'b' => [{ 'nonce' => 'n', 'k' => 3 }] }
  Canonical.strip_volatile(input) == { 'a' => { 'keep' => 2 }, 'b' => [{ 'k' => 3 }] }
end

assert 'strip_volatile treats symbol and string keys uniformly' do
  out = Canonical.strip_volatile({ ts: 1, 'timestamp' => 2, keep: 3 })
  out.keys.map(&:to_s).sort == ['keep']
end

assert 'deep_sort orders Hash keys by stringified form, recursively' do
  input = { 'b' => 1, 'a' => { 'y' => 1, 'x' => 2 } }
  sorted = Canonical.deep_sort(input)
  sorted.keys == %w[a b] && sorted['a'].keys == %w[x y]
end

assert 'deep_sort preserves Array order' do
  Canonical.deep_sort({ 'k' => [3, 1, 2] })['k'] == [3, 1, 2]
end

assert 'serialize is deterministic across equivalent inputs (key order)' do
  a = Canonical.serialize({ 'x' => 1, 'a' => 2 })
  b = Canonical.serialize({ 'a' => 2, 'x' => 1 })
  a == b && a == '{"a":2,"x":1}'
end

assert 'serialize strips volatile keys before hashing' do
  a = Canonical.serialize({ 'x' => 1, 'ts' => 'now' })
  b = Canonical.serialize({ 'x' => 1 })
  a == b
end

assert 'sha256_json is prefixed and deterministic' do
  h1 = Canonical.sha256_json({ 'x' => 1 })
  h2 = Canonical.sha256_json({ 'x' => 1 })
  h1 == h2 && h1.start_with?('sha256-') && h1.length > 'sha256-'.length
end

assert 'sha256_json differs for different payloads' do
  Canonical.sha256_json({ 'x' => 1 }) != Canonical.sha256_json({ 'x' => 2 })
end

# ---------------------------------------------------------------------------
# WAL basic writes
# ---------------------------------------------------------------------------

section 'WAL — file creation, plan_commit, step lifecycle'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)

  assert 'WAL.open creates the .kairos/wal directory' do
    Dir.exist?(File.dirname(path))
  end

  assert 'WAL.open creates the WAL file' do
    File.exist?(path)
  end

  assert 'WAL.open on existing file does not truncate' do
    wal.append_pending(step_id: 's1', plan_id: 'p1', idem_key: 'k')
    before = File.size(path)
    wal.close
    wal2 = WAL.open(path: path)
    wal2.append_pending(step_id: 's2', plan_id: 'p1', idem_key: 'k2')
    wal2.close
    File.size(path) > before
  end
end

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)

  wal.commit_plan(
    plan_id: 'p_c000', mandate_id: 'm_test', cycle: 0,
    steps: [sample_step(step_id: 'c000_s000'), sample_step(step_id: 'c000_s001',
                                                           params_hash: 'sha256-bbb')]
  )

  lines = parse_lines(path)
  assert 'plan_commit writes one JSON line' do
    lines.size == 1
  end

  assert 'plan_commit entry has op, plan_id, mandate_id, cycle, plan_hash, steps' do
    e = lines.first
    e['op'] == 'plan_commit' && e['plan_id'] == 'p_c000' &&
      e['mandate_id'] == 'm_test' && e['cycle'] == 0 &&
      e['plan_hash']&.start_with?('sha256-') &&
      e['steps'].is_a?(Array) && e['steps'].size == 2
  end

  assert 'plan_commit timestamps entry with ISO-8601 UTC' do
    Time.iso8601(lines.first['ts']).utc? rescue false
  end

  wal.append_pending(step_id: 'c000_s000', plan_id: 'p_c000', idem_key: 'ik-1')
  wal.mark_executing('c000_s000', pre_hash: 'sha256-actualpre')
  wal.mark_completed('c000_s000', post_hash: 'sha256-actualpost',
                     result_hash: 'sha256-res')

  lines = parse_lines(path)
  assert 'step lifecycle writes 4 lines (plan_commit + pending + executing + completed)' do
    lines.size == 4
  end

  assert 'pending entry uses op=append and status=pending' do
    e = lines[1]
    e['op'] == 'append' && e['status'] == 'pending' && e['idem_key'] == 'ik-1'
  end

  assert 'executing entry uses op=transition and carries pre_hash' do
    e = lines[2]
    e['op'] == 'transition' && e['status'] == 'executing' &&
      e['pre_hash'] == 'sha256-actualpre'
  end

  assert 'completed entry carries post_hash and result_hash' do
    e = lines[3]
    e['op'] == 'transition' && e['status'] == 'completed' &&
      e['post_hash'] == 'sha256-actualpost' && e['result_hash'] == 'sha256-res'
  end

  wal.close
end

# ---------------------------------------------------------------------------
# WAL — failure and needs-review paths
# ---------------------------------------------------------------------------

section 'WAL — failure, needs_review, reset_to_pending, plan_finalize'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)

  wal.commit_plan(plan_id: 'p_c000', mandate_id: 'm_f', cycle: 0,
                  steps: [sample_step])
  wal.append_pending(step_id: 'c000_s000', plan_id: 'p_c000', idem_key: 'ik')
  wal.mark_executing('c000_s000', pre_hash: 'sha256-pre')
  wal.mark_failed('c000_s000', error_class: 'RuntimeError', error_msg: 'boom ' * 300)

  lines = parse_lines(path)
  assert 'mark_failed status=failed with error_class recorded' do
    e = lines.last
    e['op'] == 'transition' && e['status'] == 'failed' &&
      e['error_class'] == 'RuntimeError'
  end

  assert 'mark_failed truncates error_msg to 500 bytes' do
    lines.last['error_msg'].length <= 500
  end

  wal.mark_needs_review('c000_s000', reason: 'divergent_state')
  assert 'mark_needs_review records status=needs_review with reason' do
    e = parse_lines(path).last
    e['status'] == 'needs_review' && e['reason'] == 'divergent_state'
  end

  wal.mark_reset_to_pending('c000_s000')
  assert 'mark_reset_to_pending records status=pending and reset=true' do
    e = parse_lines(path).last
    e['status'] == 'pending' && e['reset'] == true
  end

  wal.finalize_plan('p_c000', status: 'succeeded')
  assert 'finalize_plan writes op=plan_finalize with status' do
    e = parse_lines(path).last
    e['op'] == 'plan_finalize' && e['status'] == 'succeeded' &&
      e['plan_id'] == 'p_c000'
  end

  wal.close
end

# ---------------------------------------------------------------------------
# WAL — recovery / plans_not_finalized
# ---------------------------------------------------------------------------

section 'WAL — plans_not_finalized / recovery'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)

  # Plan 1 — fully completed & finalized.
  wal.commit_plan(plan_id: 'p_c000', mandate_id: 'm_r', cycle: 0,
                  steps: [sample_step(step_id: 'c000_s000')])
  wal.append_pending(step_id: 'c000_s000', plan_id: 'p_c000', idem_key: 'ik-a')
  wal.mark_executing('c000_s000', pre_hash: 'sha256-pre')
  wal.mark_completed('c000_s000', post_hash: 'sha256-post',
                     result_hash: 'sha256-r')
  wal.finalize_plan('p_c000', status: 'succeeded')

  # Plan 2 — interrupted mid-step (no finalize).
  wal.commit_plan(plan_id: 'p_c001', mandate_id: 'm_r', cycle: 1,
                  steps: [sample_step(step_id: 'c001_s000'),
                          sample_step(step_id: 'c001_s001',
                                      params_hash: 'sha256-bbb')])
  wal.append_pending(step_id: 'c001_s000', plan_id: 'p_c001', idem_key: 'ik-b')
  wal.mark_executing('c001_s000', pre_hash: 'sha256-pre2')
  # CRASH here — no completed, no finalize.

  wal.close

  wal2 = WAL.open(path: path)
  pending = wal2.plans_not_finalized

  assert 'plans_not_finalized returns exactly the unfinalized plan' do
    pending.size == 1 && pending.first.plan_id == 'p_c001'
  end

  assert 'plans_not_finalized carries step state rebuilt from WAL' do
    step = pending.first.steps.find { |s| s.step_id == 'c001_s000' }
    step.status == 'executing' && step.observed_pre_hash == 'sha256-pre2'
  end

  assert 'plans_not_finalized includes not-yet-started steps as non-finalized' do
    step = pending.first.steps.find { |s| s.step_id == 'c001_s001' }
    !step.finalized?
  end

  assert 'plans returns all plans including finalized ones' do
    all = wal2.plans
    all.size == 2 && all.any? { |p| p.finalized } && all.any? { |p| !p.finalized }
  end

  wal2.close
end

# ---------------------------------------------------------------------------
# WAL — archive
# ---------------------------------------------------------------------------

section 'WAL — archive (gzip + remove original)'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)
  wal.commit_plan(plan_id: 'p_c000', mandate_id: 'm_a', cycle: 0,
                  steps: [sample_step])
  wal.finalize_plan('p_c000', status: 'succeeded')

  dest = wal.archive

  assert 'archive returns the .gz path' do
    dest == "#{path}.gz" && File.exist?(dest)
  end

  assert 'archive removes the original WAL file' do
    !File.exist?(path)
  end

  assert 'archive produces a readable gzip with the original content' do
    decompressed = Zlib::GzipReader.open(dest, &:read)
    parsed = decompressed.each_line.map { |l| JSON.parse(l) }
    parsed.first['op'] == 'plan_commit' && parsed.last['op'] == 'plan_finalize'
  end
end

# ---------------------------------------------------------------------------
# WAL — torn-line tolerance (simulated crash)
# ---------------------------------------------------------------------------

section 'WAL — torn-line tolerance'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)
  wal.commit_plan(plan_id: 'p_c000', mandate_id: 'm_t', cycle: 0,
                  steps: [sample_step])
  wal.close

  # Append a torn half-line as a crash would leave it.
  File.open(path, 'a') { |f| f.write('{"op":"transition","step_id":"c000') }

  wal2 = WAL.open(path: path)
  plans = wal2.plans
  assert 'parser ignores torn tail line instead of aborting' do
    plans.size == 1 && plans.first.steps.size == 1
  end
  wal2.close
end

# ---------------------------------------------------------------------------
# WAL — empty WAL recovery
# ---------------------------------------------------------------------------

section 'WAL — empty file recovery'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)
  assert 'plans_not_finalized on empty WAL returns []' do
    wal.plans_not_finalized == []
  end
  assert 'plans on empty WAL returns []' do
    wal.plans == []
  end
  wal.close
end

# ---------------------------------------------------------------------------
# WAL — concurrent write safety
# ---------------------------------------------------------------------------

section 'WAL — concurrent write safety (mutex)'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)
  wal.commit_plan(plan_id: 'p_c000', mandate_id: 'm_c', cycle: 0,
                  steps: (0...20).map { |i| sample_step(step_id: format('c000_s%03d', i)) })

  threads = (0...20).map do |i|
    Thread.new do
      10.times do |j|
        wal.append_pending(step_id: format('c000_s%03d', i),
                           plan_id: 'p_c000',
                           idem_key: "ik-#{i}-#{j}")
      end
    end
  end
  threads.each(&:join)
  wal.close

  lines = read_lines(path)
  assert 'all concurrent writes land as complete JSON lines (no torn interleaving)' do
    # plan_commit + 20 threads × 10 appends = 201
    lines.size == 201 && lines.all? { |l| JSON.parse(l); true rescue false }
  end
end

# ---------------------------------------------------------------------------
# WAL — write after close must fail
# ---------------------------------------------------------------------------

section 'WAL — safety: write after close'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)
  wal.close
  begin
    wal.append_pending(step_id: 'x', plan_id: 'p', idem_key: 'k')
    ok = false
  rescue IOError
    ok = true
  end
  assert 'append on a closed WAL raises IOError' do
    ok
  end
end

# ---------------------------------------------------------------------------
# IdempotencyCheck tests
# ---------------------------------------------------------------------------

section 'IdempotencyCheck — verdict branches'

# Branch 1: WAL already recorded completion (post_hash present).
done_step = WAL::StepEntry.new(
  step_id: 's1', plan_id: 'p1', tool: 't', params_hash: 'ph',
  pre_hash: 'pre', expected_post_hash: 'post',
  observed_pre_hash: 'pre', post_hash: 'post', result_hash: 'r',
  status: 'completed'
)
assert 'verify returns :already_done when WAL recorded post_hash' do
  v = IdempotencyCheck.verify(done_step)
  v.kind == :already_done && v.post_hash == 'post' &&
    v.evidence[:reason] == 'wal_recorded_completion'
end

# Branch 2: current world matches expected_post_hash.
maybe_done_step = WAL::StepEntry.new(
  step_id: 's1', plan_id: 'p1', tool: 't', params_hash: 'ph',
  pre_hash: 'pre', expected_post_hash: 'post-exp',
  observed_pre_hash: 'pre', status: 'executing'
)
assert 'verify returns :already_done when current state matches expected_post_hash' do
  v = IdempotencyCheck.verify(maybe_done_step, current_post_hash: 'post-exp')
  v.kind == :already_done &&
    v.evidence[:reason] == 'current_state_matches_expected_post'
end

# Branch 3: never reached executing — pending.
never_started = WAL::StepEntry.new(
  step_id: 's1', plan_id: 'p1', tool: 't', params_hash: 'ph',
  pre_hash: 'pre', expected_post_hash: 'post',
  status: 'pending'
)
assert 'verify returns :safe_to_retry when step never reached executing' do
  v = IdempotencyCheck.verify(never_started)
  v.kind == :safe_to_retry && v.evidence[:reason] == 'never_reached_executing'
end

# Branch 4: current pre_hash matches expected pre_hash (world unchanged).
interrupted_but_unchanged = WAL::StepEntry.new(
  step_id: 's1', plan_id: 'p1', tool: 't', params_hash: 'ph',
  pre_hash: 'pre', expected_post_hash: 'post',
  observed_pre_hash: 'pre', status: 'executing'
)
assert 'verify returns :safe_to_retry when current_pre_hash matches expected pre_hash' do
  v = IdempotencyCheck.verify(interrupted_but_unchanged, current_pre_hash: 'pre')
  v.kind == :safe_to_retry &&
    v.evidence[:reason] == 'current_pre_matches_expected'
end

# Branch 5: ambiguous — executing with divergent state.
ambiguous = WAL::StepEntry.new(
  step_id: 's1', plan_id: 'p1', tool: 't', params_hash: 'ph',
  pre_hash: 'pre', expected_post_hash: 'post',
  observed_pre_hash: 'pre', status: 'executing'
)
assert 'verify returns :manual_review when state is divergent and status=executing' do
  v = IdempotencyCheck.verify(ambiguous,
                              current_pre_hash: 'sha256-other',
                              current_post_hash: 'sha256-other')
  v.kind == :manual_review &&
    v.evidence[:reason] == 'interrupted_during_execution'
end

# Priority: WAL completion beats current-state heuristics.
conflicting = WAL::StepEntry.new(
  step_id: 's1', plan_id: 'p1', tool: 't', params_hash: 'ph',
  pre_hash: 'pre', expected_post_hash: 'post',
  observed_pre_hash: 'pre', post_hash: 'post', result_hash: 'r',
  status: 'completed'
)
assert 'WAL-recorded completion takes priority over current_* inputs' do
  v = IdempotencyCheck.verify(conflicting,
                              current_pre_hash: 'pre',
                              current_post_hash: 'different')
  v.kind == :already_done
end

assert 'verify kind is always one of the three documented values' do
  IdempotencyCheck::VALID_KINDS ==
    %i[already_done safe_to_retry manual_review]
end

# ---------------------------------------------------------------------------
# End-to-end: crash mid-step then recover
# ---------------------------------------------------------------------------

section 'End-to-end — crash mid-step + WAL-guided recovery'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)

  # DECIDE: commit plan.
  wal.commit_plan(plan_id: 'p_c000', mandate_id: 'm_e2e', cycle: 0,
                  steps: [sample_step(step_id: 'c000_s000',
                                      pre_hash: 'sha256-pre',
                                      expected_post_hash: 'sha256-post')])
  # ACT: pending + executing.
  wal.append_pending(step_id: 'c000_s000', plan_id: 'p_c000',
                     idem_key: 'm_e2e:0:c000_s000:sha256-aaaa')
  wal.mark_executing('c000_s000', pre_hash: 'sha256-pre')
  # CRASH here.
  wal.close

  # Recovery loop:
  recovered = WAL.open(path: path)
  orphans = recovered.plans_not_finalized
  assert 'recovery sees one orphan plan' do
    orphans.size == 1
  end

  step = orphans.first.steps.first
  # Assume the filesystem still shows the pre-state (tool did not run).
  verdict = IdempotencyCheck.verify(step, current_pre_hash: 'sha256-pre')
  assert 'recovery verdict for unstarted side-effect step is :safe_to_retry' do
    verdict.kind == :safe_to_retry
  end

  recovered.mark_reset_to_pending('c000_s000')
  # Re-execute and complete:
  recovered.mark_executing('c000_s000', pre_hash: 'sha256-pre')
  recovered.mark_completed('c000_s000', post_hash: 'sha256-post',
                           result_hash: 'sha256-res', recovered: true)
  recovered.finalize_plan('p_c000', status: 'succeeded')
  recovered.close

  final = WAL.open(path: path)
  assert 'after recovery, plans_not_finalized is empty' do
    final.plans_not_finalized.empty?
  end
  completed_entries = parse_lines(path).select do |e|
    e['op'] == 'transition' && e['status'] == 'completed' && e['recovered']
  end
  assert 'completed entry is tagged recovered:true' do
    completed_entries.size == 1
  end
  final.close
end

# ---------------------------------------------------------------------------
# Multi-cycle mandate
# ---------------------------------------------------------------------------

section 'WAL — multi-cycle mandate (several plans in one file)'

Dir.mktmpdir do |root|
  path = wal_path(root)
  wal = WAL.open(path: path)
  3.times do |cycle|
    plan_id = "p_c#{cycle.to_s.rjust(3, '0')}"
    wal.commit_plan(plan_id: plan_id, mandate_id: 'm_multi', cycle: cycle,
                    steps: [sample_step(step_id: "#{plan_id}_s000")])
    wal.finalize_plan(plan_id, status: 'succeeded')
  end
  # One extra, still open:
  wal.commit_plan(plan_id: 'p_c003', mandate_id: 'm_multi', cycle: 3,
                  steps: [sample_step(step_id: 'p_c003_s000')])
  wal.close

  reopened = WAL.open(path: path)
  all = reopened.plans
  pending = reopened.plans_not_finalized

  assert 'plans returns 4 plans across multiple cycles' do
    all.size == 4 && all.map(&:cycle).sort == [0, 1, 2, 3]
  end

  assert 'plans_not_finalized returns only the open plan' do
    pending.size == 1 && pending.first.plan_id == 'p_c003'
  end

  reopened.close
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

puts
puts '=' * 60
puts "Result: #{$pass} passed, #{$fail} failed"
puts '=' * 60
unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end
exit($fail.zero? ? 0 : 1)
