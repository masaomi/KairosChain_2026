# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class TrustQuery < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'trust_query'
          end

          def description
            'Calculate trust score for a subject based on its attestation history. Considers quality, freshness, diversity, velocity, and revocation penalty.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[trust score query attestation reputation]
          end

          def related_tools
            %w[attestation_list attestation_issue attestation_verify]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject_ref: { type: 'string', description: 'The subject reference to calculate trust score for' }
              },
              required: %w[subject_ref]
            }
          end

          def call(arguments)
            result = trust_scorer.calculate(arguments['subject_ref'])

            chain_status = registry.verify_chain(:proofs)
            result[:registry_integrity] = chain_status

            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end
        end
      end
    end
  end
end
