# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Hestia
      module Tools
        class MeetingPlaceStart < KairosMcp::Tools::BaseTool
          def name
            'meeting_place_start'
          end

          def description
            'Start the Hestia Meeting Place server. Initializes AgentRegistry, SkillBoard, HeartbeatManager, and self-registers this instance. Requires MMP to be configured.'
          end

          def category
            :meeting_place
          end

          def usecase_tags
            %w[hestia meeting place start server agents]
          end

          def related_tools
            %w[meeting_place_status meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                name: { type: 'string', description: 'Custom name for this Meeting Place (optional)' }
              },
              required: []
            }
          end

          def call(arguments)
            config = ::Hestia.load_config
            mmp_config = ::MMP.load_config

            unless mmp_config['enabled']
              return text_content(JSON.pretty_generate({
                error: 'mmp_not_enabled',
                message: 'MMP SkillSet must be enabled. Set enabled: true in config/meeting.yml'
              }))
            end

            identity = ::MMP::Identity.new(config: mmp_config)

            # Override place name if provided
            if arguments['name']
              config['meeting_place'] ||= {}
              config['meeting_place']['name'] = arguments['name']
            end

            # Create PlaceRouter and start
            place_router = ::Hestia::PlaceRouter.new(config: config)

            # Build trust anchor client if configured
            trust_anchor = nil
            if config.dig('trust_anchor', 'record_registrations')
              trust_anchor = ::Hestia.chain_client(config: config.dig('chain'))
            end

            # Create a session store (reuse MMP's pattern)
            session_store = ::MMP::MeetingSessionStore.new

            result = place_router.start(
              identity: identity,
              session_store: session_store,
              trust_anchor_client: trust_anchor
            )

            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({
              error: 'start_failed',
              message: e.message
            }))
          end
        end
      end
    end
  end
end
