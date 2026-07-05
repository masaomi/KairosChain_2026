# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require 'time'

module Synoptis
  module Constitutive
    # A single content-attestation entry on the L2 attestation chain (design v0.9,
    # §Kinds / LED-3). It commits (subject_id, digest, moment) and may embed an
    # optional content snapshot.
    #
    # Deliberately carries NO signature and NO ttl: the entry is workflow-approved
    # (ACT-1), not crypto-gated, and an attestation entry does not expire (design §11).
    # This is posture parity with L0/L1 (LED-6), not a regression against Synoptis's
    # signed ProofEnvelope — it is a different kind for a different purpose.
    class ContentAttestationEntry
      KIND = 'content_attestation'
      DEFAULT_DIGEST_ALG = 'sha256'

      attr_reader :entry_id, :subject_id, :digest, :digest_alg, :moment, :snapshot

      def initialize(subject_id:, digest:, moment:, digest_alg: DEFAULT_DIGEST_ALG,
                     snapshot: nil, entry_id: nil)
        @entry_id = entry_id || SecureRandom.uuid
        @subject_id = subject_id
        @digest = digest
        @digest_alg = digest_alg
        @moment = moment
        @snapshot = snapshot
      end

      def to_h
        {
          kind: KIND,
          entry_id: @entry_id,
          subject_id: @subject_id,
          digest: @digest,
          digest_alg: @digest_alg,
          moment: @moment,
          snapshot: @snapshot
        }
      end

      # Deterministic canonical form for hashing. A nil snapshot is retained as JSON
      # null (no .compact) so the hash is stable regardless of which optional fields
      # are populated — same discipline as ProofEnvelope#canonical_json.
      def canonical_json
        JSON.generate(to_h, sort_keys: true)
      end

      def entry_hash
        Digest::SHA256.hexdigest(canonical_json)
      end

      def self.from_h(hash)
        hash = hash.transform_keys(&:to_sym) if hash.is_a?(Hash)
        new(
          subject_id: hash[:subject_id],
          digest: hash[:digest],
          moment: hash[:moment],
          digest_alg: hash[:digest_alg] || DEFAULT_DIGEST_ALG,
          snapshot: hash[:snapshot],
          entry_id: hash[:entry_id]
        )
      end
    end
  end
end
