# frozen_string_literal: true

require_relative 'log'

module Hestia
  module Anchoring
    # The authenticated write path (ANC-5; hestia_anchor_attestation_design_v0.5).
    #
    # Every anchor deposit and withdrawal is attributable to a registered,
    # signature-verified Meeting Place peer identity. This object binds that
    # identity: it takes the +Principal+ produced by the place's authentication
    # (the peer_id behind a verified session) and sets the depositor / withdrawer
    # from it — the caller cannot supply or spoof an identity. Unauthenticated or
    # unverified principals cannot write at all.
    #
    # Signature verification itself is done by the Meeting Place session layer
    # (PlaceRouter#authenticate! issues a session token only after RSA
    # verification); this path consumes that result. It deliberately does NOT
    # reuse any unauthenticated local anchoring entry point (design §11).
    #
    # Withdrawal *authority* (depositor-or-operator) is enforced one layer down by
    # the Log. NOTE: Log#append_anchor/append_withdrawal are trust-internal — they
    # accept raw identity strings and must only be reached through this
    # authenticated path (or the MCP tool layer that constructs a verified
    # Principal). They are not a public unauthenticated entry point.
    class WritePath
      # Raised when a write is attempted without a verified principal.
      class Unauthenticated < StandardError; end

      # A verified caller identity. +peer_id+ is the Meeting Place peer id behind
      # a session; +verified+ reflects that the session was issued after signature
      # verification. Both must hold for a write to proceed.
      Principal = Struct.new(:peer_id, :verified, keyword_init: true) do
        def verified?
          verified == true && !peer_id.to_s.strip.empty?
        end
      end

      def initialize(log:, principal:, budget: nil)
        @log = log
        @principal = principal
        @budget = budget
      end

      # Deposit an anchor. The depositor is the authenticated peer identity, not a
      # caller argument — attribution cannot be forged here.
      def deposit(digest:, anchor_type:, source_id:, external_reference: nil, metadata: {}, moment: nil)
        require_authenticated!
        budgeted do
          @log.append_anchor(
            digest: digest,
            anchor_type: anchor_type,
            source_id: source_id,
            depositor: @principal.peer_id,
            external_reference: external_reference,
            metadata: metadata,
            moment: moment
          )
        end
      end

      # Withdraw an anchor. The withdrawer is the authenticated peer identity; the
      # Log rejects it unless that identity is the target's depositor or operator.
      def withdraw(target:, reason: nil, moment: nil)
        require_authenticated!
        budgeted do
          @log.append_withdrawal(
            target: target,
            withdrawer: @principal.peer_id,
            reason: reason,
            moment: moment
          )
        end
      end

      private

      # ANC-9: reserve budget before the write; refund if the write fails, so only
      # net-successful writes consume budget.
      def budgeted
        return yield unless @budget

        @budget.charge!(@principal.peer_id)
        begin
          yield
        rescue StandardError
          @budget.refund!(@principal.peer_id)
          raise
        end
      end

      def require_authenticated!
        return if @principal.respond_to?(:verified?) && @principal.verified?

        raise Unauthenticated, 'anchor writes require a verified Meeting Place peer identity'
      end
    end
  end
end
