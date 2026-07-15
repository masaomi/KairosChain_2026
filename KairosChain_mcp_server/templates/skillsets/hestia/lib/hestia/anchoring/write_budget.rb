# frozen_string_literal: true

module Hestia
  module Anchoring
    # Availability budget for the free write surface (ANC-9).
    #
    # The free write budget is bounded per depositor identity AND in aggregate,
    # over a refilling time window, so the service cannot be exhausted. The bound
    # is checked before a write is committed; a write that then fails downstream
    # is refunded, so only net-successful writes consume budget.
    #
    # Honest limits (ANC-9): the aggregate bound prevents *exhaustion*, but fair
    # sharing among identities is only as strong as the operator's identity
    # issuance — a Sybil actor minting many identities can still consume its share.
    # Full Sybil resistance is not promised; it is disclosed, not claimed away.
    #
    # The operator (same-party) is exempt: this budget protects the served surface
    # against foreign exhaustion, not the operator's own use of its own place.
    #
    # Concrete numbers are mechanism (design §11) and are configurable; the
    # defaults are a starting point to be tuned at deployment.
    class WriteBudget
      DEFAULT_PER_IDENTITY = 60
      DEFAULT_AGGREGATE = 600
      DEFAULT_WINDOW_SECONDS = 3600

      SYBIL_DISCLOSURE =
        'The free write budget is bounded per identity and in aggregate to prevent exhaustion. ' \
        "Fair sharing among identities is only as strong as the operator's identity issuance: a " \
        'Sybil actor minting many identities can still consume its share. Full Sybil resistance is ' \
        'not provided — it is an open, disclosed limit.'

      # Raised when a write would exceed the budget. +scope+ is :per_identity or
      # :aggregate; +disclosure+ carries the honest Sybil limit.
      class BudgetExceeded < StandardError
        attr_reader :scope, :disclosure

        def initialize(scope, disclosure)
          @scope = scope
          @disclosure = disclosure
          super("write budget exceeded (#{scope}). #{disclosure}")
        end
      end

      def initialize(per_identity: DEFAULT_PER_IDENTITY, aggregate: DEFAULT_AGGREGATE,
                     window_seconds: DEFAULT_WINDOW_SECONDS, operator_id: nil, clock: nil)
        @per_identity = per_identity
        @aggregate = aggregate
        @window = window_seconds
        @operator_id = operator_id.nil? ? nil : operator_id.to_s
        @clock = clock || -> { Time.now }
        @mutex = Mutex.new
        @window_start = @clock.call
        @by_identity = Hash.new(0)
        @aggregate_count = 0
      end

      # Reserve one write for +identity+. Raises BudgetExceeded if over budget.
      # The operator is exempt.
      def charge!(identity)
        id = identity.to_s
        return if operator?(id)

        @mutex.synchronize do
          roll!
          raise BudgetExceeded.new(:aggregate, SYBIL_DISCLOSURE) if @aggregate_count >= @aggregate
          raise BudgetExceeded.new(:per_identity, SYBIL_DISCLOSURE) if @by_identity[id] >= @per_identity

          @by_identity[id] += 1
          @aggregate_count += 1
        end
      end

      # Return a reservation when the downstream write failed, so a rejected write
      # does not permanently consume budget.
      def refund!(identity)
        id = identity.to_s
        return if operator?(id)

        @mutex.synchronize do
          # Only refund within the same window; after a roll the counters reset.
          return if window_elapsed?

          @by_identity[id] -= 1 if @by_identity[id].positive?
          @aggregate_count -= 1 if @aggregate_count.positive?
        end
      end

      def status
        @mutex.synchronize do
          roll!
          {
            per_identity_limit: @per_identity,
            aggregate_limit: @aggregate,
            window_seconds: @window,
            aggregate_used: @aggregate_count,
            disclosure: SYBIL_DISCLOSURE
          }
        end
      end

      private

      def operator?(id)
        @operator_id && id == @operator_id
      end

      def window_elapsed?
        (@clock.call - @window_start) >= @window
      end

      def roll!
        return unless window_elapsed?

        @window_start = @clock.call
        @by_identity = Hash.new(0)
        @aggregate_count = 0
      end
    end
  end
end
