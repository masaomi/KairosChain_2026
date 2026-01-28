# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../state_commit/commit_service'
require_relative '../state_commit/snapshot_manager'

module KairosMcp
  module Tools
    # StateHistory: MCP tool to view state commit history
    #
    # Shows past commits with their metadata and change summaries.
    #
    class StateHistory < BaseTool
      def name
        'state_history'
      end

      def description
        'View state commit history. Shows past snapshots with reasons and change summaries.'
      end

      def category
        :state
      end

      def usecase_tags
        %w[history snapshots commits audit trail past]
      end

      def examples
        [
          {
            title: 'View recent history',
            code: 'state_history(limit: 10)'
          },
          {
            title: 'View specific commit',
            code: 'state_history(hash: "abc12345")'
          }
        ]
      end

      def related_tools
        %w[state_status state_commit chain_history]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            limit: {
              type: 'integer',
              description: 'Maximum number of commits to show (default: 10)',
              default: 10
            },
            hash: {
              type: 'string',
              description: 'Show details for a specific commit by hash (first 8 chars or full)'
            }
          }
        }
      end

      def call(arguments)
        limit = arguments['limit'] || 10
        hash = arguments['hash']

        if hash
          show_commit_details(hash)
        else
          show_history(limit)
        end
      end

      private

      def show_history(limit)
        service = KairosMcp::StateCommit::CommitService.new
        commits = service.history(limit: limit)

        if commits.empty?
          return text_content("No state commits found.\n\nUse state_commit to create the first commit.")
        end

        output = "State Commit History\n"
        output += "=" * 50 + "\n\n"

        commits.each_with_index do |commit, index|
          output += format_commit_summary(commit, index + 1)
          output += "\n"
        end

        output += "-" * 50 + "\n"
        output += "Total: #{commits.size} commits shown\n"
        output += "\nUse state_history hash=\"<hash>\" to see details for a specific commit."

        text_content(output)
      end

      def show_commit_details(hash)
        manager = KairosMcp::StateCommit::SnapshotManager.new
        
        # Try to find by partial or full hash
        snapshot = manager.load_snapshot(hash)
        
        # If not found by full hash, try to find by partial hash in filename
        unless snapshot
          snapshots = manager.list_snapshots(limit: 100)
          match = snapshots.find { |s| s[:snapshot_hash]&.start_with?(hash) }
          if match
            snapshot = manager.load_snapshot(match[:snapshot_hash])
          end
        end

        unless snapshot
          return text_content("Commit not found: #{hash}\n\nUse state_history to see available commits.")
        end

        format_commit_details(snapshot)
      end

      def format_commit_summary(commit, number)
        output = "Commit ##{number} (#{commit[:created_at]})\n"
        output += "  Hash: #{commit[:snapshot_hash][0..15]}...\n"
        output += "  Type: #{commit[:commit_type]}\n"
        output += "  By: #{commit[:created_by]}\n"
        output += "  Reason: #{commit[:reason]}\n"
        output += "  Changes: #{commit[:change_count]} recorded\n"
        output
      end

      def format_commit_details(snapshot)
        output = "State Commit Details\n"
        output += "=" * 50 + "\n\n"

        output += "Hash: #{snapshot['snapshot_hash']}\n"
        output += "Created: #{snapshot['created_at']}\n"
        output += "Type: #{snapshot['commit_type']}\n"
        output += "By: #{snapshot['created_by']}\n"
        output += "Reason: #{snapshot['reason']}\n\n"

        # Layer summaries
        output += "Layers:\n"
        layers = snapshot['layers'] || {}

        if layers['L0']
          l0 = layers['L0']
          output += "  L0 (Meta-skills):\n"
          output += "    Manifest Hash: #{l0['manifest_hash']&.[](0..15)}...\n"
          output += "    Skills: #{l0['skill_count'] || l0['skills']&.size || 0}\n"
          if l0['skills']&.any?
            l0['skills'].first(5).each do |s|
              output += "      - #{s['id']} (v#{s['version']})\n"
            end
            if l0['skills'].size > 5
              output += "      ... and #{l0['skills'].size - 5} more\n"
            end
          end
        end

        if layers['L1']
          l1 = layers['L1']
          output += "  L1 (Knowledge):\n"
          output += "    Manifest Hash: #{l1['manifest_hash']&.[](0..15)}...\n"
          output += "    Knowledge: #{l1['knowledge_count'] || l1['knowledge']&.size || 0}\n"
          output += "    Archived: #{l1['archived_count'] || l1['archived']&.size || 0}\n"
          if l1['knowledge']&.any?
            l1['knowledge'].first(5).each do |k|
              output += "      - #{k['name']}\n"
            end
            if l1['knowledge'].size > 5
              output += "      ... and #{l1['knowledge'].size - 5} more\n"
            end
          end
        end

        if layers['L2']
          l2 = layers['L2']
          output += "  L2 (Context):\n"
          output += "    Manifest Hash: #{l2['manifest_hash']&.[](0..15)}...\n"
          output += "    Sessions: #{l2['session_count'] || l2['sessions']&.size || 0}\n"
          if l2['sessions']&.any?
            l2['sessions'].first(5).each do |s|
              output += "      - #{s['id']} (#{s['context_count']} contexts)\n"
            end
          end
        end

        output += "\n"

        # Changes since last
        changes = snapshot['changes_since_last'] || []
        output += "Changes Since Last Commit: #{changes.size}\n"
        if changes.any?
          changes.first(10).each do |change|
            output += "  - [#{change['layer']}] #{change['action']}: #{change['skill_id']}\n"
          end
          if changes.size > 10
            output += "  ... and #{changes.size - 10} more changes\n"
          end
        end

        text_content(output)
      end
    end
  end
end
