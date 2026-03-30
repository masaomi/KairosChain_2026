# frozen_string_literal: true

require 'faraday'
require 'json'
require_relative 'adapter'
require_relative 'schema_converter'

module KairosMcp
  module SkillSets
    module LlmClient
      class AnthropicAdapter < Adapter
        API_URL = 'https://api.anthropic.com'
        API_VERSION = '2023-06-01'

        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil)
          api_key = resolve_api_key

          body = {
            model: resolve_model(model),
            max_tokens: resolve_max_tokens(max_tokens),
            messages: convert_messages(messages)
          }
          body[:system] = system if system
          body[:temperature] = resolve_temperature(temperature) unless temperature.nil?
          body[:tools] = tools if tools && !tools.empty?

          response = connection(api_key).post('/v1/messages') do |req|
            req.body = JSON.generate(body)
          end

          parse_response(response)
        rescue Faraday::TimeoutError => e
          raise ApiError.new("Request timed out: #{e.message}",
                             provider: 'anthropic', retryable: true)
        rescue Faraday::ConnectionFailed => e
          raise ApiError.new("Connection failed: #{e.message}",
                             provider: 'anthropic', retryable: true)
        rescue AuthError
          raise
        rescue StandardError => e
          raise ApiError.new("Anthropic API error: #{e.message}", provider: 'anthropic')
        end

        private

        def connection(api_key)
          Faraday.new(url: API_URL) do |f|
            f.request :json
            f.headers['x-api-key'] = api_key
            f.headers['anthropic-version'] = API_VERSION
            f.headers['Content-Type'] = 'application/json'
            f.options.timeout = timeout_seconds
            f.options.open_timeout = 10
            f.adapter Faraday.default_adapter
          end
        end

        # Convert canonical intermediate messages to Anthropic API format.
        # Canonical: role 'tool' + tool_use_id, assistant with tool_calls array.
        # Anthropic: role 'user' + tool_result content block, assistant with tool_use content blocks.
        # Messages already in Anthropic-native format pass through unchanged.
        def convert_messages(messages)
          messages.map do |msg|
            role = msg['role'] || msg[:role]
            content = msg['content'] || msg[:content]

            case role
            when 'tool'
              tool_id = msg['tool_use_id'] || msg[:tool_use_id]
              if tool_id
                {
                  'role' => 'user',
                  'content' => [{ 'type' => 'tool_result',
                                  'tool_use_id' => tool_id,
                                  'content' => content.is_a?(String) ? content : JSON.generate(content) }]
                }
              else
                msg  # Native format or unknown — pass through unchanged
              end
            when 'assistant'
              tool_calls = msg['tool_calls'] || msg[:tool_calls]
              if tool_calls && !tool_calls.empty?
                content_blocks = []
                content_blocks << { 'type' => 'text', 'text' => content } if content
                tool_calls.each do |tc|
                  content_blocks << {
                    'type' => 'tool_use',
                    'id' => tc['id'] || tc[:id],
                    'name' => tc['name'] || tc[:name],
                    'input' => tc['input'] || tc[:input] || {}
                  }
                end
                { 'role' => 'assistant', 'content' => content_blocks }
              else
                { 'role' => role, 'content' => content }
              end
            else
              { 'role' => role, 'content' => content }
            end
          end
        end

        def parse_response(response)
          body = JSON.parse(response.body)

          if response.status == 429
            backoff = response.headers['retry-after']&.to_i
            raise ApiError.new("Rate limited",
                               provider: 'anthropic', retryable: true,
                               rate_limited: true, suggested_backoff: backoff)
          end

          unless response.status == 200
            raise ApiError.new(
              body.dig('error', 'message') || "HTTP #{response.status}",
              provider: 'anthropic',
              retryable: response.status >= 500
            )
          end

          normalize_response(body)
        end

        def normalize_response(body)
          content_text = []
          tool_use = []

          (body['content'] || []).each do |block|
            case block['type']
            when 'text'
              content_text << block['text']
            when 'tool_use'
              tool_use << {
                'id' => block['id'],
                'name' => block['name'],
                'input' => block['input']
              }
            end
          end

          usage = body['usage'] || {}
          {
            'content' => content_text.empty? ? nil : content_text.join("\n"),
            'tool_use' => tool_use.empty? ? nil : tool_use,
            'stop_reason' => map_stop_reason(body['stop_reason']),
            'model' => body['model'],
            'input_tokens' => usage['input_tokens'],
            'output_tokens' => usage['output_tokens']
          }
        end

        def map_stop_reason(reason)
          case reason
          when 'end_turn' then 'end_turn'
          when 'tool_use' then 'tool_use'
          when 'max_tokens' then 'max_tokens'
          when 'stop_sequence' then 'stop_sequence'
          else reason || 'unknown'
          end
        end
      end
    end
  end
end
