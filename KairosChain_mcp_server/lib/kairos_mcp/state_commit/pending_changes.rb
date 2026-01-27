# frozen_string_literal: true

require 'time'

module KairosMcp
  module StateCommit
    # PendingChanges: Tracks changes since last commit
    #
    # This is a singleton-like class that accumulates changes
    # and checks auto-commit trigger conditions.
    #
    class PendingChanges
      @changes = []
      @mutex = Mutex.new

      class << self
        # Add a change to the pending list
        #
        # @param layer [String] Layer identifier (L0, L1, L2)
        # @param action [String] Action type (create, update, delete, promote, demote, archive, unarchive)
        # @param skill_id [String] Skill/knowledge identifier
        # @param reason [String, nil] Optional reason for the change
        # @param metadata [Hash] Additional metadata
        def add(layer:, action:, skill_id:, reason: nil, metadata: {})
          @mutex.synchronize do
            @changes << {
              layer: layer.to_s,
              action: action.to_s,
              skill_id: skill_id.to_s,
              reason: reason,
              metadata: metadata,
              timestamp: Time.now.iso8601
            }
          end
        end

        # Get all pending changes
        #
        # @return [Array<Hash>] List of pending changes
        def all
          @mutex.synchronize { @changes.dup }
        end

        # Get pending changes count
        #
        # @return [Integer] Number of pending changes
        def count
          @mutex.synchronize { @changes.size }
        end

        # Clear all pending changes
        def clear!
          @mutex.synchronize { @changes = [] }
        end

        # Check if there are any L0 changes
        #
        # @return [Boolean] True if L0 changes exist
        def includes_l0_change?
          @mutex.synchronize do
            @changes.any? { |c| c[:layer] == 'L0' }
          end
        end

        # Check if there are any promotions
        #
        # @return [Boolean] True if promotions exist
        def includes_promotion?
          @mutex.synchronize do
            @changes.any? { |c| c[:action] == 'promote' }
          end
        end

        # Check if there are any demotions
        #
        # @return [Boolean] True if demotions exist
        def includes_demotion?
          @mutex.synchronize do
            @changes.any? { |c| c[:action] == 'demote' || c[:action] == 'archive' }
          end
        end

        # Get L1 changes count
        #
        # @return [Integer] Number of L1 changes
        def l1_changes_count
          @mutex.synchronize do
            @changes.count { |c| c[:layer] == 'L1' }
          end
        end

        # Get L2 changes count
        #
        # @return [Integer] Number of L2 changes
        def l2_changes_count
          @mutex.synchronize do
            @changes.count { |c| c[:layer] == 'L2' }
          end
        end

        # Get total changes count
        #
        # @return [Integer] Total number of changes
        def total_changes_count
          count
        end

        # Get changes grouped by layer
        #
        # @return [Hash] Changes grouped by layer
        def by_layer
          @mutex.synchronize do
            @changes.group_by { |c| c[:layer] }
          end
        end

        # Get changes grouped by action
        #
        # @return [Hash] Changes grouped by action
        def by_action
          @mutex.synchronize do
            @changes.group_by { |c| c[:action] }
          end
        end

        # Get summary of pending changes
        #
        # @return [Hash] Summary with counts per layer and action
        def summary
          @mutex.synchronize do
            {
              total: @changes.size,
              by_layer: {
                L0: @changes.count { |c| c[:layer] == 'L0' },
                L1: @changes.count { |c| c[:layer] == 'L1' },
                L2: @changes.count { |c| c[:layer] == 'L2' }
              },
              by_action: {
                create: @changes.count { |c| c[:action] == 'create' },
                update: @changes.count { |c| c[:action] == 'update' },
                delete: @changes.count { |c| c[:action] == 'delete' },
                promote: @changes.count { |c| c[:action] == 'promote' },
                demote: @changes.count { |c| c[:action] == 'demote' },
                archive: @changes.count { |c| c[:action] == 'archive' },
                unarchive: @changes.count { |c| c[:action] == 'unarchive' }
              },
              has_l0_change: includes_l0_change?,
              has_promotion: includes_promotion?,
              has_demotion: includes_demotion?
            }
          end
        end

        # Check trigger conditions for auto-commit
        #
        # @param config [Hash] Auto-commit configuration
        # @return [Hash] Result with should_commit flag and trigger reason
        def check_trigger_conditions(config)
          return { should_commit: false, trigger: nil } unless config

          # Check event-based triggers
          if config.dig('on_events', 'l0_change') && includes_l0_change?
            return { should_commit: true, trigger: 'l0_change' }
          end

          if config.dig('on_events', 'promotion') && includes_promotion?
            return { should_commit: true, trigger: 'promotion' }
          end

          if config.dig('on_events', 'demotion') && includes_demotion?
            return { should_commit: true, trigger: 'demotion' }
          end

          # Check threshold-based triggers
          if config.dig('change_threshold', 'enabled')
            l1_threshold = config.dig('change_threshold', 'l1_changes') || 5
            if l1_changes_count >= l1_threshold
              return { should_commit: true, trigger: 'l1_threshold' }
            end

            total_threshold = config.dig('change_threshold', 'total_changes') || 10
            if total_changes_count >= total_threshold
              return { should_commit: true, trigger: 'total_threshold' }
            end
          end

          { should_commit: false, trigger: nil }
        end

        # Reset the changes (alias for clear!)
        def reset!
          clear!
        end
      end
    end
  end
end
