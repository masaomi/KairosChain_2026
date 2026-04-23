# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/persona_assembly'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      module Tools
        # Phase 2 of the orchestrator delegation protocol.
        #
        # Receives the orchestrator's persona team review (assembled in the
        # caller's own context via Agent tool), merges it with the subprocess
        # reviewer results persisted by Phase 1, and runs Consensus to produce
        # the final verdict.
        #
        # Idempotency: a second collect with the same token returns the cached
        # final result rather than re-running consensus.
        class MultiLlmReviewCollect < KairosMcp::Tools::BaseTool
          def name
            'multi_llm_review_collect'
          end

          def description
            'Submit orchestrator-side persona team review to complete a delegated ' \
              'multi_llm_review. Use this only after multi_llm_review returned ' \
              'status="delegation_pending" with a collect_token. The orchestrator ' \
              'must provide 2-4 persona reviews (each: persona, verdict, findings, reasoning).'
          end

          def category
            :review
          end

          def usecase_tags
            %w[review multi-llm consensus delegation]
          end

          def related_tools
            %w[multi_llm_review]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                collect_token: {
                  type: 'string',
                  description: 'UUID v4 token returned by multi_llm_review when ' \
                    'orchestrator_strategy="delegate" was used.'
                },
                orchestrator_reviews: {
                  type: 'array',
                  description: "Persona team review results (#{PersonaAssembly::MIN_PERSONAS}-" \
                    "#{PersonaAssembly::MAX_PERSONAS} entries). Each: " \
                    '{persona: string, verdict: APPROVE|REVISE|REJECT, ' \
                    'findings: [{severity, issue}, ...], reasoning: string}',
                  items: {
                    type: 'object',
                    properties: {
                      persona: { type: 'string' },
                      verdict: { type: 'string', enum: %w[APPROVE REVISE REJECT] },
                      reasoning: { type: 'string' },
                      findings: {
                        type: 'array',
                        items: { type: 'object' }
                      }
                    },
                    required: %w[persona verdict]
                  },
                  minItems: PersonaAssembly::MIN_PERSONAS,
                  maxItems: PersonaAssembly::MAX_PERSONAS
                }
              },
              required: %w[collect_token orchestrator_reviews]
            }
          end

          def call(arguments)
            PendingState.cleanup_expired! rescue nil

            token = arguments['collect_token']
            unless PendingState.valid_token?(token)
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => 'invalid collect_token format (expected UUID v4)'
              }))
            end

            state = PendingState.load(token)
            unless state
              return text_content(JSON.generate({
                'status' => 'expired_or_unknown_token',
                'collect_token' => token
              }))
            end

            # Idempotency: replay cached final result on duplicate collect.
            if state['collected'] && state['final_payload']
              cached = state['final_payload'].dup
              cached['idempotent_replay'] = true
              return text_content(JSON.generate(cached))
            end

            # Deadline check (defense-in-depth; GC also handles this).
            deadline = (Time.iso8601(state['collect_deadline']) rescue nil)
            if deadline && Time.now > deadline
              PendingState.delete(token)
              return text_content(JSON.generate({
                'status' => 'expired_or_unknown_token',
                'collect_token' => token,
                'reason' => 'past collect_deadline'
              }))
            end

            reviews = arguments['orchestrator_reviews']
            begin
              orchestrator_entry = PersonaAssembly.assemble(
                reviews, state['orchestrator_model']
              )
            rescue ArgumentError => e
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => "invalid orchestrator_reviews: #{e.message}"
              }))
            end

            subprocess_entries = (state['subprocess_results'] || []).map do |r|
              deserialize_review(r)
            end

            all_reviews = subprocess_entries + [orchestrator_entry]

            consensus = Consensus.aggregate(
              all_reviews,
              state['convergence_rule'] || '3/4 APPROVE',
              min_quorum: state['min_quorum'] || 2
            )

            payload = {
              'status' => 'ok',
              'verdict' => consensus[:verdict],
              'convergence' => hash_to_string_keys(consensus[:convergence]),
              'reviews' => consensus[:reviews].map { |r|
                {
                  'role_label' => r[:role_label],
                  'provider' => r[:provider],
                  'model' => r[:model],
                  'verdict' => r[:verdict],
                  'elapsed_seconds' => r[:elapsed_seconds],
                  'error' => r[:error],
                  'raw_text_length' => r[:raw_text].to_s.length
                }
              },
              'aggregated_findings' => consensus[:aggregated_findings].map { |f|
                hash_to_string_keys(f)
              },
              'review_round' => state['review_round'],
              'review_type' => state['review_type'],
              'artifact_name' => state['artifact_name'],
              'complexity' => state['complexity'],
              'llm_calls' => all_reviews.count { |r| r[:status] == :success },
              'orchestrator_model' => state['orchestrator_model'],
              'orchestrator_strategy' => 'delegate',
              'persona_count' => reviews.size
            }

            # Cache for idempotent replay; mark collected so GC keeps it
            # for the retention window.
            state['collected'] = true
            state['collected_at'] = Time.now.iso8601
            state['final_payload'] = payload
            PendingState.write(token, state)

            text_content(JSON.generate(payload))
          rescue StandardError => e
            text_content(JSON.generate({
              'status' => 'error',
              'error' => "#{e.class}: #{e.message}"
            }))
          end

          private

          def deserialize_review(h)
            {
              role_label: h['role_label'],
              provider: h['provider'],
              model: h['model'],
              raw_text: h['raw_text'].to_s,
              elapsed_seconds: h['elapsed_seconds'] || 0,
              error: h['error'],
              status: (h['status'] || 'success').to_sym
            }
          end

          def hash_to_string_keys(hash)
            return hash unless hash.is_a?(Hash)
            hash.transform_keys(&:to_s)
          end
        end
      end
    end
  end
end
