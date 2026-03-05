# frozen_string_literal: true

require 'json'
require 'time'

module Synoptis
  module Transport
    class MMPTransport < Base
      def initialize(config: nil)
        @config = config || Synoptis.default_config
      end

      def transport_name
        'mmp'
      end

      # MMP is available when MMP::Protocol is loaded
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

        # Build MMP message body
        body = {
          action: action,
          to: target_id,
          payload: payload,
          timestamp: Time.now.utc.iso8601
        }

        # In-process delivery via MMP::Protocol.process_message
        begin
          response = MMP::Protocol.process_message(body)
          return { success: true, transport: transport_name, response: response }
        rescue StandardError
          # Fall through to HTTP delivery
        end

        # Cross-instance delivery via HTTP POST if KairosMcp.http_port is available
        if defined?(KairosMcp) && KairosMcp.respond_to?(:http_port) && KairosMcp.http_port
          begin
            require 'net/http'
            uri = URI("http://127.0.0.1:#{KairosMcp.http_port}/meeting/v1/message")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 5
            http.read_timeout = 10
            req = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
            req.body = JSON.generate(body)
            res = http.request(req)
            return { success: res.is_a?(Net::HTTPSuccess), transport: transport_name, response: res.body }
          rescue StandardError => e
            return { success: false, transport: transport_name, error: "HTTP delivery failed: #{e.message}" }
          end
        end

        # No active delivery mechanism
        { success: false, transport: transport_name, error: 'No delivery mechanism available' }
      end
    end
  end
end
