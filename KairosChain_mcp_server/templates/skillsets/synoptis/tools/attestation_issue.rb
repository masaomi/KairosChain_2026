# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationIssue < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'attestation_issue'
          end

          def description
            'Issue a new attestation proof for a subject. Creates a cryptographically signed proof envelope stored in the Synoptis registry.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation issue proof trust audit]
          end

          def related_tools
            %w[attestation_verify attestation_revoke attestation_list trust_query]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject_ref: { type: 'string', description: 'Reference to the subject being attested (e.g., "skill://genomics_pipeline", "agent://id", "place://id")' },
                claim: { type: 'string', description: 'The attestation claim (e.g., "integrity_verified", "paper_accepted", "automated_safety_check")' },
                evidence: { type: 'string', description: 'Supporting evidence (DOI, patent ID, hash, content summary)' },
                actor_role: { type: 'string', enum: %w[automated peer human], description: 'Attestation source: automated (LLM check), peer (agent verification), human (real-world outcome)' },
                merkle_root: { type: 'string', description: 'Optional Merkle root for selective disclosure' },
                ttl: { type: 'integer', description: 'Time-to-live in seconds (default: 86400 = 24h)' }
              },
              required: %w[subject_ref claim]
            }
          end

          def call(arguments)
            result = attestation_engine.create_attestation(
              attester_id: resolve_agent_id,
              subject_ref: arguments['subject_ref'],
              claim: arguments['claim'],
              evidence: arguments['evidence'],
              merkle_root: arguments['merkle_root'],
              ttl: arguments['ttl'],
              actor_user_id: resolve_actor_user_id,
              actor_role: arguments['actor_role'] || resolve_actor_role,
              crypto: resolve_crypto
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
