# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require 'time'

module Synoptis
  module Constitutive
    # A revocation-withdrawal entry on the L2 attestation chain (design v0.9, §Kinds /
    # LED-2b / LED-3). It commits (subject_id, target_ref, moment) and marks the
    # referenced target entry withdrawn.
    #
    # It commits NO digest and NO content (§Kinds): a withdrawal is not a claim about
    # bytes, it is an act upon a prior entry. Like the content-attestation entry it lives
    # in the same attestation ledger and requires human approval (ACT-1); revocation is
    # itself an append, never an edit, so "what was claimed, and that it was later
    # withdrawn" survives its own withdrawal (LED-2).
    class RevocationWithdrawalEntry
      KIND = 'revocation_withdrawal'

      attr_reader :entry_id, :subject_id, :target_ref, :moment

      def initialize(subject_id:, target_ref:, moment:, entry_id: nil)
        @entry_id = entry_id || SecureRandom.uuid
        @subject_id = subject_id
        @target_ref = target_ref
        @moment = moment
      end

      def to_h
        {
          kind: KIND,
          entry_id: @entry_id,
          subject_id: @subject_id,
          target_ref: @target_ref,
          moment: @moment
        }
      end

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
          target_ref: hash[:target_ref],
          moment: hash[:moment],
          entry_id: hash[:entry_id]
        )
      end
    end
  end
end
