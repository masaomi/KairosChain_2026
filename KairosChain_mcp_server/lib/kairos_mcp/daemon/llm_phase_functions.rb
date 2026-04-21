# frozen_string_literal: true

require 'json'

module KairosMcp
  class Daemon
    # LlmPhaseFunctions — lightweight LLM callables for OodaCycleRunner.
    #
    # Design (Technical Debt #1+#2 resolution):
    #   Instead of integrating with the full Autonomos CognitiveLoop,
    #   these are thin wrappers around llm_call (MCP tool or direct callable).
    #   Each function receives observation/orient data and returns structured output.
    #
    #   Usage tracking: each call records input/output tokens into a shared
    #   UsageAccumulator that the runner can query.
    #
    # The llm_caller is a callable: ->(messages:, system:, max_tokens:, **) → Hash
    # It must return: { content: String, input_tokens: Int, output_tokens: Int }
    module LlmPhaseFunctions
      # Shared usage tracker across phases within one cycle.
      class UsageAccumulator
        attr_reader :llm_calls, :input_tokens, :output_tokens

        def initialize
          @llm_calls = 0
          @input_tokens = 0
          @output_tokens = 0
        end

        # Record LLM usage from a response.
        # When DaemonLlmCaller returns `attempts: N` (including retries),
        # llm_calls is incremented by N. Callers without `attempts` default to 1.
        def record(response)
          @llm_calls += Integer(response[:attempts] || response['attempts'] || 1)
          @input_tokens += Integer(response[:input_tokens] || response['input_tokens'] || 0)
          @output_tokens += Integer(response[:output_tokens] || response['output_tokens'] || 0)
        end

        def to_h
          { llm_calls: @llm_calls, input_tokens: @input_tokens, output_tokens: @output_tokens }
        end

        def reset!
          @llm_calls = 0
          @input_tokens = 0
          @output_tokens = 0
        end
      end

      # Build orient_fn callable.
      # @param llm_caller [#call] the LLM transport
      # @param usage [UsageAccumulator]
      # @return [Proc] ->(observation, mandate) → orient_output Hash
      def self.orient_fn(llm_caller:, usage:, max_tokens: 1024)
        lambda do |observation, mandate|
          goal = mandate[:goal] || mandate['goal'] || mandate[:goal_name] || mandate['goal_name'] || 'general maintenance'
          relevant = observation[:relevant] || observation['relevant'] || {}
          results = observation[:results] || observation['results'] || {}

          prompt = <<~PROMPT
            You are an autonomous agent in the ORIENT phase of an OODA loop.
            Your goal: #{goal}

            OBSERVATION RESULTS:
            #{JSON.pretty_generate(results)[0, 2000]}

            RELEVANT SIGNALS:
            #{JSON.pretty_generate(relevant)[0, 1000]}

            Analyze the observations and produce a structured orientation.
            Return JSON with keys: summary (string), priorities (array of strings), risk_level (low/medium/high).
          PROMPT

          response = call_and_record(llm_caller, usage,
            messages: [{ role: 'user', content: prompt }],
            system: 'You are a KairosChain daemon agent. Return only valid JSON.',
            max_tokens: max_tokens
          )
          parse_json_response(response, fallback: { summary: 'no orientation', priorities: [], risk_level: 'low' })
        end
      end

      # Build decide_fn callable.
      # @param llm_caller [#call]
      # @param usage [UsageAccumulator]
      # @param workspace_root [String]
      # @return [Proc] ->(orient_output, mandate) → decision Hash
      def self.decide_fn(llm_caller:, usage:, workspace_root:, max_tokens: 2048)
        lambda do |orient_output, mandate|
          goal = mandate[:goal] || mandate['goal'] || mandate[:goal_name] || mandate['goal_name'] || 'general maintenance'
          scope_hint = mandate[:decide_hints] || mandate['decide_hints'] || {}

          prompt = <<~PROMPT
            You are an autonomous agent in the DECIDE phase of an OODA loop.
            Your goal: #{goal}
            Workspace: #{workspace_root}

            ORIENTATION:
            #{JSON.pretty_generate(orient_output)[0, 2000]}

            SCOPE CONSTRAINTS:
            - Preferred scope: #{scope_hint[:prefer_scope] || scope_hint['prefer_scope'] || 'L2'}
            - Max edit bytes: #{scope_hint[:max_edit_bytes] || scope_hint['max_edit_bytes'] || 4096}

            DECIDE what action to take. Return JSON with one of:
            1. {"action": "code_edit", "target": "relative/path.md", "old_string": "exact text to replace", "new_string": "replacement text", "intent": "why"}
            2. {"action": "noop", "reason": "why no action needed"}

            IMPORTANT: old_string must be an EXACT substring currently in the file.
            Target path must be relative to workspace root.
          PROMPT

          response = call_and_record(llm_caller, usage,
            messages: [{ role: 'user', content: prompt }],
            system: 'You are a KairosChain daemon agent. Return only valid JSON.',
            max_tokens: max_tokens
          )
          decision = parse_json_response(response, fallback: { action: 'noop', reason: 'LLM parse failure' })
          symbolize_keys(decision)
        end
      end

      # Build reflect_fn callable.
      # @param llm_caller [#call]
      # @param usage [UsageAccumulator]
      # @return [Proc] ->(act_result, mandate) → reflect_output Hash
      def self.reflect_fn(llm_caller:, usage:, max_tokens: 512)
        lambda do |act_result, mandate|
          prompt = <<~PROMPT
            You are an autonomous agent in the REFLECT phase of an OODA loop.
            Goal: #{mandate[:goal] || mandate['goal'] || 'maintenance'}

            ACT RESULT:
            #{JSON.pretty_generate(act_result)[0, 1500]}

            Reflect on the outcome. Return JSON with:
            - assessment: "success" | "partial" | "failure"
            - lessons: array of strings (what to improve next cycle)
            - confidence: 0.0 to 1.0
          PROMPT

          response = call_and_record(llm_caller, usage,
            messages: [{ role: 'user', content: prompt }],
            system: 'You are a KairosChain daemon agent. Return only valid JSON.',
            max_tokens: max_tokens
          )
          parse_json_response(response, fallback: { assessment: 'unknown', lessons: [], confidence: 0.5 })
        end
      end

      # ---------------------------------------------------------------- helpers

      # Call llm_caller and record usage. On failure, record the failed
      # attempts into usage before re-raising so Budget stays accurate.
      def self.call_and_record(llm_caller, usage, **kwargs)
        response = llm_caller.call(**kwargs)
        usage.record(response)
        response
      rescue StandardError => e
        # Record failed attempts if the error carries attempt count
        if e.respond_to?(:attempts) && e.attempts.is_a?(Integer) && e.attempts > 0
          usage.record({ attempts: e.attempts, input_tokens: 0, output_tokens: 0 })
        end
        raise
      end

      def self.parse_json_response(response, fallback:)
        content = response[:content] || response['content'] || ''
        # Extract JSON from markdown fences if present
        if content.include?('```')
          content = content.gsub(/```(?:json)?\s*/, '').gsub(/```/, '').strip
        end
        JSON.parse(content)
      rescue JSON::ParserError
        fallback
      end

      def self.symbolize_keys(hash)
        return hash unless hash.is_a?(Hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
