# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../state_commit/commit_service'

module KairosMcp
  module Tools
    # StateStatus: MCP tool to check current state commit status
    #
    # Shows last commit, pending changes, and auto-commit trigger status.
    #
    class StateStatus < BaseTool
      def name
        'state_status'
      end

      def description
        'Get current state commit status including last commit, pending changes, and auto-commit triggers.'
      end

      def input_schema
        {
          type: 'object',
          properties: {}
        }
      end

      def call(_arguments)
        service = KairosMcp::StateCommit::CommitService.new
        status = service.status

        format_status(status)
      end

      private

      def format_status(status)
        output = "State Commit Status\n"
        output += "=" * 50 + "\n\n"

        # Enabled status
        output += "Enabled: #{status[:enabled] ? 'Yes' : 'No'}\n\n"

        # Last commit info
        output += "Last Commit:\n"
        if status[:last_commit]
          lc = status[:last_commit]
          output += "  Hash: #{lc[:hash]}\n"
          output += "  Time: #{lc[:timestamp]}\n"
          output += "  Type: #{lc[:commit_type]}\n"
          output += "  Reason: #{lc[:reason]}\n"
        else
          output += "  (No commits yet)\n"
        end
        output += "\n"

        # Current state
        output += "Current State:\n"
        output += "  Hash: #{status[:current_hash]}\n"
        output += "  Has Changes: #{status[:has_changes] ? 'Yes' : 'No'}\n"
        output += "\n"

        # Pending changes
        output += "Pending Changes:\n"
        pending = status[:pending_changes]
        if pending[:total] > 0
          output += "  Total: #{pending[:total]}\n"
          output += "  By Layer:\n"
          output += "    L0: #{pending.dig(:by_layer, :L0) || 0}\n"
          output += "    L1: #{pending.dig(:by_layer, :L1) || 0}\n"
          output += "    L2: #{pending.dig(:by_layer, :L2) || 0}\n"
          output += "  By Action:\n"
          pending[:by_action].each do |action, count|
            output += "    #{action}: #{count}\n" if count > 0
          end
        else
          output += "  (No pending changes)\n"
        end
        output += "\n"

        # Auto-commit status
        output += "Auto-Commit:\n"
        auto = status[:auto_commit]
        output += "  Enabled: #{auto[:enabled] ? 'Yes' : 'No'}\n"
        output += "  Trigger Met: #{auto[:trigger_met] ? 'Yes' : 'No'}"
        output += " (#{auto[:trigger]})" if auto[:trigger]
        output += "\n"
        output += "  Thresholds:\n"
        output += "    L1 changes: #{pending.dig(:by_layer, :L1) || 0}/#{auto.dig(:thresholds, :l1_changes)}\n"
        output += "    Total changes: #{pending[:total]}/#{auto.dig(:thresholds, :total_changes)}\n"
        output += "\n"

        # Snapshot count
        output += "Snapshots: #{status[:snapshot_count]} stored\n"

        text_content(output)
      end
    end
  end
end
