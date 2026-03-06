# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require 'time'

module Synoptis
  class ProofEnvelope
    PROOF_VERSION = '1.0.0'

    attr_reader :proof_id, :version, :attester_id, :subject_ref, :claim,
                :evidence, :merkle_root, :signature, :timestamp, :ttl,
                :actor_user_id, :actor_role, :metadata

    def initialize(attrs = {})
      attrs = attrs.transform_keys(&:to_sym) if attrs.is_a?(Hash)
      @proof_id = attrs[:proof_id] || SecureRandom.uuid
      @version = attrs[:version] || PROOF_VERSION
      @attester_id = attrs[:attester_id]
      @subject_ref = attrs[:subject_ref]
      @claim = attrs[:claim]
      @evidence = attrs[:evidence]
      @merkle_root = attrs[:merkle_root]
      @signature = attrs[:signature]
      @timestamp = attrs[:timestamp] || Time.now.utc.iso8601
      @ttl = attrs[:ttl]
      @actor_user_id = attrs[:actor_user_id]
      @actor_role = attrs[:actor_role]
      @metadata = attrs[:metadata] || {}
    end

    def to_h
      {
        proof_id: @proof_id,
        version: @version,
        attester_id: @attester_id,
        subject_ref: @subject_ref,
        claim: @claim,
        evidence: @evidence,
        merkle_root: @merkle_root,
        signature: @signature,
        timestamp: @timestamp,
        ttl: @ttl,
        actor_user_id: @actor_user_id,
        actor_role: @actor_role,
        metadata: @metadata
      }
    end

    # S-C1 fix: Retain nil values as JSON null for canonical form.
    # .compact is intentionally NOT used here — canonical form must be
    # deterministic regardless of which fields are populated.
    def canonical_json
      canonical = {
        proof_id: @proof_id,
        version: @version,
        attester_id: @attester_id,
        subject_ref: @subject_ref,
        claim: @claim,
        evidence: @evidence,
        merkle_root: @merkle_root,
        timestamp: @timestamp,
        ttl: @ttl
      }
      JSON.generate(canonical, sort_keys: true)
    end

    def content_hash
      Digest::SHA256.hexdigest(canonical_json)
    end

    def expired?
      return false unless @ttl
      issued_at = Time.parse(@timestamp)
      Time.now.utc > issued_at + @ttl
    rescue ArgumentError
      false
    end

    # Accepts an MMP::Crypto instance (which holds the private key internally).
    def sign!(crypto)
      return unless crypto
      @signature = crypto.sign(canonical_json)
    end

    def self.from_h(hash)
      hash = hash.transform_keys(&:to_sym) if hash.is_a?(Hash)
      new(hash)
    end
  end
end
