# frozen_string_literal: true

require 'faraday'
require 'json'
require_relative 'adapter'
require_relative 'schema_converter'

module KairosMcp
  module SkillSets
    module LlmClient
      class OpenaiAdapter < Adapter
        API_URL = 'https://api.openai.com'

        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil)
          api_key = resolve_api_key

          all_messages = []
          all_messages << { 'role' => 'system', 'content' => system } if system
          all_messages.concat(messages)

          body = {
            model: resolve_model(model),
            max_tokens: resolve_max_tokens(max_tokens),
            messages: all_messages,
            temperature: resolve_temperature(temperature)
          }
          body[:tools] = tools if tools && !tools.empty?

          response = connection(api_key).post('/v1/chat/completions') do |req|
            req.body = JSON.generate(body)
          end

          parse_response(response)
        rescue Faraday::TimeoutError => e
          raise ApiError.new("Request timed out: #{e.message}",
                             provider: 'openai', retryable: true)
        rescue Faraday::ConnectionFailed => e
          raise ApiError.new("Connection failed: #{e.message}",
                             provider: 'openai', retryable: true)
        rescue AuthError
          raise
        rescue StandardError => e
          raise ApiError.new("OpenAI API error: #{e.message}", provider: 'openai')
        end

        private

        def connection(api_key)
          Faraday.new(url: base_url) do |f|
            f.request :json
            f.headers['Authorization'] = "Bearer #{api_key}"
            f.headers['Content-Type'] = 'application/json'
            f.options.timeout = timeout_seconds
            f.options.open_timeout = 10
            f.adapter Faraday.default_adapter
          end
        end

        def base_url
          @config['base_url'] || @config[:base_url] || API_URL
        end

        def parse_response(response)
          body = JSON.parse(response.body)

          if response.status == 429
            backoff = response.headers['retry-after']&.to_i
            raise ApiError.new("Rate limited",
                               provider: 'openai', retryable: true,
                               rate_limited: true, suggested_backoff: backoff)
          end

          unless response.status == 200
            raise ApiError.new(
              body.dig('error', 'message') || "HTTP #{response.status}",
              provider: 'openai',
              retryable: response.status >= 500
            )
          end

          normalize_response(body)
        end

        def normalize_response(body)
          choice = body.dig('choices', 0, 'message') || {}

          tool_use = nil
          if choice['tool_calls']
            tool_use = choice['tool_calls'].map do |tc|
              input = begin
                JSON.parse(tc.dig('function', 'arguments') || '{}')
              rescue JSON::ParserError
                { '_raw' => tc.dig('function', 'arguments') }
              end
              {
                'id' => tc['id'],
                'name' => tc.dig('function', 'name'),
                'input' => input
              }
            end
          end

          usage = body['usage'] || {}
          {
            'content' => choice['content'],
            'tool_use' => tool_use,
            'stop_reason' => map_stop_reason(choice['finish_reason'] || body.dig('choices', 0, 'finish_reason')),
            'model' => body['model'],
            'input_tokens' => usage['prompt_tokens'],
            'output_tokens' => usage['completion_tokens']
          }
        end

        # OpenAI finish_reason → canonical stop_reason
        def map_stop_reason(reason)
          case reason
          when 'stop' then 'end_turn'
          when 'tool_calls' then 'tool_use'
          when 'length' then 'max_tokens'
          when 'content_filter' then 'content_filter'
          else reason || 'unknown'
          end
        end
      end
    end
  end
end
