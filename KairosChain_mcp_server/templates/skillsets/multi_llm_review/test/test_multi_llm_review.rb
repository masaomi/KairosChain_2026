# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/observer_set'
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
        # INV-E2 (v0.6): a reply has to say something beyond its verdict to
        # enter the denominator. The tests in this class are about the
        # aggregation arithmetic rather than about substance, so their
        # fixtures carry a body. The substance rule itself is covered in
        # test_observer_set.rb.
        # The verdict is stated in the one form the reading path accepts: the
        # header, on the first line, carrying a verdict name and nothing else.
        # These fixtures used to state it as prose ("I APPROVE this design"),
        # which the parser inferred from — and inference is what this SkillSet
        # stopped doing in round 9, because it read negations as approvals and
        # terse approvals as rejections.
        def body(verdict)
          "**Overall Verdict**: #{verdict}\n\n" +
            ('Checked the dispatch path, the denominator arithmetic and the ' \
             'recording of slots that never ran; notes follow. ' * 3)
        end

        def test_all_approve
          reviews = [
            { role_label: 'r1', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r2', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r3', raw_text: body('APPROVE'), status: :success }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'APPROVE', result[:reference_verdict]
          assert_equal 3, result[:vote_tally][:approve_count]
          assert_equal 0, result[:vote_tally][:reject_count]
        end

        def test_any_reject_means_revise
          reviews = [
            { role_label: 'r1', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r2', raw_text: body('REJECT'), status: :success },
            { role_label: 'r3', raw_text: body('APPROVE'), status: :success }
          ]
          result = Consensus.aggregate(reviews, '2/3 APPROVE', min_quorum: 2)
          assert_equal 'REVISE', result[:reference_verdict]
          assert_equal 1, result[:vote_tally][:reject_count]
        end

        def test_skip_excluded_from_denominator
          reviews = [
            { role_label: 'r1', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r2', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r3', raw_text: '', status: :error, error: { 'type' => 'timeout' } },
            { role_label: 'r4', raw_text: '', status: :skip }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'APPROVE', result[:reference_verdict]
          assert_equal 2, result[:vote_tally][:successful_count]
          assert_equal 2, result[:vote_tally][:skip_count]
          # threshold = ceil(2 * 0.75) = 2, approve = 2 >= 2
          assert_equal 2, result[:vote_tally][:threshold]
        end

        def test_insufficient_quorum
          reviews = [
            { role_label: 'r1', raw_text: 'APPROVE', status: :success },
            { role_label: 'r2', raw_text: '', status: :error },
            { role_label: 'r3', raw_text: '', status: :skip }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'INSUFFICIENT', result[:reference_verdict]
        end

        def test_structured_json_verdict
          reviews = [
            { role_label: 'r1', raw_text: '{"overall_verdict": "APPROVE", "reasoning": "the denominator arithmetic holds"}', status: :success },
            { role_label: 'r2', raw_text: '{"overall_verdict": "approve", "reasoning": "same, checked separately"}', status: :success },
            { role_label: 'r3', raw_text: '{"overall_verdict": "REJECT", "findings": ["P0: bug"]}', status: :success }
          ]
          result = Consensus.aggregate(reviews, '2/3 APPROVE', min_quorum: 2)
          assert_equal 'REVISE', result[:reference_verdict]
        end

        def test_ratio_threshold_with_degraded_quorum
          # "3/4 APPROVE" with 2 successful: threshold = ceil(2 * 0.75) = 2
          reviews = [
            { role_label: 'r1', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r2', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r3', raw_text: '', status: :skip },
            { role_label: 'r4', raw_text: '', status: :skip }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'APPROVE', result[:reference_verdict]
        end

        def test_not_enough_approvals_means_revise
          reviews = [
            { role_label: 'r1', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r2', raw_text: body('REVISED'), status: :success },
            { role_label: 'r3', raw_text: body('REVISE'), status: :success }
          ]
          result = Consensus.aggregate(reviews, '3/4 APPROVE', min_quorum: 2)
          assert_equal 'REVISE', result[:reference_verdict]
        end

        # INV-R5: the divergence-excluded tally's threshold is computed over
        # the NON-divergent seats — held with explicit numbers so the
        # denominator argument cannot silently revert to the full count.
        def test_excluding_divergent_threshold_uses_the_reduced_denominator
          reviews = [
            { role_label: 'r1', raw_text: body('APPROVE'), status: :success,
              model: 'm', model_declared: 'm', model_observed: 'x', model_divergence: true },
            { role_label: 'r2', raw_text: body('APPROVE'), status: :success,
              model: 'm', model_declared: 'm', model_observed: 'y', model_divergence: true },
            { role_label: 'r3', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r4', raw_text: body('APPROVE'), status: :success },
            { role_label: 'r5', raw_text: body('APPROVE'), status: :success }
          ]
          result = Consensus.aggregate(reviews, '3/5 APPROVE', min_quorum: 2)
          excl = result[:vote_tally][:excluding_divergent]
          assert_equal 3, excl[:successful_count]
          assert_equal 3, excl[:approve_count]
          # ceil(3 * 0.6) = 2 — NOT ceil(5 * 0.6) = 3.
          assert_equal 2, excl[:threshold]
          assert_equal 3, result[:vote_tally][:threshold]
        end

        def test_aggregate_findings_dedup
          # Simulate already-parsed verdicts (after extract_verdict)
          parsed = [
            { role_label: 'r1', raw_text: "P0: Missing error handling in dispatcher [consequence: a timeout kills the round]\n\nP1: Thread safety concern", status: :success, verdict: 'REJECT' },
            { role_label: 'r2', raw_text: "P0: Missing error handling in dispatcher timeout path [consequence: a timeout kills the round]", status: :success, verdict: 'REJECT' }
          ]
          findings = Consensus.aggregate_findings(parsed)

          # Both P0s share "Missing error handling in dispatcher" prefix → dedup
          p0_findings = findings.select { |f| f[:severity] == 'P0' }
          assert p0_findings.size >= 1, "Expected at least one P0 finding, got: #{findings.inspect}"
          # r1's P0 and r2's P0 should dedup; P1 is separate
          assert findings.size <= 3, "Expected dedup to reduce findings, got #{findings.size}"
        end

        # The weight axis (2026-08-06). The severity axis says what kind of
        # defect a finding is; the consequence clause says who is harmed if it
        # is never fixed. Measured on project_orientation_report R5: 3 of 7
        # P0s were factually correct and cost nobody anything, and both kinds
        # landed at P0 because the record had no second axis.
        def test_p0_without_consequence_is_recorded_at_p2
          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
                      raw_text: "P0: declared cap justification is inconsistent" }]
          f = Consensus.aggregate_findings(parsed).first
          assert_equal 'P2', f[:severity]
          assert_equal 'P0', f[:severity_stated]
          assert_equal 'consequence_missing', f[:severity_demoted]
        end

        def test_p0_with_empty_consequence_is_recorded_at_p2
          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
                      raw_text: "P0: declared cap justification is inconsistent [consequence:  ]" }]
          f = Consensus.aggregate_findings(parsed).first
          assert_equal 'P2', f[:severity]
          assert_equal 'P0', f[:severity_stated]
        end

        def test_p0_with_consequence_stays_p0_and_carries_it
          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
                      raw_text: "P0: rect frame disables overflow detection [consequence: broken figures ship undetected in published reports]" }]
          f = Consensus.aggregate_findings(parsed).first
          assert_equal 'P0', f[:severity]
          assert_equal 'broken figures ship undetected in published reports', f[:consequence]
          assert_nil f[:severity_stated]
        end

        # Only presence is checked, and only P0 is demoted: the rule is
        # mechanical by construction, like the substance rule — whether a
        # stated consequence is real or trivial is the orchestrator's call.
        def test_p1_without_consequence_is_not_demoted
          parsed = [{ role_label: 'r1', status: :success, verdict: 'REVISE',
                      raw_text: "P1: thread safety concern in counter" }]
          f = Consensus.aggregate_findings(parsed).first
          assert_equal 'P1', f[:severity]
        end

        # One reviewer states the harm, one does not: still one finding — the
        # dedup key strips the clause — and the stated consequence carries the
        # merged row's severity for both.
        def test_consequence_clause_does_not_split_the_dedup_group
          parsed = [
            { role_label: 'r1', status: :success, verdict: 'REJECT',
              raw_text: "P0: the reaper can signal its own group [consequence: the orchestrator is killed with the worker]" },
            { role_label: 'r2', status: :success, verdict: 'REVISE',
              raw_text: "P0: the reaper can signal its own group" }
          ]
          findings = Consensus.aggregate_findings(parsed)
          assert_equal 1, findings.size
          f = findings.first
          assert_equal 'P0', f[:severity]
          assert_equal %w[r1 r2].sort, f[:cited_by].sort
          assert_equal 'the orchestrator is killed with the worker', f[:consequence]
        end

        # The clause is read before the byte clamp cuts the tail — a P0 long
        # enough to lose its closing bracket to the bound must not be demoted
        # for complying (R1 finding, three seats).
        def test_consequence_beyond_the_byte_clamp_still_counts
          long_head = 'x' * (Sanitizer::FINDING_RECORD_MAX_LEN + 100)
          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
                      raw_text: "P0: #{long_head} [consequence: users lose data]" }]
          f = Consensus.aggregate_findings(parsed).first
          assert_equal 'P0', f[:severity]
          assert_equal 'users lose data', f[:consequence]
        end

        # First NON-empty clause counts: an empty clause followed by a stated
        # one must not demote past the stated harm.
        def test_first_empty_second_populated_clause_does_not_demote
          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
                      raw_text: 'P0: cap check bypassed [consequence: ] twice [consequence: operators ship a corrupt report]' }]
          f = Consensus.aggregate_findings(parsed).first
          assert_equal 'P0', f[:severity]
          assert_equal 'operators ship a corrupt report', f[:consequence]
        end

        # The demotion mark survives merging regardless of member order: a
        # group holding a demoted P0 says so even when the representative is
        # a member that was never demoted (R1 finding, three seats).
        def test_demotion_mark_survives_merging_in_either_order
          demoted = "P0: the reaper can signal its own group"
          plain   = "P2: the reaper can signal its own group"
          [[demoted, plain], [plain, demoted]].each do |first, second|
            parsed = [
              { role_label: 'r1', status: :success, verdict: 'REJECT', raw_text: first },
              { role_label: 'r2', status: :success, verdict: 'REVISE', raw_text: second }
            ]
            findings = Consensus.aggregate_findings(parsed)
            assert_equal 1, findings.size
            f = findings.first
            assert_equal 'P2', f[:severity]
            assert_equal 'P0', f[:severity_stated],
                         "mark lost for order #{[first, second].inspect}"
            assert_equal 'consequence_missing', f[:severity_demoted]
          end
        end

        # A row that merged to P0 carries no demotion mark: some member
        # stated the harm and nothing was demoted away from what the record
        # shows.
        def test_no_demotion_mark_on_a_row_that_merged_to_p0
          parsed = [
            { role_label: 'r1', status: :success, verdict: 'REJECT',
              raw_text: 'P0: the reaper can signal its own group [consequence: the orchestrator dies with the worker]' },
            { role_label: 'r2', status: :success, verdict: 'REVISE',
              raw_text: 'P0: the reaper can signal its own group' }
          ]
          f = Consensus.aggregate_findings(parsed).first
          assert_equal 'P0', f[:severity]
          assert_nil f[:severity_stated]
        end

        # The new fields reach the record: string-keyed rows through the same
        # bound the tools apply, nothing dropped and reviewer text bounded.
        def test_consequence_fields_survive_the_record_path
          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
                      raw_text: "P0: cap check bypassed\n\nP0: rect frame hides overflow [consequence: broken figures ship in published reports]" }]
          rows = Consensus.aggregate_findings(parsed)
                          .map { |f| f.transform_keys(&:to_s) }
          bound = Sanitizer.bound_findings_for_record(rows)
          demoted = bound.find { |f| f['severity_stated'] }
          assert_equal 'P0', demoted['severity_stated']
          assert_equal 'consequence_missing', demoted['severity_demoted']
          kept = bound.find { |f| f['consequence'] }
          assert_equal 'broken figures ship in published reports', kept['consequence']
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

        # v0.7 INV-R1: the vocabulary is the three canonical words plus tense
        # forms, nothing else. FAILED used to be read as a rejection; it is now
        # outside the vocabulary, the reply states no verdict, and the word the
        # reviewer wrote survives in the record beside the closed reason token.
        def test_a_word_outside_the_vocabulary_is_refused_and_recorded
          stated = { role_label: 'r1', raw_text: "**Overall Verdict**: FAILED\n\nP0: critical bug", status: :success }
          out = Consensus.extract_verdict(stated)
          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason]
          assert_equal 'FAILED', out[:stated_text]

          in_prose = { role_label: 'r1', raw_text: 'FAIL - critical bug found', status: :success }
          out = Consensus.extract_verdict(in_prose)
          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason]
          # No header, no offered word: the record shows silence, not a guess.
          assert_nil out[:stated_text]
        end

        # Tense and inflection forms of the three words stay readable.
        def test_tense_forms_of_the_canonical_words_are_read
          { 'APPROVED' => 'APPROVE', 'REVISED' => 'REVISE',
            'REJECTED' => 'REJECT', 'approves' => 'APPROVE' }.each do |form, canonical|
            review = { role_label: 'r1', raw_text: body(form), status: :success }
            assert_equal canonical, Consensus.extract_verdict(review)[:verdict], form
          end
        end

        # R12 P1: a JSON reply whose overall_verdict key appears twice states
        # two things under one name; JSON.parse would keep the second silently.
        # The document is refused as a document, so the reply states no verdict.
        def test_duplicate_overall_verdict_key_states_no_verdict
          review = { role_label: 'r1', status: :success,
                     raw_text: '{"overall_verdict": "REJECT", "overall_verdict": "APPROVE", "reasoning": "x"}' }
          out = Consensus.extract_verdict(review)
          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason]
        end

        # INV-E2 asks two things of a reply that counts: that it carry a
        # verdict and that it have substance. A reply stating no judgement
        # leaves the denominator rather than being counted as a REVISE its
        # author never gave. This replaced a conservative-REVISE default that
        # was worse than it looked — an opening sentence with no judgement in
        # it, the exact shape that retired one roster occupant, used to block
        # convergence on nobody's verdict.
        def test_a_reply_stating_no_verdict_leaves_the_denominator
          review = { role_label: 'r1', raw_text: 'I have mixed feelings about this.', status: :success }
          result = Consensus.extract_verdict(review)

          assert_equal 'SKIP', result[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, result[:skip_reason]
        end

        # The retired occupant's actual failure shape: long enough to pass any
        # substance rule, and carrying no judgement at all.
        def test_an_opening_sentence_with_no_judgement_leaves_the_denominator
          review = { role_label: 'r1', status: :success,
                     raw_text: 'I will review this design document now and provide my assessment.' }
          result = Consensus.extract_verdict(review)

          assert_equal 'SKIP', result[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, result[:skip_reason]
          # It is not insubstantial — it is substantial and says nothing. The
          # record has to keep those apart or the next reader retunes the
          # wrong rule, which is how three rebuilds of the substance rule
          # missed this case.
          assert Consensus.substantive?(review[:raw_text])
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

        def test_seat_access_note_inline_only
          inline = PromptBuilder.build_messages(
            artifact_content: 'test code here',
            artifact_name: 'test_artifact',
            review_type: 'implementation',
            review_round: 1
          )
          assert_includes inline[0]['content'], '<seat_access>'
          assert_includes inline[0]['content'], 'verdict line first'

          by_ref = PromptBuilder.build_messages(
            artifact_name: 'test_artifact',
            review_type: 'implementation',
            review_round: 1,
            artifact_reference: { path: 'log/x.md', sha256: 'a' * 64 }
          )
          refute_includes by_ref[0]['content'], '<seat_access>',
            'by_reference delivery keeps its own cannot-read instruction; the note must not contradict it'
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
          # The round number is orchestrator-side bookkeeping (2026-08-06):
          # telling a reviewer which round it is in frames counts as compared,
          # and selects for finding-production over finding-weight.
          refute_includes content, 'R2'
          refute_includes content, 'Round:'
          assert_includes content, 'Missing validation'
          assert_includes content, 'r1, r2'
        end

        # The weight axis (2026-08-06): the contract demands a consequence
        # clause for P0 and says what happens without one, so the demotion in
        # aggregation is a rule the reviewer was told, not a silent rewrite.
        def test_contract_requires_consequence_for_p0
          contract = PromptBuilder.structured_output_contract
          assert_includes contract, '[consequence:'
          assert_includes contract, 'recorded at P2'
        end
      end

      # TestOrchestratorExclusion was removed with the helpers it exercised.
      # Deciding which slot leaves the observer set now happens in one place
      # (ObserverSet, INV-P2) instead of two, and is covered by
      # test_observer_set.rb — including the case these tests could not have
      # caught, where the caller and the persona name the same model.

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
          result = PendingState.cleanup_expired!
          assert_equal 1, result[:removed]
          assert_equal 0, result[:skipped_errors]
          assert_nil PendingState.load(token)
        end

        def test_cleanup_keeps_collected_within_retention
          token = PendingState.generate_token
          PendingState.write(token, {
            'token' => token,
            'collect_deadline' => (Time.now - 100).iso8601,
            'collected' => true
          })
          result = PendingState.cleanup_expired!(retain_collected_seconds: 3600)
          assert_equal 0, result[:removed]
          refute_nil PendingState.load(token)
        end

        def test_cleanup_removes_collected_past_retention
          token = PendingState.generate_token
          PendingState.write(token, {
            'token' => token,
            'collect_deadline' => (Time.now - 7200).iso8601,
            'collected' => true
          })
          result = PendingState.cleanup_expired!(retain_collected_seconds: 3600)
          assert_equal 1, result[:removed]
        end

        def test_cleanup_skip_token_preserves_target
          token = PendingState.generate_token
          PendingState.write(token, {
            'token' => token,
            'collect_deadline' => (Time.now - 100).iso8601,
            'collected' => false
          })
          result = PendingState.cleanup_expired!(skip_token: token)
          assert_equal 0, result[:removed]
          refute_nil PendingState.load(token)
        end

        def test_cleanup_counts_errors_on_corrupt_file
          FileUtils.mkdir_p(PendingState.root_dir)
          corrupt_path = File.join(PendingState.root_dir, 'garbage.json')
          File.write(corrupt_path, 'not-json-{{{{')
          result = PendingState.cleanup_expired!
          # Corrupt file without collect_deadline is skipped silently
          # (no error raised) but counted if JSON parse fails.
          assert_operator result[:skipped_errors], :>=, 1
        ensure
          File.unlink(corrupt_path) if corrupt_path && File.exist?(corrupt_path)
        end

        def test_load_returns_nil_on_enoent_race
          token = PendingState.generate_token
          PendingState.write(token, { 'token' => token })
          # Simulate race by pre-deleting the file between exist? and read.
          # Here we just delete it first; load should return nil, not raise.
          File.unlink(PendingState.path_for(token))
          assert_nil PendingState.load(token)
        end

        def test_delete_is_idempotent_on_enoent
          token = PendingState.generate_token
          PendingState.write(token, { 'token' => token })
          assert_equal true, PendingState.delete(token)
          # Second delete: file gone, should not raise.
          assert_equal false, PendingState.delete(token)
        end

        def test_write_tmp_suffix_has_random_component
          token = PendingState.generate_token
          # Snapshot state before and during write: confirm no fixed tmp name
          # via inspection — we simply verify write returns the final path
          # and no .tmp.* file lingers.
          path = PendingState.write(token, { 'token' => token })
          assert_equal PendingState.path_for(token), path
          tmp_files = Dir.glob(File.join(PendingState.root_dir, '*.tmp.*'))
          assert_empty tmp_files
        end

        def test_cleanup_removes_orphaned_tmp_files
          FileUtils.mkdir_p(PendingState.root_dir)
          orphan = File.join(PendingState.root_dir,
                             "#{PendingState.generate_token}.json.tmp.99999.abc123")
          File.write(orphan, '{}')
          # Backdate mtime to 2 hours ago
          old = Time.now - 7200
          File.utime(old, old, orphan)
          result = PendingState.cleanup_expired!
          refute File.exist?(orphan), 'orphaned tmp should be removed'
          assert_operator result[:removed], :>=, 1
        end

        def test_cleanup_removes_stale_file_without_deadline
          # Simulates schema-drift / partial-write where a .json file lacks
          # collect_deadline. Round 1 bug: these lived forever.
          token = PendingState.generate_token
          PendingState.write(token, { 'token' => token, 'unrelated' => 'x' })
          path = PendingState.path_for(token)
          old = Time.now - 90_000 # > 24h
          File.utime(old, old, path)
          result = PendingState.cleanup_expired!
          refute File.exist?(path), 'stale no-deadline file should be removed'
          assert_operator result[:removed], :>=, 1
        end

        def test_cleanup_keeps_fresh_file_without_deadline
          # A file that lacks deadline but is recent should NOT be removed
          # (could be mid-creation by another process).
          token = PendingState.generate_token
          PendingState.write(token, { 'token' => token })
          result = PendingState.cleanup_expired!
          refute_nil PendingState.load(token), 'fresh no-deadline file must survive'
        end

        def test_cleanup_removes_stale_corrupt_json
          # Corrupt JSON without deadline should also age out via stale window.
          FileUtils.mkdir_p(PendingState.root_dir)
          corrupt = File.join(PendingState.root_dir,
                              "#{PendingState.generate_token}.json")
          File.write(corrupt, 'not-valid-json-{{{')
          old = Time.now - 90_000
          File.utime(old, old, corrupt)
          result = PendingState.cleanup_expired!
          refute File.exist?(corrupt), 'stale corrupt json should be removed'
        end

        def test_load_detailed_distinguishes_missing_from_corrupt
          token = PendingState.generate_token
          # Missing
          result = PendingState.load_detailed(token)
          assert_equal :missing, result[:status]

          # Invalid token
          result = PendingState.load_detailed('not-a-uuid')
          assert_equal :invalid_token, result[:status]

          # Corrupt
          FileUtils.mkdir_p(PendingState.root_dir)
          File.write(PendingState.path_for(token), 'not-json')
          result = PendingState.load_detailed(token)
          assert_equal :corrupt, result[:status]
          assert_nil result[:data]
          refute_nil result[:error]

          # OK
          PendingState.write(token, { 'token' => token, 'data' => 'x' })
          result = PendingState.load_detailed(token)
          assert_equal :ok, result[:status]
          assert_equal 'x', result[:data]['data']
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

        # v0.7 INV-R4: convening every persona is not a condition of
        # acceptance. One row is a seat that counts through the ordinary
        # rules; zero rows is a seat with no substantive verdict, returned as
        # its own skip row with a token cause — never the else-branch APPROVE.
        def test_single_persona_submission_is_accepted
          entry = PersonaAssembly.assemble([base_review('only', 'APPROVE')], 'claude-opus-4-7')
          assert_equal 'APPROVE', entry[:verdict]
          assert_equal :success, entry[:status]
        end

        def test_empty_persona_submission_is_a_skip_seat_not_an_approve
          entry = PersonaAssembly.assemble([], 'claude-opus-4-7')
          assert_equal :skip, entry[:status]
          assert_nil entry[:verdict]
          assert_equal 'empty_persona_submission', entry[:error]['message']

          parsed = Consensus.extract_verdict(entry)
          assert_equal 'SKIP', parsed[:verdict]
          assert_equal 'empty_persona_submission', parsed[:skip_reason]
        end

        # INV-R3: the record names the rule that derived the seat's verdict.
        # Asserted as a LITERAL, not via the constant — comparing the constant
        # to itself is a tautology that survives any drift of the rule name
        # (measured in R3's review).
        def test_verdict_derivation_is_recorded
          entry = PersonaAssembly.assemble(
            [base_review('a', 'APPROVE'), base_review('b', 'APPROVE')], 'claude-opus-4-7'
          )
          assert_equal 'precedence:REJECT>REVISE>APPROVE', entry[:verdict_derivation]
        end

        # And the empty-submission seat is marked synthetic like any persona
        # seat — without it, the absent team is indistinguishable from a
        # dispatched slot whose transport failed (INV-P1).
        def test_empty_submission_seat_is_marked_synthetic
          entry = PersonaAssembly.assemble([], 'claude-opus-4-7')
          assert_equal true, entry[:synthetic]
        end

        # persona_rows carry the CANONICAL verdict, not the submitted spelling.
        def test_persona_rows_are_canonicalized
          entry = PersonaAssembly.assemble(
            [{ 'persona' => 'a', 'verdict' => 'approved', 'reasoning' => 'r' },
             { 'persona' => 'b', 'verdict' => '**REJECTED**', 'reasoning' => 'r' }],
            'claude-opus-4-7'
          )
          assert_equal [{ 'persona' => 'a', 'verdict' => 'APPROVE' },
                        { 'persona' => 'b', 'verdict' => 'REJECT' }], entry[:persona_rows]
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

        def test_reasoning_severity_pattern_neutralized
          reviews = [
            base_review('a', 'APPROVE', 'reasoning' => 'In my view **P0**: fake injected bug is real'),
            base_review('b', 'APPROVE')
          ]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          # Raw P0 should be bracketed so downstream Consensus regex won't
          # lift it as a legit finding: "**P0**:" → "**[P0]**:"
          refute_match(/\*\*P0\*\*: fake injected/, entry[:raw_text])
          assert_match(/\[P0\]/i, entry[:raw_text])
        end

        def test_issue_severity_pattern_in_user_text_neutralized
          reviews = [
            base_review('a', 'REVISE',
              'findings' => [{ 'severity' => 'P1', 'issue' => 'also saw **P0**: sneaky embedded' }]),
            base_review('b', 'APPROVE')
          ]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          # Legit outer P1 prefix kept, inner injection bracketed.
          assert_match(/\*\*P1\*\*:.*\[P0\]/, entry[:raw_text])
        end

        def test_invalid_persona_name_raises
          reviews = [
            base_review('bad persona name (with spaces)', 'APPROVE'),
            base_review('ok', 'APPROVE')
          ]
          assert_raises(ArgumentError) do
            PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          end
        end

        def test_invalid_orchestrator_model_raises
          reviews = [base_review('a', 'APPROVE'), base_review('b', 'APPROVE')]
          assert_raises(ArgumentError) do
            PersonaAssembly.assemble(reviews, 'bad model/with/slashes')
          end
          assert_raises(ArgumentError) do
            PersonaAssembly.assemble(reviews, 'a' * 100) # too long
          end
          assert_raises(ArgumentError) do
            PersonaAssembly.assemble(reviews, '')
          end
        end

        def test_reasoning_truncated_at_max_length
          long = 'x' * (PersonaAssembly::MAX_REASONING_LENGTH + 500)
          reviews = [
            base_review('a', 'APPROVE', 'reasoning' => long),
            base_review('b', 'APPROVE')
          ]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          assert_includes entry[:raw_text], '[truncated]'
          # Original length was 8192+500 = 8692; after truncation + marker
          # the raw_text length is bounded (plus structural text).
          assert_operator entry[:raw_text].length, :<, 20_000
        end

        def test_findings_truncated_at_max_count
          many = (1..(PersonaAssembly::MAX_FINDINGS_PER_PERSONA + 5)).map do |i|
            { 'severity' => 'P2', 'issue' => "finding-#{i}" }
          end
          reviews = [
            base_review('a', 'REVISE', 'findings' => many),
            base_review('b', 'APPROVE')
          ]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          # Count occurrences of "finding-" in raw_text — should cap at MAX.
          count = entry[:raw_text].scan(/finding-\d+/).size
          assert_equal PersonaAssembly::MAX_FINDINGS_PER_PERSONA, count
        end

        # v0.7 INV-R1: the alias vocabulary is gone. A persona verdict in a
        # former alias is refused at validate! — the submission is authored by
        # the caller and can be restated — while tense forms of the three
        # canonical words remain admissible.
        def test_alias_verdicts_are_refused_at_validation
          %w[NO-GO NACK DENY VETO FAILURE LGTM REWORK].each do |word|
            err = assert_raises(ArgumentError, word) do
              PersonaAssembly.assemble(
                [{ 'persona' => 'a', 'verdict' => word, 'reasoning' => 'r' },
                 { 'persona' => 'b', 'verdict' => 'APPROVE', 'reasoning' => 'r' }],
                'claude-opus-4-7'
              )
            end
            assert_match(/not a verdict/, err.message, word)
          end
        end

        def test_tense_forms_drive_the_team_verdict
          { 'REJECTED' => 'REJECT', 'revised' => 'REVISE',
            'APPROVED' => 'APPROVE' }.each do |word, expected|
            entry = PersonaAssembly.assemble(
              [{ 'persona' => 'a', 'verdict' => word, 'reasoning' => 'r' },
               { 'persona' => 'b', 'verdict' => 'APPROVED', 'reasoning' => 'r' }],
              'claude-opus-4-7'
            )
            assert_equal expected, entry[:verdict], word
          end
        end

        def test_a_prose_verdict_field_is_refused
          # A declared verdict field carrying prose is not a verdict. The
          # word-search used until round 13 read "approve but reject on
          # security" as REJECT; round 13's REVISE fallback manufactured a
          # vote nobody cast. Round 14 refuses the submission at validate!,
          # so the caller restates the verdict and no vote is guessed at.
          err = assert_raises(ArgumentError) do
            PersonaAssembly.assemble(
              [{ 'persona' => 'a', 'verdict' => 'approve but reject on security', 'reasoning' => 'r' },
               { 'persona' => 'b', 'verdict' => 'APPROVE', 'reasoning' => 'r' }],
              'claude-opus-4-7'
            )
          end

          assert_match(/not a verdict/, err.message)
        end

        def test_safe_truncate_handles_multibyte_utf8
          # Japanese string where characters are multi-byte
          text = 'あいうえお' * 100  # 500 codepoints, ~1500 UTF-8 bytes
          truncated = PersonaAssembly.safe_truncate(text, 50)
          # Must end cleanly on a char boundary + have marker
          assert truncated.valid_encoding?, 'truncated string must be valid UTF-8'
          assert_includes truncated, '[truncated]'
        end

        def test_safe_truncate_scrubs_ascii_8bit_input
          # Simulate JSON parser returning binary-tagged string with non-UTF8 bytes
          bad = "\xFF\xFE hello \xE3\x81\x82".dup.force_encoding('ASCII-8BIT')
          truncated = PersonaAssembly.safe_truncate(bad, 100)
          assert truncated.valid_encoding?
        end

        def test_safe_truncate_short_text_unchanged
          truncated = PersonaAssembly.safe_truncate('short', 100)
          assert_equal 'short', truncated
          refute_includes truncated, '[truncated]'
        end

        def test_synthetic_flag_present
          reviews = [base_review('a', 'APPROVE'), base_review('b', 'APPROVE')]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          assert entry[:synthetic], 'synthetic flag should be true on assembled entry'
        end

        def test_invalid_finding_severity_falls_back_to_p2
          reviews = [
            base_review('a', 'REVISE',
              'findings' => [{ 'severity' => 'CRITICAL', 'issue' => 'x' }]),
            base_review('b', 'APPROVE')
          ]
          entry = PersonaAssembly.assemble(reviews, 'claude-opus-4-7')
          # Unrecognized severity defaults to P2 for Consensus compatibility.
          assert_match(/\*\*P2\*\*: x/, entry[:raw_text])
        end
      end

      class TestDelegateStrategy < Minitest::Test
        # v0.6: delegate_response records how the observer set was built, so
        # these tests hand it a minimal one. What the set contains is not what
        # they are testing — that lives in test_observer_set.rb.
        # v0.6: delegate_response records how the observer set was built and
        # validates the model that will stand in the persona position, so these
        # tests hand it a set whose persona declaration is the thing under test.
        def stub_observers(persona = 'claude-opus-4-7')
          ObserverSet.build(
            roster: [{ provider: 'codex', model: 'gpt-5.5', role_label: 'codex' }],
            orchestrator_model: persona
          )
        end

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

        # Replace WorkerSpawner.spawn with a no-op for the duration of the block.
        # Avoids actually forking a detached worker process during async tests.
        def with_stubbed_worker_spawner
          singleton = WorkerSpawner.singleton_class
          original = WorkerSpawner.method(:spawn)
          singleton.send(:define_method, :spawn) { |**_kwargs| true }
          begin
            yield
          ensure
            singleton.send(:define_method, :spawn, original)
          end
        end

        # v0.7 INV-R4: the token directory (with its marker) is created at
        # dispatch time by call(); these tests enter the delegate helpers
        # directly, so they create the run token the same way call() does.
        def make_run_token
          @tool.send(:create_token_dir!)
        end

        # The three partition_for_strategy tests that stood here went with the
        # method. Their cases (delegate drops the match, subprocess keeps it,
        # exclude drops it) are in test_observer_set.rb, where they are stated
        # against the observer set rather than against a helper that only saw
        # half of it.

        def test_delegate_response_writes_pending_state
          subprocess_results = [
            { role_label: 'codex', provider: 'codex', model: 'codex-default',
              raw_text: 'APPROVE', elapsed_seconds: 10, error: nil, status: :success }
          ]
          result = @tool.send(:delegate_response,
            token: make_run_token, review_spec: nil,
            raw_results: subprocess_results,
            arguments: { 'review_type' => 'design', 'artifact_name' => 'test' },
            config: {},
            orchestrator_model: 'claude-opus-4-7',
            observers: stub_observers,
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
          state = PendingState.load_state(payload['collect_token'])
          assert_equal 'claude-opus-4-7', state['orchestrator_model']
          assert_equal '3/4 APPROVE', state['convergence_rule']
          assert_equal 1, state['subprocess_results'].size

          # And it is written in the layout collect takes its lock in. This
          # path used to write a single legacy file, so the flock guarding
          # against two concurrent collects was skipped for every synchronous
          # delegation — silently, because nothing else about the run differs.
          assert File.exist?(PendingState.collect_lock_path(payload['collect_token']))
        end

        def test_delegate_response_requires_orchestrator_model
          result = @tool.send(:delegate_response,
            token: make_run_token, review_spec: nil,
            raw_results: [
              { role_label: 'codex', provider: 'codex', model: 'm',
                raw_text: 'APPROVE', elapsed_seconds: 1, error: nil, status: :success }
            ],
            arguments: { 'review_type' => 'design', 'artifact_name' => 'test' },
            config: {},
            orchestrator_model: nil,
            observers: stub_observers(nil),
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/orchestrator_model/, payload['error'])
        end

        # The declaration that gets validated is the one that will stand in the
        # persona position, which is what a caller can actually get wrong.
        def test_delegate_rejects_invalid_orchestrator_model
          result = @tool.send(:delegate_response,
            token: make_run_token, review_spec: nil,
            raw_results: [
              { role_label: 'codex', provider: 'codex', model: 'm',
                raw_text: 'APPROVE', elapsed_seconds: 1, error: nil, status: :success }
            ],
            arguments: { 'review_type' => 'design', 'artifact_name' => 'test' },
            config: {},
            orchestrator_model: 'bad/model/name',
            observers: stub_observers('bad/model/name'),
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/invalid orchestrator_model/, payload['error'])
        end

        def test_delegate_fails_when_no_subprocess_reviewers
          # If all reviewers matched the orchestrator_model, raw_results is [].
          result = @tool.send(:delegate_response,
            token: make_run_token, review_spec: nil,
            raw_results: [],
            arguments: { 'review_type' => 'design', 'artifact_name' => 'test' },
            config: {},
            orchestrator_model: 'claude-opus-4-7',
            observers: stub_observers,
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/requires at least one non-orchestrator reviewer/, payload['error'])
        end

        def test_delegate_response_fails_when_all_subprocess_failed
          failed = [
            { role_label: 'codex', provider: 'codex',
              error: { 'type' => 'ApiError', 'message' => 'boom' },
              elapsed_seconds: 2.5, status: :error }
          ]
          result = @tool.send(:delegate_response,
            token: make_run_token, review_spec: nil,
            raw_results: failed,
            arguments: { 'review_type' => 'design', 'artifact_name' => 'test' },
            config: {},
            orchestrator_model: 'claude-opus-4-7',
            observers: stub_observers,
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/all subprocess reviewers failed/, payload['error'])
          # New richer failure info
          failure = payload['subprocess_failures'].first
          assert_equal 'codex', failure['role_label']
          assert_equal 'ApiError', failure['error_class']
          assert_equal 'boom', failure['error_message']
          assert_equal 2.5, failure['elapsed_seconds']
        end

        def test_delegate_uses_config_deadline
          subprocess_results = [
            { role_label: 'codex', provider: 'codex', model: 'm',
              raw_text: 'APPROVE', elapsed_seconds: 1, error: nil, status: :success }
          ]
          result = @tool.send(:delegate_response,
            token: make_run_token, review_spec: nil,
            raw_results: subprocess_results,
            arguments: { 'review_type' => 'design', 'artifact_name' => 'x' },
            config: { 'delegation' => { 'collect_deadline_seconds' => 60 } },
            orchestrator_model: 'claude-opus-4-7',
            observers: stub_observers,
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          deadline = Time.iso8601(payload['must_collect_by'])
          # Should be ~60s from now, not the default 1800s
          assert_in_delta 60, deadline - Time.now, 5
        end

        # Bug #1 fix: collect_deadline_seconds_override must extend the sync
        # delegate_response deadline beyond the config default.
        def test_delegate_sync_respects_collect_deadline_override
          subprocess_results = [
            { role_label: 'codex', provider: 'codex', model: 'm',
              raw_text: 'APPROVE', elapsed_seconds: 1, error: nil, status: :success }
          ]
          result = @tool.send(:delegate_response,
            token: make_run_token, review_spec: nil,
            raw_results: subprocess_results,
            arguments: {
              'review_type' => 'design', 'artifact_name' => 'x',
              'collect_deadline_seconds_override' => 3000
            },
            config: { 'delegation' => { 'collect_deadline_seconds' => 60 } },
            orchestrator_model: 'claude-opus-4-7',
            observers: stub_observers,
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          deadline = Time.iso8601(payload['must_collect_by'])
          # Override (3000s) wins over config (60s)
          assert_in_delta 3000, deadline - Time.now, 5
        end

        # Bug #3 fix: when no override and no config, default is now 1800s (was 600s).
        def test_delegate_sync_default_deadline_is_1800
          subprocess_results = [
            { role_label: 'codex', provider: 'codex', model: 'm',
              raw_text: 'APPROVE', elapsed_seconds: 1, error: nil, status: :success }
          ]
          result = @tool.send(:delegate_response,
            token: make_run_token, review_spec: nil,
            raw_results: subprocess_results,
            arguments: { 'review_type' => 'design', 'artifact_name' => 'x' },
            config: {},
            orchestrator_model: 'claude-opus-4-7',
            observers: stub_observers,
            convergence_rule: '3/4 APPROVE',
            min_quorum: 2,
            review_round: 1,
            complexity: 'high'
          )
          payload = JSON.parse(result.first[:text])
          deadline = Time.iso8601(payload['must_collect_by'])
          assert_in_delta 1800, deadline - Time.now, 5
        end

        # Bug #1 fix (async): when timeout_seconds_override raises the worker
        # self_timeout above the configured collect_deadline, the deadline must
        # auto-extend to cover the worker lifespan + poll margin. Otherwise the
        # token expires while the worker is still healthy.
        def test_delegate_async_auto_extends_deadline_to_worker_lifespan
          reviewers = [{ provider: 'codex', model: 'codex-default', role_label: 'codex' }]
          arguments = {
            'review_type' => 'design',
            'artifact_name' => 'x',
            'timeout_seconds_override' => 1500
          }
          config = {
            'delegation' => {
              'collect_deadline_seconds' => 600,
              'parallel' => {
                'worker_self_timeout_multiplier' => 1.5,
                'worker_self_timeout_floor_seconds' => 60,
                'poll_interval_seconds' => 0.5
              }
            }
          }
          parallel_cfg = config.dig('delegation', 'parallel')

          result = nil
          with_stubbed_worker_spawner do
            result = @tool.send(:delegate_response_async,
              token: make_run_token, review_spec: nil,
              reviewers: reviewers,
              messages: [{ 'role' => 'user', 'content' => 'x' }],
              system_prompt: 'sys',
              arguments: arguments,
              config: config,
              orchestrator_model: 'claude-opus-4-7',
            observers: stub_observers,
              convergence_rule: '3/4 APPROVE',
              min_quorum: 2,
              review_round: 1,
              complexity: 'high',
              review_context: 'independent',
              max_concurrent: 2,
              timeout_secs: 1500,
              parallel_cfg: parallel_cfg
            )
          end
          payload = JSON.parse(result.first[:text])
          assert_equal 'delegation_pending', payload['status']
          deadline = Time.iso8601(payload['must_collect_by'])
          # worker_lifespan = 1500*1.5 + 60 = 2310; +10s poll margin = 2320
          # Deadline must be at least worker_lifespan + margin, NOT 600
          assert_operator deadline - Time.now, :>=, 2320 - 5
        end

        # R2 P0: the async write leg, driven through the real helper — the
        # state must carry the declared inputs (INV-R6/R3).
        def test_async_state_carries_declared_inputs
          result = nil
          with_stubbed_worker_spawner do
            result = @tool.send(:delegate_response_async,
              token: make_run_token,
              review_spec: { 'path' => 'docs/s.md', 'sha256' => 'abc' },
              reviewers: [{ provider: 'codex', model: 'codex-default', role_label: 'codex' }],
              messages: [{ 'role' => 'user', 'content' => 'x' }],
              system_prompt: 'sys',
              arguments: { 'review_type' => 'design', 'artifact_name' => 'x',
                           'persona_count_declared' => 4 },
              config: {},
              orchestrator_model: 'claude-opus-4-7',
              observers: stub_observers,
              convergence_rule: '3/4 APPROVE', min_quorum: 2, review_round: 1,
              complexity: 'high', review_context: 'independent',
              max_concurrent: 2, timeout_secs: 300, parallel_cfg: {}
            )
          end
          payload = JSON.parse(result.first[:text])
          assert_equal 'delegation_pending', payload['status']
          state = PendingState.load_state(payload['collect_token'])
          assert_equal({ 'path' => 'docs/s.md', 'sha256' => 'abc' }, state['review_spec'])
          assert_equal 4, state['persona_count_declared']
        end

        # R2 (fix 4): a spawn failure notes its cause AND reduces the dir, so
        # request.json (full prompts) is not pinned forever by the note.
        def test_spawn_failure_notes_and_reduces_to_trace
          singleton = WorkerSpawner.singleton_class
          original = WorkerSpawner.method(:spawn)
          singleton.send(:define_method, :spawn) { |**_k| raise 'no spawn' }
          result = nil
          begin
            result = @tool.send(:delegate_response_async,
              token: make_run_token, review_spec: nil,
              reviewers: [{ provider: 'codex', model: 'codex-default', role_label: 'codex' }],
              messages: [{ 'role' => 'user', 'content' => 'x' }],
              system_prompt: 'sys',
              arguments: { 'review_type' => 'design', 'artifact_name' => 'x' },
              config: {},
              orchestrator_model: 'claude-opus-4-7',
              observers: stub_observers,
              convergence_rule: '3/4 APPROVE', min_quorum: 2, review_round: 1,
              complexity: 'high', review_context: 'independent',
              max_concurrent: 2, timeout_secs: 300, parallel_cfg: {}
            )
          ensure
            singleton.send(:define_method, :spawn, original)
          end
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']

          dirs = Dir.glob(File.join(PendingState.root_dir, '*'))
          assert_equal 1, dirs.size
          files = Dir.glob(File.join(dirs.first, '*')).map { |f| File.basename(f) }.sort
          assert_equal ['reaped.json'], files,
                       'the trace must hold the note and nothing else (no marker was written by this direct-entry test)'
          reaped = JSON.parse(File.read(File.join(dirs.first, 'reaped.json')))
          assert_equal 'worker_spawn_failed:RuntimeError', reaped['reason']
        end

        # Async: explicit collect_deadline_seconds_override above the auto-min wins.
        def test_delegate_async_respects_explicit_override
          reviewers = [{ provider: 'codex', model: 'codex-default', role_label: 'codex' }]
          arguments = {
            'review_type' => 'design',
            'artifact_name' => 'x',
            'collect_deadline_seconds_override' => 5000
          }
          config = {
            'delegation' => {
              'collect_deadline_seconds' => 600,
              'parallel' => {
                'worker_self_timeout_multiplier' => 1.5,
                'worker_self_timeout_floor_seconds' => 60,
                'poll_interval_seconds' => 0.5
              }
            }
          }
          parallel_cfg = config.dig('delegation', 'parallel')

          result = nil
          with_stubbed_worker_spawner do
            result = @tool.send(:delegate_response_async,
              token: make_run_token, review_spec: nil,
              reviewers: reviewers,
              messages: [{ 'role' => 'user', 'content' => 'x' }],
              system_prompt: 'sys',
              arguments: arguments,
              config: config,
              orchestrator_model: 'claude-opus-4-7',
            observers: stub_observers,
              convergence_rule: '3/4 APPROVE',
              min_quorum: 2,
              review_round: 1,
              complexity: 'high',
              review_context: 'independent',
              max_concurrent: 2,
              timeout_secs: 300,
              parallel_cfg: parallel_cfg
            )
          end
          payload = JSON.parse(result.first[:text])
          deadline = Time.iso8601(payload['must_collect_by'])
          assert_in_delta 5000, deadline - Time.now, 5
        end
      end

      # Worker-death recovery (2026-08-06, R3): a stale heartbeat on ONE stuck
      # seat used to discard every completed seat's reply, because the only
      # exit from the crash branch was total loss. The worker now persists
      # each seat as it completes (partial_results.json), and collect reads
      # that file back: finished seats count, unreached seats enter the
      # denominator as skip rows naming the loss.
      class TestCollectWorkerCrashRecovery < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr-crash-')
          @orig_cwd = Dir.pwd
          Dir.chdir(@tmp)
          @collect = Tools::MultiLlmReviewCollect.new
          @token = PendingState.generate_token
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'token' => @token,
            'created_at' => Time.now.iso8601,
            'collect_deadline' => (Time.now + 600).iso8601,
            'review_type' => 'design',
            'artifact_name' => 'test',
            'review_round' => 1,
            'complexity' => 'high',
            'orchestrator_model' => 'claude-opus-5',
            'convergence_rule' => '3/4 APPROVE',
            'min_quorum' => 2,
            'parallel' => true,
            'subprocess_status' => 'crashed',
            'crash_reason' => 'heartbeat_stale'
          })
          PendingState.write_request(@token, {
            'reviewers' => [
              { 'provider' => 'codex', 'model' => 'gpt-5.5', 'role_label' => 'codex_gpt5.5' },
              { 'provider' => 'cursor', 'model' => 'composer-2.5', 'role_label' => 'cursor' }
            ]
          })
        end

        def teardown
          Dir.chdir(@orig_cwd)
          FileUtils.rm_rf(@tmp)
        end

        def persona_reviews
          [
            { 'persona' => 'architect', 'verdict' => 'APPROVE',
              'reasoning' => 'walked the layering; holds together', 'findings' => [] },
            { 'persona' => 'security', 'verdict' => 'APPROVE',
              'reasoning' => 'no exposure found on the seams', 'findings' => [] }
          ]
        end

        # Recovery is gated on the reaper CONFIRMING the worker's death, and
        # the reaper needs a worker.pid it can cross-check. A real, already
        # exited process (own process group, so terminate! signals a group
        # that is genuinely gone) makes the reaper answer :already_dead.
        def write_dead_worker_pid
          pid = Process.spawn('true', pgroup: true)
          Process.wait(pid)
          PendingState.write_worker_pid(@token, {
            'pid' => pid, 'pgid' => pid,
            'spawned_at' => Time.now.iso8601, 'ruby_version' => RUBY_VERSION
          })
          pid
        end

        def write_partial_for_seat_zero
          PendingState.write_partial_results(@token, {
            'schema_version' => 1,
            'token' => @token,
            'updated_at' => Time.now.iso8601,
            'results_by_index' => {
              '0' => {
                'role_label' => 'codex_gpt5.5', 'provider' => 'codex',
                'model' => 'gpt-5.5',
                'raw_text' => "**Overall Verdict**: APPROVE\n\n" \
                              'Checked the dispatch path and the pending-state ' \
                              'contract; nothing to raise.',
                'elapsed_seconds' => 12, 'error' => nil, 'status' => 'success'
              }
            }
          })
        end

        def test_completed_seats_survive_a_worker_crash
          write_dead_worker_pid
          write_partial_for_seat_zero
          payload = JSON.parse(@collect.call({
            'collect_token' => @token,
            'orchestrator_reviews' => persona_reviews
          }).first[:text])

          assert_equal 'ok', payload['status'], payload.inspect
          failure = payload['worker_failure']
          assert failure, 'the record must say the denominator survived a worker death'
          assert_equal 'subprocess_worker_crashed', failure['outcome']
          assert_equal 'heartbeat_stale', failure['reason']
          assert_equal 'already_dead', failure['reaper_outcome']
          assert_equal ['codex_gpt5.5'], failure['recovered_seats']
          assert_equal ['cursor'], failure['lost_seats']

          observers = payload.dig('vote_tally', 'denominator_composition', 'observers')
          lost = observers.find { |o| o['role_label'] == 'cursor' }
          refute lost['counted']
          assert_equal 'worker_crashed_seat_lost', lost['reason']
          counted = observers.find { |o| o['role_label'] == 'codex_gpt5.5' }
          assert counted['counted'], 'the recovered seat counts'
        end

        def test_crash_with_no_partial_results_reports_the_death_as_before
          payload = JSON.parse(@collect.call({
            'collect_token' => @token,
            'orchestrator_reviews' => persona_reviews
          }).first[:text])
          assert_equal 'subprocess_worker_crashed', payload['status']
          assert_equal 'heartbeat_stale', payload['reason']
          refute payload.key?('reaper_outcome'),
                 'with nothing to save, the worker is reported, not reaped'
        end

        # A stale heartbeat is not a death certificate. With no worker.pid the
        # reaper cannot confirm anything (:skipped), and a record sealed over
        # a possibly-live worker would be permanently false — so the crash is
        # reported as retryable instead, with the reaper's answer on it.
        def test_recovery_refused_when_death_cannot_be_confirmed
          write_partial_for_seat_zero
          payload = JSON.parse(@collect.call({
            'collect_token' => @token,
            'orchestrator_reviews' => persona_reviews
          }).first[:text])
          assert_equal 'subprocess_worker_crashed', payload['status']
          assert_equal 'skipped', payload['reaper_outcome']
        end

        # No roster, no recovery: a denominator that cannot name its missing
        # seats would shrink silently, which is the loss shape INV-E4 exists
        # to prevent.
        def test_partial_results_without_a_readable_roster_fall_back_to_crash_report
          write_dead_worker_pid
          write_partial_for_seat_zero
          File.delete(PendingState.request_path(@token))
          payload = JSON.parse(@collect.call({
            'collect_token' => @token,
            'orchestrator_reviews' => persona_reviews
          }).first[:text])
          assert_equal 'subprocess_worker_crashed', payload['status']
        end

        # The partial file names its token; one naming another token is not
        # this run's record and is not read.
        def test_partial_results_for_a_different_token_are_not_read
          write_dead_worker_pid
          write_partial_for_seat_zero
          partial = PendingState.load_partial_results(@token)
          partial['token'] = PendingState.generate_token
          PendingState.write_partial_results(@token, partial)
          payload = JSON.parse(@collect.call({
            'collect_token' => @token,
            'orchestrator_reviews' => persona_reviews
          }).first[:text])
          assert_equal 'subprocess_worker_crashed', payload['status']
        end

        # The timeout branch takes the same gate: reaper confirms death (the
        # dead pid answers :already_dead), then the partial file is final and
        # the finished seat survives.
        def test_completed_seats_survive_a_worker_timeout
          PendingState.update_state(@token) do |s|
            s.delete('subprocess_status')
            s.delete('crash_reason')
            s
          end
          write_dead_worker_pid
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          write_partial_for_seat_zero
          payload = JSON.parse(@collect.call({
            'collect_token' => @token,
            'orchestrator_reviews' => persona_reviews,
            'collect_max_wait_seconds' => 1
          }).first[:text])

          assert_equal 'ok', payload['status'], payload.inspect
          failure = payload['worker_failure']
          assert failure
          assert_equal 'worker_timeout', failure['outcome']
          assert_equal 'already_dead', failure['reaper_outcome']
          assert_equal ['codex_gpt5.5'], failure['recovered_seats']
          assert_equal ['cursor'], failure['lost_seats']
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
                'raw_text' => "**Overall Verdict**: APPROVE\n\n" + ('Walked the dispatch ' \
                  'path and the pending state contract; nothing to raise. ' * 4),
                'elapsed_seconds' => 10,
                'error' => nil, 'status' => 'success' },
              { 'role_label' => 'cursor', 'provider' => 'cursor', 'model' => 'cursor-default',
                'raw_text' => "**Overall Verdict**: APPROVE\n\n" + ('Checked the collect merge and the ' \
                  'idempotent replay path; nothing to raise. ' * 4),
                'elapsed_seconds' => 5,
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
          assert_equal 'APPROVE', payload['reference_verdict']
          # 2 subprocess + 1 assembled orchestrator = 3 reviews
          assert_equal 3, payload['reviews'].size
          # Orchestrator entry has the synthesized role_label
          assert(payload['reviews'].any? { |r| r['role_label'] == 'claude_team_claude-opus-4-7' })
          assert_equal 2, payload['persona_count']
          # llm_calls counts ONLY subprocess LLM invocations, not the synthetic
          # orchestrator entry (that was Agent-tool-driven, not a single LLM call).
          assert_equal 2, payload['llm_calls']
        end

        # The refusal landing's safety line: a submission the boundary refuses
        # must not consume the token. Validation runs inside the collect lock
        # but before anything is consumed or written, so the caller can
        # restate the verdict and collect again. Round 11 lost three external
        # results to a destroyed pending state; a validation error that ate
        # the token would rebuild that failure inside the shipped path.
        def test_a_refused_submission_leaves_the_token_collectable
          token = PendingState.generate_token
          write_state(token)
          bad = [
            { 'persona' => 'architect', 'verdict' => 'REJECT (2 blockers)',
              'reasoning' => 'decorated', 'findings' => [] },
            { 'persona' => 'security', 'verdict' => 'APPROVE',
              'reasoning' => 'fine', 'findings' => [] }
          ]
          # This harness writes the legacy single-file layout; the v0.3 token
          # dir is what shipped dispatch writes. Read whichever exists so the
          # byte comparison follows the layout under test.
          legacy_path = File.join(PendingState.root_dir, "#{token}.json")
          state_file = File.exist?(legacy_path) ? legacy_path : PendingState.state_path(token)
          state_before = File.read(state_file)
          refused = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => bad
          }).first[:text])

          assert_equal 'error', refused['status']
          assert_match(/not a verdict/, refused['error'])
          # "Leaves the token collectable" is a claim about what the refusal
          # did NOT do, so the assertions have to look at what it could have
          # done: the cache it could have written and the state it could have
          # consumed. Round 14's review measured both untouched and found only
          # the replay flag asserted here — the name promised more than the
          # test held.
          # Defensive, not discriminating: this legacy fixture never writes
          # collected.json on any path (round-15 review, measured), so this
          # line cannot fail here — it guards the v0.3 layout where that file
          # IS the cache. The byte-identity line below carries the
          # discriminating power in this fixture: a successful collect
          # rewrites the legacy state file, a refusal does not.
          refute File.exist?(PendingState.collected_path(token)),
                 'refusal must not write the collected cache'
          assert_equal state_before, File.read(state_file),
                       'refusal must leave the pending state byte-identical'

          retried = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          }).first[:text])

          assert_equal 'ok', retried['status']
          refute retried['idempotent_replay'], 'refused call must not have written the cache'
          # The restated submission composes the same run the happy path does:
          # 2 subprocess rows + 1 assembled team, 2 LLM calls, 2 personas —
          # and the same verdict, because counts alone would pass a regression
          # that keeps the membership but moves the vote (the shape both
          # round-13 and round-14 P0s took).
          assert_equal 3, retried['reviews'].size
          assert_equal 2, retried['persona_count']
          assert_equal 2, retried['llm_calls']
          assert_equal 'APPROVE', retried['reference_verdict']
        end

        # v0.7 INV-R1/R4: the refusal is an event on the accepting side, and
        # the run's final record carries it — facts and cause, never the
        # refused body. The sidecar is written under the collect lock and read
        # by the collect that succeeds.
        def test_a_refusal_is_readable_from_the_final_record
          token = PendingState.generate_token
          write_state(token)
          bad = [
            { 'persona' => 'architect', 'verdict' => 'LGTM',
              'reasoning' => 'this body must not be stored', 'findings' => [] }
          ]
          refused = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => bad
          }).first[:text])
          assert_equal 'error', refused['status']

          retried = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          }).first[:text])

          assert_equal 'ok', retried['status']
          refusals = retried['refused_submissions']
          assert_equal 1, refusals.size
          entry = refusals.first
          assert_equal 'persona_validation', entry['stage']
          assert_equal 1, entry['submission_count']
          assert_match(/not a verdict/, entry['reason'])
          refute_match(/this body must not be stored/, JSON.generate(refusals),
                       'the refused body must not be stored')

          # A run with no refusal shows none — silence, not an empty column.
          token2 = PendingState.generate_token
          write_state(token2)
          clean = JSON.parse(@collect.call({
            'collect_token' => token2, 'orchestrator_reviews' => good_reviews
          }).first[:text])
          refute clean.key?('refused_submissions')
        end

        # v0.7 R2: the record-side columns, held where they land rather than
        # where they are computed (R1 P0: mutation showed serialize/deserialize
        # columns deletable with every suite green).
        def test_new_columns_survive_the_pending_state_round_trip
          review = {
            role_label: 'r', provider: 'codex', model: 'm', model_declared: 'm',
            model_observed: 'm2', model_source: 'observed', model_divergence: true,
            api_error_status: 'retried_once', fast_mode_state: 'off',
            artifact_delivery: 'by_reference',
            raw_text: 'x', elapsed_seconds: 1, error: nil, status: :success,
            usage: nil
          }
          round_tripped = ReviewSerializer.deserialize(ReviewSerializer.serialize(review))

          assert_equal 'retried_once', round_tripped[:api_error_status]
          assert_equal 'off', round_tripped[:fast_mode_state]
          assert_equal 'by_reference', round_tripped[:artifact_delivery]

          row = ReviewSerializer.payload_row(round_tripped.merge(verdict: 'APPROVE'))
          assert_equal 'retried_once', row['api_error_status']
          assert_equal 'off', row['fast_mode_state']
          assert_equal 'by_reference', row['artifact_delivery']
        end

        def test_stated_text_reaches_row_and_composition
          review = { role_label: 'r', status: :success,
                     raw_text: "**Overall Verdict**: LGTM\n\nP0: real finding here" }
          parsed = Consensus.extract_verdict(review)
          row = ReviewSerializer.payload_row(parsed)
          assert_equal 'LGTM', row['stated_text']

          comp = Consensus.aggregate([review], '3/5 APPROVE', min_quorum: 1)
          observer = comp[:vote_tally][:denominator_composition][:observers].first
          assert_equal 'LGTM', observer[:stated_text]
        end

        # v0.7 R2 (INV-R3): the persona rows land in the record.
        def test_persona_rows_reach_the_final_record
          token = PendingState.generate_token
          write_state(token)
          mixed = [
            { 'persona' => 'architect', 'verdict' => 'REJECT',
              'reasoning' => 'broken', 'findings' => [] },
            { 'persona' => 'security', 'verdict' => 'APPROVE',
              'reasoning' => 'fine', 'findings' => [] }
          ]
          payload = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => mixed
          }).first[:text])

          team = payload['reviews'].find { |r| r['role_label'].start_with?('claude_team_') }
          assert_equal [{ 'persona' => 'architect', 'verdict' => 'REJECT' },
                        { 'persona' => 'security', 'verdict' => 'APPROVE' }],
                       team['persona_rows']
          # R3 P0: the derivation rule must reach the durable record too, and
          # as a literal — the producer-side constant cannot vouch for it.
          assert_equal 'precedence:REJECT>REVISE>APPROVE', team['verdict_derivation']
        end

        # v0.7 R2 (INV-R3/R4): declared vs submitted persona counts.
        def test_declared_persona_count_reaches_the_final_record
          token = PendingState.generate_token
          write_state(token, 'persona_count_declared' => 3)
          payload = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          }).first[:text])

          assert_equal 3, payload['persona_count_declared']
          assert_equal 2, payload['persona_count']
        end

        # v0.7 R2 (INV-R6): review_spec survives the state round trip into the
        # final record (R1 P0: the read leg was deletable with every suite
        # green).
        def test_review_spec_reaches_the_final_record_from_state
          token = PendingState.generate_token
          spec = { 'path' => 'docs/spec.md', 'sha256' => 'abc' }
          write_state(token, 'review_spec' => spec)
          payload = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          }).first[:text])

          assert_equal spec, payload['review_spec']
        end

        # v0.7 R2: a synchronous collect writes the collected.json sidecar, so
        # the completed record is pinned by the same filename the parallel
        # path uses (R1 P0: the sync final record lived only inline in state
        # and was reaped with a false cause).
        def test_sync_collect_writes_the_collected_sidecar
          token = PendingState.generate_token
          write_state(token)
          payload = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          }).first[:text])
          assert_equal 'ok', payload['status']

          assert File.exist?(PendingState.collected_path(token))
          cached = PendingState.load_collected(token)
          assert_equal 'APPROVE', cached['final_payload']['reference_verdict']
        end

        # v0.7 R2: a token abandoned with a terminal note answers with the
        # note's cause, not with expired_or_unknown (R1 P1: a terminal token
        # still looked collectible).
        def test_a_terminated_token_answers_with_its_recorded_cause
          token = PendingState.generate_token
          PendingState.create_token_dir!(token)
          PendingState.atomic_write_json(PendingState.reaped_path(token), {
            'reaped_at' => Time.now.iso8601, 'reason' => 'worker_spawn_failed:RuntimeError'
          })
          payload = JSON.parse(@collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          }).first[:text])

          assert_equal 'terminated_run', payload['status']
          assert_equal 'worker_spawn_failed:RuntimeError', payload['reason']
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

        # v0.7 INV-R4: a submission smaller than what was convened is not
        # refused. One persona is one accepted row; the seat counts through
        # the ordinary rules and the shortfall is the record's business.
        def test_a_single_persona_submission_collects
          token = PendingState.generate_token
          write_state(token)
          result = @collect.call({
            'collect_token' => token,
            'orchestrator_reviews' => [good_reviews.first]
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'ok', payload['status']
          assert_equal 1, payload['persona_count']
        end

        # And an empty submission is a seat that leaves the denominator with
        # its cause on the record — never a manufactured APPROVE.
        def test_an_empty_persona_submission_is_a_recorded_absence
          token = PendingState.generate_token
          write_state(token)
          result = @collect.call({
            'collect_token' => token,
            'orchestrator_reviews' => []
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'ok', payload['status']
          team = payload['reviews'].find { |r| r['role_label'].start_with?('claude_team_') }
          assert_equal 'SKIP', team['verdict']
          assert_equal 'empty_persona_submission', team['skip_reason']
          # The two subprocess approvals still carry the reference tally.
          assert_equal 'APPROVE', payload['reference_verdict']
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
          assert_equal 'REVISE', payload['reference_verdict']
        end

        def test_validation_error_tagged_with_error_class
          token = PendingState.generate_token
          write_state(token)
          result = @collect.call({
            'collect_token' => token,
            'orchestrator_reviews' => [
              { 'persona' => 'bad/name', 'verdict' => 'APPROVE',
                'reasoning' => 'x', 'findings' => [] },
              { 'persona' => 'ok', 'verdict' => 'APPROVE',
                'reasoning' => 'x', 'findings' => [] }
            ]
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_match(/invalid persona name/, payload['error'])
        end

        def test_corrupt_state_returns_internal_error
          token = PendingState.generate_token
          FileUtils.mkdir_p(PendingState.root_dir)
          File.write(PendingState.path_for(token), 'not-valid-json-{{{')
          result = @collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          })
          payload = JSON.parse(result.first[:text])
          assert_equal 'error', payload['status']
          assert_equal 'internal', payload['error_class']
          assert_match(/corrupt/, payload['error'])
        end

        def test_cleanup_preserves_requested_token
          # A token that is past its deadline must not be GC'd before the
          # explicit "past collect_deadline" branch surfaces to the caller.
          token = PendingState.generate_token
          write_state(token, 'collect_deadline' => (Time.now - 1).iso8601)
          result = @collect.call({
            'collect_token' => token, 'orchestrator_reviews' => good_reviews
          })
          payload = JSON.parse(result.first[:text])
          # Expected: explicit expired_or_unknown_token with reason, NOT a
          # generic "token not found" (which would indicate GC ate it first).
          assert_equal 'expired_or_unknown_token', payload['status']
          # The reason field is present only on the deadline-check branch,
          # not on the token-missing branch — confirming cleanup didn't fire.
          assert_equal 'past collect_deadline', payload['reason']
        end
      end
    end
  end
end
