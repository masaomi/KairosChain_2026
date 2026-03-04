# frozen_string_literal: true

module Synoptis
  module Transport
    class LocalTransport < Base
      def initialize(config: nil)
        @config = config || Synoptis.default_config
      end

      def transport_name
        'local'
      end

      # Available only when Multiuser SkillSet is loaded
      def available?
        defined?(Multiuser) && Multiuser.respond_to?(:loaded?) && Multiuser.loaded?
      end

      # Direct local delivery within same instance (no network required)
      def send_message(target_id, message)
        unless available?
          return { success: false, transport: transport_name, error: 'Multiuser not available' }
        end

        begin
          action = message[:action] || message['action']
          payload = message[:payload] || message['payload'] || message

          # Direct DB-level delivery via Multiuser tenant access
          if defined?(Multiuser::TenantManager) && Multiuser::TenantManager.respond_to?(:deliver_to)
            response = Multiuser::TenantManager.deliver_to(target_id, {
              action: action,
              payload: payload,
              transport: 'local'
            })
            return { success: true, transport: transport_name, response: response }
          end

          # No TenantManager available for delivery
          { success: false, transport: transport_name, error: 'No TenantManager available for local delivery' }
        rescue StandardError => e
          { success: false, transport: transport_name, error: e.message }
        end
      end
    end
  end
end
