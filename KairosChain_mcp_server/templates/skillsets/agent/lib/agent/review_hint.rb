# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      # Strict validator for the LLM-emitted review_hint structure (Phase 12 §3.6).
      #
      # Critical property: this hint is ADDITIVE only (§3.2 OR-floor). A return value
      # of `false` does NOT suppress rule-based triggers — rule_fired || hint_needed.
      # Therefore malformed hints fail-through to `false` (no review request from
      # this side), and the OR-floor lets the deterministic rule path fire on its own.
      #
      # Schema:
      #   review_hint: {
      #     needed:  Boolean,
      #     reason:  String  | nil,
      #     urgency: 'low' | 'medium' | 'high' | nil
      #   }
      class ReviewHint
        VALID_URGENCY = %w[low medium high].freeze

        # PR3 hardening: per-process counter of validation failures, exposed for
        # observability. agent_status / introspection tools may read this to
        # surface drift (e.g., DECIDE LLM repeatedly emitting malformed hints).
        # Reset by tests via reset_failure_count!.
        @failure_count = 0
        class << self
          attr_reader :failure_count
        end

        def self.reset_failure_count!
          @failure_count = 0
        end

        # Parse and validate. Returns boolean.
        # On any validation failure, returns false (and logs + increments counter).
        # The counter exposes audit signal without forcing a chain_record dependency
        # in this hot path (Phase 12 kairos Prop 3: recognition without raise/break,
        # but observable through @failure_count + log).
        def self.parse(raw, logger: nil)
          return false unless raw.is_a?(Hash)

          needed = raw['needed']
          unless needed == true || needed == false
            note_failure(logger, "review_hint.needed must be boolean, got #{needed.inspect}")
            return false
          end

          reason = raw['reason']
          unless reason.nil? || reason.is_a?(String)
            note_failure(logger, "review_hint.reason must be string or nil, got #{reason.class}")
            return false
          end

          urgency = raw['urgency']
          unless urgency.nil? || VALID_URGENCY.include?(urgency)
            note_failure(logger, "review_hint.urgency must be one of #{VALID_URGENCY} or nil, got #{urgency.inspect}")
            return false
          end

          needed
        rescue StandardError => e
          note_failure(logger, "review_hint parse error: #{e.class}: #{e.message}")
          false
        end

        def self.note_failure(logger, msg)
          @failure_count += 1
          log(logger, msg)
        end
        private_class_method :note_failure

        def self.log(logger, msg)
          if logger
            logger.warn("[review_hint] #{msg}")
          else
            warn "[review_hint] #{msg}"
          end
        end
        private_class_method :log
      end
    end
  end
end
