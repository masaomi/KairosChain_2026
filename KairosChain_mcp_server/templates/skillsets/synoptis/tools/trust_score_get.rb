# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class TrustScoreGet < KairosMcp::Tools::BaseTool
          def name
            'trust_score_get'
          end

          def description
            'Get trust score and breakdown for an agent. Returns quality, freshness, diversity, revocation and velocity metrics, plus anomaly flags for potential collusion detection.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[synoptis trust score reputation attestation]
          end

          def related_tools
            %w[attestation_list attestation_verify]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                agent_id: {
                  type: 'string',
                  description: 'Agent ID to calculate trust score for'
                },
                window_days: {
                  type: 'number',
                  description: 'Number of days to consider for scoring. Default: 180'
                }
              },
              required: %w[agent_id]
            }
          end

          def call(arguments)
            agent_id = arguments['agent_id']
            window_days = (arguments['window_days'] || 180).to_i

            config = ::Synoptis.load_config
            storage_path = ::Synoptis.storage_path(config)
            registry = ::Synoptis::Registry::FileRegistry.new(storage_path: storage_path)

            # Calculate trust score
            scorer = ::Synoptis::TrustScorer.new(registry: registry, config: config)
            score_result = scorer.score(agent_id, window_days: window_days)

            # Analyze graph for anomalies
            analyzer = ::Synoptis::GraphAnalyzer.new(registry: registry, config: config)
            graph_result = analyzer.analyze(agent_id)

            # Merge anomaly flags
            all_flags = score_result[:anomaly_flags] + graph_result[:anomaly_flags]

            output = {
              agent_id: agent_id,
              score: score_result[:score],
              breakdown: score_result[:breakdown],
              attestation_count: score_result[:attestation_count],
              graph_metrics: graph_result[:metrics],
              anomaly_flags: all_flags,
              window_days: window_days,
              note: all_flags.empty? ? nil : 'Anomaly flags are advisory only. Final trust decisions should involve human judgment.'
            }.compact

            text_content(JSON.pretty_generate(output))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Trust score calculation failed', message: e.message }))
          end
        end
      end
    end
  end
end
