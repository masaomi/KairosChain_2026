# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'

module MMP
  # Direct-mode session issuance and per-request authorization under a
  # non-open admission policy (secure MMP v1, design v0.4 I2).
  #
  # A session is issued only for a key the policy admits, presented with a
  # fresh, single-use proof (RegistrationProof, protocol kairos-mmp-direct/1)
  # addressed to one of this listener's origins. Every authenticated request
  # is decided again; a decided refusal revokes, an unavailable decision only
  # refuses that request.
  class DirectSession
    ISSUER = 'mmp.direct'
    MAX_AGE = 300
    FUTURE_SKEW = 30
    RESTART_MARGIN = 30

    # The only codes a refused sender ever sees.
    REFUSAL_CODES = %w[proof_stale proof_wrong_audience proof_invalid admission_refused admission_revoked].freeze

    # Single-use nonces, kept until their proof could no longer be fresh.
    class NonceStore
      def initialize
        @seen = {}
        @mutex = Mutex.new
      end

      # true when the nonce was unused (and is now used)
      def claim(nonce, expires_at)
        @mutex.synchronize do
          now = Time.now.utc
          @seen.delete_if { |_n, exp| exp < now }
          return false if @seen.key?(nonce)

          @seen[nonce] = expires_at
          true
        end
      end
    end

    attr_reader :policy, :origins, :started_at

    def initialize(policy:, origins:, started_at:, session_store:, nonce_store: NonceStore.new, clock: -> { Time.now.utc })
      @policy = policy.to_s
      @origins = Array(origins).map(&:to_s).freeze
      @started_at = started_at
      @session_store = session_store
      @nonce_store = nonce_store
      @clock = clock
    end

    # @return [Array(Integer, Hash)] HTTP status and body
    def admit(body, remote_addr: nil)
      identity = body['identity']
      public_key = body['public_key']
      identity_signature = body['identity_signature']
      proof = body['direct_proof']
      proof_signature = body['direct_proof_signature']

      return refuse(400, 'proof_invalid') unless identity.is_a?(Hash) && public_key.is_a?(String) && identity_signature.is_a?(String)

      key = RegistrationProof.parse_key(public_key)
      return refuse(400, 'proof_invalid') unless key
      return refuse(403, 'proof_invalid') unless identity_signature_valid?(identity, identity_signature, public_key)
      return refuse(400, 'proof_invalid') unless proof.is_a?(Hash) && proof_signature.is_a?(String)
      return refuse(400, 'proof_invalid') if RegistrationProof.field_error(proof)

      unless @origins.include?(proof['audience'])
        return refuse(403, 'proof_wrong_audience', expected_audience: @origins.first)
      end

      now = @clock.call
      issued_at = RegistrationProof.issued_at_time(proof)
      earliest = [now - MAX_AGE, @started_at + RESTART_MARGIN].max
      unless issued_at && issued_at >= earliest && issued_at <= now + FUTURE_SKEW
        return refuse(403, 'proof_stale',
                      server_time: now.utc.iso8601,
                      earliest_acceptable_at: earliest.utc.iso8601)
      end

      unless RegistrationProof.verify(public_key, proof, proof_signature, protocol: RegistrationProof::DIRECT_PROTOCOL)
        return refuse(403, 'proof_invalid')
      end
      return refuse(403, 'proof_invalid') unless proof['agent_id'] == identity['instance_id']

      key_sha256 = Digest::SHA256.hexdigest(key.public_to_der)
      decision = Admission.decide(@policy, {
        phase: :introduce,
        key_sha256: key_sha256,
        public_key_pem: public_key,
        instance_id: identity['instance_id'].to_s,
        claimed_name: identity['name'].to_s,
        remote_addr: remote_addr.to_s
      })
      unless decision[:admit]
        warn "[MMP::DirectSession] refused #{key_sha256[0, 16]}… (#{decision[:reason] || 'not admitted'})"
        return refuse(403, 'admission_refused', key_sha256: key_sha256)
      end

      return refuse(403, 'proof_invalid') unless @nonce_store.claim(proof['nonce'], issued_at + MAX_AGE + FUTURE_SKEW)

      token = @session_store.create_session(
        identity['instance_id'].to_s, public_key,
        issuer: ISSUER, key_sha256: key_sha256, admitted_as: decision[:as]
      )
      [200, { status: 'received', identity_verified: true, session_token: token }]
    end

    # @param session [Hash] from MeetingSessionStore#session_record
    # @return [Hash] { ok:, status:, error:, revoke:, key_sha256:, admitted_as: }
    def authorize(session)
      return { ok: false, status: 401, error: 'invalid_or_expired_token', revoke: false } unless session && session[:issuer] == ISSUER

      key_sha256 = session[:key_sha256]
      return { ok: false, status: 403, error: 'admission_revoked', revoke: true } unless key_sha256.is_a?(String) && !key_sha256.empty?

      decision = Admission.decide(@policy, { phase: :request, key_sha256: key_sha256, instance_id: session[:peer_id].to_s })
      return { ok: false, status: 403, error: 'admission_refused', revoke: false } if decision[:unavailable]
      return { ok: false, status: 403, error: 'admission_revoked', revoke: true } unless decision[:admit]

      { ok: true, key_sha256: key_sha256, admitted_as: decision[:as] }
    end

    private

    def identity_signature_valid?(identity, signature, public_key)
      canonical = JSON.generate(identity, sort_keys: true)
      Crypto.new(auto_generate: false).verify_signature(canonical, signature, public_key)
    rescue StandardError
      false
    end

    def refuse(status, code, extra = {})
      [status, { error: code }.merge(extra)]
    end
  end
end
