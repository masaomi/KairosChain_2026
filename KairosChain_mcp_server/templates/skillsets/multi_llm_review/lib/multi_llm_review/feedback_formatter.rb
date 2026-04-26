# frozen_string_literal: true

require_relative 'sanitizer'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Formats aggregated_findings into Agent-consumable feedback_text.
      #
      # Phase 12 §3.7. Pure function of findings — same input always produces
      # identical text (golden-file testable).
      #
      # Order: sanitize → truncate → severity prefix (severity is never cut).
      class FeedbackFormatter
        SCHEMA_VERSION = 1
        MAX_FINDINGS_PER_FEEDBACK = 50
        MAX_AGGREGATED_FINDINGS = 200

        # Build feedback_text from aggregated findings.
        #
        # @param findings [Array<Hash>] each with :severity / 'severity' and :issue / 'issue'
        # @return [String] deterministic, sanitized feedback text
        def self.build(findings)
          return '' if findings.nil? || findings.empty?

          findings = Array(findings).first(MAX_AGGREGATED_FINDINGS)
          shown = findings.first(MAX_FINDINGS_PER_FEEDBACK)
          omitted = findings.size - shown.size

          lines = ['Multi-LLM review found issues:']
          shown.each do |f|
            severity = stringify(f[:severity] || f['severity'] || 'P?')
            issue    = Sanitizer.sanitize_finding_text(f[:issue] || f['issue'])
            lines << "- #{severity}: #{issue}"
          end
          if omitted.positive?
            lines << "... (#{omitted} more findings omitted; see aggregated_findings array for full list)"
          end
          lines << ''
          lines << 'Revise plan to address these.'
          lines.join("\n")
        end

        # Build feedback_text for INSUFFICIENT verdict (§3.7.4).
        # Error string is also untrusted (may reflect reviewer content) → sanitized.
        def self.build_insufficient(error_msg)
          sanitized = Sanitizer.sanitize_finding_text(error_msg, max_len: 200)
          "Multi-LLM review could not complete (reason: #{sanitized}). Plan needs human review or retry."
        end

        def self.stringify(s)
          s.to_s.gsub(/[^A-Za-z0-9?]/, '')[0, 8]
        end
        private_class_method :stringify
      end
    end
  end
end
