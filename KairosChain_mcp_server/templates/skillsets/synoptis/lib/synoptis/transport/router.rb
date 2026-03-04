# frozen_string_literal: true

module Synoptis
  module Transport
    class Router
      DEFAULT_PRIORITY = %w[mmp hestia local].freeze

      attr_reader :config

      def initialize(config: nil)
        @config = config || Synoptis.default_config
        @priority = @config.dig('transport', 'priority') || DEFAULT_PRIORITY
      end

      # Send a message to target agent via best available transport
      # Falls back through priority list on failure
      def send(target_id, message)
        errors = []

        ordered_transports.each do |transport|
          next unless transport.available?

          result = transport.send_message(target_id, message)
          return result if result[:success]

          errors << { transport: transport.transport_name, error: result[:error] }
        end

        {
          success: false,
          transport: 'none',
          error: 'All transports failed',
          details: errors
        }
      end

      # List available transports in priority order
      def available_transports
        ordered_transports.select(&:available?).map(&:transport_name)
      end

      private

      def ordered_transports
        @ordered_transports ||= @priority.filter_map do |name|
          case name
          when 'mmp'    then MMPTransport.new(config: @config)
          when 'hestia' then HestiaTransport.new(config: @config)
          when 'local'  then LocalTransport.new(config: @config)
          end
        end
      end
    end
  end
end
