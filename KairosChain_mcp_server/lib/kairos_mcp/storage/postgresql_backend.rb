# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'backend'

module KairosMcp
  module Storage
    # PostgreSQL-based storage backend (for multi-tenant applications like Echoria)
    #
    # This backend provides:
    # - Multi-tenant isolation via tenant_id scoping
    # - Full ACID transactions with PostgreSQL
    # - Connection pooling compatible (single connection managed here)
    #
    # Requires: gem install pg
    #
    # Configuration:
    #   storage:
    #     backend: postgresql
    #     postgresql:
    #       host: localhost
    #       port: 5432
    #       dbname: echoria_development
    #       user: echoria
    #       password: echoria_dev
    #       tenant_id: null  # Set per-request for multi-tenant
    #
    class PostgresqlBackend < Backend

      SCHEMA = <<~SQL
        -- Blockchain blocks (tenant-scoped)
        CREATE TABLE IF NOT EXISTS kairos_blocks (
            id BIGSERIAL PRIMARY KEY,
            tenant_id TEXT NOT NULL DEFAULT 'default',
            block_index INTEGER NOT NULL,
            timestamp TEXT NOT NULL,
            data JSONB NOT NULL,
            previous_hash TEXT NOT NULL,
            merkle_root TEXT NOT NULL,
            hash TEXT NOT NULL,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE (tenant_id, block_index)
        );

        -- Action logs (tenant-scoped)
        CREATE TABLE IF NOT EXISTS kairos_action_logs (
            id BIGSERIAL PRIMARY KEY,
            tenant_id TEXT NOT NULL DEFAULT 'default',
            timestamp TEXT NOT NULL,
            action TEXT NOT NULL,
            skill_id TEXT,
            layer TEXT,
            details JSONB,
            created_at TIMESTAMPTZ DEFAULT NOW()
        );

        -- Knowledge metadata (tenant-scoped, content in files)
        CREATE TABLE IF NOT EXISTS kairos_knowledge_meta (
            id BIGSERIAL PRIMARY KEY,
            tenant_id TEXT NOT NULL DEFAULT 'default',
            name TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            version TEXT,
            description TEXT,
            tags JSONB DEFAULT '[]',
            is_archived BOOLEAN DEFAULT FALSE,
            archived_at TIMESTAMPTZ,
            archived_reason TEXT,
            superseded_by TEXT,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE (tenant_id, name)
        );

        -- Indexes
        CREATE INDEX IF NOT EXISTS idx_kairos_blocks_tenant ON kairos_blocks(tenant_id);
        CREATE INDEX IF NOT EXISTS idx_kairos_blocks_hash ON kairos_blocks(hash);
        CREATE INDEX IF NOT EXISTS idx_kairos_blocks_tenant_index ON kairos_blocks(tenant_id, block_index);
        CREATE INDEX IF NOT EXISTS idx_kairos_action_logs_tenant ON kairos_action_logs(tenant_id);
        CREATE INDEX IF NOT EXISTS idx_kairos_action_logs_timestamp ON kairos_action_logs(tenant_id, timestamp);
        CREATE INDEX IF NOT EXISTS idx_kairos_action_logs_skill ON kairos_action_logs(tenant_id, skill_id);
        CREATE INDEX IF NOT EXISTS idx_kairos_knowledge_meta_tenant ON kairos_knowledge_meta(tenant_id);
        CREATE INDEX IF NOT EXISTS idx_kairos_knowledge_meta_archived ON kairos_knowledge_meta(tenant_id, is_archived);
      SQL

      attr_reader :tenant_id

      def initialize(config = {})
        @conn_params = {
          host: config[:host] || config['host'] || 'localhost',
          port: (config[:port] || config['port'] || 5432).to_i,
          dbname: config[:dbname] || config['dbname'] || 'kairos_development',
          user: config[:user] || config['user'],
          password: config[:password] || config['password']
        }.compact

        @tenant_id = config[:tenant_id] || config['tenant_id'] || 'default'

        require 'pg'
        setup_database
      rescue LoadError => e
        raise LoadError, "PostgreSQL backend requires pg gem: #{e.message}"
      end

      # Switch tenant context (for multi-tenant usage via KairosBridge)
      # @param new_tenant_id [String] The new tenant ID
      def switch_tenant!(new_tenant_id)
        @tenant_id = new_tenant_id.to_s
      end

      # ===========================================================================
      # Block Operations
      # ===========================================================================

      def load_blocks
        result = exec_params(<<~SQL, [@tenant_id])
          SELECT block_index, timestamp, data, previous_hash, merkle_root, hash
          FROM kairos_blocks
          WHERE tenant_id = $1
          ORDER BY block_index ASC
        SQL

        return nil if result.ntuples == 0

        result.map do |row|
          {
            index: row['block_index'].to_i,
            timestamp: row['timestamp'],
            data: JSON.parse(row['data']),
            previous_hash: row['previous_hash'],
            merkle_root: row['merkle_root'],
            hash: row['hash']
          }
        end
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to load blocks: #{e.message}"
        nil
      end

      def save_block(block)
        data = block.is_a?(Hash) ? block : block.to_h
        exec_params(<<~SQL, [@tenant_id, data[:index], data[:timestamp].to_s, data[:data].to_json, data[:previous_hash], data[:merkle_root], data[:hash]])
          INSERT INTO kairos_blocks (tenant_id, block_index, timestamp, data, previous_hash, merkle_root, hash)
          VALUES ($1, $2, $3, $4, $5, $6, $7)
          ON CONFLICT (tenant_id, block_index)
          DO UPDATE SET timestamp = EXCLUDED.timestamp, data = EXCLUDED.data,
                        previous_hash = EXCLUDED.previous_hash, merkle_root = EXCLUDED.merkle_root,
                        hash = EXCLUDED.hash
        SQL
        true
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to save block: #{e.message}"
        false
      end

      def save_all_blocks(blocks)
        transaction do
          blocks.each { |block| save_block(block) }
        end
        true
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to save all blocks: #{e.message}"
        false
      end

      def all_blocks
        load_blocks || []
      end

      # ===========================================================================
      # Action Log Operations
      # ===========================================================================

      def record_action(entry)
        details = entry[:details] ? entry[:details].to_json : nil
        exec_params(<<~SQL, [@tenant_id, entry[:timestamp] || Time.now.iso8601, entry[:action], entry[:skill_id], entry[:layer], details])
          INSERT INTO kairos_action_logs (tenant_id, timestamp, action, skill_id, layer, details)
          VALUES ($1, $2, $3, $4, $5, $6)
        SQL
        true
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to record action: #{e.message}"
        false
      end

      def action_history(limit: 50)
        result = exec_params(<<~SQL, [@tenant_id, limit])
          SELECT timestamp, action, skill_id, details
          FROM kairos_action_logs
          WHERE tenant_id = $1
          ORDER BY id DESC
          LIMIT $2
        SQL

        result.to_a.reverse.map do |row|
          {
            timestamp: row['timestamp'],
            action: row['action'],
            skill_id: row['skill_id'],
            details: row['details'] ? (JSON.parse(row['details']) rescue row['details']) : nil
          }
        end
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to get action history: #{e.message}"
        []
      end

      def clear_action_log!
        exec_params("DELETE FROM kairos_action_logs WHERE tenant_id = $1", [@tenant_id])
        true
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to clear action log: #{e.message}"
        false
      end

      # ===========================================================================
      # Knowledge Meta Operations
      # ===========================================================================

      def save_knowledge_meta(name, meta)
        tags_json = meta[:tags] ? meta[:tags].to_json : '[]'
        exec_params(<<~SQL, [@tenant_id, name, meta[:content_hash], meta[:version], meta[:description], tags_json, meta[:is_archived] ? true : false, meta[:archived_at], meta[:archived_reason], meta[:superseded_by]])
          INSERT INTO kairos_knowledge_meta
            (tenant_id, name, content_hash, version, description, tags, is_archived, archived_at, archived_reason, superseded_by)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          ON CONFLICT (tenant_id, name)
          DO UPDATE SET content_hash = EXCLUDED.content_hash, version = EXCLUDED.version,
                        description = EXCLUDED.description, tags = EXCLUDED.tags,
                        is_archived = EXCLUDED.is_archived, archived_at = EXCLUDED.archived_at,
                        archived_reason = EXCLUDED.archived_reason, superseded_by = EXCLUDED.superseded_by,
                        updated_at = NOW()
        SQL
        true
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to save knowledge meta: #{e.message}"
        false
      end

      def get_knowledge_meta(name)
        result = exec_params(<<~SQL, [@tenant_id, name])
          SELECT name, content_hash, version, description, tags,
                 is_archived, archived_at, archived_reason, superseded_by,
                 created_at, updated_at
          FROM kairos_knowledge_meta
          WHERE tenant_id = $1 AND name = $2
        SQL

        return nil if result.ntuples == 0

        row = result[0]
        {
          name: row['name'],
          content_hash: row['content_hash'],
          version: row['version'],
          description: row['description'],
          tags: row['tags'] ? (JSON.parse(row['tags']) rescue []) : [],
          is_archived: row['is_archived'] == 't',
          archived_at: row['archived_at'],
          archived_reason: row['archived_reason'],
          superseded_by: row['superseded_by'],
          created_at: row['created_at'],
          updated_at: row['updated_at']
        }
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to get knowledge meta: #{e.message}"
        nil
      end

      def list_knowledge_meta
        result = exec_params(<<~SQL, [@tenant_id])
          SELECT name, content_hash, version, description, tags,
                 is_archived, archived_at, archived_reason, superseded_by,
                 created_at, updated_at
          FROM kairos_knowledge_meta
          WHERE tenant_id = $1
          ORDER BY name ASC
        SQL

        result.map do |row|
          {
            name: row['name'],
            content_hash: row['content_hash'],
            version: row['version'],
            description: row['description'],
            tags: row['tags'] ? (JSON.parse(row['tags']) rescue []) : [],
            is_archived: row['is_archived'] == 't',
            archived_at: row['archived_at'],
            archived_reason: row['archived_reason'],
            superseded_by: row['superseded_by'],
            created_at: row['created_at'],
            updated_at: row['updated_at']
          }
        end
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to list knowledge meta: #{e.message}"
        []
      end

      def delete_knowledge_meta(name)
        exec_params("DELETE FROM kairos_knowledge_meta WHERE tenant_id = $1 AND name = $2", [@tenant_id, name])
        true
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to delete knowledge meta: #{e.message}"
        false
      end

      def update_knowledge_archived(name, archived, reason: nil)
        exec_params(<<~SQL, [archived, archived ? Time.now.iso8601 : nil, reason, @tenant_id, name])
          UPDATE kairos_knowledge_meta
          SET is_archived = $1, archived_at = $2, archived_reason = $3, updated_at = NOW()
          WHERE tenant_id = $4 AND name = $5
        SQL
        true
      rescue PG::Error => e
        warn "[PostgresqlBackend] Failed to update knowledge archived status: #{e.message}"
        false
      end

      # ===========================================================================
      # Utility Methods
      # ===========================================================================

      def ready?
        @conn && @conn.status == PG::CONNECTION_OK && exec_params("SELECT 1", []).first['?column?'] == '1'
      rescue StandardError
        false
      end

      def backend_type
        :postgresql
      end

      # Get the raw database connection (for advanced operations)
      attr_reader :conn

      # Execute raw SQL with parameters
      def exec_params(sql, params = [])
        reconnect_if_needed
        @conn.exec_params(sql, params)
      end

      # Run a transaction
      def transaction
        reconnect_if_needed
        @conn.exec("BEGIN")
        yield
        @conn.exec("COMMIT")
      rescue StandardError => e
        @conn.exec("ROLLBACK") rescue nil
        raise e
      end

      # Close the connection
      def close
        @conn&.close
        @conn = nil
      end

      private

      def setup_database
        @conn = PG.connect(@conn_params)
        @conn.exec(SCHEMA)
      end

      def reconnect_if_needed
        return if @conn && @conn.status == PG::CONNECTION_OK

        @conn&.close rescue nil
        @conn = PG.connect(@conn_params)
      end
    end
  end
end
