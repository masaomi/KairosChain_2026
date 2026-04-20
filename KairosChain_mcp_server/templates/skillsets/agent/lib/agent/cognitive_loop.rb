# frozen_string_literal: true

require 'json'
require_relative 'message_format'

module KairosMcp
  module SkillSets
    module Agent
      # Raised by ErrorTaxonomy-aware error handler when context is too long.
      # Caught by run_phase to trigger message compression.
      class ContextOverflowError < StandardError; end

      class CognitiveLoop
        FALLBACK_PROVIDERS = %w[claude_code].freeze
        MAX_BACKOFF_SECONDS = 5  # MCP thread blocking mitigation

        attr_reader :total_calls

        # @param caller_tool [BaseTool] the agent_step tool instance (has invoke_tool)
        # @param session [Session] current agent session
        def initialize(caller_tool, session)
          @caller = caller_tool
          @session = session
          @fallback_attempted = false
          @fallback_advisory_shown = false
          @total_calls = 0
        end

        # Generic phase runner for ORIENT, REFLECT, and DECIDE_PREP.
        # Runs the LLM loop with tool_use until the LLM stops requesting tools.
        # Returns the final LLM response hash.
        #
        # @param invocation_context [InvocationContext, nil] phase-specific context
        #   for tool filtering. If nil, uses the session's base context.
        def run_phase(phase_name, system_prompt, messages, available_tools,
                      invocation_context: nil)
          phase_cfg = @session.phase_config(phase_name)
          ctx = invocation_context || @session.invocation_context
          iteration = 0
          tool_call_count = 0
          compressed = false

          loop do
            iteration += 1
            if iteration > phase_cfg[:max_llm_calls]
              return { 'content' => "[Budget: max LLM calls for #{phase_name}]",
                       'stop_reason' => 'budget' }
            end

            @total_calls += 1
            begin
              parsed = call_llm_with_fallback(
                'messages' => messages,
                'system' => system_prompt,
                'tools' => available_tools,
                'invocation_context_json' => ctx.to_json
              )
            rescue ContextOverflowError
              # Compress once per phase; if already compressed, propagate as error
              if compressed
                return { 'error' => 'Context overflow after compression' }
              end
              compressed = true
              messages = compress_messages(messages)
              next
            end
            return { 'error' => parsed['error'] } if parsed['status'] == 'error'

            response = parsed['response']
            @session.record_snapshot(parsed['snapshot']) if parsed['snapshot']

            # No tool_use → LLM finished reasoning
            return response unless response['tool_use']

            # Pre-validate batch size before executing any tool
            batch_size = response['tool_use'].size
            if tool_call_count + batch_size > phase_cfg[:max_tool_calls]
              return { 'content' => "[Budget: tool batch (#{batch_size}) would exceed " \
                                    "limit (#{phase_cfg[:max_tool_calls]} - #{tool_call_count} remaining)]",
                       'stop_reason' => 'budget' }
            end

            response['tool_use'].each do |tu|
              tool_call_count += 1

              tool_result = @caller.invoke_tool(tu['name'], tu['input'] || {},
                                                 context: ctx)
              tool_text = tool_result.map { |b| b[:text] || b['text'] }.compact.join("\n")

              messages << MessageFormat.assistant_tool_use(tu)
              messages << MessageFormat.tool_result(tu['id'], tool_text)
            end
          end
        end

        # DECIDE-specific runner with JSON extraction + repair loop.
        # No tool_use — reference gathering must be done via run_phase pre-pass.
        def run_decide(system_prompt, messages, max_repair: nil)
          phase_cfg = @session.phase_config('decide')
          max_repair ||= phase_cfg[:max_repair_attempts]
          attempts = 0

          loop do
            attempts += 1
            if attempts > phase_cfg[:max_llm_calls]
              return { 'error' => 'Budget exceeded for DECIDE phase' }
            end

            @total_calls += 1

            parsed = call_llm_with_fallback(
              'messages' => messages,
              'system' => system_prompt,
              'tools' => [],
              'invocation_context_json' => @session.invocation_context.to_json
            )
            return { 'error' => parsed['error'] } if parsed['status'] == 'error'

            response = parsed['response']
            @session.record_snapshot(parsed['snapshot']) if parsed['snapshot']

            content = response['content'] || ''

            json_str = extract_json(content)
            unless json_str
              if attempts >= max_repair
                return { 'error' => "DECIDE: no valid JSON after #{max_repair} attempts",
                         'raw_content' => content }
              end
              messages << MessageFormat.user_message(
                "Your response did not contain valid JSON. Please output the decision_payload " \
                "as a JSON object with keys 'summary' and 'task_json'. Attempt #{attempts}/#{max_repair}."
              )
              next
            end

            begin
              decision = JSON.parse(json_str)
              task_json_str = JSON.generate(decision['task_json'])
              ::Autoexec::TaskDsl.from_json(task_json_str)
              return { 'decision_payload' => decision }
            rescue => e
              if attempts >= max_repair
                return { 'error' => "DECIDE: TaskDsl validation failed after #{max_repair} attempts: #{e.message}",
                         'raw_content' => content }
              end
              messages << MessageFormat.user_message(
                "JSON parsed but TaskDsl validation failed: #{e.message}. " \
                "Fix the task_json structure and try again. Attempt #{attempts}/#{max_repair}."
              )
            end
          end
        end

        private

        # Call llm_call with taxonomy-aware error recovery.
        # When error_taxonomy feature is enabled, classifies errors via
        # ErrorTaxonomy and takes type-appropriate action (backoff, retry,
        # switch provider, compress, disable thinking).
        # Falls back to legacy auth_error-only handling when disabled.
        def call_llm_with_fallback(arguments)
          llm_result = @caller.invoke_tool('llm_call', arguments,
                                            context: @session.invocation_context)
          parsed = JSON.parse(llm_result.map { |b| b[:text] || b['text'] }.compact.join)

          error_info = parsed['error']
          return parsed unless error_info.is_a?(Hash)

          if error_taxonomy_enabled?
            handle_error_with_taxonomy(parsed, arguments)
          else
            handle_error_legacy(parsed, arguments)
          end
        end

        # Taxonomy-aware error handler (Enhancement C).
        # Classifies error via ErrorTaxonomy and dispatches recovery action.
        def handle_error_with_taxonomy(parsed, arguments)
          error_info = parsed['error']
          # CF-2 fix: lazy-require ErrorTaxonomy to avoid NameError when
          # llm_client SkillSet hasn't been loaded yet.
          unless defined?(::KairosMcp::SkillSets::LlmClient::ErrorTaxonomy)
            return handle_error_legacy(parsed, arguments)
          end
          taxonomy = ::KairosMcp::SkillSets::LlmClient::ErrorTaxonomy
          classification = taxonomy.classify(error_info)

          log_event(:warn, 'llm_error_classified',
                    error_type: classification[:type].to_s,
                    action: classification[:action].to_s,
                    message: classification[:original_message].to_s[0..100])

          record_error_event(classification)

          # CF-1 fix: only count @total_calls when a new LLM call is actually issued.
          # retry_llm_call increments @total_calls internally.
          # :compress raises (no LLM call), :rephrase/:report return as-is (no LLM call).
          case classification[:action]
          when :switch_provider
            return try_provider_fallback(parsed, arguments)
          when :backoff
            backoff = (classification[:suggested_backoff] || MAX_BACKOFF_SECONDS).to_i
            sleep([backoff, MAX_BACKOFF_SECONDS].min)
            return retry_llm_call(arguments)
          when :compress
            raise ContextOverflowError, classification[:original_message]
          when :fallback_model
            return retry_with_fallback_model(arguments)
          when :retry
            return retry_llm_call(arguments)
          when :disable_thinking
            new_args = arguments.dup
            new_args['extended_thinking'] = false
            return retry_llm_call(new_args)
          else # :rephrase, :report — no new LLM call
            parsed
          end
        end

        # Legacy error handler (pre-taxonomy): auth_error only.
        def handle_error_legacy(parsed, arguments)
          error_info = parsed['error']
          if error_info['type'] != 'auth_error' || @fallback_attempted
            return parsed
          end
          try_provider_fallback(parsed, arguments)
        end

        # Retry a single llm_call and return parsed result.
        # CF-1 fix: counts toward @total_calls budget.
        def retry_llm_call(arguments)
          @total_calls += 1
          result = @caller.invoke_tool('llm_call', arguments,
                                        context: @session.invocation_context)
          JSON.parse(result.map { |b| b[:text] || b['text'] }.compact.join)
        end

        # Try switching to a fallback model (for model_not_found errors).
        # Currently delegates to provider fallback since model selection
        # is provider-coupled.
        def retry_with_fallback_model(arguments)
          new_args = arguments.dup
          new_args.delete('model')  # let provider use its default
          retry_llm_call(new_args)
        end

        # Provider fallback for auth/billing errors.
        # Extracted from legacy call_llm_with_fallback for reuse.
        def try_provider_fallback(parsed, arguments)
          error_info = parsed['error']
          original_provider = error_info['provider'] || 'configured'
          warn "[agent] Error from #{original_provider} (#{error_info['type']}), attempting provider fallback"

          FALLBACK_PROVIDERS.each do |fallback|
            @fallback_attempted = true
            configure_result = try_configure_provider(fallback)
            next unless configure_result

            warn "[agent] Switched to provider: #{fallback}"
            retry_parsed = retry_llm_call(arguments)

            retry_error = retry_parsed['error']
            if retry_error.is_a?(Hash) && retry_error['type'] == 'auth_error'
              warn "[agent] Fallback provider #{fallback} also failed: #{retry_error['message']}"
              next
            end

            check_permission_advisory(fallback)
            return retry_parsed
          end

          parsed['error']['fallback_attempted'] = true
          parsed['error']['fallback_exhausted'] = true
          parsed
        end

        # Record error classification event on blockchain (non-fatal).
        def record_error_event(classification)
          @caller.invoke_tool('chain_record', {
            'logs' => [JSON.generate({
              'event_type' => 'llm_error',
              'error_type' => classification[:type].to_s,
              'action_taken' => classification[:action].to_s,
              'session_id' => @session.session_id
            })]
          }, context: @session.invocation_context)
        rescue StandardError => e
          warn "[agent] Failed to record error event: #{e.message}"
        end

        def error_taxonomy_enabled?
          @session&.config&.dig('features', 'error_taxonomy') != false
        end

        # Compress messages by keeping head + tail and summarizing middle.
        # v1.0: no LLM calls — pure truncation.
        # CF-3 fix: ensures tool_use/tool_result pairs are never split at boundaries.
        def compress_messages(messages)
          return messages if messages.length <= 5

          # Find safe head boundary: expand forward to avoid ending on a tool_use
          head_end = 1
          while head_end < messages.length - 3 && tool_use_message?(messages[head_end])
            head_end += 1
          end

          # Find safe tail boundary: expand backward to avoid starting on a tool_result
          tail_start = messages.length - 3
          while tail_start > head_end + 1 && tool_result_message?(messages[tail_start])
            tail_start -= 1
          end

          # If boundaries overlap, just return all messages (too short to compress)
          return messages if tail_start <= head_end + 1

          head = messages[0..head_end]
          tail = messages[tail_start..]
          middle_count = tail_start - head_end - 1

          head + [{
            'role' => 'user',
            'content' => "[Compressed: #{middle_count} intermediate messages removed. " \
                         "Focus on the goal and recent context.]"
          }] + tail
        end

        def tool_use_message?(msg)
          msg.is_a?(Hash) && (msg['role'] == 'assistant') &&
            (msg.key?('tool_use') || msg.dig('content').is_a?(Array) &&
             msg['content'].any? { |b| b.is_a?(Hash) && b['type'] == 'tool_use' })
        end

        def tool_result_message?(msg)
          msg.is_a?(Hash) && (msg['role'] == 'user') &&
            (msg.key?('tool_use_id') || msg.dig('content').is_a?(Array) &&
             msg['content'].any? { |b| b.is_a?(Hash) && b['type'] == 'tool_result' })
        end

        def try_configure_provider(provider)
          args = { 'provider' => provider }
          result = @caller.invoke_tool('llm_configure', args,
                                        context: @session.invocation_context)
          parsed = JSON.parse(result.map { |b| b[:text] || b['text'] }.compact.join)
          parsed['status'] == 'ok'
        rescue StandardError => e
          warn "[agent] Failed to configure provider #{provider}: #{e.message}"
          false
        end

        # Check if Claude Code PreToolUse hook is configured for the MCP server.
        # If not, record a one-time advisory on the session so the user knows
        # how to avoid permission prompts during autonomous operation.
        def check_permission_advisory(provider)
          return unless provider == 'claude_code'
          return if @fallback_advisory_shown
          return if claude_hook_configured?

          @fallback_advisory_shown = true
          mcp_name = detect_mcp_server_name
          return unless mcp_name  # Can't advise without knowing the server name

          matcher = "mcp__#{mcp_name}__*"

          advisory = <<~MSG.strip
            Claude Code fallback activated — using your Claude Code subscription instead of API.
            For uninterrupted autonomous operation, a PreToolUse hook for "#{matcher}" is needed.

            To auto-apply this setting, re-run agent_step with apply_permission_hook: true:
              agent_step(session_id: "#{@session.session_id}", action: "approve", apply_permission_hook: true)

            This auto-approves only #{mcp_name} MCP tools. Bash, file edits, and other tools still require confirmation.
          MSG

          @session.permission_advisory = advisory
        end

        def claude_hook_configured?
          mcp_name = detect_mcp_server_name
          return false unless mcp_name

          matcher = "mcp__#{mcp_name}__*"
          settings_candidates.each do |path|
            next unless File.exist?(path)
            settings = JSON.parse(File.read(path))
            hooks = settings.dig('hooks', 'PreToolUse') || []
            return true if hooks.any? { |h| h['matcher'] == matcher }
          end
          false
        rescue StandardError
          false
        end

        # Detect MCP server name from Claude Code settings.
        # Scans project-level and global settings for mcpServers entries
        # whose command/args include 'kairos-chain'.
        def detect_mcp_server_name
          settings_candidates.each do |path|
            next unless File.exist?(path)
            settings = JSON.parse(File.read(path))
            (settings['mcpServers'] || {}).each do |name, config|
              cmd_parts = Array(config['command']) + Array(config['args'])
              return name if cmd_parts.any? { |part| part.to_s.include?('kairos-chain') }
            end
          end
          nil
        rescue StandardError
          nil
        end

        def settings_candidates
          project = File.join(Dir.pwd, '.claude', 'settings.json')
          global = File.join(Dir.home, '.claude', 'settings.json')
          [project, global]
        end

        # Structured logging helper. Uses KairosMcp.logger if available.
        def log_event(level, event, **fields)
          return unless defined?(::KairosMcp) && ::KairosMcp.respond_to?(:logger) && ::KairosMcp.logger
          fields[:source] = 'cognitive_loop'
          fields[:session_id] = @session&.session_id
          ::KairosMcp.logger.send(level, event, **fields)
        rescue StandardError
          # Logger must never crash the agent
        end

        def extract_json(content)
          JSON.parse(content)
          content
        rescue JSON::ParserError
          if content =~ /```(?:json)?\s*\n?(.*?)\n?```/m
            begin
              JSON.parse($1)
              $1
            rescue JSON::ParserError
              nil
            end
          end
        end
      end
    end
  end
end
