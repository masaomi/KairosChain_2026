# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationRevoke < KairosMcp::Tools::BaseTool
          def name
            'attestation_revoke'
          end

          def description
            'Revoke a previously issued attestation proof. The attestation will be marked as revoked and subsequent verifications will report it as invalid.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[synoptis attestation revoke trust]
          end

          def related_tools
            %w[attestation_verify attestation_list]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                proof_id: {
                  type: 'string',
                  description: 'ID of the attestation proof to revoke'
                },
                reason: {
                  type: 'string',
                  description: 'Reason for revoking the attestation'
                }
              },
              required: %w[proof_id reason]
            }
          end

          def call(arguments)
            proof_id = arguments['proof_id']
            reason = arguments['reason']

            config = ::Synoptis.load_config
            engine = ::Synoptis.engine(config: config)

            # Determine revoker identity
            revoked_by = resolve_agent_id

            # Revoke the proof
            revocation = engine.revoke_proof(proof_id, reason, revoked_by)

            # Notify attestee via transport (best effort)
            proof_data = engine.registry.find_proof(proof_id)
            if proof_data
              attestee_id = proof_data[:attestee_id]
              if attestee_id && attestee_id != revoked_by
                router = ::Synoptis::Transport::Router.new(config: config)
                router.send(attestee_id, {
                  action: 'attestation_revoke',
                  payload: { proof_id: proof_id, reason: reason, revoked_at: revocation[:revoked_at] }
                })
              end
            end

            output = {
              proof_id: proof_id,
              status: 'revoked',
              revocation_id: revocation[:revocation_id],
              reason: reason,
              revoked_by: revoked_by,
              revoked_at: revocation[:revoked_at]
            }

            text_content(JSON.pretty_generate(output))
          rescue ArgumentError => e
            text_content(JSON.pretty_generate({ error: 'Invalid revocation', message: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Revocation failed', message: e.message }))
          end

          private

          def resolve_agent_id
            if defined?(KairosMcp) && KairosMcp.respond_to?(:agent_id)
              KairosMcp.agent_id
            else
              'local_agent'
            end
          end
        end
      end
    end
  end
end
