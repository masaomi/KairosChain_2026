# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # Push a branch to a remote. Requires explicit `confirm: true`.
        # `force` is explicitly not supported; use lower-level git manually for that.
        class SafeGitPush < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          REMOTE_NAME = /\A[A-Za-z0-9][A-Za-z0-9._\-]{0,62}\z/.freeze
          BRANCH_NAME = /\A[A-Za-z0-9][A-Za-z0-9._\-\/]{0,254}\z/.freeze

          def name
            'safe_git_push'
          end

          def description
            'Push a branch to a remote. Requires risk_budget >= "high" AND explicit confirm=true. ' \
              'Never force-pushes. Remote and branch names are strictly validated to prevent ' \
              'argument injection. Array-form subprocess (no shell).'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[git push network high_risk]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                remote: { type: 'string', description: 'Remote name (default: origin)' },
                branch: { type: 'string', description: 'Branch to push (default: current HEAD)' },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' },
                risk_budget: {
                  type: 'string',
                  enum: %w[low medium high],
                  description: 'Caller risk budget — must be "high" to proceed'
                },
                confirm: { type: 'boolean', description: 'Must be true — explicit confirmation flag' },
                set_upstream: { type: 'boolean', description: 'Pass --set-upstream (default: false)' }
              },
              required: %w[risk_budget confirm]
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            return json_err('workspace is not a git repo') unless File.directory?(File.join(ws, '.git'))

            risk_budget = arguments['risk_budget'].to_s
            return json_err("risk_budget must be 'high' for push (got #{risk_budget.inspect})") unless risk_budget == 'high'
            return json_err('confirm must be true to proceed with push') unless arguments['confirm'] == true

            remote = (arguments['remote'] || 'origin').to_s
            return json_err("invalid remote: #{remote.inspect}") unless remote.match?(REMOTE_NAME)
            return json_err('remote must not start with -') if remote.start_with?('-')

            branch = arguments['branch']
            if branch.nil? || branch.to_s.empty?
              cur_stdout, _, cur_status = Open3.capture3('git', '-C', ws, 'rev-parse', '--abbrev-ref', 'HEAD')
              return json_err('could not determine current branch') unless cur_status.success?
              branch = cur_stdout.strip
              return json_err("detached HEAD — explicit branch required") if branch == 'HEAD'
            end
            branch = branch.to_s
            return json_err("invalid branch: #{branch.inspect}") unless branch.match?(BRANCH_NAME)
            return json_err('branch must not start with -') if branch.start_with?('-')

            set_upstream = arguments.fetch('set_upstream', false)

            # Verify remote is configured (read-only check)
            rem_stdout, rem_stderr, rem_status = Open3.capture3('git', '-C', ws, 'remote', 'get-url', '--', remote)
            return json_err("remote not configured: #{remote}", stderr: rem_stderr.strip) unless rem_status.success?

            cmd = ['git', '-C', ws, 'push']
            cmd << '--set-upstream' if set_upstream
            cmd += ['--', remote, branch]

            stdout, stderr, status = Open3.capture3(*cmd)
            unless status.success?
              return json_err("push failed: #{stderr.strip}", exit_code: status.exitstatus, stdout: stdout.strip)
            end

            json_ok(
              remote: remote,
              remote_url: rem_stdout.strip,
              branch: branch,
              set_upstream: set_upstream,
              stdout: stdout.strip,
              stderr: stderr.strip
            )
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("push failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
