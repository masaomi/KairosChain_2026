# frozen_string_literal: true

# Multiuser SkillSet: Multi-tenant user management for KairosChain
#
# Registers 6 hooks into KairosChain core:
#   Hook 1: Backend.register('postgresql')
#   Hook 2: Safety.register_policy(:can_modify_l0, :can_modify_l1, :can_modify_l2, :can_manage_tokens)
#   Hook 3: ToolRegistry.register_gate(:multiuser_authz)
#   Hook 4: Protocol.register_filter(:multiuser_tenant)
#   Hook 5: Auth::TokenStore.register('postgresql')
#   Hook 6: KairosMcp.register_path_resolver(:multiuser_tenant)
#
module Multiuser
  class << self
    attr_reader :pool, :tenant_manager, :user_registry

    def load!
      return if @loaded
      require 'pg'

      require_relative 'multiuser/pg_connection_pool'
      require_relative 'multiuser/pg_backend'
      require_relative 'multiuser/tenant_manager'
      require_relative 'multiuser/user_registry'
      require_relative 'multiuser/tenant_token_store'
      require_relative 'multiuser/authorization_gate'
      require_relative 'multiuser/request_filter'

      config = load_config
      pg_config = config['postgresql'] || {}

      @pool = PgConnectionPool.new(pg_config)
      @tenant_manager = TenantManager.new(@pool)
      @user_registry = UserRegistry.new(@pool, @tenant_manager)

      # Run public schema migrations on first load
      @tenant_manager.migrate_public!

      # Hook 1: Storage backend
      KairosMcp::Storage::Backend.register('postgresql', Multiuser::PgBackend)

      # Hook 2: RBAC policies (keys match Safety#can_modify_*? lookup names)
      KairosMcp::Safety.register_policy(:can_modify_l0) { |u| u[:role] == 'owner' }
      KairosMcp::Safety.register_policy(:can_modify_l1) { |u| %w[owner member].include?(u[:role]) }
      KairosMcp::Safety.register_policy(:can_modify_l2) { |_u| true }
      KairosMcp::Safety.register_policy(:can_manage_tokens) { |u| u[:role] == 'owner' }

      # Hook 3: Authorization gate (default-deny)
      KairosMcp::ToolRegistry.register_gate(:multiuser_authz, &AuthorizationGate.method(:check))

      # Hook 4: Tenant resolution filter
      KairosMcp::Protocol.register_filter(:multiuser_tenant, &RequestFilter.method(:apply))

      # Hook 5: PostgreSQL-backed token store
      KairosMcp::Auth::TokenStore.register('postgresql', Multiuser::TenantTokenStore)

      # Hook 6: Tenant-aware path resolution
      KairosMcp.register_path_resolver(:multiuser_tenant) do |type, user_context|
        next nil unless user_context&.dig(:tenant_schema)
        tenant_id = user_context[:tenant_schema]
        base = File.join(KairosMcp.data_dir, 'tenants', tenant_id)
        case type
        when :knowledge then File.join(base, 'knowledge')
        when :context   then File.join(base, 'context')
        end
      end

      @loaded = true
      $stderr.puts "[Multiuser] Loaded successfully (PostgreSQL: #{pg_config['host'] || 'localhost'}:#{pg_config['port'] || 5432})"
    rescue LoadError => e
      warn "[Multiuser] pg gem not installed: #{e.message}"
    rescue PG::Error => e
      warn "[Multiuser] PostgreSQL connection failed: #{e.message}"
      warn "[Multiuser] Multiuser SkillSet disabled. Check config/multiuser.yml"
    end

    def loaded?
      @loaded == true
    end

    def unload!
      KairosMcp::Storage::Backend.unregister('postgresql')
      KairosMcp::Safety.unregister_policy(:can_modify_l0)
      KairosMcp::Safety.unregister_policy(:can_modify_l1)
      KairosMcp::Safety.unregister_policy(:can_modify_l2)
      KairosMcp::Safety.unregister_policy(:can_manage_tokens)
      KairosMcp::ToolRegistry.unregister_gate(:multiuser_authz)
      KairosMcp::Protocol.unregister_filter(:multiuser_tenant)
      KairosMcp::Auth::TokenStore.unregister('postgresql')
      KairosMcp.unregister_path_resolver(:multiuser_tenant)

      @pool&.close_all
      @pool = nil
      @tenant_manager = nil
      @user_registry = nil
      @loaded = false
    end

    private

    def load_config
      config_path = File.join(File.dirname(__FILE__), '..', 'config', 'multiuser.yml')
      return {} unless File.exist?(config_path)

      require 'yaml'
      YAML.safe_load(File.read(config_path)) || {}
    rescue StandardError => e
      warn "[Multiuser] Failed to load config: #{e.message}"
      {}
    end
  end
end
