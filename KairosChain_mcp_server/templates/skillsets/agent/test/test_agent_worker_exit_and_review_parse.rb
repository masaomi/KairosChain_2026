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
# Reads the SHIPPED template copies, not the instance copies under .kairos.
# Usage: ruby test_agent_worker_exit_and_review_parse.rb

require 'minitest/autorun'
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
require_relative '../lib/agent/step_delegation'

StepDelegation = KairosMcp::SkillSets::Agent::StepDelegation
AgentStepTool  = KairosMcp::SkillSets::Agent::Tools::AgentStep

FakeSession = Struct.new(:session_dir)

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
    ENV['KAIROS_WORKER_STALL_SECONDS'] = '60'
    ENV['KAIROS_WORKER_TIMEOUT_SECONDS'] = '120'
    assert_equal 60,  StepDelegation.worker_stall_seconds
    assert_equal 120, StepDelegation.worker_hard_cap_seconds
  ensure
    ENV.delete('KAIROS_WORKER_STALL_SECONDS')
    ENV.delete('KAIROS_WORKER_TIMEOUT_SECONDS')
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
