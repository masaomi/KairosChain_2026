# frozen_string_literal: true

require 'securerandom'

module KairosMcp
  module SkillSets
    module Autoexec
      module Tools
        class AutoexecPlan < KairosMcp::Tools::BaseTool
          def name
            'autoexec_plan'
          end

          def description
            'Create a structured task execution plan from a JSON task decomposition. ' \
              'The LLM decomposes a task into steps (as JSON), this tool validates, ' \
              'classifies risk, and stores the plan with a hash lock. ' \
              'Plans are saved but NOT executed — use autoexec_run to execute.'
          end

          def category
            :autoexec
          end

          def usecase_tags
            %w[autoexec plan task decomposition autonomous]
          end

          def related_tools
            %w[autoexec_run]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                task_json: {
                  type: 'string',
                  description: 'JSON string with task decomposition. Format: ' \
                    '{"task_id": "my_task", "meta": {"description": "...", "risk_default": "low"}, ' \
                    '"steps": [{"step_id": "s1", "action": "read files", "risk": "low", ' \
                    '"depends_on": [], "requires_human_cognition": false}]}'
                },
                task_dsl: {
                  type: 'string',
                  description: 'Alternative: provide task plan directly as Kairos DSL string. ' \
                    'Format: task :id do / meta description: "..." / step :s1, action: "...", risk: :low / end'
                }
              }
            }
          end

          def call(arguments)
            task_json = arguments['task_json']
            task_dsl = arguments['task_dsl']

            unless task_json || task_dsl
              return text_content(JSON.pretty_generate({
                error: 'Provide either task_json or task_dsl parameter',
                json_format: {
                  task_id: 'my_task',
                  meta: { description: 'Task description', risk_default: 'medium' },
                  steps: [
                    { step_id: 'step1', action: 'read and analyze files',
                      risk: 'low', depends_on: [], requires_human_cognition: false }
                  ]
                }
              }))
            end

            # Parse plan from JSON or DSL
            plan = if task_json
                     ::Autoexec::TaskDsl.from_json(task_json)
                   else
                     ::Autoexec::TaskDsl.parse(task_dsl)
                   end

            # Generate canonical source and compute hash
            source = ::Autoexec::TaskDsl.to_source(plan)
            plan_hash = ::Autoexec::TaskDsl.compute_hash(source)

            # Classify risk for each step
            risk_summary = ::Autoexec::RiskClassifier.risk_summary(plan.steps)

            # Check for denied operations
            denied_steps = []
            plan.steps.each do |step|
              if ::Autoexec::RiskClassifier.denied?(step.action)
                denied_steps << { step_id: step.step_id, action: step.action }
              end
            end

            unless denied_steps.empty?
              return text_content(JSON.pretty_generate({
                error: 'Plan contains denied operations (L0 deny-list)',
                denied_steps: denied_steps,
                message: 'These operations cannot be executed by autoexec. Remove or modify these steps.'
              }))
            end

            # Save plan
            task_id = plan.task_id.to_s
            stored_hash = ::Autoexec::PlanStore.save(task_id, plan, source)

            # Build required permissions list
            required_permissions = build_permissions(plan)

            result = {
              status: 'planned',
              task_id: task_id,
              plan_hash: stored_hash,
              step_count: plan.steps.size,
              risk_summary: risk_summary,
              steps: plan.steps.map { |s|
                { step_id: s.step_id, action: s.action, risk: s.risk,
                  requires_human_cognition: s.requires_human_cognition }
              },
              required_permissions: required_permissions,
              plan_dsl: source,
              next_steps: [
                'Review the plan above',
                "Run: autoexec_run(task_id: \"#{task_id}\", mode: \"dry_run\", approved_hash: \"#{stored_hash}\")",
                'After dry_run review, change mode to "execute" to run the plan'
              ]
            }

            text_content(JSON.pretty_generate(result))
          rescue ::Autoexec::TaskDsl::ParseError => e
            text_content(JSON.pretty_generate({ error: "DSL parse error: #{e.message}" }))
          rescue ::Autoexec::RiskClassifier::DeniedOperationError => e
            text_content(JSON.pretty_generate({ error: "Denied operation: #{e.message}" }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, type: e.class.name }))
          end

          private

          def build_permissions(plan)
            permissions = { low: [], medium: [], high: [] }
            plan.steps.each do |step|
              risk = step.risk || ::Autoexec::RiskClassifier.classify_step(step)
              permissions[risk] << { step_id: step.step_id, action: step.action }
            end
            permissions
          end
        end
      end
    end
  end
end
