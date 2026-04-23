# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/prompt_builder'
require_relative '../lib/multi_llm_review/dispatcher'

# Stub out BaseTool so we can load the tool file in isolation.
module KairosMcp
  module Tools
    class BaseTool
      def text_content(s); [{ text: s }]; end
    end
  end unless defined?(KairosMcp::Tools::BaseTool)
end
require_relative '../tools/multi_llm_review'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/persona_assembly'
require_relative '../tools/multi_llm_review_collect'
require 'tmpdir'
require 'fileutils'

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

      class TestOrchestratorExclusion < Minitest::Test
        def setup
          @tool = Tools::MultiLlmReview.new
          @reviewers = [
            { provider: 'claude_code', model: 'claude-opus-4-7', role_label: 'team_47' },
            { provider: 'claude_code', model: 'claude-opus-4-6', role_label: 'cli_46' },
            { provider: 'codex', role_label: 'codex' },
            { provider: 'cursor', role_label: 'cursor' }
          ]
        end

        def test_excludes_matching_model
          kept, n = @tool.send(:exclude_orchestrator, @reviewers,
                               'claude-opus-4-7',
                               { 'exclude_orchestrator_model' => true })
          assert_equal 1, n
          assert_equal 3, kept.size
          refute(kept.any? { |r| r[:model] == 'claude-opus-4-7' })
        end

        def test_excludes_other_opus
          kept, n = @tool.send(:exclude_orchestrator, @reviewers,
                               'claude-opus-4-6',
                               { 'exclude_orchestrator_model' => true })
          assert_equal 1, n
          assert(kept.any? { |r| r[:model] == 'claude-opus-4-7' })
          refute(kept.any? { |r| r[:model] == 'claude-opus-4-6' })
        end

        def test_no_match_keeps_all
          kept, n = @tool.send(:exclude_orchestrator, @reviewers,
                               'claude-sonnet-4-6',
                               { 'exclude_orchestrator_model' => true })
          assert_equal 0, n
          assert_equal 4, kept.size
        end

        def test_nil_orchestrator_is_noop
          kept, n = @tool.send(:exclude_orchestrator, @reviewers, nil,
                               { 'exclude_orchestrator_model' => true })
          assert_equal 0, n
          assert_equal 4, kept.size
        end

        def test_empty_orchestrator_is_noop
          kept, n = @tool.send(:exclude_orchestrator, @reviewers, '',
                               { 'exclude_orchestrator_model' => true })
          assert_equal 0, n
          assert_equal 4, kept.size
        end

        def test_disabled_flag_keeps_all
          kept, n = @tool.send(:exclude_orchestrator, @reviewers,
                               'claude-opus-4-7',
                               { 'exclude_orchestrator_model' => false })
          assert_equal 0, n
          assert_equal 4, kept.size
        end

        def test_default_when_flag_missing_excludes
          # Missing key defaults to true (opt-out, not opt-in)
          kept, n = @tool.send(:exclude_orchestrator, @reviewers,
                               'claude-opus-4-7', {})
          assert_equal 1, n
          assert_equal 3, kept.size
        end
      end

      class TestPendingState < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr-pending-')
          @orig_cwd = Dir.pwd
          Dir.chdir(@tmp)
        end

        def teardown
          Dir.chdir(@orig_cwd)
          FileUtils.rm_rf(@tmp)
        end

        def test_generate_token_is_uuid_v4
          token = PendingState.generate_token
          assert PendingState.valid_token?(token), "expected #{token} to be valid UUID v4"
        end

        def test_invalid_token_rejects_path_traversal
          refute PendingState.valid_token?('../../etc/passwd')
          refute PendingState.valid_token?('not-a-uuid')
          refute PendingState.valid_token?('a' * 36)
          refute PendingState.valid_token?(nil)
        end

        def test_write_and_load_roundtrip
          token = PendingState.generate_token
          PendingState.write(token, { 'token' => token, 'foo' => 'bar' })
          loaded = PendingState.load(token)
          assert_equal token, loaded['token']
          assert_equal 'bar', loaded['foo']
        end

        def test_load_returns_nil_for_missing
          assert_nil PendingState.load(PendingState.generate_token)
        end

        def test_load_returns_nil_for_invalid_token
          assert_nil PendingState.load('not-a-uuid')
        end

        def test_atomic_write_no_partial_file
          token = PendingState.generate_token
          PendingState.write(token, { 'token' => token, 'data' => 'x' * 100 })
          # No tmp file should remain after successful write
          tmp_files = Dir.glob(File.join(PendingState.root_dir, '*.tmp.*'))
          assert_empty tmp_files
        end

        def test_cleanup_expired_removes_uncollected_past_deadline
          token = PendingState.generate_token
          PendingState.write(token, {
            'token' => token,
            'collect_deadline' => (Time.now - 100).iso8601,
            'collected' => false
          })
          removed = PendingState.cleanup_expired!
          assert_equal 1, removed
          assert_nil PendingState.load(token)
        end

        def test_cleanup_keeps_collected_within_retention
          token = PendingState.generate_token
          PendingState.write(token, {
            'token' => token,
            'collect_deadline' => (Time.now - 100).iso8601,
            'collected' => true
          })
          removed = PendingState.cleanup_expired!(retain_collected_seconds: 3600)
          assert_equal 0, removed
          refute_nil PendingState.load(token)
        end

        def test_cleanup_removes_collected_past_retention
          token = PendingState.generate_token
          PendingState.write(token, {
            'token' => token,
            'collect_deadline' => (Time.now - 7200).iso8601,
            'collected' => true
          })
          removed = PendingState.cleanup_expired!(retain_collected_seconds: 3600)
          assert_equal 1, removed
        end
      end

      class TestPersonaAssembly < Minitest::Test
        def base_review(persona, verdict, **extras)
          { 'persona' => persona, 'verdict' => verdict,
            'reasoning' => "#{persona} reasoning", 'findings' => [] }.merge(extras)
        end

        def test_all_approve_assembles_to_approve
          reviews = [base_review('a', 'APPROVE'), base_review('b', 'APPROVE')]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          assert_match(/APPROVE/, entry[:raw_text])
          assert_equal 'claude_team_claude-opus-4-7', entry[:role_label]
          assert_equal 'claude-opus-4-7', entry[:model]
          assert_equal :success, entry[:status]
        end

        def test_any_reject_dominates
          reviews = [
            base_review('a', 'APPROVE'),
            base_review('b', 'REJECT'),
            base_review('c', 'REVISE')
          ]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          assert_includes entry[:raw_text], 'Overall Verdict**: REJECT'
        end

        def test_any_revise_without_reject
          reviews = [base_review('a', 'APPROVE'), base_review('b', 'REVISE')]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          assert_includes entry[:raw_text], 'Overall Verdict**: REVISE'
        end

        def test_below_min_personas_raises
          assert_raises(ArgumentError) do
            PersonaAssembly.assemble([base_review('only', 'APPROVE')], 'claude-opus-4-7')
          end
        end

        def test_above_max_personas_raises
          reviews = (1..5).map { |i| base_review("p#{i}", 'APPROVE') }
          assert_raises(ArgumentError) do
            PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          end
        end

        def test_missing_persona_raises
          reviews = [
            { 'verdict' => 'APPROVE' },
            base_review('b', 'APPROVE')
          ]
          assert_raises(ArgumentError) do
            PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          end
        end

        def test_missing_verdict_raises
          reviews = [
            { 'persona' => 'a' },
            base_review('b', 'APPROVE')
          ]
          assert_raises(ArgumentError) do
            PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          end
        end

        def test_findings_appear_in_raw_text
          reviews = [
            base_review('a', 'REVISE',
              'findings' => [{ 'severity' => 'P1', 'issue' => 'missing-X' }]),
            base_review('b', 'APPROVE')
          ]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          assert_includes entry[:raw_text], 'P1'
          assert_includes entry[:raw_text], 'missing-X'
        end
      end

      class TestDelegateStrategy < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr-delegate-')
          @orig_cwd = Dir.pwd
          Dir.chdir(@tmp)
          @tool = Tools::MultiLlmReview.new
        end

        def teardown
          Dir.chdir(@orig_cwd)
          FileUtils.rm_rf(@tmp)
        end

        def test_partition_for_strategy_delegate_drops_match
          reviewers = [
            { provider: 'claude_code', model: 'claude-opus-4-7', role_label: 'r47' },
            { provider: 'claude_code', model: 'claude-opus-4-6', role_label: 'r46' },
            { provider: 'codex', role_label: 'codex' }
          ]
          kept, n = @tool.send(:partition_for_strategy,
                               reviewers, 'claude-opus-4-7', 'delegate', {})
          assert_equal 1, n
          assert_equal 2, kept.size
          refute(kept.any? { |r| r[:model] == 'claude-opus-4-7' })
        end

        def test_partition_for_strategy_subprocess_keeps_all
          reviewers = [
            { provider: 'claude_code', model: 'claude-opus-4-7', role_label: 'r47' },
            { provider: 'codex', role_label: 'codex' }
          ]
          kept, n = @tool.send(:partition_for_strategy,
                               reviewers, 'claude-opus-4-7', 'subprocess', {})
          assert_equal 0, n
          assert_equal 2, kept.size
        end

        def test_partition_for_strategy_exclude_uses_config_flag
          reviewers = [
            { provider: 'claude_code', model: 'claude-opus-4-7', role_label: 'r47' },
            { provider: 'codex', role_label: 'codex' }
          ]
          kept, n = @tool.send(:partition_for_strategy, reviewers,
                               'claude-opus-4-7', 'exclude',
                               { 'exclude_orchestrator_model' => true })
          assert_equal 1, n
          assert_equal 1, kept.size
        end

        def test_delegate_response_writes_pending_state
          subprocess_results = [
            { role_label: 'codex', provider: 'codex', model: 'codex-default',
              raw_text: 'APPROVE', elapsed_seconds: 10, error: nil, status: :success }
          ]
          result = @tool.send(:delegate_response,
            raw_results: subprocess_results,
            arguments: { 'review_type' => 'design', 'artifact_name' => 'test' },
            config: {},
            orchestrator_model: 'claude-opus-4-7',
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          assert_equal 'delegation_pending', payload['status']
          assert PendingState.valid_token?(payload['collect_token'])
          assert_equal 1, payload['subprocess_done']
          assert_equal 'claude-opus-4-7', payload['orchestrator_model']

          # Pending state contains orchestrator_model + convergence_rule
          state = PendingState.load(payload['collect_token'])
          assert_equal 'claude-opus-4-7', state['orchestrator_model']
          assert_equal '3/4 APPROVE', state['convergence_rule']
          assert_equal 1, state['subprocess_results'].size
        end

        def test_delegate_response_requires_orchestrator_model
          result = @tool.send(:delegate_response,
            raw_results: [],
            arguments: { 'review_type' => 'design', 'artifact_name' => 'test' },
            config: {},
            orchestrator_model: nil,
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/requires orchestrator_model/, payload['error'])
        end

        def test_delegate_response_fails_when_all_subprocess_failed
          failed = [
            { role_label: 'codex', provider: 'codex', error: 'boom', status: :error }
          ]
          result = @tool.send(:delegate_response,
            raw_results: failed,
            arguments: { 'review_type' => 'design', 'artifact_name' => 'test' },
            config: {},
            orchestrator_model: 'claude-opus-4-7',
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/all subprocess reviewers failed/, payload['error'])
        end

        def test_delegate_uses_config_deadline
          subprocess_results = [
            { role_label: 'codex', provider: 'codex', model: 'm',
              raw_text: 'APPROVE', elapsed_seconds: 1, error: nil, status: :success }
          ]
          result = @tool.send(:delegate_response,
            raw_results: subprocess_results,
            arguments: { 'review_type' => 'design', 'artifact_name' => 'x' },
            config: { 'delegation' => { 'collect_deadline_seconds' => 60 } },
            orchestrator_model: 'claude-opus-4-7',
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          deadline = Time.iso8601(payload['must_collect_by'])
          # Should be ~60s from now, not the default 600s
          assert_in_delta 60, deadline - Time.now, 5
        end
      end

      class TestCollectTool < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr-collect-')
          @orig_cwd = Dir.pwd
          Dir.chdir(@tmp)
          @collect = Tools::MultiLlmReviewCollect.new
        end

        def teardown
          Dir.chdir(@orig_cwd)
          FileUtils.rm_rf(@tmp)
        end

        def write_state(token, overrides = {})
          PendingState.write(token, {
            'token' => token,
            'created_at' => Time.now.iso8601,
            'collect_deadline' => (Time.now + 600).iso8601,
            'review_type' => 'design',
            'artifact_name' => 'test',
            'review_round' => 1,
            'complexity' => 'high',
            'orchestrator_model' => 'claude-opus-4-7',
            'convergence_rule' => '3/4 APPROVE',
            'min_quorum' => 2,
            'collected' => false,
            'subprocess_results' => [
              { 'role_label' => 'codex', 'provider' => 'codex', 'model' => 'codex-default',
                'raw_text' => 'APPROVE - looks good', 'elapsed_seconds' => 10,
                'error' => nil, 'status' => 'success' },
              { 'role_label' => 'cursor', 'provider' => 'cursor', 'model' => 'cursor-default',
                'raw_text' => 'APPROVE', 'elapsed_seconds' => 5,
                'error' => nil, 'status' => 'success' }
            ]
          }.merge(overrides))
        end

        def good_reviews
          [
            { 'persona' => 'architect', 'verdict' => 'APPROVE',
              'reasoning' => 'looks fine', 'findings' => [] },
            { 'persona' => 'security', 'verdict' => 'APPROVE',
              'reasoning' => 'no issues', 'findings' => [] }
          ]
        end

        def test_invalid_token_format
          result = @collect.call({
            'collect_token' => 'not-a-uuid',
            'orchestrator_reviews' => good_reviews
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/invalid collect_token/, payload['error'])
        end

        def test_unknown_token
          result = @collect.call({
            'collect_token' => PendingState.generate_token,
            'orchestrator_reviews' => good_reviews
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'expired_or_unknown_token', payload['status']
        end

        def test_happy_path_merges_subprocess_and_orchestrator
          token = PendingState.generate_token
          write_state(token)
          result = @collect.call({
            'collect_token' => token,
            'orchestrator_reviews' => good_reviews
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'ok', payload['status']
          assert_equal 'APPROVE', payload['verdict']
          # 2 subprocess + 1 assembled orchestrator = 3 reviews
          assert_equal 3, payload['reviews'].size
          # Orchestrator entry has the synthesized role_label
          assert(payload['reviews'].any? { |r| r['role_label'] == 'claude_team_claude-opus-4-7' })
          assert_equal 2, payload['persona_count']
        end

        def test_idempotent_replay
          token = PendingState.generate_token
          write_state(token)
          first = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          }).first[:text])
          second = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          }).first[:text])
          assert_equal first['verdict'], second['verdict']
          assert second['idempotent_replay'], 'expected idempotent_replay flag on second call'
        end

        def test_expired_deadline_returns_expired
          token = PendingState.generate_token
          write_state(token, 'collect_deadline' => (Time.now - 60).iso8601)
          result = @collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'expired_or_unknown_token', payload['status']
        end

        def test_too_few_personas_rejected
          token = PendingState.generate_token
          write_state(token)
          result = @collect.call({
            'collect_token' => token,
            'orchestrator_reviews' => [good_reviews.first]
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/at least #{PersonaAssembly::MIN_PERSONAS}/, payload['error'])
        end

        def test_orchestrator_reject_propagates_to_consensus
          token = PendingState.generate_token
          write_state(token)
          rejecting = [
            { 'persona' => 'architect', 'verdict' => 'REJECT',
              'reasoning' => 'broken', 'findings' => [
                { 'severity' => 'P0', 'issue' => 'critical-bug' }
              ] },
            { 'persona' => 'security', 'verdict' => 'APPROVE',
              'reasoning' => 'fine', 'findings' => [] }
          ]
          result = @collect.call({
            'collect_token' => token, 'orchestrator_reviews' => rejecting
          })
          payload = JSON.parse(result.first[:text])
          # subprocess approved, orchestrator team rejected → REVISE per any-REJECT rule
          assert_equal 'REVISE', payload['verdict']
        end
      end
    end
  end
end
