# frozen_string_literal: true

module ServiceGrant
  class PaymentVerifier
    ATTESTATION_MAX_AGE = 86_400  # 24 hours

    def initialize(grant_manager:, pg_pool:)
      @grant_manager = grant_manager
      @pg = pg_pool
    end

    # @param attestation [Hash] Must include:
    #   :hash           - attestation hash (Synoptis)
    #   :payment_intent_id - stable payment identifier (NOT attestation hash)
    #   :issued_at      - attestation creation timestamp
    #   :payer_pubkey_hash - payer identity
    #   :service        - target service
    #   :plan           - target plan
    #   :amount         - payment amount (string, e.g., "9.99")
    #   :currency       - payment currency
    #   :nonce          - one-time nonce
    def verify_and_upgrade(attestation)
      # 1. Expiry check
      age = Time.now.to_i - attestation[:issued_at].to_i
      raise InvalidAttestationError, "Attestation expired (age: #{age}s)" if age > ATTESTATION_MAX_AGE
      raise InvalidAttestationError, "Attestation from the future" if age < -60

      # 2. Duplicate check by payment_intent_id (NOT attestation_hash)
      existing = find_by_payment_intent(attestation[:payment_intent_id])
      if existing
        validate_idempotent_match!(existing, attestation)
        return { success: true, idempotent: true }
      end

      # 3. Attestation signature verification (Synoptis) — Phase 3
      # 4. Amount/plan/service consistency check
      verify_amount_matches_plan(attestation)

      # 5. Upgrade grant
      old_plan = @grant_manager.get_grant(
        attestation[:payer_pubkey_hash], service: attestation[:service]
      )&.dig(:plan) || 'free'

      @grant_manager.upgrade_plan(
        attestation[:payer_pubkey_hash],
        service: attestation[:service],
        new_plan: attestation[:plan]
      )

      # 6. Record payment (idempotent via UNIQUE on payment_intent_id)
      record_payment(attestation, old_plan: old_plan)

      { success: true, old_plan: old_plan, new_plan: attestation[:plan] }
    rescue PG::UniqueViolation
      # Concurrent duplicate -- validate and return idempotent success
      existing = find_by_payment_intent(attestation[:payment_intent_id])
      validate_idempotent_match!(existing, attestation) if existing
      { success: true, idempotent: true }
    end

    private

    def find_by_payment_intent(payment_intent_id)
      result = @pg.exec_params(
        "SELECT * FROM payment_records WHERE payment_intent_id = $1",
        [payment_intent_id]
      )
      result.ntuples > 0 ? result[0] : nil
    end

    def validate_idempotent_match!(existing, attestation)
      mismatches = []
      mismatches << "payer" if existing['pubkey_hash'] != attestation[:payer_pubkey_hash]
      mismatches << "service" if existing['service'] != attestation[:service]
      mismatches << "plan" if existing['new_plan'] != attestation[:plan]
      mismatches << "amount" if existing['amount'].to_s != attestation[:amount].to_s
      unless mismatches.empty?
        raise InvalidAttestationError,
          "Conflicting duplicate payment_intent_id: #{mismatches.join(', ')} mismatch"
      end
    end

    def verify_amount_matches_plan(attestation)
      plan_price = @grant_manager.plan_registry.subscription_price(
        attestation[:service], attestation[:plan]
      )
      if plan_price && attestation[:amount].to_s != plan_price.to_s
        raise InvalidAttestationError,
          "Amount mismatch: paid #{attestation[:amount]} but plan requires #{plan_price}"
      end
    end

    def record_payment(attestation, old_plan:)
      @pg.exec_params(<<~SQL, [
        attestation[:payer_pubkey_hash],
        attestation[:service],
        attestation[:payment_intent_id],
        attestation[:hash],
        attestation[:payment_type] || 'attestation',
        attestation[:amount],
        attestation[:currency] || 'USD',
        attestation[:amount_display],
        old_plan,
        attestation[:plan],
        attestation[:nonce]
      ])
        INSERT INTO payment_records
          (pubkey_hash, service, payment_intent_id, attestation_hash,
           payment_type, amount, currency, amount_display,
           old_plan, new_plan, nonce)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      SQL
    end
  end
end
