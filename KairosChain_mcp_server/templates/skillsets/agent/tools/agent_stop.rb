# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentStop < KairosMcp::Tools::BaseTool
          def name
            'agent_stop'
          end

          def description
            'Stop an agent session. Can be called at any state. ' \
              'Terminates the session and records the interruption.'
          end

          def category
            :agent
          end

          def usecase_tags
            %w[agent stop terminate session]
          end

          def related_tools
            %w[agent_start agent_step agent_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                session_id: {
                  type: 'string',
                  description: 'Session ID to stop'
                }
              },
              required: ['session_id']
            }
          end

          def call(arguments)
            session_id = arguments['session_id']
            session = Session.load(session_id)
            return text_content(JSON.generate({ 'status' => 'error', 'error' => 'Session not found' })) unless session

            # Interruption resilience Slice A (INV-A2): stopping is a
            # state-advancing operation and passes the same per-session gate
            # as agent_step — an ungated save here could interleave with an
            # in-flight advance and have the termination silently overwritten.
            gate = AdvanceGate.new(session.guard_dir)
            result = gate.with_lock do
              fresh = Session.load(session_id) || session
              previous_state = fresh.state
              anchor_at_issue = gate.current_anchor(fresh)
              intent = gate.unresolved_intent(cleanup: true)

              fresh.update_state('terminated')
              fresh.save

              # Update mandate status
              begin
                ::Autonomos::Mandate.update_status(fresh.mandate_id, 'interrupted')
              rescue StandardError
                # Non-fatal
              end

              outcome = {
                'status' => 'ok',
                'session_id' => session_id,
                'previous_state' => previous_state,
                'state' => 'terminated'
              }
              # A stop over an unresolved side effect records the ambiguity;
              # the intent file is kept as its audit trace (INV-A3).
              outcome['unresolved_intent_at_stop'] = intent if intent
              outcome['anchor'] = "#{gate.seq + 1}:terminated:#{fresh.cycle_number}"
              gate.commit(anchor_at_issue, 'stop', outcome)
              text_content(JSON.generate(outcome))
            end

            if result.is_a?(Hash) && result['status'] == 'busy'
              return text_content(JSON.generate(result.merge(
                'session_id' => session_id,
                'hint' => 'an advance is in flight; retry when it settles (agent_status shows advance_in_flight)'
              )))
            end
            result
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
          end
        end
      end
    end
  end
end
