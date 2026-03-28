# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentStatus < KairosMcp::Tools::BaseTool
          def name
            'agent_status'
          end

          def description
            'Get the current status of an agent session, or list all active sessions.'
          end

          def category
            :agent
          end

          def usecase_tags
            %w[agent status session]
          end

          def related_tools
            %w[agent_start agent_step agent_stop]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                session_id: {
                  type: 'string',
                  description: 'Session ID to query (omit to list all active sessions)'
                }
              }
            }
          end

          def call(arguments)
            session_id = arguments['session_id']

            if session_id
              session = Session.load(session_id)
              return text_content(JSON.generate({ 'status' => 'error', 'error' => 'Session not found' })) unless session

              text_content(JSON.generate({
                'status' => 'ok',
                'session_id' => session.session_id,
                'mandate_id' => session.mandate_id,
                'goal_name' => session.goal_name,
                'state' => session.state,
                'cycle_number' => session.cycle_number
              }))
            else
              sessions = Session.list_active
              text_content(JSON.generate({
                'status' => 'ok',
                'active_sessions' => sessions.map { |s|
                  { 'session_id' => s.session_id, 'goal_name' => s.goal_name,
                    'state' => s.state, 'cycle' => s.cycle_number }
                }
              }))
            end
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
          end
        end
      end
    end
  end
end
