# frozen_string_literal: true

# Phase 12 §11 prompt-contract test.
#
# Verifies that:
#   1. decide_system_prompt explicitly REQUIRES review_hint in the schema.
#   2. A well-formed mock LLM response that includes review_hint passes
#      ReviewHint.parse without warnings.
#   3. A response WITHOUT review_hint still parses to false (graceful degradation;
#      OR-floor's rule path still applies).
#   4. The documented shape `{ needed, reason, urgency }` matches what
#      ReviewHint.parse accepts.

require 'minitest/autorun'
require 'json'
require_relative '../lib/agent/review_hint'

# Stub minimal infrastructure to load agent_step.rb in isolation
module KairosMcp
  module Tools
    class BaseTool
    end
  end unless defined?(KairosMcp::Tools::BaseTool)
end

require_relative '../tools/agent_step'

module KairosMcp
  module SkillSets
    module Agent
      class TestDecidePromptContract < Minitest::Test
        def setup
          @step = Tools::AgentStep.allocate
        end

        def test_prompt_mentions_review_hint_required
          prompt = @step.send(:decide_system_prompt)
          assert_match(/review_hint/, prompt, 'DECIDE prompt must reference review_hint')
          assert_match(/REQUIRED/i, prompt, 'review_hint must be marked as required')
        end

        def test_prompt_describes_review_hint_shape
          prompt = @step.send(:decide_system_prompt)
          assert_match(/needed/, prompt)
          assert_match(/reason/, prompt)
          assert_match(/urgency/, prompt)
        end

        def test_prompt_documents_or_floor_property
          prompt = @step.send(:decide_system_prompt)
          # Plan author must know that needed:false won't suppress rule fires.
          assert_match(/advisory|additive|structural/i, prompt,
                       'DECIDE prompt should explain hint is advisory/additive')
        end

        # Read-gap fix: DECIDE must be told to use safe_file_read for disk files and
        # NOT to use resource_read with a file:// URI (which only accepts in-system URIs).
        def test_prompt_steers_file_reads_to_safe_file_read
          prompt = @step.send(:decide_system_prompt)
          assert_match(/safe_file_read/, prompt,
                       'DECIDE prompt should point disk reads at safe_file_read')
          assert_match(/resource_read/, prompt)
          assert_match(%r{file://}, prompt,
                       'DECIDE prompt should warn against resource_read with file:// URIs')
        end

        # Instructions-drift fix: DECIDE must pass verbatim sub-tool instructions through
        # unchanged rather than paraphrasing / re-scoping the task.
        def test_prompt_requires_verbatim_instruction_passthrough
          prompt = @step.send(:decide_system_prompt)
          assert_match(/UNCHANGED|verbatim/i, prompt,
                       'DECIDE prompt should require verbatim passthrough of instructions')
          assert_match(/paraphrase|re-scope|re-target/i, prompt,
                       'DECIDE prompt should forbid paraphrasing/re-scoping the task')
        end

        # Over-marking fix: requires_human_cognition was listed as a required field
        # with no criterion at all, and the planner marked 10 of 13 steps (including
        # plain file writes). The field now carries a default, a criterion, a
        # counter-criterion, and the cost of a true.
        def test_prompt_gives_a_criterion_for_requires_human_cognition
          prompt = @step.send(:decide_system_prompt)
          assert_match(/requires_human_cognition — default FALSE/, prompt,
                       'DECIDE prompt must state the default for requires_human_cognition')
          assert_match(/only the operator can supply/i, prompt,
                       'DECIDE prompt must say what a true actually requires')
        end

        def test_prompt_separates_human_cognition_from_risk
          prompt = @step.send(:decide_system_prompt)
          # The observed over-marking came from treating "important" as "needs a human".
          assert_match(/Do NOT set it because a step is risky/i, prompt,
                       'DECIDE prompt must stop risk from being read as needing a human')
          assert_match(/writing a file, reading, searching, computing, recording/, prompt,
                       'DECIDE prompt must name the routine step kinds that stay FALSE')
        end

        def test_prompt_states_the_cost_of_a_true
          prompt = @step.send(:decide_system_prompt)
          # Without the cost, the planner has no reason to prefer fewer trues.
          assert_match(/HALTS at the first true step/, prompt,
                       'DECIDE prompt must state that execution halts at the first true')
          assert_match(/fewest steps/, prompt,
                       'DECIDE prompt must ask for the fewest trues')
        end

        # Simulate well-formed LLM output and verify it parses through ReviewHint
        def test_well_formed_llm_output_parses
          llm_output = {
            'summary' => 'add knowledge entry',
            'task_json' => { 'task_id' => 'x', 'meta' => {}, 'steps' => [] },
            'review_hint' => { 'needed' => true, 'reason' => 'L0 path', 'urgency' => 'high' }
          }
          assert_equal true, ReviewHint.parse(llm_output['review_hint'])
        end

        def test_response_without_review_hint_parses_to_false
          # Graceful degradation: OR-floor rule path still fires for high-complexity work.
          llm_output = {
            'summary' => 'minor doc fix',
            'task_json' => { 'task_id' => 'x', 'meta' => {}, 'steps' => [] }
            # no review_hint
          }
          assert_equal false, ReviewHint.parse(llm_output['review_hint'])
        end

        def test_low_urgency_routine_plan_parses
          llm_output = {
            'review_hint' => { 'needed' => false, 'reason' => 'routine', 'urgency' => 'low' }
          }
          assert_equal false, ReviewHint.parse(llm_output['review_hint'])
        end

        def test_minimal_review_hint_accepted
          # reason and urgency are optional per ReviewHint contract
          llm_output = { 'review_hint' => { 'needed' => true } }
          assert_equal true, ReviewHint.parse(llm_output['review_hint'])
        end
      end
    end
  end
end
