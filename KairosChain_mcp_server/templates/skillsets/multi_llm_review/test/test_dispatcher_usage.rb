# frozen_string_literal: true
# v0.3.1 meta-review bug #2: Dispatcher#build_success preserves `usage`.

require 'minitest/autorun'
require_relative '../lib/multi_llm_review/dispatcher'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestDispatcherUsagePreserved < Minitest::Test
        def test_build_success_preserves_usage_from_llm_response
          d = Dispatcher.new(nil, timeout_seconds: 60, max_concurrent: 1)
          llm_response = {
            'provider' => 'codex',
            'response' => { 'content' => 'ok', 'model' => 'gpt-5.5' },
            'usage' => { 'input_tokens' => 42, 'output_tokens' => 7, 'total_tokens' => 49 }
          }
          result = d.send(:build_success, { role_label: 'r', provider: 'codex' },
                          llm_response,
                          Process.clock_gettime(Process::CLOCK_MONOTONIC))
          assert_equal 42, result[:usage]['input_tokens']
          assert_equal 7,  result[:usage]['output_tokens']
          assert_equal 49, result[:usage]['total_tokens']
        end

        def test_build_success_nil_usage_when_llm_response_lacks
          d = Dispatcher.new(nil, timeout_seconds: 60, max_concurrent: 1)
          llm_response = { 'provider' => 'x', 'response' => { 'content' => 'ok' } }
          result = d.send(:build_success, { role_label: 'r' }, llm_response,
                          Process.clock_gettime(Process::CLOCK_MONOTONIC))
          assert_nil result[:usage]
        end
      end

      # Per-seat persistence hook (2026-08-06). One stuck seat killed the
      # worker via stale heartbeat and took three COMPLETED external seats
      # with it, because nothing left the worker's memory until every seat
      # was done. The hook fires as each reply arrives so the caller can
      # persist it; a failing hook must not fail the dispatch it guards.
      class TestDispatcherOnResultHook < Minitest::Test
        class StubInvoker
          def invoke_tool(_name, args, context: nil)
            [{ text: JSON.generate({
              'status' => 'ok',
              'provider' => args['provider_override'],
              'response' => { 'content' => "**Overall Verdict**: APPROVE\n\nfine" }
            }) }]
          end
        end

        def reviewers
          [{ provider: 'a', model: 'm-a', role_label: 'seat_a' },
           { provider: 'b', model: 'm-b', role_label: 'seat_b' }]
        end

        def test_on_result_fires_once_per_arrived_reply_with_its_index
          seen = []
          d = Dispatcher.new(StubInvoker.new, timeout_seconds: 30, max_concurrent: 2)
          results = d.dispatch(reviewers, [], '', context: nil,
                               on_result: ->(idx, r) { seen << [idx, r[:role_label]] })
          assert_equal 2, results.size
          assert_equal [[0, 'seat_a'], [1, 'seat_b']], seen.sort
        end

        def test_a_failing_hook_does_not_fail_the_dispatch
          d = Dispatcher.new(StubInvoker.new, timeout_seconds: 30, max_concurrent: 2)
          results = nil
          capture_io do
            results = d.dispatch(reviewers, [], '', context: nil,
                                 on_result: ->(_i, _r) { raise 'disk full' })
          end
          assert_equal 2, results.size
          assert(results.all? { |r| r[:status] == :success })
        end

        # The deadline skip is this dispatch's decision about the seat, and
        # the hook carries it like an arrived reply — a persisted record that
        # omitted it let crash recovery relabel a reached-and-timed-out seat
        # as one the worker never got to (R1 finding).
        def test_deadline_skips_are_notified_with_their_true_reason
          slow = Class.new do
            def invoke_tool(_name, _args, context: nil)
              sleep 2
              [{ text: JSON.generate({ 'status' => 'ok', 'response' => { 'content' => 'late' } }) }]
            end
          end
          seen = []
          d = Dispatcher.new(slow.new, timeout_seconds: 0, max_concurrent: 2)
          results = d.dispatch(reviewers, [], '', context: nil,
                               on_result: ->(idx, r) { seen << [idx, r] })
          assert_equal 2, results.size
          skipped = seen.select { |_i, r| r[:status] == :skip }
          refute_empty skipped, 'the deadline skips must reach the hook'
          skipped.each do |_i, r|
            assert_includes %w[dispatch_timeout cancelled_before_start],
                            r[:error]['message']
          end
        end
      end
    end
  end
end
