# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require_relative 'adapter'
require_relative 'safe_subprocess'

module KairosMcp
  module SkillSets
    module LlmClient
      # Adapter that uses Cursor Agent (`agent -p --mode plan`) as the LLM backend.
      # HOME is redirected to an empty sandbox dir to prevent the agent from
      # reading the caller's Cursor state. Env sanitized via SafeSubprocess.
      class CursorAdapter < Adapter
        DEFAULT_TIMEOUT = 180
        SANDBOX_HOME = '/tmp/kairos_empty_home'

        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil, output_schema: nil)
          prepare_sandbox!
          prompt = build_prompt(messages, system, tools, output_schema)
          timeout_seconds = @config&.dig('timeout_seconds') || DEFAULT_TIMEOUT

          args = ['agent', '-p', '--mode', 'plan']

          stdout, stderr, status = SafeSubprocess.safe_capture(
            args,
            stdin_data: prompt,
            timeout_seconds: timeout_seconds,
            env: {
              '_auth_env_key' => 'CURSOR_API_KEY',
              'HOME' => SANDBOX_HOME
            },
            dispatch_id: @config&.dig('dispatch_id'),
            chdir: SANDBOX_HOME
          )

          unless status && status.success?
            raise ApiError.new(
              "cursor agent exited with status #{status&.exitstatus}: #{strip_ansi(stderr)[0..200]}",
              provider: 'cursor', retryable: false
            )
          end

          parse_response(stdout, model)
        rescue Timeout::Error
          raise ApiError.new(
            "cursor agent timed out after #{timeout_seconds}s",
            provider: 'cursor', retryable: true
          )
        rescue Errno::ENOENT
          raise ApiError.new(
            "cursor agent CLI not found. Install Cursor Agent CLI.",
            provider: 'cursor', retryable: false
          )
        rescue ApiError
          raise
        rescue StandardError => e
          raise ApiError.new("cursor agent error: #{e.message}", provider: 'cursor')
        end

        private

        def prepare_sandbox!
          FileUtils.mkdir_p(SANDBOX_HOME)
          # Clean leftover state from prior runs
          %w[.cursor .cursorrc .config].each do |name|
            path = File.join(SANDBOX_HOME, name)
            FileUtils.rm_rf(path) if File.exist?(path)
          end
        rescue StandardError
          nil
        end

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
            'model' => model || @config&.dig('model') || 'cursor',
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
              'id' => "cu_#{SecureRandom.hex(4)}",
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
