# frozen_string_literal: true

require 'digest'
require_relative 'entry'

module Synoptis
  module Anchoring
    # Attestation type vocabulary (aud_l2_mutual_anchoring_design v0.5 MAP-4)
    # under map-1 §3: producer-side validation of declared types at intake, and
    # the retraction coherence check the convention promises. This is the
    # "map-1 module" Entry defers vocabulary validation to.
    module AttestationTypes
      # The normative vocabulary (map-1 §3). Extension is a new convention.
      VOCABULARY = %w[observation quality-endorsement succession-designation retraction].freeze
      RETRACTION = 'retraction'
      TARGET_KEY = 'target_entry_hash'
      HEX_DIGEST = /\A[a-f0-9]{64}\z/

      class VocabularyError < StandardError; end

      module_function

      # Producer-side intake validation (map-1 §3). +attestation_type+ nil is
      # a pre-map-1 untyped entry and passes; a declared type must come from
      # the vocabulary, and a retraction must identify its target unambiguously
      # in metadata. Refuse-not-coerce: violations raise.
      def validate_intake!(attestation_type, metadata)
        return true if attestation_type.nil?

        t = attestation_type.to_s
        unless VOCABULARY.include?(t)
          raise VocabularyError, "attestation_type #{t.inspect} is not in the map-1 vocabulary (#{VOCABULARY.join(', ')})"
        end
        return true unless t == RETRACTION

        m = (metadata || {})
        m = m.transform_keys(&:to_s) if m.is_a?(Hash)
        raise VocabularyError, 'retraction metadata must be a Hash carrying its target reference' unless m.is_a?(Hash)

        # map-1 §3: an anchor-log retraction targets an anchor-log entry, and
        # ONLY that — a reference no verifier on this surface can resolve
        # (e.g. an internal-chain record digest) must not be appendable as a
        # "valid" retraction, not even alongside a resolvable one. Internal-
        # chain retraction is §4's record form.
        if m.key?('target_record_sha256')
          raise VocabularyError,
                'anchor-log retraction must not carry metadata.target_record_sha256 (internal-chain take-backs are map-1 §4 records)'
        end
        value = m[TARGET_KEY]
        unless value.is_a?(String) && value.match?(HEX_DIGEST)
          raise VocabularyError, "retraction must carry metadata.#{TARGET_KEY} as 64-char lowercase hex (map-1 §3)"
        end

        true
      end

      # Retraction coherence over anchor-log entries (map-1 §3): diagnostic,
      # never raises on hostile input. +retraction_h+ and +target_h+ are entry
      # hashes-of-the-record shape (Entry#to_h). Coherent iff the retraction is
      # a typed retraction anchor entry whose metadata.target_entry_hash equals
      # the target's entry_hash and whose depositor equals the target's
      # depositor (issuer at map-1 = committed depositor; credential-level
      # binding is deferred, disclosed in the convention).
      def retraction_coherence(retraction_h, target_h)
        mismatches = []
        r = shape(retraction_h)
        t = shape(target_h)
        rbody = r['body'].is_a?(Hash) ? r['body'] : {}
        tbody = t['body'].is_a?(Hash) ? t['body'] : {}

        mismatches << 'retraction is not an anchor entry' unless r['kind'] == 'anchor'
        mismatches << "retraction attestation_type is #{rbody['attestation_type'].inspect}, not retraction" unless rbody['attestation_type'] == RETRACTION
        meta = rbody['metadata'].is_a?(Hash) ? rbody['metadata'].transform_keys(&:to_s) : {}
        target_ref = meta['target_entry_hash']
        if target_ref.nil?
          mismatches << 'retraction carries no metadata.target_entry_hash'
        elsif target_ref != t['entry_hash']
          mismatches << "target_entry_hash #{target_ref.inspect} does not match target entry_hash"
        end
        if rbody['depositor'].nil? || rbody['depositor'] != tbody['depositor']
          mismatches << "retraction depositor #{rbody['depositor'].inspect} does not equal target depositor #{tbody['depositor'].inspect} (issuer-only at map-1 = depositor equality)"
        end
        # Retraction of a retraction is not recognized (map-1 §3): a retracted
        # claim stays retracted.
        if tbody['attestation_type'] == RETRACTION
          mismatches << 'target is itself a retraction (retraction of a retraction is not recognized, map-1 §3)'
        end
        # Append-order sanity: a retraction cannot precede what it takes back.
        # Missing/malformed positions are themselves a mismatch — a fabricated
        # log must not pass by omitting the field the check needs.
        if r['position'].is_a?(Integer) && t['position'].is_a?(Integer)
          if r['position'] <= t['position']
            mismatches << "retraction position #{r['position']} is not after target position #{t['position']}"
          end
        else
          mismatches << 'retraction and target positions must both be Integers'
        end

        { coherent: mismatches.empty?, mismatches: mismatches }
      end

      def shape(entry_h)
        entry_h.is_a?(Hash) ? entry_h.transform_keys(&:to_s) : {}
      end
    end
  end
end
