# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class ChallengeCreate < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'challenge_create'
          end

          def description
            'Create a challenge against an existing attestation. The original attester must respond within the configured timeout.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[challenge create attestation dispute audit]
          end

          def related_tools
            %w[challenge_respond attestation_verify attestation_list]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                proof_id: { type: 'string', description: 'The proof ID to challenge' },
                challenge_type: { type: 'string', enum: %w[validity evidence_request re_verification],
                                  description: 'Type of challenge' },
                details: { type: 'string', description: 'Details or reason for the challenge' }
              },
              required: %w[proof_id challenge_type]
            }
          end

          def call(arguments)
            result = challenge_manager.create_challenge(
              proof_id: arguments['proof_id'],
              challenger_id: resolve_agent_id,
              challenge_type: arguments['challenge_type'],
              details: arguments['details'],
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
