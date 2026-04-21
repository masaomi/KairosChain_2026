# frozen_string_literal: true

module KairosMcp
  class Daemon
    # ActiveObserve — policy-driven OBSERVE phase.
    #
    # Design (v0.2 §2, P3.1):
    #   The passive OBSERVE phase inspects mandate state in memory. The
    #   active variant additionally invokes a whitelisted set of READ-ONLY
    #   tools named in the mandate's `observe_policies`, collects their
    #   results, and runs a cheap triage step to highlight what looks
    #   relevant. In P3.1 the triage is a keyword filter stub; a future
    #   revision will slot in a cheap LLM call with the same interface.
    #
    # Safety:
    #   Only tools listed in READ_ONLY_ALLOWLIST (or the caller-supplied
    #   allowlist) are ever invoked. A mandate cannot widen its own
    #   observation surface — policies must be a subset of the allowlist.
    class ActiveObserve
      # A deliberately conservative default. Additional read-only tools may
      # be allowed by passing an explicit `allowlist:` into #initialize.
      READ_ONLY_ALLOWLIST = %w[
        chain_history
        chain_status
        chain_verify
        knowledge_get
        knowledge_list
        skills_list
        skills_get
        skills_dsl_list
        skills_dsl_get
        resource_list
        resource_read
        introspection_health
        introspection_check
        state_status
        state_history
        document_status
        meeting_browse
        meeting_check_freshness
        skillset_browse
      ].freeze

      def initialize(allowlist: READ_ONLY_ALLOWLIST, keywords: nil, logger: nil)
        @allowlist = allowlist.map(&:to_s).freeze
        @keywords  = keywords
        @logger    = logger
      end

      # Execute the active OBSERVE step.
      #
      # @param mandate_hash [Hash] must expose :observe_policies (or the
      #   'observe_policies' key) as an Array of tool names. May expose
      #   :goal_name and :goal for keyword-based triage.
      # @param tool_invoker [#call] a callable accepting
      #   (tool_name, args) and returning the tool's native result. The
      #   caller supplies this so ActiveObserve itself is I/O-agnostic
      #   and trivially testable.
      # @return [Hash] structured observation with :policies_invoked,
      #   :policies_skipped, :results, :relevant, :errors.
      def observe(mandate_hash, tool_invoker:)
        raise ArgumentError, 'mandate_hash required' unless mandate_hash.is_a?(Hash)
        raise ArgumentError, 'tool_invoker must respond to call' unless tool_invoker.respond_to?(:call)

        policies = Array(mandate_hash[:observe_policies] || mandate_hash['observe_policies'])
        invoked = []
        skipped = []
        results = {}
        errors  = {}

        policies.each do |entry|
          tool_name, args = normalize_policy(entry)
          unless allowed?(tool_name)
            skipped << tool_name
            log(:warn, :active_observe_skip, tool: tool_name, reason: 'not_in_allowlist')
            next
          end

          begin
            results[tool_name] = tool_invoker.call(tool_name, args)
            invoked << tool_name
          rescue StandardError => e
            errors[tool_name] = "#{e.class}: #{e.message}"
            log(:error, :active_observe_error, tool: tool_name, error: errors[tool_name])
          end
        end

        relevant = select_relevant(results, mandate_hash)

        {
          policies_invoked: invoked,
          policies_skipped: skipped,
          results:          results,
          relevant:         relevant,
          errors:           errors
        }
      end

      # Triage stub. In P3.1 we score results by simple keyword membership
      # (mandate goal tokens). Returning the full result under a :match
      # entry keeps the interface stable for the eventual LLM-backed
      # implementation, which will add confidence scores without changing
      # the key layout.
      #
      # @return [Hash] tool_name → { match: Boolean, score: Float, matched_keywords: [...] }
      def select_relevant(results, mandate_hash)
        keywords = effective_keywords(mandate_hash)
        return {} if results.empty?

        results.each_with_object({}) do |(tool, payload), acc|
          matched = match_keywords(payload, keywords)
          acc[tool] = {
            match:            !matched.empty? || keywords.empty?,
            score:            keywords.empty? ? 1.0 : matched.size.to_f / keywords.size,
            matched_keywords: matched
          }
        end
      end

      # ------------------------------------------------------------------ helpers

      private

      # A policy entry is either a String tool-name or a Hash
      # { tool: "...", args: {...} }. Normalizing here means the rest of
      # the class can assume a pair.
      def normalize_policy(entry)
        case entry
        when String
          [entry, {}]
        when Hash
          tool = entry[:tool] || entry['tool'] || entry[:name] || entry['name']
          args = entry[:args] || entry['args'] || {}
          [tool.to_s, args]
        else
          [entry.to_s, {}]
        end
      end

      def allowed?(tool_name)
        @allowlist.include?(tool_name.to_s)
      end

      def effective_keywords(mandate_hash)
        return Array(@keywords).map(&:to_s).reject(&:empty?) if @keywords

        raw = [
          mandate_hash[:goal_name], mandate_hash['goal_name'],
          mandate_hash[:goal],      mandate_hash['goal']
        ].compact.map(&:to_s).join(' ')
        raw.downcase.scan(/[a-z0-9]{3,}/).uniq
      end

      def match_keywords(payload, keywords)
        return [] if keywords.empty?

        haystack = payload_to_string(payload).downcase
        keywords.select { |k| haystack.include?(k) }
      end

      def payload_to_string(payload)
        case payload
        when String then payload
        when Hash, Array then payload.to_s
        else payload.to_s
        end
      end

      def log(level, event, **fields)
        return unless @logger && @logger.respond_to?(level)

        @logger.public_send(level, event, **fields)
      end
    end
  end
end
