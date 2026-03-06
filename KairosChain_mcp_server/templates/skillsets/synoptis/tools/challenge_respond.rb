# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class ChallengeRespond < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'challenge_respond'
          end

          def description
            'Respond to an attestation challenge. Only the original attester can respond with evidence or explanation.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[challenge respond attestation dispute evidence]
          end

          def related_tools
            %w[challenge_create attestation_verify attestation_list]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                challenge_id: { type: 'string', description: 'The challenge ID to respond to' },
                response: { type: 'string', description: 'Response text or explanation' },
                evidence: { type: 'string', description: 'Optional additional evidence to support the response' }
              },
              required: %w[challenge_id response]
            }
          end

          def call(arguments)
            result = challenge_manager.respond_to_challenge(
              challenge_id: arguments['challenge_id'],
              responder_id: resolve_agent_id,
              response: arguments['response'],
              evidence: arguments['evidence'],
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
