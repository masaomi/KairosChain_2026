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
    #
    # A `target_ref` (Slice 2, LED-2b) marks this entry a SUPERSESSION: it commits the
    # entry_id of the prior entry it supersedes. The first content-attestation about a
    # subject carries none; a re-attestation of an already-attested subject is a
    # supersession (§Kinds).
    class ContentAttestationEntry
      KIND = 'content_attestation'
      DEFAULT_DIGEST_ALG = 'sha256'

      attr_reader :entry_id, :subject_id, :digest, :digest_alg, :moment, :snapshot, :target_ref

      def initialize(subject_id:, digest:, moment:, digest_alg: DEFAULT_DIGEST_ALG,
                     snapshot: nil, entry_id: nil, target_ref: nil)
        @entry_id = entry_id || SecureRandom.uuid
        @subject_id = subject_id
        @digest = digest
        @digest_alg = digest_alg
        @moment = moment
        @snapshot = snapshot
        @target_ref = target_ref
      end

      # A supersession points at the entry it supersedes (LED-2b).
      def supersession?
        !@target_ref.nil?
      end

      def to_h
        {
          kind: KIND,
          entry_id: @entry_id,
          subject_id: @subject_id,
          digest: @digest,
          digest_alg: @digest_alg,
          moment: @moment,
          snapshot: @snapshot,
          target_ref: @target_ref
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
          entry_id: hash[:entry_id],
          target_ref: hash[:target_ref]
        )
      end
    end
  end
end
