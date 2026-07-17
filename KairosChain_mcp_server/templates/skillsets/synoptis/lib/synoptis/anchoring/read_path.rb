# frozen_string_literal: true

require_relative 'log'
require_relative 'write_path'
require_relative 'public_verifier'

module Synoptis
  module Anchoring
    # Authenticated read over the anchor log (slice 1 of ANC-7).
    #
    # This is the read a peer performs behind a Meeting Place session. It is the
    # PublicVerifier's record producer gated by authentication: slice 1 keeps the
    # gate closed, slice 2's WebRouter view opens it (unauthenticated public
    # verification, ANC-7 in full), reusing the identical record so the two
    # surfaces cannot drift.
    #
    # Read cost is kept independent of chain length (ANC-9): digest lookup is an
    # O(1) index hit and a read never recomputes the whole chain. The tamper-
    # evidence recompute (ANC-1) is a separate, explicit +verify_chain+ call.
    class ReadPath
      class Unauthenticated < WritePath::Unauthenticated; end

      # Kept as an alias so callers depending on ReadPath::PROOF_SCOPE still work;
      # the canonical home is the shared verifier.
      PROOF_SCOPE = PublicVerifier::PROOF_SCOPE

      def initialize(log:, principal:, board: nil)
        @log = log
        @principal = principal
        @verifier = PublicVerifier.new(log: log, board: board)
      end

      # Verify a digest: verification record per anchor entry (empty if none).
      def verify_digest(digest)
        require_authenticated!
        @verifier.verify_digest(digest)
      end

      # Verification record for a specific entry (nil for unknown / non-anchor).
      def get(entry_hash)
        require_authenticated!
        @verifier.get(entry_hash)
      end

      # Follow the retrieval pointer (the DOI) for an entry. nil if the entry is
      # withdrawn or carried no pointer — retrieval is never load-bearing (BRD-4).
      def follow_pointer(entry_hash)
        require_authenticated!
        record = @verifier.get(entry_hash)
        record && record[:retrieval_pointer]
      end

      # Explicit, separate tamper-evidence check (ANC-1). Not run per read.
      def verify_chain
        require_authenticated!
        @log.verify
      end

      private

      def require_authenticated!
        return if @principal.respond_to?(:verified?) && @principal.verified?

        raise Unauthenticated,
              'reading the anchor log requires a verified Meeting Place peer identity ' \
              '(the public unauthenticated view is slice 2)'
      end
    end
  end
end
