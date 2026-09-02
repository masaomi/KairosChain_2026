#!/usr/bin/env ruby
# frozen_string_literal: true

# Field defects D4 and D5 (2026-08-26, ledger: L2 agent_3_77_0_field_defects).
#
#   D4 — the delegated worker's watchdog killed healthy slow cycles at a fixed
#        1500 s and exited with exit!(124) writing nothing. Covered here:
#        the two-bound configuration (stall / hard cap, env-overridable), the
#        worker exit record round-trip, crash_detail's token matching and its
#        positive "no record" marker, and last_activity_time's exclusion of
#        heartbeat and lock files (counting heartbeats would blind the stall
#        bound: the heartbeat thread outlives a hung main thread).
#   D5 — a reviewer reply carrying several JSON blocks defeated the parser
#        (first parseable block had no overall_verdict). Covered here: the
#        candidate scan prefers the block that carries a String verdict, the
#        fallback reasons stay honest, and an unparseable reply is persisted
#        raw beside the session records.
#
# Second bundle (2026-09-02):
#   D5-b — the candidate scan walked back to the NEAREST '{' and counted
#          braces with no notion of strings, so a nested object before the key
#          or a brace inside a string value produced a decoy. Covered here with
#          the ledger's exact shapes, each paired with a fenced decoy so the
#          crude first-{…}-last fallback cannot mask the defect.
#   Holes — the D5 raw-save WIRING (run_persona_review → persist_raw_review),
#          the crash record actually carried into agent_wait / agent_status
#          payloads, the stale exit record cleared by a fresh open_handle, the
#          watchdog tick override, and env-touching tests restoring the ENV.
#   The worker PROCESS itself is exercised in test_agent_worker_process.rb.
#
# Reads the SHIPPED template copies, not the instance copies under .kairos.
# Usage: ruby test_agent_worker_exit_and_review_parse.rb

require 'minitest/autorun'
require 'minitest/mock'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'

$test_kairos_dir = Dir.mktmpdir('agent_worker_exit_test')

module Autoexec
  def self.loaded?
    true
  end
end

module KairosMcp
  def self.data_dir
    $test_kairos_dir
  end

  module Tools
    class BaseTool
      def text_content(text)
        text
      end
    end
  end
end

require File.expand_path('../autonomos/lib/autonomos', File.dirname(__dir__))
require_relative '../lib/agent/mandate_adapter'

$LOAD_PATH.unshift File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../autoexec/lib', __dir__)
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'
require_relative '../lib/agent'
require_relative '../tools/agent_step'
require_relative '../tools/agent_wait'
require_relative '../tools/agent_status'
require_relative '../lib/agent/step_delegation'

# Session.storage_path resolves through Autonomos when it responds to
# storage_path; pin it to the test dir so the real tools find real sessions.
module Autonomos
  def self.storage_path(subpath)
    path = File.join($test_kairos_dir, subpath)
    FileUtils.mkdir_p(path)
    path
  end
end

StepDelegation = KairosMcp::SkillSets::Agent::StepDelegation
AgentStepTool  = KairosMcp::SkillSets::Agent::Tools::AgentStep
AgentWaitTool  = KairosMcp::SkillSets::Agent::Tools::AgentWait
AgentStatusTool = KairosMcp::SkillSets::Agent::Tools::AgentStatus
AgentSession   = KairosMcp::SkillSets::Agent::Session

FakeSession = Struct.new(:session_dir)

# Sets ENV for the block and restores every touched key to its prior value
# (present or absent), so a test never leaks a knob into the rest of the run.
def with_env(pairs)
  saved = pairs.keys.to_h { |k| [k, ENV[k]] }
  pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  yield
ensure
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

class TestWorkerExitRecord < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('wx_')
    @delegation = StepDelegation.new(@dir)
    @identity = { 'step_token' => 'tok-1', 'issue_anchor' => '1:checkpoint:1' }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_write_and_read_round_trip
    @delegation.write_worker_exit(@identity, 'self_timeout_stalled',
                                  'elapsed_seconds' => 100, 'silent_seconds' => 90)
    rec = @delegation.worker_exit
    assert_equal 'self_timeout_stalled', rec['exit_class']
    assert_equal 'tok-1', rec['step_token']
    assert_equal 90, rec['silent_seconds']
    assert_equal Process.pid, rec['pid']
    refute_nil rec['timestamp']
  end

  def test_crash_detail_matches_token
    @delegation.write_worker_exit(@identity, 'superseded')
    assert_equal 'superseded', @delegation.crash_detail('tok-1')['exit_class']
  end

  def test_crash_detail_ignores_other_tokens_record
    @delegation.write_worker_exit(@identity, 'normal')
    detail = @delegation.crash_detail('tok-2')
    assert_equal 'no_record', detail['exit_class']
  end

  def test_crash_detail_without_any_record_is_positive_no_record
    detail = @delegation.crash_detail('tok-1')
    assert_equal 'no_record', detail['exit_class']
    assert_match(/without an exit record/, detail['note'])
  end

  def test_worker_exit_survives_nil_identity
    rec = @delegation.write_worker_exit(nil, 'bootstrap_failure')
    assert_equal 'bootstrap_failure', rec['exit_class']
    assert_nil rec['step_token']
  end

  # Second bundle, housekeeping: a fresh handle mints a new token, so the
  # previous worker's exit record is stale by construction and is removed.
  def test_fresh_open_handle_clears_the_previous_workers_exit_record
    @delegation.write_worker_exit({ 'step_token' => 'old-tok' }, 'self_timeout_stalled')
    refute_nil @delegation.worker_exit
    how, = @delegation.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    assert_equal :opened, how
    assert_nil @delegation.worker_exit
  end

  def test_rejoining_a_live_handle_keeps_its_record
    _how, tok = @delegation.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    @delegation.touch_heartbeat(tok)
    @delegation.write_worker_exit({ 'step_token' => tok }, 'trapped_signal', 'phase' => 'during_gated_call')
    how, tok2 = @delegation.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    assert_equal :existing, how
    assert_equal tok, tok2
    assert_equal 'trapped_signal', @delegation.worker_exit['exit_class']
  end
end

# Hole 3: the exit record must reach the OPERATOR through the two read
# surfaces, not just exist on disk. Real Session, real tools, real files.
class TestCrashRecordCarriedByTools < Minitest::Test
  def setup
    @sid = "crash_carry_#{SecureRandom.hex(4)}"
    ctx = KairosMcp::InvocationContext.new
    @session = AgentSession.new(session_id: @sid, mandate_id: 'm', goal_name: 'g',
                                invocation_context: ctx, config: {}, autonomous: false)
    @session.update_state('observed')
    @session.save
    @delegation = StepDelegation.new(@session.guard_dir)
    _how, @tok = @delegation.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    # Worker "died" after writing its record; its heartbeat went stale.
    @delegation.write_worker_exit({ 'step_token' => @tok, 'issue_anchor' => '0:observed:0' },
                                  'self_timeout_stalled', 'elapsed_seconds' => 3000, 'silent_seconds' => 2800)
    FileUtils.touch(File.join(@session.guard_dir, "delegation.heartbeat.#{@tok}"), mtime: Time.now - 60)
    assert_equal 'crashed', @delegation.status
  end

  def teardown
    FileUtils.remove_entry(@session.guard_dir) if File.directory?(@session.guard_dir)
  end

  def test_agent_status_payload_carries_the_exit_record
    out = JSON.parse(AgentStatusTool.new.call({ 'session_id' => @sid })[0][:text])
    assert_equal 'crashed', out.dig('delegation', 'status')
    assert_equal 'self_timeout_stalled', out.dig('delegation', 'worker_exit', 'exit_class')
    assert_equal 2800, out.dig('delegation', 'worker_exit', 'silent_seconds')
    assert_equal @tok, out.dig('delegation', 'worker_exit', 'step_token')
  end

  def test_agent_wait_crashed_payload_carries_the_exit_record
    out = JSON.parse(AgentWaitTool.new.call({ 'session_id' => @sid, 'max_wait_seconds' => 2 })[0][:text])
    assert_equal 'crashed', out['status']
    assert_equal 'self_timeout_stalled', out.dig('worker_exit', 'exit_class')
    assert_equal @tok, out.dig('worker_exit', 'step_token')
    assert_equal 'agent_status', out.dig('next_action', 'tool')
  end

  def test_a_record_for_another_token_reads_as_no_record
    @delegation.write_worker_exit({ 'step_token' => 'not-ours' }, 'normal')
    out = JSON.parse(AgentStatusTool.new.call({ 'session_id' => @sid })[0][:text])
    assert_equal 'no_record', out.dig('delegation', 'worker_exit', 'exit_class')
  end
end

class TestStallActivityClock < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('act_')
    @delegation = StepDelegation.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_heartbeats_and_locks_do_not_count_as_activity
    old = Time.now - 300
    content = File.join(@dir, 'progress.jsonl')
    File.write(content, 'x')
    File.utime(old, old, content)
    # Fresh liveness/locking artifacts that must NOT rejuvenate the clock.
    File.write(File.join(@dir, 'delegation.heartbeat.tok-1'), '')
    File.write(File.join(@dir, 'delegation.lock'), '')
    File.write(File.join(@dir, 'advance.lock'), '')

    assert_in_delta old.to_f, @delegation.last_activity_time.to_f, 5.0
  end

  def test_real_writes_do_count
    File.write(File.join(@dir, 'llm_snapshots.jsonl'), 'x')
    assert_in_delta Time.now.to_f, @delegation.last_activity_time.to_f, 5.0
  end

  # Impl review R1, I1: the worker's exit record (the D6 interim write in
  # particular) and its atomic-write temp file are not session activity.
  def test_worker_exit_record_and_its_tmp_do_not_count_as_activity
    old = Time.now - 300
    content = File.join(@dir, 'progress.jsonl')
    File.write(content, 'x')
    File.utime(old, old, content)
    @delegation.write_worker_exit({ 'step_token' => 'tok-1' }, 'trapped_signal', 'phase' => 'during_gated_call')
    File.write(File.join(@dir, "worker_exit.json.tmp.#{Process.pid}.123"), '{}')

    assert_in_delta old.to_f, @delegation.last_activity_time.to_f, 5.0
  end

  def test_empty_dir_falls_back_to_now
    assert_in_delta Time.now.to_f, @delegation.last_activity_time.to_f, 5.0
  end
end

class TestWatchdogBounds < Minitest::Test
  def test_defaults
    assert_equal 2700,  StepDelegation.worker_stall_seconds
    assert_equal 10_800, StepDelegation.worker_hard_cap_seconds
  end

  def test_env_overrides
    with_env('KAIROS_WORKER_STALL_SECONDS' => '60', 'KAIROS_WORKER_TIMEOUT_SECONDS' => '120') do
      assert_equal 60,  StepDelegation.worker_stall_seconds
      assert_equal 120, StepDelegation.worker_hard_cap_seconds
    end
  end

  # Both tests below start from a CLEARED knob (with_env(k => nil)) so an
  # ambient value in the shell that runs the suite cannot fail them.
  def test_env_overrides_restore_preexisting_values
    with_env('KAIROS_WORKER_STALL_SECONDS' => nil) do
      with_env('KAIROS_WORKER_STALL_SECONDS' => '7') do
        with_env('KAIROS_WORKER_STALL_SECONDS' => '60') do
          assert_equal 60, StepDelegation.worker_stall_seconds
        end
        assert_equal '7', ENV['KAIROS_WORKER_STALL_SECONDS'], 'inner block must restore, not delete'
      end
      assert_nil ENV['KAIROS_WORKER_STALL_SECONDS']
    end
  end

  def test_watchdog_tick_default_and_floor
    with_env('KAIROS_WORKER_WATCHDOG_TICK_SECONDS' => nil) do
      assert_equal 30, StepDelegation.worker_watchdog_tick_seconds
      with_env('KAIROS_WORKER_WATCHDOG_TICK_SECONDS' => '2') do
        assert_equal 2, StepDelegation.worker_watchdog_tick_seconds
      end
      with_env('KAIROS_WORKER_WATCHDOG_TICK_SECONDS' => '0') do
        assert_equal 1, StepDelegation.worker_watchdog_tick_seconds, 'floor is 1 s, never a busy loop'
      end
    end
  end

  def test_worker_script_parses
    script = File.expand_path('../bin/agent_step_worker.rb', __dir__)
    assert system(RbConfig.ruby, '-c', script, out: File::NULL, err: File::NULL),
           'agent_step_worker.rb must stay syntactically valid'
  end
end

class TestReviewParseHardening < Minitest::Test
  def setup
    @tool = AgentStepTool.allocate
  end

  def parse(content)
    @tool.send(:parse_persona_review, content)
  end

  def test_clean_json_still_parses
    r = parse('{"overall_verdict": "approve", "key_findings": []}')
    assert_equal 'APPROVE', r[:overall_verdict]
    refute r[:parse_error]
  end

  def test_verdict_found_past_a_decoy_json_block
    # D5 regression shape: the first parseable JSON block (echoed plan
    # fragment in a code fence) has no overall_verdict; the real verdict
    # object comes later in prose.
    content = <<~REPLY
      Looking at the plan first:
      ```json
      {"task_id": "t-99", "steps": [{"tool_name": "safe_file_read"}]}
      ```
      My assessment as a panel follows.
      {"overall_verdict": "revise", "key_findings": ["step 3 unclear"]}
    REPLY
    r = parse(content)
    assert_equal 'REVISE', r[:overall_verdict]
    assert_equal ['step 3 unclear'], r[:key_findings]
    refute r[:parse_error]
  end

  def test_hash_without_verdict_still_falls_back_honestly
    r = parse('{"verdict": "APPROVE"}')
    assert r[:parse_error]
    assert_match(/invalid overall_verdict type: NilClass/, r[:key_findings].first)
    assert_equal 'REVISE', r[:overall_verdict]
  end

  def test_no_json_at_all_falls_back
    r = parse('The plan looks fine to me, ship it.')
    assert r[:parse_error]
    assert_match(/no JSON found/, r[:key_findings].first)
  end

  def test_fenced_verdict_object_parses
    content = "verdict below\n```json\n{\"overall_verdict\": \"REJECT\"}\n```\n"
    assert_equal 'REJECT', parse(content)[:overall_verdict]
  end

  # ---- D5-b: the ledger's residual shapes ----
  # Each shape is paired with a fenced decoy (a valid JSON block with no
  # verdict) so that the crude first-{…}-last fallback spans prose and fails;
  # otherwise that fallback would mask the scanner defect.

  DECOY_FENCE = "Echoing the plan first:\n```json\n{\"task_id\": \"t-1\", \"steps\": []}\n```\n"

  def test_nested_object_before_the_verdict_key_is_not_a_decoy
    content = DECOY_FENCE +
              "Now my verdict as a panel:\n" \
              '{"summary": {"a": 1}, "overall_verdict": "APPROVE", "key_findings": []}' + "\n"
    r = parse(content)
    assert_equal 'APPROVE', r[:overall_verdict]
    assert_equal({ 'a' => 1 }, r[:summary])
    refute r[:parse_error]
  end

  def test_brace_inside_a_string_value_does_not_corrupt_the_depth_count
    content = DECOY_FENCE +
              "Panel verdict:\n" \
              '{"key_findings": ["step 3 uses {tool} without a check", "see } later"], ' \
              '"overall_verdict": "revise"}' + "\n"
    r = parse(content)
    # parse_error first: the fallback verdict is also REVISE, so the verdict
    # alone cannot tell a parsed reply from a failed one.
    refute r[:parse_error], r[:key_findings].inspect
    assert_equal 'REVISE', r[:overall_verdict]
    assert_equal 2, r[:key_findings].size
  end

  def test_decoy_object_carrying_a_non_string_verdict_loses_to_the_real_one
    content = DECOY_FENCE +
              "A fragment I am quoting: {\"overall_verdict\": {\"draft\": true}} — ignore it.\n" \
              "Final: {\"overall_verdict\": \"reject\", \"key_findings\": [\"no rollback\"]}\n"
    r = parse(content)
    assert_equal 'REJECT', r[:overall_verdict]
    assert_equal ['no rollback'], r[:key_findings]
  end

  def test_unbalanced_quote_in_prose_does_not_swallow_the_json_on_the_next_line
    content = DECOY_FENCE +
              "The tool is 5\" wide, which is fine.\n" \
              "{\"overall_verdict\": \"approve\"}\n"
    assert_equal 'APPROVE', parse(content)[:overall_verdict]
  end

  # ---- impl review R1: I4 (nested verdicts) and I6 (same-line odd quote) ----

  # I4 — the persona-block shape. Per-persona objects each carry their own
  # overall_verdict; the panel verdict is the top-level one. Both main's
  # nearest-brace walk-back and the first D5-b scan (innermost first, text
  # order) picked a persona's verdict. Depth-ascending order picks the panel's.
  def test_top_level_verdict_beats_per_persona_verdicts
    content = DECOY_FENCE +
              "Panel verdict:\n" \
              '{"personas": {"pragmatic": {"overall_verdict": "approve"}, ' \
              '"security": {"overall_verdict": "reject"}}, ' \
              '"overall_verdict": "reject", "key_findings": ["no rollback"]}' + "\n"
    r = parse(content)
    assert_equal 'REJECT', r[:overall_verdict]
    assert_equal ['no rollback'], r[:key_findings]
    refute r[:parse_error]
  end

  def test_top_level_verdict_beats_a_nested_summary_verdict
    content = DECOY_FENCE +
              "Verdict:\n" \
              '{"summary": {"overall_verdict": "n/a"}, "overall_verdict": "REJECT", "key_findings": []}' + "\n"
    r = parse(content)
    assert_equal 'REJECT', r[:overall_verdict]
    refute r[:parse_error]
  end

  # I6 — an odd quote on the SAME line as the JSON. The string-aware scan
  # reads `" wide: {"` as a string, so no span encloses the key; main's
  # nearest-brace walk-back parsed this shape, so it is kept as the candidate
  # of last resort for exactly that case (coverage stays a superset of main).
  def test_same_line_unbalanced_quote_before_the_json_still_parses
    content = DECOY_FENCE +
              "The tool is 5\" wide: {\"overall_verdict\": \"approve\"}\n"
    r = parse(content)
    assert_equal 'APPROVE', r[:overall_verdict]
    refute r[:parse_error]
  end

  # Pins the "encloses the key" half of the span predicate (the mutant that
  # survived R1: `open_at < key_at` alone). Prose in front forces the scan
  # path; the sibling object {"a": 1} opens before the key but closes before
  # it too, so it must not be offered as a candidate at all.
  def test_candidates_exclude_a_sibling_object_that_closes_before_the_key
    outer = '{"summary": {"a": 1}, "overall_verdict": "APPROVE"}'
    candidates = @tool.send(:extract_json_candidates, "Verdict: #{outer}")
    assert_includes candidates, outer
    refute_includes candidates, '{"a": 1}'
  end

  def test_balanced_object_spans_ignore_braces_inside_strings
    src = '{"a": "}{", "b": {"c": "\\"{"}}' # 30 chars; braces at 7, 8 and 26 sit inside strings
    spans = @tool.send(:balanced_object_spans, src)
    # inner {"c": …} and the outer object; the braces inside strings yield no span
    assert_equal [[17, 28], [0, 29]], spans
    assert_equal src.length - 1, spans.last[1]
  end

  def test_persist_raw_review_writes_capped_file
    Dir.mktmpdir('raw_') do |dir|
      session = FakeSession.new(dir)
      path = @tool.send(:persist_raw_review, session, 'a' * 70_000)
      refute_nil path
      assert File.exist?(path)
      assert_equal 65_536, File.size(path)
      assert File.basename(path).start_with?('review_raw_')
    end
  end

  def test_persist_raw_review_nil_content_is_nil
    assert_nil @tool.send(:persist_raw_review, FakeSession.new('/tmp'), nil)
  end

  def test_norm_g_present
    norms = @tool.send(:permission_norms)
    assert_match(/\(g\)/, norms)
    assert_match(/finished text/, norms)
  end
end

# Hole 4: the D5 raw-save WIRING. Drives the real run_persona_review with the
# LLM loop replaced, so the seam "parse failed → persist_raw_review → path in
# key_findings" is exercised end to end rather than method by method.
class TestReviewRawSaveWiring < Minitest::Test
  WiringSession = Struct.new(:session_dir, :config)
  FakeReviewLoop = Struct.new(:content) do
    def run_phase(*)
      { 'content' => content }
    end

    def total_calls
      1
    end
  end

  class WiringStep < AgentStepTool
    def load_persona_definitions(_personas, _session)
      []
    end

    def build_persona_review_prompt(*)
      'prompt'
    end

    def persona_review_system_prompt
      'system'
    end
  end

  def run_review(reply)
    Dir.mktmpdir('wire_') do |dir|
      session = WiringSession.new(dir, { 'complexity_review' => { 'personas' => ['pragmatic'] } })
      tool = WiringStep.allocate
      loop_double = FakeReviewLoop.new(reply)
      result = KairosMcp::SkillSets::Agent::CognitiveLoop.stub(:new, loop_double) do
        tool.send(:run_persona_review, session, { 'summary' => 'x' }, { signals: [] })
      end
      yield result, Dir.glob(File.join(dir, 'review_raw_*.txt'))
    end
  end

  def test_unparseable_reply_is_persisted_and_its_path_reported
    reply = 'I read the plan twice; it looks fine to me, ship it.'
    run_review(reply) do |result, raw_files|
      assert result[:parse_error]
      assert_equal 1, raw_files.size
      assert_equal reply, File.read(raw_files.first)
      assert(result[:key_findings].any? { |f| f == "raw reviewer reply saved: #{raw_files.first}" },
             "key_findings must point at the raw file: #{result[:key_findings].inspect}")
      assert_equal 1, result[:llm_calls]
    end
  end

  def test_parseable_reply_leaves_no_raw_file
    run_review('{"overall_verdict": "approve", "key_findings": []}') do |result, raw_files|
      refute result[:parse_error]
      assert_empty raw_files
      assert_equal 'APPROVE', result[:overall_verdict]
    end
  end
end
