# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require_relative 'adapter'
require_relative 'safe_subprocess'

module KairosMcp
  module SkillSets
    module LlmClient
      # Adapter that uses Claude Code CLI as the LLM backend.
      # No API costs — uses the Claude Code subscription.
      # Invokes `claude -p --output-format json` as a subprocess.
      #
      # Key safety measures:
      # - --mcp-config '{"mcpServers":{}}' prevents recursive MCP server loading
      # - --no-session-persistence avoids polluting session state
      # - SafeSubprocess handles subprocess lifecycle (PID tracking, env sanitization)
      class ClaudeCodeAdapter < Adapter
        DEFAULT_TIMEOUT = 120
        # Default to Opus 4.7 explicitly. Without --model, Claude Code may
        # auto-route to Haiku for simple/long-context prompts, silently
        # downgrading reviewer quality.
        DEFAULT_MODEL = 'claude-opus-4-7'
        SANDBOX_CWD = '/tmp/kairos_sandbox'
        SANDBOX_HOME = '/tmp/kairos_claude_home'

        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil, output_schema: nil)
          prompt = build_prompt(messages, system, tools, output_schema)
          timeout_seconds = @config&.dig('timeout_seconds') || DEFAULT_TIMEOUT
          effective_model = model || @config&.dig('model') || DEFAULT_MODEL
          effort = @config&.dig('effort')

          args = [
            'claude', '-p',
            '--output-format', 'json',
            '--no-session-persistence',
            '--mcp-config', '{"mcpServers":{}}',
            '--model', effective_model
          ]
          # Effort: low / medium / high / xhigh / max
          args += ['--effort', effort.to_s] if effort && !effort.to_s.empty?

          sandbox_mode = @config&.dig('sandbox_mode')
          spawn_env = { '_auth_env_key' => 'ANTHROPIC_API_KEY' }
          spawn_chdir = nil

          # Review/sandbox mode: lock down tools + chdir to empty sandbox
          # (prevents project-level CLAUDE.md contamination).
          # HOME is preserved so CLI OAuth auth (~/.claude/) works.
          # --mcp-config '{}' (always on) prevents MCP recursion.
          if sandbox_mode
            prepare_sandbox!
            args += ['--disallowedTools', '*']
            spawn_chdir = SANDBOX_CWD
          end

          stdout, stderr, status = SafeSubprocess.safe_capture(
            args,
            stdin_data: prompt,
            timeout_seconds: timeout_seconds,
            env: spawn_env,
            dispatch_id: @config&.dig('dispatch_id'),
            chdir: spawn_chdir
          )

          unless status && status.success?
            raise ApiError.new(
              "Claude Code exited with status #{status&.exitstatus}: #{stderr[0..200]}",
              provider: 'claude_code', retryable: false
            )
          end

          parse_response(stdout, requested_model: effective_model)
        rescue Timeout::Error
          raise ApiError.new(
            "Claude Code timed out after #{timeout_seconds}s",
            provider: 'claude_code', retryable: true
          )
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

        def prepare_sandbox!
          [SANDBOX_CWD, SANDBOX_HOME].each { |d| FileUtils.mkdir_p(d) }
          # Clean CWD to prevent CLAUDE.md contamination
          %w[CLAUDE.md .claude .mcp.json].each do |name|
            path = File.join(SANDBOX_CWD, name)
            FileUtils.rm_rf(path) if File.exist?(path)
          end
          # Clean HOME to prevent settings leakage
          %w[.claude .config].each do |name|
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

        def parse_response(stdout, requested_model: nil)
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
            'model' => requested_model || data.dig('modelUsage')&.keys&.first || 'claude_code',
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
