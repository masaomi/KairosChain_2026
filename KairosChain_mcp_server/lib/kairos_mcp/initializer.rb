# frozen_string_literal: true

require 'fileutils'
require_relative '../kairos_mcp'

module KairosMcp
  # Initializer: Sets up the data directory with default templates
  #
  # Creates the following structure:
  #   <data_dir>/
  #   ├── skills/
  #   │   ├── kairos.rb        # L0 meta-skills (Ruby DSL)
  #   │   ├── kairos.md        # L0 philosophy (Markdown)
  #   │   ├── config.yml       # Configuration
  #   │   └── versions/        # Version snapshots
  #   ├── knowledge/           # L1 knowledge layer
  #   ├── context/             # L2 context layer
  #   ├── config/
  #   │   ├── safety.yml       # Safety constraints
  #   │   └── tool_metadata.yml # Tool metadata
  #   └── storage/
  #       ├── embeddings/      # Vector search indices
  #       │   ├── skills/
  #       │   └── knowledge/
  #       ├── snapshots/       # State commit snapshots
  #       └── export/          # SQLite export directory
  #
  class Initializer
    # Run the initialization
    #
    # @param quiet [Boolean] Suppress output (for auto-init)
    def self.run(quiet: false)
      new(quiet: quiet).run
    end

    def initialize(quiet: false)
      @quiet = quiet
      @data_dir = KairosMcp.data_dir
      @templates_dir = KairosMcp.templates_dir
    end

    def run
      log "Initializing KairosChain data directory..."
      log "  Target: #{@data_dir}"
      log ""

      create_directories
      copy_templates
      
      log ""
      log "KairosChain data directory initialized successfully!"
      log ""
      log "Data directory: #{@data_dir}"
      log ""
      log "To start the MCP server:"
      log "  kairos_mcp_server                    # stdio mode (for Cursor)"
      log "  kairos_mcp_server --http             # HTTP mode (for remote)"
      log ""
      log "To configure in Cursor (mcp.json):"
      log "  {"
      log "    \"mcpServers\": {"
      log "      \"kairos\": {"
      log "        \"command\": \"kairos_mcp_server\","
      log "        \"args\": [\"--data-dir\", \"#{@data_dir}\"]"
      log "      }"
      log "    }"
      log "  }"
    end

    private

    def create_directories
      dirs = [
        KairosMcp.skills_dir,
        KairosMcp.versions_dir,
        KairosMcp.knowledge_dir,
        KairosMcp.context_dir,
        KairosMcp.config_dir,
        KairosMcp.storage_dir,
        KairosMcp.embeddings_dir,
        KairosMcp.skills_index_path,
        KairosMcp.knowledge_index_path,
        KairosMcp.snapshots_dir,
        KairosMcp.export_dir
      ]

      dirs.each do |dir|
        FileUtils.mkdir_p(dir)
        log "  Created: #{relative_path(dir)}/"
      end
    end

    def copy_templates
      template_files = [
        ['skills/kairos.rb',        KairosMcp.dsl_path],
        ['skills/kairos.md',        KairosMcp.md_path],
        ['skills/config.yml',       KairosMcp.skills_config_path],
        ['config/safety.yml',       KairosMcp.safety_config_path],
        ['config/tool_metadata.yml', KairosMcp.tool_metadata_path]
      ]

      template_files.each do |template_name, dest_path|
        template_path = File.join(@templates_dir, template_name)

        if File.exist?(dest_path)
          log "  Exists:  #{relative_path(dest_path)} (skipped)"
        elsif File.exist?(template_path)
          FileUtils.cp(template_path, dest_path)
          log "  Created: #{relative_path(dest_path)}"
        else
          log "  Warning: Template not found: #{template_name}"
        end
      end
    end

    def relative_path(path)
      path.sub("#{@data_dir}/", '')
    end

    def log(message)
      $stderr.puts message unless @quiet
    end
  end
end
