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
    attr_reader :pool, :tenant_manager, :user_registry, :load_error

    def load!
      return if @loaded
      @load_error = nil
      require 'pg'

      require 'kairos_mcp/storage/backend'
      require 'kairos_mcp/safety'
      require 'kairos_mcp/tool_registry'
      require 'kairos_mcp/protocol'
      require 'kairos_mcp/auth/token_store'

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
        next nil unless tenant_id.match?(PgConnectionPool::TENANT_SCHEMA_PATTERN)
        base = File.join(KairosMcp.data_dir, 'tenants', tenant_id)
        case type
        when :knowledge then File.join(base, 'knowledge')
        when :context   then File.join(base, 'context')
        end
      end

      @loaded = true
      $stderr.puts "[Multiuser] Loaded successfully (PostgreSQL: #{pg_config['host'] || 'localhost'}:#{pg_config['port'] || 5432})"
    rescue LoadError => e
      @load_error = { type: 'pg_gem_missing', message: "pg gem is not installed. Run: gem install pg" }
      warn "[Multiuser] #{@load_error[:message]}"
    rescue PG::ConnectionBad => e
      @load_error = { type: 'pg_server_unavailable', message: "PostgreSQL server is not running or unreachable: #{e.message}" }
      warn "[Multiuser] #{@load_error[:message]}"
    rescue PG::Error => e
      @load_error = { type: 'pg_error', message: "PostgreSQL error: #{e.message}. Check config/multiuser.yml" }
      warn "[Multiuser] #{@load_error[:message]}"
    rescue NameError => e
      @load_error = { type: 'dependency_error', message: "Missing dependency: #{e.message}" }
      warn "[Multiuser] #{@load_error[:message]}"
    rescue StandardError => e
      @load_error = { type: 'unexpected_error', message: "Unexpected error during load: #{e.class}: #{e.message}" }
      warn "[Multiuser] #{@load_error[:message]}"
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

    # Record a system-level event to the blockchain.
    # Shared by UserRegistry and TenantManager.
    def record_system_event(action:, actor: 'system', target:, details: {})
      require 'kairos_mcp/kairos_chain/chain'

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
      nil
    rescue StandardError => e
      $stderr.puts "[Multiuser] Failed to record system event: #{e.message}"
      "chain_recording_failed: #{e.message}"
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

# Auto-initialize when required by SkillSet loader
Multiuser.load!
