# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module LlmClient
      # Abstract LLM provider adapter. Subclasses implement #call.
      class Adapter
        attr_reader :config

        def initialize(config)
          @config = config
        end

        # Make one API call. Returns normalized response hash.
        # Subclasses MUST rescue provider errors and raise ApiError.
        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil, output_schema: nil)
          raise NotImplementedError, "#{self.class}#call not implemented"
        end

        protected

        def resolve_model(override)
          override || @config['model'] || @config[:model]
        end

        def resolve_max_tokens(override)
          override || @config['default_max_tokens'] || @config[:default_max_tokens] || 4096
        end

        def resolve_temperature(override)
          override || @config['default_temperature'] || @config[:default_temperature] || 0.7
        end

        def resolve_api_key
          env_var = @config['api_key_env'] || @config[:api_key_env]
          raise AuthError, "No api_key_env configured" unless env_var

          key = ENV[env_var]
          raise AuthError, "Environment variable '#{env_var}' is not set" unless key && !key.empty?

          key
        end

        def timeout_seconds
          @config['timeout_seconds'] || @config[:timeout_seconds] || 120
        end
      end

      class ApiError < StandardError
        attr_reader :provider, :retryable, :rate_limited, :suggested_backoff

        def initialize(message, provider: nil, retryable: false, rate_limited: false, suggested_backoff: nil)
          @provider = provider
          @retryable = retryable
          @rate_limited = rate_limited
          @suggested_backoff = suggested_backoff
          super(message)
        end
      end

      class AuthError < ApiError
        def initialize(message)
          super(message, retryable: false)
        end
      end
    end
  end
end
