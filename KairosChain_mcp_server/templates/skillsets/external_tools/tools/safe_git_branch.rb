# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # List, create, or switch git branches. Never takes -f / --force / -D.
        class SafeGitBranch < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          # Branch name validation — conservative subset of refname rules.
          # Allows: alphanumerics, -_./  (no spaces, no shell metachars).
          VALID_BRANCH = /\A[A-Za-z0-9][A-Za-z0-9._\-\/]{0,254}\z/.freeze
          FORBIDDEN = [
            '..', '@{', '//', '\\',
            "\x00", "\x7f"
          ].freeze

          def name
            'safe_git_branch'
          end

          def description
            'List branches, create a new branch, or switch to an existing branch. ' \
              'Never forces, never deletes. Branch names are strictly validated to prevent ' \
              'argument injection into git subcommands.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[git branch workspace]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                action: {
                  type: 'string',
                  enum: %w[list create switch current],
                  description: 'list | create | switch | current (default: list)'
                },
                branch: { type: 'string', description: 'Branch name (required for create/switch)' },
                start_point: { type: 'string', description: 'Create branch from this ref (optional; default HEAD)' },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' }
              }
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            return json_err('workspace is not a git repo') unless File.directory?(File.join(ws, '.git'))

            action = arguments['action'] || 'list'

            case action
            when 'list'    then list_branches(ws)
            when 'current' then current_branch(ws)
            when 'create'  then create_branch(ws, arguments)
            when 'switch'  then switch_branch(ws, arguments)
            else
              json_err("unknown action: #{action}")
            end
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("branch op failed: #{e.class}: #{e.message}")
          end

          private

          def valid_branch_name?(name)
            return false if name.nil? || name.empty?
            return false unless name.match?(VALID_BRANCH)
            return false if FORBIDDEN.any? { |f| name.include?(f) }
            return false if name.start_with?('-') # guard against arg injection
            return false if name.end_with?('.') || name.end_with?('/')
            true
          end

          def list_branches(ws)
            stdout, stderr, status = Open3.capture3('git', '-C', ws, 'branch', '--list', '--format=%(refname:short)')
            return json_err("list failed: #{stderr.strip}") unless status.success?
            branches = stdout.each_line.map(&:strip).reject(&:empty?)
            cur_stdout, _, cur_status = Open3.capture3('git', '-C', ws, 'rev-parse', '--abbrev-ref', 'HEAD')
            current = cur_status.success? ? cur_stdout.strip : nil
            json_ok(branches: branches, current: current, count: branches.size)
          end

          def current_branch(ws)
            stdout, stderr, status = Open3.capture3('git', '-C', ws, 'rev-parse', '--abbrev-ref', 'HEAD')
            return json_err("rev-parse failed: #{stderr.strip}") unless status.success?
            json_ok(current: stdout.strip)
          end

          def create_branch(ws, arguments)
            name = arguments['branch'].to_s
            return json_err("invalid branch name: #{name.inspect}") unless valid_branch_name?(name)

            start = arguments['start_point']
            if start
              return json_err("invalid start_point: #{start.inspect}") unless valid_ref?(start)
              cmd = ['git', '-C', ws, 'branch', '--', name, start]
            else
              cmd = ['git', '-C', ws, 'branch', '--', name]
            end
            stdout, stderr, status = Open3.capture3(*cmd)
            return json_err("create failed: #{stderr.strip}", exit_code: status.exitstatus) unless status.success?
            json_ok(created: name, start_point: start)
          end

          def switch_branch(ws, arguments)
            name = arguments['branch'].to_s
            return json_err("invalid branch name: #{name.inspect}") unless valid_branch_name?(name)
            cmd = ['git', '-C', ws, 'switch', '--', name]
            stdout, stderr, status = Open3.capture3(*cmd)
            return json_err("switch failed: #{stderr.strip}", exit_code: status.exitstatus) unless status.success?
            json_ok(switched_to: name, stdout: stdout.strip)
          end

          def valid_ref?(ref)
            return false if ref.nil? || ref.empty?
            return false if ref.start_with?('-')
            return false if ref.include?("\x00") || ref.include?(' ')
            return false if ref.include?('..') || ref.include?('@{')
            # Loose — git will validate; we only block injection-shaped inputs.
            true
          end
        end
      end
    end
  end
end
