# frozen_string_literal: true

require 'securerandom'
require 'time'

module KairosMcp
  class Daemon
    # ElevationToken — opaque, unforgeable grant for temporary policy elevation.
    #
    # Design (P3.2 v0.2 §5.1, MF2 fix):
    #   Identity comparison via equal? (object_id). Even if an attacker
    #   knows the proposal_id, they cannot forge a token that passes matches?.
    class ElevationToken
      attr_reader :proposal_id, :scope, :granted_by, :granted_at

      def initialize(proposal_id:, scope:, granted_by:)
        @proposal_id = proposal_id.freeze
        @scope       = scope.freeze
        @granted_by  = granted_by.freeze
        @granted_at  = Time.now.utc.iso8601.freeze
      end

      # Identity comparison — only the exact token object matches.
      # @param other [ElevationToken, nil]
      # @return [Boolean]
      def matches?(other)
        other.equal?(self)
      end

      def to_h
        { proposal_id: @proposal_id, scope: @scope,
          granted_by: @granted_by, granted_at: @granted_at }
      end
    end
  end
end
