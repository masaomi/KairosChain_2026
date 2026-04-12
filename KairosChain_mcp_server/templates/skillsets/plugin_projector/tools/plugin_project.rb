# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module PluginProjector
      module Tools
        class PluginProject < ::KairosMcp::Tools::BaseTool
          def name
            'plugin_project'
          end

          def description
            'Project SkillSet plugin artifacts to Claude Code structure. ' \
              'Use project to sync, status to check state, verify to validate integrity.'
          end

          def category
            :meta
          end

          def usecase_tags
            %w[plugin projection claude-code meta self-referential]
          end

          def related_tools
            %w[skills_audit skills_promote skillset_acquire]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: {
                  type: 'string',
                  enum: %w[project status verify],
                  description: 'project: sync artifacts to Claude Code structure. ' \
                    'status: show projection state. verify: check projected files match manifest.'
                },
                force: {
                  type: 'boolean',
                  description: 'Force re-projection ignoring digest check (project command only)'
                }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            require_relative '../../../../lib/kairos_mcp/plugin_projector'
            require_relative '../../../../lib/kairos_mcp/skillset_manager'

            project_root = ::KairosMcp.project_root
            mode = ::KairosMcp.projection_mode
            projector = ::KairosMcp::PluginProjector.new(project_root, mode: mode)

            case arguments['command']
            when 'project'
              manager = ::KairosMcp::SkillSetManager.new
              enabled = manager.enabled_skillsets
              knowledge_entries = ::KairosMcp.collect_knowledge_entries

              if arguments['force']
                projector.project!(enabled, knowledge_entries: knowledge_entries)
                text_content(JSON.pretty_generate({
                  status: 'projected',
                  mode: mode,
                  force: true,
                  message: 'Run /reload-plugins to activate new skills.'
                }))
              else
                changed = projector.project_if_changed!(enabled, knowledge_entries: knowledge_entries)
                text_content(JSON.pretty_generate({
                  status: changed ? 'projected' : 'unchanged',
                  mode: mode,
                  message: changed ? 'Run /reload-plugins to activate new skills.' : 'No changes detected.'
                }))
              end

            when 'status'
              text_content(JSON.pretty_generate(projector.status))

            when 'verify'
              result = projector.verify
              text_content(JSON.pretty_generate(result))

            else
              text_content(JSON.pretty_generate({ error: "Unknown command: #{arguments['command']}" }))
            end
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(3) }))
          end
        end
      end
    end
  end
end
