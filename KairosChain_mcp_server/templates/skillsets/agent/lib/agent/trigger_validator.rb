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
        # @param multi_cfg [Hash, nil] complexity_review.multi_llm_review subtree;
        #   when provided, validate! warns on the rule_only + enabled + empty
        #   trigger_on combination (review gate effectively disabled despite enabled:true).
        # @return [Array<String>] the validated, stringified signals (echo of input)
        # @raise [ConfigurationError] on unknown signal name
        def self.validate!(trigger_on, multi_cfg: nil)
          stringified = Array(trigger_on).map(&:to_s)
          if stringified.empty?
            warn_if_review_unreachable(multi_cfg)
            return []
          end
          unknown = stringified - KNOWN_SIGNALS
          unless unknown.empty?
            raise ConfigurationError,
                  "agent.yml complexity_review.multi_llm_review.trigger_on contains " \
                  "unknown signals: #{unknown.inspect}. Known: #{KNOWN_SIGNALS.inspect}"
          end
          stringified
        end

        # PR3 hardening: surface configuration that would silently disable the
        # review gate. enabled:true + trigger_on:[] under rule_only mode means
        # rule never fires; under rule_or_hint, only LLM hints can ever trigger
        # which is unreliable. Either case warrants an operator warning.
        def self.warn_if_review_unreachable(multi_cfg)
          return unless multi_cfg.is_a?(Hash) && multi_cfg['enabled']
          mode = multi_cfg['trigger_mode'] || 'rule_or_hint'
          if mode == 'rule_only'
            warn '[trigger_validator] WARNING: enabled:true but trigger_on:[] with ' \
                 'trigger_mode:rule_only — review gate cannot fire. ' \
                 'Either populate trigger_on (e.g. [l0_change, design_scope]) or ' \
                 'set trigger_mode:rule_or_hint to allow LLM hints to trigger review.'
          else
            warn '[trigger_validator] note: trigger_on:[] under rule_or_hint — ' \
                 'review gate fires only on LLM-emitted review_hint.needed=true. ' \
                 'Consider adding [l0_change, design_scope] for structural floor.'
          end
        end
        private_class_method :warn_if_review_unreachable
      end
    end
  end
end
