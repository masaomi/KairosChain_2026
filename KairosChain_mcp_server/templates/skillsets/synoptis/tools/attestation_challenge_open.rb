# frozen_string_literal: true

require 'json'
require 'digest'

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationChallengeOpen < KairosMcp::Tools::BaseTool
          def name
            'attestation_challenge_open'
          end

          def description
            'Open a challenge against an attestation proof. The attester has a response window (default: 72h) to defend or accept the challenge.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[synoptis attestation challenge dispute trust]
          end

          def related_tools
            %w[attestation_challenge_resolve attestation_verify attestation_list]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                proof_id: {
                  type: 'string',
                  description: 'ID of the attestation proof to challenge'
                },
                reason: {
                  type: 'string',
                  description: 'Reason for challenging the attestation'
                },
                evidence: {
                  type: 'string',
                  description: 'Optional JSON string of evidence supporting the challenge'
                }
              },
              required: %w[proof_id reason]
            }
          end

          def call(arguments)
            proof_id = arguments['proof_id']
            reason = arguments['reason']
            evidence = arguments['evidence']

            config = ::Synoptis.load_config
            storage_path = ::Synoptis.storage_path(config)
            registry = ::Synoptis::Registry::FileRegistry.new(storage_path: storage_path)
            manager = ::Synoptis::ChallengeManager.new(registry: registry, config: config)

            challenger_id = resolve_agent_id

            evidence_hash = nil
            if evidence
              evidence_hash = "sha256:#{Digest::SHA256.hexdigest(evidence)}"
            end

            challenge = manager.open_challenge(proof_id, challenger_id, reason, evidence_hash: evidence_hash)

            # Notify attester via transport (best effort)
            proof_data = registry.find_proof(proof_id)
            if proof_data
              attester_id = proof_data[:attester_id]
              if attester_id && attester_id != challenger_id
                router = ::Synoptis::Transport::Router.new(config: config)
                router.send(attester_id, {
                  action: 'attestation_challenge',
                  payload: {
                    challenge_id: challenge[:challenge_id],
                    challenged_proof_id: proof_id,
                    reason: reason,
                    deadline_at: challenge[:deadline_at]
                  }
                })
              end
            end

            output = {
              challenge_id: challenge[:challenge_id],
              challenged_proof_id: proof_id,
              challenger_id: challenger_id,
              reason: reason,
              status: challenge[:status],
              deadline_at: challenge[:deadline_at],
              created_at: challenge[:created_at]
            }

            text_content(JSON.pretty_generate(output))
          rescue ArgumentError => e
            text_content(JSON.pretty_generate({ error: 'Invalid challenge', message: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Challenge failed', message: e.message }))
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
