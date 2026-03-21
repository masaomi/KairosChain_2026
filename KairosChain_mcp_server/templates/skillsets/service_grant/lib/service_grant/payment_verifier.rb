# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'

module ServiceGrant
  class PaymentVerifier
    PAYMENT_CLAIM = 'payment_verified'

    def initialize(grant_manager:, pg_pool:, plan_registry:, synoptis_registry: nil)
      @grant_manager = grant_manager
      @pg = pg_pool
      @plan_registry = plan_registry
      @synoptis_registry = synoptis_registry
      @authorized_issuers = plan_registry.authorized_payment_issuers
      @max_age = plan_registry.attestation_max_age
    end

    # @param proof_data [Hash] Full ProofEnvelope JSON from Payment Agent
    # @return [Hash] { success: true, old_plan: ..., new_plan: ... }
    def verify_and_upgrade(proof_data)
      raise ConfigValidationError, 'Synoptis registry required for payment verification' unless @synoptis_registry

      # 1. Validate raw data before normalization (ProofEnvelope.from_h fills defaults)
      validate_raw_proof(proof_data)

      # 2. Normalize and import proof
      proof = import_proof(proof_data)

      # 3. Verify signature (cryptographic — with public key)
      verify_signature(proof)

      # 4. Verify issuer authorization
      verify_issuer(proof)

      # 5. Verify freshness (from signed timestamp)
      verify_freshness(proof)

      # 6. Verify not revoked
      verify_not_revoked(proof)

      # 7. Parse and validate evidence (all payment fields from signed content)
      evidence = parse_evidence(proof)
      payment_intent_id = evidence['payment_intent_id']

      # 8. Verify nonce
      verify_nonce(evidence)

      # 9. Duplicate check (using signed payment_intent_id)
      existing = find_by_payment_intent(payment_intent_id)
      if existing
        validate_idempotent_match!(existing, evidence)
        return { success: true, idempotent: true }
      end

      # 10. Amount + currency verification
      verify_amount_matches_plan(evidence)

      # 11. Ensure grant exists + upgrade + record (single transaction)
      payer = extract_payer_pubkey(proof)
      execute_upgrade_transaction(payer, proof, evidence, payment_intent_id)
    rescue PG::UniqueViolation
      # Concurrent duplicate — validate and return idempotent
      existing = find_by_payment_intent(payment_intent_id) if payment_intent_id
      validate_idempotent_match!(existing, evidence) if existing && evidence
      { success: true, idempotent: true }
    end

    private

    # --- Raw validation (before ProofEnvelope.from_h fills defaults) ---

    def validate_raw_proof(proof_data)
      data = proof_data.is_a?(Hash) ? proof_data : {}
      pid = data['proof_id'] || data[:proof_id]
      ts = data['timestamp'] || data[:timestamp]
      sig = data['signature'] || data[:signature]
      raise InvalidAttestationError, 'Missing proof_id in transmitted proof' if pid.nil? || pid.to_s.strip.empty?
      raise InvalidAttestationError, 'Missing timestamp in transmitted proof' if ts.nil? || ts.to_s.strip.empty?
      raise InvalidAttestationError, 'Missing signature in transmitted proof' if sig.nil? || sig.to_s.strip.empty?
    end

    # --- Proof import ---

    def import_proof(proof_data)
      envelope = Synoptis::ProofEnvelope.from_h(proof_data)

      unless @synoptis_registry.find_proof(envelope.proof_id)
        @synoptis_registry.store_proof(envelope)
      end

      proof = @synoptis_registry.find_proof(envelope.proof_id)
      raise InvalidAttestationError, 'Proof not found after import' unless proof
      proof
    end

    # --- Cryptographic verification ---

    def verify_signature(proof)
      issuer_hash = Synoptis::TrustIdentity.extract_pubkey_hash(proof.attester_id)
      public_key = resolve_public_key(issuer_hash)
      raise InvalidAttestationError, 'Cannot resolve issuer public key' unless public_key

      verifier = Synoptis::Verifier.new
      result = verifier.verify(proof, public_key: public_key)
      unless result[:valid]
        raise InvalidAttestationError,
          "Attestation signature verification failed: #{result[:errors].join(', ')}"
      end
    end

    def resolve_public_key(pubkey_hash)
      return nil unless pubkey_hash

      # Try Hestia AgentRegistry (stores public keys by agent_id)
      # Payment Agents register via MMP, their agent_id may equal their pubkey_hash
      if defined?(Hestia::AgentRegistry)
        registry = Hestia::AgentRegistry
        # Try direct lookup (agent_id == pubkey_hash for Payment Agents)
        key = registry.public_key_for(pubkey_hash) if registry.respond_to?(:public_key_for)
        return key if key

        # Try agent:// prefixed lookup
        key = registry.public_key_for("agent://#{pubkey_hash}") if registry.respond_to?(:public_key_for)
        return key if key
      end

      # Try MMP PeerManager (stores public keys by peer_id)
      if defined?(MMP::PeerManager) && MMP::PeerManager.respond_to?(:instance)
        pm = MMP::PeerManager.instance rescue nil
        if pm
          pm.list_peers.each do |peer|
            next unless peer.public_key
            peer_hash = Digest::SHA256.hexdigest(peer.public_key)
            return peer.public_key if peer_hash == pubkey_hash
          end
        end
      end

      nil
    end

    # --- Authorization ---

    def verify_issuer(proof)
      issuer_hash = Synoptis::TrustIdentity.extract_pubkey_hash(proof.attester_id)
      raise InvalidAttestationError, 'Cannot resolve issuer identity' unless issuer_hash
      unless @authorized_issuers.include?(issuer_hash)
        raise InvalidAttestationError, 'Unauthorized payment issuer'
      end
    end

    # --- Freshness ---

    def verify_freshness(proof)
      issued_at = Time.parse(proof.timestamp).to_i
      age = Time.now.to_i - issued_at
      raise InvalidAttestationError, "Attestation expired (age: #{age}s)" if age > @max_age
      raise InvalidAttestationError, 'Attestation from the future' if age < -60
    rescue ArgumentError, TypeError
      raise InvalidAttestationError, 'Invalid attestation timestamp format'
    end

    # --- Revocation ---

    def verify_not_revoked(proof)
      if @synoptis_registry.revoked?(proof.proof_id)
        raise InvalidAttestationError, 'Attestation has been revoked'
      end
    end

    # --- Evidence parsing ---

    def parse_evidence(proof)
      raise InvalidAttestationError, "Claim must be '#{PAYMENT_CLAIM}'" unless proof.claim == PAYMENT_CLAIM

      evidence = proof.evidence.is_a?(String) ? JSON.parse(proof.evidence) : proof.evidence
      raise InvalidAttestationError, 'Evidence must be a JSON object' unless evidence.is_a?(Hash)

      required = %w[payment_intent_id service plan amount currency nonce]
      missing = required - evidence.keys
      raise InvalidAttestationError, "Missing evidence fields: #{missing.join(', ')}" unless missing.empty?
      evidence
    rescue JSON::ParserError => e
      raise InvalidAttestationError, "Malformed evidence JSON: #{e.message}"
    end

    # --- Nonce ---

    def verify_nonce(evidence)
      nonce = evidence['nonce']
      if nonce.nil? || nonce.to_s.strip.empty?
        raise InvalidAttestationError, 'Nonce is required and must not be empty'
      end
    end

    # --- Payer identity ---

    def extract_payer_pubkey(proof)
      payer = Synoptis::TrustIdentity.extract_pubkey_hash(proof.subject_ref)
      raise InvalidAttestationError, 'Cannot resolve payer identity from subject_ref' unless payer
      payer
    end

    # --- Amount + currency ---

    def verify_amount_matches_plan(evidence)
      plan_price = @plan_registry.subscription_price(evidence['service'], evidence['plan'])
      return unless plan_price  # Free plan upgrades have no price

      if evidence['amount'].to_s != plan_price.to_s
        raise InvalidAttestationError,
          "Amount mismatch: paid #{evidence['amount']} but plan requires #{plan_price}"
      end

      plan_currency = @plan_registry.currency(evidence['service'])
      if evidence['currency'] != plan_currency
        raise InvalidAttestationError,
          "Currency mismatch: paid in #{evidence['currency']} but plan requires #{plan_currency}"
      end
    end

    # --- Idempotency ---

    def find_by_payment_intent(payment_intent_id)
      result = @pg.exec_params(
        'SELECT * FROM payment_records WHERE payment_intent_id = $1',
        [payment_intent_id]
      )
      result.ntuples > 0 ? result[0] : nil
    end

    def validate_idempotent_match!(existing, evidence)
      mismatches = []
      mismatches << 'service' if existing['service'] != evidence['service']
      mismatches << 'plan' if existing['new_plan'] != evidence['plan']
      mismatches << 'amount' if existing['amount'].to_s != evidence['amount'].to_s
      mismatches << 'currency' if existing['currency'] != evidence['currency']
      unless mismatches.empty?
        raise InvalidAttestationError,
          "Conflicting duplicate payment_intent_id: #{mismatches.join(', ')} mismatch"
      end
    end

    # --- Transactional upgrade (all SQL on single connection) ---

    def execute_upgrade_transaction(payer, proof, evidence, payment_intent_id)
      service = evidence['service']
      new_plan = evidence['plan']
      billing_model = @plan_registry.billing_model(service)

      raise PlanNotFoundError, "Plan '#{new_plan}' not found" unless @plan_registry.plan_exists?(service, new_plan)

      @pg.with_connection do |conn|
        conn.exec('BEGIN')
        begin
          # Ensure grant exists (upsert — first-time payer gets free plan)
          version = @plan_registry.current_version(service, 'free')
          conn.exec_params(<<~SQL, [payer, service, version, billing_model])
            INSERT INTO service_grants (pubkey_hash, service, plan, plan_version, billing_model)
            VALUES ($1, $2, 'free', $3, $4)
            ON CONFLICT (pubkey_hash, service) DO NOTHING
          SQL

          # Get current plan
          result = conn.exec_params(
            'SELECT plan FROM service_grants WHERE pubkey_hash = $1 AND service = $2',
            [payer, service]
          )
          old_plan = result.ntuples > 0 ? result[0]['plan'] : 'free'

          # Upgrade plan + set/clear subscription expiry in single UPDATE
          new_version = @plan_registry.current_version(service, new_plan)
          duration = @plan_registry.subscription_duration(service, new_plan)
          if duration
            conn.exec_params(<<~SQL, [new_plan, new_version, duration, payer, service])
              UPDATE service_grants
              SET plan = $1, plan_version = $2,
                  subscription_expires_at = NOW() + INTERVAL '1 day' * $3,
                  last_active_at = NOW()
              WHERE pubkey_hash = $4 AND service = $5
            SQL
          else
            conn.exec_params(<<~SQL, [new_plan, new_version, payer, service])
              UPDATE service_grants
              SET plan = $1, plan_version = $2,
                  subscription_expires_at = NULL,
                  last_active_at = NOW()
              WHERE pubkey_hash = $3 AND service = $4
            SQL
          end

          # Record payment (with provider_tx_id)
          payment_params = [
            payer, service, payment_intent_id, proof.proof_id,
            'attestation', evidence['amount'], evidence['currency'],
            evidence['amount'], old_plan, new_plan, evidence['nonce'],
            evidence['provider_tx_id']
          ]
          conn.exec_params(<<~SQL, payment_params)
            INSERT INTO payment_records
              (pubkey_hash, service, payment_intent_id, attestation_hash,
               payment_type, amount, currency, amount_display,
               old_plan, new_plan, nonce, provider_tx_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
          SQL

          conn.exec('COMMIT')
          { success: true, old_plan: old_plan, new_plan: new_plan }
        rescue StandardError
          conn.exec('ROLLBACK') rescue nil
          raise
        end
      end
    end
  end
end
