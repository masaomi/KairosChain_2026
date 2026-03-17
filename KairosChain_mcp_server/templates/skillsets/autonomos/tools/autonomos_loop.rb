# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Autonomos
      module Tools
        class AutonomosLoop < KairosMcp::Tools::BaseTool
          include ::Autonomos::Ooda

          def name
            'autonomos_loop'
          end

          def description
            'Continuous autonomous execution loop with mandate-based safety. ' \
              'create_mandate: pre-authorize a bounded loop. start: begin first cycle. ' \
              'cycle_complete: reflect on execution + start next cycle. interrupt: stop loop. ' \
              'Each cycle returns a proposal for the LLM to execute via autoexec.'
          end

          def category
            :autonomos
          end

          def usecase_tags
            %w[autonomos loop continuous mandate agent]
          end

          def related_tools
            %w[autonomos_cycle autonomos_reflect autonomos_status autoexec_plan autoexec_run]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: {
                  type: 'string',
                  enum: %w[create_mandate start cycle_complete interrupt],
                  description: 'create_mandate: pre-authorize loop scope. start: begin first cycle. ' \
                    'cycle_complete: reflect + next cycle. interrupt: stop loop.'
                },
                goal_name: {
                  type: 'string',
                  description: 'Goal name — L2 context first, L1 knowledge fallback (for create_mandate)'
                },
                max_cycles: {
                  type: 'integer',
                  description: 'Maximum cycles to run (1-10, for create_mandate)'
                },
                checkpoint_every: {
                  type: 'integer',
                  description: 'Pause for human review every N cycles (1-3, for create_mandate)'
                },
                risk_budget: {
                  type: 'string',
                  enum: %w[low medium],
                  description: 'Maximum risk level for auto-approved actions (for create_mandate)'
                },
                mandate_id: {
                  type: 'string',
                  description: 'Mandate ID (for start, cycle_complete, interrupt)'
                },
                execution_result: {
                  type: 'string',
                  description: 'Result from autoexec execution (for cycle_complete)'
                },
                feedback: {
                  type: 'string',
                  description: 'Human feedback to incorporate (for cycle_complete)'
                }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            ensure_loaded!

            command = arguments['command']

            result = case command
                     when 'create_mandate'
                       handle_create_mandate(arguments)
                     when 'start'
                       handle_start(arguments)
                     when 'cycle_complete'
                       handle_cycle_complete(arguments)
                     when 'interrupt'
                       handle_interrupt(arguments)
                     else
                       { error: "Unknown command: #{command}" }
                     end

            text_content(JSON.pretty_generate(result))
          rescue ::Autonomos::DependencyError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          rescue ArgumentError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, type: e.class.name }))
          end

          private

          def ensure_loaded!
            ::Autonomos.load! unless ::Autonomos.loaded?
          end

          # --- create_mandate ---

          def handle_create_mandate(args)
            goal_name = args['goal_name'] || ::Autonomos.config.fetch('default_goal_name', 'project_goals')
            max_cycles = args['max_cycles'] || 3
            checkpoint_every = args['checkpoint_every'] || 1
            risk_budget = args['risk_budget'] || 'low'

            goal = load_goal(goal_name)
            unless goal[:found]
              return {
                error: "Goal '#{goal_name}' not found",
                hint: 'Set a goal via context_save(name: "project_goals", content: "...") for session-scoped goals, ' \
                      'or knowledge_update for reusable templates'
              }
            end

            goal_hash = Digest::SHA256.hexdigest(goal[:content].to_s)

            mandate = ::Autonomos::Mandate.create(
              goal_name: goal_name,
              goal_hash: goal_hash,
              max_cycles: max_cycles.to_i,
              checkpoint_every: checkpoint_every.to_i,
              risk_budget: risk_budget.to_s
            )

            chain_ref = record_mandate_on_chain(mandate)

            {
              mandate_id: mandate[:mandate_id],
              status: 'created',
              goal_name: goal_name,
              goal_hash: goal_hash,
              max_cycles: max_cycles.to_i,
              checkpoint_every: checkpoint_every.to_i,
              risk_budget: risk_budget,
              chain_ref: chain_ref,
              next_steps: [
                'Review mandate scope above',
                "To start: autonomos_loop(command: \"start\", mandate_id: \"#{mandate[:mandate_id]}\")",
                'To cancel: no action needed (mandate expires unused)'
              ]
            }
          end

          # --- start ---

          def handle_start(args)
            mandate_id = args['mandate_id']
            return { error: 'mandate_id required for start' } unless mandate_id

            mandate = ::Autonomos::Mandate.load(mandate_id)
            return { error: "Mandate '#{mandate_id}' not found" } unless mandate

            unless mandate[:status] == 'created'
              return {
                error: "Mandate is in '#{mandate[:status]}' state, expected 'created'",
                hint: 'Use create_mandate to create a new mandate'
              }
            end

            ::Autonomos::Mandate.update_status(mandate_id, 'active')
            run_cycle(mandate_id, mandate, feedback: nil)
          end

          # --- cycle_complete ---

          def handle_cycle_complete(args)
            mandate_id = args['mandate_id']
            return { error: 'mandate_id required for cycle_complete' } unless mandate_id

            mandate = ::Autonomos::Mandate.load(mandate_id)
            return { error: "Mandate '#{mandate_id}' not found" } unless mandate

            unless %w[active paused_at_checkpoint paused_risk_exceeded].include?(mandate[:status])
              return {
                error: "Mandate is in '#{mandate[:status]}' state",
                hint: 'Mandate must be active or paused to continue'
              }
            end

            execution_result = args['execution_result']
            feedback = args['feedback']

            if %w[paused_at_checkpoint paused_risk_exceeded].include?(mandate[:status])
              ::Autonomos::Mandate.update_status(mandate_id, 'active')
              mandate = ::Autonomos::Mandate.load(mandate_id)
            end

            # Reflect on previous cycle (always via Reflector for state consistency)
            cycle_id_to_reflect = mandate[:last_cycle_id]
            if execution_result
              reflect_result = reflect_on_cycle(mandate, execution_result, feedback)
              evaluation = reflect_result[:evaluation] || 'unknown'
            elsif cycle_id_to_reflect
              # Skip path: use Reflector with skip_reason to close cycle properly
              reflect_result = reflect_on_skipped_cycle(cycle_id_to_reflect, feedback)
              evaluation = reflect_result[:evaluation] || 'skipped'
            else
              # No previous cycle to reflect on (e.g. first cycle_complete after pause)
              evaluation = 'skipped'
            end

            # Record cycle in mandate (always, including skipped — advances state properly)
            mandate = ::Autonomos::Mandate.record_cycle(
              mandate_id,
              cycle_id: mandate[:last_cycle_id],
              evaluation: evaluation
            )

            # Check termination conditions
            termination = ::Autonomos::Mandate.check_termination(mandate)
            if termination
              return terminate_loop(mandate_id, mandate, termination)
            end

            # Check for checkpoint
            if ::Autonomos::Mandate.checkpoint_due?(mandate)
              return pause_at_checkpoint(mandate_id, mandate)
            end

            run_cycle(mandate_id, mandate, feedback: feedback)
          end

          # --- interrupt ---

          def handle_interrupt(args)
            mandate_id = args['mandate_id']
            return { error: 'mandate_id required for interrupt' } unless mandate_id

            mandate = ::Autonomos::Mandate.load(mandate_id)
            return { error: "Mandate '#{mandate_id}' not found" } unless mandate

            if %w[terminated interrupted].include?(mandate[:status])
              return { error: "Mandate already #{mandate[:status]}" }
            end

            terminate_loop(mandate_id, mandate, 'interrupted')
          end

          # --- Core Loop Logic ---

          def run_cycle(mandate_id, mandate, feedback:)
            cycle_id = ::Autonomos::CycleStore.generate_cycle_id

            lock_acquired = false
            begin
              ::Autonomos::CycleStore.acquire_lock(cycle_id)
              lock_acquired = true

              observation = observe(mandate[:goal_name])
              orientation = orient(observation, mandate[:goal_name], feedback)

              # goal_hash verification: detect goal drift since mandate creation
              if orientation[:goal_hash] != mandate[:goal_hash]
                ::Autonomos::Mandate.update_status(mandate_id, 'paused_goal_drift')
                return {
                  mandate_id: mandate_id,
                  status: 'paused_goal_drift',
                  cycle_id: cycle_id,
                  message: 'Goal content has changed since mandate was created. ' \
                    'Create a new mandate with the updated goal, or interrupt this one.',
                  original_hash: mandate[:goal_hash],
                  current_hash: orientation[:goal_hash],
                  next_steps: [
                    "Create new mandate: autonomos_loop(command: \"create_mandate\", goal_name: \"#{mandate[:goal_name]}\")",
                    "Interrupt: autonomos_loop(command: \"interrupt\", mandate_id: \"#{mandate_id}\")"
                  ]
                }
              end

              if orientation[:gaps].empty?
                cycle_state = build_cycle_state(
                  cycle_id, mandate[:goal_name],
                  observation, orientation, nil, 'no_action'
                )
                ::Autonomos::CycleStore.save(cycle_id, cycle_state)
                return terminate_loop(mandate_id, mandate, 'goal_achieved')
              end

              proposal = decide(orientation)
              intent_ref, _intent_error = record_intent(cycle_id, mandate[:goal_name], orientation, proposal)

              cycle_state = build_cycle_state(
                cycle_id, mandate[:goal_name],
                observation, orientation, proposal, 'decided'
              )
              cycle_state[:intent_ref] = intent_ref
              cycle_state[:mandate_id] = mandate_id
              ::Autonomos::CycleStore.save(cycle_id, cycle_state)

              # Loop detection (3-step lookback)
              recent_gaps = Array(mandate[:recent_gap_descriptions])
              if ::Autonomos::Mandate.loop_detected?(proposal, recent_gaps)
                return terminate_loop(mandate_id, mandate, 'loop_detected')
              end

              # Update mandate with current cycle info
              gap_desc = proposal.dig(:selected_gap, :description)
              recent_gaps = (recent_gaps + [gap_desc]).last(3)
              mandate[:last_proposal] = proposal
              mandate[:last_cycle_id] = cycle_id
              mandate[:recent_gap_descriptions] = recent_gaps
              ::Autonomos::Mandate.save(mandate_id, mandate)

              # Risk budget gate
              if ::Autonomos::Mandate.risk_exceeds_budget?(proposal, mandate[:risk_budget])
                ::Autonomos::Mandate.update_status(mandate_id, 'paused_risk_exceeded')
                return {
                  mandate_id: mandate_id,
                  status: 'paused_risk_exceeded',
                  cycle_id: cycle_id,
                  cycles_completed: mandate[:cycles_completed],
                  proposal_summary: summarize_proposal(proposal),
                  risk_budget: mandate[:risk_budget],
                  next_steps: [
                    'Proposal exceeds risk budget. Review and decide:',
                    "Execute manually then continue: autonomos_loop(command: \"cycle_complete\", mandate_id: \"#{mandate_id}\", execution_result: \"...\")",
                    "Skip and continue: autonomos_loop(command: \"cycle_complete\", mandate_id: \"#{mandate_id}\")",
                    "Stop: autonomos_loop(command: \"interrupt\", mandate_id: \"#{mandate_id}\")"
                  ]
                }
              end

              complexity = proposal[:complexity_hint] || { level: 'low', signals: [] }
              steps = [
                "Execute via autoexec: autoexec_plan(task_json: '#{JSON.generate(proposal[:autoexec_task])}')",
                "After execution: autonomos_loop(command: \"cycle_complete\", mandate_id: \"#{mandate_id}\", execution_result: \"...\")",
                "To stop: autonomos_loop(command: \"interrupt\", mandate_id: \"#{mandate_id}\")"
              ]

              if complexity[:level] != 'low'
                steps.unshift(
                  "COMPLEXITY #{complexity[:level].upcase} (#{complexity[:signals].join(', ')}): " \
                  'Consider running sc_review(persona_assembly) on this proposal before executing.'
                )
              end

              {
                mandate_id: mandate_id,
                status: 'active',
                cycle_id: cycle_id,
                cycle_number: mandate[:cycles_completed] + 1,
                cycles_remaining: mandate[:max_cycles] - mandate[:cycles_completed],
                proposal_summary: summarize_proposal(proposal),
                complexity_hint: complexity,
                autoexec_task: proposal[:autoexec_task],
                next_steps: steps
              }
            ensure
              ::Autonomos::CycleStore.release_lock if lock_acquired
            end
          end

          def reflect_on_cycle(mandate, execution_result, feedback)
            # Direct lookup by stored cycle_id (not scan)
            cycle_id = mandate[:last_cycle_id]
            unless cycle_id
              return { cycle_id: nil, evaluation: 'unknown' }
            end

            cycle = ::Autonomos::CycleStore.load(cycle_id)
            unless cycle && cycle[:state] == 'decided'
              return { cycle_id: cycle_id, evaluation: 'unknown' }
            end

            reflector = ::Autonomos::Reflector.new(
              cycle_id,
              execution_result: execution_result,
              feedback: feedback
            )
            result = reflector.reflect
            { cycle_id: cycle_id, evaluation: result[:evaluation] }
          end

          def reflect_on_skipped_cycle(cycle_id, feedback)
            cycle = ::Autonomos::CycleStore.load(cycle_id)
            unless cycle && cycle[:state] == 'decided'
              return { cycle_id: cycle_id, evaluation: 'skipped' }
            end

            reflector = ::Autonomos::Reflector.new(
              cycle_id,
              skip_reason: 'Skipped by user (no execution result provided)',
              feedback: feedback
            )
            result = reflector.reflect
            { cycle_id: cycle_id, evaluation: result[:evaluation] }
          end

          def terminate_loop(mandate_id, mandate, reason)
            new_status = reason == 'interrupted' ? 'interrupted' : 'terminated'
            mandate[:status] = new_status
            mandate[:termination_reason] = reason
            ::Autonomos::Mandate.save(mandate_id, mandate)

            chain_ref = record_loop_summary(mandate, reason)
            evaluations = mandate[:cycle_history].map { |c| c[:evaluation] }

            {
              mandate_id: mandate_id,
              status: new_status,
              termination_reason: reason,
              cycles_completed: mandate[:cycles_completed],
              evaluations: evaluations,
              chain_ref: chain_ref,
              message: termination_message(reason)
            }
          end

          def pause_at_checkpoint(mandate_id, mandate)
            ::Autonomos::Mandate.update_status(mandate_id, 'paused_at_checkpoint')

            evaluations = mandate[:cycle_history].map { |c| c[:evaluation] }

            {
              mandate_id: mandate_id,
              status: 'paused_at_checkpoint',
              cycles_completed: mandate[:cycles_completed],
              cycles_remaining: mandate[:max_cycles] - mandate[:cycles_completed],
              last_evaluation: evaluations.last,
              cumulative_evaluations: evaluations,
              checkpoint_prompt: 'Review progress. Continue with cycle_complete, or interrupt.',
              next_steps: [
                "Continue: autonomos_loop(command: \"cycle_complete\", mandate_id: \"#{mandate_id}\", feedback: \"...\")",
                "Stop: autonomos_loop(command: \"interrupt\", mandate_id: \"#{mandate_id}\")"
              ]
            }
          end

          # --- Helpers ---

          def summarize_proposal(proposal)
            return nil unless proposal

            {
              task_id: proposal[:task_id],
              design_intent: proposal[:design_intent],
              gap_description: proposal.dig(:selected_gap, :description),
              remaining_gaps: proposal[:remaining_gaps],
              risk: proposal.dig(:autoexec_task, :meta, :risk_default)
            }
          end

          def termination_message(reason)
            case reason
            when 'goal_achieved'
              'All gaps resolved. Goal appears achieved.'
            when 'max_cycles_reached'
              'Maximum cycle count reached. Review progress and create a new mandate to continue.'
            when 'error_threshold'
              '2 consecutive failures. Review errors and create a new mandate with adjusted approach.'
            when 'loop_detected'
              'Same gap pattern detected. Approach may need human redesign.'
            when 'interrupted'
              'Loop interrupted by user.'
            else
              "Loop terminated: #{reason}"
            end
          end

          # --- Chain Recording ---

          def record_mandate_on_chain(mandate)
            return nil unless defined?(KairosChain::Chain)

            begin
              chain = KairosChain::Chain.new
              log_entry = JSON.generate({
                _type: 'autonomos_mandate',
                mandate_id: mandate[:mandate_id],
                goal_name: mandate[:goal_name],
                goal_hash: mandate[:goal_hash],
                max_cycles: mandate[:max_cycles],
                checkpoint_every: mandate[:checkpoint_every],
                risk_budget: mandate[:risk_budget],
                timestamp: Time.now.iso8601
              })
              block = chain.add_block([log_entry])
              block&.hash
            rescue StandardError => e
              warn "[autonomos] Mandate recording failed: #{e.message}"
              nil
            end
          end

          def record_loop_summary(mandate, reason)
            return nil unless defined?(KairosChain::Chain)

            begin
              chain = KairosChain::Chain.new
              log_entry = JSON.generate({
                _type: 'autonomos_loop_summary',
                mandate_id: mandate[:mandate_id],
                cycles_completed: mandate[:cycles_completed],
                termination_reason: reason,
                evaluations: mandate[:cycle_history].map { |c| c[:evaluation] },
                timestamp: Time.now.iso8601
              })
              block = chain.add_block([log_entry])
              block&.hash
            rescue StandardError => e
              warn "[autonomos] Loop summary recording failed: #{e.message}"
              nil
            end
          end
        end
      end
    end
  end
end
