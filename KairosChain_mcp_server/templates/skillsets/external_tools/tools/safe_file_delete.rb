# frozen_string_literal: true

require 'json'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # Delete a file confined to workspace. Directories are not accepted.
        class SafeFileDelete < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          def name
            'safe_file_delete'
          end

          def description
            'Delete a file confined to workspace_root. Refuses to delete directories ' \
              'and symlinks that point outside the workspace. Returns pre_hash for audit.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[file delete workspace]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                path: { type: 'string', description: 'File path to delete (confined)' },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' },
                missing_ok: { type: 'boolean', description: 'Return ok=true if file already missing (default: false)' }
              },
              required: ['path']
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            abs = confine(arguments['path'], ws)
            missing_ok = arguments.fetch('missing_ok', false)

            unless File.exist?(abs) || File.symlink?(abs)
              return json_ok(path: arguments['path'], deleted: false, reason: 'not found') if missing_ok
              return json_err("not found: #{arguments['path']}")
            end

            if File.directory?(abs) && !File.symlink?(abs)
              return json_err("refuses to delete a directory: #{arguments['path']}")
            end

            pre_hash = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(abs)
            File.unlink(abs)

            json_ok(
              path: arguments['path'],
              absolute_path: abs,
              deleted: true,
              pre_hash: pre_hash
            )
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("delete failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
