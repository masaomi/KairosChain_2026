# frozen_string_literal: true

require 'securerandom'
require 'time'

module Synoptis
  class RevocationManager
    def initialize(registry:)
      @registry = registry
    end

    # Revoke an attestation proof
    def revoke(proof_id, reason, revoked_by)
      raise ArgumentError, 'proof_id is required' if proof_id.nil? || proof_id.empty?
      raise ArgumentError, 'reason is required' if reason.nil? || reason.empty?

      # Verify the proof exists and check authorization
      proof = @registry.find_proof(proof_id)
      raise ArgumentError, "Proof #{proof_id} not found" unless proof

      # Only the attester or attestee may revoke
      unless revoked_by == proof[:attester_id] || revoked_by == proof[:attestee_id]
        raise ArgumentError, "Not authorized to revoke proof #{proof_id}: must be attester or attestee"
      end

      # Check if already revoked
      existing = @registry.find_revocation(proof_id)
      raise "Proof #{proof_id} is already revoked" if existing

      revocation = {
        revocation_id: "rev_#{SecureRandom.uuid}",
        proof_id: proof_id,
        reason: reason,
        revoked_by: revoked_by,
        revoked_at: Time.now.utc.iso8601
      }

      @registry.save_revocation(revocation)

      # Update proof status
      proof_data = proof.is_a?(Hash) ? proof : proof.to_h
      proof_data[:status] = 'revoked'
      proof_data[:revoke_ref] = { reason: reason, revoked_at: revocation[:revoked_at] }
      @registry.update_proof_status(proof_id, 'revoked', proof_data[:revoke_ref]) if @registry.respond_to?(:update_proof_status)

      revocation
    end

    # Check if a proof has been revoked
    def revoked?(proof_id)
      !@registry.find_revocation(proof_id).nil?
    end

    # Get the revocation record for a proof
    def revocation_for(proof_id)
      @registry.find_revocation(proof_id)
    end
  end
end
