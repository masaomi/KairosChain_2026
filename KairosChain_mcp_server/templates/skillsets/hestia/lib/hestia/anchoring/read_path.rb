# frozen_string_literal: true

require_relative 'log'
require_relative 'write_path'

module Hestia
  module Anchoring
    # Authenticated read over the anchor log (slice 1 of ANC-7).
    #
    # This is the read a peer performs behind a Meeting Place session: verify a
    # digest was recorded, see its chain position, and follow its retrieval
    # pointer. The UNAUTHENTICATED public verification view (ANC-7 in full) is
    # slice 2 — it reuses the very same verification record produced here, minus
    # this auth gate, so nothing built here has to be broken to open it.
    #
    # Read cost is kept independent of chain length (ANC-9): digest lookup is an
    # O(1) index hit and a read never recomputes the whole chain. The tamper-
    # evidence recompute (ANC-1) is a separate, explicit +verify_chain+ call.
    class ReadPath
      class Unauthenticated < WritePath::Unauthenticated; end

      # ANC-7's honest proof-scope statement. A match says only what it can.
      PROOF_SCOPE =
        'A digest match proves only that this digest was recorded by this depositor at this ' \
        'place at this moment. It does NOT prove authorship, quality, that the bytes behind the ' \
        'digest ever existed, or that the external reference is honest.'

      def initialize(log:, principal:, board: nil)
        @log = log
        @principal = principal
        @board = board
      end

      # Verify a digest: return a verification record for every anchor entry that
      # committed it (empty if none). O(1) index lookup — no chain recompute.
      def verify_digest(digest)
        require_authenticated!
        @log.find_by_digest(digest).map { |entry| verification_record(entry) }
      end

      # Verification record for a specific entry (nil for unknown / non-anchor).
      def get(entry_hash)
        require_authenticated!
        entry = @log.get(entry_hash.to_s)
        return nil unless entry && entry.anchor?

        verification_record(entry)
      end

      # Follow the retrieval pointer (the DOI) for an entry. nil if the entry is
      # withdrawn or carried no pointer — retrieval is never load-bearing (BRD-4).
      def follow_pointer(entry_hash)
        require_authenticated!
        record = record_for(entry_hash)
        record && record[:retrieval_pointer]
      end

      # Explicit, separate tamper-evidence check (ANC-1). Not run per read.
      def verify_chain
        require_authenticated!
        @log.verify
      end

      private

      def record_for(entry_hash)
        entry = @log.get(entry_hash.to_s)
        return nil unless entry && entry.anchor?

        verification_record(entry)
      end

      def verification_record(entry)
        view = @log.view(entry.entry_hash)
        withdrawn = view['withdrawn']
        body = view['body']
        record = {
          entry_hash: entry.entry_hash,
          digest: entry.digest,
          digest_algorithm: body['digest_algorithm'],
          canonicalization: body['canonicalization'],
          position: entry.position,
          depositor: entry.depositor,
          moment: body['moment'],
          withdrawn: withdrawn,
          # BRD-4: pointer suppressed on withdrawal; proof does not depend on it.
          retrieval_pointer: withdrawn ? nil : body['external_reference'],
          proof_scope: PROOF_SCOPE
        }
        record[:attestations] = @board.attestations_for(entry.entry_hash) if @board
        record
      end

      def require_authenticated!
        return if @principal.respond_to?(:verified?) && @principal.verified?

        raise Unauthenticated,
              'reading the anchor log requires a verified Meeting Place peer identity ' \
              '(the public unauthenticated view is slice 2)'
      end
    end
  end
end
