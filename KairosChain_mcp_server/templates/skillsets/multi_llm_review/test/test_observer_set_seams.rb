# frozen_string_literal: true

# Seam tests: the invariants where they leave ObserverSet and enter the code
# that carries them into production.
#
# R1's test-integrity review mutated the shipped code in nine ways and found
# that four mutations left the whole suite green: forcing model_source to
# 'observed', restoring reviewers_override in the dispatch tool, ignoring
# escalate in the bundle tool, and disabling every new argument on the collect
# side. Each of those is a test here. The core was well covered; the seams were
# not covered at all, which is the more dangerous shape — a pure function with
# good tests can still be wired to nothing.

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'yaml'

require_relative '../lib/multi_llm_review/observer_set'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/dispatcher'
require_relative '../lib/multi_llm_review/persona_assembly'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/prompt_builder'
require_relative '../lib/multi_llm_review/verdict_vocabulary'

unless defined?(KairosMcp::Tools::BaseTool)
  module KairosMcp
    module Tools
      class BaseTool
        def initialize(*) ; end
        def text_content(str) = [{ type: 'text', text: str }]
        def invoke_tool(*) = nil
      end
    end
  end
end

require_relative '../tools/multi_llm_review'
require_relative '../tools/multi_llm_review_bundle'
require_relative '../tools/multi_llm_review_collect'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # INV-E1 at the dispatch tool: a caller cannot substitute a roster, and
      # the refusal is visible rather than silent.
      class TestDispatchToolRosterAuthority < Minitest::Test
        def setup
          @tool = Tools::MultiLlmReview.new
        end

        def call_with(extra = {})
          JSON.parse(@tool.call({
            'artifact_content' => 'x', 'artifact_name' => 'n',
            'review_type' => 'design'
          }.merge(extra)).first[:text])
        end

        def test_reviewers_override_is_refused_not_ignored
          payload = call_with('reviewers_override' => [
            { 'provider' => 'codex', 'model' => 'gpt-5.5', 'role_label' => 'only_me' }
          ])

          assert_equal 'error', payload['status']
          assert_match(/reviewers_override was removed/, payload['error'])
          assert_match(/escalate/, payload['error'])
        end

        def test_empty_override_is_refused_too
          # An empty array used to mean "fall through to config", which made the
          # argument look supported. It is not supported at all now.
          payload = call_with('reviewers_override' => [])
          assert_equal 'error', payload['status']
        end

        # INV-E5 at the tool boundary: a roster the tool cannot vouch for stops
        # the run instead of dispatching against an external default.
        def test_roster_slot_without_a_model_stops_the_run
          tool = Tools::MultiLlmReview.new
          def tool.load_review_config
            { 'reviewers' => [{ 'provider' => 'cursor', 'role_label' => 'cursor_default' }] }
          end
          payload = JSON.parse(tool.call(
            'artifact_content' => 'x', 'artifact_name' => 'n', 'review_type' => 'design'
          ).first[:text])

          assert_equal 'error', payload['status']
          assert_match(/does not name a model/, payload['error'])
        end
      end

      # INV-E1 / INV-E3 / INV-E5 at the bundle tool. A bundle names the
      # observers a human will run by hand, which is still convening them.
      class TestBundleToolRosterAuthority < Minitest::Test
        def setup
          @tool = Tools::MultiLlmReviewBundle.new
        end

        def build(extra = {})
          JSON.parse(@tool.call({
            'artifact_content' => 'x', 'artifact_name' => 'n',
            'review_type' => 'design'
          }.merge(extra)).first[:text])
        end

        def test_reviewers_override_is_refused
          payload = build('reviewers_override' => [
            { 'provider' => 'codex', 'model' => 'gpt-5.5', 'role_label' => 'only_me' }
          ])
          assert_equal 'error', payload['status']
          assert_match(/reviewers_override was removed/, payload['error'])
        end

        def test_escalation_strictly_adds_the_reserve_slots
          base = build
          escalated = build('escalate' => true)
          skip 'config has no reserve slots' if base['status'] != 'ok'

          reserve = (YAML.load_file(
            File.join(__dir__, '..', 'config', 'multi_llm_review.yml')
          )['escalation_reviewers'] || [])
          skip 'config has no reserve slots' if reserve.empty?

          assert_equal base['bundle']['per_reviewer_prompts'].size + reserve.size,
                       escalated['bundle']['per_reviewer_prompts'].size
        end

        def test_slot_without_a_model_is_refused_here_too
          tool = Tools::MultiLlmReviewBundle.new
          def tool.load_review_config
            { 'reviewers' => [{ 'provider' => 'cursor', 'role_label' => 'cursor_default' }] }
          end
          payload = JSON.parse(tool.call(
            'artifact_content' => 'x', 'artifact_name' => 'n', 'review_type' => 'design'
          ).first[:text])

          assert_equal 'error', payload['status']
          assert_match(/does not name a model/, payload['error'])
        end
      end

      # INV-E5 / INV-P1 where provenance is actually decided.
      class TestDispatcherProvenance < Minitest::Test
        def build_success(reviewer, response)
          Dispatcher.new(nil).send(:build_success, reviewer, response, 0.0)
        end

        def slot(model = 'claude-opus-4-6')
          { role_label: 'cli', provider: 'claude_code', model: model }
        end

        def test_transport_that_reports_the_model_is_recorded_as_observed
          r = build_success(slot, { 'response' => {
            'content' => 'text', 'model_observed' => 'claude-opus-4-6'
          } })

          assert_equal 'observed', r[:model_source]
          assert_equal 'claude-opus-4-6', r[:model_observed]
          refute r[:model_divergence]
        end

        def test_transport_that_cannot_report_is_recorded_as_declared
          r = build_success(slot, { 'response' => { 'content' => 'text' } })

          assert_equal 'declared', r[:model_source]
          assert_nil r[:model_observed]
        end

        def test_a_different_answering_model_is_not_silent
          r = build_success(slot, { 'response' => {
            'content' => 'text', 'model_observed' => 'claude-opus-4-8'
          } })

          assert_equal true, r[:model_divergence]
          assert_equal 'claude-opus-4-6', r[:model_declared]
          assert_equal 'claude-opus-4-8', r[:model_observed]
        end

        def test_blank_report_does_not_masquerade_as_an_observation
          r = build_success(slot, { 'response' => { 'content' => 'x', 'model_observed' => '  ' } })
          assert_equal 'declared', r[:model_source]
        end

        # INV-E4: a slot that failed still has to be identifiable in the record.
        def test_failed_and_skipped_slots_keep_their_identity
          d = Dispatcher.new(nil)
          err = d.send(:build_error, slot, { 'type' => 'boom' }, 0.0)
          skipped = d.send(:build_skip, slot, 'dispatch_timeout')

          assert_equal 'claude-opus-4-6', err[:model]
          assert_equal 'claude-opus-4-6', skipped[:model]
        end
      end

      # The delegate → pending state → collect round trip, with a non-empty
      # excluded set and a persona declaration that differs from the caller.
      class TestCollectRoundTrip < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr-seam-')
          @cwd = Dir.pwd
          Dir.chdir(@tmp)
          @collect = Tools::MultiLlmReviewCollect.new
        end

        def teardown
          Dir.chdir(@cwd)
          FileUtils.remove_entry(@tmp)
        end

        def personas
          [{ 'persona' => 'a', 'verdict' => 'APPROVE', 'reasoning' => 'the set is built once' },
           { 'persona' => 'b', 'verdict' => 'APPROVE', 'reasoning' => 'the record carries provenance' }]
        end

        # Two layouts reach collect: the single legacy file older tokens were
        # written as, and the token directory both delegation paths write now.
        # Which one a token is in decides where its cache has to go back.
        def write_state(overrides = {})
          write_state_in(:legacy, overrides)
        end

        def write_state_in_token_dir(overrides = {})
          write_state_in(:token_dir, overrides)
        end

        def write_state_in(layout, overrides)
          token = PendingState.generate_token
          if layout == :token_dir
            PendingState.create_token_dir!(token)
            FileUtils.touch(PendingState.collect_lock_path(token))
          end
          writer = layout == :token_dir ? :write_state : :write
          PendingState.public_send(writer, token, {
            'token' => token,
            'created_at' => Time.now.iso8601,
            'collect_deadline' => (Time.now + 600).iso8601,
            'review_type' => 'design', 'artifact_name' => 'n',
            'review_round' => 1, 'complexity' => 'high',
            'orchestrator_model' => 'claude-fable-5',
            'persona_model' => 'claude-opus-5',
            'excluded_slots' => [
              { 'role_label' => 'cli_opus5', 'model' => 'claude-opus-5',
                'reason' => ObserverSet::REASON_PERSONA_OCCUPIED }
            ],
            'escalation' => { 'escalated' => true, 'slots' => ['cli_fable5'] },
            'convergence_rule' => '3/5 APPROVE',
            'min_quorum' => 1,
            'collected' => false,
            'subprocess_results' => [
              { 'role_label' => 'codex', 'provider' => 'codex', 'model' => 'gpt-5.5',
                'model_source' => 'declared',
                'raw_text' => "**Overall Verdict**: APPROVE\n\nChecked the observer set construction and the record.",
                'elapsed_seconds' => 1, 'error' => nil, 'status' => 'success' },
              { 'role_label' => 'cli_opus46', 'provider' => 'claude_code',
                'model' => 'claude-opus-4-6', 'model_source' => 'observed',
                'model_observed' => 'claude-opus-4-8', 'model_divergence' => true,
                'raw_text' => "**Overall Verdict**: APPROVE\n\nThe provenance now survives the boundary.",
                'elapsed_seconds' => 1, 'error' => nil, 'status' => 'success' },
              { 'role_label' => 'cursor', 'provider' => 'cursor', 'model' => 'composer-2.5',
                'model_source' => 'declared',
                'raw_text' => '**Overall Verdict**: APPROVE', 'elapsed_seconds' => 1,
                'error' => nil, 'status' => 'success' }
            ]
          }.merge(overrides))
          token
        end

        def collect(token)
          JSON.parse(@collect.call(
            'collect_token' => token, 'orchestrator_reviews' => personas
          ).first[:text])
        end

        # INV-P1: the persona is labelled with the model it was declared to run
        # on, not with the caller.
        def test_persona_is_labelled_with_the_declared_persona_model
          payload = collect(write_state)

          assert_equal 'ok', payload['status']
          labels = payload['reviews'].map { |r| r['role_label'] }
          assert_includes labels, 'claude_team_claude-opus-5'
          refute_includes labels, 'claude_team_claude-fable-5'
        end

        # INV-E2 on the collect side: the hollow subprocess reply leaves the
        # denominator even though it arrived through pending state.
        def test_hollow_reply_leaves_the_denominator_after_the_round_trip
          payload = collect(write_state)

          hollow = payload['reviews'].find { |r| r['role_label'] == 'cursor' }
          assert_equal 'SKIP', hollow['verdict']
          # Nothing was lost in transport, and the row has to say so on its own.
          assert_equal 'insubstantial', hollow['skip_reason']
          assert_nil hollow['error']
          assert_equal 3, payload['convergence']['successful_count']

          # A row that did not leave the denominator has no reason to give, and
          # omits the field rather than carrying an explicit null — the shape
          # the composition uses for the same fact. Two shapes for one absence
          # inside a single record is a difference a reader has to interpret.
          counted = payload['reviews'].find { |r| r['role_label'] == 'codex' }
          refute counted.key?('skip_reason')
        end

        # The other way a slot leaves the denominator. If both arrive as a bare
        # SKIP the record cannot tell a silent reviewer from a broken one.
        def test_a_transport_failure_is_recorded_apart_from_a_hollow_reply
          token = write_state
          state = PendingState.load_state(token)
          state['subprocess_results'] = state['subprocess_results'].map do |r|
            next r unless r['role_label'] == 'codex'

            r.merge('status' => 'error', 'error' => 'spawn failed', 'raw_text' => '')
          end
          PendingState.write(token, state)

          lost = collect(token)['reviews'].find { |r| r['role_label'] == 'codex' }
          assert_equal 'SKIP', lost['verdict']
          assert_equal 'transport', lost['skip_reason']
        end

        # INV-E4: the slots that never ran, and the escalation, survive into
        # the final record.
        def test_composition_survives_the_round_trip
          comp = collect(write_state)['convergence']['denominator_composition']

          labels = comp['observers'].map { |o| o['role_label'] }
          assert_includes labels, 'cli_opus5'
          occupied = comp['observers'].find { |o| o['role_label'] == 'cli_opus5' }
          assert_equal false, occupied['counted']
          assert_equal ObserverSet::REASON_PERSONA_OCCUPIED, occupied['reason']
          assert_equal({ 'escalated' => true, 'slots' => ['cli_fable5'] },
                       comp['escalation'])
        end

        # Idempotency on the non-parallel path is the inline cache, and the
        # cache is only found where the state is read from. Writing it to the
        # legacy file for a token that has a directory hid it: load_state
        # prefers the directory, so the second collect saw no cache, recomputed
        # consensus and wrote its own answer over the first.
        #
        # Both layouts are exercised because a synchronous delegation now
        # writes the directory one, and older tokens are still the file.
        def test_a_second_collect_replays_the_first_answer_in_either_layout
          { legacy: method(:write_state),
            token_dir: method(:write_state_in_token_dir) }.each do |layout, write|
            token = write.call
            first = collect(token)
            second = collect(token)

            refute first['idempotent_replay'], layout.to_s
            assert_equal true, second['idempotent_replay'], layout.to_s
            assert_equal first['verdict'], second['verdict'], layout.to_s
          end
        end

        # An argument the tool reads but does not declare cannot be sent: a
        # caller sends what the schema names. This one was read from the day
        # the parallel path landed and reachable by nobody, so a roster slower
        # than the configured wait cost the whole round.
        def test_the_wait_override_is_both_declared_and_obeyed
          assert_includes @collect.input_schema[:properties].keys,
                          :collect_max_wait_seconds

          token = write_state({ 'parallel' => true })
          payload = JSON.parse(@collect.call(
            'collect_token' => token, 'orchestrator_reviews' => personas,
            'collect_max_wait_seconds' => 1
          ).first[:text])

          # No worker was ever spawned for this token, so the wait runs out.
          # What is being pinned is whose number ran out: the caller's, not
          # the 420 seconds in config.
          assert_equal 'worker_timeout', payload['status']
          assert_operator payload['waited_seconds'], :<, 30
        end

        # A token from an intermediate version carries part of the record. The
        # parts it carries are its own and the parts it does not are left
        # unsaid: completing them asserted values the producing code cannot
        # emit, which is worse than the omission it replaced, because a reader
        # can see silence and cannot see an invention.
        def test_a_partial_escalation_record_is_left_as_it_was_recorded
          token = write_state('escalation' => { 'requested' => true })

          assert_equal({ 'requested' => true },
                       collect(token)['convergence']['denominator_composition']['escalation'])
        end

        # The one case that is answered rather than left silent, because it can
        # be answered truthfully: a version with no escalation to offer cannot
        # have been asked for it.
        def test_a_token_written_before_escalation_existed_is_the_case_that_is_filled
          token = write_state
          state = PendingState.load_state(token)
          state.delete('escalation')
          PendingState.write(token, state)

          assert_equal({ 'requested' => false, 'escalated' => false,
                         'slots' => [], 'dispatched' => [] },
                       collect(token)['convergence']['denominator_composition']['escalation'])
        end

        # The filled record is built fresh each time. Returning copies that
        # shared one frozen constant's arrays meant a caller appending to
        # `slots` on one record reached every later one, and `freeze` read as a
        # guarantee against exactly that.
        def test_the_filled_record_is_not_shared_between_rounds
          first = Consensus.normalize_escalation(nil)
          first['slots'] << 'mutated'

          assert_empty Consensus.normalize_escalation(nil)['slots']
        end

        # INV-E5: a divergence recorded by the dispatcher is still legible at
        # the end of the round trip.
        def test_divergence_survives_the_round_trip
          comp = collect(write_state)['convergence']['denominator_composition']
          diverged = comp['observers'].find { |o| o['role_label'] == 'cli_opus46' }

          assert_equal 'observed', diverged['model_source']
          assert_equal true, diverged['model_divergence']
        end

        # The rule that decides the verdict is chosen when the run starts and
        # travels in the token, because collect is a separate call that has no
        # access to the config the dispatching side read. A collect that fell
        # back to its own default would judge the round by a rule the caller
        # never chose — and would do so silently, since the recorded rule would
        # still be the one in the token.
        def test_collect_judges_by_the_rule_carried_in_the_token
          # The rule is a ratio over the replies that counted, so a split is
          # needed for the threshold to be visible at all: three counted, two
          # approving. 2/3 clears it and 3/3 does not.
          split = lambda do |rule|
            state = write_state('convergence_rule' => rule)
            s = PendingState.load_state(state)
            s['subprocess_results'] = s['subprocess_results'].map do |r|
              next r unless r['role_label'] == 'codex'

              r.merge('raw_text' => "**Overall Verdict**: REVISE\n\nThe reason belongs beside the row.")
            end
            PendingState.write(state, s)
            collect(state)
          end

          lenient = split.call('2/3 APPROVE')
          strict  = split.call('3/3 APPROVE')

          assert_equal 3, lenient['convergence']['successful_count']
          assert_equal 2, lenient['convergence']['approve_count']

          assert_equal 'APPROVE', lenient['verdict']
          assert_equal '2/3 APPROVE', lenient['convergence']['rule']

          assert_equal 'REVISE', strict['verdict']
          assert_equal '3/3 APPROVE', strict['convergence']['rule']
        end

        # The other half of the verdict decision travels the same boundary and
        # had no gate: collect could ignore it and fall back to its own default
        # with nothing going red.
        def test_collect_honours_the_quorum_carried_in_the_token
          low  = collect(write_state('min_quorum' => 1))
          high = collect(write_state('min_quorum' => 9))

          assert_equal 'APPROVE', low['verdict']
          assert_equal 1, low['convergence']['min_quorum']

          assert_equal 'INSUFFICIENT', high['verdict']
          assert_equal 9, high['convergence']['min_quorum']
        end

        # INV-E5 on the rows a reader reads, not only in the composition. The
        # fixture already carries a divergent row, so this assertion was free
        # and its absence left all three fields deletable from collect's rows.
        def test_divergence_is_named_on_the_reviewer_row_after_the_round_trip
          row = collect(write_state)['reviews'].find { |r| r['role_label'] == 'cli_opus46' }

          assert_equal 'observed', row['model_source']
          assert_equal 'claude-opus-4-8', row['model_observed']
          assert_equal true, row['model_divergence']
        end

        # INV-P1. The persona row is a declaration standing in for an observer.
        # Without this field it is shaped exactly like a dispatched slot whose
        # transport could not report its model — same provider, same
        # model_source, same counted — and a reader takes one for the other.
        def test_the_persona_row_is_marked_as_a_declaration
          payload = collect(write_state)
          persona = payload['reviews'].find { |r| r['role_label'].start_with?('claude_team_') }
          executed = payload['reviews'].find { |r| r['role_label'] == 'codex' }

          assert_equal true, persona['synthetic']
          assert_equal false, executed['synthetic']

          observers = payload['convergence']['denominator_composition']['observers']
          assert_equal true, observers.find { |o| o['role_label'] == persona['role_label'] }['synthetic']
          assert_equal false, observers.find { |o| o['role_label'] == 'codex' }['synthetic']
        end

        # A token written while the substance rule was still tunable carries a
        # floor that no longer means anything. Reading it would resurrect the
        # break it was retired for — at 400 every reply in this fixture is
        # hollow — so the key must be inert, not merely absent from new writes.
        def test_a_stale_substance_floor_in_the_token_is_ignored
          payload = collect(write_state('substance_min_chars' => 400))

          assert_equal 'ok', payload['status']
          counted = payload['reviews'].reject { |r| r['verdict'] == 'SKIP' }
          assert_equal %w[codex cli_opus46 claude_team_claude-opus-5],
                       counted.map { |r| r['role_label'] }
        end

        # A token written before this change carries none of the new keys.
        def test_older_tokens_still_collect
          token = write_state
          state = PendingState.load_state(token)
          # substance_min_chars is deleted too: tokens written while the rule
          # was still tunable carry it, and collect must simply ignore it.
          %w[persona_model excluded_slots escalation substance_min_chars].each { |k| state.delete(k) }
          PendingState.write(token, state)

          payload = collect(token)
          assert_equal 'ok', payload['status']
          assert(payload['reviews'].any? { |r| r['role_label'] == 'claude_team_claude-fable-5' })
        end
      end
# INV-P2 at the tool level was covered here by a class that re-implemented
# the tool's strategy mapping and then checked ObserverSet against the copy —
# it never called the tool, so breaking the mapping in the tool left this
# file green. Removed rather than repaired: test_tool_wiring.rb drives the
# real call body for all three strategies, which is the coverage this class
# appeared to provide and did not.

      # INV-E2's criterion. Three earlier versions measured length and each
      # broke differently, so the cases below pin both directions of every
      # break rather than only the one that was live at the time.
      class TestSubstanceCriterion < Minitest::Test
        def substantive?(text)
          Consensus.substantive?(text)
        end

        # The case that made this a P0: a one-line review carrying a finding is
        # the most valuable thing a reviewer returns, and findings are only
        # harvested from replies that counted.
        # The defect this round was written to fix, and it was found live: a
        # persona quoting a reply shape inside a finding flipped the team's
        # REVISE to a recorded APPROVE, because the verdict was re-derived by
        # searching the rendered text. A submission that states its verdict as
        # a field has already answered, and nothing in its prose may overrule
        # that.
        # The stated field must decide on its own, so the text here disagrees
        # with it and carries no header of its own. Asserting this against a
        # reply that also has a correct header proves nothing: the header would
        # give the same answer, and the field could be ignored entirely.
        def test_a_stated_verdict_decides_alone
          stated = { status: :success, verdict: 'REVISE', substantive: true,
                     raw_text: 'Looks fine to me, APPROVE.' }

          assert_equal 'REVISE', Consensus.extract_verdict(stated)[:verdict]
        end

        # And the assembled persona entry states one, so the team verdict does
        # not depend on the rendered text being read back correctly.
        def test_the_assembled_persona_entry_states_its_own_verdict
          entry = PersonaAssembly.assemble(
            [{ 'persona' => 'a', 'verdict' => 'REVISE', 'reasoning' => 'the record drops provenance' },
             { 'persona' => 'b', 'verdict' => 'APPROVE', 'reasoning' => 'the rest is fine' }],
            'claude-opus-5'
          )

          assert_equal 'REVISE', entry[:verdict]
          assert_equal true, entry[:synthetic]
          # Re-deriving from the text must reach the same answer, not a
          # different one, which is the property that broke in round 4.
          assert_equal 'REVISE', Consensus.extract_verdict(entry)[:verdict]
        end

        # A header quoted mid-sentence is someone talking about a header. The
        # reply opens with prose, so no header is read, and no verdict is
        # guessed from the sentence either — the reviewer is recorded as having
        # stated none, which is what happened.
        def test_a_header_quoted_mid_sentence_is_not_a_header
          talking_about_one = {
            status: :success,
            raw_text: 'The tool printed **Overall Verdict**: APPROVE by mistake; my verdict is REJECT.'
          }

          out = Consensus.extract_verdict(talking_about_one)
          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason]
        end

        # A real header still wins over anything said later.
        def test_a_real_header_wins_over_later_prose
          reply = { status: :success, raw_text: "**Overall Verdict**: REVISE\n\n" \
                                                'Everything else I would APPROVE.' }

          assert_equal 'REVISE', Consensus.extract_verdict(reply)[:verdict]
        end

        # INV-E2's other half. A reply can be long and say nothing that decides
        # anything; counting it as a conservative REVISE blocked convergence on
        # a judgement its author never made.
        def test_a_reply_with_no_verdict_leaves_the_denominator
          reply = { status: :success,
                    raw_text: 'I will review this design document now and provide my assessment.' }
          out = Consensus.apply_substance_rule(Consensus.extract_verdict(reply))

          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason]
        end

        # INV-E2 must reach every observer the same way. A JSON document is
        # structured exactly as a persona submission is, so it is judged
        # structurally — judging it by text residue counted its own key names
        # as content and let an empty submission through as an APPROVE.
        def test_a_structured_reply_is_judged_by_its_parts_not_its_key_names
          empty = { status: :success,
                    raw_text: '{"overall_verdict": "APPROVE", "findings": [], "reasoning": ""}' }
          real  = { status: :success,
                    raw_text: '{"overall_verdict": "APPROVE", "findings": [], ' \
                              '"reasoning": "the observer set is built once"}' }
          with_finding = { status: :success,
                           raw_text: '{"overall_verdict": "REJECT", "reasoning": "", ' \
                                     '"findings": [{"severity": "P0", "issue": "key logged"}]}' }
          tag_only = { status: :success,
                       raw_text: '{"overall_verdict": "APPROVE", "reasoning": "", ' \
                                 '"findings": [{"severity": "P0"}]}' }

          decide = ->(r) { Consensus.apply_substance_rule(Consensus.extract_verdict(r)) }

          assert_equal 'SKIP', decide.call(empty)[:verdict]
          assert_equal Consensus::SKIP_REASON_INSUBSTANTIAL, decide.call(empty)[:skip_reason]
          assert_equal 'APPROVE', decide.call(real)[:verdict]
          assert_equal 'REJECT', decide.call(with_finding)[:verdict]
          # A severity with no issue text says nothing about what is wrong —
          # the same answer PersonaAssembly gives for the same shape.
          assert_equal 'SKIP', decide.call(tag_only)[:verdict]
        end

        # A JSON object quoted inside prose is prose: it no longer states a
        # verdict through the structured path, so a reply that quotes one is
        # left to the ordinary rules rather than being handed the quoted
        # answer.
        #
        # The limitation this does NOT remove: the last-resort word heuristic
        # sees the verdict word inside the quotation like any other word, so a
        # reply that states no verdict of its own can still pick one up from
        # what it quotes. That path is order-sensitive (REJECT before REVISE
        # before APPROVE), so it cannot turn a rejection into an approval — and
        # a reply that states its own verdict, by field or by header, is immune
        # either way. Removing the heuristic would drop every reply that
        # answers without the prescribed header, which is a larger loss.
        def test_a_quoted_object_no_longer_states_the_verdict_structurally
          quoting_approve = {
            status: :success,
            raw_text: 'The reply {"overall_verdict": "APPROVE"} is counted; my verdict is REJECT.'
          }

          # No verdict is stated where this system reads one, so none is
          # recorded. Under the fallback this reply was decided by whichever
          # verdict word its prose happened to contain.
          out = Consensus.extract_verdict(quoting_approve)
          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason]

          # And a reply that states its own verdict is unaffected by what it quotes.
          with_own_header = {
            status: :success,
            raw_text: "**Overall Verdict**: REVISE\n\nThe reply " \
                      '{"overall_verdict": "APPROVE"} is counted.'
          }
          assert_equal 'REVISE', Consensus.extract_verdict(with_own_header)[:verdict]
        end

        def test_a_terse_reply_carrying_a_finding_counts
          assert substantive?("REJECT\nP0: private key logged in plaintext.")
        end

        def test_a_verdict_with_nothing_attached_does_not_count
          refute substantive?('APPROVE')
          refute substantive?('**Overall Verdict**: APPROVE')
        end

        # Emphasis and punctuation are not content. Without stripping them a
        # verdict-only reply buys itself a residue by shouting.
        def test_a_decorated_verdict_with_nothing_attached_does_not_count
          refute substantive?('APPROVE!!!')
          refute substantive?('**APPROVE** — ')
          refute substantive?('### REJECT ###')
        end

        # The opposite failure: length alone used to be enough, so a page of
        # repeated verdict words passed.
        def test_repeated_verdict_words_do_not_count
          refute substantive?('APPROVE ' * 50)
        end

        def test_a_short_but_real_review_counts
          assert substantive?('REJECT: the caller slot is decided twice and the two readings disagree.')
        end

        # The break that retired the character floor. This project reviews
        # Japanese design documents and reviewers answer in the artifact's
        # language, so a rule calibrated on English word lengths silently drops
        # whole verdicts. Under the last floor (10) this residue was 6 and the
        # REJECT it carried disappeared from the denominator.
        def test_a_japanese_review_counts
          assert substantive?('競合状態あり')
          assert substantive?("REJECT\n記録が母数より先に確定する")
        end

        # Held against the shortest residues seen in the shipped corpus, in
        # both scripts. A floor that admits one and not the other is encoding a
        # language, which is why there is no floor.
        def test_the_shortest_real_residues_count_in_either_script
          assert substantive?('No issues')
          assert substantive?('不足')
        end

        # Recorded from .kairos/multi_llm_review/pending — the reply that three
        # rounds of handoffs called a "42-character empty approval". It is the
        # exact form prompt_builder.rb asks reviewers to send when they find
        # nothing, so it counts, and nothing in this rule may be tuned to
        # exclude it: the only way to drop this reply is to drop every honest
        # terse approval with it. Whether such a reply should carry a full vote
        # is a question for the roster, not for substance detection.
        def test_the_approval_form_this_skillset_asks_for_counts
          assert substantive?("**Overall Verdict**: APPROVE\n\nNo findings\n")
        end

        def test_empty_does_not_count
          refute substantive?('')
          refute substantive?("\n\n  ")
        end

        # A structured submission answers the substance question itself, and
        # that answer has to outrank the text. Without this the persona is
        # judged by however its verdicts happened to render — which is not what
        # it said, and is long enough to pass in either direction by accident.
        def test_a_structural_answer_outranks_the_rendered_text
          verbose_but_empty = {
            verdict: 'APPROVE', raw_text: 'a' * 400, substantive: false
          }
          terse_but_real = {
            verdict: 'REJECT', raw_text: 'REJECT', substantive: true
          }

          assert_equal 'SKIP', Consensus.apply_substance_rule(verbose_but_empty)[:verdict]
          assert_equal 'insubstantial',
                       Consensus.apply_substance_rule(verbose_but_empty)[:skip_reason]
          assert_equal 'REJECT', Consensus.apply_substance_rule(terse_but_real)[:verdict]
        end

        # A free-text reply has no structural answer, so it falls through to the
        # residue rule rather than being counted by default.
        def test_a_reply_with_no_structural_answer_is_judged_on_its_residue
          assert_equal 'SKIP',
                       Consensus.apply_substance_rule(verdict: 'APPROVE', raw_text: 'APPROVE')[:verdict]
          assert_equal 'APPROVE',
                       Consensus.apply_substance_rule(verdict: 'APPROVE', raw_text: 'APPROVE 競合状態あり')[:verdict]
        end

        # The persona path decides substance structurally; an array padded with
        # blanks is not a finding.
        def test_persona_findings_of_blanks_are_not_substance
          entry = PersonaAssembly.assemble(
            [{ 'persona' => 'a', 'verdict' => 'APPROVE', 'reasoning' => '', 'findings' => [nil, '', {}] },
             { 'persona' => 'b', 'verdict' => 'APPROVE', 'reasoning' => '', 'findings' => [] }],
            'm'
          )
          assert_equal false, entry[:substantive]
        end

        def test_persona_findings_with_content_are_substance
          entry = PersonaAssembly.assemble(
            [{ 'persona' => 'a', 'verdict' => 'REJECT', 'reasoning' => '',
               'findings' => [{ 'severity' => 'P0', 'issue' => 'the boundary drops provenance' }] },
             { 'persona' => 'b', 'verdict' => 'APPROVE', 'reasoning' => '', 'findings' => [] }],
            'm'
          )
          assert_equal true, entry[:substantive]
        end
      end

      # INV-E4 asks the record to say why a slot left the denominator, and a
      # reason that is always the same word is not saying it.
      class TestWhyASlotLeftTheDenominator < Minitest::Test
        def decide(review)
          Consensus.apply_substance_rule(Consensus.extract_verdict(review))
        end

        # A call that broke and a slot this system declined to run are
        # different events. Under one word the record says a reviewer was
        # unreachable when in fact the dispatch window closed, and the round is
        # diagnosed as somebody else's outage.
        def test_a_slot_the_dispatcher_declined_to_run_is_not_a_transport_failure
          declined = Dispatcher.new(nil).send(
            :build_skip,
            { role_label: 'cli', provider: 'claude_code', model: 'claude-opus-4-6' },
            'dispatch_timeout'
          )
          broke = { status: :error, role_label: 'codex',
                    error: { 'type' => 'spawn', 'message' => 'no such file' } }

          assert_equal 'dispatch_timeout', decide(declined)[:skip_reason]
          assert_equal Consensus::SKIP_REASON_TRANSPORT, decide(broke)[:skip_reason]
        end

        def test_a_declined_slot_with_no_stated_reason_still_says_that_much
          bare = { status: :skip, role_label: 'cli', error: nil }

          assert_equal Consensus::SKIP_REASON_NOT_DISPATCHED, decide(bare)[:skip_reason]
        end

        # Only a token is carried into the record. The dispatcher names its
        # reasons as tokens, but the field it writes them in is free-form, so a
        # sentence, a traceback, or anything a transport put there would
        # otherwise land in a field the runbook documents as a small vocabulary.
        def test_only_a_token_shaped_reason_is_carried_into_the_record
          { 'dispatch_timeout' => 'dispatch_timeout',
            'cancelled_before_start' => 'cancelled_before_start',
            "Traceback (most recent call last):\n  File ..." =>
              Consensus::SKIP_REASON_NOT_DISPATCHED,
            'the reviewer could not be reached' => Consensus::SKIP_REASON_NOT_DISPATCHED,
            '' => Consensus::SKIP_REASON_NOT_DISPATCHED }.each do |message, expected|
            out = decide(status: :skip, role_label: 'cli',
                         error: { 'type' => 'skip', 'message' => message })

            assert_equal expected, out[:skip_reason], message[0, 40]
          end
        end

        # A submission that states SKIP *and* says why keeps its own reason.
        # Overwriting it with the constant was invisible: the only test passed
        # a nil reason, so it exercised the fallback and nothing else.
        def test_a_declared_skip_keeps_the_reason_it_stated
          out = decide(status: :success, verdict: 'SKIP',
                       skip_reason: 'out_of_scope', raw_text: 'not my area')

          assert_equal 'out_of_scope', out[:skip_reason]
        end

        # A submission may state SKIP for itself. Why it did is its own
        # business; the record used to answer for it, and answered wrongly.
        def test_a_submission_that_declares_skip_is_not_recorded_as_a_broken_call
          out = decide(status: :success, verdict: 'SKIP', raw_text: 'not my area')

          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_DECLINED, out[:skip_reason]
        end

        # Every route to SKIP names its own reason, so the composition has
        # nothing left to default to — and a row that arrives without one is
        # silent rather than mislabelled.
        def test_the_composition_does_not_supply_a_reason_it_was_not_given
          comp = Consensus.aggregate(
            [{ status: :success, role_label: 'a', raw_text: "**Overall Verdict**: REJECT\n\nP0: the reaper never runs" },
             { status: :success, role_label: 'b', verdict: 'SKIP', raw_text: 'x',
               skip_reason: nil }],
            '3/5 APPROVE', min_quorum: 1
          )[:convergence][:denominator_composition]

          by_label = comp[:observers].map { |o| [o[:role_label], o] }.to_h
          assert_equal Consensus::SKIP_REASON_DECLINED, by_label['b'][:reason]
          refute by_label['a'].key?(:reason)
        end

        # Every route into the composition now names a reason, which leaves
        # nothing exercising the default the composition used to apply — and a
        # default nothing exercises is a default nobody can see go wrong. The
        # rule is stated where it lives instead: a row that arrives without a
        # reason is recorded without one. Silence is legible; `transport` is a
        # claim about a call that may never have been made.
        def test_the_composition_invents_no_reason_for_a_row_that_carries_none
          rows = Consensus.denominator_composition(
            [{ role_label: 'x', verdict: 'SKIP' }], [], nil
          )[:observers]

          refute rows.first[:counted]
          refute rows.first.key?(:reason)
        end
      end

      # Claims that were load-bearing and held by nothing. Round 8 found each
      # of these by mutation: the code was right, the argument for it was
      # written down, and the argument was what nothing checked.
      class TestTheArgumentsTheCodeRestsOn < Minitest::Test
        # A submission that declares its verdict as a field bypasses text
        # parsing entirely. Every test of that branch supplied APPROVE or SKIP,
        # so REJECT could be dropped from the accepted set and a structured
        # rejection would quietly leave the denominator — the round-4 defect
        # class the field was introduced to close.
        def test_every_declared_verdict_is_honoured_as_a_field
          %w[APPROVE REVISE REJECT].each do |declared|
            out = Consensus.extract_verdict(
              status: :success, verdict: declared,
              raw_text: 'a body that states no verdict of its own'
            )

            assert_equal declared, out[:verdict], declared
            assert_nil out[:skip_reason], declared
          end
        end

        # `substantive?` is allowed to measure the raw reply, quotations and
        # all, because a row that leaves the denominator takes its findings
        # with it. That is the whole argument, and it rests on one `next` in
        # aggregate_findings.
        def test_findings_from_a_row_that_left_the_denominator_are_not_aggregated
          parsed = [
            { role_label: 'counted', verdict: 'REJECT',
              raw_text: "**Overall Verdict**: REJECT\n\nP0: the reaper never runs" },
            { role_label: 'left', verdict: 'SKIP', skip_reason: 'no_verdict',
              raw_text: "P0: a finding from a reviewer that stated no verdict" }
          ]

          issues = Consensus.aggregate_findings(parsed).map { |f| f[:cited_by] }.flatten
          assert_equal ['counted'], issues.uniq
        end

        # A JSON reply is judged structurally only when it is a verdict-bearing
        # document. Without that guard an arbitrary JSON body is judged by
        # rules written for a review, and a document with no verdict key at all
        # changes which branch decides it.
        def test_a_json_body_that_is_not_a_review_is_left_to_the_residue_rule
          assert_nil Consensus.structural_substance('{"note": "not a review at all"}')
          assert_nil Consensus.structural_substance('not json')
          refute_nil Consensus.structural_substance('{"overall_verdict": "APPROVE"}')
        end

        # The threshold's zero guard. With min_quorum configured to 0 — which
        # the config read permits, since 0 is truthy in Ruby — returning 0 here
        # would produce an APPROVE off no successful reviews at all.
        def test_no_successful_reviews_can_never_reach_the_threshold
          assert_equal 1, Consensus.parse_threshold('3/5 APPROVE', 0)

          out = Consensus.aggregate([{ status: :error, role_label: 'a' }],
                                    '3/5 APPROVE', min_quorum: 0)
          refute_equal 'APPROVE', out[:verdict]
        end

        # The reason carried from the dispatcher is bounded in length as well
        # as in shape. The shape test used a traceback and a sentence, both of
        # which fail on their characters before length is ever consulted.
        def test_a_token_shaped_reason_that_is_not_short_is_not_carried
          long = 'a' * 80
          out = Consensus.extract_verdict(
            status: :skip, role_label: 'cli',
            error: { 'type' => 'skip', 'message' => long }
          )

          assert_equal Consensus::SKIP_REASON_NOT_DISPATCHED, out[:skip_reason]
        end
      end

      # Round 5. Round 4 closed eighteen findings and three of its closures
      # opened a hole of their own, all three in the direction that passes: a
      # rejection stopped being counted, or an approval was recorded where a
      # rejection was stated. The cases below are those three, plus the two
      # remaining round-5 findings, each named for what actually happened.
      class TestVerdictIsWhatTheReviewerSaid < Minitest::Test
        def verdict_of(text)
          Consensus.extract_verdict(status: :success, raw_text: text)[:verdict]
        end

        # The defect round 6 shipped, and the reason its tests could not see
        # it: the capture class was written with \s, which in Ruby includes the
        # newline, so it ran off the header line into the following prose and
        # handed that prose to the precedence rule. Every round-6 test put a
        # "P0:" line after the header, and the digit halted the capture.
        def test_the_header_capture_stops_at_the_end_of_its_line
          { "**Overall Verdict**: APPROVE\n\nNo blocking issues." => 'APPROVE',
            "**Overall Verdict**: APPROVE\n\nNothing needs work here." => 'APPROVE',
            "**Overall Verdict**: APPROVE\n\nNo changes required elsewhere." => 'APPROVE',
            "**Overall Verdict**: APPROVE\nREJECT is what I would say of the prior draft." => 'APPROVE',
            # A transport that prepends a blank line has not made the reviewer
            # decline to answer. The body disagrees with the header on purpose,
            # so this case fails if the leading blank line stops the header
            # being read — with a body that agrees, it passes either way.
            "\n\n**Overall Verdict**: APPROVE\n\nP0: this would be a blocker if it were real" =>
              'APPROVE' }
            .each { |reply, expected| assert_equal expected, verdict_of(reply), reply[0, 60] }
        end

        # Position decides whose header it is, and the value decides whether
        # it is a verdict at all. Three rounds tried to tell a stated header
        # from a displayed one by reading the text more cleverly and each
        # attempt opened a hole, because a quotation and a statement are the
        # same characters.
        #
        # None of these three replies states a verdict where this system reads
        # one, so none is counted, and each says so in the record. What they
        # used to do instead was worse in both directions: the fallback read
        # the quoted APPROVE as this reviewer's, or read "blocker" in a
        # preamble as a rejection this reviewer never made.
        def test_a_header_below_the_first_line_is_not_read_as_the_verdict
          nested_fence = "The contract asks reviewers to write:\n\n````markdown\n```\n" \
                         "**Overall Verdict**: APPROVE\n```\n````\n\n" \
                         "which this artifact does not meet.\n\n**Overall Verdict**: REJECT\n"
          quoted_first = "> **Overall Verdict**: APPROVE\n\nI disagree.\n\n" \
                         "**Overall Verdict**: REJECT\n"
          preamble = "Some notes first: this has a blocker in the reaper.\n\n" \
                     "**Overall Verdict**: APPROVE\n"

          [nested_fence, quoted_first, preamble].each do |reply|
            out = Consensus.extract_verdict(status: :success, raw_text: reply)
            assert_equal 'SKIP', out[:verdict], reply[0, 40]
            assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason], reply[0, 40]
          end
        end

        # The cost of not guessing, stated as a test so it cannot be forgotten:
        # a reviewer that fences its whole review loses its vote, because its
        # header is on line two. It loses it visibly. The alternative, reading
        # a header from anywhere, is what gave a quoted sample the vote.
        def test_a_reviewer_that_fences_its_own_review_is_not_counted
          reply = "```\n**Overall Verdict**: REJECT\n\nP0: the worker is never reaped\n```"

          out = Consensus.extract_verdict(status: :success, raw_text: reply)
          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason]
        end

        # CRLF is a transport detail, not a statement about the review.
        def test_a_reply_with_windows_line_endings_states_its_verdict
          assert_equal 'REJECT',
                       verdict_of("**Overall Verdict**: REJECT\r\n\r\nP0: the reaper never runs\r\n")
        end

        # The header names a verdict, and the names can be more than one word.
        def test_multi_word_verdict_names_are_read_from_the_header
          { 'NO GO' => 'REJECT', 'SHIP IT' => 'APPROVE', 'NO-GO' => 'REJECT',
            'NO_GO' => 'REJECT', 'SHIP_IT' => 'APPROVE',
            'CHANGES REQUIRED' => 'REVISE' }.each do |word, expected|
            assert_equal expected, verdict_of("**Overall Verdict**: #{word}\n\nP0: concrete"),
                         word
          end
        end

        # The whole of what follows the colon has to be a verdict. A sentence
        # that contains one is not one, and this is the rule that removes the
        # two failures round 8 found: the prompt's own template line echoed
        # back ("APPROVE / REJECT", which used to truncate to APPROVE and bury
        # a stated rejection), and a negation ("NOT APPROVED", which used to
        # match APPROVE and record the opposite of what was said).
        def test_a_header_that_is_a_sentence_states_no_verdict
          ['APPROVE / REJECT', 'APPROVE, REJECT', 'NOT APPROVED', 'DO NOT APPROVE',
           'CANNOT APPROVE', 'DOES NOT PASS', 'APPROVE (no changes required)',
           'APPROVE; my verdict is REJECT', 'APPROVE WITH CHANGES REQUIRED',
           'DISAPPROVE'].each do |value|
            out = Consensus.extract_verdict(
              status: :success,
              raw_text: "**Overall Verdict**: #{value}\n\nP0: private key written to the log"
            )

            assert_equal 'SKIP', out[:verdict], value
            assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason], value
          end
        end

        # Emphasis and spacing are not part of the value; anything else is.
        def test_emphasis_and_spacing_around_the_verdict_are_not_part_of_it
          { '**APPROVE**' => 'APPROVE', '  APPROVE  ' => 'APPROVE',
            'approve' => 'APPROVE', '*REJECT*' => 'REJECT' }.each do |value, expected|
            assert_equal expected, verdict_of("**Overall Verdict**: #{value}\n\nP0: concrete"),
                         value
          end
        end

        # Round 4 named `reasoning` and `issue` as the body of a structured
        # reply. Those are the keys this system's own persona schema uses; an
        # external reviewer picks its own, and a REJECT whose findings carried
        # `description` was recorded as an empty submission and left the
        # denominator.
        def test_a_finding_under_a_key_we_did_not_guess_is_substance
          reply = '{"overall_verdict": "REJECT", "findings": ' \
                  '[{"severity": "P0", "description": "the collect path drops escalation"}]}'
          out = Consensus.apply_substance_rule(
            Consensus.extract_verdict(status: :success, raw_text: reply)
          )

          assert_equal 'REJECT', out[:verdict]
          assert_nil out[:skip_reason]
        end

        # The other half of the same rule: a document whose values say nothing
        # is still hollow, whatever its keys are called. This is what naming
        # the keys was for, and it has to survive not naming them.
        def test_a_document_whose_values_say_nothing_still_leaves_the_denominator
          %w[
            {"overall_verdict":"APPROVE","findings":[],"reasoning":""}
            {"overall_verdict":"APPROVE","summary":"","notes":[""]}
            {"overall_verdict":"APPROVE","findings":[{"severity":"P0"}]}
          ].each do |reply|
            out = Consensus.apply_substance_rule(
              Consensus.extract_verdict(status: :success, raw_text: reply)
            )

            assert_equal 'SKIP', out[:verdict], reply
            assert_equal Consensus::SKIP_REASON_INSUBSTANTIAL, out[:skip_reason], reply
          end
        end

        # A reviewer that cites the offending code instead of describing it has
        # said something about the artifact. Round 6 removed fenced material
        # before measuring substance, so this reply was dropped as hollow and
        # its findings went with it, since a SKIP row is never aggregated.
        def test_a_review_whose_body_is_a_code_citation_is_substance
          cited = { status: :success,
                    raw_text: "**Overall Verdict**: REJECT\n\n```\nmutex.lock\n```\n" }

          out = Consensus.apply_substance_rule(Consensus.extract_verdict(cited))
          assert_equal 'REJECT', out[:verdict]
          assert_nil out[:skip_reason]
        end

        # A severity names how bad something is and never what it is, so a
        # reply that states a verdict and a tag has said nothing about the
        # artifact — in prose exactly as in a document.
        #
        # Every severity the prompt offers, in either case. Pinning one literal
        # left the range and the case-insensitivity free: narrowing the digits
        # to P0-P2, or dropping the case flag, changed nothing any test could
        # see while letting "APPROVE. P3" and "APPROVE. p0" into the
        # denominator.
        def test_a_severity_tag_alone_is_not_substance_in_prose_either
          %w[P0 P1 P2 P3 p0 p3].each do |tag|
            out = Consensus.apply_substance_rule(
              Consensus.extract_verdict(status: :success,
                                        raw_text: "**Overall Verdict**: APPROVE\n\n#{tag}")
            )

            assert_equal 'SKIP', out[:verdict], tag
            assert_equal Consensus::SKIP_REASON_INSUBSTANTIAL, out[:skip_reason], tag
          end
        end

        # A document is walked to the end. Stopping at the first element of an
        # array dropped a REJECT whose substance sat in its second finding —
        # the defect class the key-agnostic rule was written for, reappearing
        # one level down.
        def test_substance_anywhere_in_a_document_counts
          reply = '{"overall_verdict": "REJECT", "findings": [{"severity": "P0"}, ' \
                  '{"severity": "P0", "description": "private key logged in plaintext"}]}'
          out = Consensus.apply_substance_rule(
            Consensus.extract_verdict(status: :success, raw_text: reply)
          )

          assert_equal 'REJECT', out[:verdict]
          assert_nil out[:skip_reason]
        end

        # The verdict field is a verdict, so its text is not substance. Tested
        # with a body under a key nothing names, so the exclusion of the
        # verdict field is what decides — with a recognised body key the
        # document would count for that instead.
        def test_the_verdict_field_is_not_counted_as_what_the_document_said
          hollow = '{"overall_verdict": "APPROVE", "findings": [], "reasoning": ""}'
          out = Consensus.apply_substance_rule(
            Consensus.extract_verdict(status: :success, raw_text: hollow)
          )

          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_INSUBSTANTIAL, out[:skip_reason]
        end

        # A document whose verdict field holds a wording this system does not
        # recognise has not stated a verdict, and leaves before substance is
        # ever asked. It used to be normalised to REVISE — a judgement its
        # author never gave, blocking the round on nobody's opinion.
        def test_a_document_whose_verdict_wording_is_unreadable_states_none
          reply = '{"overall_verdict": "NEEDS TRIAGE", "findings": [{"issue": "real"}]}'
          out = Consensus.apply_substance_rule(
            Consensus.extract_verdict(status: :success, raw_text: reply)
          )

          assert_equal 'SKIP', out[:verdict]
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, out[:skip_reason]
        end

        # Two vocabularies meant the same answer counted differently depending
        # on which observer carried it: a persona answering NO-GO was recorded
        # as a REJECT, and an external slot answering NO-GO stated no judgement
        # at all and left the denominator. Both halves lose a blocking vote.
        def test_the_same_word_is_the_same_judgement_whoever_carried_it
          { 'NO-GO' => 'REJECT', 'NACK' => 'REJECT', 'VETO' => 'REJECT',
            'LGTM' => 'APPROVE', 'REWORK' => 'REVISE',
            'CHANGES REQUIRED' => 'REVISE' }.each do |word, expected|
            external = Consensus.extract_verdict(
              status: :success,
              raw_text: "**Overall Verdict**: #{word}\n\nP0: the reaper never runs"
            )[:verdict]

            assert_equal expected, external, "external slot answering #{word}"

            persona_entry = PersonaAssembly.assemble(
              [{ 'persona' => 'a', 'verdict' => word, 'reasoning' => 'the reaper never runs' },
               { 'persona' => 'b', 'verdict' => word, 'reasoning' => 'the reaper never runs' }],
              'claude-opus-4-7'
            )

            assert_equal expected, persona_entry[:verdict], "persona answering #{word}"
          end
        end

        # The seam nothing was holding. Every rule above is about a header
        # this system asks reviewers to write, and what it asks for lives in
        # one file while what it reads lives in another. A mutation that
        # stopped the prompt asking for the header left the whole suite green:
        # the parser's tests write the header themselves, so they cannot
        # notice that nobody is asking for it any more.
        def test_the_prompt_asks_for_a_header_this_system_can_read
          contract = PromptBuilder.structured_output_contract

          # And the contract has to show, verbatim, lines the parser accepts.
          # Asserting that it mentions "FIRST line" checked for a token, not
          # for what the contract says: "a verdict on the FIRST line is
          # ignored" would have satisfied it. So the contract's own example
          # lines are fed back through the parser, and every one of them has to
          # be read as the verdict it shows.
          shown = contract.lines.grep(/^\s*\*\*Overall Verdict\*\*:/)
          assert_operator shown.size, :>=, 3,
                          'the contract no longer shows the acceptable lines'

          shown.each do |line|
            expected = VerdictVocabulary.stated(line[/:(.*)$/, 1])
            refute_nil expected, "the contract shows #{line.strip.inspect}, which is not a verdict"

            out = Consensus.extract_verdict(
              status: :success,
              raw_text: "#{line.strip}\n\nP0: this would be a blocker if it were real"
            )
            assert_equal expected, out[:verdict], line.strip
          end

          read_as = shown.map { |l| VerdictVocabulary.stated(l[/:(.*)$/, 1]) }
          assert_equal read_as.uniq.size, read_as.size,
                       "the contract shows #{shown.map(&:strip).inspect}, " \
                       'which the parser cannot tell apart'
        end

        # Reading the whole header line would hand the rest of the sentence to
        # a precedence rule meant for verdict names. A verdict name is made of
        # letters, spaces, hyphens and underscores, and the header is read that
        # far and no further.
      end
    end
  end
end
