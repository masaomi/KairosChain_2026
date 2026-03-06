# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationVerify < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'attestation_verify'
          end

          def description
            'Verify an attestation proof by ID. Checks structural validity, signature, expiry, and revocation status.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation verify proof trust check]
          end

          def related_tools
            %w[attestation_issue attestation_list trust_query]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                proof_id: { type: 'string', description: 'The proof ID to verify' },
                public_key: { type: 'string', description: 'Optional PEM public key for signature verification. If omitted, signature check is skipped.' }
              },
              required: %w[proof_id]
            }
          end

          def call(arguments)
            result = attestation_engine.verify_attestation(
              arguments['proof_id'],
              public_key: arguments['public_key']
            )

            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end
        end
      end
    end
  end
end
