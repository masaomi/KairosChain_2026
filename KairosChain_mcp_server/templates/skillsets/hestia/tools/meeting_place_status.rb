# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Hestia
      module Tools
        class MeetingPlaceStatus < KairosMcp::Tools::BaseTool
          def name
            'meeting_place_status'
          end

          def description
            'Get the current status of the Hestia Meeting Place: registered agents, uptime, heartbeat info, and SkillBoard summary.'
          end

          def category
            :meeting_place
          end

          def usecase_tags
            %w[hestia meeting place status agents heartbeat]
          end

          def related_tools
            %w[meeting_place_start meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                include_agents: { type: 'boolean', description: 'Include full agent list (default: false)' }
              },
              required: []
            }
          end

          def call(arguments)
            # This tool works standalone with a PlaceRouter instance
            # In production, it would access the running PlaceRouter via HttpServer
            # For now, report config-based status
            config = ::Hestia.load_config
            place_config = config['meeting_place'] || {}

            result = {
              meeting_place: {
                name: place_config['name'] || 'KairosChain Meeting Place',
                max_agents: place_config['max_agents'] || 100,
                session_timeout: place_config['session_timeout'] || 3600
              },
              chain: {
                backend: config.dig('chain', 'backend') || 'in_memory',
                enabled: config.dig('chain', 'enabled') != false
              },
              trust_anchor: {
                record_exchanges: config.dig('trust_anchor', 'record_exchanges') != false,
                record_registrations: config.dig('trust_anchor', 'record_registrations') != false
              },
              hint: 'Use meeting_place_start to start the Meeting Place server.'
            }

            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({
              error: 'status_failed',
              message: e.message
            }))
          end
        end
      end
    end
  end
end
