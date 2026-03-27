# frozen_string_literal: true

require 'json'
require_relative 'message_format'

module KairosMcp
  module SkillSets
    module Agent
      class CognitiveLoop
        # @param caller_tool [BaseTool] the agent_step tool instance (has invoke_tool)
        # @param session [Session] current agent session
        def initialize(caller_tool, session)
          @caller = caller_tool
          @session = session
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

            llm_result = @caller.invoke_tool('llm_call', {
              'messages' => messages,
              'system' => system_prompt,
              'tools' => available_tools,
              'invocation_context_json' => @session.invocation_context.to_json
            }, context: @session.invocation_context)

            parsed = JSON.parse(llm_result.map { |b| b[:text] || b['text'] }.compact.join)
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

            llm_result = @caller.invoke_tool('llm_call', {
              'messages' => messages,
              'system' => system_prompt,
              'tools' => [],
              'invocation_context_json' => @session.invocation_context.to_json
            }, context: @session.invocation_context)

            parsed = JSON.parse(llm_result.map { |b| b[:text] || b['text'] }.compact.join)
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
              Autoexec::TaskDsl.from_json(task_json_str)
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
