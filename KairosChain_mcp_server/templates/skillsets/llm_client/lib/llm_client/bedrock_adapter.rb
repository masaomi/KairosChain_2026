# frozen_string_literal: true

require 'json'
require_relative 'adapter'
require_relative 'schema_converter'

module KairosMcp
  module SkillSets
    module LlmClient
      # Adapter for AWS Bedrock (Claude on AWS).
      # Data stays within AWS — no external LLM provider data transfer.
      # Requires: gem 'aws-sdk-bedrockruntime'
      class BedrockAdapter < Adapter
        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil)
          client = bedrock_client

          converted_messages = convert_messages(messages)

          payload = {
            anthropic_version: 'bedrock-2023-05-31',
            max_tokens: resolve_max_tokens(max_tokens),
            messages: converted_messages
          }
          payload[:system] = system if system
          payload[:temperature] = resolve_temperature(temperature) unless temperature.nil?

          if tools && !tools.empty?
            payload[:tools] = tools.map do |t|
              {
                name: t[:name] || t['name'],
                description: t[:description] || t['description'],
                input_schema: t[:input_schema] || t['input_schema'] || t[:inputSchema] || t['inputSchema']
              }
            end
          end

          response = client.invoke_model(
            model_id: resolve_model(model),
            body: JSON.generate(payload),
            content_type: 'application/json',
            accept: 'application/json'
          )

          body = JSON.parse(response.body.string)
          normalize_response(body)
        rescue LoadError
          raise ApiError.new(
            "Bedrock adapter requires 'aws-sdk-bedrockruntime' gem. " \
            "Add to Gemfile: gem 'aws-sdk-bedrockruntime', '~> 1.0'",
            provider: 'bedrock', retryable: false
          )
        rescue AuthError
          raise
        rescue StandardError => e
          if e.class.name.include?('Aws::')
            retryable = e.respond_to?(:retryable?) ? e.retryable? : false
            raise ApiError.new(
              "Bedrock API error: #{e.message}",
              provider: 'bedrock', retryable: retryable
            )
          end
          raise ApiError.new("Bedrock error: #{e.message}", provider: 'bedrock')
        end

        private

        def bedrock_client
          begin
            require 'aws-sdk-bedrockruntime'
          rescue LoadError
            raise LoadError, "aws-sdk-bedrockruntime not installed"
          end

          region = @config['aws_region'] || @config[:aws_region] ||
                   ENV.fetch('AWS_REGION', 'us-east-1')

          Aws::BedrockRuntime::Client.new(region: region)
        end

        def resolve_model(override)
          override || @config['model'] || @config[:model] ||
            ENV.fetch('AWS_BEDROCK_MODEL_ID', 'anthropic.claude-sonnet-4-5-20250929-v1:0')
        end

        def convert_messages(messages)
          messages.map do |msg|
            role = msg['role'] || msg[:role]
            content = msg['content'] || msg[:content]

            case role
            when 'system'
              # Bedrock system is a top-level parameter, not a message.
              # If caller passes system in messages, convert to user context.
              { role: 'user', content: "[System Context]: #{content}" }
            when 'tool'
              tool_id = msg['tool_use_id'] || msg[:tool_use_id]
              {
                role: 'user',
                content: [{
                  type: 'tool_result',
                  tool_use_id: tool_id,
                  content: content.is_a?(String) ? content : JSON.generate(content)
                }]
              }
            when 'assistant'
              tool_calls = msg['tool_calls'] || msg[:tool_calls]
              if tool_calls
                content_blocks = []
                content_blocks << { type: 'text', text: content } if content
                tool_calls.each do |tc|
                  content_blocks << {
                    type: 'tool_use',
                    id: tc['id'] || tc[:id],
                    name: tc['name'] || tc[:name],
                    input: tc['input'] || tc[:input] || tc['arguments'] || tc[:arguments] || {}
                  }
                end
                { role: 'assistant', content: content_blocks }
              else
                { role: 'assistant', content: content }
              end
            else
              { role: role, content: content }
            end
          end
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
