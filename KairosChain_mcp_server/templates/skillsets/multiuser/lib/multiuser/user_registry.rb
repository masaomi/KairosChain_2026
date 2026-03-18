# frozen_string_literal: true

module Multiuser
  class UserRegistry
    VALID_ROLES = %w[owner member guest].freeze

    attr_reader :pool, :tenant_manager

    def initialize(pool, tenant_manager)
      @pool = pool
      @tenant_manager = tenant_manager
    end

    def register(username, role: 'member', display_name: nil, actor: 'system')
      validate_role!(role)
      validate_username!(username)

      schema = tenant_manager.create_tenant(username, actor: actor)

      pool.with_connection do |conn|
        conn.exec_params(
          "INSERT INTO users (username, display_name, tenant_schema, role) VALUES ($1, $2, $3, $4)",
          [username, display_name || username, schema, role]
        )
      end

      chain_warning = Multiuser.record_system_event(
        action: 'user_registered',
        actor: actor,
        target: username,
        details: { role: role, tenant_schema: schema }
      )

      result = { username: username, role: role, tenant_schema: schema }
      result[:chain_warning] = chain_warning if chain_warning
      result
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

    def update_role(username, new_role, actor: 'system')
      validate_role!(new_role)

      pool.with_connection do |conn|
        result = conn.exec_params(
          "UPDATE users SET role = $1, updated_at = NOW() WHERE username = $2 RETURNING username, role",
          [new_role, username]
        )
        raise ArgumentError, "User not found: #{username}" if result.ntuples == 0
      end

      chain_warning = Multiuser.record_system_event(
        action: 'user_role_changed',
        actor: actor,
        target: username,
        details: { new_role: new_role }
      )

      result = { username: username, role: new_role }
      result[:chain_warning] = chain_warning if chain_warning
      result
    end

    def delete(username, actor: 'system')
      user = find(username)
      raise ArgumentError, "User not found: #{username}" unless user

      schema = user['tenant_schema']

      pool.with_connection do |conn|
        conn.exec_params("DELETE FROM users WHERE username = $1", [username])
      end

      tenant_manager.drop_tenant(schema, actor: actor) if schema && tenant_manager.tenant_exists?(schema)

      chain_warning = Multiuser.record_system_event(
        action: 'user_deleted',
        actor: actor,
        target: username,
        details: { tenant_schema: schema }
      )

      result = { username: username, deleted: true }
      result[:chain_warning] = chain_warning if chain_warning
      result
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

  end
end
