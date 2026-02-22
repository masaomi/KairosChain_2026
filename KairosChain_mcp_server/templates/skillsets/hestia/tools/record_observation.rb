# frozen_string_literal: true

require 'digest'

module KairosMcp
  module SkillSets
    module Hestia
      module Tools
        class RecordObservation < KairosMcp::Tools::BaseTool
          def name
            'record_observation'
          end

          def description
            'Record a subjective observation of an interaction on HestiaChain. Multiple agents can record different observations of the same interaction. DEE principle: meaning coexists.'
          end

          def category
            :chain
          end

          def usecase_tags
            %w[hestia observation interaction dee witness fadeout log]
          end

          def related_tools
            %w[philosophy_anchor chain_migrate_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                observed_id: {
                  type: 'string',
                  description: 'ID of the agent being observed (peer instance_id)'
                },
                observation_type: {
                  type: 'string',
                  enum: %w[initiated completed faded observed],
                  description: 'Type: initiated (interaction started), completed (interaction ended), faded (relationship faded), observed (general)'
                },
                interaction_data: {
                  type: 'string',
                  description: 'Description of the interaction (will be hashed — only the hash is stored on chain)'
                },
                interpretation: {
                  type: 'object',
                  description: 'Your subjective interpretation of the interaction (stored locally, hash goes on chain)'
                }
              },
              required: %w[observed_id observation_type interaction_data]
            }
          end

          def call(arguments)
            observed_id = arguments['observed_id']
            observation_type = arguments['observation_type']
            interaction_data = arguments['interaction_data']
            interpretation = arguments['interpretation'] || {}

            # Get agent identity
            config = ::MMP.load_config
            identity = ::MMP::Identity.new(config: config)
            observer_id = identity.instance_id

            # Hash the interaction data
            interaction_hash = Digest::SHA256.hexdigest(interaction_data)

            # Create observation
            observation = ::Hestia::Chain::Protocol::ObservationLog.new(
              observer_id: observer_id,
              observed_id: observed_id,
              interaction_hash: interaction_hash,
              observation_type: observation_type,
              interpretation: interpretation
            )

            # Submit to HestiaChain
            client = ::Hestia.chain_client
            anchor = observation.to_anchor
            result = client.submit(anchor)

            output = {
              status: result[:status],
              observation_id: observation.observation_id,
              anchor_hash: result[:anchor_hash],
              observation_type: observation_type,
              observer_id: observer_id,
              observed_id: observed_id,
              interaction_hash: interaction_hash,
              self_observation: observation.self_observation?,
              fadeout: observation.fadeout?,
              note: 'Interaction data is private. Only the hash is recorded on chain.'
            }

            text_content(JSON.pretty_generate(output))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Failed to record observation', message: e.message }))
          end
        end
      end
    end
  end
end
