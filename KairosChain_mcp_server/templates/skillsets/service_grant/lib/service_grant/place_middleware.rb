# frozen_string_literal: true

module ServiceGrant
  class PlaceMiddleware
    attr_writer :session_store

    def initialize(access_checker:, session_store: nil)
      @checker = access_checker
      @session_store = session_store
    end

    # Called by PlaceRouter before each handler.
    # @return [Hash, nil] nil = allowed, Hash = denial response
    def check(peer_id:, action:, service:, auth_token: nil)
      store = resolve_session_store
      unless store
        return { status: 503, error: "unavailable",
                 message: "Service Grant middleware: session_store not available" }
      end

      # Prefer token-based resolution (exact session) over peer_id scan
      pubkey_hash = if auth_token && store.respond_to?(:pubkey_hash_for_token)
                      store.pubkey_hash_for_token(auth_token)
                    else
                      store.pubkey_hash_for(peer_id)
                    end

      unless pubkey_hash
        return { status: 403, error: "forbidden",
                 message: "Cannot resolve identity for this peer" }
      end

      @checker.check_access(pubkey_hash: pubkey_hash, action: action, service: service)
      nil
    rescue AccessDeniedError => e
      {
        status: e.reason == :quota_exceeded ? 429 : 403,
        error: "forbidden",
        message: e.message,
        details: e.details
      }
    rescue RateLimitError => e
      { status: 429, error: "rate_limited", message: e.message }
    rescue PgUnavailableError
      { status: 503, error: "service_unavailable", message: "Database temporarily unavailable" }
    end

    private

    def resolve_session_store
      @session_store
    end
  end
end
