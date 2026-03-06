# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationList < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'attestation_list'
          end

          def description
            'List attestation proofs with optional filters by subject, attester, or claim type.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation list query audit]
          end

          def related_tools
            %w[attestation_issue attestation_verify trust_query]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject_ref: { type: 'string', description: 'Filter by subject reference' },
                attester_id: { type: 'string', description: 'Filter by attester ID' },
                claim: { type: 'string', description: 'Filter by claim type' }
              }
            }
          end

          def call(arguments)
            filter = {}
            filter[:subject_ref] = arguments['subject_ref'] if arguments['subject_ref']
            filter[:attester_id] = arguments['attester_id'] if arguments['attester_id']
            filter[:claim] = arguments['claim'] if arguments['claim']

            result = attestation_engine.list_attestations(filter: filter)

            text_content(JSON.pretty_generate({
              attestations: result,
              count: result.size,
              filter: filter
            }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end
        end
      end
    end
  end
end
