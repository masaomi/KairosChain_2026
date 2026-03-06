# frozen_string_literal: true

module Synoptis
  module Transport
    class BaseTransport
      def initialize(config: {})
        @config = config
      end

      def available?
        raise NotImplementedError, "#{self.class}#available? must be implemented"
      end

      def send_attestation(peer_id:, envelope:)
        raise NotImplementedError, "#{self.class}#send_attestation must be implemented"
      end

      def send_revocation(peer_id:, revocation:)
        raise NotImplementedError, "#{self.class}#send_revocation must be implemented"
      end

      def send_challenge(peer_id:, challenge:)
        raise NotImplementedError, "#{self.class}#send_challenge must be implemented"
      end

      def send_challenge_response(peer_id:, response:)
        raise NotImplementedError, "#{self.class}#send_challenge_response must be implemented"
      end
    end
  end
end
