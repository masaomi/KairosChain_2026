# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Autoexec
      module Tools
        class AutoexecRun < KairosMcp::Tools::BaseTool
          def name
            'autoexec_run'
          end

          def description
            'Execute a previously planned task. Verifies plan hash integrity, ' \
              'acquires execution lock, and processes steps in dependency order. ' \
              'Default mode is dry_run (shows what would happen without side effects). ' \
              'Steps marked requires_human_cognition will halt execution for human review. ' \
              'Also shows task status when no approved_hash is provided.'
          end

          def category
            :autoexec
          end

          def usecase_tags
            %w[autoexec run execute autonomous semi-autonomous]
          end

          def related_tools
            %w[autoexec_plan]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                task_id: {
                  type: 'string',
                  description: 'Task ID from autoexec_plan output'
                },
                mode: {
                  type: 'string',
                  enum: %w[dry_run execute status],
                  description: 'dry_run: preview without side effects (default). ' \
                    'execute: run the plan. status: show current task status and plan list.'
                },
                approved_hash: {
                  type: 'string',
                  description: 'Plan hash from autoexec_plan output. Required for dry_run and execute modes. ' \
                    'Ensures the approved plan has not been modified.'
                }
              },
              required: %w[task_id]
            }
          end

          def call(arguments)
            task_id = arguments['task_id']
            mode = arguments['mode'] || 'dry_run'
            approved_hash = arguments['approved_hash']

            # Status mode: show task info without execution
            if mode == 'status'
              return handle_status(task_id)
            end

            # Require approved_hash for dry_run and execute
            unless approved_hash && !approved_hash.empty?
              return text_content(JSON.pretty_generate({
                error: 'approved_hash is required for dry_run and execute modes',
                hint: 'Use the plan_hash from autoexec_plan output'
              }))
            end

            # 1+2. Load plan INTO MEMORY and verify hash atomically (TOCTOU fix)
            stored = ::Autoexec::PlanStore.load(task_id)
            unless stored
              return text_content(JSON.pretty_generate({
                error: "Task '#{task_id}' not found",
                action: 'Run autoexec_plan first to create a plan'
              }))
            end
            plan = stored[:plan]
            source = stored[:source]

            # Verify hash on the loaded in-memory content (single read, no TOCTOU)
            unless stored[:hash] == approved_hash
              return text_content(JSON.pretty_generate({
                error: 'Plan hash mismatch — the plan has been modified since approval',
                task_id: task_id,
                expected_hash: approved_hash,
                actual_hash: stored[:hash],
                action: 'Re-run autoexec_plan to get a new plan and hash'
              }))
            end

            # 3. Acquire execution lock (Day-1 #4)
            ::Autoexec::PlanStore.acquire_lock(task_id)

            begin
              # 4. Check for checkpoint (resume from halted step)
              checkpoint = ::Autoexec::PlanStore.load_checkpoint(task_id)
              completed_step_ids = if checkpoint && checkpoint[:task_id] == task_id.to_s
                                     (checkpoint[:completed_steps] || []).map(&:to_sym)
                                   else
                                     []
                                   end

              # 5. Sort steps by dependency (topological sort)
              sorted_steps = topological_sort(plan.steps)

              # 5a. Two-phase commit: record INTENT block before execution
              intent_ref, intent_error = record_intent(task_id, approved_hash, plan, mode)

              # 5b. Process steps
              results = []
              halted_at = nil

              sorted_steps.each_with_index do |step, idx|
                # Skip already-completed steps (checkpoint resume)
                if completed_step_ids.include?(step.step_id)
                  results << { step_id: step.step_id, status: 'already_completed', index: idx + 1, total: sorted_steps.size }
                  next
                end

                # Check requires_human_cognition (Philosophy BLOCKER resolution)
                if step.requires_human_cognition
                  checkpoint_state = {
                    task_id: task_id,
                    mode: mode,
                    completed_steps: results.map { |r| r[:step_id] },
                    halted_at_step: step.step_id.to_s,
                    reason: 'requires_human_cognition',
                    timestamp: Time.now.iso8601
                  }
                  ::Autoexec::PlanStore.save_checkpoint(task_id, checkpoint_state)
                  halted_at = step.step_id
                  break
                end

                # Classify risk
                risk = step.risk || ::Autoexec::RiskClassifier.classify_step(step)

                step_result = {
                  step_id: step.step_id,
                  action: step.action,
                  risk: risk,
                  index: idx + 1,
                  total: sorted_steps.size
                }

                if mode == 'dry_run'
                  step_result[:status] = 'would_execute'
                  step_result[:message] = "DRY RUN: Would #{step.action}"
                else
                  # Execute mode — actual execution is delegated to the LLM/Claude Code
                  # tool system. AutoExec orchestrates, not executes.
                  step_result[:status] = 'delegated'
                  step_result[:message] = "DELEGATED: #{step.action} — awaiting LLM tool execution"
                end

                results << step_result
              end

              # 6. Record OUTCOME to chain (two-phase commit, phase 2)
              chain_ref, chain_error = record_outcome(task_id, approved_hash, plan, mode, results, halted_at, intent_ref)

              # 7. Update plan status
              status = halted_at ? 'halted' : 'completed'
              ::Autoexec::PlanStore.update_status(task_id, "#{mode}_#{status}")

              # 8. Build response (merged autoexec_status functionality)
              response = {
                task_id: task_id,
                mode: mode,
                plan_hash: approved_hash,
                outcome: halted_at ? 'halted' : (mode == 'dry_run' ? 'dry_run_complete' : 'delegated'),
                steps_completed: results.size,
                steps_remaining: sorted_steps.size - results.size,
                steps: results,
                chain_ref: chain_ref,
                intent_ref: intent_ref
              }

              # Surface chain recording failures (not silently swallowed)
              warnings = []
              warnings << "Intent recording failed: #{intent_error}" if intent_error
              warnings << "Outcome recording failed: #{chain_error}" if chain_error
              unless warnings.empty?
                response[:chain_warning] = warnings.join('; ') + '. ' \
                  'Execution result is valid but not fully recorded on chain.'
              end

              if halted_at
                response[:halted_at] = halted_at
                response[:halt_reason] = 'Human cognitive participation required at this step'
                response[:resume_hint] = 'Review the step, then re-run with the same parameters to continue'
              end

              # Include active tasks list (status functionality)
              response[:all_tasks] = ::Autoexec::PlanStore.list

              text_content(JSON.pretty_generate(response))
            ensure
              # Always release lock
              ::Autoexec::PlanStore.release_lock
            end
          rescue RuntimeError => e
            # Lock acquisition failure
            text_content(JSON.pretty_generate({ error: e.message, task_id: task_id }))
          rescue StandardError => e
            ::Autoexec::PlanStore.release_lock
            text_content(JSON.pretty_generate({ error: e.message, type: e.class.name }))
          end

          private

          def handle_status(task_id)
            stored = ::Autoexec::PlanStore.load(task_id)
            checkpoint = ::Autoexec::PlanStore.load_checkpoint(task_id)
            locked = ::Autoexec::PlanStore.locked?

            result = {
              task_id: task_id,
              exists: !stored.nil?,
              locked: locked,
              checkpoint: checkpoint,
              all_tasks: ::Autoexec::PlanStore.list
            }

            if stored
              result[:plan_hash] = stored[:hash]
              result[:step_count] = stored[:plan].steps.size
              result[:status] = stored[:metadata][:status]
            end

            text_content(JSON.pretty_generate(result))
          end

          def topological_sort(steps)
            step_map = steps.map { |s| [s.step_id, s] }.to_h
            visited = {}
            sorted = []

            visit = lambda do |step|
              return if visited[step.step_id]

              visited[step.step_id] = true
              step.depends_on.each do |dep|
                dep_step = step_map[dep]
                visit.call(dep_step) if dep_step && !visited[dep]
              end
              sorted << step
            end

            steps.each { |s| visit.call(s) }
            sorted
          end

          # Two-phase commit: Phase 1 — record INTENT before execution
          # Returns [ref, error] like record_outcome for consistent error surfacing
          def record_intent(task_id, plan_hash, plan, mode)
            return [nil, nil] unless defined?(KairosChain::Chain)

            begin
              chain = KairosChain::Chain.new
              log_entry = JSON.generate({
                type: 'autoexec_intent',
                task_id: task_id,
                plan_hash: plan_hash,
                step_count: plan.steps.size,
                mode: mode,
                timestamp: Time.now.iso8601
              })
              block = chain.add_block([log_entry])
              [block&.hash, nil]
            rescue StandardError => e
              warn "[autoexec] Intent recording failed: #{e.message}"
              [nil, e.message]
            end
          end

          # Two-phase commit: Phase 2 — record OUTCOME after execution
          def record_outcome(task_id, plan_hash, plan, mode, results, halted_at, intent_ref)
            return [nil, nil] unless defined?(KairosChain::Chain)

            begin
              chain = KairosChain::Chain.new
              outcome = halted_at ? 'halted' : (mode == 'dry_run' ? 'dry_run_complete' : 'delegated')

              log_entry = JSON.generate({
                type: mode == 'dry_run' ? 'autoexec_dry_run' : 'autoexec_outcome',
                task_id: task_id,
                plan_hash: plan_hash,
                step_count: plan.steps.size,
                steps_completed: results.size,
                outcome: outcome,
                mode: mode,
                intent_ref: intent_ref,
                timestamp: Time.now.iso8601
              })

              block = chain.add_block([log_entry])
              [block&.hash, nil]
            rescue StandardError => e
              warn "[autoexec] Outcome recording failed: #{e.message}"
              [nil, e.message]
            end
          end
        end
      end
    end
  end
end
