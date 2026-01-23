# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative 'backend'

module KairosMcp
  module Storage
    # SQLite-based storage backend (optional, for team use)
    #
    # This backend provides:
    # - ACID transactions for data integrity
    # - Built-in locking for concurrent access
    # - WAL mode for better read/write concurrency
    #
    # Requires: gem install sqlite3
    #
    # Storage:
    # - Blockchain: blocks table
    # - Action logs: action_logs table
    # - Knowledge metadata: knowledge_meta table (content still in files)
    #
    class SqliteBackend < Backend
      DEFAULT_DB_PATH = File.expand_path('../../../storage/kairos.db', __dir__)

      SCHEMA = <<~SQL
        -- Blockchain blocks
        CREATE TABLE IF NOT EXISTS blocks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            block_index INTEGER NOT NULL UNIQUE,
            timestamp TEXT NOT NULL,
            data TEXT NOT NULL,
            previous_hash TEXT NOT NULL,
            merkle_root TEXT NOT NULL,
            hash TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        );

        -- Action logs
        CREATE TABLE IF NOT EXISTS action_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            action TEXT NOT NULL,
            skill_id TEXT,
            layer TEXT,
            details TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );

        -- Knowledge metadata (content is in files)
        CREATE TABLE IF NOT EXISTS knowledge_meta (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            content_hash TEXT NOT NULL,
            version TEXT,
            description TEXT,
            tags TEXT,
            is_archived INTEGER DEFAULT 0,
            archived_at TEXT,
            archived_reason TEXT,
            superseded_by TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );

        -- Indexes
        CREATE INDEX IF NOT EXISTS idx_blocks_hash ON blocks(hash);
        CREATE INDEX IF NOT EXISTS idx_blocks_index ON blocks(block_index);
        CREATE INDEX IF NOT EXISTS idx_action_logs_timestamp ON action_logs(timestamp);
        CREATE INDEX IF NOT EXISTS idx_action_logs_skill ON action_logs(skill_id);
        CREATE INDEX IF NOT EXISTS idx_knowledge_meta_archived ON knowledge_meta(is_archived);
        CREATE INDEX IF NOT EXISTS idx_knowledge_meta_hash ON knowledge_meta(content_hash);
      SQL

      def initialize(config = {})
        @db_path = config[:path] || config['path'] || DEFAULT_DB_PATH
        @wal_mode = config[:wal_mode] != false && config['wal_mode'] != false

        require 'sqlite3'
        setup_database
      rescue LoadError => e
        raise LoadError, "SQLite backend requires sqlite3 gem: #{e.message}"
      end

      # ===========================================================================
      # Block Operations
      # ===========================================================================

      def load_blocks
        rows = @db.execute(<<~SQL)
          SELECT block_index, timestamp, data, previous_hash, merkle_root, hash
          FROM blocks
          ORDER BY block_index ASC
        SQL

        return nil if rows.empty?

        rows.map do |row|
          {
            index: row[0],
            timestamp: row[1],
            data: JSON.parse(row[2]),
            previous_hash: row[3],
            merkle_root: row[4],
            hash: row[5]
          }
        end
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to load blocks: #{e.message}"
        nil
      end

      def save_block(block)
        data = block.is_a?(Hash) ? block : block.to_h
        @db.execute(<<~SQL, [
          data[:index],
          data[:timestamp].to_s,
          data[:data].to_json,
          data[:previous_hash],
          data[:merkle_root],
          data[:hash]
        ])
          INSERT OR REPLACE INTO blocks (block_index, timestamp, data, previous_hash, merkle_root, hash)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL
        true
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to save block: #{e.message}"
        false
      end

      def save_all_blocks(blocks)
        @db.transaction do
          blocks.each { |block| save_block(block) }
        end
        true
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to save all blocks: #{e.message}"
        false
      end

      def all_blocks
        load_blocks || []
      end

      # ===========================================================================
      # Action Log Operations
      # ===========================================================================

      def record_action(entry)
        @db.execute(<<~SQL, [
          entry[:timestamp] || Time.now.iso8601,
          entry[:action],
          entry[:skill_id],
          entry[:layer],
          entry[:details]&.to_json
        ])
          INSERT INTO action_logs (timestamp, action, skill_id, layer, details)
          VALUES (?, ?, ?, ?, ?)
        SQL
        true
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to record action: #{e.message}"
        false
      end

      def action_history(limit: 50)
        rows = @db.execute(<<~SQL, [limit])
          SELECT timestamp, action, skill_id, details
          FROM action_logs
          ORDER BY id DESC
          LIMIT ?
        SQL

        rows.reverse.map do |row|
          {
            timestamp: row[0],
            action: row[1],
            skill_id: row[2],
            details: row[3] ? (JSON.parse(row[3]) rescue row[3]) : nil
          }
        end
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to get action history: #{e.message}"
        []
      end

      def clear_action_log!
        @db.execute("DELETE FROM action_logs")
        true
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to clear action log: #{e.message}"
        false
      end

      # ===========================================================================
      # Knowledge Meta Operations
      # ===========================================================================

      def save_knowledge_meta(name, meta)
        existing = get_knowledge_meta(name)

        if existing
          @db.execute(<<~SQL, [
            meta[:content_hash],
            meta[:version],
            meta[:description],
            meta[:tags]&.to_json,
            meta[:is_archived] ? 1 : 0,
            meta[:archived_at],
            meta[:archived_reason],
            meta[:superseded_by],
            name
          ])
            UPDATE knowledge_meta
            SET content_hash = ?, version = ?, description = ?, tags = ?,
                is_archived = ?, archived_at = ?, archived_reason = ?, superseded_by = ?,
                updated_at = datetime('now')
            WHERE name = ?
          SQL
        else
          @db.execute(<<~SQL, [
            name,
            meta[:content_hash],
            meta[:version],
            meta[:description],
            meta[:tags]&.to_json,
            meta[:is_archived] ? 1 : 0,
            meta[:archived_at],
            meta[:archived_reason],
            meta[:superseded_by]
          ])
            INSERT INTO knowledge_meta (name, content_hash, version, description, tags,
                                        is_archived, archived_at, archived_reason, superseded_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
        end
        true
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to save knowledge meta: #{e.message}"
        false
      end

      def get_knowledge_meta(name)
        row = @db.get_first_row(<<~SQL, [name])
          SELECT name, content_hash, version, description, tags,
                 is_archived, archived_at, archived_reason, superseded_by,
                 created_at, updated_at
          FROM knowledge_meta
          WHERE name = ?
        SQL

        return nil unless row

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
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to get knowledge meta: #{e.message}"
        nil
      end

      def list_knowledge_meta
        rows = @db.execute(<<~SQL)
          SELECT name, content_hash, version, description, tags,
                 is_archived, archived_at, archived_reason, superseded_by,
                 created_at, updated_at
          FROM knowledge_meta
          ORDER BY name ASC
        SQL

        rows.map do |row|
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
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to list knowledge meta: #{e.message}"
        []
      end

      def delete_knowledge_meta(name)
        @db.execute("DELETE FROM knowledge_meta WHERE name = ?", [name])
        true
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to delete knowledge meta: #{e.message}"
        false
      end

      def update_knowledge_archived(name, archived, reason: nil)
        @db.execute(<<~SQL, [
          archived ? 1 : 0,
          archived ? Time.now.iso8601 : nil,
          reason,
          name
        ])
          UPDATE knowledge_meta
          SET is_archived = ?, archived_at = ?, archived_reason = ?, updated_at = datetime('now')
          WHERE name = ?
        SQL
        true
      rescue SQLite3::Exception => e
        warn "[SqliteBackend] Failed to update knowledge archived status: #{e.message}"
        false
      end

      # ===========================================================================
      # Utility Methods
      # ===========================================================================

      def ready?
        @db && @db.execute("SELECT 1").first == [1]
      rescue StandardError
        false
      end

      def backend_type
        :sqlite
      end

      # Get the database path
      attr_reader :db_path

      # Get the raw database connection (for advanced operations)
      attr_reader :db

      # Execute raw SQL (for migrations, etc.)
      def execute(sql, params = [])
        @db.execute(sql, params)
      end

      # Run a transaction
      def transaction(&block)
        @db.transaction(&block)
      end

      private

      def setup_database
        FileUtils.mkdir_p(File.dirname(@db_path))
        @db = SQLite3::Database.new(@db_path)

        # Enable WAL mode for better concurrency
        if @wal_mode
          @db.execute("PRAGMA journal_mode=WAL")
        end

        # Other performance settings
        @db.execute("PRAGMA synchronous=NORMAL")
        @db.execute("PRAGMA cache_size=10000")
        @db.execute("PRAGMA temp_store=MEMORY")

        # Create schema
        @db.execute_batch(SCHEMA)
      end
    end
  end
end
