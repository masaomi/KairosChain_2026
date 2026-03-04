# frozen_string_literal: true

module Synoptis
  class Verifier
    def initialize(registry: nil, config: nil)
      @registry = registry
      @config = config || Synoptis.default_config
    end

    # Composite verification of a ProofEnvelope
    # options:
    #   public_key: PEM string or OpenSSL::PKey for signature verification
    #   check_revocation: boolean (default: true) — internal use only for signature_only mode
    #   check_expiry: boolean (default: true) — internal use only for signature_only mode
    #   check_merkle: boolean (default: false)
    # NOTE: Per security requirements (Plan §17), revocation and expiry checks must
    # not be skipped in normal verification. The check_revocation/check_expiry options
    # exist solely for the attestation_verify tool's signature_only mode.
    def verify(proof, options = {})
      reasons = []
      trust_hints = {}

      # 1. Signature verification
      public_key = options[:public_key]
      if public_key
        unless proof.valid_signature?(public_key)
          reasons << 'signature_invalid'
        end
      else
        reasons << 'no_public_key_provided'
        trust_hints[:note] = 'Signature not verified — no public key supplied'
      end

      # 2. Evidence hash verification
      if proof.evidence && proof.evidence_hash
        computed = "sha256:#{Digest::SHA256.hexdigest(proof.evidence.is_a?(String) ? proof.evidence : JSON.generate(proof.evidence))}"
        if computed != proof.evidence_hash
          reasons << 'evidence_hash_mismatch'
        end
      end

      # 3. Revocation check
      if options.fetch(:check_revocation, true)
        if proof.revoked?
          reasons << 'revoked'
        elsif @registry && @registry.respond_to?(:find_revocation)
          revocation = @registry.find_revocation(proof.proof_id)
          if revocation
            reasons << 'revoked'
            trust_hints[:revoked_at] = revocation[:revoked_at]
            trust_hints[:revoke_reason] = revocation[:reason]
          end
        end
      end

      # 4. Expiry check
      if options.fetch(:check_expiry, true) && proof.expired?
        reasons << 'expired'
      end

      # 5. Merkle proof verification (optional)
      # Merkle tree is built from evidence.values; verify requires the original leaf value
      if options[:check_merkle] && proof.merkle_proof && proof.merkle_root
        merkle_proof = proof.merkle_proof.map { |step| step.transform_keys(&:to_sym) }
        if proof.evidence.is_a?(Hash) && !proof.evidence.empty?
          leaf_value = proof.evidence.values.first.to_s
          unless MerkleTree.verify(leaf_value, merkle_proof, proof.merkle_root)
            reasons << 'merkle_proof_invalid'
          end
        else
          # Cannot verify merkle proof without evidence (existence_only mode)
          reasons << 'merkle_proof_unverifiable' unless proof.disclosure_level == 'existence_only'
        end
      end

      # 6. Claim type validation
      unless ClaimTypes.valid_claim_type?(proof.claim_type)
        reasons << 'unknown_claim_type'
      end

      {
        valid: reasons.empty?,
        reasons: reasons,
        trust_hints: trust_hints
      }
    end
  end
end
