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
            messages: messages
          }
          body[:system] = system if system
          body[:temperature] = resolve_temperature(temperature) if temperature
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

          {
            'content' => content_text.empty? ? nil : content_text.join("\n"),
            'tool_use' => tool_use.empty? ? nil : tool_use,
            'stop_reason' => map_stop_reason(body['stop_reason']),
            'model' => body['model']
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
