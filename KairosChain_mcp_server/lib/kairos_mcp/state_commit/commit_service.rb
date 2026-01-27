# frozen_string_literal: true

require_relative 'manifest_builder'
require_relative 'snapshot_manager'
require_relative 'diff_calculator'
require_relative 'pending_changes'

module KairosMcp
  module StateCommit
    # CommitService: Orchestrates the state commit process
    #
    # Responsibilities:
    # - Execute explicit and auto commits
    # - Check auto-commit conditions
    # - Record commits to blockchain
    #
    class CommitService
      def initialize(config: nil)
        @config = config || load_config
        @manifest_builder = ManifestBuilder.new
        @snapshot_manager = SnapshotManager.new(
          snapshot_dir: @config.dig('state_commit', 'snapshot_dir'),
          max_snapshots: @config.dig('state_commit', 'max_snapshots')
        )
        @diff_calculator = DiffCalculator.new
      end

      # Execute an explicit commit (user-initiated)
      #
      # @param reason [String] Reason for the commit (required)
      # @param actor [String] Who is committing (human/ai)
      # @param force [Boolean] Force commit even if no changes
      # @return [Hash] Result with success status and commit info
      def explicit_commit(reason:, actor: 'human', force: false)
        return { success: false, error: "Reason is required for explicit commit" } if reason.nil? || reason.empty?

        perform_commit(
          reason: reason,
          commit_type: 'explicit',
          actor: actor,
          force: force
        )
      end

      # Execute an auto commit (system-initiated)
      #
      # @param trigger [String] What triggered the auto-commit
      # @return [Hash] Result with success status and commit info
      def auto_commit(trigger:)
        # Generate auto-commit reason
        summary = PendingChanges.summary
        reason = generate_auto_reason(trigger, summary)

        perform_commit(
          reason: reason,
          commit_type: 'auto',
          actor: 'system',
          force: false
        )
      end

      # Check if auto-commit should be triggered
      #
      # @return [Hash] Result with should_commit flag and trigger
      def should_auto_commit?
        return { should_commit: false, reason: "State commit disabled" } unless enabled?

        auto_config = @config.dig('state_commit', 'auto_commit')
        return { should_commit: false, reason: "Auto-commit disabled" } unless auto_config&.dig('enabled')

        # Check trigger conditions (OR)
        trigger_result = PendingChanges.check_trigger_conditions(auto_config)
        return { should_commit: false, reason: "No trigger conditions met" } unless trigger_result[:should_commit]

        # Check hash comparison (AND condition)
        if auto_config.dig('skip_if_no_changes') != false
          current_manifest = @manifest_builder.build_full_manifest
          last_snapshot = @snapshot_manager.get_last_snapshot

          if last_snapshot && !@diff_calculator.has_changes?(last_snapshot, current_manifest)
            return { should_commit: false, reason: "No actual changes detected" }
          end
        end

        { should_commit: true, trigger: trigger_result[:trigger] }
      end

      # Check auto-commit and execute if needed
      #
      # @return [Hash, nil] Commit result if committed, nil otherwise
      def check_and_auto_commit
        result = should_auto_commit?
        return nil unless result[:should_commit]

        auto_commit(trigger: result[:trigger])
      end

      # Get current status
      #
      # @return [Hash] Current state commit status
      def status
        last_snapshot = @snapshot_manager.get_last_snapshot
        current_manifest = @manifest_builder.build_full_manifest
        pending_summary = PendingChanges.summary
        auto_config = @config.dig('state_commit', 'auto_commit') || {}

        has_changes = if last_snapshot
                        @diff_calculator.has_changes?(last_snapshot, current_manifest)
                      else
                        true
                      end

        trigger_result = PendingChanges.check_trigger_conditions(auto_config)

        {
          enabled: enabled?,
          last_commit: last_snapshot ? {
            hash: last_snapshot['snapshot_hash'],
            timestamp: last_snapshot['created_at'],
            reason: last_snapshot['reason'],
            commit_type: last_snapshot['commit_type']
          } : nil,
          current_hash: current_manifest[:combined_hash],
          has_changes: has_changes,
          pending_changes: pending_summary,
          auto_commit: {
            enabled: auto_config.dig('enabled') || false,
            trigger_met: trigger_result[:should_commit],
            trigger: trigger_result[:trigger],
            thresholds: {
              l1_changes: auto_config.dig('change_threshold', 'l1_changes') || 5,
              total_changes: auto_config.dig('change_threshold', 'total_changes') || 10
            }
          },
          snapshot_count: @snapshot_manager.count
        }
      end

      # Get commit history
      #
      # @param limit [Integer] Maximum number of commits to return
      # @return [Array<Hash>] List of commit metadata
      def history(limit: 20)
        @snapshot_manager.list_snapshots(limit: limit)
      end

      # Check if state commit is enabled
      #
      # @return [Boolean] True if enabled
      def enabled?
        @config.dig('state_commit', 'enabled') != false
      end

      private

      def perform_commit(reason:, commit_type:, actor:, force: false)
        return { success: false, error: "State commit is disabled" } unless enabled?

        # Build current manifest
        current_manifest = @manifest_builder.build_full_manifest

        # Get last snapshot for comparison
        last_snapshot = @snapshot_manager.get_last_snapshot

        # Check if there are actual changes (unless forced)
        unless force
          if last_snapshot && !@diff_calculator.has_changes?(last_snapshot, current_manifest)
            return { 
              success: false, 
              error: "No changes since last commit. Use force=true to commit anyway.",
              last_commit_hash: last_snapshot['snapshot_hash']
            }
          end
        end

        # Calculate diff
        diff = @diff_calculator.calculate(last_snapshot, current_manifest)
        diff_summary = @diff_calculator.summarize(diff)

        # Get pending changes
        pending_changes = PendingChanges.all

        # Save snapshot (off-chain)
        snapshot_result = @snapshot_manager.save_snapshot(
          current_manifest,
          pending_changes,
          reason: reason,
          actor: actor,
          commit_type: commit_type
        )

        return { success: false, error: "Failed to save snapshot" } unless snapshot_result[:success]

        # Record to blockchain (on-chain)
        block_result = record_to_blockchain(
          prev_snapshot_hash: last_snapshot&.dig('snapshot_hash'),
          next_snapshot_hash: snapshot_result[:snapshot_hash],
          snapshot_ref: snapshot_result[:snapshot_ref],
          summary: diff_summary,
          reason: reason,
          commit_type: commit_type,
          actor: actor
        )

        # Clear pending changes
        PendingChanges.clear!

        {
          success: true,
          snapshot_hash: snapshot_result[:snapshot_hash],
          snapshot_ref: snapshot_result[:snapshot_ref],
          block_index: block_result[:block_index],
          commit_type: commit_type,
          reason: reason,
          summary: diff_summary,
          timestamp: snapshot_result[:timestamp]
        }
      end

      def record_to_blockchain(prev_snapshot_hash:, next_snapshot_hash:, snapshot_ref:, summary:, reason:, commit_type:, actor:)
        require_relative '../kairos_chain/chain'

        chain = KairosChain::Chain.new

        block_data = {
          type: 'state_commit',
          commit_type: commit_type,
          actor: actor,
          prev_snapshot_hash: prev_snapshot_hash,
          next_snapshot_hash: next_snapshot_hash,
          snapshot_ref: snapshot_ref,
          summary: summary,
          reason: reason,
          timestamp: Time.now.iso8601
        }

        block = chain.add_block([block_data.to_json])

        { block_index: block.index, block_hash: block.hash }
      end

      def generate_auto_reason(trigger, summary)
        parts = ["Auto-commit (#{trigger})"]

        details = []
        details << "L0 changed" if summary[:has_l0_change]
        details << "L1: #{summary.dig(:by_layer, :L1)} changes" if summary.dig(:by_layer, :L1).to_i > 0
        details << "L2: #{summary.dig(:by_layer, :L2)} changes" if summary.dig(:by_layer, :L2).to_i > 0
        details << "promotions: #{summary.dig(:by_action, :promote)}" if summary.dig(:by_action, :promote).to_i > 0

        parts << details.join(", ") if details.any?

        parts.join(": ")
      end

      def load_config
        require_relative '../skills_config'
        SkillsConfig.load
      rescue StandardError
        {}
      end
    end
  end
end
