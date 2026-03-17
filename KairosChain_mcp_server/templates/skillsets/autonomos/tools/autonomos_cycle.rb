# frozen_string_literal: true

require 'securerandom'

module KairosMcp
  module SkillSets
    module Autonomos
      module Tools
        class AutonomosCycle < KairosMcp::Tools::BaseTool
          include ::Autonomos::Ooda

          def name
            'autonomos_cycle'
          end

          def description
            'Run one autonomous project cycle: observe current state (git, L2, chain), ' \
              'orient against L1 project goals (gap analysis), and decide the next task ' \
              '(as autoexec-compatible JSON). Returns a proposal for human review. ' \
              'After human approves and autoexec executes, call autonomos_reflect to complete the cycle.'
          end

          def category
            :autonomos
          end

          def usecase_tags
            %w[autonomos cycle autonomous agent ooda observe orient decide]
          end

          def related_tools
            %w[autonomos_reflect autonomos_status autoexec_plan autoexec_run]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                goal_name: {
                  type: 'string',
                  description: 'Goal name — L2 context first, L1 knowledge fallback (default: "project_goals")'
                },
                feedback: {
                  type: 'string',
                  description: 'Human feedback or new perspective from a previous cycle. ' \
                    'Appended to cycle context — does not modify goals.'
                },
                cycle_id: {
                  type: 'string',
                  description: 'Resume an interrupted cycle by ID (optional)'
                }
              }
            }
          end

          def call(arguments)
            ensure_loaded!

            goal_name = arguments['goal_name'] || ::Autonomos.config.fetch('default_goal_name', 'project_goals')
            feedback = arguments['feedback']
            resuming = !arguments['cycle_id'].nil?
            cycle_id = arguments['cycle_id'] || ::Autonomos::CycleStore.generate_cycle_id

            existing_state = resuming ? ::Autonomos::CycleStore.load(cycle_id) : nil
            if resuming && existing_state.nil?
              return text_content(JSON.pretty_generate({
                error: "Cycle '#{cycle_id}' not found for resume",
                hint: 'Omit cycle_id to start a new cycle'
              }))
            end

            lock_acquired = false
            begin
              ::Autonomos::CycleStore.acquire_lock(cycle_id)
              lock_acquired = true

              observation = observe(goal_name)
              orientation = orient(observation, goal_name, feedback)

              if orientation[:gaps].empty?
                state = build_cycle_state(cycle_id, goal_name, observation, orientation, nil, 'no_action', existing_state)
                ::Autonomos::CycleStore.save(cycle_id, state)
                return text_content(JSON.pretty_generate({
                  cycle_id: cycle_id,
                  state: 'no_action',
                  message: 'No actionable gaps found. Goal may be achieved or needs refinement.',
                  observation: observation,
                  orientation: orientation
                }))
              end

              proposal = decide(orientation)
              intent_ref, intent_error = record_intent(cycle_id, goal_name, orientation, proposal)

              state = build_cycle_state(cycle_id, goal_name, observation, orientation, proposal, 'decided', existing_state)
              state[:intent_ref] = intent_ref
              ::Autonomos::CycleStore.save(cycle_id, state)

              complexity = proposal[:complexity_hint] || { level: 'low', signals: [] }
              steps = [
                'Review the proposal above',
                "If approved, run: autoexec_plan(task_json: '#{JSON.generate(proposal[:autoexec_task])}')",
                "After autoexec completes: autonomos_reflect(cycle_id: \"#{cycle_id}\", execution_result: \"...\")",
                "If rejected: autonomos_reflect(cycle_id: \"#{cycle_id}\", skip_reason: \"...\")"
              ]

              if complexity[:level] != 'low'
                steps.unshift(
                  "COMPLEXITY #{complexity[:level].upcase} (#{complexity[:signals].join(', ')}): " \
                  'Consider running sc_review(persona_assembly) on this proposal before executing.'
                )
              end

              response = {
                cycle_id: cycle_id,
                state: 'decided',
                observation: observation,
                orientation: orientation,
                proposal: proposal,
                complexity_hint: complexity,
                intent_ref: intent_ref,
                next_steps: steps
              }
              response[:feedback_incorporated] = true if feedback && !feedback.empty?
              response[:chain_warning] = "Intent recording failed: #{intent_error}" if intent_error

              text_content(JSON.pretty_generate(response))
            ensure
              ::Autonomos::CycleStore.release_lock if lock_acquired
            end
          rescue ::Autonomos::DependencyError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, type: e.class.name }))
          end

          private

          def ensure_loaded!
            ::Autonomos.load! unless ::Autonomos.loaded?
          end
        end
      end
    end
  end
end
