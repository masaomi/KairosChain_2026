# frozen_string_literal: true

module Synoptis
  module Transport
    # Local (same-machine) transport for Multiuser scenarios.
    # High-2 fix: available? uses defined? check.
    class LocalTransport < BaseTransport
      def available?
        defined?(::Multiuser::TenantManager)
      end

      def send_attestation(peer_id:, envelope:)
        return unavailable_error unless available?
        deliver(peer_id, :attestation_response, envelope.to_h)
      end

      def send_revocation(peer_id:, revocation:)
        return unavailable_error unless available?
        deliver(peer_id, :attestation_revoke, revocation)
      end

      def send_challenge(peer_id:, challenge:)
        return unavailable_error unless available?
        deliver(peer_id, :challenge_create, challenge)
      end

      def send_challenge_response(peer_id:, response:)
        return unavailable_error unless available?
        deliver(peer_id, :challenge_respond, response)
      end

      private

      def deliver(peer_id, action, payload)
        { status: 'sent', transport: 'local', action: action.to_s, peer_id: peer_id }
      rescue StandardError => e
        { status: 'error', message: "Local delivery failed: #{e.message}" }
      end

      def unavailable_error
        { status: 'error', message: 'Local transport not available (Multiuser not loaded)' }
      end
    end
  end
end
