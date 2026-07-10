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

          # Registered host keys, derived live from the host-profile registry
          # (bundled default + installed add-on SkillSets). Falls back to the
          # bundled default if the registry cannot be consulted.
          def registered_hosts
            require 'kairos_mcp/plugin_projector'
            ::KairosMcp::PluginProjector::HostProfile.load_addons!(::KairosMcp.data_dir)
            ::KairosMcp::PluginProjector::HostProfile.available
          rescue StandardError
            ['claude']
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
                },
                host: {
                  type: 'string',
                  # INV-H6 (design v0.3 FROZEN): the host choice is derived from the
                  # registry at presentation time, never authored as a fixed list.
                  # Hosts beyond the bundled claude default are contributed by
                  # add-on SkillSets (e.g. codex_projection, opencode_projection).
                  enum: registered_hosts,
                  description: 'Target host (default claude). Registered hosts are discovered ' \
                    'from installed add-on SkillSets; the bundled default is claude.'
                }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            require 'kairos_mcp/plugin_projector'
            require 'kairos_mcp/skillset_manager'

            project_root = ::KairosMcp.project_root
            mode = ::KairosMcp.projection_mode
            host = arguments['host'] || 'claude'
            projector = ::KairosMcp::PluginProjector.new(project_root, mode: mode,
                                                         data_dir: ::KairosMcp.data_dir, host: host)
            # Host-specific hint carried as profile data, not a host-name branch (INV-H1).
            reload_hint = projector.host.reload_hint || ''

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
                  host: host,
                  force: true,
                  message: "Projected to #{host}.#{reload_hint}"
                }))
              else
                changed = projector.project_if_changed!(enabled, knowledge_entries: knowledge_entries)
                text_content(JSON.pretty_generate({
                  status: changed ? 'projected' : 'unchanged',
                  mode: mode,
                  host: host,
                  message: changed ? "Projected to #{host}.#{reload_hint}" : 'No changes detected.'
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
