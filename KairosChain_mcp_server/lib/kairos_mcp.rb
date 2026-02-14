# frozen_string_literal: true

require_relative 'kairos_mcp/version'

module KairosMcp
  # =========================================================================
  # Data Directory Management
  # =========================================================================
  #
  # KairosChain stores runtime data (skills, knowledge, context, storage)
  # separately from the gem's library code. The data directory is resolved
  # using the following priority:
  #
  #   1. Explicitly set via KairosMcp.data_dir = "/path/to/data"
  #   2. Environment variable KAIROS_DATA_DIR
  #   3. Default: .kairos/ in the current working directory
  #
  # Use `kairos_mcp_server init` to generate the initial data directory
  # with default templates.
  #
  class << self
    # Get the root data directory for all runtime data
    #
    # @return [String] Absolute path to the data directory
    def data_dir
      @data_dir ||= resolve_data_dir
    end

    # Set the root data directory explicitly
    #
    # @param path [String] Absolute or relative path
    def data_dir=(path)
      @data_dir = File.expand_path(path)
      @path_cache = {}
    end

    # Reset data_dir (for testing or re-initialization)
    def reset_data_dir!
      @data_dir = nil
      @path_cache = {}
    end

    # =========================================================================
    # Path accessors for each data subdirectory
    # =========================================================================

    # L0 skills directory (kairos.rb, kairos.md, config.yml, versions/)
    def skills_dir
      path_for('skills')
    end

    # L0 skills DSL file path
    def dsl_path
      File.join(skills_dir, 'kairos.rb')
    end

    # L0 skills philosophy file path
    def md_path
      File.join(skills_dir, 'kairos.md')
    end

    # L0 skills config file path
    def skills_config_path
      File.join(skills_dir, 'config.yml')
    end

    # L0 skills versions directory
    def versions_dir
      File.join(skills_dir, 'versions')
    end

    # L0 action log file path
    def action_log_path
      File.join(skills_dir, 'action_log.jsonl')
    end

    # L1 knowledge directory
    def knowledge_dir
      path_for('knowledge')
    end

    # L2 context directory
    def context_dir
      path_for('context')
    end

    # Storage directory (blockchain, embeddings, snapshots, tokens, etc.)
    def storage_dir
      path_for('storage')
    end

    # Blockchain file path (for file backend)
    def blockchain_path
      File.join(storage_dir, 'blockchain.json')
    end

    # SQLite database path
    def sqlite_path
      File.join(storage_dir, 'kairos.db')
    end

    # Token store file path
    def token_store_path
      File.join(storage_dir, 'tokens.json')
    end

    # Embeddings directory (for vector search)
    def embeddings_dir
      File.join(storage_dir, 'embeddings')
    end

    # Skills embeddings index path
    def skills_index_path
      File.join(embeddings_dir, 'skills')
    end

    # Knowledge embeddings index path
    def knowledge_index_path
      File.join(embeddings_dir, 'knowledge')
    end

    # Snapshots directory (for state commit)
    def snapshots_dir
      File.join(storage_dir, 'snapshots')
    end

    # Export directory (for SQLite export)
    def export_dir
      File.join(storage_dir, 'export')
    end

    # Config directory (safety.yml, tool_metadata.yml)
    def config_dir
      path_for('config')
    end

    # Safety config file path
    def safety_config_path
      File.join(config_dir, 'safety.yml')
    end

    # Tool metadata file path
    def tool_metadata_path
      File.join(config_dir, 'tool_metadata.yml')
    end

    # =========================================================================
    # Template directory (shipped with the gem)
    # =========================================================================

    # Path to the bundled templates directory within the gem
    #
    # @return [String] Absolute path to templates/
    def templates_dir
      File.expand_path('../templates', __dir__)
    end

    # =========================================================================
    # Gem root directory (for library code paths)
    # =========================================================================

    # Path to the gem's root directory (one level above lib/)
    #
    # @return [String] Absolute path to gem root
    def gem_root
      File.expand_path('..', __dir__)
    end

    # Check if the data directory has been initialized
    #
    # @return [Boolean] true if essential files exist
    def initialized?
      File.exist?(dsl_path) && File.exist?(skills_config_path)
    end

    private

    def resolve_data_dir
      dir = ENV['KAIROS_DATA_DIR'] || File.join(Dir.pwd, '.kairos')
      File.expand_path(dir)
    end

    def path_for(subdir)
      @path_cache ||= {}
      @path_cache[subdir] ||= File.join(data_dir, subdir)
    end
  end
end
