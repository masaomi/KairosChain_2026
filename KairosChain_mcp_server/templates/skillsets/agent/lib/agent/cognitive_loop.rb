# frozen_string_literal: true

require 'json'
require_relative 'message_format'

module KairosMcp
  module SkillSets
    module Agent
      class CognitiveLoop
        FALLBACK_PROVIDERS = %w[claude_code].freeze

        # @param caller_tool [BaseTool] the agent_step tool instance (has invoke_tool)
        # @param session [Session] current agent session
        def initialize(caller_tool, session)
          @caller = caller_tool
          @session = session
          @fallback_attempted = false
        end

        # Generic phase runner for ORIENT, REFLECT, and DECIDE_PREP.
        # Runs the LLM loop with tool_use until the LLM stops requesting tools.
        # Returns the final LLM response hash.
        def run_phase(phase_name, system_prompt, messages, available_tools)
          phase_cfg = @session.phase_config(phase_name)
          iteration = 0
          tool_call_count = 0

          loop do
            iteration += 1
            if iteration > phase_cfg[:max_llm_calls]
              return { 'content' => "[Budget: max LLM calls for #{phase_name}]",
                       'stop_reason' => 'budget' }
            end

            parsed = call_llm_with_fallback(
              'messages' => messages,
              'system' => system_prompt,
              'tools' => available_tools,
              'invocation_context_json' => @session.invocation_context.to_json
            )
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
                                                 context: @session.invocation_context)
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

        # Call llm_call with automatic provider fallback on auth errors.
        # Tries the configured provider first. On auth_error, switches to
        # fallback providers (claude_code) via llm_configure, then retries once.
        def call_llm_with_fallback(arguments)
          llm_result = @caller.invoke_tool('llm_call', arguments,
                                            context: @session.invocation_context)
          parsed = JSON.parse(llm_result.map { |b| b[:text] || b['text'] }.compact.join)

          # If not an auth error, or already tried fallback, return as-is
          error_info = parsed['error']
          if !error_info || !error_info.is_a?(Hash) || error_info['type'] != 'auth_error' || @fallback_attempted
            return parsed
          end

          # Attempt provider fallback
          original_provider = error_info['provider'] || 'configured'
          warn "[agent] Auth error from #{original_provider}, attempting provider fallback"

          FALLBACK_PROVIDERS.each do |fallback|
            @fallback_attempted = true
            configure_result = try_configure_provider(fallback)
            next unless configure_result

            warn "[agent] Switched to provider: #{fallback}"
            retry_result = @caller.invoke_tool('llm_call', arguments,
                                                context: @session.invocation_context)
            retry_parsed = JSON.parse(retry_result.map { |b| b[:text] || b['text'] }.compact.join)

            # If this provider also fails with auth_error, try next
            retry_error = retry_parsed['error']
            if retry_error.is_a?(Hash) && retry_error['type'] == 'auth_error'
              warn "[agent] Fallback provider #{fallback} also failed: #{retry_error['message']}"
              next
            end

            return retry_parsed
          end

          # All fallbacks exhausted — return original error with fallback info
          parsed['error']['fallback_attempted'] = true
          parsed['error']['fallback_exhausted'] = true
          parsed
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
