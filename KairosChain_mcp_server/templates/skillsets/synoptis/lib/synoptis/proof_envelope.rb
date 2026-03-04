# frozen_string_literal: true

require 'securerandom'
require 'json'
require 'digest'
require 'time'

module Synoptis
  class ProofEnvelope
    # Fields that form the canonical JSON for signing
    SIGNABLE_FIELDS = %w[
      proof_id claim_type disclosure_level attester_id attestee_id
      subject_ref target_hash evidence_hash merkle_root nonce
      issued_at expires_at
    ].freeze

    attr_accessor :proof_id, :claim_type, :disclosure_level,
                  :attester_id, :attestee_id, :subject_ref,
                  :target_hash, :evidence_hash, :evidence,
                  :merkle_root, :merkle_proof, :nonce,
                  :signature, :attester_pubkey_fingerprint,
                  :transport, :issued_at, :expires_at,
                  :status, :revoke_ref

    def initialize(**attrs)
      @proof_id = attrs[:proof_id] || "att_#{SecureRandom.uuid}"
      @claim_type = attrs[:claim_type]
      @disclosure_level = attrs[:disclosure_level] || 'existence_only'
      @attester_id = attrs[:attester_id]
      @attestee_id = attrs[:attestee_id]
      @subject_ref = attrs[:subject_ref]
      @target_hash = attrs[:target_hash]
      @evidence_hash = attrs[:evidence_hash]
      @evidence = attrs[:evidence]
      @merkle_root = attrs[:merkle_root]
      @merkle_proof = attrs[:merkle_proof]
      @nonce = attrs[:nonce] || SecureRandom.hex(16)
      @signature = attrs[:signature]
      @attester_pubkey_fingerprint = attrs[:attester_pubkey_fingerprint]
      @transport = attrs[:transport] || 'local'
      @issued_at = attrs[:issued_at] || Time.now.utc.iso8601
      @expires_at = attrs[:expires_at]
      @status = attrs[:status] || 'active'
      @revoke_ref = attrs[:revoke_ref]
    end

    # Generate canonical JSON for signature target (sorted keys, deterministic)
    def canonical_json
      signable = {}
      SIGNABLE_FIELDS.each do |field|
        value = send(field.to_sym)
        signable[field] = value unless value.nil?
      end
      JSON.generate(signable.sort.to_h)
    end

    # Sign the envelope using MMP::Crypto instance
    def sign!(crypto)
      @attester_pubkey_fingerprint = crypto.key_fingerprint
      @signature = crypto.sign(canonical_json)
      self
    end

    # Verify signature against a public key (PEM string or OpenSSL::PKey)
    def valid_signature?(public_key_or_crypto)
      return false unless @signature

      if public_key_or_crypto.respond_to?(:verify_signature)
        public_key_or_crypto.verify_signature(canonical_json, @signature)
      else
        require 'openssl'
        require 'base64'
        key = public_key_or_crypto.is_a?(String) ? OpenSSL::PKey::RSA.new(public_key_or_crypto) : public_key_or_crypto
        data_bytes = canonical_json
        key.verify(OpenSSL::Digest.new('SHA256'), Base64.strict_decode64(@signature), data_bytes)
      end
    end

    def expired?
      return false unless @expires_at

      Time.parse(@expires_at.to_s) < Time.now.utc
    end

    def revoked?
      @status == 'revoked'
    end

    def active?
      @status == 'active' && !expired?
    end

    def to_h
      {
        proof_id: @proof_id,
        claim_type: @claim_type,
        disclosure_level: @disclosure_level,
        attester_id: @attester_id,
        attestee_id: @attestee_id,
        subject_ref: @subject_ref,
        target_hash: @target_hash,
        evidence_hash: @evidence_hash,
        evidence: @evidence,
        merkle_root: @merkle_root,
        merkle_proof: @merkle_proof,
        nonce: @nonce,
        signature: @signature,
        attester_pubkey_fingerprint: @attester_pubkey_fingerprint,
        transport: @transport,
        issued_at: @issued_at,
        expires_at: @expires_at,
        status: @status,
        revoke_ref: @revoke_ref
      }.compact
    end

    def to_json(*_args)
      JSON.generate(to_h)
    end

    def self.from_h(hash)
      h = hash.transform_keys(&:to_sym)
      # Deep symbolize merkle_proof entries for MerkleTree compatibility
      if h[:merkle_proof].is_a?(Array)
        h[:merkle_proof] = h[:merkle_proof].map do |step|
          step.is_a?(Hash) ? step.transform_keys(&:to_sym) : step
        end
      end
      # Deep symbolize evidence if it's a hash
      if h[:evidence].is_a?(Hash)
        h[:evidence] = h[:evidence].transform_keys(&:to_sym)
      end
      new(**h)
    end

    # Convert to Hestia::Chain::Core::Anchor format (when Hestia is available)
    def to_anchor
      return nil unless defined?(Hestia::Chain::Core::Anchor)

      Hestia::Chain::Core::Anchor.new(
        anchor_type: 'audit',
        source_id: @attester_id,
        target_id: @attestee_id,
        data_hash: @evidence_hash,
        metadata: {
          proof_id: @proof_id,
          claim_type: @claim_type,
          subject_ref: @subject_ref,
          merkle_root: @merkle_root
        }
      )
    end
  end
end
