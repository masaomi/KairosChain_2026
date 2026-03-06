# frozen_string_literal: true

module Synoptis
  class RevocationManager
    def initialize(registry:, config: {})
      @registry = registry
      @config = config
    end

    # Identity resolution uses MMP::Identity#instance_id (Critical-2 fix).
    # actor_user_id from @safety.current_user[:user] for audit (High-1 fix).
    def revoke(proof_id:, reason:, revoker_id:, actor_user_id: nil, actor_role: nil)
      envelope = @registry.find_proof(proof_id)
      return { status: 'error', message: 'Proof not found' } unless envelope

      if @registry.revoked?(proof_id)
        return { status: 'error', message: 'Already revoked' }
      end

      unless revoker_id.to_s == envelope.attester_id.to_s || actor_role == 'admin'
        return { status: 'error', message: 'Not authorized to revoke this attestation' }
      end

      revocation = {
        proof_id: proof_id,
        revoker_id: revoker_id.to_s,
        reason: reason,
        actor_user_id: actor_user_id,
        actor_role: actor_role,
        timestamp: Time.now.utc.iso8601
      }

      @registry.store_revocation(revocation)
      { status: 'revoked', proof_id: proof_id, revocation: revocation }
    end
  end
end
