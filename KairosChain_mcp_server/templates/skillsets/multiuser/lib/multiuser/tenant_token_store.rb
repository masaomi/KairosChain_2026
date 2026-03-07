# frozen_string_literal: true

require 'digest'
require 'securerandom'

module Multiuser
  # PostgreSQL-backed TokenStore with same public API as Auth::TokenStore
  class TenantTokenStore
    VALID_ROLES = %w[owner member guest].freeze
    TOKEN_PREFIX = 'kc_'
    DEFAULT_EXPIRY_DAYS = 90

    def initialize(config = {})
      @pool = Multiuser.pool
    end

    def create(user:, role: 'member', issued_by: 'system', expires_in: nil)
      validate_role!(role)

      raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(32)}"
      token_hash = Digest::SHA256.hexdigest(raw_token)
      now = Time.now
      expires_at = calculate_expiry(now, expires_in)

      user_record = Multiuser.user_registry&.find(user)
      user_id = user_record ? user_record['id'] : nil

      @pool.with_connection do |conn|
        conn.exec_params(
          "INSERT INTO tokens (token_hash, user_id, role, status, issued_at, expires_at, issued_by) " \
          "VALUES ($1, $2, $3, 'active', $4, $5, $6)",
          [token_hash, user_id, role, now.iso8601, expires_at&.iso8601, issued_by]
        )
      end

      {
        'raw_token' => raw_token,
        'token_hash' => token_hash,
        'user' => user,
        'role' => role,
        'issued_at' => now.iso8601,
        'expires_at' => expires_at&.iso8601,
        'issued_by' => issued_by,
        'status' => 'active'
      }
    end

    def verify(raw_token)
      token_hash = Digest::SHA256.hexdigest(raw_token)

      @pool.with_connection do |conn|
        result = conn.exec_params(
          "SELECT t.*, u.username, u.tenant_schema FROM tokens t " \
          "LEFT JOIN users u ON t.user_id = u.id " \
          "WHERE t.token_hash = $1 AND t.status = 'active'",
          [token_hash]
        )
        return nil if result.ntuples == 0

        entry = result.first
        return nil if entry['expires_at'] && Time.parse(entry['expires_at']) < Time.now

        {
          user: entry['username'],
          role: entry['role'],
          tenant_schema: entry['tenant_schema'],
          issued_at: entry['issued_at'],
          expires_at: entry['expires_at']
        }
      end
    end

    def revoke(user:)
      count = 0
      @pool.with_connection do |conn|
        result = conn.exec_params(
          "UPDATE tokens SET status = 'revoked', revoked_at = NOW() " \
          "WHERE user_id = (SELECT id FROM users WHERE username = $1) AND status = 'active'",
          [user]
        )
        count = result.cmd_tuples
      end
      count
    end

    def rotate(user:, issued_by: 'system')
      @pool.with_connection do |conn|
        conn.exec("BEGIN")

        old = conn.exec_params(
          "SELECT t.role, t.issued_at, t.expires_at FROM tokens t " \
          "JOIN users u ON t.user_id = u.id " \
          "WHERE u.username = $1 AND t.status = 'active' LIMIT 1",
          [user]
        )

        role = old.ntuples > 0 ? old.first['role'] : 'member'
        expires_at = nil

        if old.ntuples > 0 && old.first['expires_at']
          original_issued = Time.parse(old.first['issued_at'])
          original_expires = Time.parse(old.first['expires_at'])
          duration_seconds = (original_expires - original_issued).to_i
          expires_at = (Time.now + duration_seconds).utc.strftime('%Y-%m-%d %H:%M:%S')
        end

        conn.exec_params(
          "UPDATE tokens SET status = 'revoked', revoked_at = NOW() " \
          "WHERE user_id = (SELECT id FROM users WHERE username = $1) AND status = 'active'",
          [user]
        )

        token = SecureRandom.hex(32)
        token_hash = Digest::SHA256.hexdigest(token)

        conn.exec_params(
          "INSERT INTO tokens (token_hash, user_id, role, status, issued_by, expires_at) " \
          "VALUES ($1, (SELECT id FROM users WHERE username = $2), $3, 'active', $4, $5)",
          [token_hash, user, role, issued_by, expires_at]
        )

        conn.exec("COMMIT")
        { 'raw_token' => token, 'user' => user, 'role' => role }
      rescue => e
        conn&.exec("ROLLBACK") rescue nil
        raise
      end
    end

    def list(include_revoked: false)
      @pool.with_connection do |conn|
        sql = "SELECT u.username, t.role, t.status, t.issued_at, t.expires_at, t.issued_by " \
              "FROM tokens t LEFT JOIN users u ON t.user_id = u.id"
        sql += " WHERE t.status = 'active'" unless include_revoked
        sql += " ORDER BY t.issued_at"

        conn.exec(sql).map do |row|
          {
            user: row['username'],
            role: row['role'],
            status: row['status'],
            issued_at: row['issued_at'],
            expires_at: row['expires_at'],
            issued_by: row['issued_by'],
            expired: row['expires_at'] && Time.parse(row['expires_at']) < Time.now
          }
        end
      end
    end

    def empty?
      @pool.with_connection do |conn|
        result = conn.exec("SELECT COUNT(*) AS cnt FROM tokens WHERE status = 'active'")
        result.first['cnt'].to_i == 0
      end
    end

    def reload!
      # No-op for DB-backed store
    end

    private

    def validate_role!(role)
      unless VALID_ROLES.include?(role)
        raise ArgumentError, "Invalid role: #{role}"
      end
    end

    def calculate_expiry(from, expires_in)
      return nil if expires_in == 'never'
      expires_in ||= "#{DEFAULT_EXPIRY_DAYS}d"

      case expires_in
      when /\A(\d+)d\z/ then from + ($1.to_i * 86400)
      when /\A(\d+)h\z/ then from + ($1.to_i * 3600)
      when /\A(\d+)m\z/ then from + ($1.to_i * 60)
      else from + (DEFAULT_EXPIRY_DAYS * 86400)
      end
    end
  end
end
