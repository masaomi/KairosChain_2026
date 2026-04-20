# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # Read-only `git status --porcelain=v1` inside the workspace.
        class SafeGitStatus < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          def name
            'safe_git_status'
          end

          def description
            'Run `git status --porcelain=v1 -b` in the workspace repository. Read-only. ' \
              'Returns branch, clean flag, and structured entries.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[git status readonly workspace]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                workspace_root: { type: 'string', description: 'Optional override of workspace root' },
                untracked: {
                  type: 'string',
                  enum: %w[no normal all],
                  description: 'git --untracked-files mode (default: normal)'
                }
              }
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            return json_err('workspace is not a git repo') unless File.directory?(File.join(ws, '.git'))

            untracked = arguments['untracked'] || 'normal'
            cmd = ['git', '-C', ws, 'status', '--porcelain=v1', '-b', "--untracked-files=#{untracked}"]
            stdout, stderr, status = Open3.capture3(*cmd)
            return json_err("git status failed: #{stderr.strip}", exit_code: status.exitstatus) unless status.success?

            branch = nil
            entries = []
            stdout.each_line do |line|
              line = line.chomp
              if line.start_with?('## ')
                branch = line.sub(/^## /, '')
                next
              end
              next if line.empty?
              # Porcelain v1: XY <path>  (2-char status + single space)
              xy = line[0, 2]
              path = line[3..]
              entries << { xy: xy, path: path }
            end

            clean = entries.empty?
            json_ok(branch: branch, clean: clean, entries: entries, count: entries.size)
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("status failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
