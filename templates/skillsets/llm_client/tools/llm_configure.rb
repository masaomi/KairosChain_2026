# frozen_string_literal: true

require 'json'
require 'yaml'

module KairosMcp
  module SkillSets
    module LlmClient
      module Tools
        class LlmConfigure < KairosMcp::Tools::BaseTool
          def name
            'llm_configure'
          end

          def description
            'Set or change the LLM provider, model, and API key env var. ' \
              'API keys are never stored — only the environment variable name.'
          end

          def category
            :llm
          end

          def input_schema
            {
              type: 'object',
              properties: {
                provider: {
                  type: 'string',
                  description: 'Provider: "anthropic", "openai", or "local"',
                  enum: %w[anthropic openai local]
                },
                model: { type: 'string', description: 'Model name' },
                api_key_env: { type: 'string', description: 'Environment variable name for API key' },
                base_url: { type: 'string', description: 'Base URL override (for local/proxy)' },
                default_max_tokens: { type: 'integer' },
                default_temperature: { type: 'number' }
              }
            }
          end

          def call(arguments)
            config_path = File.join(__dir__, '..', 'config', 'llm_client.yml')
            config = if File.exist?(config_path)
                       YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
                     else
                       {}
                     end

            # Update only provided fields
            %w[provider model api_key_env base_url default_max_tokens default_temperature].each do |key|
              config[key] = arguments[key] if arguments.key?(key)
            end

            # Remove base_url if nil (reset to default)
            config.delete('base_url') if config['base_url'].nil?

            File.write(config_path, YAML.dump(config))

            text_content(JSON.generate({
              'status' => 'ok',
              'message' => "Configuration updated",
              'config' => config.reject { |k, _| k == 'cost_estimates' }
            }))
          rescue StandardError => e
            text_content(JSON.generate({
              'status' => 'error',
              'error' => { 'type' => 'config_error', 'message' => e.message }
            }))
          end
        end
      end
    end
  end
end
