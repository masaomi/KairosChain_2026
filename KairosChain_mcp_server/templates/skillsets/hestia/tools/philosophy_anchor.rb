# frozen_string_literal: true

require 'digest'

module KairosMcp
  module SkillSets
    module Hestia
      module Tools
        class PhilosophyAnchor < KairosMcp::Tools::BaseTool
          def name
            'philosophy_anchor'
          end

          def description
            'Declare your exchange philosophy on HestiaChain. This makes your philosophical stance observable to other agents without requiring agreement. DEE principle: observation without judgment.'
          end

          def category
            :chain
          end

          def usecase_tags
            %w[hestia philosophy declaration dee exchange compatibility anchor]
          end

          def related_tools
            %w[record_observation chain_migrate_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                philosophy_type: {
                  type: 'string',
                  enum: %w[exchange interaction fadeout],
                  description: 'Type of philosophy: exchange (skill sharing), interaction (general), fadeout (disengagement)'
                },
                content: {
                  type: 'string',
                  description: 'Philosophy content text (will be hashed — only the hash is stored on chain, content stays private)'
                },
                compatible_with: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Compatibility tags: cooperative, competitive, observational, experimental, conservative, adaptive'
                },
                version: {
                  type: 'string',
                  description: 'Version of this declaration (default: 1.0)'
                }
              },
              required: %w[philosophy_type content]
            }
          end

          def call(arguments)
            philosophy_type = arguments['philosophy_type']
            content = arguments['content']
            compatible_with = arguments['compatible_with'] || []
            version = arguments['version'] || '1.0'

            # Get agent identity
            config = ::MMP.load_config
            identity = ::MMP::Identity.new(config: config)
            agent_id = identity.instance_id

            # Hash the content (content stays private, only hash goes on chain)
            philosophy_hash = Digest::SHA256.hexdigest(content)

            # Create declaration
            declaration = ::Hestia::Chain::Protocol::PhilosophyDeclaration.new(
              agent_id: agent_id,
              philosophy_type: philosophy_type,
              philosophy_hash: philosophy_hash,
              compatible_with: compatible_with,
              version: version
            )

            # Submit to HestiaChain
            client = ::Hestia.chain_client
            anchor = declaration.to_anchor
            result = client.submit(anchor)

            output = {
              status: result[:status],
              declaration_id: declaration.declaration_id,
              anchor_hash: result[:anchor_hash],
              philosophy_type: philosophy_type,
              philosophy_hash: philosophy_hash,
              compatible_with: compatible_with,
              version: version,
              agent_id: agent_id,
              note: 'Philosophy content is private. Only the hash is recorded on chain.'
            }

            text_content(JSON.pretty_generate(output))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Failed to anchor philosophy', message: e.message }))
          end
        end
      end
    end
  end
end
