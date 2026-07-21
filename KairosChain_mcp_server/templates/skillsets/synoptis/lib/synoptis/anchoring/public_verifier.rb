# frozen_string_literal: true

require_relative 'log'

module Synoptis
  module Anchoring
    # The shared verification-record producer (ANC-7 / ANC-8).
    #
    # It turns an anchor entry into the honest public record a verifier reads:
    # the digest and how it was computed, when/where/by whom it was recorded, its
    # chain position, a navigable retrieval pointer (for a not-withdrawn entry),
    # the foreign/same-party relation with its disclosed limit (ANC-8), and the
    # proof-scope statement (ANC-7).
    #
    # This is deliberately AUTH-FREE. Slice 1's authenticated ReadPath delegates
    # to it behind an auth gate; slice 2's public WebRouter view uses it directly
    # (the public verification view is unauthenticated by ANC-7). One record
    # producer, two surfaces — so the two can never drift.
    class PublicVerifier
      # ANC-7's honest proof-scope statement. A match says only what it can.
      PROOF_SCOPE =
        'A digest match proves only that this digest was recorded by this depositor at this ' \
        'place at this moment. It does NOT prove authorship, quality, that the bytes behind the ' \
        'digest ever existed, or that the external reference is honest.'

      # ANC-8's disclosed limit: the relation label is only as trustworthy as the
      # operator's identity issuance, and a foreign anchor's external credibility
      # additionally rests on independent head publication (scope Y).
      RELATION_DISCLOSURE =
        "This distinction is only as trustworthy as the operator's identity issuance; a foreign " \
        "anchor's external credibility additionally rests on independent head publication, which " \
        'this scope does not yet provide.'

      def initialize(log:, board: nil)
        @log = log
        @board = board
      end

      # Verify a digest: a record per anchor entry committing it (empty if none).
      def verify_digest(digest)
        @log.find_by_digest(digest).map { |entry| record(entry) }
      end

      # Resolve by the content-independent verification address (source_id).
      def by_source_id(source_id)
        @log.find_by_source_id(source_id).select(&:anchor?).map { |entry| record(entry) }
      end

      # Record for a specific entry id (nil for unknown / non-anchor).
      def get(entry_hash)
        entry = @log.get(entry_hash.to_s)
        return nil unless entry && entry.anchor?

        record(entry)
      end

      private

      def record(entry)
        view = @log.view(entry.entry_hash)
        withdrawn = view['withdrawn']
        body = view['body']
        {
          entry_hash: entry.entry_hash,
          digest: entry.digest,
          digest_algorithm: body['digest_algorithm'],
          canonicalization: body['canonicalization'],
          position: entry.position,
          depositor: entry.depositor,
          moment: body['moment'],
          withdrawn: withdrawn,
          # BRD-4: pointer suppressed on withdrawal; the proof does not need it.
          retrieval_pointer: withdrawn ? nil : body['external_reference'],
          source_id: withdrawn ? nil : body['source_id'],
          relation: relation_for(entry),
          relation_disclosure: RELATION_DISCLOSURE,
          proof_scope: PROOF_SCOPE,
          # MPR-1: the committed head binding, surfaced verbatim for auditors.
          # Structural committed state like the digest itself, so it stays
          # visible on withdrawal (only depositor-supplied surfaced fields are
          # suppressed).
          head_binding: body['head_binding'],
          attestations: @board ? @board.attestations_for(entry.entry_hash) : []
        }
      end

      # ANC-8 / AHM-3: derive the label from the entry's own governing identity
      # (the identity in effect when the entry was committed), never from a single
      # current operator id. same_party => "public reference point";
      # foreign => "external anchor".
      def relation_for(entry)
        gov = entry.governing_identity
        gov && entry.depositor == gov ? :same_party : :foreign
      end
    end
  end
end
