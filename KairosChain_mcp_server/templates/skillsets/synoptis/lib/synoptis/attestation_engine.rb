# frozen_string_literal: true

module Synoptis
  class AttestationEngine
    def initialize(registry:, config: {})
      @registry = registry
      @config = config
      @default_ttl = (config[:default_ttl] || config['default_ttl'] || 86400).to_i
      # fetch's default argument is evaluated eagerly, so a key present but
      # holding nil used to yield nil — falsy — and silently disabled both this
      # refusal and the Verifier's missing_signature. An unset or empty value
      # must mean "required".
      raw = config.key?(:require_signature) ? config[:require_signature] : config['require_signature']
      @require_signature = raw.nil? ? true : raw
      @verifier = Verifier.new(config: { require_signature: @require_signature })
    end

    # submitter_pubkey names the party that handed the anchor this content, as
    # distinct from attester_id, which names the anchor that recorded it. It
    # enters the canonical form (envelope version 1.1.0) and is therefore
    # covered by the signature rather than being a display-only field.
    def create_attestation(attester_id:, subject_ref:, claim:, evidence: nil,
                           merkle_root: nil, ttl: nil, actor_user_id: nil, actor_role: nil,
                           crypto: nil, submitter_pubkey: nil)
      # The engine is the object configured with require_signature, so the
      # refusal belongs here rather than in each caller. Without it, storing
      # succeeds and reports 'created' while Verifier answers missing_signature
      # for the same proof forever after — the defect this guard closes for
      # every caller at once, not only the one that was patched.
      if @require_signature && crypto.nil?
        return {
          status: 'error',
          message: 'signing key unavailable; refusing to store a proof that could never verify'
        }
      end

      # A proof whose attester cannot be named is attributable to nobody and
      # revocable by nobody, since RevocationManager authorises on
      # revoker_id == attester_id. The check belongs beside the signing one:
      # both are about whether the record can mean anything once stored.
      if attester_id.nil? || attester_id.to_s.strip.empty?
        return {
          status: 'error',
          message: 'attester identity unavailable; refusing to store an unattributable proof'
        }
      end

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
        submitter_pubkey: submitter_pubkey,
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
