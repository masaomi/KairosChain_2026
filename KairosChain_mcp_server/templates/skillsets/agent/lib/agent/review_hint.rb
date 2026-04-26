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

        # Parse and validate. Returns boolean.
        # On any validation failure, returns false (and logs for audit).
        def self.parse(raw, logger: nil)
          return false unless raw.is_a?(Hash)

          needed = raw['needed']
          unless needed == true || needed == false
            log(logger, "review_hint.needed must be boolean, got #{needed.inspect}")
            return false
          end

          reason = raw['reason']
          unless reason.nil? || reason.is_a?(String)
            log(logger, "review_hint.reason must be string or nil, got #{reason.class}")
            return false
          end

          urgency = raw['urgency']
          unless urgency.nil? || VALID_URGENCY.include?(urgency)
            log(logger, "review_hint.urgency must be one of #{VALID_URGENCY} or nil, got #{urgency.inspect}")
            return false
          end

          needed
        rescue StandardError => e
          log(logger, "review_hint parse error: #{e.class}: #{e.message}")
          false
        end

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
