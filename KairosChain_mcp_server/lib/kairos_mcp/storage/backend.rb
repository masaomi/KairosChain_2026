# frozen_string_literal: true

module KairosMcp
  module Storage
    # Abstract base class for storage backends
    #
    # KairosChain supports three storage backends:
    # - FileBackend (default): File-based storage for individual use
    # - SqliteBackend (optional): SQLite-based storage for team use
    # - PostgresqlBackend (optional): PostgreSQL-based storage for multi-tenant apps
    #
    # The backend is selected via config.yml:
    #   storage:
    #     backend: file  # or 'sqlite' or 'postgresql'
    #
    class Backend
      # ===========================================================================
      # Block Operations (Blockchain)
      # ===========================================================================

      # Load all blocks from storage
      # @return [Array<Hash>, nil] Array of block data or nil if not found
      def load_blocks
        raise NotImplementedError, "#{self.class}#load_blocks must be implemented"
      end

      # Save a single block to storage
      # @param block [Hash] Block data to save
      # @return [Boolean] Success status
      def save_block(block)
        raise NotImplementedError, "#{self.class}#save_block must be implemented"
      end

      # Save all blocks to storage (for file backend bulk write)
      # @param blocks [Array<Hash>] Array of block data
      # @return [Boolean] Success status
      def save_all_blocks(blocks)
        raise NotImplementedError, "#{self.class}#save_all_blocks must be implemented"
      end

      # Get all blocks
      # @return [Array<Hash>] All blocks
      def all_blocks
        raise NotImplementedError, "#{self.class}#all_blocks must be implemented"
      end

      # ===========================================================================
      # Action Log Operations
      # ===========================================================================

      # Record an action to the log
      # @param entry [Hash] Log entry with :timestamp, :action, :skill_id, :details
      # @return [Boolean] Success status
      def record_action(entry)
        raise NotImplementedError, "#{self.class}#record_action must be implemented"
      end

      # Get action history
      # @param limit [Integer] Maximum number of entries to return
      # @return [Array<Hash>] Recent action log entries
      def action_history(limit: 50)
        raise NotImplementedError, "#{self.class}#action_history must be implemented"
      end

      # Clear all action logs
      # @return [Boolean] Success status
      def clear_action_log!
        raise NotImplementedError, "#{self.class}#clear_action_log! must be implemented"
      end

      # ===========================================================================
      # Knowledge Meta Operations
      # ===========================================================================
      # Note: Knowledge content (*.md files) is always stored in files.
      # SQLite only stores metadata for faster queries.

      # Save knowledge metadata
      # @param name [String] Knowledge name
      # @param meta [Hash] Metadata (content_hash, version, description, tags, etc.)
      # @return [Boolean] Success status
      def save_knowledge_meta(name, meta)
        raise NotImplementedError, "#{self.class}#save_knowledge_meta must be implemented"
      end

      # Get knowledge metadata
      # @param name [String] Knowledge name
      # @return [Hash, nil] Metadata or nil if not found
      def get_knowledge_meta(name)
        raise NotImplementedError, "#{self.class}#get_knowledge_meta must be implemented"
      end

      # List all knowledge metadata
      # @return [Array<Hash>] Array of metadata for all knowledge entries
      def list_knowledge_meta
        raise NotImplementedError, "#{self.class}#list_knowledge_meta must be implemented"
      end

      # Delete knowledge metadata
      # @param name [String] Knowledge name
      # @return [Boolean] Success status
      def delete_knowledge_meta(name)
        raise NotImplementedError, "#{self.class}#delete_knowledge_meta must be implemented"
      end

      # Update knowledge archived status
      # @param name [String] Knowledge name
      # @param archived [Boolean] Archived status
      # @param reason [String, nil] Archive reason
      # @return [Boolean] Success status
      def update_knowledge_archived(name, archived, reason: nil)
        raise NotImplementedError, "#{self.class}#update_knowledge_archived must be implemented"
      end

      # ===========================================================================
      # Utility Methods
      # ===========================================================================

      # Check if the backend is ready
      # @return [Boolean] True if backend is initialized and ready
      def ready?
        raise NotImplementedError, "#{self.class}#ready? must be implemented"
      end

      # Get backend type
      # @return [Symbol] :file, :sqlite, or :postgresql
      def backend_type
        raise NotImplementedError, "#{self.class}#backend_type must be implemented"
      end

      # ===========================================================================
      # Factory Method
      # ===========================================================================

      # Create a storage backend based on configuration
      # @param config [Hash] Configuration hash with :backend key
      # @return [Backend] A FileBackend, SqliteBackend, or PostgresqlBackend instance
      def self.create(config = {})
        backend = config[:backend]&.to_s || 'file'

        case backend
        when 'postgresql'
          begin
            require_relative 'postgresql_backend'
            PostgresqlBackend.new(config[:postgresql] || {})
          rescue LoadError => e
            warn "[KairosChain] PostgreSQL backend requested but pg gem not available: #{e.message}"
            warn "[KairosChain] Falling back to file backend"
            require_relative 'file_backend'
            FileBackend.new(config[:file] || {})
          end
        when 'sqlite'
          begin
            require_relative 'sqlite_backend'
            SqliteBackend.new(config[:sqlite] || {})
          rescue LoadError => e
            warn "[KairosChain] SQLite backend requested but sqlite3 gem not available: #{e.message}"
            warn "[KairosChain] Falling back to file backend"
            require_relative 'file_backend'
            FileBackend.new(config[:file] || {})
          end
        else
          require_relative 'file_backend'
          FileBackend.new(config[:file] || {})
        end
      end

      # Get the default storage configuration from config.yml
      # @return [Hash] Storage configuration
      def self.load_config
        require_relative '../../kairos_mcp'
        config_path = KairosMcp.skills_config_path
        return {} unless File.exist?(config_path)

        require 'yaml'
        config = YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
        config['storage'] || {}
      rescue StandardError => e
        warn "[KairosChain] Failed to load storage config: #{e.message}"
        {}
      end

      # Create a backend using the default configuration
      # @return [Backend] A FileBackend or SqliteBackend instance
      def self.default
        config = load_config
        create(config.transform_keys(&:to_sym))
      end
    end
  end
end
