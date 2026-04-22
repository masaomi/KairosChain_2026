# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
# Only load always-needed modules at startup.
# Provider adapters are lazy-loaded in build_adapter() to avoid
# crashing when optional gems (faraday, aws-sdk) are not installed.
require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/claude_code_adapter'
require_relative '../lib/llm_client/schema_converter'
require_relative '../lib/llm_client/error_taxonomy'

module KairosMcp
  module SkillSets
    module LlmClient
      module Tools
        class LlmCall < KairosMcp::Tools::BaseTool
          def name
            'llm_call'
          end

          def description
            'Make exactly one LLM API call. Returns response including tool_use requests. ' \
              'Does NOT execute tools, loop, retry, or fall back. Pure transport.'
          end

          def category
            :llm
          end

          def usecase_tags
            %w[llm api call provider transport]
          end

          def related_tools
            %w[llm_configure llm_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                messages: {
                  type: 'array',
                  description: 'Conversation messages array (role + content)',
                  items: { type: 'object' }
                },
                system: {
                  type: 'string',
                  description: 'System prompt (optional)'
                },
                tools: {
                  type: 'array',
                  description: 'Tool names or fnmatch patterns to include as LLM tools (optional)',
                  items: { type: 'string' }
                },
                invocation_context_json: {
                  type: 'string',
                  description: 'Serialized InvocationContext for policy-filtered schema discovery (optional)'
                },
                model: {
                  type: 'string',
                  description: 'Model override (optional, uses config default)'
                },
                max_tokens: {
                  type: 'integer',
                  description: 'Max tokens override (optional)'
                },
                temperature: {
                  type: 'number',
                  description: 'Temperature override (optional)'
                },
                output_schema: {
                  type: 'object',
                  description: 'JSON Schema for structured output (optional). When provided, ' \
                    'the LLM is instructed to return only valid JSON matching this schema. ' \
                    'Note: OpenAI strict mode requires all properties listed in "required" array.'
                }
              },
              required: ['messages']
            }
          end

          def call(arguments)
            config = load_config
            adapter = build_adapter(config)
            messages = arguments['messages']
            system = arguments['system']
            model = arguments['model']
            max_tokens = arguments['max_tokens']
            temperature = arguments['temperature']
            output_schema = arguments['output_schema']

            # Resolve tool schemas with policy filtering
            tool_schemas = nil
            tool_names_provided = []
            if arguments['tools'] && !arguments['tools'].empty?
              ctx = deserialize_context(arguments['invocation_context_json'])
              tool_schemas, tool_names_provided = resolve_and_convert_tools(
                arguments['tools'], ctx, config
              )
            end

            # Make the API call (with auto-fallback to claude_code on AuthError)
            raw_response = begin
              adapter.call(
                messages: messages,
                system: system,
                tools: tool_schemas,
                model: model,
                max_tokens: max_tokens,
                temperature: temperature,
                output_schema: output_schema
              )
            rescue AuthError => e
              # P4 fix: auto-fallback to claude_code adapter when API key is missing
              if config['provider'] != 'claude_code'
                warn "[llm_call] AuthError from #{config['provider']}, falling back to claude_code: #{e.message}"
                adapter = ClaudeCodeAdapter.new(config)
                adapter.call(
                  messages: messages,
                  system: system,
                  tools: tool_schemas,
                  model: model,
                  max_tokens: max_tokens,
                  temperature: temperature,
                  output_schema: output_schema
                )
              else
                raise
              end
            end

            # Track usage
            usage = extract_usage(raw_response, adapter)

            # Build success payload
            actual_model = raw_response['model'] || model || config['model'] || 'unknown'
            payload = {
              'status' => 'ok',
              'provider' => config['provider'],
              'model' => actual_model,
              'response' => raw_response,
              'usage' => usage,
              'snapshot' => build_snapshot(
                actual_model, system, messages, tool_names_provided, raw_response
              )
            }

            UsageTracker.record(usage)
            text_content(JSON.generate(payload))
          rescue KairosMcp::SkillSets::LlmClient::ApiError => e
            # CF-7 fix: use ErrorTaxonomy for consistent type classification
            text_content(JSON.generate({
              'status' => 'error',
              'error' => {
                'type' => ErrorTaxonomy.classify_as_string(e),
                'message' => e.message,
                'provider' => e.provider,
                'retryable' => e.retryable,
                'rate_limited' => e.rate_limited,
                'suggested_backoff_seconds' => e.suggested_backoff
              }
            }))
          rescue StandardError => e
            text_content(JSON.generate({
              'status' => 'error',
              'error' => {
                'type' => classify_error(e),
                'message' => e.message,
                'provider' => nil,
                'retryable' => false,
                'rate_limited' => false,
                'suggested_backoff_seconds' => nil
              }
            }))
          end

          private

          def load_config
            config_path = File.join(__dir__, '..', 'config', 'llm_client.yml')
            if File.exist?(config_path)
              require 'yaml'
              YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
            else
              { 'provider' => 'anthropic', 'model' => 'claude-sonnet-4-6',
                'api_key_env' => 'ANTHROPIC_API_KEY' }
            end
          end

          def build_adapter(config)
            case config['provider']
            when 'openai', 'local', 'openrouter'
              require_relative '../lib/llm_client/openai_adapter'
              OpenaiAdapter.new(config)
            when 'claude_code'
              ClaudeCodeAdapter.new(config)
            when 'bedrock'
              require_relative '../lib/llm_client/bedrock_adapter'
              BedrockAdapter.new(config)
            else
              require_relative '../lib/llm_client/anthropic_adapter'
              AnthropicAdapter.new(config)
            end
          end

          def deserialize_context(json_string)
            return nil if json_string.nil? || json_string.empty?

            ctx = KairosMcp::InvocationContext.from_json(json_string)
            return ctx if ctx

            # Fail-closed: malformed context returns a deny-all context
            KairosMcp::InvocationContext.new(whitelist: [])
          rescue StandardError
            # Parse error → deny-all (fail-closed, not fail-open)
            KairosMcp::InvocationContext.new(whitelist: [])
          end

          def resolve_and_convert_tools(patterns, invocation_context, config)
            return [nil, []] unless @registry

            all_schemas = @registry.list_tools

            # Expand fnmatch patterns
            resolved = all_schemas.select { |s|
              patterns.any? { |pat| File.fnmatch(pat, s[:name]) }
            }

            # Policy filter: only include tools the context allows
            if invocation_context
              resolved = resolved.select { |s| invocation_context.allowed?(s[:name]) }
            end

            tool_names = resolved.map { |s| s[:name] }

            # Convert to provider format
            target = config['provider'] == 'openai' ? :openai : :anthropic
            result = SchemaConverter.convert_batch(resolved, target)

            unless result[:errors].empty?
              warn "[llm_call] Schema conversion errors: #{result[:errors].map { |e| e[:tool] }.join(', ')}"
            end

            [result[:schemas], tool_names]
          end

          def extract_usage(response, adapter)
            input_t = response.delete('input_tokens').to_i
            output_t = response.delete('output_tokens').to_i
            {
              'input_tokens' => input_t,
              'output_tokens' => output_t,
              'total_tokens' => input_t + output_t
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

          def classify_error(error)
            ErrorTaxonomy.classify_as_string(error)
          end
        end

        # In-memory usage tracker (per ToolRegistry lifecycle)
        module UsageTracker
          @mutex = Mutex.new
          @stats = { calls: 0, input_tokens: 0, output_tokens: 0 }

          def self.record(usage)
            @mutex.synchronize do
              @stats[:calls] += 1
              @stats[:input_tokens] += usage['input_tokens'].to_i
              @stats[:output_tokens] += usage['output_tokens'].to_i
            end
          end

          def self.stats
            @mutex.synchronize { @stats.dup }
          end

          def self.reset!
            @mutex.synchronize { @stats = { calls: 0, input_tokens: 0, output_tokens: 0 } }
          end
        end
      end
    end
  end
end
