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

              # Interruption resilience Slice A (INV-A4): the status surface
              # answers "what should the next call be" from persisted state
              # alone, so a fresh driver recovers by reading and re-issuing —
              # no reconstruction of intent required.
              gate = AdvanceGate.new(session.guard_dir)
              payload = {
                'status' => 'ok',
                'session_id' => session.session_id,
                'mandate_id' => session.mandate_id,
                'goal_name' => session.goal_name,
                'state' => session.state,
                'cycle_number' => session.cycle_number,
                'anchor' => gate.current_anchor(session)
              }
              # Slice A-2: surface the delegation handle so a fresh driver
              # learns about an in-flight or finished delegated step from
              # persisted state alone.
              delegation = StepDelegation.new(session.guard_dir)
              dstatus = delegation.status
              if dstatus != 'none'
                payload['delegation'] = {
                  'status' => dstatus,
                  'step_token' => delegation.pending&.dig('step_token')
                }.compact
                if %w[ready still_pending].include?(dstatus)
                  payload['next_move'] = {
                    'tool' => 'agent_wait',
                    'args' => { 'session_id' => session.session_id },
                    'reason' => dstatus == 'ready' ? 'delegated step finished; collect its outcome' : 'delegated step in flight; wait for it'
                  }
                  return text_content(JSON.generate(payload))
                end
              end

              if gate.busy?
                # An open intent while the lock is held is normal execution,
                # not an unresolved point — report in-flight instead.
                payload['advance_in_flight'] = true
                payload['next_move'] = {
                  'tool' => 'agent_status',
                  'args' => { 'session_id' => session.session_id },
                  'reason' => 'an advance is executing; poll status until it settles, then follow next_move'
                }
              else
                payload['next_move'] = gate.next_move(session)
              end
              text_content(JSON.generate(payload))
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
