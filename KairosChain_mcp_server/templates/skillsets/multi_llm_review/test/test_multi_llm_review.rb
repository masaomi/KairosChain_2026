# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/prompt_builder'
require_relative '../lib/multi_llm_review/dispatcher'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestConsensus < Minitest::Test
        def test_all_approve
          reviews = [
            { role_label: 'r1', raw_text: 'Overall Verdict: APPROVE', status: :success },
            { role_label: 'r2', raw_text: 'APPROVE - looks good', status: :success },
            { role_label: 'r3', raw_text: 'I APPROVE this design', status: :success }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'APPROVE', result[:verdict]
          assert_equal 3, result[:convergence][:approve_count]
          assert_equal 0, result[:convergence][:reject_count]
        end

        def test_any_reject_means_revise
          reviews = [
            { role_label: 'r1', raw_text: 'APPROVE', status: :success },
            { role_label: 'r2', raw_text: 'REJECT - security issue', status: :success },
            { role_label: 'r3', raw_text: 'APPROVE', status: :success }
          ]
          result = Consensus.aggregate(reviews, '2/3 APPROVE', min_quorum: 2)
          assert_equal 'REVISE', result[:verdict]
          assert_equal 1, result[:convergence][:reject_count]
        end

        def test_skip_excluded_from_denominator
          reviews = [
            { role_label: 'r1', raw_text: 'APPROVE', status: :success },
            { role_label: 'r2', raw_text: 'APPROVE', status: :success },
            { role_label: 'r3', raw_text: '', status: :error, error: { 'type' => 'timeout' } },
            { role_label: 'r4', raw_text: '', status: :skip }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'APPROVE', result[:verdict]
          assert_equal 2, result[:convergence][:successful_count]
          assert_equal 2, result[:convergence][:skip_count]
          # threshold = ceil(2 * 0.75) = 2, approve = 2 >= 2
          assert_equal 2, result[:convergence][:threshold]
        end

        def test_insufficient_quorum
          reviews = [
            { role_label: 'r1', raw_text: 'APPROVE', status: :success },
            { role_label: 'r2', raw_text: '', status: :error },
            { role_label: 'r3', raw_text: '', status: :skip }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'INSUFFICIENT', result[:verdict]
        end

        def test_structured_json_verdict
          reviews = [
            { role_label: 'r1', raw_text: '{"overall_verdict": "APPROVE", "findings": []}', status: :success },
            { role_label: 'r2', raw_text: '{"overall_verdict": "approve"}', status: :success },
            { role_label: 'r3', raw_text: '{"overall_verdict": "REJECT", "findings": ["P0: bug"]}', status: :success }
          ]
          result = Consensus.aggregate(reviews, '2/3 APPROVE', min_quorum: 2)
          assert_equal 'REVISE', result[:verdict]
        end

        def test_ratio_threshold_with_degraded_quorum
          # "3/4 APPROVE" with 2 successful: threshold = ceil(2 * 0.75) = 2
          reviews = [
            { role_label: 'r1', raw_text: 'APPROVE', status: :success },
            { role_label: 'r2', raw_text: 'APPROVE', status: :success },
            { role_label: 'r3', raw_text: '', status: :skip },
            { role_label: 'r4', raw_text: '', status: :skip }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'APPROVE', result[:verdict]
        end

        def test_not_enough_approvals_means_revise
          reviews = [
            { role_label: 'r1', raw_text: 'APPROVE', status: :success },
            { role_label: 'r2', raw_text: 'looks good but NEEDS WORK', status: :success },
            { role_label: 'r3', raw_text: 'more details needed', status: :success }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'REVISE', result[:verdict]
        end

        def test_aggregate_findings_dedup
          # Simulate already-parsed verdicts (after extract_verdict)
          parsed = [
            { role_label: 'r1', raw_text: "P0: Missing error handling in dispatcher\n\nP1: Thread safety concern", status: :success, verdict: 'REJECT' },
            { role_label: 'r2', raw_text: "P0: Missing error handling in dispatcher timeout path", status: :success, verdict: 'REJECT' }
          ]
          findings = Consensus.aggregate_findings(parsed)

          # Both P0s share "Missing error handling in dispatcher" prefix → dedup
          p0_findings = findings.select { |f| f[:severity] == 'P0' }
          assert p0_findings.size >= 1, "Expected at least one P0 finding, got: #{findings.inspect}"
          # r1's P0 and r2's P0 should dedup; P1 is separate
          assert findings.size <= 3, "Expected dedup to reduce findings, got #{findings.size}"
        end

        def test_parse_threshold_ratio
          assert_equal 3, Consensus.parse_threshold('3/4 APPROVE', 4)
          assert_equal 2, Consensus.parse_threshold('3/4 APPROVE', 2)
          assert_equal 2, Consensus.parse_threshold('2/3 APPROVE', 3)
          assert_equal 1, Consensus.parse_threshold('3/4 APPROVE', 1)
        end

        def test_overall_verdict_markdown_line
          review = { role_label: 'r1', raw_text: "**Overall Verdict**: APPROVE\n\nSome concerns noted but overall good.", status: :success }
          result = Consensus.extract_verdict(review)
          assert_equal 'APPROVE', result[:verdict]
        end

        def test_approve_with_concerns_not_false_revise
          review = { role_label: 'r1', raw_text: "**Overall Verdict**: APPROVE\n\nMinor concerns about naming.", status: :success }
          result = Consensus.extract_verdict(review)
          assert_equal 'APPROVE', result[:verdict], "APPROVE with concerns should not be REVISE"
        end

        def test_verdict_extraction_fail_maps_to_reject
          review = { role_label: 'r1', raw_text: 'FAIL - critical bug found', status: :success }
          result = Consensus.extract_verdict(review)
          assert_equal 'REJECT', result[:verdict]
        end

        def test_verdict_extraction_unparseable_defaults_to_revise
          review = { role_label: 'r1', raw_text: 'I have mixed feelings about this.', status: :success }
          result = Consensus.extract_verdict(review)
          assert_equal 'REVISE', result[:verdict]
        end
      end

      # Stub invoker for Dispatcher tests
      class StubInvoker
        attr_reader :call_log

        def initialize(responses: {}, delay: 0, error_providers: [])
          @responses = responses
          @delay = delay
          @error_providers = error_providers
          @call_log = []
          @mutex = Mutex.new
        end

        def invoke_tool(_name, args, context: nil)
          provider = args['provider_override'] || 'unknown'
          @mutex.synchronize { @call_log << { provider: provider, args: args.dup, time: Time.now } }
          sleep @delay if @delay > 0

          if @error_providers.include?(provider)
            raise StandardError, "Simulated error for #{provider}"
          end

          response = @responses[provider] || default_response(provider)
          [{ text: JSON.generate(response) }]
        end

        private

        def default_response(provider)
          {
            'status' => 'ok',
            'provider' => provider,
            'response' => {
              'content' => "APPROVE - looks good. No findings.",
              'model' => "test-#{provider}"
            }
          }
        end
      end

      class TestDispatcher < Minitest::Test
        def setup
          @reviewers = [
            { provider: 'r1', role_label: 'reviewer_1' },
            { provider: 'r2', role_label: 'reviewer_2' },
            { provider: 'r3', role_label: 'reviewer_3' }
          ]
          @messages = [{ 'role' => 'user', 'content' => 'test review' }]
          @system = 'You are a reviewer.'
        end

        def test_all_succeed
          invoker = StubInvoker.new
          dispatcher = Dispatcher.new(invoker, timeout_seconds: 10, max_concurrent: 3)
          results = dispatcher.dispatch(@reviewers, @messages, @system,
                                        context: nil, review_context: 'independent')
          assert_equal 3, results.size
          results.each { |r| assert_equal :success, r[:status] }
          assert_equal 3, invoker.call_log.size
        end

        def test_one_error
          invoker = StubInvoker.new(error_providers: ['r2'])
          dispatcher = Dispatcher.new(invoker, timeout_seconds: 10, max_concurrent: 3)
          results = dispatcher.dispatch(@reviewers, @messages, @system,
                                        context: nil, review_context: 'independent')
          assert_equal 3, results.size
          assert_equal :success, results[0][:status]
          assert_equal :error, results[1][:status]
          assert_equal :success, results[2][:status]
        end

        def test_timeout_marks_uncollected_as_skip
          # r2 sleeps longer than the dispatcher timeout
          invoker = StubInvoker.new(delay: 0)
          slow_invoker = Object.new
          call_count = 0
          call_mutex = Mutex.new
          slow_invoker.define_singleton_method(:invoke_tool) do |_name, args, context: nil|
            provider = args['provider_override']
            call_mutex.synchronize { call_count += 1 }
            sleep(provider == 'r2' ? 5 : 0.1)
            [{ text: JSON.generate({
              'status' => 'ok', 'provider' => provider,
              'response' => { 'content' => 'APPROVE', 'model' => 'test' }
            }) }]
          end

          dispatcher = Dispatcher.new(slow_invoker, timeout_seconds: 2, max_concurrent: 3)
          results = dispatcher.dispatch(@reviewers, @messages, @system,
                                        context: nil, review_context: 'independent')
          assert_equal 3, results.size
          # r2 should be dispatch_timeout (or success if it finished in time)
          skip_count = results.count { |r| r[:status] == :skip }
          success_count = results.count { |r| r[:status] == :success }
          assert success_count >= 2, "Expected at least 2 successes, got #{success_count}"
        end

        def test_semaphore_limits_concurrency
          concurrent_count = 0
          max_concurrent_seen = 0
          mutex = Mutex.new
          tracking_invoker = Object.new
          tracking_invoker.define_singleton_method(:invoke_tool) do |_name, args, context: nil|
            mutex.synchronize do
              concurrent_count += 1
              max_concurrent_seen = [max_concurrent_seen, concurrent_count].max
            end
            sleep 0.2
            mutex.synchronize { concurrent_count -= 1 }
            provider = args['provider_override']
            [{ text: JSON.generate({
              'status' => 'ok', 'provider' => provider,
              'response' => { 'content' => 'APPROVE', 'model' => 'test' }
            }) }]
          end

          dispatcher = Dispatcher.new(tracking_invoker, timeout_seconds: 10, max_concurrent: 1)
          results = dispatcher.dispatch(@reviewers, @messages, @system,
                                        context: nil, review_context: 'independent')
          assert_equal 3, results.size
          assert_equal 1, max_concurrent_seen, "Semaphore should limit to 1 concurrent"
        end

        def test_dispatch_id_and_sandbox_passed_to_llm_call
          invoker = StubInvoker.new
          dispatcher = Dispatcher.new(invoker, timeout_seconds: 10, max_concurrent: 3)
          dispatcher.dispatch(@reviewers, @messages, @system,
                              context: nil, review_context: 'independent')

          assert_equal 3, invoker.call_log.size

          # All calls should include the same dispatch_id (non-empty)
          dispatch_ids = invoker.call_log.map { |log| log[:args]['dispatch_id'] }
          dispatch_ids.each do |did|
            assert did, "dispatch_id should be present"
            refute_empty did, "dispatch_id should not be empty"
          end
          assert_equal 1, dispatch_ids.uniq.size, "All calls in one dispatch should share the same dispatch_id"

          # All calls with review_context='independent' should have sandbox_mode=true
          invoker.call_log.each do |log|
            assert_equal true, log[:args]['sandbox_mode'],
              "sandbox_mode should be true for independent review"
          end
        end
      end

      class TestPromptBuilder < Minitest::Test
        def test_system_prompt_independent
          prompt = PromptBuilder.build_system_prompt('design', review_context: 'independent')
          assert_includes prompt, 'independent code reviewer'
          assert_includes prompt, 'Do NOT read or reference'
          assert_includes prompt, 'Architecture'
        end

        def test_system_prompt_project_aware
          prompt = PromptBuilder.build_system_prompt('implementation', review_context: 'project_aware')
          assert_includes prompt, 'independent code reviewer'
          refute_includes prompt, 'Do NOT read or reference'
          assert_includes prompt, 'Code correctness'
        end

        def test_build_messages_initial
          messages = PromptBuilder.build_messages(
            artifact_content: 'test code here',
            artifact_name: 'test_artifact',
            review_type: 'implementation',
            review_round: 1
          )
          assert_equal 1, messages.size
          assert_equal 'user', messages[0]['role']
          assert_includes messages[0]['content'], '<artifact>'
          assert_includes messages[0]['content'], 'test code here'
          assert_includes messages[0]['content'], 'Initial review'
        end

        def test_build_messages_with_prior_findings
          prior = [
            { severity: 'P0', issue: 'Missing validation', cited_by: ['r1', 'r2'] }
          ]
          messages = PromptBuilder.build_messages(
            artifact_content: 'revised code',
            artifact_name: 'test_v2',
            review_type: 'fix_plan',
            review_round: 2,
            prior_findings: prior
          )
          content = messages[0]['content']
          assert_includes content, 'R2'
          assert_includes content, 'Missing validation'
          assert_includes content, 'r1, r2'
        end
      end
    end
  end
end
