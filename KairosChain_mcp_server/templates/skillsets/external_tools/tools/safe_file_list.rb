# frozen_string_literal: true

require 'json'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # List directory contents, confined to workspace_root.
        class SafeFileList < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          DEFAULT_MAX_ENTRIES = 1000

          def name
            'safe_file_list'
          end

          def description
            'List directory entries confined to workspace_root. Returns file type, size, and mtime. ' \
              'Does not follow symlinks to escape the workspace.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[file list directory workspace]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                path: { type: 'string', description: 'Directory path (default: workspace root)' },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' },
                include_hidden: { type: 'boolean', description: 'Include dotfiles (default: false)' },
                max_entries: { type: 'integer', description: "Max entries to return (default: #{DEFAULT_MAX_ENTRIES})" }
              }
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            path = arguments['path'] || '.'
            abs = confine(path, ws)
            return json_err("not a directory: #{path}") unless File.directory?(abs)

            include_hidden = arguments.fetch('include_hidden', false)
            max_entries = (arguments['max_entries'] || DEFAULT_MAX_ENTRIES).to_i
            truncated = false

            entries = []
            Dir.entries(abs).sort.each do |entry|
              next if entry == '.' || entry == '..'
              next if !include_hidden && entry.start_with?('.')
              if entries.size >= max_entries
                truncated = true
                break
              end
              child = File.join(abs, entry)
              stat = File.lstat(child)
              type =
                if stat.symlink? then 'symlink'
                elsif stat.directory? then 'directory'
                elsif stat.file? then 'file'
                else 'other'
                end
              entries << {
                name: entry,
                type: type,
                size: stat.size,
                mtime: stat.mtime.iso8601
              }
            end

            json_ok(
              path: path,
              absolute_path: abs,
              entries: entries,
              count: entries.size,
              truncated: truncated
            )
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("list failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
