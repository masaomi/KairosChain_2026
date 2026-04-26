# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      # Validates agent.yml's complexity_review.multi_llm_review.trigger_on against
      # the actual signal vocabulary produced by assess_decision_complexity.
      #
      # Phase 12 §12 / v0.4 P-1. Aligned with agent_step.rb:1005-1031.
      #
      # Fail-loud at session start (not silently at first cycle) so typos like
      # "l0_chagne" don't bypass the review gate at runtime.
      class TriggerValidator
        KNOWN_SIGNALS = %w[
          high_risk
          many_steps
          design_scope
          l0_change
          core_files
          multi_file
          state_mutation
        ].freeze

        class ConfigurationError < StandardError; end

        # @param trigger_on [Array<String>] from agent.yml
        # @return [Array<String>] the validated, stringified signals (echo of input)
        # @raise [ConfigurationError] on unknown signal name
        def self.validate!(trigger_on)
          return [] if trigger_on.nil? || trigger_on.empty?
          stringified = Array(trigger_on).map(&:to_s)
          unknown = stringified - KNOWN_SIGNALS
          unless unknown.empty?
            raise ConfigurationError,
                  "agent.yml complexity_review.multi_llm_review.trigger_on contains " \
                  "unknown signals: #{unknown.inspect}. Known: #{KNOWN_SIGNALS.inspect}"
          end
          stringified
        end
      end
    end
  end
end
