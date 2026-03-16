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

            # Delegate to HttpServer when running in HTTP mode
            http_server = defined?(KairosMcp) && KairosMcp.respond_to?(:http_server) ? KairosMcp.http_server : nil
            if http_server
              trust_anchor = nil
              if config.dig('trust_anchor', 'record_registrations')
                trust_anchor = ::Hestia.chain_client(config: config.dig('chain'))
              end
              http_server.start_place(identity: identity, trust_anchor_client: trust_anchor, hestia_config: config)
              place_name = config.dig('meeting_place', 'name') || 'KairosChain Meeting Place'
              return text_content(JSON.pretty_generate({
                status: 'started',
                message: 'Meeting Place started via HttpServer (HTTP mode)',
                name: place_name
              }))
            end

            # STDIO mode: create local PlaceRouter
            place_router = ::Hestia::PlaceRouter.new(config: config)

            trust_anchor = nil
            if config.dig('trust_anchor', 'record_registrations')
              trust_anchor = ::Hestia.chain_client(config: config.dig('chain'))
            end

            session_store = ::MMP::MeetingSessionStore.new

            # Detect Synoptis trust scorer if available (optional SkillSet dependency)
            scorer = resolve_trust_scorer

            result = place_router.start(
              identity: identity,
              session_store: session_store,
              trust_anchor_client: trust_anchor,
              trust_scorer: scorer
            )

            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({
              error: 'start_failed',
              message: e.message
            }))
          end

          private

          # Runtime detection of Synoptis SkillSet.
          # Returns a TrustScorer instance if Synoptis is loaded, nil otherwise.
          # This follows the core_or_skillset_guide pattern for optional dependencies.
          def resolve_trust_scorer
            return nil unless defined?(::Synoptis::TrustScorer)
            return nil unless defined?(::Synoptis::Registry::FileRegistry)

            synoptis_config = {}
            if defined?(::Synoptis) && ::Synoptis.respond_to?(:load_config)
              synoptis_config = ::Synoptis.load_config rescue {}
            end

            registry_path = synoptis_config.dig('registry', 'path') || 'storage/synoptis_registry.jsonl'
            registry = ::Synoptis::Registry::FileRegistry.new(path: registry_path)
            ::Synoptis::TrustScorer.new(registry: registry, config: synoptis_config)
          rescue StandardError => e
            $stderr.puts "[MeetingPlaceStart] Synoptis detection failed (non-fatal): #{e.message}"
            nil
          end
        end
      end
    end
  end
end
