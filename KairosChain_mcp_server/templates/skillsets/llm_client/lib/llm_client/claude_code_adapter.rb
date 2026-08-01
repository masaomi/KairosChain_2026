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
        # Default to Opus 5 explicitly. Without --model, Claude Code may
        # auto-route to Haiku for simple/long-context prompts, silently
        # downgrading reviewer quality.
        # Updated 2026-07-25: was claude-opus-4-8, retired from the
        # multi_llm_review roster when Opus 5 entered it. This constant is a
        # fallback only — roster entries always pass an explicit model.
        DEFAULT_MODEL = 'claude-opus-5'
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
          model_usage = data['modelUsage'] || {}

          # The answering model is the entry that produced the output tokens,
          # not the first hash key. The CLI places a small internal call
          # (claude-haiku, ~18 output tokens) beside the main call unless
          # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC suppresses it, so under
          # the worker's stripped environment the envelope carries two keys,
          # and `keys.first` attributed the reply to whichever entry the CLI
          # inserted first. Reproduced 2/2 with byte-identical prompts
          # (2026-07-31); this misread was the root cause of every model
          # divergence this transport had recorded. See L2
          # mlr_v07_design_inputs_and_haiku_root_cause_20260731.
          observed = model_usage.max_by { |_m, u| (u || {})['outputTokens'].to_i }&.first

          {
            'content' => tool_use ? nil : result_text,
            'tool_use' => tool_use,
            'stop_reason' => tool_use ? 'tool_use' : map_stop_reason(data['stop_reason']),
            'model' => requested_model || observed || 'claude_code',
            # What the CLI reports as having answered, when it reports it.
            # Kept separate from 'model' (which echoes the request) so callers
            # can tell a request from an observation and notice when the two
            # disagree. The four divergences recorded before the fix above
            # (R6/R8/R10/R13, 2026-07) were all keys.first misreads — the main
            # call was claude-opus-4-6 every time, and the R13 reply's odd
            # content (identifiers that exist nowhere in the reviewed code) is
            # explained by the sandboxed slot reading no repository, not by a
            # different model answering. A divergence observed after the
            # 2026-07-31 fix has no known benign explanation and is worth
            # investigating.
            'model_observed' => observed,
            # Diagnostic envelope, previously discarded. All four divergence
            # incidents above were undiagnosable from the record because the
            # fields that say what happened did not survive this method.
            # Consumers that persist reviews should carry these through.
            'model_usage' => model_usage.empty? ? nil : model_usage,
            'api_error_status' => data['api_error_status'],
            'fast_mode_state' => data['fast_mode_state'],
            'terminal_reason' => data['terminal_reason'],
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
