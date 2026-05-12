# frozen_string_literal: true

require_relative 'kairos_mcp/version'

module KairosMcp
  # =========================================================================
  # Template Files Registry
  # =========================================================================
  #
  # Centralized mapping of template files to their data directory destinations.
  # Used by Initializer (for init) and UpgradeAnalyzer (for migration).
  #
  # Format: [template_relative_path, data_dir_accessor_symbol]
  #
  TEMPLATE_FILES = [
    ['skills/kairos.rb',              :dsl_path],
    ['skills/kairos.md',              :md_path],
    ['skills/kairos_quickguide.md',   :quickguide_path],
    ['skills/kairos_tutorial.md',     :tutorial_path],
    ['skills/researcher.md',          :researcher_path],
    ['skills/config.yml',             :skills_config_path],
    ['config/safety.yml',             :safety_config_path],
    ['config/tool_metadata.yml',      :tool_metadata_path]
  ].freeze

  # File type classification for upgrade conflict resolution
  TEMPLATE_FILE_TYPES = {
    'skills/kairos.rb'              => :l0_dsl,
    'skills/kairos.md'              => :l0_doc,
    'skills/kairos_quickguide.md'   => :l0_doc,
    'skills/kairos_tutorial.md'     => :l0_doc,
    'skills/researcher.md'          => :l0_doc,
    'skills/config.yml'             => :config_yaml,
    'config/safety.yml'             => :config_yaml,
    'config/tool_metadata.yml'      => :config_yaml
  }.freeze

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
  # Use `kairos-chain init` to generate the initial data directory
  # with default templates.
  #
  @path_resolvers = {}
  @path_resolver_mutex = Mutex.new

  class << self
    # =========================================================================
    # SkillSet Path Resolver Registry
    # =========================================================================

    # Register a named path resolver for tenant-aware directory resolution.
    # Block receives (type, user_context) and returns a path or nil.
    def register_path_resolver(name, &block)
      @path_resolver_mutex.synchronize do
        @path_resolvers[name.to_sym] = block
      end
    end

    def unregister_path_resolver(name)
      @path_resolver_mutex.synchronize do
        @path_resolvers.delete(name.to_sym)
      end
    end

    # =========================================================================
    # HttpServer reference (set when running in HTTP mode)
    # =========================================================================

    def http_server
      @http_server
    end

    def http_server=(server)
      @http_server = server
    end

    # =========================================================================

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

    # L0 skills quick guide file path (user-facing instructions)
    def quickguide_path
      File.join(skills_dir, 'kairos_quickguide.md')
    end

    # L0 skills tutorial file path (onboarding instructions)
    def tutorial_path
      File.join(skills_dir, 'kairos_tutorial.md')
    end

    # Researcher instruction mode file path
    def researcher_path
      File.join(skills_dir, 'researcher.md')
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

    # L1 knowledge directory.
    # When user_context is provided, registered path resolvers can return
    # a tenant-specific path. Without user_context, returns the global path.
    def knowledge_dir(user_context: nil)
      resolved = resolve_path(:knowledge, user_context)
      resolved || path_for('knowledge')
    end

    # L2 context directory.
    # Same tenant-aware resolution as knowledge_dir.
    def context_dir(user_context: nil)
      resolved = resolve_path(:context, user_context)
      resolved || path_for('context')
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

    # SkillSets directory (plugin-based extensions)
    def skillsets_dir
      path_for('skillsets')
    end

    # SkillSets config file (enabled/disabled state, layer overrides)
    def skillsets_config_path
      File.join(skillsets_dir, 'config.yml')
    end

    # Meta file path (.kairos_meta.yml for upgrade tracking)
    def meta_path
      File.join(data_dir, '.kairos_meta.yml')
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

    # =========================================================================
    # Plugin Projection support — consumer project root
    # =========================================================================
    #
    # Design v0.2 (log/20260512_consumer_project_root_separation_design_v0.2.md):
    # consumer_project_root is decoupled from data_dir. Resolution order:
    #   1. Explicit setter (CLI flag --project-root)
    #   2. Environment variable KAIROS_PROJECT_ROOT
    #   3. Per-transport default with plausibility check:
    #        stdio_mcp / cli_direct: Dir.pwd if plausible
    #        http_mcp: no default (returns nil; caller must refuse projection)
    #
    # See design §2 (invariants) and §6 (failure taxonomy).

    PLAUSIBILITY_MARKERS = ['CLAUDE.md', '.git', '.claude',
                            File.join('.kairos', 'projection_manifest.json')].freeze

    # Consumer project root: where projection artifacts (CLAUDE.md, .claude/) are written.
    # Distinct from data_dir (where KairosChain state lives).
    #
    # @return [String, nil] absolute real path, or nil if no plausible root is available
    def consumer_project_root
      resolve_consumer_project_root unless defined?(@consumer_project_root_resolved) && @consumer_project_root_resolved
      @consumer_project_root
    end

    # Source of the currently resolved consumer_project_root.
    # @return [Symbol] :explicit_cli, :explicit_env, :transport_default, :absent
    def consumer_project_root_source
      consumer_project_root # trigger resolution
      @consumer_project_root_source || :absent
    end

    # Explicit setter (used by CLI --project-root flag).
    # Setting to nil clears any cached resolution.
    def consumer_project_root=(path)
      if path.nil?
        @consumer_project_root = nil
        @consumer_project_root_source = :absent
      else
        @consumer_project_root = real_path(File.expand_path(path))
        @consumer_project_root_source = :explicit_cli
      end
      @consumer_project_root_resolved = true
    end

    # Reset resolution cache (for testing or re-initialization).
    def reset_consumer_project_root!
      @consumer_project_root = nil
      @consumer_project_root_source = nil
      @consumer_project_root_resolved = false
    end

    # Resolve consumer_project_root following the documented order.
    # @param transport [Symbol] :stdio_mcp, :http_mcp, :cli_direct (default: auto-detect)
    # @return [String, nil] resolved absolute real path, or nil
    def resolve_consumer_project_root(transport: nil)
      # Skip env/default lookup if explicit setter was used
      if @consumer_project_root_source == :explicit_cli && @consumer_project_root
        @consumer_project_root_resolved = true
        return @consumer_project_root
      end

      transport ||= detect_transport

      # 1. Environment variable
      if (env_val = ENV['KAIROS_PROJECT_ROOT']) && !env_val.empty?
        @consumer_project_root = real_path(File.expand_path(env_val))
        @consumer_project_root_source = :explicit_env
        @consumer_project_root_resolved = true
        return @consumer_project_root
      end

      # 2. Transport default
      if transport == :http_mcp
        # HTTP MCP: no default permitted (design §4)
        @consumer_project_root = nil
        @consumer_project_root_source = :absent
        @consumer_project_root_resolved = true
        return nil
      end

      # stdio_mcp / cli_direct: cwd default with plausibility
      candidate = real_path(Dir.pwd)
      if plausibility_check(candidate)
        @consumer_project_root = candidate
        @consumer_project_root_source = :transport_default
      else
        @consumer_project_root = nil
        @consumer_project_root_source = :absent
      end
      @consumer_project_root_resolved = true
      @consumer_project_root
    end

    # Plausibility predicate (design Inv 6 / §11).
    # Candidate passes if any recognizable project marker exists at the path.
    def plausibility_check(path)
      return false if path.nil? || path.empty?
      return false unless Dir.exist?(path)
      PLAUSIBILITY_MARKERS.any? do |marker|
        candidate = File.join(path, marker)
        File.exist?(candidate) || Dir.exist?(candidate)
      end
    end

    # Resolve a path to its real path (symlinks resolved). Falls back to expand_path
    # for non-existent paths.
    def real_path(path)
      File.realpath(File.expand_path(path))
    rescue Errno::ENOENT
      File.expand_path(path)
    end

    # Detect current transport mode based on runtime state.
    # @return [Symbol] :http_mcp or :stdio_mcp
    def detect_transport
      return :http_mcp if @http_server
      :stdio_mcp
    end

    # DEPRECATED in v0.2: parent-of-data-dir derivation.
    # Returns consumer_project_root when available, falling back to File.dirname(data_dir)
    # only for backward compatibility with internal callers that have not yet been
    # migrated. New code should use consumer_project_root and handle nil explicitly.
    def project_root
      consumer_project_root || File.dirname(data_dir)
    end

    # Determine projection mode for PluginProjector
    # :project (default) — writes to .claude/skills/, .claude/agents/, settings.json
    # :plugin — writes to plugin root skills/, agents/, hooks/hooks.json
    def projection_mode
      return :plugin if ENV['KAIROS_PROJECTION_MODE'] == 'plugin'
      root = consumer_project_root || File.dirname(data_dir)
      plugin_json = File.join(root, '.claude-plugin', 'plugin.json')
      claude_dir = File.join(root, '.claude')
      return :plugin if File.exist?(plugin_json) && !File.exist?(claude_dir)
      :project
    end

    # Collect L1 knowledge entries for plugin projection
    # Shared by protocol.rb and plugin_project tool
    def collect_knowledge_entries(user_context: nil)
      kdir = knowledge_dir(user_context: user_context)
      return [] unless Dir.exist?(kdir)
      Dir.glob(File.join(kdir, '**', '*.md')).filter_map do |f|
        fm = parse_frontmatter(f)
        next unless fm
        { name: fm['name'] || File.basename(f, '.md'),
          description: fm['description'] || '',
          version: fm['version'] || '0',
          tags: fm['tags'] || [],
          path: f }
      end
    end

    def parse_frontmatter(path)
      content = File.read(path, encoding: 'utf-8')
      return nil unless content.start_with?('---')
      parts = content.split('---', 3)
      return nil if parts.length < 3
      require 'yaml'
      YAML.safe_load(parts[1])
    rescue StandardError
      nil
    end

    private

    def resolve_path(type, user_context)
      return nil unless user_context
      resolvers = @path_resolver_mutex.synchronize { @path_resolvers.values.dup }
      return nil if resolvers.empty?
      resolvers.each do |resolver|
        result = resolver.call(type, user_context)
        return result if result
      end
      nil
    end

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
