# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        # Interruption resilience Slice A-2 (INV-A1/A4): server-side blocking
        # wait for a delegated agent step. Mirrors the review SkillSet's wait
        # surface: every status carries a deterministic next_action recovery
        # hint, so a fresh driver — including one that never saw the
        # initiating call — recovers by reading and re-issuing.
        class AgentWait < KairosMcp::Tools::BaseTool
          POLL_INTERVAL_SECONDS = 1.0
          MAX_WAIT_DEFAULT_SECONDS = 600
          MAX_WAIT_HARD_CAP_SECONDS = 1800

          def name
            'agent_wait'
          end

          def description
            'Block until a delegated agent step (agent_step with execution: "delegated") ' \
              'completes. Returns the step outcome when ready, or a status with a ' \
              'deterministic next_action hint (still_pending / crashed / no_delegation).'
          end

          def category
            :agent
          end

          def usecase_tags
            %w[agent wait delegation resume]
          end

          def related_tools
            %w[agent_step agent_status agent_stop]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                session_id: {
                  type: 'string',
                  description: 'Agent session ID whose delegated step to wait for'
                },
                max_wait_seconds: {
                  type: 'integer',
                  description: "Server-side blocking cap (default #{MAX_WAIT_DEFAULT_SECONDS}, " \
                               "hard cap #{MAX_WAIT_HARD_CAP_SECONDS})"
                }
              },
              required: %w[session_id]
            }
          end

          def call(arguments)
            session_id = arguments['session_id']
            session = Session.load(session_id)
            return text_content(JSON.generate({ 'status' => 'error', 'error' => 'Session not found' })) unless session

            max_wait = [(arguments['max_wait_seconds'] || MAX_WAIT_DEFAULT_SECONDS).to_i,
                        MAX_WAIT_HARD_CAP_SECONDS].min
            max_wait = MAX_WAIT_DEFAULT_SECONDS if max_wait <= 0

            delegation = StepDelegation.new(session.guard_dir)
            deadline = Time.now + max_wait

            loop do
              case delegation.status
              when 'ready'
                return ready_response(session, delegation)
              when 'none'
                return text_content(JSON.generate({
                  'status' => 'no_delegation', 'session_id' => session_id,
                  'next_action' => status_hint(session_id,
                                               'no delegated step is pending; read agent_status and follow next_move')
                }))
              when 'crashed'
                return text_content(JSON.generate({
                  'status' => 'crashed', 'session_id' => session_id,
                  'step_token' => delegation.pending&.dig('step_token'),
                  'next_action' => status_hint(session_id,
                                               'the delegated worker died; the gate makes a re-issue safe — ' \
                                               'read agent_status and follow next_move (a committed advance replays, ' \
                                               'an uncommitted one re-executes exactly once)')
                }))
              end

              if Time.now >= deadline
                return text_content(JSON.generate({
                  'status' => 'still_pending', 'session_id' => session_id,
                  'step_token' => delegation.pending&.dig('step_token'),
                  'next_action' => {
                    'tool' => 'agent_wait',
                    'args' => { 'session_id' => session_id, 'max_wait_seconds' => max_wait },
                    'purpose' => 'worker alive; wait again'
                  }
                }))
              end
              sleep POLL_INTERVAL_SECONDS
            end
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => "#{e.class}: #{e.message}" }))
          end

          private

          def ready_response(session, delegation)
            outcome = delegation.result || { 'status' => 'error', 'error' => 'result unreadable' }
            fresh = Session.load(session.session_id) || session
            gate = AdvanceGate.new(fresh.guard_dir)
            text_content(JSON.generate({
              'status' => 'ready', 'session_id' => session.session_id,
              'outcome' => outcome,
              'next_move' => gate.next_move(fresh)
            }))
          end

          def status_hint(session_id, purpose)
            { 'tool' => 'agent_status', 'args' => { 'session_id' => session_id },
              'purpose' => purpose }
          end
        end
      end
    end
  end
end
