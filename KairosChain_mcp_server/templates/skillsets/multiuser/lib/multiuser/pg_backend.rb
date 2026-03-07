# frozen_string_literal: true

require 'json'
require 'time'
require 'kairos_mcp/storage/backend'

module Multiuser
  # PostgreSQL storage backend for multi-tenant use.
  # Implements the same interface as SqliteBackend, using tenant-scoped
  # connections via PgConnectionPool#with_tenant_connection.
  class PgBackend < KairosMcp::Storage::Backend
    attr_reader :pool, :tenant_schema

    def initialize(config = {})
      @pool = Multiuser.pool
    end

    # Resolve current tenant schema from request-scoped user_context.
    # Set by Protocol#handle_tools_call via Thread.current[:kairos_user_context].
    def current_schema
      Thread.current[:kairos_user_context]&.dig(:tenant_schema)
    end

    # =========================================================================
    # Block Operations
    # =========================================================================

    def load_blocks
      schema = current_schema
      return nil unless schema

      @pool.with_tenant_connection(schema) do |conn|
        result = conn.exec(
          "SELECT block_index, timestamp, data, previous_hash, merkle_root, hash " \
          "FROM blocks ORDER BY block_index ASC"
        )
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
      end
    rescue => e
      warn "[PgBackend] Failed to load blocks: #{e.message}"
      nil
    end

    def save_block(block)
      schema = current_schema
      return false unless schema

      data = block.is_a?(Hash) ? block : block.to_h

      @pool.with_tenant_connection(schema) do |conn|
        conn.exec_params(
          "INSERT INTO blocks (block_index, timestamp, data, previous_hash, merkle_root, hash) " \
          "VALUES ($1, $2, $3, $4, $5, $6) " \
          "ON CONFLICT (block_index) DO UPDATE SET " \
          "timestamp = EXCLUDED.timestamp, data = EXCLUDED.data, " \
          "previous_hash = EXCLUDED.previous_hash, merkle_root = EXCLUDED.merkle_root, " \
          "hash = EXCLUDED.hash",
          [
            data[:index],
            data[:timestamp].to_s,
            data[:data].to_json,
            data[:previous_hash],
            data[:merkle_root],
            data[:hash]
          ]
        )
      end
      true
    rescue => e
      warn "[PgBackend] Failed to save block: #{e.message}"
      false
    end

    def save_all_blocks(blocks)
      blocks.each { |block| save_block(block) }
      true
    rescue => e
      warn "[PgBackend] Failed to save all blocks: #{e.message}"
      false
    end

    def all_blocks
      load_blocks || []
    end

    # =========================================================================
    # Action Log Operations
    # =========================================================================

    def record_action(entry)
      schema = current_schema
      return false unless schema

      @pool.with_tenant_connection(schema) do |conn|
        conn.exec_params(
          "INSERT INTO action_logs (timestamp, action, skill_id, layer, details) " \
          "VALUES ($1, $2, $3, $4, $5)",
          [
            entry[:timestamp] || Time.now.iso8601,
            entry[:action],
            entry[:skill_id],
            entry[:layer],
            entry[:details]&.to_json
          ]
        )
      end
      true
    rescue => e
      warn "[PgBackend] Failed to record action: #{e.message}"
      false
    end

    def action_history(limit: 50)
      schema = current_schema
      return [] unless schema

      @pool.with_tenant_connection(schema) do |conn|
        result = conn.exec_params(
          "SELECT timestamp, action, skill_id, layer, details " \
          "FROM action_logs ORDER BY id DESC LIMIT $1",
          [limit]
        )

        result.to_a.reverse.map do |row|
          {
            timestamp: row['timestamp'],
            action: row['action'],
            skill_id: row['skill_id'],
            details: row['details'] ? (JSON.parse(row['details']) rescue row['details']) : nil
          }
        end
      end
    rescue => e
      warn "[PgBackend] Failed to get action history: #{e.message}"
      []
    end

    def clear_action_log!
      schema = current_schema
      return false unless schema

      @pool.with_tenant_connection(schema) do |conn|
        conn.exec("DELETE FROM action_logs")
      end
      true
    rescue => e
      warn "[PgBackend] Failed to clear action log: #{e.message}"
      false
    end

    # =========================================================================
    # Knowledge Meta Operations
    # =========================================================================

    def save_knowledge_meta(name, meta)
      schema = current_schema
      return false unless schema

      @pool.with_tenant_connection(schema) do |conn|
        existing = conn.exec_params(
          "SELECT 1 FROM knowledge_meta WHERE name = $1", [name]
        )

        if existing.ntuples > 0
          conn.exec_params(
            "UPDATE knowledge_meta SET content_hash = $1, version = $2, description = $3, " \
            "tags = $4, is_archived = $5, archived_at = $6, archived_reason = $7, " \
            "superseded_by = $8, updated_at = NOW() WHERE name = $9",
            [
              meta[:content_hash], meta[:version], meta[:description],
              meta[:tags]&.to_json, meta[:is_archived] ? true : false,
              meta[:archived_at], meta[:archived_reason], meta[:superseded_by],
              name
            ]
          )
        else
          conn.exec_params(
            "INSERT INTO knowledge_meta (name, content_hash, version, description, tags, " \
            "is_archived, archived_at, archived_reason, superseded_by) " \
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            [
              name, meta[:content_hash], meta[:version], meta[:description],
              meta[:tags]&.to_json, meta[:is_archived] ? true : false,
              meta[:archived_at], meta[:archived_reason], meta[:superseded_by]
            ]
          )
        end
      end
      true
    rescue => e
      warn "[PgBackend] Failed to save knowledge meta: #{e.message}"
      false
    end

    def get_knowledge_meta(name)
      schema = current_schema
      return nil unless schema

      @pool.with_tenant_connection(schema) do |conn|
        result = conn.exec_params(
          "SELECT name, content_hash, version, description, tags, " \
          "is_archived, archived_at, archived_reason, superseded_by, " \
          "created_at, updated_at FROM knowledge_meta WHERE name = $1",
          [name]
        )
        return nil if result.ntuples == 0

        row = result.first
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
    rescue => e
      warn "[PgBackend] Failed to get knowledge meta: #{e.message}"
      nil
    end

    def list_knowledge_meta
      schema = current_schema
      return [] unless schema

      @pool.with_tenant_connection(schema) do |conn|
        result = conn.exec(
          "SELECT name, content_hash, version, description, tags, " \
          "is_archived, archived_at, archived_reason, superseded_by, " \
          "created_at, updated_at FROM knowledge_meta ORDER BY name ASC"
        )

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
      end
    rescue => e
      warn "[PgBackend] Failed to list knowledge meta: #{e.message}"
      []
    end

    def delete_knowledge_meta(name)
      schema = current_schema
      return false unless schema

      @pool.with_tenant_connection(schema) do |conn|
        conn.exec_params("DELETE FROM knowledge_meta WHERE name = $1", [name])
      end
      true
    rescue => e
      warn "[PgBackend] Failed to delete knowledge meta: #{e.message}"
      false
    end

    def update_knowledge_archived(name, archived, reason: nil)
      schema = current_schema
      return false unless schema

      @pool.with_tenant_connection(schema) do |conn|
        conn.exec_params(
          "UPDATE knowledge_meta SET is_archived = $1, archived_at = $2, " \
          "archived_reason = $3, updated_at = NOW() WHERE name = $4",
          [archived, archived ? Time.now.iso8601 : nil, reason, name]
        )
      end
      true
    rescue => e
      warn "[PgBackend] Failed to update knowledge archived status: #{e.message}"
      false
    end

    # =========================================================================
    # Utility Methods
    # =========================================================================

    def ready?
      @pool.with_connection { |conn| conn.exec("SELECT 1").first['?column?'] == '1' }
    rescue
      false
    end

    def backend_type
      :postgresql
    end
  end
end
