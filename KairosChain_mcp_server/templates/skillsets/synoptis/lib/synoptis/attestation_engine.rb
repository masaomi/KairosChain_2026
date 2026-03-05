# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'json'
require 'time'

module Synoptis
  class AttestationEngine
    attr_reader :config, :registry, :verifier, :revocation_manager
    attr_accessor :transport_router

    def initialize(config: nil, registry: nil)
      @config = config || Synoptis.default_config
      @registry = registry
      @verifier = Verifier.new(registry: registry, config: @config)
      @revocation_manager = RevocationManager.new(registry: registry) if registry
    end

    # Create an attestation request to send to the target agent
    def create_request(target_id, claim_type, subject_ref, disclosure_level = 'existence_only')
      raise ArgumentError, "Invalid claim_type: #{claim_type}" unless ClaimTypes.valid_claim_type?(claim_type)
      raise ArgumentError, "Invalid disclosure_level: #{disclosure_level}" unless ClaimTypes.valid_disclosure_level?(disclosure_level)

      {
        request_id: "req_#{SecureRandom.uuid}",
        target_id: target_id,
        claim_type: claim_type,
        subject_ref: subject_ref,
        disclosure_level: disclosure_level,
        nonce: SecureRandom.hex(16),
        created_at: Time.now.utc.iso8601
      }
    end

    # Build a signed ProofEnvelope from a request and evidence
    def build_proof(request, evidence, crypto, attester_id:)
      attestee_id = request[:target_id]

      # Self-attestation check
      allow_self = @config.dig('attestation', 'allow_self_attestation')
      if !allow_self && attester_id == attestee_id
        raise ArgumentError, 'Self-attestation is not allowed'
      end

      # Check for revoked proof with same (attester, attestee, claim_type, subject_ref)
      if @registry
        existing = @registry.list_proofs({}).select do |p|
          p[:attester_id] == attester_id &&
            p[:attestee_id] == attestee_id &&
            p[:claim_type] == request[:claim_type] &&
            p[:subject_ref] == request[:subject_ref] &&
            p[:status] == 'revoked'
        end
        unless existing.empty?
          raise ArgumentError, 'Cannot re-issue attestation for a previously revoked proof with same attester, attestee, claim_type, and subject_ref'
        end
      end

      # Validate min_evidence_fields
      min_fields = @config.dig('attestation', 'min_evidence_fields') || 2
      if evidence.is_a?(Hash) && evidence.size < min_fields
        raise ArgumentError, "Evidence must have at least #{min_fields} fields (got #{evidence.size})"
      end

      # Compute evidence hash
      evidence_json = evidence.is_a?(String) ? evidence : JSON.generate(evidence)
      evidence_hash = "sha256:#{Digest::SHA256.hexdigest(evidence_json)}"

      # Compute target hash (hash of subject reference for integrity)
      target_hash = "sha256:#{Digest::SHA256.hexdigest(request[:subject_ref].to_s)}"

      # Build Merkle tree from evidence fields if possible
      merkle_root = nil
      merkle_proof = nil
      if evidence.is_a?(Hash) && evidence.size > 1
        leaves = evidence.values.map { |v| v.to_s }
        tree = MerkleTree.new(leaves)
        merkle_root = tree.root
        merkle_proof = tree.proof_for(0) # proof for first leaf
      end

      # Calculate expiry
      expiry_days = @config.dig('attestation', 'default_expiry_days') || 180
      expires_at = (Time.now.utc + (expiry_days * 86400)).iso8601

      # Build envelope
      proof = ProofEnvelope.new(
        claim_type: request[:claim_type],
        disclosure_level: request[:disclosure_level],
        attester_id: attester_id,
        attestee_id: attestee_id,
        subject_ref: request[:subject_ref],
        target_hash: target_hash,
        evidence_hash: evidence_hash,
        evidence: request[:disclosure_level] == 'full' ? evidence : nil,
        merkle_root: merkle_root,
        merkle_proof: merkle_proof,
        nonce: request[:nonce],
        expires_at: expires_at
      )

      # Sign
      proof.sign!(crypto)

      # Store
      @registry.save_proof(proof.to_h) if @registry

      proof
    end

    # Verify a proof (delegates to Verifier)
    def verify_proof(proof, options = {})
      proof = ProofEnvelope.from_h(proof) if proof.is_a?(Hash)
      @verifier.verify(proof, options)
    end

    # Revoke a proof (delegates to RevocationManager)
    def revoke_proof(proof_id, reason, revoked_by)
      raise 'No registry configured' unless @revocation_manager

      @revocation_manager.revoke(proof_id, reason, revoked_by)
    end
  end
end
