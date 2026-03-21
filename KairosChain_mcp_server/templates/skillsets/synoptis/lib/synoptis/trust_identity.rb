# frozen_string_literal: true

module Synoptis
  # Canonical trust subject identity for cross-SkillSet trust resolution.
  #
  # Maps between pubkey_hash (Service Grant identity) and attestation
  # subject_ref/attester_id (Synoptis identity). Enables PageRank-based
  # trust scoring across the attestation graph.
  #
  # Canonical URI: agent://<pubkey_hash>
  #
  # IMPORTANT: Only 64-character lowercase hex strings (SHA-256 hashes)
  # are recognized as agent identities. Non-agent refs (skill://, place://,
  # knowledge/*, etc.) are left untouched by normalize().
  module TrustIdentity
    PREFIX = 'agent://'.freeze
    # SHA-256 hex: exactly 64 lowercase hex characters
    PUBKEY_HASH_PATTERN = /\A[0-9a-f]{64}\z/.freeze

    # Is this ref an agent identity (pubkey_hash or agent:// URI)?
    def self.agent_ref?(ref)
      return false unless ref
      return true if ref.start_with?(PREFIX)
      PUBKEY_HASH_PATTERN.match?(ref)
    end

    # Convert pubkey_hash to canonical URI
    def self.canonical(pubkey_hash)
      return nil unless pubkey_hash
      pubkey_hash.start_with?(PREFIX) ? pubkey_hash : "#{PREFIX}#{pubkey_hash}"
    end

    # Extract pubkey_hash from canonical URI or raw hash
    def self.extract_pubkey_hash(ref)
      return nil unless ref
      if ref.start_with?(PREFIX)
        ref.sub(PREFIX, '')
      elsif PUBKEY_HASH_PATTERN.match?(ref)
        ref
      end
      # Returns nil for non-agent refs (skill://, knowledge/*, etc.)
    end

    # Normalize a ref to canonical form IF it is an agent identity.
    # Non-agent refs (skill://, place://, etc.) are returned unchanged.
    def self.normalize(ref)
      return nil unless ref
      return ref unless agent_ref?(ref)
      hash = extract_pubkey_hash(ref)
      hash ? canonical(hash) : ref
    end
  end
end
