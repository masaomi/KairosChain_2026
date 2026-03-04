# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationVerify < KairosMcp::Tools::BaseTool
          def name
            'attestation_verify'
          end

          def description
            'Verify an attestation proof. Checks signature validity, evidence hash, revocation status, and expiry. Returns detailed verification result with reasons.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[synoptis attestation verify signature trust proof]
          end

          def related_tools
            %w[attestation_list attestation_revoke]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                proof_payload: {
                  type: 'string',
                  description: 'JSON string of the Proof Envelope to verify'
                },
                mode: {
                  type: 'string',
                  enum: %w[signature_only full],
                  description: 'Verification mode: signature_only (just signature check) or full (all checks including revocation and expiry). Default: full'
                },
                public_key_pem: {
                  type: 'string',
                  description: 'PEM-encoded public key of the attester for signature verification (optional — will attempt AgentRegistry lookup if omitted)'
                }
              },
              required: %w[proof_payload]
            }
          end

          def call(arguments)
            proof_json = arguments['proof_payload']
            mode = arguments['mode'] || 'full'
            public_key_pem = arguments['public_key_pem']

            proof_hash = JSON.parse(proof_json, symbolize_names: true)
            proof = ::Synoptis::ProofEnvelope.from_h(proof_hash)

            config = ::Synoptis.load_config
            storage_path = ::Synoptis.storage_path(config)
            registry = ::Synoptis::Registry::FileRegistry.new(storage_path: storage_path)
            verifier = ::Synoptis::Verifier.new(registry: registry, config: config)

            options = {}
            options[:public_key] = public_key_pem if public_key_pem

            if mode == 'signature_only'
              options[:check_revocation] = false
              options[:check_expiry] = false
            end

            result = verifier.verify(proof, options)

            output = {
              proof_id: proof.proof_id,
              valid: result[:valid],
              mode: mode,
              reasons: result[:reasons],
              trust_hints: result[:trust_hints],
              claim_type: proof.claim_type,
              attester_id: proof.attester_id,
              attestee_id: proof.attestee_id,
              status: proof.status,
              issued_at: proof.issued_at,
              expires_at: proof.expires_at
            }

            text_content(JSON.pretty_generate(output))
          rescue JSON::ParserError => e
            text_content(JSON.pretty_generate({ error: 'Invalid JSON in proof_payload', message: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Verification failed', message: e.message }))
          end
        end
      end
    end
  end
end
