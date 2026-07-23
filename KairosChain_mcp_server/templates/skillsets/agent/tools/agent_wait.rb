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
                collected = ready_response(session, delegation)
                # nil means a concurrent collector/fresh delegation won the
                # race after we observed 'ready'; keep polling rather than
                # returning a stale outcome.
                return collected if collected
              when 'none'
                return text_content(JSON.generate({
                  'status' => 'no_delegation', 'session_id' => session_id,
                  'next_action' => status_hint(session_id,
                                               'no delegated step is pending; read agent_status and follow next_move')
                }))
              when 'crashed'
                recovered = crashed_response(session, delegation)
                # nil => the handle was superseded between the crash read and
                # the recovery claim; keep polling against the new generation.
                return recovered if recovered
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

          # Returns the MCP ready content, or nil if the result we observed was
          # collected/superseded by a concurrent caller before we could claim
          # it under the lock (the wait loop then keeps polling — never a stale
          # outcome).
          def ready_response(session, delegation)
            # collect() decides readiness against the live pending under the
            # lock and returns the result only if it belongs to the current
            # handle; nil means superseded/collected -> the wait loop keeps
            # polling rather than returning a stale outcome.
            raw = delegation.collect
            return nil unless raw

            outcome = raw['outcome'] || { 'status' => 'error', 'error' => 'result unreadable' }
            # next_move is best-effort: the outcome has already been consumed,
            # so a failure to derive the hint must not lose the return value.
            next_move = begin
              fresh = Session.load(session.session_id) || session
              AdvanceGate.new(fresh.guard_dir).next_move(fresh)
            rescue StandardError
              nil
            end
            text_content(JSON.generate({
              'status' => 'ready', 'session_id' => session.session_id,
              'outcome' => outcome,
              'next_move' => next_move
            }))
          end

          # Crash-window (b): the worker committed its gated advance (state
          # moved, seq bumped, replay record written) but died before writing
          # the result. Recover the committed outcome from the gate log at the
          # handle's issue-anchor AND action (so a different judgment that
          # consumed the same anchor never returns the wrong outcome), so the
          # return value is not lost.
          # Returns MCP content, or nil when the handle was superseded between
          # the (unlocked) crash observation and the recovery claim — in which
          # case the wait loop keeps polling against the new generation rather
          # than returning a recovered outcome for a stale one.
          def crashed_response(session, delegation)
            pending = delegation.pending
            return nil unless pending # already collected/superseded to none
            issue_anchor = pending['issue_anchor']
            action_key = pending['action_key']
            token = pending['step_token']
            gate = AdvanceGate.new(session.guard_dir)
            committed = issue_anchor && gate.committed_outcome(issue_anchor, action_key)

            if committed
              # Claim the recovery only if we still own this handle; if a fresh
              # delegation superseded it, decline (return nil -> keep polling).
              return nil unless delegation.clear_pending_if(token)
              fresh = Session.load(session.session_id) || session
              return text_content(JSON.generate({
                'status' => 'ready', 'session_id' => session.session_id,
                'recovered' => true, 'outcome' => committed,
                'next_move' => AdvanceGate.new(fresh.guard_dir).next_move(fresh)
              }))
            end

            # Nothing committed: the worker died before the gate advanced, so a
            # re-issue is a fresh, exactly-once execution. Point the driver at
            # agent_status/next_move.
            text_content(JSON.generate({
              'status' => 'crashed', 'session_id' => session.session_id,
              'step_token' => pending&.dig('step_token'),
              'next_action' => status_hint(session.session_id,
                                           'the delegated worker died before committing; the gate makes a ' \
                                           're-issue safe (exactly-once) — read agent_status and follow next_move')
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
