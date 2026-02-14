# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../skills_config'
require 'fileutils'
require 'time'

module KairosMcp
  module Tools
    class ChainImport < BaseTool
      def name
        'chain_import'
      end

      def description
        'Import data from files to SQLite database. WARNING: This will overwrite existing data. Requires approved=true and creates automatic backup before import.'
      end

      def category
        :chain
      end

      def usecase_tags
        %w[import restore sqlite migrate blockchain]
      end

      def examples
        [
          {
            title: 'Import from files',
            code: 'chain_import(source: "files", approved: true)'
          },
          {
            title: 'Import from export directory',
            code: 'chain_import(source: "export", input_dir: "/path/to/export", approved: true)'
          }
        ]
      end

      def related_tools
        %w[chain_export chain_status]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            source: {
              type: 'string',
              enum: ['files', 'export'],
              description: "'files' = rebuild from original file storage (blockchain.json, action_log.jsonl, knowledge/). 'export' = import from exported directory."
            },
            input_dir: {
              type: 'string',
              description: "For source='export': directory containing exported files. Defaults to storage/export/"
            },
            approved: {
              type: 'boolean',
              description: 'REQUIRED: Must be true to proceed. This confirms you understand data will be overwritten.'
            },
            skip_backup: {
              type: 'boolean',
              description: 'Skip automatic backup before import. NOT RECOMMENDED. Default: false'
            }
          },
          required: ['source', 'approved']
        }
      end

      def call(arguments)
        source = arguments['source']
        approved = arguments['approved']
        skip_backup = arguments['skip_backup'] || false
        input_dir = arguments['input_dir']

        # Validate source
        unless %w[files export].include?(source)
          return text_content("Error: source must be 'files' or 'export'")
        end

        # Check if SQLite backend is enabled
        unless SkillsConfig.storage_backend_sqlite?
          return text_content("Error: chain_import only works with SQLite backend. Current backend: #{SkillsConfig.storage_backend}")
        end

        sqlite_config = SkillsConfig.sqlite_config
        db_path = File.expand_path(sqlite_config['path'] || 'storage/kairos.db', base_dir)

        # Preview mode if not approved
        unless approved
          return preview_import(source, db_path, input_dir)
        end

        require_relative '../storage/importer'

        # Create backup before import (unless skipped)
        backup_path = nil
        if File.exist?(db_path) && !skip_backup
          backup_path = create_backup(db_path)
        end

        # Perform import based on source
        result = case source
                 when 'files'
                   Storage::Importer.rebuild_from_files(db_path: db_path)
                 when 'export'
                   export_dir = input_dir || File.expand_path('storage/export', base_dir)
                   Storage::Importer.import(input_dir: export_dir, db_path: db_path)
                 end

        if result[:error]
          return text_content("Import failed: #{result[:error]}\n\nBackup available at: #{backup_path}")
        end

        output = <<~OUTPUT
          Import completed successfully!

          Source: #{source}
          Database: #{db_path}
          #{backup_path ? "Backup created: #{backup_path}" : "No backup (database was new or skip_backup=true)"}

          Imported:
          - Blocks: #{result[:blocks]}
          - Action logs: #{result[:action_logs]}
          - Knowledge metadata: #{result[:knowledge_meta]}

          NOTE: Restart the MCP server to use the imported data.
        OUTPUT

        text_content(output)
      end

      private

      def base_dir
        KairosMcp.data_dir
      end

      def preview_import(source, db_path, input_dir)
        # Check what will be affected
        existing_info = get_existing_info(db_path)
        source_info = get_source_info(source, input_dir)

        output = <<~OUTPUT
          === Import Preview (DRY RUN) ===

          Source: #{source}
          Target database: #{db_path}

          Current database contains:
          #{existing_info}

          Data to be imported:
          #{source_info}

          ⚠️  WARNING: Import will OVERWRITE all existing data!

          To proceed, call again with approved=true:
            chain_import source="#{source}" approved=true

          A backup will be automatically created before import.
        OUTPUT

        text_content(output)
      end

      def get_existing_info(db_path)
        return "  (database does not exist - will be created)" unless File.exist?(db_path)

        begin
          require 'sqlite3'
          db = SQLite3::Database.new(db_path)

          blocks = db.get_first_value("SELECT COUNT(*) FROM blocks") || 0
          action_logs = db.get_first_value("SELECT COUNT(*) FROM action_logs") || 0
          knowledge = db.get_first_value("SELECT COUNT(*) FROM knowledge_meta") || 0

          "  - Blocks: #{blocks}\n  - Action logs: #{action_logs}\n  - Knowledge metadata: #{knowledge}"
        rescue StandardError => e
          "  (unable to read database: #{e.message})"
        end
      end

      def get_source_info(source, input_dir)
        case source
        when 'files'
          get_files_source_info
        when 'export'
          get_export_source_info(input_dir)
        end
      end

      def get_files_source_info
        info = []

        # Check blockchain.json
        blockchain_file = File.expand_path('storage/blockchain.json', base_dir)
        if File.exist?(blockchain_file)
          blocks = JSON.parse(File.read(blockchain_file)).size rescue '?'
          info << "  - Blocks: #{blocks} (from storage/blockchain.json)"
        else
          info << "  - Blocks: 0 (storage/blockchain.json not found)"
        end

        # Check action_log.jsonl
        action_log_file = File.expand_path('skills/action_log.jsonl', base_dir)
        if File.exist?(action_log_file)
          logs = File.readlines(action_log_file).size rescue '?'
          info << "  - Action logs: #{logs} (from skills/action_log.jsonl)"
        else
          info << "  - Action logs: 0 (skills/action_log.jsonl not found)"
        end

        # Check knowledge directory
        knowledge_dir = File.expand_path('knowledge', base_dir)
        if File.directory?(knowledge_dir)
          count = Dir[File.join(knowledge_dir, '*')].select { |d| File.directory?(d) && !d.end_with?('.archived') }.size
          info << "  - Knowledge: #{count} directories (from knowledge/)"
        else
          info << "  - Knowledge: 0 (knowledge/ not found)"
        end

        info.join("\n")
      end

      def get_export_source_info(input_dir)
        export_dir = input_dir || File.expand_path('storage/export', base_dir)

        unless File.directory?(export_dir)
          return "  (export directory not found: #{export_dir})"
        end

        info = []

        # Check manifest
        manifest_file = File.join(export_dir, 'manifest.json')
        if File.exist?(manifest_file)
          manifest = JSON.parse(File.read(manifest_file)) rescue {}
          counts = manifest['counts'] || {}
          info << "  - Blocks: #{counts['blocks'] || '?'}"
          info << "  - Action logs: #{counts['action_logs'] || '?'}"
          info << "  - Knowledge metadata: #{counts['knowledge_meta'] || '?'}"
          info << "  (from #{export_dir})"
        else
          info << "  (manifest.json not found in #{export_dir})"
        end

        info.join("\n")
      end

      def create_backup(db_path)
        timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
        backup_dir = File.join(File.dirname(db_path), 'backups')
        FileUtils.mkdir_p(backup_dir)

        backup_path = File.join(backup_dir, "kairos_#{timestamp}.db")
        FileUtils.cp(db_path, backup_path)

        # Also backup WAL file if exists
        wal_file = "#{db_path}-wal"
        if File.exist?(wal_file)
          FileUtils.cp(wal_file, "#{backup_path}-wal")
        end

        backup_path
      end
    end
  end
end
