# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      # Adapter that uses Claude Code CLI as the LLM backend.
      # No API costs — uses the Claude Code subscription.
      # Invokes `claude -p --output-format json` as a subprocess.
      class ClaudeCodeAdapter < Adapter
        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil)
          prompt = build_prompt(messages, system, tools)

          args = ['claude', '-p', '--output-format', 'json']
          args += ['--model', model] if model

          stdout, stderr, status = Open3.capture3(*args, stdin_data: prompt)

          unless status.success?
            raise ApiError.new(
              "Claude Code exited with status #{status.exitstatus}: #{stderr[0..200]}",
              provider: 'claude_code', retryable: false
            )
          end

          parse_response(stdout)
        rescue Errno::ENOENT
          raise ApiError.new(
            "Claude Code CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code",
            provider: 'claude_code', retryable: false
          )
        rescue ApiError
          raise
        rescue StandardError => e
          raise ApiError.new("Claude Code error: #{e.message}", provider: 'claude_code')
        end

        private

        def build_prompt(messages, system, tools)
          parts = []

          if system
            parts << "[System]: #{system}"
            parts << ""
          end

          if tools && !tools.empty?
            parts << "[Available tools - respond with JSON when you want to use a tool]:"
            tools.each do |t|
              name = t[:name] || t['name']
              desc = t[:description] || t['description']
              schema = t[:input_schema] || t['input_schema'] || t[:inputSchema] || t['inputSchema']
              parts << "- #{name}: #{desc}"
              if schema && schema.is_a?(Hash) && schema['properties']
                params = schema['properties'].keys.join(', ')
                parts << "  Parameters: #{params}"
              end
            end
            parts << ""
            parts << "To use a tool, include in your response:"
            parts << '```json'
            parts << '{"tool_use": [{"name": "tool_name", "input": {"param": "value"}}]}'
            parts << '```'
            parts << ""
          end

          messages.each do |msg|
            role = msg['role'] || msg[:role]
            content = msg['content'] || msg[:content]
            case role
            when 'user'
              parts << content.to_s
            when 'assistant'
              parts << "[Previous assistant response]: #{content}"
            when 'tool'
              tool_id = msg['tool_use_id'] || msg[:tool_use_id] || 'unknown'
              parts << "[Tool result for #{tool_id}]: #{content}"
            end
          end

          parts.join("\n")
        end

        def parse_response(stdout)
          data = JSON.parse(stdout)

          unless data['type'] == 'result'
            raise ApiError.new(
              "Unexpected Claude Code response type: #{data['type']}",
              provider: 'claude_code'
            )
          end

          if data['is_error']
            raise ApiError.new(
              data['result'] || 'Claude Code returned an error',
              provider: 'claude_code', retryable: false
            )
          end

          result_text = data['result'] || ''
          tool_use = extract_tool_use(result_text)
          usage = data['usage'] || {}

          {
            'content' => tool_use ? nil : result_text,
            'tool_use' => tool_use,
            'stop_reason' => tool_use ? 'tool_use' : map_stop_reason(data['stop_reason']),
            'model' => data.dig('modelUsage')&.keys&.first || 'claude_code',
            'input_tokens' => usage['input_tokens'],
            'output_tokens' => usage['output_tokens']
          }
        end

        # Try to extract tool_use JSON from Claude Code's text response
        def extract_tool_use(text)
          # Look for JSON block with tool_use
          json_match = text.match(/```json\s*\n?(.*?)\n?\s*```/m) ||
                       text.match(/\{[^{}]*"tool_use"\s*:/m)

          return nil unless json_match

          json_str = json_match[1] || json_match[0]
          parsed = JSON.parse(json_str)

          if parsed.is_a?(Hash) && parsed['tool_use'].is_a?(Array)
            parsed['tool_use'].map do |tu|
              {
                'id' => "cc_#{SecureRandom.hex(4)}",
                'name' => tu['name'],
                'input' => tu['input'] || {}
              }
            end
          end
        rescue JSON::ParserError
          nil
        end

        def map_stop_reason(reason)
          case reason
          when 'end_turn' then 'end_turn'
          when 'max_tokens' then 'max_tokens'
          else reason || 'end_turn'
          end
        end
      end
    end
  end
end
