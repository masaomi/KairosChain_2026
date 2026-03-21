# frozen_string_literal: true

module ServiceGrant
  class AccessGate
    def initialize(access_checker:)
      @checker = access_checker
    end

    def register!
      gate = self
      KairosMcp::ToolRegistry.register_gate(:service_grant) do |tool_name, arguments, safety|
        gate.call(tool_name, arguments, safety)
      end
    end

    def unregister!
      KairosMcp::ToolRegistry.unregister_gate(:service_grant)
    end

    def call(tool_name, arguments, safety)
      user_ctx = safety.current_user
      return unless user_ctx  # STDIO mode -- permissive

      return if user_ctx[:local_dev]  # local dev mode -- permissive

      pubkey_hash = user_ctx[:pubkey_hash]

      # Fail-closed: HTTP mode + Service Grant loaded + no pubkey_hash
      if pubkey_hash.nil?
        raise KairosMcp::ToolRegistry::GateDeniedError.new(
          tool_name, "service_grant",
          "Service Grant enabled but pubkey_hash missing from auth context. " \
          "Check token_store configuration."
        )
      end

      # Fail-closed: no service context means RequestEnricher didn't run
      service = user_ctx[:service]
      unless service
        raise KairosMcp::ToolRegistry::GateDeniedError.new(
          tool_name, "service_grant",
          "No service context available. Ensure RequestEnricher filter is registered."
        )
      end

      action = @checker.resolve_action(service, tool_name)
      remote_ip = user_ctx[:remote_ip]

      @checker.check_access(pubkey_hash: pubkey_hash, action: action,
                            service: service, remote_ip: remote_ip)
    rescue AccessDeniedError => e
      raise KairosMcp::ToolRegistry::GateDeniedError.new(
        tool_name, e.reason.to_s, e.message
      )
    rescue RateLimitError => e
      raise KairosMcp::ToolRegistry::GateDeniedError.new(
        tool_name, "rate_limited", e.message
      )
    rescue PgUnavailableError
      raise KairosMcp::ToolRegistry::GateDeniedError.new(
        tool_name, "service_unavailable", "Database temporarily unavailable"
      )
    end
  end
end
