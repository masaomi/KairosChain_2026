# frozen_string_literal: true

module Synoptis
  module Transport
    class HestiaTransport < Base
      def initialize(config: nil)
        @config = config || Synoptis.default_config
      end

      def transport_name
        'hestia'
      end

      # Available only when Hestia SkillSet is loaded
      def available?
        defined?(Hestia) && Hestia.respond_to?(:loaded?) && Hestia.loaded?
      end

      # Discover agent via Meeting Place, then delegate to MMP for actual delivery
      def send_message(target_id, message)
        unless available?
          return { success: false, transport: transport_name, error: 'Hestia not available' }
        end

        begin
          # Discover target agent via AgentRegistry
          if defined?(Hestia::AgentRegistry) && Hestia::AgentRegistry.respond_to?(:find)
            agent_info = Hestia::AgentRegistry.find(target_id)
            unless agent_info
              return { success: false, transport: transport_name, error: "Agent #{target_id} not found in AgentRegistry" }
            end

            # Check if target supports mutual_attestation
            capabilities = agent_info[:capabilities] || agent_info['capabilities'] || []
            unless capabilities.include?('mutual_attestation')
              return { success: false, transport: transport_name, error: "Agent #{target_id} does not support mutual_attestation" }
            end
          end

          # Delegate actual delivery to MMP transport
          mmp = MMPTransport.new(config: @config)
          result = mmp.send_message(target_id, message)
          result[:transport] = transport_name  # Record discovery transport
          result
        rescue StandardError => e
          { success: false, transport: transport_name, error: e.message }
        end
      end
    end
  end
end
