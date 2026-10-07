# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'
require_relative 'agent_step'

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
                },
                rationale: {
                  type: 'string',
                  description: 'Why stop (optional). Kept off the chain; the ruling carries its sha256.'
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
              # Fail closed if the persisted record is gone; a stop on a
              # stale snapshot would mask store corruption.
              fresh = Session.load(session_id)
              next { 'status' => 'error',
                     'error' => "session record unreadable for #{session_id}" } unless fresh

              # Stopping an already-terminated session is a no-op, not a new
              # advance: a retried stop must not append duplicate commits.
              if fresh.state == 'terminated'
                next { 'status' => 'ok', 'session_id' => session_id,
                       'state' => 'terminated', 'already_terminated' => true }
              end

              previous_state = fresh.state
              anchor_at_issue = gate.current_anchor(fresh)
              intent = gate.unresolved_intent(cleanup: true)
              # The same point an agent_step stop records: the stop, and the plan
              # with the driver's signals when a plan is the subject (INV-D4).
              # A stop always proceeds, even over a different answer the
              # operator typed at the terminal (the ruling names that answer),
              # and whatever fails while the ruling is prepared.
              point, tables, answer = prepare_stop_ruling(fresh, gate, session_id, anchor_at_issue)

              fresh.update_state('terminated', stop: 'terminated', detail: 'agent_stop')
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
              outcome['stop'] = fresh.stop
              outcome['ruling'] = record_stop_ruling(fresh, anchor_at_issue, point, tables, answer, arguments['rationale'])
              gate.commit(anchor_at_issue, 'stop', outcome)
              text_content(JSON.generate(outcome))
            end

            if result.is_a?(Hash)
              result = result.merge('session_id' => session_id)
              if result['status'] == 'busy'
                result['hint'] = 'an advance is in flight; retry when it settles (agent_status shows advance_in_flight)'
              end
              return text_content(JSON.generate(result))
            end
            result
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
          end

          private

          def prepare_stop_ruling(fresh, gate, session_id, anchor)
            step_tool = AgentStep.new(@safety, registry: @registry)
            point = step_tool.send(:answer_point, fresh, gate)
            tables = step_tool.send(:answer_tables)
            ar = AnswerRuling
            records, read_error = ar.chain_records
            answer = if read_error
                       { 'read_error' => read_error }
                     else
                       ar.reconcile(ar.attestation_at(records, session_id, anchor), action: 'stop')
                         .merge('prior_ruling_block' => ar.prior_ruling_at(records, session_id, anchor)&.dig('block'))
                         .compact
                     end
            [point, tables, answer]
          rescue StandardError => e
            [{ 'state' => fresh.state, 'cycle' => fresh.cycle_number, 'stop' => fresh.stop_kind },
             { 'act_classification' => nil, 'delegation' => nil },
             { 'read_error' => "ruling preparation failed: #{e.class}: #{e.message[0, 100]}" }]
          end

          # The ruling for this stop (design v0.3, INV-D4).
          def record_stop_ruling(session, anchor, point, tables, answer, rationale)
            ar = AnswerRuling
            unless answer['attestation']
              begin
                ar.save_texts(session.guard_dir, anchor: anchor, source: 'caller', rationale: rationale)
              rescue StandardError
                nil
              end
            end
            rec = ar.ruling(session_id: session.session_id, mandate_id: session.mandate_id, anchor: anchor,
                            point: point, action: 'stop', action_key: 'stop', tables: tables,
                            answer: answer, rationale: rationale)
            ar.record(self, rec)
          rescue StandardError => e
            { 'recorded' => false, 'error' => "#{e.class}: #{e.message[0, 160]}" }
          end
        end
      end
    end
  end
end
