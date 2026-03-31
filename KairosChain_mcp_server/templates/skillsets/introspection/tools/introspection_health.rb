# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Introspection
      module Tools
        # Calculate health scores for L1 knowledge entries.
        # Uses Synoptis TrustScorer when available, falls back to staleness-only scoring.
        class IntrospectionHealth < ::KairosMcp::Tools::BaseTool
          def name
            'introspection_health'
          end

          def description
            'Calculate health scores for L1 knowledge entries. ' \
            'Uses Synoptis TrustScorer when available, falls back to staleness-only scoring.'
          end

          def category
            :introspection
          end

          def usecase_tags
            %w[health knowledge staleness trust introspection]
          end

          def related_tools
            %w[introspection_check knowledge_list]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                name: { type: 'string', description: 'Specific L1 knowledge name (optional, omit for all)' },
                sort_by: { type: 'string', enum: %w[score name], description: 'Sort order (default: score)' },
                below_threshold: { type: 'number', description: 'Only show entries below this score (0.0-1.0)' }
              }
            }
          end

          def call(arguments)
            scorer = HealthScorer.new(user_context: @safety&.current_user, config: load_config)
            result = if arguments['name']
                       scorer.score_single(arguments['name'])
                     else
                       scorer.score_l1
                     end

            # Filter
            if arguments['below_threshold'] && result[:entries]
              result[:entries].select! { |e| e[:health_score] < arguments['below_threshold'] }
            end

            # Sort
            if arguments['sort_by'] == 'name' && result[:entries]
              result[:entries].sort_by! { |e| e[:name] }
            end

            text_content(JSON.pretty_generate(result))
          end

          private

          def load_config
            config_path = File.join(
              KairosMcp.skillsets_dir, 'introspection', 'config', 'introspection.yml'
            )
            return {} unless File.exist?(config_path)
            YAML.safe_load(File.read(config_path)) || {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
