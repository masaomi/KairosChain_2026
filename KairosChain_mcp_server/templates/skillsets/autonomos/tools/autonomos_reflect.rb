# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Autonomos
      module Tools
        class AutonomosReflect < KairosMcp::Tools::BaseTool
          def name
            'autonomos_reflect'
          end

          def description
            'Post-execution reflection for an autonomous cycle. Call after autoexec completes ' \
              '(or to skip execution). Evaluates results, saves learnings to L2, proposes L1 ' \
              'promotion if patterns recur, and records outcome on chain (two-phase commit, phase 2). ' \
              'Returns evaluation, learnings, and suggested next direction.'
          end

          def category
            :autonomos
          end

          def usecase_tags
            %w[autonomos reflect evaluate learn memory]
          end

          def related_tools
            %w[autonomos_cycle autonomos_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                cycle_id: {
                  type: 'string',
                  description: 'Cycle ID from autonomos_cycle output (required)'
                },
                execution_result: {
                  type: 'string',
                  description: 'Summary of what autoexec did (success/failure/partial details)'
                },
                feedback: {
                  type: 'string',
                  description: 'Human feedback on the execution results — perspective, corrections, new insights'
                },
                skip_reason: {
                  type: 'string',
                  description: 'If act phase was skipped, explain why (e.g., "proposal rejected", "goal changed")'
                }
              },
              required: %w[cycle_id]
            }
          end

          def call(arguments)
            ensure_loaded!

            cycle_id = arguments['cycle_id']
            execution_result = arguments['execution_result']
            feedback = arguments['feedback']
            skip_reason = arguments['skip_reason']

            reflector = ::Autonomos::Reflector.new(
              cycle_id,
              execution_result: execution_result,
              feedback: feedback,
              skip_reason: skip_reason
            )

            result = reflector.reflect

            if result[:error]
              return text_content(JSON.pretty_generate(result))
            end

            # Add follow-up guidance
            result[:next_steps] = [
              "Run autonomos_cycle(feedback: \"#{result[:suggested_next].to_s[0..60]}...\") to start next cycle",
              'Or set/update goals: knowledge_update(name: "project_goals", content: "...")'
            ]

            text_content(JSON.pretty_generate(result))
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
