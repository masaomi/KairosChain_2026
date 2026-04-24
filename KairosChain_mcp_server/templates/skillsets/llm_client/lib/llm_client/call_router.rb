# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require_relative 'adapter'
require_relative 'error_taxonomy'

module KairosMcp
  module SkillSets
    module LlmClient
      # Pure-Ruby transport module shared between Tools::LlmCall (MCP server
      # context) and Headless (detached worker context). Does exactly one
      # LLM call with provider_override, AuthError→claude_code fallback,
      # UsageTracker accounting, and snapshot assembly.
      #
      # NOT responsible for: tool-schema resolution (requires MCP ToolRegistry
      # and InvocationContext; tool-aware callers must inject pre-resolved
      # schemas via args['tool_schemas'] + args['tool_names']).
      #
      # Returns a Hash matching Tools::LlmCall#call output shape.
      module CallRouter
        PROVIDER_API_KEY_DEFAULTS = {
          'anthropic' => 'ANTHROPIC_API_KEY',
          'openai' => 'OPENAI_API_KEY',
          'codex' => nil,
          'cursor' => nil,
          'claude_code' => nil,
          'bedrock' => nil,
          'local' => nil,
          'openrouter' => 'OPENROUTER_API_KEY'
        }.freeze

        module_function

        # @param args [Hash] string-keyed args (messages/system/model/effort/...)
        # @param config [Hash] base llm_client config (provider, api_key_env, ...)
        # @return [Hash] success payload with status/provider/model/response/usage/snapshot
        #                or error payload with status:'error' + error:{...}
        def perform(args, config)
          config = apply_provider_override(args, config)
          config = apply_dispatch_controls(args, config)

          requested_provider = args['provider_override']
          actual_provider    = config['provider']

          messages      = args['messages']
          system        = args['system']
          model         = args['model']
          max_tokens    = args['max_tokens']
          temperature   = args['temperature']
          output_schema = args['output_schema']
          # Pre-resolved tool schemas from caller (LlmCall resolves via registry;
          # Headless never passes tools).
          tool_schemas       = args['tool_schemas']
          tool_names_provided = args['tool_names'] || []

          adapter = build_adapter(config)

          begin
            raw_response = adapter.call(
              messages: messages, system: system, tools: tool_schemas,
              model: model, max_tokens: max_tokens, temperature: temperature,
              output_schema: output_schema
            )
          rescue AuthError => e
            if config['provider'] != 'claude_code'
              warn "[CallRouter] AuthError from #{config['provider']}, falling back to claude_code: #{e.message}"
              require_relative 'claude_code_adapter'
              actual_provider = 'claude_code'
              adapter = ClaudeCodeAdapter.new(config)
              raw_response = adapter.call(
                messages: messages, system: system, tools: tool_schemas,
                model: model, max_tokens: max_tokens, temperature: temperature,
                output_schema: output_schema
              )
            else
              raise
            end
          end

          usage = extract_usage(raw_response)
          actual_model = raw_response['model'] || model || config['model'] || 'unknown'
          {
            'status' => 'ok',
            'provider' => actual_provider,
            'requested_provider' => requested_provider,
            'model' => actual_model,
            'response' => raw_response,
            'usage' => usage,
            'snapshot' => build_snapshot(
              actual_model, system, messages, tool_names_provided, raw_response
            )
          }
        rescue ApiError => e
          {
            'status' => 'error',
            'error' => {
              'type' => ErrorTaxonomy.classify_as_string(e),
              'message' => e.message,
              'provider' => e.provider,
              'retryable' => e.retryable,
              'rate_limited' => e.rate_limited,
              'suggested_backoff_seconds' => e.suggested_backoff
            }
          }
        rescue StandardError => e
          {
            'status' => 'error',
            'error' => {
              'type' => ErrorTaxonomy.classify_as_string(e),
              'message' => e.message,
              'provider' => nil,
              'retryable' => false,
              'rate_limited' => false,
              'suggested_backoff_seconds' => nil
            }
          }
        end

        def apply_provider_override(args, config)
          requested = args['provider_override']
          return config unless requested && !requested.empty?
          overrides = { 'provider' => requested }
          # Always set api_key_env to the new provider's default — even if
          # default is nil (CLI-auth providers). Prevents carrying the prior
          # provider's api_key_env across a provider change (R2-impl P1 from
          # codex 5.5: anthropic/openai key leaking into codex/cursor config).
          overrides['api_key_env'] = PROVIDER_API_KEY_DEFAULTS[requested]
          config.merge(overrides)
        end

        def apply_dispatch_controls(args, config)
          c = config.dup
          c['dispatch_id']  = args['dispatch_id']  if args['dispatch_id']
          c['sandbox_mode'] = true                  if args['sandbox_mode']
          c['effort']       = args['effort']        if args['effort']
          c
        end

        def build_adapter(config)
          case config['provider']
          when 'openai', 'local', 'openrouter'
            require_relative 'openai_adapter'
            OpenaiAdapter.new(config)
          when 'claude_code'
            require_relative 'claude_code_adapter'
            ClaudeCodeAdapter.new(config)
          when 'codex'
            require_relative 'codex_adapter'
            CodexAdapter.new(config)
          when 'cursor'
            require_relative 'cursor_adapter'
            CursorAdapter.new(config)
          when 'bedrock'
            require_relative 'bedrock_adapter'
            BedrockAdapter.new(config)
          else
            require_relative 'anthropic_adapter'
            AnthropicAdapter.new(config)
          end
        end

        def extract_usage(response)
          input_t  = response.delete('input_tokens').to_i
          output_t = response.delete('output_tokens').to_i
          {
            'input_tokens'  => input_t,
            'output_tokens' => output_t,
            'total_tokens'  => input_t + output_t
          }
        end

        def build_snapshot(model, system, messages, tool_names, response)
          {
            'timestamp' => Time.now.iso8601,
            'model' => model,
            'system_prompt_hash' => system ? Digest::SHA256.hexdigest(system)[0..15] : nil,
            'messages_count' => messages&.length || 0,
            'tool_schemas_provided' => tool_names,
            'response_summary_length' => (response['content'] || '').length
          }
        end
      end
    end
  end
end
