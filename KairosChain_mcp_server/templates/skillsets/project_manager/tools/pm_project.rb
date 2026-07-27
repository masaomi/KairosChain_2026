# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ProjectManagerSkillSet
      module Tools
        class PmProject < KairosMcp::Tools::BaseTool
          include ::ProjectManager::ToolHelpers

          def name
            'pm_project'
          end

          def description
            'Manage projects in the project_manager store: register, update (name/status/notes), list. ' \
            'Routine operations only — irreversible actions (abandonment, external commitments) are ' \
            'recorded via pm_record, which the operator must explicitly approve (INV-PM-4).'
          end

          def category
            :project_management
          end

          def usecase_tags
            %w[project management secretary register status]
          end

          def related_tools
            %w[pm_item pm_query pm_digest pm_record]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: { type: 'string', enum: %w[register update list],
                           description: 'Operation to perform' },
                id: { type: 'string', description: 'Project id (update)' },
                name: { type: 'string', description: 'Project name (register/update)' },
                status: { type: 'string', enum: %w[active paused done abandoned],
                          description: 'Project status (update)' },
                notes: { type: 'string', description: 'Free-form notes (register/update)' }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            result =
              case arguments['command']
              when 'register'
                raise ArgumentError, 'name is required' unless arguments['name']

                pm_store.register_project(name: arguments['name'], notes: arguments['notes'])
              when 'update'
                raise ArgumentError, 'id is required' unless arguments['id']

                attrs = arguments.slice('name', 'status', 'notes')
                pm_store.update_project(arguments['id'], attrs)
              when 'list'
                pm_store.projects
              else
                raise ArgumentError, "unknown command: #{arguments['command']}"
              end
            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end
        end
      end
    end
  end
end
