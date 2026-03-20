# frozen_string_literal: true

module ServiceGrant
  class << self
    attr_reader :pg_pool, :plan_registry, :cycle_manager, :grant_manager,
                :usage_tracker, :access_checker, :ip_resolver, :load_error

    def load!
      return if @loaded
      @load_error = nil
      require 'pg'

      require 'kairos_mcp/safety'
      require 'kairos_mcp/tool_registry'
      require 'kairos_mcp/protocol'

      require_relative 'service_grant/errors'
      require_relative 'service_grant/pg_connection_pool'
      require_relative 'service_grant/pg_circuit_breaker'
      require_relative 'service_grant/ip_rate_tracker'
      require_relative 'service_grant/cycle_manager'
      require_relative 'service_grant/plan_registry'
      require_relative 'service_grant/grant_manager'
      require_relative 'service_grant/usage_tracker'
      require_relative 'service_grant/access_checker'
      require_relative 'service_grant/access_gate'
      require_relative 'service_grant/place_middleware'
      require_relative 'service_grant/request_enricher'
      require_relative 'service_grant/payment_verifier'
      require_relative 'service_grant/client_ip_resolver'
      require_relative 'service_grant/trust_scorer_adapter'

      config = load_config

      # 1. Config (no dependencies)
      config_path = File.join(File.dirname(__FILE__), '..', 'config', 'service_grant.yml')
      @plan_registry = PlanRegistry.new(config_path)
      @cycle_manager = CycleManager.new(plan_registry: @plan_registry)

      # 2. Database
      pg_config = config['postgresql'] || {}
      pg_policy = (config['pg_unavailable_policy'] || 'deny_all').to_sym
      @circuit_breaker = PgCircuitBreaker.new(policy: pg_policy)
      @pg_pool = PgConnectionPool.new(pg_config, circuit_breaker: @circuit_breaker)
      @pg_pool.test_connection!

      # 3. IP resolution + domain objects
      @ip_resolver = ClientIpResolver.new(config['ip_resolution'] || {})
      @grant_manager = GrantManager.new(pg_pool: @pg_pool, plan_registry: @plan_registry)
      @usage_tracker = UsageTracker.new(pg_pool: @pg_pool, plan_registry: @plan_registry,
                                         cycle_manager: @cycle_manager)

      # 4. Trust scorer (optional — requires Synoptis SkillSet)
      @trust_scorer_adapter = build_trust_scorer(config)

      # 5. Unified access checker
      @access_checker = AccessChecker.new(
        grant_manager: @grant_manager, usage_tracker: @usage_tracker,
        plan_registry: @plan_registry, cycle_manager: @cycle_manager,
        trust_scorer: @trust_scorer_adapter
      )

      # 5. Core Hook integrations
      @enricher = RequestEnricher.new(service_name: config['default_service'] || 'meeting_place')
      @enricher.register!

      @gate = AccessGate.new(access_checker: @access_checker)
      @gate.register!

      # 6. Safety policy for admin tools
      register_admin_policy!

      # 7. Hestia Place middleware
      register_place_middleware!

      # 8. Startup validation
      validate_active_grants!

      @loaded = true
      $stderr.puts "[ServiceGrant] Loaded successfully"
    rescue LoadError => e
      @load_error = { type: 'pg_gem_missing', message: "pg gem is not installed. Run: gem install pg" }
      warn "[ServiceGrant] #{@load_error[:message]}"
    rescue PG::ConnectionBad => e
      @load_error = { type: 'pg_server_unavailable', message: "PostgreSQL unavailable: #{e.message}" }
      warn "[ServiceGrant] #{@load_error[:message]}"
    rescue ConfigValidationError => e
      @load_error = { type: 'config_error', message: "Config invalid: #{e.message}" }
      warn "[ServiceGrant] #{@load_error[:message]}"
    rescue StandardError => e
      unload!
      @load_error = { type: 'unexpected_error', message: "#{e.class}: #{e.message}" }
      warn "[ServiceGrant] Failed to load: #{e.message}"
    end

    def loaded?
      @loaded == true
    end

    def unload!
      @gate&.unregister!
      @enricher&.unregister!
      unregister_place_middleware!
      unregister_admin_policy!
      @pg_pool&.close_all
      @pg_pool = nil
      @plan_registry = nil
      @cycle_manager = nil
      @grant_manager = nil
      @usage_tracker = nil
      @access_checker = nil
      @gate = nil
      @enricher = nil
      @circuit_breaker = nil
      @trust_scorer_adapter = nil
      @loaded = false
    end

    private

    def build_trust_scorer(config)
      trust_required = @plan_registry.trust_requirements_configured?

      unless defined?(Synoptis::TrustScorer) && defined?(Synoptis::Registry)
        if trust_required
          raise ConfigValidationError,
            "trust_requirements are configured but Synoptis SkillSet is not available. " \
            "Either add synoptis to depends_on or remove trust_requirements from config."
        end
        warn "[ServiceGrant] Synoptis TrustScorer not available. Trust-based access control disabled."
        return nil
      end

      begin
        ts_config = config['trust_scorer'] || {}
        cache_ttl = ts_config.dig('anti_collusion', 'cache_ttl') || 300

        # Access the Synoptis registry (file-backed)
        registry_path = ts_config['registry_path'] || 'storage/synoptis_registry'
        registry = Synoptis::Registry::FileRegistry.new(data_dir: registry_path)
        scorer = Synoptis::TrustScorer.new(registry: registry, config: ts_config)

        TrustScorerAdapter.new(scorer: scorer, cache_ttl: cache_ttl)
      rescue StandardError => e
        if trust_required
          raise ConfigValidationError,
            "trust_requirements are configured but TrustScorer failed to initialize: #{e.message}"
        end
        warn "[ServiceGrant] TrustScorer initialization failed (non-fatal): #{e.message}"
        nil
      end
    end

    def load_config
      config_path = File.join(File.dirname(__FILE__), '..', 'config', 'service_grant.yml')
      return {} unless File.exist?(config_path)

      require 'yaml'
      YAML.safe_load(File.read(config_path)) || {}
    rescue StandardError => e
      warn "[ServiceGrant] Failed to load config: #{e.message}"
      {}
    end

    def register_place_middleware!
      unless defined?(Hestia::PlaceRouter)
        warn "[ServiceGrant] WARNING: Hestia::PlaceRouter not found. " \
             "Path B (/place/*) access control will NOT be enforced. " \
             "Ensure depends_on includes 'hestia' in skillset.json."
        return
      end

      # session_store is per-instance (set when PlaceRouter#start is called).
      # Middleware is registered without it; PlaceRouter passes peer_id at
      # call time, and session_store is set lazily via attr_writer.
      @place_middleware = PlaceMiddleware.new(access_checker: @access_checker)
      Hestia::PlaceRouter.register_middleware(@place_middleware)
    end

    def unregister_place_middleware!
      if defined?(Hestia::PlaceRouter) && @place_middleware
        Hestia::PlaceRouter.unregister_middleware(@place_middleware)
      end
      @place_middleware = nil
    end

    def register_admin_policy!
      KairosMcp::Safety.register_policy(:can_manage_grants) do |user|
        next true if user.nil?           # STDIO mode: always allowed
        next true if user[:local_dev]    # local dev: always allowed
        user[:role] == 'owner'           # HTTP mode: owner only
      end
    end

    def unregister_admin_policy!
      KairosMcp::Safety.unregister_policy(:can_manage_grants) if
        KairosMcp::Safety.respond_to?(:unregister_policy)
    end

    def validate_active_grants!
      orphaned = @grant_manager.grants_with_unknown_plans(@plan_registry)
      orphaned.each do |g|
        warn "[ServiceGrant] WARNING: Grant #{g[:pubkey_hash]}@#{g[:service]} " \
             "has plan '#{g[:plan]}' which is not in current config. " \
             "Access BLOCKED until plan migration. Run service_grant_migrate to fix."
      end
    rescue StandardError => e
      warn "[ServiceGrant] Grant validation skipped (non-fatal): #{e.message}"
    end
  end
end

# Auto-initialize when required by SkillSet loader
ServiceGrant.load!
