# frozen_string_literal: true

require 'json'
require 'yaml'

module KairosMcp
  module SkillSets
    module LlmClient
      module Tools
        class LlmStatus < KairosMcp::Tools::BaseTool
          def name
            'llm_status'
          end

          def description
            'Show current LLM provider configuration and session usage statistics.'
          end

          def category
            :llm
          end

          def input_schema
            { type: 'object', properties: {} }
          end

          def call(arguments)
            config_path = File.join(__dir__, '..', 'config', 'llm_client.yml')
            config = if File.exist?(config_path)
                       YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
                     else
                       {}
                     end

            api_key_env = config['api_key_env']
            api_key_set = api_key_env && ENV[api_key_env] && !ENV[api_key_env].empty?

            stats = UsageTracker.stats
            cost_estimates = config['cost_estimates'] || {}
            model = config['model'] || 'unknown'
            model_cost = cost_estimates[model] || {}

            estimated_cost = 0.0
            if model_cost.any?
              input_cost = (model_cost['input'] || model_cost[:input] || 0).to_f
              output_cost = (model_cost['output'] || model_cost[:output] || 0).to_f
              estimated_cost = (stats[:input_tokens] * input_cost + stats[:output_tokens] * output_cost) / 1_000_000.0
            end

            text_content(JSON.generate({
              'provider' => config['provider'] || 'not configured',
              'model' => model,
              'api_key_configured' => api_key_set || false,
              'session_usage' => {
                'total_calls' => stats[:calls],
                'total_input_tokens' => stats[:input_tokens],
                'total_output_tokens' => stats[:output_tokens],
                'total_cost_estimate_usd' => estimated_cost.round(4)
              }
            }))
          end
        end
      end
    end
  end
end
