# frozen_string_literal: true

require 'securerandom'

module MMP
  # MeetingSessionStore manages session tokens for Meeting Protocol authentication.
  #
  # After a successful `POST /meeting/v1/introduce` handshake with RSA signature
  # verification, a session token is issued. All subsequent authenticated endpoints
  # require `Authorization: Bearer <token>`.
  #
  # Features:
  #   - Token TTL (default 60min)
  #   - Rate limiting (default 100 req/min per session)
  #   - Thread-safe (Mutex)
  #   - Token revocation via `goodbye`
  class MeetingSessionStore
    DEFAULT_TTL_MINUTES = 60
    DEFAULT_RATE_LIMIT_PER_MINUTE = 100

    Session = Struct.new(
      :peer_id, :public_key, :pubkey_hash, :token, :created_at,
      :last_activity, :request_count, :request_window_start,
      keyword_init: true
    )

    attr_reader :ttl_minutes, :rate_limit

    def initialize(ttl_minutes: DEFAULT_TTL_MINUTES, rate_limit: DEFAULT_RATE_LIMIT_PER_MINUTE)
      @sessions = {}
      @ttl = ttl_minutes * 60
      @ttl_minutes = ttl_minutes
      @rate_limit = rate_limit
      @mutex = Mutex.new
    end

    # Create a new session for a verified peer.
    # Returns the session token string.
    #
    # @param peer_id [String] Peer identifier
    # @param public_key [String] PEM-encoded public key
    # @param pubkey_hash [String, nil] SHA256 hex of public key (for Service Grant)
    def create_session(peer_id, public_key, pubkey_hash: nil)
      token = SecureRandom.hex(32)
      now = Time.now
      @mutex.synchronize do
        @sessions[token] = Session.new(
          peer_id: peer_id,
          public_key: public_key,
          pubkey_hash: pubkey_hash,
          token: token,
          created_at: now,
          last_activity: now,
          request_count: 0,
          request_window_start: now
        )
      end
      token
    end

    # Validate a session token. Returns peer_id if valid, nil if invalid/expired.
    def validate(token)
      return nil unless token

      @mutex.synchronize do
        session = @sessions[token]
        return nil unless session

        # Check TTL
        if Time.now - session.created_at > @ttl
          @sessions.delete(token)
          return nil
        end

        session.last_activity = Time.now
        session.peer_id
      end
    end

    # Check rate limit for a token. Returns true if within limits, false if exceeded.
    def check_rate_limit(token)
      return false unless token

      @mutex.synchronize do
        session = @sessions[token]
        return false unless session

        now = Time.now
        # Reset window if more than 60 seconds have passed
        if now - session.request_window_start > 60
          session.request_count = 0
          session.request_window_start = now
        end

        session.request_count += 1
        session.request_count <= @rate_limit
      end
    end

    # Revoke a session token (used by goodbye).
    def revoke(token)
      return nil unless token

      @mutex.synchronize { @sessions.delete(token) }
    end

    # Get session info (for status/debugging).
    def session_info(token)
      return nil unless token

      @mutex.synchronize do
        session = @sessions[token]
        return nil unless session

        {
          peer_id: session.peer_id,
          created_at: session.created_at.iso8601,
          last_activity: session.last_activity.iso8601,
          request_count: session.request_count,
          ttl_remaining_seconds: [(@ttl - (Time.now - session.created_at)).to_i, 0].max
        }
      end
    end

    # Number of active sessions.
    def active_session_count
      @mutex.synchronize do
        cleanup_expired
        @sessions.size
      end
    end

    # Reverse lookup: find pubkey_hash for a given peer_id.
    # Falls back to linear scan — use pubkey_hash_for_token when possible.
    #
    # @param peer_id [String] Peer identifier
    # @return [String, nil] pubkey_hash if found
    def pubkey_hash_for(peer_id)
      @mutex.synchronize do
        session = @sessions.values.find { |s| s.peer_id == peer_id }
        session&.pubkey_hash
      end
    end

    # Exact session lookup by token. O(1) — no ambiguity with multiple sessions.
    #
    # @param token [String] Bearer token
    # @return [String, nil] pubkey_hash if session exists
    def pubkey_hash_for_token(token)
      @mutex.synchronize do
        session = @sessions[token]
        session&.pubkey_hash
      end
    end

    private

    # Remove expired sessions (called within mutex).
    def cleanup_expired
      now = Time.now
      @sessions.delete_if { |_token, session| now - session.created_at > @ttl }
    end
  end
end
