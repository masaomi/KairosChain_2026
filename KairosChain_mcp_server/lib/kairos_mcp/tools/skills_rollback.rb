require_relative 'base_tool'
require_relative '../version_manager'
require_relative '../action_log'

module KairosMcp
  module Tools
    class SkillsRollback < BaseTool
      def name
        'skills_rollback'
      end

      def description
        'Manage Skills DSL versions. List available versions, create snapshots, or rollback to a previous version.'
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
              description: 'Reason for creating snapshot (for snapshot command)'
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
          return text_content("Error: version filename is required") unless version
          
          begin
            VersionManager.rollback(version)
            ActionLog.record(action: 'rollback_performed', details: { version: version })
            text_content("Rollback successful. Restored to: #{version}")
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
