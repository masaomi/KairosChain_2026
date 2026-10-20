require_relative 'base_tool'
require_relative '../version_manager'
require_relative '../action_log'
require_relative '../safe_evolver'

module KairosMcp
  module Tools
    class SkillsRollback < BaseTool
      def name
        'skills_rollback'
      end

      def description
        'Manage Skills DSL versions. List available versions, create snapshots, or rollback to a previous version.'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[rollback version snapshot backup restore L0 undo]
      end

      def examples
        [
          {
            title: 'List versions',
            code: 'skills_rollback(command: "list")'
          },
          {
            title: 'Create snapshot',
            code: 'skills_rollback(command: "snapshot", reason: "Before major change")'
          },
          {
            title: 'Rollback to version',
            code: 'skills_rollback(command: "rollback", version: "kairos_20240115_143000.rb")'
          }
        ]
      end

      def related_tools
        %w[skills_evolve skills_dsl_list chain_history]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "list", "snapshot", "rollback", "view", or "diff"',
              enum: ['list', 'snapshot', 'rollback', 'view', 'diff']
            },
            version: {
              type: 'string',
              description: 'Version filename (for rollback/view/diff commands)'
            },
            reason: {
              type: 'string',
              description: 'Reason for the snapshot or the rollback (snapshot and rollback commands)'
            },
            approved: {
              type: 'boolean',
              description: 'Human approval for rollback. Without it nothing is written and a pending proposal is returned.'
            },
            proposal_id: {
              type: 'string',
              description: 'Id of the pending restore proposal to apply. Given, the approval binds that proposal and the version argument is ignored.'
            }
          }
        }
      end

      def call(arguments)
        command = arguments['command'] || 'list'

        case command
        when 'list'
          versions = VersionManager.list_versions
          if versions.empty?
            return text_content("No version snapshots found.")
          end
          
          output = "Available Version Snapshots:\n\n"
          output += "| Filename | Created | Reason |\n"
          output += "|----------|---------|--------|\n"
          versions.each do |v|
            created = v[:created].strftime('%Y-%m-%d %H:%M:%S')
            reason = v[:reason] || '-'
            output += "| #{v[:filename]} | #{created} | #{reason} |\n"
          end
          text_content(output)

        when 'snapshot'
          reason = arguments['reason'] || 'manual snapshot'
          filename = VersionManager.create_snapshot(reason: reason)
          ActionLog.record(action: 'snapshot_created', details: { filename: filename, reason: reason })
          text_content("Snapshot created: #{filename}")

        when 'rollback'
          version = arguments['version']
          proposal_id = arguments['proposal_id']
          unless version || proposal_id
            return text_content("Error: version filename or proposal_id is required")
          end

          begin
            if proposal_id
              # F2b: apply the proposal that was displayed, so the approval binds
              # the (base, result) pair the operator actually saw. Building a
              # fresh proposal here would let the approval land on a different
              # change than the one it was given for.
              stored = L0ProposalStore.load(proposal_id)
              return text_content("Error: proposal #{proposal_id} not found") unless stored

              kind = stored[:kind] || stored['kind']
              unless kind.to_s == 'restore'
                return text_content("Error: proposal #{proposal_id} has kind #{kind}, not restore")
              end

              prop = {
                success: true,
                proposal_id: proposal_id,
                base: stored[:base] || stored['base'],
                result: stored[:result] || stored['result']
              }

              # The displayed pair only binds while its base still describes the
              # current content. If the definition moved on, the proposal is
              # stale and applying it would write a result nobody approved.
              current_base = Digest::SHA256.hexdigest(File.read(KairosMcp.dsl_path))
              if prop[:base] != current_base
                return text_content(
                  "Error: proposal #{proposal_id} is stale. It was built against base " \
                  "#{prop[:base]} but the current content hashes to #{current_base}. " \
                  "Create a new proposal."
                )
              end
            else
              prop = SafeEvolver.propose_restore(version: version, reason: arguments['reason'])
            end

            if !prop[:success]
              text_content("Rollback refused: #{prop[:error]}")
            else
              # Everything shown or logged below describes the stored proposal,
              # the thing the approval binds -- never the caller's `version`,
              # which on the proposal_id path may name a different snapshot.
              proposal = L0ProposalStore.load(prop[:proposal_id]) || {}
              snapshot = proposal['snapshot']
              label = snapshot ? "snapshot #{snapshot}" : "proposal #{prop[:proposal_id]}"
              note = if proposal_id && version && version != snapshot
                       "Note: version #{version} was given, but proposal #{proposal_id} restores " \
                         "#{snapshot || 'an unnamed snapshot'}; the version argument is ignored."
                     end

              res = SafeEvolver.apply(proposal_id: prop[:proposal_id], approved: arguments['approved'] || false)

              if res[:pending]
                # Summarise the change so the approval is an informed one. A diff
                # failure must not swallow the pending message.
                diff_summary = begin
                  # Line counts, stored content vs current: restoring brings back
                  # the stored content's distinct lines and drops the current ones.
                  restored_lines = proposal.fetch('content').lines
                  current_lines = File.read(KairosMcp.dsl_path).lines
                  "+#{(restored_lines - current_lines).size} / -#{(current_lines - restored_lines).size} lines"
                rescue => e
                  "diff unavailable: #{e.message}"
                end

                text_content([
                  note,
                  "Rollback requires approval. Nothing was written.",
                  "Proposal: #{prop[:proposal_id]} (#{label})",
                  "#{prop[:base][0, 12]} -> #{prop[:result][0, 12]} (#{diff_summary})",
                  "Re-run with proposal_id=#{prop[:proposal_id]} and approved=true to apply."
                ].compact.join("\n"))
              elsif res[:success]
                ActionLog.record(action: 'rollback_performed',
                                 details: { proposal_id: prop[:proposal_id], result: prop[:result], snapshot: snapshot })
                text_content([note, "Rollback successful. L0 now holds the content of hash #{prop[:result]} (#{label})."].compact.join("\n"))
              else
                text_content([note, "Rollback failed: #{res[:error]}"].compact.join("\n"))
              end
            end
          rescue => e
            text_content("Rollback failed: #{e.message}")
          end

        when 'view'
          version = arguments['version']
          return text_content("Error: version filename is required") unless version
          
          begin
            content = VersionManager.get_version_content(version)
            # Truncate if too long
            if content.length > 5000
              content = content[0, 5000] + "\n\n... (truncated)"
            end
            text_content("Content of #{version}:\n\n```ruby\n#{content}\n```")
          rescue => e
            text_content("Error: #{e.message}")
          end

        when 'diff'
          version = arguments['version']
          return text_content("Error: version filename is required") unless version
          
          begin
            diff = VersionManager.diff(version)
            output = "Diff Summary (#{version} vs current):\n\n"
            output += "- Old version: #{diff[:old_lines]} lines\n"
            output += "- Current version: #{diff[:current_lines]} lines\n"
            output += "- Lines added: #{diff[:added]}\n"
            output += "- Lines removed: #{diff[:removed]}\n"
            text_content(output)
          rescue => e
            text_content("Error: #{e.message}")
          end

        else
          text_content("Unknown command: #{command}")
        end
      end
    end
  end
end
