# frozen_string_literal: true

module Synoptis
  class AttestationEngine
    def initialize(registry:, config: {})
      @registry = registry
      @config = config
      @default_ttl = (config[:default_ttl] || config['default_ttl'] || 86400).to_i
      @require_signature = config.fetch(:require_signature, config.fetch('require_signature', true))
      @verifier = Verifier.new(config: { require_signature: @require_signature })
    end

    def create_attestation(attester_id:, subject_ref:, claim:, evidence: nil,
                           merkle_root: nil, ttl: nil, actor_user_id: nil, actor_role: nil,
                           crypto: nil)
      # S-C4 fix: Duplicate detection is strictly registry-dependent
      existing = @registry.list_proofs(filter: {
        attester_id: attester_id.to_s,
        subject_ref: subject_ref.to_s,
        claim: claim.to_s
      })
      non_revoked = existing.reject { |e| @registry.revoked?(e.proof_id) || e.expired? }
      unless non_revoked.empty?
        return {
          status: 'error',
          message: 'Active attestation already exists for this claim',
          existing_proof_id: non_revoked.first.proof_id
        }
      end

      envelope = ProofEnvelope.new(
        attester_id: attester_id.to_s,
        subject_ref: subject_ref.to_s,
        claim: claim.to_s,
        evidence: evidence,
        merkle_root: merkle_root,
        ttl: ttl || @default_ttl,
        actor_user_id: actor_user_id,
        actor_role: actor_role,
        timestamp: Time.now.utc.iso8601
      )

      envelope.sign!(crypto) if crypto

      @registry.store_proof(envelope)

      {
        status: 'created',
        proof_id: envelope.proof_id,
        content_hash: envelope.content_hash,
        envelope: envelope.to_h
      }
    end

    def verify_attestation(proof_id, public_key: nil)
      envelope = @registry.find_proof(proof_id)
      return { status: 'error', message: 'Proof not found' } unless envelope

      if @registry.revoked?(proof_id)
        return { status: 'revoked', proof_id: proof_id }
      end

      result = @verifier.verify(envelope, public_key: public_key)
      result.merge(proof_id: proof_id)
    end

    def list_attestations(filter: {})
      @registry.list_proofs(filter: filter).map do |envelope|
        {
          proof_id: envelope.proof_id,
          attester_id: envelope.attester_id,
          subject_ref: envelope.subject_ref,
          claim: envelope.claim,
          timestamp: envelope.timestamp,
          expired: envelope.expired?,
          revoked: @registry.revoked?(envelope.proof_id)
        }
      end
    end
  end
end
