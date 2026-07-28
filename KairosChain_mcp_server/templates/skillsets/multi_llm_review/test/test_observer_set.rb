# frozen_string_literal: true

# Tests for ObserverSet (INV-E1 / INV-E3 / INV-E5 / INV-P2) and for the
# denominator rules Consensus gained alongside it (INV-E2 / INV-E4).
#
# The cases below are the ones the design loop actually got wrong. Round 3
# split the persona rules into two unconditional statements and they collided
# in the default configuration; round 4's fidelity clause was narrowed until
# the real production incident fell outside it. Each of those is a test here,
# named for the case rather than for the method.

require 'minitest/autorun'
require_relative '../lib/multi_llm_review/observer_set'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/persona_assembly'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      ROSTER = [
        { provider: 'claude_code', model: 'claude-opus-5',   role_label: 'cli_opus5' },
        { provider: 'claude_code', model: 'claude-opus-4-6', role_label: 'cli_opus46' },
        { provider: 'codex',       model: 'gpt-5.5',         role_label: 'codex_55' },
        { provider: 'cursor',      model: 'composer-2.5',    role_label: 'cursor_c25' }
      ].freeze

      RESERVE = [
        { provider: 'claude_code', model: 'claude-fable-5', role_label: 'cli_fable5' }
      ].freeze

      class TestObserverSet < Minitest::Test
        def labels(result)
          result.dispatch.map { |s| s[:role_label] }
        end

        # INV-P2, the case round 3 could not decide: caller and persona are the
        # same model. Occupancy resolves first, so the slot is occupied rather
        # than excluded, and the persona verdict counts.
        def test_caller_equals_persona_model_slot_is_occupied_not_excluded
          r = ObserverSet.build(roster: ROSTER, orchestrator_model: 'claude-opus-5')

          assert_equal %w[cli_opus46 codex_55 cursor_c25], labels(r)
          assert r.persona[:convened]
          assert_equal 'cli_opus5', r.persona[:occupies]
          refute r.persona[:independent]
          assert_equal [ObserverSet::REASON_PERSONA_OCCUPIED],
                       r.excluded.map { |e| e[:reason] }
        end

        # INV-P2 clause 3 is read as written — "one matching the caller does not
        # run" means at most one — and the reading is only observable from three
        # matching slots up. Author decision, 2026-07-27: letter, not purpose.
        # Widening this to "every match" belongs in a re-freeze of the invariant
        # text, not in the code, so the boundary is pinned here rather than left
        # to whoever next reads the clause.
        def test_only_one_slot_leaves_for_matching_the_caller
          def slot(label) = { provider: 'claude_code', model: 'claude-opus-5', role_label: label }
          codex = { provider: 'codex', model: 'gpt-5.5', role_label: 'codex_55' }

          # Two matching slots: the persona takes one, clause 3 takes the other,
          # and no surplus is left over to show the difference.
          two = ObserverSet.build(roster: [slot('a'), slot('b'), codex],
                                  orchestrator_model: 'claude-opus-5')
          assert_equal %w[codex_55], labels(two)
          assert_equal [ObserverSet::REASON_PERSONA_OCCUPIED, ObserverSet::REASON_CALLER_SLOT],
                       two.excluded.map { |e| e[:reason] }

          # Three: the surplus runs. Under the "every match" reading it would
          # not, so this assertion is the whole decision.
          three = ObserverSet.build(roster: [slot('a'), slot('b'), slot('c'), codex],
                                    orchestrator_model: 'claude-opus-5')
          assert_equal %w[c codex_55], labels(three)
          assert_equal 2, three.excluded.size
        end

        # The same surplus, asked for explicitly. A caller that wants its own
        # model to run in a fresh context says so, and then nothing leaves for
        # matching it.
        def test_separate_context_keeps_every_matching_slot
          def slot(label) = { provider: 'claude_code', model: 'claude-opus-5', role_label: label }

          r = ObserverSet.build(roster: [slot('a'), slot('b')],
                                orchestrator_model: 'claude-opus-5',
                                separate_context: true)

          assert_equal %w[b], labels(r)
          assert_equal [ObserverSet::REASON_PERSONA_OCCUPIED],
                       r.excluded.map { |e| e[:reason] }
        end

        # The construction this whole change exists for: a caller on one model
        # running its personas on another. Both slots leave the dispatch list,
        # for different reasons, and the reasons are distinguishable.
        def test_persona_model_differs_from_caller
          r = ObserverSet.build(roster: ROSTER,
                                orchestrator_model: 'claude-fable-5',
                                persona_model: 'claude-opus-5')

          assert_equal %w[cli_opus46 codex_55 cursor_c25], labels(r)
          assert_equal 'cli_opus5', r.persona[:occupies]
          assert_equal 'claude-opus-5', r.persona[:model]
          # The caller is not on the roster here, so nothing else drops.
          assert_equal 1, r.excluded.size
        end

        def test_caller_slot_leaves_when_persona_is_elsewhere
          r = ObserverSet.build(roster: ROSTER,
                                orchestrator_model: 'claude-opus-4-6',
                                persona_model: 'claude-opus-5')

          assert_equal %w[codex_55 cursor_c25], labels(r)
          reasons = r.excluded.map { |e| [e[:role_label], e[:reason]] }.to_h
          assert_equal ObserverSet::REASON_PERSONA_OCCUPIED, reasons['cli_opus5']
          assert_equal ObserverSet::REASON_CALLER_SLOT, reasons['cli_opus46']
        end

        # INV-P2, third clause: with nothing declared no persona is convened
        # and the run is single phase — which is what the tool did before this
        # change, so an un-updated caller sees no difference.
        def test_nothing_declared_convenes_no_persona
          r = ObserverSet.build(roster: ROSTER)

          assert_equal %w[cli_opus5 cli_opus46 codex_55 cursor_c25], labels(r)
          refute r.persona[:convened]
          assert_empty r.excluded
        end

        def test_persona_model_off_roster_joins_as_independent_observer
          r = ObserverSet.build(roster: ROSTER, persona_model: 'claude-haiku-4-5')

          assert_equal %w[cli_opus5 cli_opus46 codex_55 cursor_c25], labels(r)
          assert r.persona[:independent]
          assert_nil r.persona[:occupies]
          assert_empty r.excluded
        end

        # Round 3 left this combination able to seat the same model twice.
        def test_separate_context_plus_self_declaration_does_not_double_seat
          r = ObserverSet.build(roster: ROSTER,
                                orchestrator_model: 'claude-opus-5',
                                persona_model: 'claude-opus-5',
                                separate_context: true)

          # The slot is seated once, by the persona, and the separate-context
          # request finds nothing left to act on.
          refute_includes labels(r), 'cli_opus5'
          assert_equal 'cli_opus5', r.persona[:occupies]
          assert_equal 1, r.excluded.size
        end

        def test_separate_context_keeps_the_caller_slot_running
          r = ObserverSet.build(roster: ROSTER,
                                orchestrator_model: 'claude-opus-4-6',
                                persona_model: 'claude-opus-5',
                                separate_context: true)

          assert_includes labels(r), 'cli_opus46'
          refute_includes labels(r), 'cli_opus5'
        end

        def test_convene_persona_false_drops_the_caller_slot_without_a_persona
          r = ObserverSet.build(roster: ROSTER,
                                orchestrator_model: 'claude-opus-5',
                                convene_persona: false)

          refute r.persona[:convened]
          refute_includes labels(r), 'cli_opus5'
          assert_equal [ObserverSet::REASON_CALLER_SLOT],
                       r.excluded.map { |e| e[:reason] }
        end

        # INV-P2 fixes the count of occupied slots, not which one.
        def test_only_one_slot_is_occupied_when_several_match
          roster = ROSTER + [
            { provider: 'claude_code', model: 'claude-opus-5', role_label: 'cli_opus5_b' }
          ]
          r = ObserverSet.build(roster: roster, persona_model: 'claude-opus-5')

          assert_equal 1, r.excluded.size
          assert_includes labels(r), 'cli_opus5_b'
        end

        # INV-E3
        def test_escalation_adds_slots_only_when_asked
          off = ObserverSet.build(roster: ROSTER, escalation: RESERVE)
          refute off.escalated
          refute_includes labels(off), 'cli_fable5'

          on = ObserverSet.build(roster: ROSTER, escalation: RESERVE, escalate: true)
          assert on.escalated
          assert_includes labels(on), 'cli_fable5'
          assert_equal ['cli_fable5'], on.escalation_labels
          assert_equal ['cli_fable5'], on.escalation_dispatched
        end

        # INV-E4. The container offering a slot and the slot answering are two
        # different facts, and they come apart whenever the persona takes the
        # reserve slot over — here a Fable 5 caller escalating onto a Fable 5
        # reserve. A record that carries only the offer counts an observer that
        # never ran, and the ratio it feeds is then unreadable.
        def test_a_reserve_slot_taken_over_by_the_persona_is_not_recorded_as_dispatched
          r = ObserverSet.build(roster: ROSTER, escalation: RESERVE, escalate: true,
                                orchestrator_model: 'claude-fable-5')

          refute_includes labels(r), 'cli_fable5'
          assert r.escalated
          assert_equal ['cli_fable5'], r.escalation_labels
          assert_empty r.escalation_dispatched
          assert_equal 'cli_fable5', r.persona[:occupies]
        end

        # The other way the two come apart: the reserve slot is the caller's own
        # and leaves the set without anything standing in its place.
        def test_a_reserve_slot_dropped_as_the_callers_own_is_not_recorded_as_dispatched
          r = ObserverSet.build(roster: ROSTER, escalation: RESERVE, escalate: true,
                                orchestrator_model: 'claude-fable-5',
                                convene_persona: false)

          refute_includes labels(r), 'cli_fable5'
          assert_equal ['cli_fable5'], r.escalation_labels
          assert_empty r.escalation_dispatched
          refute r.persona[:convened]
        end

        # INV-E4: the record identifies an observer by its role_label, so two
        # slots sharing one both vote and cannot be told apart afterwards. The
        # way this happens in practice is a roster entry also listed in the
        # container, where the duplicate only appears on calls that escalate —
        # which is exactly when a reader is least likely to be counting.
        def test_a_duplicated_role_label_is_refused
          dup = { provider: 'codex', model: 'gpt-5.5', role_label: 'codex_55' }

          e = assert_raises(ObserverSet::RosterError) do
            ObserverSet.build(roster: ROSTER, escalation: [dup], escalate: true)
          end
          assert_match(/share a role_label/, e.message)
          assert_match(/codex_55/, e.message)

          # Without the escalation the same config is fine, which is why this
          # cannot be left to the operator to notice.
          assert ObserverSet.build(roster: ROSTER, escalation: [dup])
        end

        # The same rule, reaching the observer it did not reach: the persona's
        # name is built from a declaration made at call time, so it was never
        # among the slots checked against each other. A roster written today
        # can collide with a persona convened tomorrow, and then two rows share
        # a name in the record and the findings each cited stop being
        # attributable.
        def test_a_slot_named_like_the_persona_team_is_refused
          collide = { provider: 'claude_code', model: 'claude-opus-4-8',
                      role_label: PersonaAssembly.role_label_for('claude-opus-5') }

          e = assert_raises(ObserverSet::RosterError) do
            ObserverSet.build(roster: ROSTER + [collide], persona_model: 'claude-opus-5')
          end
          assert_match(/claude_team_claude-opus-5/, e.message)

          # The same roster is fine when no persona is convened under that
          # name, which is why the operator cannot be expected to notice.
          assert ObserverSet.build(roster: ROSTER + [collide], convene_persona: false)
        end

        # A collision with a slot that will not run is still a collision: the
        # slot appears in the composition under its name whether it ran or not.
        def test_the_collision_is_refused_even_when_the_named_slot_is_excluded
          collide = { provider: 'claude_code', model: 'claude-opus-5',
                      role_label: PersonaAssembly.role_label_for('claude-opus-5') }

          assert_raises(ObserverSet::RosterError) do
            ObserverSet.build(roster: [collide], persona_model: 'claude-opus-5')
          end
        end

        def test_a_slot_without_a_role_label_is_refused
          e = assert_raises(ObserverSet::RosterError) do
            ObserverSet.build(roster: [{ provider: 'codex', model: 'gpt-5.5' }])
          end
          assert_match(/no role_label/, e.message)
        end

        # Malformed config should say so, not fail somewhere downstream with an
        # error about symbols and integers.
        def test_a_non_mapping_slot_is_refused_as_a_roster_error
          e = assert_raises(ObserverSet::RosterError) do
            ObserverSet.build(roster: ROSTER, escalation: ['claude-fable-5'], escalate: true)
          end
          assert_match(/not a mapping/, e.message)
        end

        # INV-E4: asking and getting nothing is a different run from not
        # asking, and the record has to be able to say which.
        def test_the_escalation_request_is_recorded_even_when_the_container_is_empty
          asked = ObserverSet.build(roster: ROSTER, escalation: [], escalate: true)
          never = ObserverSet.build(roster: ROSTER, escalation: [])

          assert_equal true, asked.escalation_requested
          assert_equal false, never.escalation_requested
          # Everything else about the two runs is identical, which is why the
          # request needs its own field.
          assert_equal never.escalated, asked.escalated
          assert_equal never.escalation_labels, asked.escalation_labels
        end

        # Both rules read the caller's declaration, so both normalize it. A
        # trailing space used to make occupancy fire and the caller-slot rule
        # silently not.
        # Two matching slots, so occupancy takes one and the caller-slot rule
        # has the other to act on — with a single match the caller-slot rule
        # never runs and the mismatch is invisible.
        def test_a_padded_caller_declaration_is_handled_by_both_rules
          roster = [
            { provider: 'claude_code', model: 'claude-opus-5', role_label: 'a' },
            { provider: 'claude_code', model: 'claude-opus-5', role_label: 'b' },
            { provider: 'codex', model: 'gpt-5.5', role_label: 'c' }
          ]

          padded = ObserverSet.build(roster: roster, orchestrator_model: ' claude-opus-5 ')
          plain  = ObserverSet.build(roster: roster, orchestrator_model: 'claude-opus-5')

          assert_equal %w[c], labels(plain)
          assert_equal labels(plain), labels(padded)
          assert_equal plain.excluded.map { |e| e[:reason] },
                       padded.excluded.map { |e| e[:reason] }
        end

        # INV-E3: removing the container from config is the whole retirement
        # procedure; a caller still asking for it changes nothing.
        def test_escalation_request_is_inert_once_the_container_is_gone
          r = ObserverSet.build(roster: ROSTER, escalation: [], escalate: true)

          refute r.escalated
          assert_equal %w[cli_opus5 cli_opus46 codex_55 cursor_c25], labels(r)
        end

        # INV-E5: this is the production incident of 2026-07-27 in test form.
        def test_slot_without_a_model_is_refused
          roster = ROSTER + [{ provider: 'cursor', role_label: 'cursor_default' }]
          err = assert_raises(ObserverSet::RosterError) do
            ObserverSet.build(roster: roster)
          end
          assert_match(/does not name a model/, err.message)
        end

        def test_slot_without_a_provider_is_refused
          roster = ROSTER + [{ model: 'gpt-5.5', role_label: 'nowhere' }]
          assert_raises(ObserverSet::RosterError) { ObserverSet.build(roster: roster) }
        end

        def test_reserve_slots_are_validated_too
          reserve = [{ provider: 'claude_code', role_label: 'cli_fable5' }]
          assert_raises(ObserverSet::RosterError) do
            ObserverSet.build(roster: ROSTER, escalation: reserve, escalate: true)
          end
        end
      end

      class TestPersonaSubstance < Minitest::Test
        def persona(reasoning: '', findings: [])
          [{ 'persona' => 'a', 'verdict' => 'APPROVE',
             'reasoning' => reasoning, 'findings' => findings },
           { 'persona' => 'b', 'verdict' => 'APPROVE',
             'reasoning' => '', 'findings' => [] }]
        end

        def test_submission_with_reasoning_is_substantive
          e = PersonaAssembly.assemble(persona(reasoning: 'the set is built once'), 'm')
          assert_equal true, e[:substantive]
        end

        def test_submission_with_only_findings_is_substantive
          e = PersonaAssembly.assemble(
            persona(findings: [{ 'severity' => 'P0', 'issue' => 'the boundary drops provenance' }]),
            'm'
          )
          assert_equal true, e[:substantive]
        end

        # A severity tag with no issue text renders as an empty finding, so it
        # is not substance — R2 caught this as a hole in the first version.
        def test_a_severity_tag_without_issue_text_is_not_substance
          e = PersonaAssembly.assemble(persona(findings: [{ 'severity' => 'P0' }]), 'm')
          assert_equal false, e[:substantive]
        end

        def test_submission_with_neither_is_hollow
          e = PersonaAssembly.assemble(persona, 'm')
          assert_equal false, e[:substantive]
        end

        def test_persona_entry_is_labelled_as_declared
          e = PersonaAssembly.assemble(persona(reasoning: 'x'), 'claude-opus-5')
          assert_equal 'declared', e[:model_source]
          assert_equal 'claude_team_claude-opus-5', e[:role_label]
        end
      end

      class TestSubstanceAndComposition < Minitest::Test
        def review(label, text, status: :success)
          { role_label: label, model: 'm', raw_text: text, status: status }
        end

        # The verdict is stated in the one form the reading path accepts:
        # header, first line, verdict name and nothing else on it.
        REAL = "**Overall Verdict**: APPROVE\n\n" + ('The invariant holds because the ' \
               'observer set is built in one pass and the caller slot is decided ' \
               'after occupancy. ' * 4)

        # A reply that states its verdict and nothing else. This is the shape
        # INV-E2 removes from the denominator, and it has to carry a real
        # header to get that far — a bare "APPROVE" states no verdict at all
        # now, and leaves under `no_verdict` before substance is ever asked.
        HOLLOW = '**Overall Verdict**: APPROVE'

        # INV-E2. The 42-character APPROVE that a reviewer actually returned
        # during round 4 of this design's own review loop.
        def test_verdict_word_with_nothing_attached_leaves_the_denominator
          out = Consensus.aggregate(
            [review('a', REAL), review('b', REAL), review('c', HOLLOW)],
            '3/5 APPROVE', min_quorum: 2
          )

          assert_equal 2, out[:convergence][:successful_count]
          assert_equal 1, out[:convergence][:skip_count]
          hollow = out[:reviews].find { |r| r[:role_label] == 'c' }
          assert_equal 'SKIP', hollow[:verdict]
          assert_equal Consensus::SKIP_REASON_INSUBSTANTIAL, hollow[:skip_reason]
        end

        # Substance is not length. A one-line review counts, as long as it
        # states its verdict where the reading path looks — which is now the
        # header and only the header, so the fixture states it there. Under
        # the inference the parser used to do, "REJECT: ..." as an opening
        # sentence counted; that is the same reading that also turned "no
        # blocking issues" into a rejection, and it went with it.
        def test_a_short_but_real_review_still_counts
          short = "**Overall Verdict**: REJECT\n" \
                  'the caller slot is decided twice, once by occupancy and ' \
                  'once by the caller rule, and the two disagree.'
          out = Consensus.aggregate([review('a', REAL), review('b', short)],
                                    '3/5 APPROVE', min_quorum: 1)

          assert_equal 2, out[:convergence][:successful_count]
          assert_equal 1, out[:convergence][:reject_count]
        end

        # And a review that says something real without stating its verdict in
        # that form leaves the denominator — visibly, under `no_verdict`. This
        # is the cost of not guessing, and it is a cost rather than a defect
        # only because the record says so.
        def test_a_real_review_that_states_no_header_verdict_leaves_visibly
          headerless = 'REJECT: the caller slot is decided twice, and the two ' \
                       'rules disagree about which one wins.'
          out = Consensus.aggregate([review('a', REAL), review('b', headerless)],
                                    '3/5 APPROVE', min_quorum: 1)

          assert_equal 1, out[:convergence][:successful_count]
          left = out[:reviews].find { |r| r[:role_label] == 'b' }
          assert_equal Consensus::SKIP_REASON_NO_VERDICT, left[:skip_reason]
        end

        def test_transport_failure_and_emptiness_are_recorded_apart
          out = Consensus.aggregate(
            [review('a', REAL), review('b', '', status: :error), review('c', HOLLOW)],
            '3/5 APPROVE', min_quorum: 1
          )

          reasons = out[:reviews].map { |r| [r[:role_label], r[:skip_reason]] }.to_h
          assert_equal Consensus::SKIP_REASON_TRANSPORT, reasons['b']
          assert_equal Consensus::SKIP_REASON_INSUBSTANTIAL, reasons['c']
        end

        # INV-E2: an empty reply must not raise the bar. Two approvals out of
        # two counted observers converge; the hollow third does not drag it.
        def test_emptiness_does_not_raise_the_required_agreement
          out = Consensus.aggregate(
            [review('a', REAL), review('b', REAL), review('c', HOLLOW)],
            '3/5 APPROVE', min_quorum: 2
          )

          assert_equal 2, out[:convergence][:threshold]
          assert_equal 'APPROVE', out[:verdict]
        end

        # INV-E4
        def test_composition_names_every_observer_and_why_it_did_not_count
          excluded = [{ role_label: 'cli_opus5', model: 'claude-opus-5',
                        reason: ObserverSet::REASON_PERSONA_OCCUPIED }]
          out = Consensus.aggregate(
            [review('a', REAL), review('c', HOLLOW)],
            '3/5 APPROVE', min_quorum: 1,
            excluded_slots: excluded,
            escalation: { 'escalated' => true, 'slots' => ['cli_fable5'] }
          )

          comp = out[:convergence][:denominator_composition]
          assert_equal %w[a c cli_opus5], comp[:observers].map { |o| o[:role_label] }
          # A record that exists is carried as it is. Filling its gaps wrote
          # `requested: false` beside `escalated: true`, a pair the producing
          # code cannot emit — escalation is only ever escalated because it was
          # requested. Silence about a key is legible; an invented value is not.
          assert_equal({ 'escalated' => true, 'slots' => ['cli_fable5'] },
                       comp[:escalation])

          by_label = comp[:observers].map { |o| [o[:role_label], o] }.to_h
          assert by_label['a'][:counted]
          refute by_label['c'][:counted]
          assert_equal Consensus::SKIP_REASON_INSUBSTANTIAL, by_label['c'][:reason]
          assert_equal ObserverSet::REASON_PERSONA_OCCUPIED, by_label['cli_opus5'][:reason]
        end

        # INV-E2 reaches the persona, but through structure rather than
        # length: a structured submission whose personas say nothing is hollow,
        # while a terse one that gives reasoning is not.
        def test_persona_submission_without_reasoning_or_findings_is_hollow
          hollow = review('team', 'Overall Verdict: APPROVE').merge(substantive: false)
          out = Consensus.aggregate([review('a', REAL), hollow],
                                    '3/5 APPROVE', min_quorum: 1)

          assert_equal 1, out[:convergence][:successful_count]
          assert_equal Consensus::SKIP_REASON_INSUBSTANTIAL,
                       out[:reviews].find { |r| r[:role_label] == 'team' }[:skip_reason]
        end

        def test_terse_persona_submission_still_counts
          terse = review('team', 'Overall Verdict: APPROVE').merge(substantive: true)
          out = Consensus.aggregate([review('a', REAL), terse],
                                    '3/5 APPROVE', min_quorum: 1)

          assert_equal 2, out[:convergence][:successful_count]
        end

        # INV-E5 / INV-P1: a record says whether the model name was observed or
        # merely declared, and a divergence is not silent.
        def test_composition_carries_model_provenance
          observed = review('a', REAL).merge(model_source: 'observed',
                                             model_divergence: true)
          declared = review('b', REAL).merge(model_source: 'declared')
          out = Consensus.aggregate([observed, declared], '3/5 APPROVE', min_quorum: 1)

          by_label = out[:convergence][:denominator_composition][:observers]
                     .map { |o| [o[:role_label], o] }.to_h
          assert_equal 'observed', by_label['a'][:model_source]
          assert_equal true, by_label['a'][:model_divergence]
          assert_equal 'declared', by_label['b'][:model_source]
        end
      end
    end
  end
end
