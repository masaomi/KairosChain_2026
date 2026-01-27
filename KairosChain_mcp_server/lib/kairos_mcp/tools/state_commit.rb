# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../state_commit/commit_service'

module KairosMcp
  module Tools
    # StateCommit: MCP tool for explicit state commits
    #
    # Creates a snapshot of the current L0/L1/L2 state and records it to blockchain.
    #
    class StateCommit < BaseTool
      def name
        'state_commit'
      end

      def description
        'Create a state commit (snapshot of L0/L1/L2 layers). Records to blockchain for auditability.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "commit" to create a commit',
              enum: ['commit'],
              default: 'commit'
            },
            reason: {
              type: 'string',
              description: 'Reason for the commit (required for explicit commits)'
            },
            force: {
              type: 'boolean',
              description: 'Force commit even if no changes detected (default: false)',
              default: false
            }
          },
          required: ['reason']
        }
      end

      def call(arguments)
        command = arguments['command'] || 'commit'
        reason = arguments['reason']
        force = arguments['force'] || false

        case command
        when 'commit'
          handle_commit(reason, force)
        else
          text_content("Unknown command: #{command}")
        end
      end

      private

      def handle_commit(reason, force)
        if reason.nil? || reason.strip.empty?
          return text_content(<<~MSG)
            ERROR: Reason is required for explicit commit.

            Usage:
              state_commit reason="Your commit message here"

            Example:
              state_commit reason="Feature implementation complete"
              state_commit reason="Weekly checkpoint" force=true
          MSG
        end

        service = KairosMcp::StateCommit::CommitService.new
        result = service.explicit_commit(reason: reason, actor: 'human', force: force)

        if result[:success]
          format_success(result)
        else
          format_error(result)
        end
      end

      def format_success(result)
        summary = result[:summary] || {}
        
        output = <<~MSG
          SUCCESS: State commit created

          Commit Details:
            Hash: #{result[:snapshot_hash]}
            Block: ##{result[:block_index]}
            Type: #{result[:commit_type]}
            Reason: #{result[:reason]}
            Timestamp: #{result[:timestamp]}

          Changes Summary:
        MSG

        if summary[:L0_changed]
          output += "    L0: changed\n"
        end

        if summary[:L1_added].to_i > 0 || summary[:L1_modified].to_i > 0 || summary[:L1_deleted].to_i > 0
          l1_parts = []
          l1_parts << "+#{summary[:L1_added]}" if summary[:L1_added].to_i > 0
          l1_parts << "~#{summary[:L1_modified]}" if summary[:L1_modified].to_i > 0
          l1_parts << "-#{summary[:L1_deleted]}" if summary[:L1_deleted].to_i > 0
          output += "    L1: #{l1_parts.join(', ')}\n"
        end

        if summary[:L2_sessions_added].to_i > 0 || summary[:L2_sessions_deleted].to_i > 0
          l2_parts = []
          l2_parts << "+#{summary[:L2_sessions_added]} sessions" if summary[:L2_sessions_added].to_i > 0
          l2_parts << "-#{summary[:L2_sessions_deleted]} sessions" if summary[:L2_sessions_deleted].to_i > 0
          output += "    L2: #{l2_parts.join(', ')}\n"
        end

        if summary[:promotions].to_i > 0
          output += "    Promotions: #{summary[:promotions]}\n"
        end

        if summary[:demotions].to_i > 0
          output += "    Demotions: #{summary[:demotions]}\n"
        end

        output += "\n  Snapshot: #{result[:snapshot_ref]}"

        text_content(output)
      end

      def format_error(result)
        output = "FAILED: #{result[:error]}"
        
        if result[:last_commit_hash]
          output += "\n\nLast commit hash: #{result[:last_commit_hash]}"
          output += "\nUse force=true to commit anyway."
        end

        text_content(output)
      end
    end
  end
end
