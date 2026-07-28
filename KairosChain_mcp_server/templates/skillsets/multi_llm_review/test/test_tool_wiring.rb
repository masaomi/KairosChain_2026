# frozen_string_literal: true

# Tests that drive the tool's own call body.
#
# R2's test-integrity review put a `raise` immediately after ObserverSet.build
# inside Tools::MultiLlmReview#call and the whole suite stayed green: nothing
# reached the strategy mapping, the convergence-rule selection, the escalation
# record, the pending-state write or the config reads. The seam tests written
# the round before had re-implemented the mapping instead of invoking it, which
# is the same defect one layer up — a test that copies the logic under test
# passes whatever the logic does.
#
# So these drive the real thing: a stub invoker stands in for llm_call, and the
# assertions are made against what the tool returns and what it wrote.

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'

require_relative '../lib/multi_llm_review/observer_set'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/review_serializer'
require_relative '../lib/multi_llm_review/build_review_bundle'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/dispatcher'

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

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestToolWiring < Minitest::Test
        REVIEW_TEXT = "**Overall Verdict**: APPROVE\n\n" \
                      'Checked the observer set, the denominator and the record.'

        ROSTER = [
          { 'provider' => 'claude_code', 'model' => 'claude-opus-5', 'role_label' => 'a' },
          { 'provider' => 'claude_code', 'model' => 'claude-opus-4-6', 'role_label' => 'b' },
          { 'provider' => 'codex', 'model' => 'gpt-5.5', 'role_label' => 'c' }
        ].freeze

        RESERVE = [
          { 'provider' => 'claude_code', 'model' => 'claude-fable-5', 'role_label' => 'r' }
        ].freeze

        def setup
          @tmp = Dir.mktmpdir('mlr-wiring-')
          @cwd = Dir.pwd
          Dir.chdir(@tmp)
        end

        def teardown
          Dir.chdir(@cwd)
          FileUtils.remove_entry(@tmp)
        end

        # A tool whose config is ours and whose llm_call is a stub. Everything
        # between those two ends is the shipped code.
        def tool(config_extra = {}, observed: nil)
          t = Tools::MultiLlmReview.new
          cfg = {
            'reviewers' => ROSTER,
            'escalation_reviewers' => RESERVE,
            'convergence_rule' => '3/5 APPROVE',
            'convergence_rule_after_exclusion' => '3/4 APPROVE',
            'min_quorum' => 1,
            'delegation' => { 'parallel' => { 'default' => false } }
          }.merge(config_extra)
          t.define_singleton_method(:load_review_config) { cfg }
          t.define_singleton_method(:invoke_tool) do |_name, args, **_kw|
            response = { 'content' => REVIEW_TEXT }
            response['model_observed'] = observed if observed
            [{ text: JSON.generate(
              'status' => 'ok', 'provider' => 'stub',
              'response' => response, 'usage' => {}
            ) }]
          end
          t
        end

        def run_review(t, args = {})
          JSON.parse(t.call({
            'artifact_content' => 'x', 'artifact_name' => 'n',
            'review_type' => 'design', 'parallel' => false
          }.merge(args)).first[:text])
        end

        def pending_state_of(payload)
          PendingState.load_state(payload['collect_token'])
        end

        # --- INV-P2: the three strategies, driven through the tool ---

        def test_delegate_convenes_and_returns_a_token
          out = run_review(tool, 'orchestrator_model' => 'claude-opus-5')

          assert_equal 'delegation_pending', out['status']
          state = pending_state_of(out)
          assert_equal 'claude-opus-5', state['persona_model']
          assert_equal 'delegate', state['orchestrator_strategy']
          assert_equal ['a'], state['excluded_slots'].map { |e| e['role_label'] }
          assert_equal ObserverSet::REASON_PERSONA_OCCUPIED,
                       state['excluded_slots'].first['reason']
        end

        # "subprocess" buys a fresh external process on the caller's own model.
        # It must stay single phase, and the caller's slot must run.
        def test_subprocess_stays_single_phase_and_runs_the_caller_slot
          out = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                 'orchestrator_strategy' => 'subprocess')

          assert_equal 'ok', out['status']
          assert_equal %w[a b c], out['reviews'].map { |r| r['role_label'] }
          assert_equal 0, out['excluded_reviewers']
        end

        def test_exclude_stays_single_phase_and_drops_the_caller_slot
          out = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                 'orchestrator_strategy' => 'exclude')

          assert_equal 'ok', out['status']
          assert_equal %w[b c], out['reviews'].map { |r| r['role_label'] }
          assert_equal 1, out['excluded_reviewers']
        end

        # The eased rule exists for a set that actually got smaller. Asking
        # which reason fired instead of asking whether the denominator shrank
        # eased it for a run that lost nothing: the caller's slot leaves under
        # "exclude", and a persona declared on a model no slot names answers in
        # the set, so the observer count is unchanged.
        def test_the_eased_rule_needs_the_denominator_to_have_shrunk
          lost_one = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                      'orchestrator_strategy' => 'exclude')
          lost_none = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                       'orchestrator_strategy' => 'exclude',
                                       'persona_model' => 'claude-fable-5')

          assert_equal '3/4 APPROVE', lost_one['convergence']['rule']

          # The persona answers in the excluded slot's place, so the roster is
          # whole and the rule it is judged by is the whole-roster one.
          assert_equal 'delegation_pending', lost_none['status']
          assert_equal '3/5 APPROVE', pending_state_of(lost_none)['convergence_rule']
        end

        # The persona replacing the slot it occupies is the case the rule was
        # written for, and it still eases: one slot leaves for the caller, one
        # for occupancy, and only one of the two is answered for.
        def test_the_eased_rule_still_applies_when_a_slot_is_genuinely_lost
          out = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                 'orchestrator_strategy' => 'exclude',
                                 'persona_model' => 'claude-opus-4-6')

          assert_equal 'delegation_pending', out['status']
          assert_equal '3/4 APPROVE', pending_state_of(out)['convergence_rule']
        end

        # The token directory exists before the state is written into it, so a
        # failed write used to leave a token whose directory was there and
        # whose state was not. load_state then returned nil and collect told
        # the caller its token had expired — a token that never finished being
        # created reported as one that ran out of time.
        #
        # Driven through both delegation paths rather than through the helper.
        # The first version of this test called the helper directly and
        # asserted nothing about who used it, so it stayed green while the
        # parallel path — the default shape — never adopted it at all, and
        # kept the defect the helper was written for.
        def test_neither_delegation_path_leaves_a_half_made_token
          { 'sync' => false, 'parallel' => true }.each do |name, parallel|
            original = PendingState.method(:write_state)
            # What a full disk does, at the first write after the directory
            # exists.
            PendingState.define_singleton_method(:write_state) do |*|
              raise Errno::ENOSPC, 'no space left on device'
            end

            begin
              run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                               'parallel' => parallel)
            rescue StandardError
              nil
            ensure
              PendingState.define_singleton_method(:write_state, original)
            end

            leftovers = Dir.glob(File.join(PendingState.root_dir, '*'))
            assert_empty leftovers, "the #{name} path left #{leftovers.inspect}"
          end
        end

        def test_nothing_declared_runs_the_whole_roster_in_one_phase
          out = run_review(tool)

          assert_equal 'ok', out['status']
          assert_equal %w[a b c], out['reviews'].map { |r| r['role_label'] }
        end

        def test_persona_model_alone_is_enough
          out = run_review(tool, 'persona_model' => 'claude-opus-4-6')

          assert_equal 'delegation_pending', out['status']
          assert_equal 'claude-opus-4-6', pending_state_of(out)['persona_model']
        end

        # The validated declaration is the persona one, not the caller's.
        def test_an_invalid_persona_declaration_is_rejected
          out = run_review(tool, 'persona_model' => 'bad/model/name')

          assert_equal 'error', out['status']
          assert_match(/invalid orchestrator_model/, out['error'])
        end

        def test_a_bad_caller_declaration_does_not_block_a_valid_persona
          out = run_review(tool, 'orchestrator_model' => 'bad/model/name',
                                 'persona_model' => 'claude-opus-4-6')

          assert_equal 'delegation_pending', out['status']
        end

        # --- the convergence rule the exclude strategy carries ---

        def test_exclude_applies_the_post_exclusion_rule
          out = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                 'orchestrator_strategy' => 'exclude')
          assert_equal '3/4 APPROVE', out['convergence']['rule']
        end

        def test_the_post_exclusion_rule_does_not_apply_without_an_exclusion
          out = run_review(tool, 'orchestrator_strategy' => 'exclude')
          assert_equal '3/5 APPROVE', out['convergence']['rule']
        end

        def test_the_default_strategy_keeps_the_full_roster_rule
          out = run_review(tool)
          assert_equal '3/5 APPROVE', out['convergence']['rule']
        end

        # --- INV-E3: the container, through the tool ---

        def test_escalation_adds_the_reserve_slot_and_says_so_in_the_record
          off = run_review(tool)
          on  = run_review(tool, 'escalate' => true)

          refute_includes off['reviews'].map { |r| r['role_label'] }, 'r'
          assert_includes on['reviews'].map { |r| r['role_label'] }, 'r'

          off_rec = off['convergence']['denominator_composition']['escalation']
          on_rec  = on['convergence']['denominator_composition']['escalation']
          assert_equal({ 'requested' => false, 'escalated' => false, 'slots' => [], 'dispatched' => [] }, off_rec)
          assert_equal({ 'requested' => true, 'escalated' => true, 'slots' => ['r'], 'dispatched' => ['r'] }, on_rec)
        end

        # The offer and the dispatch come apart when the persona takes the
        # reserve slot over. Recording only the offer counted an observer that
        # never answered, in the one record a later reader uses to compare
        # ratios across rounds.
        def test_a_reserve_slot_taken_by_the_persona_is_not_recorded_as_dispatched
          out = run_review(tool, 'escalate' => true,
                                 'orchestrator_model' => 'claude-fable-5',
                                 'orchestrator_strategy' => 'exclude')
          rec = out['convergence']['denominator_composition']['escalation']

          assert_equal({ 'requested' => true, 'escalated' => true, 'slots' => ['r'], 'dispatched' => [] }, rec)
          refute_includes out['reviews'].map { |r| r['role_label'] }, 'r'
        end

        # INV-E3: the verdict is unchanged. INV-E4: the record still has to say
        # the caller asked, because a run that asked and got nothing is not a
        # run that never asked — and with the rule being a ratio, the operator's
        # intended denominator differed from the one they got. Collapsing the
        # two made the record assert, not omit, that escalation was not wanted.
        def test_a_request_for_a_container_that_is_gone_changes_no_verdict_but_is_recorded
          t = tool({'escalation_reviewers' => []})
          out = run_review(t, 'escalate' => true)

          assert_equal %w[a b c], out['reviews'].map { |r| r['role_label'] }
          assert_equal({ 'requested' => true, 'escalated' => false,
                         'slots' => [], 'dispatched' => [] },
                       out['convergence']['denominator_composition']['escalation'])

          # Distinguishable from the run that never asked.
          never_asked = run_review(t)['convergence']['denominator_composition']['escalation']
          assert_equal false, never_asked['requested']
        end

        # --- INV-E5 / INV-P1: provenance, decided by the real dispatcher ---

        def test_a_transport_that_cannot_report_is_recorded_as_declared
          out = run_review(tool)

          out['reviews'].each do |r|
            assert_equal 'declared', r['model_source']
            assert_nil r['model_observed']
          end
        end

        def test_a_divergent_answer_names_both_models_in_the_record
          out = run_review(tool(observed: 'claude-opus-4-8'))
          row = out['convergence']['denominator_composition']['observers']
                .find { |o| o['role_label'] == 'b' }

          assert_equal 'observed', row['model_source']
          assert_equal 'claude-opus-4-6', row['model_declared']
          assert_equal 'claude-opus-4-8', row['model_observed']
          assert_equal true, row['model_divergence']
        end

        # The same facts on the rows a reader actually reads. Asserting them
        # only on the composition left all three fields deletable from the
        # per-reviewer rows with nothing going red — the non-divergent test
        # above is satisfied by a deleted key and by a hardcoded constant.
        def test_a_divergent_answer_names_both_models_on_the_reviewer_row
          row = run_review(tool(observed: 'claude-opus-4-8'))['reviews']
                .find { |r| r['role_label'] == 'b' }

          assert_equal 'observed', row['model_source']
          assert_equal 'claude-opus-4-8', row['model_observed']
          assert_equal true, row['model_divergence']
        end

        # --- INV-E1 / INV-E5 at the entrance ---

        def test_a_roster_the_tool_cannot_vouch_for_stops_the_run
          t = tool({'reviewers' => [{ 'provider' => 'cursor', 'role_label' => 'no_model' }]})
          out = run_review(t)

          assert_equal 'error', out['status']
          assert_match(/does not name a model/, out['error'])
        end

        def test_a_reserve_slot_without_a_model_stops_the_run_too
          t = tool({'escalation_reviewers' => [{ 'provider' => 'cursor', 'role_label' => 'r' }]})
          out = run_review(t, 'escalate' => true)

          assert_equal 'error', out['status']
          assert_match(/does not name a model/, out['error'])
        end

        def test_reviewers_override_is_refused_by_the_tool
          out = run_review(tool, 'reviewers_override' => [
            { 'provider' => 'codex', 'model' => 'gpt-5.5', 'role_label' => 'only_me' }
          ])
          assert_equal 'error', out['status']
        end

        # A tool whose stub answers one named model with a bare verdict and
        # everyone else with a real review. INV-E2 only matters on the way to a
        # denominator, so it has to be driven from here rather than checked on
        # Consensus alone.
        def tool_answering_hollow_for(model)
          t = tool
          t.define_singleton_method(:invoke_tool) do |_name, args, **_kw|
            asked = args['model'] || args[:model]
            # A reply that states its verdict and nothing else. It has to
            # state it in the form the reading path accepts to get as far as
            # the substance rule — a bare "APPROVE" states no verdict at all
            # and leaves under `no_verdict` before substance is asked.
            text = asked == model ? '**Overall Verdict**: APPROVE' : REVIEW_TEXT
            [{ text: JSON.generate(
              'status' => 'ok', 'provider' => 'stub',
              'response' => { 'content' => text }, 'usage' => {}
            ) }]
          end
          t
        end

        # The strategy decides which observers ran, so a record naming a
        # different one than the run used makes the denominator unexplainable
        # after the fact. The two single-phase strategies both return their
        # record directly, which is where it has to be right.
        def test_the_final_record_names_the_strategy_that_actually_ran
          %w[exclude subprocess].each do |strategy|
            out = run_review(tool, 'orchestrator_strategy' => strategy,
                                   'orchestrator_model' => 'claude-opus-5')

            assert_equal strategy, out['orchestrator_strategy'], strategy
          end
        end

        # The same field on the delegated path, where it travels in the token
        # instead of being returned, and where the default has to survive being
        # left unstated by the caller.
        def test_the_delegated_record_names_the_strategy_that_actually_ran
          left_unstated = run_review(tool, 'orchestrator_model' => 'claude-opus-5')
          assert_equal 'delegate', pending_state_of(left_unstated)['orchestrator_strategy']

          configured = run_review(tool({ 'default_orchestrator_strategy' => 'delegate' }),
                                  'orchestrator_model' => 'claude-opus-5')
          assert_equal 'delegate', pending_state_of(configured)['orchestrator_strategy']
        end

        # --- the default path: parallel, with the worker held back ---

        # Every other test here forces parallel: false, so the shipped default
        # ran end to end nowhere. It matters because the parallel branch writes
        # its own copy of the pending state — a second writer of the same record,
        # which is where the two drift apart unheld.
        def with_worker_stubbed
          spawned = []
          WorkerSpawner.singleton_class.send(:alias_method, :spawn_real, :spawn)
          WorkerSpawner.define_singleton_method(:spawn) { |**kw| spawned << kw }
          yield spawned
        ensure
          WorkerSpawner.singleton_class.send(:alias_method, :spawn, :spawn_real)
          WorkerSpawner.singleton_class.send(:remove_method, :spawn_real)
        end

        def parallel_tool(config_extra = {})
          tool({ 'delegation' => { 'parallel' => { 'default' => true } } }.merge(config_extra))
        end

        def test_the_parallel_path_spawns_a_worker_and_returns_a_token
          with_worker_stubbed do |spawned|
            out = JSON.parse(parallel_tool.call(
              'artifact_content' => 'x', 'artifact_name' => 'n', 'review_type' => 'design',
              'orchestrator_model' => 'claude-opus-5'
            ).first[:text])

            assert_equal 'delegation_pending', out['status']
            assert_equal true, out['parallel']
            assert_equal 1, spawned.size
            assert_equal out['collect_token'], spawned.first[:token]
          end
        end

        # The record the parallel writer produces has to say the same things the
        # synchronous writer says. Anything only one of them carries is a field
        # collect will find missing exactly half the time.
        def test_both_pending_state_writers_record_the_same_run
          with_worker_stubbed do
            args = { 'artifact_content' => 'x', 'artifact_name' => 'n',
                     'review_type' => 'design', 'orchestrator_model' => 'claude-opus-5',
                     'escalate' => true }

            par = PendingState.load_state(
              JSON.parse(parallel_tool.call(args).first[:text])['collect_token']
            )
            syn = PendingState.load_state(
              JSON.parse(tool.call(args.merge('parallel' => false)).first[:text])['collect_token']
            )

            keys = %w[orchestrator_model orchestrator_strategy persona_model
                      persona_independent excluded_slots escalation
                      convergence_rule min_quorum]
            keys.each { |k| assert_equal syn[k], par[k], "pending state key #{k}" }
            assert_equal true, par['escalation']['escalated']
            assert_equal ['r'], par['escalation']['dispatched']
          end
        end

        # INV-P1 on this path too. Nothing here is a persona — every row is a
        # slot that ran — and the record has to say so rather than leaving the
        # field off, because a reader distinguishing declarations from
        # observations must get the same answer from both paths.
        def test_every_row_on_the_single_phase_path_is_marked_as_executed
          rows = run_review(tool)['reviews']

          refute_empty rows
          rows.each { |r| assert_equal false, r['synthetic'], r['role_label'] }
        end

        # INV-E4 on the single-phase path. The composition was only ever
        # asserted here for slots that ran, and only on the delegated path for
        # slots that did not — so the excluded slot could be dropped from every
        # direct-consensus response with the suite still green.
        def test_the_single_phase_record_keeps_the_slot_that_did_not_run
          out = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                 'orchestrator_strategy' => 'exclude')
          observers = out['convergence']['denominator_composition']['observers']
          dropped = observers.find { |o| o['role_label'] == 'a' }

          refute_nil dropped, 'the excluded slot vanished from the composition'
          assert_equal false, dropped['counted']
          assert_equal ObserverSet::REASON_CALLER_SLOT, dropped['reason']
        end

        # The delegated path under a strategy other than the default. Every
        # other test here reaches it with the strategy already equal to
        # 'delegate', so asserting that value was satisfied by a constant.
        # 'subprocess' plus an explicit persona_model is the reachable case.
        def test_the_delegated_record_names_a_non_default_strategy
          out = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                 'orchestrator_strategy' => 'subprocess',
                                 'persona_model' => 'claude-opus-4-6')

          assert_equal 'delegation_pending', out['status']
          assert_equal 'subprocess', pending_state_of(out)['orchestrator_strategy']
        end

        # An empty declaration is not a declaration. "" is truthy in Ruby, so
        # this used to convene a persona and return a token from a strategy
        # that promises a verdict in one phase.
        def test_an_empty_persona_declaration_does_not_convene_one
          %w[exclude subprocess].each do |strategy|
            out = run_review(tool, 'orchestrator_model' => 'claude-opus-5',
                                   'orchestrator_strategy' => strategy,
                                   'persona_model' => '')
            assert_equal 'ok', out['status'], strategy
          end
        end

        # --- INV-E1: there is no roster but the configured one ---

        # The built-in roster that used to sit here named three slots with no
        # model, so it could not survive INV-E5 validation: an operator whose
        # config went missing was told that "claude_team" lacked a model, naming
        # a slot they had never configured and no file to go and look at.
        def test_a_missing_config_names_the_file_and_no_phantom_slots
          t = tool
          t.define_singleton_method(:load_review_config) { {} }
          out = run_review(t)

          assert_equal 'error', out['status']
          assert_includes out['error'], 'multi_llm_review.yml'
          assert_includes out['error'], 'reviewers'
          refute_includes out['error'], 'claude_team'
        end

        def test_an_empty_roster_is_refused_rather_than_substituted
          out = run_review(tool({ 'reviewers' => [] }))

          assert_equal 'error', out['status']
          assert_includes out['error'], 'multi_llm_review.yml'
          refute_includes out['error'], 'claude_team'
        end

        # --- INV-E2 reaches the denominator through the tool ---

        def test_a_hollow_reply_leaves_the_denominator_in_the_dispatch_path
          out = run_review(tool_answering_hollow_for('gpt-5.5'))

          hollow = out['reviews'].find { |r| r['role_label'] == 'c' }
          assert_equal 'SKIP', hollow['verdict']
          assert_equal 'insubstantial', hollow['skip_reason']
          assert_equal 2, out['convergence']['successful_count']
          # Three observers answered; one of them said nothing. What the
          # configuration named is a different number and a different field.
          assert_equal 3, out['convergence']['observers_reporting']
        end

        # The denominator shrank, so the record has to say why. A transport
        # failure and an empty reply both remove a slot and must stay apart.
        def test_the_record_separates_a_hollow_reply_from_a_lost_one
          comp = run_review(tool_answering_hollow_for('gpt-5.5'))
                 .dig('convergence', 'denominator_composition', 'observers')
          entry = comp.find { |o| o['role_label'] == 'c' }

          assert_equal false, entry['counted']
          assert_equal 'insubstantial', entry['reason']
        end

        # --- INV-E2 takes no setting ---

        # The floor was removed because no value of it was correct, so a config
        # that still carries one must not be able to move the denominator. If
        # the key ever becomes live again this run empties out: every stub reply
        # is far under 400 characters of residue.
        def test_a_substance_floor_left_in_config_does_not_move_the_denominator
          plain  = run_review(tool)
          stale  = run_review(tool({ 'substance_min_chars' => 400 }))

          assert_operator plain['convergence']['successful_count'], :>, 0
          assert_equal plain['convergence']['successful_count'],
                       stale['convergence']['successful_count']
          assert_equal plain['reviews'].map { |r| r['verdict'] },
                       stale['reviews'].map { |r| r['verdict'] }
        end

        # collect applies the same parameterless rule, so handing it a floor
        # across the pending-state boundary would be handing it a rule the
        # dispatching side never used.
        def test_no_substance_floor_reaches_pending_state
          out = run_review(tool({ 'substance_min_chars' => 77 }),
                           'orchestrator_model' => 'claude-opus-5')
          refute_includes pending_state_of(out).keys, 'substance_min_chars'
        end

        # --- INV-E4: the acknowledgment describes what happened ---

        def test_a_run_without_a_persona_does_not_claim_the_persona_gate_ran
          out = run_review(tool)
          refute_equal 'claude_code_agent_personas',
                       out.dig('harness_assistance_used', 'path_taken')
        end


        # N3 (R2 mutation, previously green): the key gated the exclude
        # strategy and nothing else. Widening it moves the denominator under a
        # config nobody edited.
        def test_turning_off_self_exclusion_reaches_only_the_exclude_strategy
          cfg = { 'exclude_orchestrator_model' => false }

          under_exclude = run_review(tool(cfg), 'orchestrator_model' => 'claude-opus-5',
                                                'orchestrator_strategy' => 'exclude')
          assert_equal %w[a b c], under_exclude['reviews'].map { |r| r['role_label'] }

          # Under the default the key has no effect. Declaring a persona on a
          # different model is what makes that observable: the caller's own slot
          # is a plain caller-match there, and it still leaves the set.
          under_delegate = run_review(tool(cfg), 'orchestrator_model' => 'claude-opus-4-6',
                                                 'persona_model' => 'claude-opus-5')
          assert_equal 'delegation_pending', under_delegate['status']
          reasons = pending_state_of(under_delegate)['excluded_slots']
                    .map { |e| [e['role_label'], e['reason']] }.to_h
          assert_equal ObserverSet::REASON_CALLER_SLOT, reasons['b']
          assert_equal ObserverSet::REASON_PERSONA_OCCUPIED, reasons['a']
        end

        # N7 (previously green): the two rows for one slot are linked, so a
        # five-slot roster does not read as six observers.
        def test_the_occupied_slot_names_what_replaced_it
          out = run_review(tool, 'orchestrator_model' => 'claude-opus-5')
          row = pending_state_of(out)['excluded_slots'].first

          assert_equal 'claude_team_claude-opus-5', row['replaced_by']
        end

        # N12 / N21 / N22 (previously green): "when we do not know, say
        # declared" is the only thing that keeps a provenance-less record
        # honest, so the default is asserted rather than assumed.
        def test_a_record_without_provenance_reads_as_declared_not_observed
          parsed = Consensus.aggregate(
            [{ role_label: 'legacy', model: 'gpt-5.5', status: :success,
               raw_text: 'APPROVE. A record written before provenance existed.' }],
            '3/5 APPROVE', min_quorum: 1
          )
          row = parsed[:convergence][:denominator_composition][:observers].first

          assert_equal 'declared', row[:model_source]
        end

        def test_a_failed_slot_does_not_claim_its_model_was_observed
          d = Dispatcher.new(nil)
          slot = { role_label: 'x', provider: 'codex', model: 'gpt-5.5' }

          assert_equal 'declared', d.send(:build_error, slot, { 'type' => 'e' }, 0.0)[:model_source]
          assert_equal 'declared', d.send(:build_skip, slot, 'timeout')[:model_source]
        end

        # --- the config fingerprint covers what decides a run ---

        def test_the_fingerprint_moves_when_the_denominator_rules_move
          base = { 'convergence_rule' => '3/5', 'min_quorum' => 1,
                   'escalation_reviewers' => RESERVE }
          moved_rule = base.merge('convergence_rule' => '4/5')
          moved_quorum = base.merge('min_quorum' => 3)
          moved_container = base.merge('escalation_reviewers' => [])

          refute_equal BuildReviewBundle.config_hash(base),
                       BuildReviewBundle.config_hash(moved_rule)
          refute_equal BuildReviewBundle.config_hash(base),
                       BuildReviewBundle.config_hash(moved_quorum)
          refute_equal BuildReviewBundle.config_hash(base),
                       BuildReviewBundle.config_hash(moved_container)
        end

        # The mirror of the above: a key that no longer decides anything must
        # not decide the fingerprint either, or two runs judged identically get
        # recorded as incomparable.
        def test_the_fingerprint_ignores_the_retired_substance_floor
          base = { 'convergence_rule' => '3/5', 'escalation_reviewers' => RESERVE }

          assert_equal BuildReviewBundle.config_hash(base),
                       BuildReviewBundle.config_hash(base.merge('substance_min_chars' => 200))
        end
      end

      # The one mapping that crosses into pending state, tested once rather
      # than inspected in three copies.
      class TestReviewSerializer < Minitest::Test
        def review
          {
            role_label: 'cli', provider: 'claude_code', model: 'claude-opus-4-6',
            model_declared: 'claude-opus-4-6', model_observed: 'claude-opus-4-8',
            model_source: 'observed', model_divergence: true,
            raw_text: 'APPROVE. Nothing to raise.', elapsed_seconds: 1.0,
            error: nil, status: :success, usage: { 'input_tokens' => 1 }
          }
        end

        def test_provenance_survives_a_round_trip
          back = ReviewSerializer.deserialize(
            JSON.parse(JSON.generate(ReviewSerializer.serialize(review)))
          )

          assert_equal 'claude-opus-4-6', back[:model_declared]
          assert_equal 'claude-opus-4-8', back[:model_observed]
          assert_equal 'observed', back[:model_source]
          assert_equal true, back[:model_divergence]
          assert_equal :success, back[:status]
          assert_equal({ 'input_tokens' => 1 }, back[:usage])
        end

        # A record that says nothing about where its model name came from is
        # read as a declaration, never as an observation.
        def test_silence_about_provenance_reads_as_declared
          back = ReviewSerializer.deserialize(
            'role_label' => 'old', 'model' => 'gpt-5.5', 'raw_text' => 'APPROVE.',
            'status' => 'success'
          )

          assert_equal 'declared', back[:model_source]
          assert_nil back[:model_observed]
        end

        # The detached worker uses this same mapping, which is the point: the
        # worker is the shipped path and it used to carry its own copy.
        # The detached worker is the shipped path (parallel defaults to true),
        # so what it writes is what collect reads. Evaluating its result mapping
        # here catches both a hand-rolled copy and a filter applied on top of
        # the shared one — R2's mutation did the latter and went unnoticed.
        def test_the_worker_writes_every_provenance_field
          worker = File.read(File.join(__dir__, '..', 'bin', 'dispatch_worker.rb'))
          line = worker[/'results' => .*/]
          refute_nil line, 'worker no longer has a results mapping'

          results = [{ role_label: 'x', provider: 'codex', model: 'gpt-5.5',
                       model_declared: 'gpt-5.5', model_observed: 'gpt-5.4',
                       model_source: 'observed', model_divergence: true,
                       raw_text: 'APPROVE.', elapsed_seconds: 1, error: nil,
                       status: :success, usage: nil }]
          mapped = eval(line.sub("'results' => ", '').chomp(','), binding) # rubocop:disable Security/Eval

          %w[model_declared model_observed model_source model_divergence].each do |key|
            assert mapped.first.key?(key), "worker dropped #{key}"
          end
          assert_equal 'gpt-5.4', mapped.first['model_observed']
        end
      end
    end
  end
end
