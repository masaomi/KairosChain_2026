# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # Stage paths and create a commit. Array-form subprocess; no shell.
        class SafeGitCommit < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          def name
            'safe_git_commit'
          end

          def description
            'Stage paths and create a commit. Path arguments are confined to workspace_root before ' \
              '`git add` — paths that escape are rejected. Uses array-form subprocess calls (no shell). ' \
              'In daemon_mode=true, passes --no-verify to skip local hooks.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[git commit stage workspace]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                message: { type: 'string', description: 'Commit message (required)' },
                paths: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Paths to stage. If empty, stages all tracked changes (git add -u).'
                },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' },
                author_name: { type: 'string', description: 'Override author name (via -c user.name)' },
                author_email: { type: 'string', description: 'Override author email (via -c user.email)' },
                daemon_mode: { type: 'boolean', description: 'Skip hooks via --no-verify (default: false)' },
                allow_empty: { type: 'boolean', description: 'Allow commit even if no changes (default: false)' }
              },
              required: ['message']
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            return json_err('workspace is not a git repo') unless File.directory?(File.join(ws, '.git'))

            message = arguments['message'].to_s
            return json_err('message must not be empty') if message.strip.empty?
            return json_err('message contains null byte') if message.include?("\x00")

            paths = Array(arguments['paths'])
            daemon_mode = arguments.fetch('daemon_mode', false)
            allow_empty = arguments.fetch('allow_empty', false)

            # Validate & confine all paths BEFORE touching git.
            confined = paths.map do |p|
              begin
                confine(p, ws)
              rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
                return json_err("confinement: #{e.message}", rejected_path: p)
              end
            end

            # git add
            if confined.empty?
              cmd = ['git', '-C', ws, 'add', '-u']
              stdout, stderr, status = Open3.capture3(*cmd)
              return json_err("git add -u failed: #{stderr.strip}", exit_code: status.exitstatus) unless status.success?
            else
              cmd = ['git', '-C', ws, 'add', '--'] + confined
              stdout, stderr, status = Open3.capture3(*cmd)
              return json_err("git add failed: #{stderr.strip}", exit_code: status.exitstatus) unless status.success?
            end

            # Build commit command
            commit_cmd = ['git', '-C', ws]
            if (an = arguments['author_name'])
              commit_cmd += ['-c', "user.name=#{an}"]
            end
            if (ae = arguments['author_email'])
              commit_cmd += ['-c', "user.email=#{ae}"]
            end
            commit_cmd += ['commit', '-m', message]
            commit_cmd << '--no-verify' if daemon_mode
            commit_cmd << '--allow-empty' if allow_empty

            stdout, stderr, status = Open3.capture3(*commit_cmd)
            unless status.success?
              # Distinguish "nothing to commit" from real failure.
              if stderr.include?('nothing to commit') || stdout.include?('nothing to commit')
                return json_err('nothing to commit', exit_code: status.exitstatus)
              end
              return json_err("git commit failed: #{stderr.strip}", exit_code: status.exitstatus, stdout: stdout)
            end

            # Read resulting commit sha
            sha_out, sha_err, sha_status = Open3.capture3('git', '-C', ws, 'rev-parse', 'HEAD')
            commit_sha = sha_status.success? ? sha_out.strip : nil

            json_ok(
              commit_sha: commit_sha,
              message: message,
              daemon_mode: daemon_mode,
              stdout: stdout.strip
            )
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("commit failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
