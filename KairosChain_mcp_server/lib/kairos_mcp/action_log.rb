# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

module KairosMcp
  # ActionLog: Records actions for audit trail
  #
  # This class has been refactored to use the Storage backend abstraction.
  # By default, it uses FileBackend (file-based storage).
  # When SQLite is enabled, it uses SqliteBackend.
  #
  class ActionLog
    LOG_PATH = File.expand_path('../../skills/action_log.jsonl', __dir__)

    class << self
      # Record an action to the log
      #
      # @param action [String] The action performed
      # @param skill_id [String, nil] The skill ID involved
      # @param details [Hash, nil] Additional details
      # @return [Boolean] Success status
      def record(action:, skill_id: nil, details: nil)
        entry = {
          timestamp: Time.now.iso8601,
          action: action,
          skill_id: skill_id,
          details: details
        }

        storage_backend.record_action(entry)
      end

      # Get action history
      #
      # @param limit [Integer] Maximum number of entries to return
      # @return [Array<Hash>] Recent action log entries
      def history(limit: 50)
        storage_backend.action_history(limit: limit)
      end

      # Clear all action logs
      #
      # @return [Boolean] Success status
      def clear!
        storage_backend.clear_action_log!
      end

      # Get the storage backend type
      # @return [Symbol] :file or :sqlite
      def storage_type
        storage_backend.backend_type
      end

      # Reset the storage backend (useful for testing)
      def reset_backend!
        @storage_backend = nil
      end

      # Set a custom storage backend (useful for testing or dependency injection)
      # @param backend [Storage::Backend] The backend to use
      def storage_backend=(backend)
        @storage_backend = backend
      end

      private

      def storage_backend
        @storage_backend ||= default_storage_backend
      end

      def default_storage_backend
        require_relative 'storage/backend'
        Storage::Backend.default
      end
    end
  end
end
