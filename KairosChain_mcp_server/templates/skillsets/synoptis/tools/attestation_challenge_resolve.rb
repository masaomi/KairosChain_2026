# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationChallengeResolve < KairosMcp::Tools::BaseTool
          def name
            'attestation_challenge_resolve'
          end

          def description
            'Resolve an open challenge. Decision: uphold (attestation remains valid) or invalidate (attestation is revoked). Affects trust scores of both challenger and attester.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[synoptis attestation challenge resolve trust]
          end

          def related_tools
            %w[attestation_challenge_open attestation_verify trust_score_get]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                challenge_id: {
                  type: 'string',
                  description: 'ID of the challenge to resolve'
                },
                decision: {
                  type: 'string',
                  enum: %w[uphold invalidate],
                  description: 'Decision: uphold (challenge rejected, attestation valid) or invalidate (challenge accepted, attestation revoked)'
                },
                response: {
                  type: 'string',
                  description: 'Optional response text explaining the decision'
                }
              },
              required: %w[challenge_id decision]
            }
          end

          def call(arguments)
            challenge_id = arguments['challenge_id']
            decision = arguments['decision']
            response = arguments['response']

            config = ::Synoptis.load_config
            storage_path = ::Synoptis.storage_path(config)
            registry = ::Synoptis::Registry::FileRegistry.new(storage_path: storage_path)
            manager = ::Synoptis::ChallengeManager.new(registry: registry, config: config)

            result = manager.resolve_challenge(challenge_id, decision, response: response)

            # Notify relevant parties via transport (best effort)
            notify_resolution(config, registry, result)

            output = {
              challenge_id: result[:challenge_id],
              challenged_proof_id: result[:challenged_proof_id],
              status: result[:status],
              decision: decision,
              response: result[:response],
              response_at: result[:response_at],
              resolved_at: result[:resolved_at]
            }

            text_content(JSON.pretty_generate(output))
          rescue ArgumentError => e
            text_content(JSON.pretty_generate({ error: 'Invalid resolution', message: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Resolution failed', message: e.message }))
          end

          private

          def notify_resolution(config, registry, challenge)
            router = ::Synoptis::Transport::Router.new(config: config)
            proof_data = registry.find_proof(challenge[:challenged_proof_id])
            return unless proof_data

            notification = {
              action: 'attestation_response',
              payload: {
                challenge_id: challenge[:challenge_id],
                status: challenge[:status],
                resolved_at: challenge[:resolved_at]
              }
            }

            # Notify challenger
            router.send(challenge[:challenger_id], notification) if challenge[:challenger_id]

            # Notify attester
            attester_id = proof_data[:attester_id]
            router.send(attester_id, notification) if attester_id && attester_id != challenge[:challenger_id]
          rescue StandardError
            # Best effort notification — don't fail the resolution
          end
        end
      end
    end
  end
end
