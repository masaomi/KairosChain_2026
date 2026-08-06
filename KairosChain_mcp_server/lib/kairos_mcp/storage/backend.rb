# frozen_string_literal: true

module KairosMcp
  module Storage
    # Raised when a read or a write against the ledger fails, and when the key or
    # the ledger path cannot be used. It wraps the underlying exception as #cause.
    #
    # For a write, this means **it is unknown whether the write landed**. It must
    # not be read as "nothing was written" — re-read the ledger to find out.
    class Error < StandardError; end

    # Abstract base class for storage backends
    #
    # KairosChain supports two storage backends:
    # - FileBackend (default): File-based storage for individual use
    # - SqliteBackend (optional): SQLite-based storage for team use
    #
    # The backend is selected via config.yml:
    #   storage:
    #     backend: file  # or 'sqlite'
    #
    class Backend
      # ===========================================================================
      # SkillSet Extension Registry
      # ===========================================================================

      @registry = {}

      # Register a named backend class for SkillSet use (e.g. 'postgresql')
      def self.register(name, klass)
        @registry[name.to_s] = klass
      end

      # Unregister a named backend
      def self.unregister(name)
        @registry.delete(name.to_s)
      end

      # ===========================================================================
      # Block Operations (Blockchain)
      # ===========================================================================

      # Load all blocks from storage
      #
      # Read contract (a backend that declares #blockchain_file must honour it):
      # nil is returned **only when the ledger does not exist**. A ledger that
      # cannot be opened or cannot be parsed (including a zero-byte file) raises
      # Storage::Error. Collapsing those into nil would let a damaged ledger pass
      # as "absent" and be rebuilt from genesis.
      #
      # @return [Array<Hash>, nil] Array of block data, or nil when absent
      # @raise [Storage::Error] the ledger exists but could not be read
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
      #
      # Write contract: failure raises Storage::Error. Returning false for a
      # failed write is forbidden — the caller cannot distinguish "refused" from
      # "wrote and then failed", and a false return reads as a benign result.
      #
      # @param blocks [Array<Hash>] Array of block data
      # @return [Boolean] true
      # @raise [Storage::Error] the write failed or its outcome is unknown
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
      # @return [Symbol] :file or :sqlite
      def backend_type
        raise NotImplementedError, "#{self.class}#backend_type must be implemented"
      end

      # INV-G — the contract question is a single one: "state the absolute path of
      # your ledger". A backend answers it by defining #blockchain_file. This base
      # class deliberately does not, so a backend that has not been written
      # against the append procedure of INV-D (sqlite's INSERT OR REPLACE never
      # truncates the sequence; postgresql is registered by a SkillSet) is refused
      # rather than silently driven by a file-shaped procedure. Under such a
      # backend, Chain refuses to append and reads the ledger as unreadable.

      # ===========================================================================
      # Factory Method
      # ===========================================================================

      # Create a storage backend based on configuration
      # @param config [Hash] Configuration hash with :backend key
      # @return [Backend] A FileBackend or SqliteBackend instance
      def self.create(config = {})
        backend = config[:backend]&.to_s || 'file'

        # Check SkillSet-registered backends first (e.g. 'postgresql')
        if @registry.key?(backend)
          return @registry[backend].new(config[backend.to_sym] || {})
        end

        case backend
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
