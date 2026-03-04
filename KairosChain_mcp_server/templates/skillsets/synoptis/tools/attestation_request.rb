# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationRequest < KairosMcp::Tools::BaseTool
          def name
            'attestation_request'
          end

          def description
            'Send an attestation request to a target agent. Creates a request with claim type, subject reference, and disclosure level, then delivers it via the best available transport.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[synoptis attestation request trust p2p]
          end

          def related_tools
            %w[attestation_issue attestation_verify attestation_list]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                target_agent: {
                  type: 'string',
                  description: 'Agent ID of the attestation target'
                },
                claim_type: {
                  type: 'string',
                  enum: ::Synoptis::ClaimTypes.all_types,
                  description: 'Type of claim for the attestation'
                },
                subject_ref: {
                  type: 'string',
                  description: 'Reference to the subject being attested (e.g., skill:fastqc_v1)'
                },
                disclosure_level: {
                  type: 'string',
                  enum: %w[existence_only full],
                  description: 'Level of evidence disclosure. Default: existence_only'
                }
              },
              required: %w[target_agent claim_type subject_ref]
            }
          end

          def call(arguments)
            target_agent = arguments['target_agent']
            claim_type = arguments['claim_type']
            subject_ref = arguments['subject_ref']
            disclosure_level = arguments['disclosure_level'] || 'existence_only'

            config = ::Synoptis.load_config
            engine = ::Synoptis.engine(config: config)

            # Create the request
            request = engine.create_request(target_agent, claim_type, subject_ref, disclosure_level)

            # Send via transport router
            router = ::Synoptis::Transport::Router.new(config: config)
            message = {
              action: 'attestation_request',
              payload: request
            }

            delivery = router.send(target_agent, message)

            output = {
              request_id: request[:request_id],
              target_agent: target_agent,
              claim_type: claim_type,
              subject_ref: subject_ref,
              disclosure_level: disclosure_level,
              nonce: request[:nonce],
              delivery: {
                success: delivery[:success],
                transport: delivery[:transport],
                status: delivery.dig(:response, :status) || 'sent'
              }
            }

            text_content(JSON.pretty_generate(output))
          rescue ArgumentError => e
            text_content(JSON.pretty_generate({ error: 'Invalid request', message: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Request failed', message: e.message }))
          end
        end
      end
    end
  end
end
