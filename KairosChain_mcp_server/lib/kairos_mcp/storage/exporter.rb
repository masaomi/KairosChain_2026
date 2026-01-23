# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module KairosMcp
  module Storage
    # Exporter: Export data from SQLite to files
    #
    # This allows:
    # - Backing up SQLite data to human-readable files
    # - Inspecting data without SQL commands
    # - Migrating from SQLite back to file-based storage
    #
    # Export structure:
    #   export_path/
    #   ├── blockchain.json       # All blocks
    #   ├── action_log.jsonl      # Action log entries
    #   └── knowledge_meta.json   # Knowledge metadata (content is in knowledge/*.md)
    #
    class Exporter
      DEFAULT_EXPORT_PATH = File.expand_path('../../../storage/export', __dir__)

      class << self
        # Export all data from SQLite to files
        #
        # @param db_path [String] Path to SQLite database
        # @param output_dir [String] Directory to export to
        # @return [Hash] Export results
        def export(db_path:, output_dir: DEFAULT_EXPORT_PATH)
          require 'sqlite3'

          db = SQLite3::Database.new(db_path)
          FileUtils.mkdir_p(output_dir)

          results = {
            exported_at: Time.now.iso8601,
            db_path: db_path,
            output_dir: output_dir,
            blocks: 0,
            action_logs: 0,
            knowledge_meta: 0
          }

          # Export blocks
          results[:blocks] = export_blocks(db, output_dir)

          # Export action logs
          results[:action_logs] = export_action_logs(db, output_dir)

          # Export knowledge metadata
          results[:knowledge_meta] = export_knowledge_meta(db, output_dir)

          # Write export manifest
          write_manifest(output_dir, results)

          results
        rescue LoadError => e
          { success: false, error: "SQLite not available: #{e.message}" }
        rescue SQLite3::Exception => e
          { success: false, error: "Database error: #{e.message}" }
        end

        # Export only blockchain data
        #
        # @param db_path [String] Path to SQLite database
        # @param output_file [String] Output file path
        # @return [Integer] Number of blocks exported
        def export_blockchain(db_path:, output_file:)
          require 'sqlite3'

          db = SQLite3::Database.new(db_path)
          FileUtils.mkdir_p(File.dirname(output_file))
          export_blocks(db, File.dirname(output_file), File.basename(output_file))
        end

        # Export only action logs
        #
        # @param db_path [String] Path to SQLite database
        # @param output_file [String] Output file path
        # @return [Integer] Number of entries exported
        def export_action_log(db_path:, output_file:)
          require 'sqlite3'

          db = SQLite3::Database.new(db_path)
          FileUtils.mkdir_p(File.dirname(output_file))
          export_action_logs(db, File.dirname(output_file), File.basename(output_file))
        end

        private

        def export_blocks(db, output_dir, filename = 'blockchain.json')
          rows = db.execute(<<~SQL)
            SELECT block_index, timestamp, data, previous_hash, merkle_root, hash
            FROM blocks
            ORDER BY block_index ASC
          SQL

          blocks = rows.map do |row|
            {
              index: row[0],
              timestamp: row[1],
              data: JSON.parse(row[2]),
              previous_hash: row[3],
              merkle_root: row[4],
              hash: row[5]
            }
          end

          output_file = File.join(output_dir, filename)
          File.write(output_file, JSON.pretty_generate(blocks))

          blocks.size
        end

        def export_action_logs(db, output_dir, filename = 'action_log.jsonl')
          rows = db.execute(<<~SQL)
            SELECT timestamp, action, skill_id, layer, details
            FROM action_logs
            ORDER BY id ASC
          SQL

          output_file = File.join(output_dir, filename)
          File.open(output_file, 'w') do |f|
            rows.each do |row|
              entry = {
                timestamp: row[0],
                action: row[1],
                skill_id: row[2],
                layer: row[3],
                details: row[4] ? (JSON.parse(row[4]) rescue row[4]) : nil
              }
              f.puts(entry.to_json)
            end
          end

          rows.size
        end

        def export_knowledge_meta(db, output_dir, filename = 'knowledge_meta.json')
          rows = db.execute(<<~SQL)
            SELECT name, content_hash, version, description, tags,
                   is_archived, archived_at, archived_reason, superseded_by,
                   created_at, updated_at
            FROM knowledge_meta
            ORDER BY name ASC
          SQL

          meta_list = rows.map do |row|
            {
              name: row[0],
              content_hash: row[1],
              version: row[2],
              description: row[3],
              tags: row[4] ? (JSON.parse(row[4]) rescue []) : [],
              is_archived: row[5] == 1,
              archived_at: row[6],
              archived_reason: row[7],
              superseded_by: row[8],
              created_at: row[9],
              updated_at: row[10]
            }
          end

          output_file = File.join(output_dir, filename)
          File.write(output_file, JSON.pretty_generate(meta_list))

          meta_list.size
        end

        def write_manifest(output_dir, results)
          manifest = {
            kairos_chain_export: true,
            version: '1.0',
            exported_at: results[:exported_at],
            source_db: results[:db_path],
            contents: {
              blockchain: 'blockchain.json',
              action_log: 'action_log.jsonl',
              knowledge_meta: 'knowledge_meta.json'
            },
            counts: {
              blocks: results[:blocks],
              action_logs: results[:action_logs],
              knowledge_meta: results[:knowledge_meta]
            }
          }

          File.write(File.join(output_dir, 'manifest.json'), JSON.pretty_generate(manifest))
        end
      end
    end
  end
end
