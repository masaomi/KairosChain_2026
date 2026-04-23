# frozen_string_literal: true

require 'openssl'

module KairosMcp
  module SkillSets
    module DaemonRuntime
      # Uniform failure type for authentication failures. Callers rescue
      # AuthError to return HTTP 401; everything else is a 500.
      # B10 (R5, Opus 4.6): canonical_request now raises AuthError, not
      # RuntimeError, so a malformed-input request does not escape as 500.
      class AuthError < StandardError
        attr_reader :code
        def initialize(code, message = nil)
          @code = code
          super(message || code)
        end
      end

      # TTL-bounded replay cache. Thread-safe (all mutations under @mutex).
      #
      # R5 rerun findings addressed:
      # - Nonce TOCTOU: seen/record were separate calls with no mutex, so
      #   two concurrent requests with the same nonce could both pass.
      #   Exposed as a single atomic `check_and_record` plus legacy
      #   seen?/record helpers that each hold the mutex.
      # - @nonce_cache thread safety: all Hash access is synchronized.
      # - Size bound under sustained traffic: eviction runs every write
      #   (not only on size threshold) with O(1) amortized sweep.
      class NonceCache
        DEFAULT_MAX_ENTRIES = 10_000

        def initialize(max_entries: DEFAULT_MAX_ENTRIES, clock: -> { Time.now })
          @mutex = Mutex.new
          @entries = {}   # nonce => expiry (Time)
          @max_entries = max_entries
          @clock = clock
        end

        # Atomic seen-or-record. Returns true if the nonce was fresh and
        # is now recorded; false if it was already seen (replay).
        # Callers MUST use this (not separate seen?/record) on the request
        # path to avoid TOCTOU.
        #
        # R1 P2 (3-voice): sweep is no longer run on every call. Expired
        # entries are handled lazily inside `fresh_locked?`; full sweep is
        # only triggered when the cap is exceeded (bounded amortized cost).
        def check_and_record(nonce, ttl:)
          @mutex.synchronize do
            return false if fresh_locked?(nonce)
            @entries[nonce] = @clock.call + ttl
            enforce_cap_locked
            true
          end
        end

        def seen?(nonce)
          @mutex.synchronize { fresh_locked?(nonce) }
        end

        def record(nonce, ttl:)
          @mutex.synchronize do
            @entries[nonce] = @clock.call + ttl
            enforce_cap_locked
          end
        end

        def size
          @mutex.synchronize { @entries.size }
        end

        private

        def fresh_locked?(nonce)
          expiry = @entries[nonce]
          return false unless expiry
          if expiry < @clock.call
            @entries.delete(nonce)
            false
          else
            true
          end
        end

        def sweep_expired_locked
          now = @clock.call
          @entries.delete_if { |_, exp| exp < now }
        end

        # Called when size exceeds cap. Sweep expired first (amortized
        # O(n) but rare), then evict oldest insertion-order until within
        # cap. Ruby Hash preserves insertion order, so `shift` removes
        # the oldest entry.
        def enforce_cap_locked
          return if @entries.size <= @max_entries
          sweep_expired_locked
          overflow = @entries.size - @max_entries
          overflow.times { @entries.shift } if overflow.positive?
        end
      end

      # HMAC-SHA256 request authentication (v0.4 §2.6).
      #
      # Canonical request is a NUL-delimited byte sequence with the body
      # length-prefixed, preventing NUL smuggling inside the body from
      # forging a fake field boundary.
      #
      # verify! records the nonce ONLY after HMAC verification succeeds
      # (v0.4 R5 P1 fix: unauthenticated requests must not poison the
      # replay cache).
      module AttachAuth
        HMAC_ALGO            = 'SHA256'
        TIMESTAMP_WINDOW_SEC = 30
        NONCE_TTL_SEC        = 120  # must exceed TIMESTAMP_WINDOW_SEC

        module_function

        # Build the canonical request bytes. Raises AuthError if any
        # structurally-invalid field is supplied (B10: AuthError not
        # RuntimeError, so HTTP handlers mapping AuthError → 401 cover it).
        def canonical_request(method:, path:, body:, timestamp:, nonce:)
          raise AuthError.new('malformed', 'method contains NUL')    if method.to_s.include?("\x00")
          raise AuthError.new('malformed', 'path contains NUL')      if path.to_s.include?("\x00")
          raise AuthError.new('malformed', 'timestamp contains NUL') if timestamp.to_s.include?("\x00")
          raise AuthError.new('malformed', 'nonce contains NUL')     if nonce.to_s.include?("\x00")

          body_bytes = body.to_s.b
          [
            method,
            "\x00",
            path,
            "\x00",
            timestamp.to_s,
            "\x00",
            nonce,
            "\x00",
            body_bytes.bytesize.to_s,
            "\x00",
            body_bytes
          ].join.b
        end

        def sign(secret, method:, path:, body:, timestamp:, nonce:)
          msg = canonical_request(method: method, path: path, body: body,
                                  timestamp: timestamp, nonce: nonce)
          OpenSSL::HMAC.hexdigest(HMAC_ALGO, secret, msg)
        end

        # Full request authentication. On success returns true. On any
        # failure raises AuthError with a stable `code` field for logging.
        #
        # Invariants:
        # - timestamp parsed with Integer(...) coerced to AuthError
        #   (B2: was bare ArgumentError → unhandled 500).
        # - nonce recorded ONLY after secure_compare succeeds.
        # - nonce check + record is atomic (TOCTOU-safe).
        def verify!(secret, header_mac:, method:, path:, body:,
                    timestamp:, nonce:, nonce_cache:, now: Time.now)
          begin
            ts = Integer(timestamp.to_s, 10)
          rescue ArgumentError, TypeError
            raise AuthError.new('timestamp_invalid',
                                'timestamp is not a base-10 integer')
          end
          # R1 P2 (4.7): reject non-positive timestamps outright rather
          # than letting `.abs` mask them. Unix-epoch seconds must be > 0.
          if ts <= 0
            raise AuthError.new('timestamp_invalid', 'timestamp must be positive')
          end
          if (now.to_i - ts).abs > TIMESTAMP_WINDOW_SEC
            raise AuthError.new('timestamp_skew', 'timestamp outside window')
          end

          expected = sign(secret, method: method, path: path, body: body,
                          timestamp: timestamp, nonce: nonce)
          # R1 P3 (4.6): drop Rack::Utils dependency; stdlib covers this.
          unless secure_compare(expected, header_mac.to_s)
            raise AuthError.new('hmac_mismatch', 'hmac does not match')
          end

          # v0.4 §2.6: record nonce only after HMAC verification.
          unless nonce_cache.check_and_record(nonce, ttl: NONCE_TTL_SEC)
            raise AuthError.new('nonce_replay', 'nonce already used')
          end

          true
        end

        def secure_compare(a, b)
          return false unless a.bytesize == b.bytesize
          OpenSSL.fixed_length_secure_compare(a, b)
        end
      end
    end
  end
end
