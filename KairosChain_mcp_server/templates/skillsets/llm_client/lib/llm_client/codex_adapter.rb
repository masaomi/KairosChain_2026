# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'adapter'
require_relative 'safe_subprocess'

module KairosMcp
  module SkillSets
    module LlmClient
      # Adapter that uses OpenAI Codex CLI (`codex exec`) as the LLM backend.
      # Invokes `codex exec --sandbox read-only -` with the prompt on stdin.
      # Env is sanitized via SafeSubprocess (unsetenv_others: true).
      class CodexAdapter < Adapter
        DEFAULT_TIMEOUT = 180

        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil, output_schema: nil)
          prompt = build_prompt(messages, system, tools, output_schema)
          timeout_seconds = @config&.dig('timeout_seconds') || DEFAULT_TIMEOUT

          args = ['codex', 'exec', '--sandbox', 'read-only']
          # Reasoning effort: minimal / low / medium / high
          effort = @config&.dig('effort')
          if effort && !effort.to_s.empty?
            args += ['-c', "model_reasoning_effort=#{effort}"]
          end
          args << '-'

          # Uses CLI auth from ~/.codex/ (via `codex login`). HOME is preserved
          # by SafeSubprocess SAFE_ENV_KEYS, so CLI auth state is accessible.
          stdout, stderr, status = SafeSubprocess.safe_capture(
            args,
            stdin_data: prompt,
            timeout_seconds: timeout_seconds,
            env: {},
            dispatch_id: @config&.dig('dispatch_id')
          )

          unless status && status.success?
            raise ApiError.new(
              "codex exec exited with status #{status&.exitstatus}: #{strip_ansi(stderr)[0..200]}",
              provider: 'codex', retryable: false
            )
          end

          parse_response(stdout, model)
        rescue Timeout::Error
          raise ApiError.new(
            "codex exec timed out after #{timeout_seconds}s",
            provider: 'codex', retryable: true
          )
        rescue Errno::ENOENT
          raise ApiError.new(
            "codex CLI not found. Install: https://github.com/openai/codex",
            provider: 'codex', retryable: false
          )
        rescue ApiError
          raise
        rescue StandardError => e
          raise ApiError.new("codex error: #{e.message}", provider: 'codex')
        end

        private

        def build_prompt(messages, system, tools, output_schema = nil)
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
              if schema.is_a?(Hash) && schema['properties']
                parts << "  Parameters: #{schema['properties'].keys.join(', ')}"
              end
            end
            parts << ""
            parts << "To use a tool, include in your response:"
            parts << '```json'
            parts << '{"tool_use": [{"name": "tool_name", "input": {"param": "value"}}]}'
            parts << '```'
            parts << ""
          end

          if output_schema
            qualifier = (tools && !tools.empty?) ? "When you are NOT using a tool, respond" : "Respond"
            parts << "[Output Format]: #{qualifier} with ONLY valid JSON (no markdown fences) matching this schema:"
            parts << JSON.generate(output_schema)
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

        def parse_response(stdout, model)
          text = strip_ansi(stdout).to_s
          tool_use = extract_tool_use(text)

          {
            'content' => tool_use ? nil : text,
            'tool_use' => tool_use,
            'stop_reason' => tool_use ? 'tool_use' : 'end_turn',
            'model' => model || 'codex-cli-default',
            'input_tokens' => nil,
            'output_tokens' => nil
          }
        end

        def extract_tool_use(text)
          json_match = text.match(/```json\s*\n?(.*?)\n?\s*```/m) ||
                       text.match(/\{[^{}]*"tool_use"\s*:[^{}]*\}/m)
          return nil unless json_match

          parsed = JSON.parse(json_match[1] || json_match[0])
          return nil unless parsed.is_a?(Hash) && parsed['tool_use'].is_a?(Array)

          parsed['tool_use'].map do |tu|
            {
              'id' => "cx_#{SecureRandom.hex(4)}",
              'name' => tu['name'],
              'input' => tu['input'] || {}
            }
          end
        rescue JSON::ParserError
          nil
        end

        def strip_ansi(s)
          return '' if s.nil?
          s.gsub(/\e\[[0-9;]*[A-Za-z]/, '')
        end
      end
    end
  end
end
