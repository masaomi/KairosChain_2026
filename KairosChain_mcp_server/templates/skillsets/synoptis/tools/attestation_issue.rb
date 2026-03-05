# frozen_string_literal: true

require 'json'
require 'securerandom'

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationIssue < KairosMcp::Tools::BaseTool
          def name
            'attestation_issue'
          end

          def description
            'Issue a signed attestation proof. Verifies evidence, builds a Proof Envelope with cryptographic signature, and delivers it to the attestee via transport.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[synoptis attestation issue sign proof trust]
          end

          def related_tools
            %w[attestation_request attestation_verify attestation_list]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                request_id: {
                  type: 'string',
                  description: 'Request ID from a previous attestation_request (for audit trail only)'
                },
                target_agent: {
                  type: 'string',
                  description: 'Agent ID of the attestation recipient (attestee)'
                },
                claim_type: {
                  type: 'string',
                  enum: ::Synoptis::ClaimTypes.all_types,
                  description: 'Type of claim being attested'
                },
                subject_ref: {
                  type: 'string',
                  description: 'Reference to the subject being attested'
                },
                evidence: {
                  type: 'string',
                  description: 'JSON string of evidence data supporting the attestation'
                },
                disclosure_level: {
                  type: 'string',
                  enum: %w[existence_only full],
                  description: 'Level of evidence disclosure. Default: existence_only'
                },
                expires_in_days: {
                  type: 'number',
                  description: 'Number of days until the attestation expires. Default: from config (180)'
                }
              },
              required: %w[target_agent claim_type subject_ref evidence]
            }
          end

          def call(arguments)
            target_agent = arguments['target_agent']
            claim_type = arguments['claim_type']
            subject_ref = arguments['subject_ref']
            evidence = JSON.parse(arguments['evidence'])
            disclosure_level = arguments['disclosure_level'] || 'existence_only'
            expires_in_days = arguments['expires_in_days']

            # Validate expires_in_days
            if expires_in_days && expires_in_days.to_i < 1
              raise ArgumentError, 'expires_in_days must be at least 1'
            end

            config = ::Synoptis.load_config

            # Override expiry if specified
            if expires_in_days
              config = config.dup
              config['attestation'] = (config['attestation'] || {}).merge('default_expiry_days' => expires_in_days.to_i)
            end

            engine = ::Synoptis.engine(config: config)

            # Determine attester identity
            attester_id = resolve_attester_id

            # Build the request structure — always use fresh nonce
            request = {
              target_id: target_agent,
              claim_type: claim_type,
              subject_ref: subject_ref,
              disclosure_level: disclosure_level,
              nonce: SecureRandom.hex(16)
            }

            # Get crypto for signing
            crypto = resolve_crypto

            # Build and sign the proof
            proof = engine.build_proof(request, evidence, crypto, attester_id: attester_id)

            # Deliver to attestee via transport
            router = ::Synoptis::Transport::Router.new(config: config)
            message = {
              action: 'attestation_proof',
              payload: proof.to_h
            }

            delivery = router.send(target_agent, message)

            output = {
              proof_id: proof.proof_id,
              claim_type: proof.claim_type,
              attester_id: proof.attester_id,
              attestee_id: proof.attestee_id,
              subject_ref: proof.subject_ref,
              status: proof.status,
              issued_at: proof.issued_at,
              expires_at: proof.expires_at,
              signature: proof.signature ? 'present' : 'missing',
              delivery: {
                success: delivery[:success],
                transport: delivery[:transport]
              }
            }

            text_content(JSON.pretty_generate(output))
          rescue JSON::ParserError => e
            text_content(JSON.pretty_generate({ error: 'Invalid JSON in evidence', message: e.message }))
          rescue ArgumentError => e
            text_content(JSON.pretty_generate({ error: 'Invalid attestation', message: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Issue failed', message: e.message }))
          end

          private

          def resolve_attester_id
            return ENV['SYNOPTIS_AGENT_ID'] if ENV['SYNOPTIS_AGENT_ID']

            if defined?(KairosMcp) && KairosMcp.respond_to?(:agent_id)
              KairosMcp.agent_id
            else
              raise 'Agent identity not available'
            end
          end

          def resolve_crypto
            if defined?(KairosMcp) && defined?(MMP::Identity)
              identity = MMP::Identity.new(
                workspace_root: KairosMcp.data_dir,
                config: MMP.load_config
              )
              identity.crypto
            elsif defined?(MMP::Crypto)
              $stderr.puts '[Synoptis] WARNING: Using ephemeral crypto key — signatures will not be verifiable across sessions'
              MMP::Crypto.new
            else
              raise 'MMP::Crypto not available for signing'
            end
          end
        end
      end
    end
  end
end
