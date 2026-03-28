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

            previous_state = session.state
            session.update_state('terminated')
            session.save

            # Update mandate status
            begin
              Autonomos::Mandate.update_status(session.mandate_id, 'interrupted')
            rescue StandardError
              # Non-fatal
            end

            text_content(JSON.generate({
              'status' => 'ok',
              'session_id' => session_id,
              'previous_state' => previous_state,
              'state' => 'terminated'
            }))
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
          end
        end
      end
    end
  end
end
