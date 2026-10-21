# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/agent/dsl'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1DSL < Minitest::Test
        POLICY = <<~RUBY
          policy "masa_2026_10_20" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            free_of_personal_data projects: ["KairosChain_2026"]
            spend default: { review_rounds: 8, stand_in_calls: 200 }
          end
        RUBY

        PLAN = <<~RUBY
          run "rebuild", template: :dev_cycle do
            goal "Rebuild the agent SkillSet"
            spend review_rounds: 6
            phase(:design)                { produce "log/rebuild_design_v*.md" }
            phase(:design_review)         { review :mlr, of: :design, max_rounds: 5 }
            phase(:implement)             { check tests: "templates/skillsets/agent/test" }
            phase(:implementation_review) { review :mlr, of: :implement, max_rounds: 3 }
            report :layered_deck
          end
        RUBY

        def test_policy_parses_into_a_frozen_pinned_object
          p = DSL.parse_policy(POLICY)
          assert p.frozen?
          assert_equal 'masa_2026_10_20', p.name
          assert p.allows?(:novel_reversible)
          assert p.consents?(:review, :project_artifacts)
          refute p.consents?(:lookup), 'the policy language has no lookup consent'
          assert p.free_of_personal_data?('KairosChain_2026')
          refute p.free_of_personal_data?('GenomicsChain_SkillSets')
          assert_equal 200, p.spend[:stand_in_calls]
          assert_equal DSL.digest(POLICY), p.digest
        end

        def test_a_policy_without_a_spend_bound_is_refused
          src = POLICY.sub(/^\s*spend default:.*\n/, '')
          assert_raises(DSL::Error) { DSL.parse_policy(src) }
        end

        def test_a_policy_that_consents_to_lookup_is_refused
          src = POLICY.sub("consent review:", "consent lookup: :public_web\n            consent review:")
          err = assert_raises(DSL::Error) { DSL.parse_policy(src) }
          assert_includes err.message, 'unknown consent'
          assert_equal [:review], DSL::CONSENT_KINDS
        end

        def test_unknown_stand_in_class_is_refused
          src = POLICY.sub(':novel_reversible', ':anything')
          assert_raises(DSL::Error) { DSL.parse_policy(src) }
        end

        def test_policy_documents_cannot_reach_ruby
          assert_raises(NoMethodError, NameError) { DSL.parse_policy('policy "x" do; File.read("/etc/hosts"); end') }
        end

        def test_plan_parses_phases_in_order
          plan = DSL.parse_plan(PLAN)
          assert_equal %i[design design_review implement implementation_review], plan.phase_names
          assert_equal :review, plan.phase(:design_review).kind
          assert_equal 5, plan.phase(:design_review).args[:max_rounds]
          assert_equal 'templates/skillsets/agent/test', plan.phase(:implement).args[:tests]
          assert_equal DSL.digest(PLAN), plan.digest
        end

        def test_a_plan_may_narrow_but_not_widen_the_policy_spend
          policy = DSL.parse_policy(POLICY)
          assert DSL.parse_plan(PLAN).check_against(policy)
          wide = DSL.parse_plan(PLAN.sub('review_rounds: 6', 'review_rounds: 9'))
          assert_raises(DSL::Error) { wide.check_against(policy) }
        end

        def test_a_phase_with_two_kinds_is_refused
          src = PLAN.sub('{ produce "log/rebuild_design_v*.md" }',
                         '{ produce "x"; check tests: "y" }')
          assert_raises(DSL::Error) { DSL.parse_plan(src) }
        end
      end
    end
  end
end
