# frozen_string_literal: true

module Multiuser
  class UserRegistry
    VALID_ROLES = %w[owner member guest].freeze

    attr_reader :pool, :tenant_manager

    def initialize(pool, tenant_manager)
      @pool = pool
      @tenant_manager = tenant_manager
    end

    def register(username, role: 'member', display_name: nil)
      validate_role!(role)
      validate_username!(username)

      schema = tenant_manager.create_tenant(username)

      pool.with_connection do |conn|
        conn.exec_params(
          "INSERT INTO users (username, display_name, tenant_schema, role) VALUES ($1, $2, $3, $4)",
          [username, display_name || username, schema, role]
        )
      end

      record_system_event(
        action: 'user_registered',
        actor: 'system',
        target: username,
        details: { role: role, tenant_schema: schema }
      )

      { username: username, role: role, tenant_schema: schema }
    end

    def find(username)
      pool.with_connection do |conn|
        result = conn.exec_params(
          "SELECT * FROM users WHERE username = $1",
          [username]
        )
        result.ntuples > 0 ? result.first : nil
      end
    end

    def list
      pool.with_connection do |conn|
        conn.exec("SELECT username, display_name, tenant_schema, role, created_at FROM users ORDER BY created_at")
           .to_a
      end
    end

    def update_role(username, new_role)
      validate_role!(new_role)

      pool.with_connection do |conn|
        result = conn.exec_params(
          "UPDATE users SET role = $1, updated_at = NOW() WHERE username = $2 RETURNING username, role",
          [new_role, username]
        )
        raise ArgumentError, "User not found: #{username}" if result.ntuples == 0
      end

      record_system_event(
        action: 'user_role_changed',
        actor: 'system',
        target: username,
        details: { new_role: new_role }
      )

      { username: username, role: new_role }
    end

    def delete(username)
      user = find(username)
      raise ArgumentError, "User not found: #{username}" unless user

      schema = user['tenant_schema']

      pool.with_connection do |conn|
        conn.exec_params("DELETE FROM users WHERE username = $1", [username])
      end

      tenant_manager.drop_tenant(schema) if schema && tenant_manager.tenant_exists?(schema)

      record_system_event(
        action: 'user_deleted',
        actor: 'system',
        target: username,
        details: { tenant_schema: schema }
      )

      { username: username, deleted: true }
    end

    def count
      pool.with_connection do |conn|
        conn.exec("SELECT COUNT(*) AS cnt FROM users").first['cnt'].to_i
      end
    end

    private

    def validate_role!(role)
      unless VALID_ROLES.include?(role)
        raise ArgumentError, "Invalid role: #{role}. Must be one of: #{VALID_ROLES.join(', ')}"
      end
    end

    def validate_username!(username)
      raise ArgumentError, 'Username cannot be blank' if username.nil? || username.strip.empty?
      unless username.match?(/\A[a-zA-Z0-9_\-\.]+\z/)
        raise ArgumentError, 'Username must contain only alphanumeric, underscores, hyphens, dots'
      end
    end

    def record_system_event(action:, actor:, target:, details: {})
      require_relative '../../../../KairosChain_mcp_server/lib/kairos_mcp/kairos_chain/chain' rescue nil

      begin
        chain = KairosMcp::KairosChain::Chain.new
        chain.add_block([{
          type: 'multiuser_system_event',
          layer: 'system',
          action: action,
          actor: actor,
          target: target,
          details: details,
          timestamp: Time.now.iso8601
        }.to_json])
      rescue StandardError => e
        $stderr.puts "[Multiuser] Failed to record system event: #{e.message}"
      end
    end
  end
end
