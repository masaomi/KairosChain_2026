# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ProjectManagerSkillSet
      module Tools
        class PmQuery < KairosMcp::Tools::BaseTool
          include ::ProjectManager::ToolHelpers

          def name
            'pm_query'
          end

          def description
            'Query work items by status, salience, temporal proximity, dependency (blocked), or assignee. ' \
            'Read-only: never advances the last-meaningful-touch marker.'
          end

          def category
            :project_management
          end

          def usecase_tags
            %w[query filter status salience deadline blocked]
          end

          def related_tools
            %w[pm_item pm_digest]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                project_id: { type: 'string', description: 'Filter by owning project' },
                status: { type: 'string', enum: %w[open active awaiting_gate done dropped] },
                salience: { type: 'string', enum: %w[low normal high] },
                assignee: { type: 'string', description: 'Filter by holder' },
                blocked: { type: 'boolean', description: 'true = only items with unresolved deps; false = only unblocked' },
                due_within_days: { type: 'integer', description: 'Only items due within N days' }
              }
            }
          end

          def call(arguments)
            result = pm_store.query(
              project_id: arguments['project_id'],
              status: arguments['status'],
              salience: arguments['salience'],
              assignee: arguments['assignee'],
              blocked: arguments.key?('blocked') ? arguments['blocked'] : nil,
              due_within_days: arguments['due_within_days']
            )
            text_content(JSON.pretty_generate({ count: result.size, items: result }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end
        end
      end
    end
  end
end
