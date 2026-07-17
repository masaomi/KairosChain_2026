# frozen_string_literal: true

require_relative 'public_verifier'
require_relative 'write_budget'
require_relative 'containment'

module Synoptis
  module Anchoring
    # The Synoptis-owned public read handle (AHM-1: anchor read semantics are owned
    # by Synoptis; the Meeting Place is only a public window).
    #
    # hestia's public WebRouter consumes this ONE handle instead of reaching into
    # the anchor verifier and the disclosure / reference-safety policy constants
    # separately. Everything the window needs to PRESENT an anchor — the honest
    # verification records, the Sybil disclosure shown with the write budget, and
    # the "is this pointer safe to link" policy — is provided here, so hestia keeps
    # only presentation and never owns anchor read semantics.
    #
    # It is auth-free by construction (it wraps the auth-free PublicVerifier); the
    # authenticated read surface is ReadPath, which gates before delegating.
    class PublicRead
      def initialize(log:, board: nil)
        @verifier = PublicVerifier.new(log: log, board: board)
      end

      # --- Verification-record producers (delegated to the verifier) ---

      def verify_digest(digest)
        @verifier.verify_digest(digest)
      end

      def get(entry_hash)
        @verifier.get(entry_hash)
      end

      def by_source_id(source_id)
        @verifier.by_source_id(source_id)
      end

      # --- Disclosure / reference-safety policy (owned by Synoptis) ---

      # ANC-9 Sybil disclosure, shown alongside the write budget in the public
      # verification view.
      def sybil_disclosure
        WriteBudget::SYBIL_DISCLOSURE
      end

      # ANC-2 reference-safety policy: is a retrieval pointer safe to render as a
      # link? Which schemes are safe is decided here; hestia only maps a safe
      # pointer to its presentation href. Defense-in-depth over the containment
      # already applied at write time.
      def safe_reference?(pointer)
        pointer.to_s.strip.match?(Containment::SAFE_REFERENCE_PATTERN)
      end
    end
  end
end
