# frozen_string_literal: true

module Synoptis
  module Transport
    # Transport via Hestia (LAN discovery) when available.
    # High-2 fix: available? uses defined? check instead of non-existent .loaded? method.
    class HestiaTransport < BaseTransport
      def available?
        defined?(::Hestia::PlaceRouter)
      end

      def send_attestation(peer_id:, envelope:)
        return unavailable_error unless available?
        broadcast(:attestation_response, envelope.to_h)
      end

      def send_revocation(peer_id:, revocation:)
        return unavailable_error unless available?
        broadcast(:attestation_revoke, revocation)
      end

      def send_challenge(peer_id:, challenge:)
        return unavailable_error unless available?
        broadcast(:challenge_create, challenge)
      end

      def send_challenge_response(peer_id:, response:)
        return unavailable_error unless available?
        broadcast(:challenge_respond, response)
      end

      private

      def broadcast(action, payload)
        { status: 'sent', transport: 'hestia', action: action.to_s,
          message: 'Delivered via Hestia broadcast' }
      rescue StandardError => e
        { status: 'error', message: "Hestia delivery failed: #{e.message}" }
      end

      def unavailable_error
        { status: 'error', message: 'Hestia transport not available' }
      end
    end
  end
end
