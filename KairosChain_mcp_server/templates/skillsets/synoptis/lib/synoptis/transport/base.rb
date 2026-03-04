# frozen_string_literal: true

module Synoptis
  module Transport
    class Base
      # Send a message to a target agent
      # Returns { success: Boolean, transport: String, response: Hash }
      def send_message(_target_id, _message)
        raise NotImplementedError
      end

      # Check if this transport is currently available
      def available?
        raise NotImplementedError
      end

      # Transport name identifier
      def transport_name
        raise NotImplementedError
      end
    end
  end
end
