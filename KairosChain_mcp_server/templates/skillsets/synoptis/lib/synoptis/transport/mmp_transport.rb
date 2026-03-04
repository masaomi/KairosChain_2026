# frozen_string_literal: true

module Synoptis
  module Transport
    class MMPTransport < Base
      def initialize(config: nil)
        @config = config || Synoptis.default_config
      end

      def transport_name
        'mmp'
      end

      # MMP is always available (core dependency)
      def available?
        defined?(MMP::Protocol)
      end

      # Send attestation message via MMP protocol
      def send_message(target_id, message)
        unless available?
          return { success: false, transport: transport_name, error: 'MMP::Protocol not available' }
        end

        action = message[:action] || message['action']
        payload = message[:payload] || message['payload'] || message

        # Build MMP message
        mmp_message = {
          action: action,
          to: target_id,
          payload: payload,
          timestamp: Time.now.utc.iso8601
        }

        # Use MeetingRouter if available for actual delivery
        if defined?(KairosMcp::MeetingRouter)
          begin
            router = KairosMcp::MeetingRouter.instance rescue nil
            if router && router.respond_to?(:handle_message)
              response = router.handle_message(mmp_message)
              return { success: true, transport: transport_name, response: response }
            end
          rescue StandardError => e
            return { success: false, transport: transport_name, error: e.message }
          end
        end

        # No active delivery mechanism — report as undelivered
        { success: false, transport: transport_name, error: 'No MeetingRouter available for delivery' }
      end
    end
  end
end
