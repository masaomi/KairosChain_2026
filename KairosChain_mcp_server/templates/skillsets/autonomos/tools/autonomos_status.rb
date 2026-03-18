# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Autonomos
      module Tools
        class AutonomosStatus < KairosMcp::Tools::BaseTool
          def name
            'autonomos_status'
          end

          def description
            'View autonomous cycle history and current state. Shows active cycle, ' \
              'recent cycle history, or detailed summary of a specific cycle.'
          end

          def category
            :autonomos
          end

          def usecase_tags
            %w[autonomos status history cycles]
          end

          def related_tools
            %w[autonomos_cycle autonomos_reflect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: {
                  type: 'string',
                  enum: %w[current history summary mandate],
                  description: 'current: show active/latest cycle. history: list recent cycles. summary: detailed view of one cycle. mandate: show active mandate/loop state.'
                },
                cycle_id: {
                  type: 'string',
                  description: 'Specific cycle ID (for summary command)'
                },
                limit: {
                  type: 'integer',
                  description: 'Number of cycles to show in history (default: 10)'
                },
                mandate_id: {
                  type: 'string',
                  description: 'Specific mandate ID (for mandate command)'
                }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            ensure_loaded!

            command = arguments['command']
            cycle_id = arguments['cycle_id']
            limit = arguments['limit'] || 10

            result = case command
                     when 'current'
                       handle_current
                     when 'history'
                       handle_history(limit)
                     when 'summary'
                       handle_summary(cycle_id)
                     when 'mandate'
                       handle_mandate(arguments['mandate_id'])
                     else
                       { error: "Unknown command: #{command}. Use: current, history, summary, mandate" }
                     end

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

          def handle_current
            latest = ::Autonomos::CycleStore.load_latest
            locked = ::Autonomos::CycleStore.locked?

            result = { locked: locked }

            if latest
              result[:latest_cycle] = {
                cycle_id: latest[:cycle_id],
                state: latest[:state],
                goal_name: latest[:goal_name],
                created_at: latest[:created_at],
                updated_at: latest[:updated_at]
              }
              result[:latest_cycle][:evaluation] = latest[:evaluation] if latest[:evaluation]
            else
              result[:latest_cycle] = nil
              result[:message] = 'No cycles found. Run autonomos_cycle() to start.'
            end

            result
          end

          def handle_history(limit)
            cycles = ::Autonomos::CycleStore.list(limit: limit)

            {
              total_cycles: cycles.size,
              cycles: cycles.map { |c|
                {
                  cycle_id: c[:cycle_id],
                  state: c[:state],
                  goal_name: c[:goal_name],
                  created_at: c[:created_at]
                }
              }
            }
          end

          def handle_summary(cycle_id)
            unless cycle_id
              return { error: 'cycle_id required for summary command' }
            end

            cycle = ::Autonomos::CycleStore.load(cycle_id)
            unless cycle
              return { error: "Cycle '#{cycle_id}' not found" }
            end

            {
              cycle_id: cycle[:cycle_id],
              state: cycle[:state],
              goal_name: cycle[:goal_name],
              created_at: cycle[:created_at],
              updated_at: cycle[:updated_at],
              state_history: cycle[:state_history],
              observation_summary: summarize_observation(cycle[:observation]),
              orientation: cycle[:orientation],
              proposal: cycle[:proposal],
              intent_ref: cycle[:intent_ref],
              evaluation: cycle[:evaluation]
            }
          end

          def handle_mandate(mandate_id)
            if mandate_id
              mandate = ::Autonomos::Mandate.load(mandate_id)
              return { error: "Mandate '#{mandate_id}' not found" } unless mandate

              {
                mandate_id: mandate[:mandate_id],
                status: mandate[:status],
                goal_name: mandate[:goal_name],
                max_cycles: mandate[:max_cycles],
                checkpoint_every: mandate[:checkpoint_every],
                risk_budget: mandate[:risk_budget],
                cycles_completed: mandate[:cycles_completed],
                consecutive_errors: mandate[:consecutive_errors],
                cycle_history: mandate[:cycle_history],
                termination_reason: mandate[:termination_reason],
                created_at: mandate[:created_at],
                updated_at: mandate[:updated_at]
              }
            else
              active = ::Autonomos::Mandate.list_active
              {
                active_mandates: active.map { |m|
                  {
                    mandate_id: m[:mandate_id],
                    status: m[:status],
                    goal_name: m[:goal_name],
                    cycles_completed: m[:cycles_completed],
                    max_cycles: m[:max_cycles]
                  }
                }
              }
            end
          end

          def summarize_observation(obs)
            return nil unless obs

            summary = {}
            if obs[:git]
              summary[:git_available] = obs[:git][:git_available]
              summary[:branch] = obs[:git][:branch] if obs[:git][:branch]
              summary[:modified_files] = Array(obs[:git][:status]).size
            end
            summary[:has_previous_cycle] = !obs[:previous_cycle].nil?
            summary[:chain_events_count] = Array(obs[:chain_events]).size
            summary
          end
        end
      end
    end
  end
end
