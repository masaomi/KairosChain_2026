# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'digest'
require 'yaml'
require 'time'

module KairosMcp
  module Storage
    # Importer: Import data from files to SQLite
    #
    # This allows:
    # - Migrating from file-based storage to SQLite
    # - Rebuilding SQLite from exported files
    # - Recovering from SQLite corruption using file backups
    #
    # Import sources:
    #   - Exported files (from Exporter)
    #   - Original file-based storage (blockchain.json, action_log.jsonl)
    #   - Knowledge directory (for metadata extraction)
    #
    class Importer

      class << self
        # Import data from files to SQLite
        #
        # @param input_dir [String] Directory containing files to import
        # @param db_path [String] Path to SQLite database (will be created)
        # @param options [Hash] Import options
        # @return [Hash] Import results
        def import(input_dir:, db_path:, options: {})
          require 'sqlite3'
          require_relative 'sqlite_backend'

          # Create or open database
          backend = SqliteBackend.new(path: db_path)

          results = {
            imported_at: Time.now.iso8601,
            input_dir: input_dir,
            db_path: db_path,
            blocks: 0,
            action_logs: 0,
            knowledge_meta: 0
          }

          # Import blocks
          blockchain_file = File.join(input_dir, 'blockchain.json')
          if File.exist?(blockchain_file)
            results[:blocks] = import_blocks(backend, blockchain_file)
          end

          # Import action logs
          action_log_file = File.join(input_dir, 'action_log.jsonl')
          if File.exist?(action_log_file)
            results[:action_logs] = import_action_logs(backend, action_log_file)
          end

          # Import knowledge metadata
          knowledge_meta_file = File.join(input_dir, 'knowledge_meta.json')
          if File.exist?(knowledge_meta_file)
            results[:knowledge_meta] = import_knowledge_meta(backend, knowledge_meta_file)
          end

          results
        rescue LoadError => e
          { success: false, error: "SQLite not available: #{e.message}" }
        rescue SQLite3::Exception => e
          { success: false, error: "Database error: #{e.message}" }
        end

        # Rebuild SQLite from original file-based storage
        #
        # This imports from the original storage locations:
        # - storage/blockchain.json
        # - skills/action_log.jsonl
        # - knowledge/ directory (extracts metadata from *.md files)
        #
        # @param db_path [String] Path to SQLite database (will be created/replaced)
        # @param storage_dir [String] Storage directory path
        # @param knowledge_dir [String] Knowledge directory path
        # @param skills_dir [String] Skills directory path
        # @return [Hash] Import results
        def rebuild_from_files(db_path:, storage_dir: nil, 
                               knowledge_dir: nil,
                               skills_dir: nil)
          storage_dir ||= KairosMcp.storage_dir
          knowledge_dir ||= KairosMcp.knowledge_dir
          skills_dir ||= KairosMcp.skills_dir
          require 'sqlite3'
          require_relative 'sqlite_backend'

          # Remove existing database if present
          FileUtils.rm_f(db_path) if File.exist?(db_path)

          # Create new database
          backend = SqliteBackend.new(path: db_path)

          results = {
            rebuilt_at: Time.now.iso8601,
            db_path: db_path,
            blocks: 0,
            action_logs: 0,
            knowledge_meta: 0
          }

          # Import blockchain
          blockchain_file = File.join(storage_dir, 'blockchain.json')
          if File.exist?(blockchain_file)
            results[:blocks] = import_blocks(backend, blockchain_file)
          end

          # Import action logs
          action_log_file = File.join(skills_dir, 'action_log.jsonl')
          if File.exist?(action_log_file)
            results[:action_logs] = import_action_logs(backend, action_log_file)
          end

          # Extract and import knowledge metadata from *.md files
          results[:knowledge_meta] = extract_and_import_knowledge_meta(backend, knowledge_dir)

          results
        rescue LoadError => e
          { success: false, error: "SQLite not available: #{e.message}" }
        rescue SQLite3::Exception => e
          { success: false, error: "Database error: #{e.message}" }
        end

        # Import only blockchain
        #
        # @param db_path [String] Path to SQLite database
        # @param blockchain_file [String] Path to blockchain.json
        # @return [Integer] Number of blocks imported
        def import_blockchain(db_path:, blockchain_file:)
          require 'sqlite3'
          require_relative 'sqlite_backend'

          backend = SqliteBackend.new(path: db_path)
          import_blocks(backend, blockchain_file)
        end

        # Import only action logs
        #
        # @param db_path [String] Path to SQLite database
        # @param action_log_file [String] Path to action_log.jsonl
        # @return [Integer] Number of entries imported
        def import_action_log(db_path:, action_log_file:)
          require 'sqlite3'
          require_relative 'sqlite_backend'

          backend = SqliteBackend.new(path: db_path)
          import_action_logs(backend, action_log_file)
        end

        private

        def import_blocks(backend, file_path)
          content = File.read(file_path)
          blocks = JSON.parse(content, symbolize_names: true)

          # Clear existing blocks
          backend.execute("DELETE FROM blocks")

          # Import blocks
          backend.transaction do
            blocks.each do |block|
              backend.save_block(block)
            end
          end

          blocks.size
        end

        def import_action_logs(backend, file_path)
          # Clear existing logs
          backend.clear_action_log!

          count = 0
          File.readlines(file_path).each do |line|
            entry = JSON.parse(line.strip, symbolize_names: true) rescue next
            backend.record_action(entry)
            count += 1
          end

          count
        end

        def import_knowledge_meta(backend, file_path)
          content = File.read(file_path)
          meta_list = JSON.parse(content, symbolize_names: true)

          # Clear existing metadata
          backend.execute("DELETE FROM knowledge_meta")

          # Import metadata
          meta_list.each do |meta|
            backend.save_knowledge_meta(meta[:name], meta)
          end

          meta_list.size
        end

        def extract_and_import_knowledge_meta(backend, knowledge_dir)
          return 0 unless File.directory?(knowledge_dir)

          count = 0
          archived_dir = File.join(knowledge_dir, '.archived')

          # Process active knowledge
          Dir[File.join(knowledge_dir, '*')].each do |dir|
            next unless File.directory?(dir)
            next if dir == archived_dir

            meta = extract_metadata_from_dir(dir, archived: false)
            next unless meta

            backend.save_knowledge_meta(meta[:name], meta)
            count += 1
          end

          # Process archived knowledge
          if File.directory?(archived_dir)
            Dir[File.join(archived_dir, '*')].each do |dir|
              next unless File.directory?(dir)

              meta = extract_metadata_from_dir(dir, archived: true)
              next unless meta

              backend.save_knowledge_meta(meta[:name], meta)
              count += 1
            end
          end

          count
        end

        def extract_metadata_from_dir(dir, archived:)
          name = File.basename(dir)
          md_file = File.join(dir, "#{name}.md")

          return nil unless File.exist?(md_file)

          content = File.read(md_file)
          frontmatter = extract_frontmatter(content)
          content_hash = Digest::SHA256.hexdigest(content)

          meta = {
            name: name,
            content_hash: content_hash,
            version: frontmatter['version'],
            description: frontmatter['description'],
            tags: frontmatter['tags'] || [],
            is_archived: archived
          }

          # Read archive metadata if archived
          if archived
            archive_meta_file = File.join(dir, '.archive_meta.yml')
            if File.exist?(archive_meta_file)
              archive_meta = YAML.safe_load(File.read(archive_meta_file)) rescue {}
              meta[:archived_at] = archive_meta['archived_at']
              meta[:archived_reason] = archive_meta['archived_reason']
              meta[:superseded_by] = archive_meta['superseded_by']
            end
          end

          meta
        end

        def extract_frontmatter(content)
          return {} unless content.start_with?('---')

          parts = content.split('---', 3)
          return {} if parts.size < 3

          YAML.safe_load(parts[1]) || {}
        rescue StandardError
          {}
        end
      end
    end
  end
end
