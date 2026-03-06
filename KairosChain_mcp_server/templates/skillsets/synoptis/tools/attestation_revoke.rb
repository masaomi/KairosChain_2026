# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationRevoke < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'attestation_revoke'
          end

          def description
            'Revoke an existing attestation. Only the original attester or an admin can revoke.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation revoke trust audit]
          end

          def related_tools
            %w[attestation_issue attestation_verify attestation_list]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                proof_id: { type: 'string', description: 'The proof ID to revoke' },
                reason: { type: 'string', description: 'Reason for revocation' }
              },
              required: %w[proof_id reason]
            }
          end

          def call(arguments)
            result = revocation_manager.revoke(
              proof_id: arguments['proof_id'],
              reason: arguments['reason'],
              revoker_id: resolve_agent_id,
              actor_user_id: resolve_actor_user_id,
              actor_role: resolve_actor_role
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
