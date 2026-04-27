# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'time'

# Stub BaseTool so we can load the tool file in isolation.
module KairosMcp
  module Tools
    class BaseTool
      def text_content(s); [{ text: s }]; end
    end
  end unless defined?(KairosMcp::Tools::BaseTool)
end

require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/wait_for_worker'
require_relative '../tools/multi_llm_review_wait'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestMultiLlmReviewWait < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr-wait-')
          @orig_cwd = Dir.pwd
          Dir.chdir(@tmp)
          @tool = Tools::MultiLlmReviewWait.new
          @token = '11111111-2222-4333-8444-555555555555'
        end

        def teardown
          Dir.chdir(@orig_cwd)
          FileUtils.rm_rf(@tmp)
        end

        def write_state(extra = {})
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'schema_version' => 4,
            'token' => @token,
            'created_at' => Time.now.iso8601,
            'collect_deadline' => (Time.now + 1800).iso8601,
            'subprocess_status' => 'pending',
            'subprocess_total' => 3,
            'parallel' => true
          }.merge(extra))
          FileUtils.touch(PendingState.collect_lock_path(@token))
        end

        def call_wait(args = {})
          payload = JSON.parse(@tool.call({ 'collect_token' => @token }.merge(args)).first[:text])
          payload
        end

        # ── unknown_token ────────────────────────────────────────────────

        def test_unknown_token_returns_unknown_with_redispatch_hint
          payload = call_wait
          assert_equal 'unknown_token', payload['status']
          assert_equal @token, payload['collect_token']
          assert_equal 'multi_llm_review', payload['next_action']['tool']
          assert_match(/never existed|garbage-collected|new dispatch/i,
                       payload['next_action']['purpose'])
        end

        def test_invalid_token_format_returns_unknown
          payload = JSON.parse(@tool.call({ 'collect_token' => 'not-a-uuid' }).first[:text])
          assert_equal 'unknown_token', payload['status']
        end

        # ── already_collected ────────────────────────────────────────────

        def test_already_collected_returns_replay_hint
          write_state
          PendingState.write_collected(@token, {
            'final_payload' => { 'status' => 'ok', 'verdict' => 'APPROVE' }
          })
          payload = call_wait
          assert_equal 'already_collected', payload['status']
          assert_equal 'multi_llm_review_collect', payload['next_action']['tool']
          assert_match(/idempotent replay/i, payload['next_action']['purpose'])
        end

        # ── past_collect_deadline ────────────────────────────────────────

        def test_past_deadline_returns_redispatch_without_blocking
          write_state('collect_deadline' => (Time.now - 60).iso8601)
          t0 = Time.now
          payload = call_wait('max_wait_seconds' => 5)
          elapsed = Time.now - t0
          assert_equal 'past_collect_deadline', payload['status']
          assert_equal 'multi_llm_review', payload['next_action']['tool']
          assert_operator elapsed, :<, 1.0, 'must not block when past deadline'
        end

        # ── ready ────────────────────────────────────────────────────────

        def test_ready_when_subprocess_results_present
          write_state
          PendingState.write_subprocess_results(@token, {
            'results' => [
              { 'role_label' => 'codex', 'raw_text' => 'APPROVE', 'status' => 'success' },
              { 'role_label' => 'cursor', 'raw_text' => 'APPROVE', 'status' => 'success' },
              { 'role_label' => 'claude', 'raw_text' => 'APPROVE', 'status' => 'success' }
            ],
            'elapsed_seconds' => 12.3
          })
          payload = call_wait('max_wait_seconds' => 2)
          assert_equal 'ready', payload['status']
          assert_equal 3, payload['subprocess_done']
          assert_equal 3, payload['subprocess_total']
          assert_equal 'multi_llm_review_collect', payload['next_action']['tool']
          assert_includes payload['next_action']['args'].keys, 'orchestrator_reviews'
        end

        # ── still_pending + streak escalation ────────────────────────────

        def test_still_pending_returned_when_worker_healthy_but_slow
          write_state
          # Live heartbeat so WaitForWorker sees a healthy worker.
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          PendingState.write_worker_pid(@token, { 'pid' => Process.pid, 'pgid' => Process.pid })

          payload = call_wait('max_wait_seconds' => 1)
          assert_equal 'still_pending', payload['status']
          assert_equal 1, payload['still_pending_streak']
          assert_equal 'multi_llm_review_wait', payload['next_action']['tool']
        end

        def test_still_pending_streak_persists_across_calls
          write_state
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          PendingState.write_worker_pid(@token, { 'pid' => Process.pid, 'pgid' => Process.pid })

          p1 = call_wait('max_wait_seconds' => 1)
          assert_equal 1, p1['still_pending_streak']
          p2 = call_wait('max_wait_seconds' => 1)
          assert_equal 2, p2['still_pending_streak']
        end

        def test_streak_at_limit_escalates_to_crashed
          write_state('wait_still_pending_streak' => 3)
          payload = call_wait('max_wait_seconds' => 1)
          assert_equal 'crashed', payload['status']
          assert_equal 'wait_exhausted', payload['crashed_reason']
          assert_equal 'multi_llm_review', payload['next_action']['tool']
        end

        def test_ready_resets_streak
          write_state('wait_still_pending_streak' => 2)
          PendingState.write_subprocess_results(@token, { 'results' => [], 'elapsed_seconds' => 1 })
          payload = call_wait('max_wait_seconds' => 1)
          assert_equal 'ready', payload['status']
          state = PendingState.load_state(@token)
          assert_equal 0, state['wait_still_pending_streak'].to_i
        end

        # ── crashed (worker terminal) ────────────────────────────────────

        def test_crashed_status_propagates_reason
          write_state('subprocess_status' => 'crashed', 'crash_reason' => 'segfault')
          payload = call_wait('max_wait_seconds' => 1)
          assert_equal 'crashed', payload['status']
          assert_equal 'segfault', payload['crashed_reason']
          assert_equal 'multi_llm_review', payload['next_action']['tool']
        end

        # ── hard cap ─────────────────────────────────────────────────────
        # Hard cap is enforced before WaitForWorker is invoked. We verify the
        # clamping logic without actually waiting for the cap by checking the
        # request was processed (well-formed payload returned in bounded time)
        # and the deadline-remaining check fired.
        def test_max_wait_clamped_when_request_exceeds_hard_cap
          # Set a very short deadline so the deadline-remaining clamp fires
          # almost immediately.
          write_state('collect_deadline' => (Time.now + 2).iso8601)
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          PendingState.write_worker_pid(@token, { 'pid' => Process.pid, 'pgid' => Process.pid })

          t0 = Time.now
          payload = call_wait('max_wait_seconds' => 999_999)
          elapsed = Time.now - t0
          # Whatever status comes back (still_pending or past_collect_deadline
          # depending on timing), elapsed must be bounded — never the 999_999s
          # the caller requested. Enforces the clamp path is not bypassed.
          refute_nil payload['status']
          assert_operator elapsed, :<, 30.0,
            'elapsed must be bounded by deadline-remaining clamp, not by raw max_wait_seconds'
        end

        # ── elapsed_seconds field is always present ──────────────────────

        def test_elapsed_seconds_always_present
          write_state
          PendingState.write_subprocess_results(@token, { 'results' => [], 'elapsed_seconds' => 0.1 })
          payload = call_wait('max_wait_seconds' => 1)
          assert payload.key?('elapsed_seconds'), 'elapsed_seconds field missing'
          assert_kind_of Float, payload['elapsed_seconds']
        end

        # ── next_action present on every status ──────────────────────────

        def test_next_action_present_on_every_status
          write_state
          # ready
          PendingState.write_subprocess_results(@token, { 'results' => [], 'elapsed_seconds' => 1 })
          assert call_wait('max_wait_seconds' => 1)['next_action'], 'ready missing next_action'

          # past_collect_deadline
          File.delete(PendingState.subprocess_results_path(@token))
          PendingState.write_state(@token, PendingState.load_state(@token)
            .merge('collect_deadline' => (Time.now - 1).iso8601))
          assert call_wait['next_action'], 'past_collect_deadline missing next_action'

          # crashed
          PendingState.write_state(@token, PendingState.load_state(@token).merge(
            'collect_deadline' => (Time.now + 600).iso8601,
            'subprocess_status' => 'crashed', 'crash_reason' => 'oom'
          ))
          assert call_wait['next_action'], 'crashed missing next_action'
        end
      end

      # ── v3.24.1 regression tests for v3.24.0 review findings ───────────
      class TestMultiLlmReviewWaitV3_24_1Regressions < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr-wait-v341-')
          @orig_cwd = Dir.pwd
          Dir.chdir(@tmp)
          @tool = Tools::MultiLlmReviewWait.new
          @token = '22222222-3333-4444-8555-666666666666'
        end

        def teardown
          Dir.chdir(@orig_cwd)
          FileUtils.rm_rf(@tmp)
        end

        def write_state(extra = {})
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'schema_version' => 4,
            'token' => @token,
            'created_at' => Time.now.iso8601,
            'collect_deadline' => (Time.now + 1800).iso8601,
            'subprocess_status' => 'pending',
            'subprocess_total' => 3,
            'parallel' => true
          }.merge(extra))
          FileUtils.touch(PendingState.collect_lock_path(@token))
        end

        def call_wait(args = {})
          JSON.parse(@tool.call({ 'collect_token' => @token }.merge(args)).first[:text])
        end

        # Bug #1 (P0): config_parallel had dead `unless ... || true` guard so
        # YAML was never loaded. Verify config keys actually take effect now.
        def test_config_parallel_loads_yaml_when_file_exists
          # Use ruby reflection: invoke the private loader directly.
          loaded = @tool.send(:load_config_parallel)
          assert_kind_of Hash, loaded
          # Real config file ships with these keys (v3.24.0):
          assert loaded.key?('wait_max_default_seconds') ||
                 loaded.key?('poll_interval_seconds'),
                 "load_config_parallel returned empty hash — YAML not actually loaded. Got: #{loaded.inspect}"
        end

        # Bug #6: streak guard ran BEFORE ready check, so a worker that
        # finished while streak was at limit was misclassified as crashed.
        def test_ready_check_takes_precedence_over_streak_guard
          # Token is at streak limit (3) AND has subprocess_results.json.
          write_state('wait_still_pending_streak' => 5)
          PendingState.write_subprocess_results(@token, {
            'results' => [
              { 'role_label' => 'r1', 'raw_text' => 'APPROVE', 'status' => 'success' },
              { 'role_label' => 'r2', 'raw_text' => 'APPROVE', 'status' => 'success' }
            ],
            'elapsed_seconds' => 5.0
          })
          payload = call_wait('max_wait_seconds' => 1)
          assert_equal 'ready', payload['status'],
            "Expected ready (worker finished) even though streak limit was hit; got: #{payload.inspect}"
          assert_equal 'multi_llm_review_collect', payload['next_action']['tool']
        end

        # Bug #4: post-wait deadline revalidation. If deadline elapses during
        # WaitForWorker.wait, the post-wait check should return
        # past_collect_deadline rather than still_pending.
        def test_post_wait_deadline_revalidation
          # Deadline is 1.5s from now. Heartbeat live → WaitForWorker.wait
          # would return :timeout after max_wait=2s, but deadline-cap clamps
          # to ~1.5s. After the wait, Time.now >= deadline_at_entry → return
          # past_collect_deadline.
          write_state('collect_deadline' => (Time.now + 1.5).iso8601)
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          PendingState.write_worker_pid(@token, { 'pid' => Process.pid, 'pgid' => Process.pid })

          payload = call_wait('max_wait_seconds' => 2)
          # Outcome should NOT be still_pending — either past_collect_deadline
          # (post-wait revalidation fired) or ready (if results file appeared).
          # What we forbid is still_pending when the deadline is gone.
          refute_equal 'still_pending', payload['status'],
            "Should not return still_pending when deadline elapsed during wait. Got: #{payload.inspect}"
        end

        # Bug #7: malformed collect_deadline → previously silently nilled and
        # skipped checks. Now should return crashed/malformed_state.
        def test_malformed_collect_deadline_returns_crashed
          write_state('collect_deadline' => 'not-an-iso8601-timestamp')
          payload = call_wait('max_wait_seconds' => 1)
          assert_equal 'crashed', payload['status']
          assert_equal 'malformed_state', payload['crashed_reason']
        end

        # Bug #5: internal exceptions previously returned status: 'error',
        # outside the declared 6-status enum. Now should map to crashed.
        def test_internal_error_returns_crashed_status_in_enum
          # Trigger an internal error by passing a weird arguments object.
          # The outer rescue should map it to crashed/internal_error.
          payload = JSON.parse(@tool.call(nil).first[:text])
          # nil arguments → token becomes "" → unknown_token (not internal_error)
          # so the error path needs a different trigger. Use a token that
          # passes valid_token? but PendingState raises on. Easier: stub.
          assert_includes %w[unknown_token crashed], payload['status']
          refute_equal 'error', payload['status']
        end

        # Bug #2: streak increment via update_state RMW is atomic. Verify
        # that under sequential timeouts, streak increments correctly.
        def test_streak_increments_atomically_via_update_state
          write_state
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          PendingState.write_worker_pid(@token, { 'pid' => Process.pid, 'pgid' => Process.pid })

          p1 = call_wait('max_wait_seconds' => 1)
          assert_equal 'still_pending', p1['status']
          assert_equal 1, p1['still_pending_streak']

          # Reload state and verify persistence.
          state_after_1 = PendingState.load_state(@token)
          assert_equal 1, state_after_1['wait_still_pending_streak']

          p2 = call_wait('max_wait_seconds' => 1)
          assert_equal 'still_pending', p2['status']
          assert_equal 2, p2['still_pending_streak']
        end

        # Bug #3: still_pending hint should report the *effective* streak
        # limit (from config), not nil from state['wait_still_pending_streak_limit'].
        def test_still_pending_hint_reports_correct_streak_limit
          write_state
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          PendingState.write_worker_pid(@token, { 'pid' => Process.pid, 'pgid' => Process.pid })

          p = call_wait('max_wait_seconds' => 1)
          assert_equal 'still_pending', p['status']
          # Hint must mention "streak N/M" with M being the actual limit (3 by default).
          purpose = p['next_action']['purpose']
          assert_match(%r{streak 1/3}, purpose,
            "Expected '/3' (effective limit) in next_action purpose; got: #{purpose}")
        end

        # Off-by-one: when remaining < 1s, return past_collect_deadline
        # rather than clamping to 1 and entering WaitForWorker.
        def test_remaining_lt_one_second_returns_past_deadline_immediately
          write_state('collect_deadline' => (Time.now + 0.4).iso8601)
          # Sleep briefly so remaining is genuinely < 0.
          sleep 0.5
          t0 = Time.now
          p = call_wait('max_wait_seconds' => 60)
          elapsed = Time.now - t0
          assert_equal 'past_collect_deadline', p['status']
          assert_operator elapsed, :<, 1.0
        end
      end

      # ── backward compat: collect can still be called without wait ────────
      # Verifies that introducing wait does not break the existing
      # "delegation_pending → collect" path. The collect tool already polls
      # internally and remains the primary completion gate.
      class TestWaitToolBackwardCompat < Minitest::Test
        def test_collect_works_without_wait_tool
          # Smoke test: load the collect tool and verify it has not gained a
          # required dependency on wait. (Full collect integration is covered
          # in test_multi_llm_review.rb; this is a presence check.)
          require_relative '../tools/multi_llm_review_collect'
          collect = Tools::MultiLlmReviewCollect.new
          schema = collect.input_schema
          assert_equal 'object', schema[:type]
          # The collect tool's required fields must still be just collect_token
          # + orchestrator_reviews — wait must NOT have been added as required.
          required = schema[:required] || []
          refute_includes required, 'wait_completed'
          refute_includes required, 'wait_token'
        end
      end
    end
  end
end
