# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Prompt-injection sanitizer for review findings and bundle bodies.
      #
      # Phase 12 §3.7 / v0.4 P-3.
      #
      # Two responsibilities:
      #   1. Strip control characters that enable invisible injection (bidi, zero-width, tag chars).
      #   2. Escape wrapper delimiters so reviewer-emitted text cannot break Agent's
      #      <review_feedback>...</review_feedback> or <artifact>...</artifact> framing.
      #
      # Used at three sites:
      #   - Dispatch: artifact_content sanitization before reviewer prompt
      #   - Aggregation: each finding.issue sanitized before feedback_text assembly
      #   - Chain record write/read: safe_load_bundle re-sanitizes on replay
      class Sanitizer
        # Unicode code points to strip. Enumerated explicitly (not "all Cc/Cf") because
        # some Cf characters (e.g., language tags) are legitimate in technical text.
        CONTROL_CHAR_RANGES = [
          0x0000..0x0008, 0x000B..0x000C, 0x000E..0x001F, 0x007F..0x009F,  # C0/C1 control
          0x00AD..0x00AD,                                                    # Soft Hyphen
          0x061C..0x061C,                                                    # Arabic Letter Mark (ALM)
          0x180B..0x180D, 0x180E..0x180E,                                    # Mongolian Free Variation Selectors + MVS
          0x200B..0x200F,                                                    # Zero-width + LRM/RLM
          0x2028..0x2029,                                                    # Line/Paragraph separator
          0x202A..0x202E,                                                    # Bidi overrides (LRE/RLE/PDF/LRO/RLO)
          0x2060..0x2064,                                                    # Word Joiner + invisible operators
          0x2066..0x2069,                                                    # Bidi isolates (LRI/RLI/FSI/PDI)
          0xFE00..0xFE0F,                                                    # Variation Selectors VS-1..VS-16 (PR3 hardening)
          0xFEFF..0xFEFF,                                                    # BOM / ZWNBSP
          0xE0000..0xE007F,                                                  # Tag chars
          0xE0100..0xE01EF                                                   # VS-17..VS-256 (supplementary)
        ].freeze

        # Wrapper delimiters that the Agent uses to frame untrusted content. Reviewer
        # output containing these breaks the framing; we replace them with [escaped:...]
        # forms that are visually informative but cannot collide with framing parsing.
        FORBIDDEN_DELIMITERS = %w[
          <artifact> </artifact>
          <review_feedback> </review_feedback>
          <finding> </finding>
          <persona> </persona>
        ].freeze

        # Maximum iterations of recursive delimiter substitution. Replacements eliminate
        # angle brackets so a fixed point is reached quickly; the cap protects against
        # future delimiter additions that could oscillate.
        MAX_SANITIZE_ITERATIONS = 8

        DEFAULT_MAX_LEN = 500

        # Maximum bytes for artifact_content sanitization. Large enough to hold a
        # full design doc (Phase 12 v0.3 was ~30KB) but caps replay-time DoS.
        ARTIFACT_MAX_LEN = 262_144  # 256KB

        # Pattern that catches case-insensitive delimiter variants with optional
        # whitespace inside the angle brackets ("< Artifact >", "</ artifact >").
        # Built from FORBIDDEN_DELIMITERS at load time.
        DELIMITER_PATTERN = Regexp.union(
          %w[artifact review_feedback finding persona].flat_map do |tag|
            ["<\\s*#{tag}\\s*>", "<\\s*/\\s*#{tag}\\s*>"]
          end.map { |p| Regexp.new(p, Regexp::IGNORECASE) }
        )

        # PR3 hardening: encoded delimiter forms that some downstream consumer
        # might decode (HTML renderer, URL parser, web log viewer). Detected
        # SEPARATELY from DELIMITER_PATTERN so they can be rejected at chain
        # boundary without false-positive escaping of legitimate text discussing
        # HTML entities. We only REJECT (not auto-escape) — encoded forms
        # appearing in artifact_content are a strong signal of injection intent.
        ENCODED_DELIMITER_PATTERN = Regexp.union(
          %w[artifact review_feedback finding persona].flat_map do |tag|
            [
              # HTML entity: &lt;artifact&gt;
              Regexp.new("&lt;\\s*#{tag}\\s*&gt;", Regexp::IGNORECASE),
              Regexp.new("&lt;\\s*/\\s*#{tag}\\s*&gt;", Regexp::IGNORECASE),
              # URL-encoded: %3Cartifact%3E
              Regexp.new("%3C\\s*#{tag}\\s*%3E", Regexp::IGNORECASE),
              Regexp.new("%3C\\s*/\\s*#{tag}\\s*%3E", Regexp::IGNORECASE)
            ]
          end
        )

        class SanitizationError < StandardError; end

        # Sanitize a single finding/issue/error string for safe inclusion in feedback_text.
        #
        # @param s [String, nil] untrusted text from reviewer or external source
        # @param max_len [Integer] truncation length applied AFTER sanitization
        # @return [String] sanitized + truncated; severity prefix is added by caller
        def self.sanitize_finding_text(s, max_len: DEFAULT_MAX_LEN)
          return '' if s.nil?
          s = s.to_s

          # Step 1: NFKC normalize to collapse fullwidth/compat variants
          # (e.g., U+FF1C / U+FF1E fullwidth angle brackets → ASCII < >).
          # Without this, '＜artifact＞' would bypass DELIMITER_PATTERN.
          s = s.unicode_normalize(:nfkc) if s.respond_to?(:unicode_normalize)

          # Step 2: strip enumerated control chars (after NFKC so fullwidth
          # control variants are caught by their canonical equivalents).
          s = s.each_char.reject { |c| control_char?(c) }.join

          # Step 3: escape wrapper delimiters with case/whitespace tolerance.
          # Recursive until stable; capped by MAX_SANITIZE_ITERATIONS.
          iterations = 0
          loop do
            before = s
            s = s.gsub(DELIMITER_PATTERN) { |m| "[escaped:#{m.gsub(/[<>\s\/]/, '')}]" }
            iterations += 1
            break if s == before
            if iterations >= MAX_SANITIZE_ITERATIONS
              raise SanitizationError,
                    "sanitize_finding_text did not reach fixed point in #{MAX_SANITIZE_ITERATIONS} iterations"
            end
          end

          # Step 4: truncate AFTER sanitization
          s[0, max_len]
        end

        # Sanitize artifact_content for safe inclusion in reviewer prompts.
        # Same contract as sanitize_finding_text but with a much higher max_len
        # (artifact bodies are intentionally large).
        def self.sanitize_artifact(s)
          sanitize_finding_text(s, max_len: ARTIFACT_MAX_LEN)
        end

        # Reject content destined for chain_record if it contains forbidden delimiters
        # un-escaped. This applies BEFORE inline-vs-CAS branching (v0.4 P-6) to ensure
        # CAS-routed bundles are also gated.
        #
        # @param content [String] canonical bytes of bundle or decision_payload
        # @return [void]
        # @raise [SanitizationError] if unsanitized delimiters present
        def self.reject_unsanitized_for_chain!(content)
          return if content.nil? || content.empty?
          # NFKC normalization collapses fullwidth angle brackets to ASCII so
          # attackers cannot route '＜artifact＞' through CAS.
          normalized = content.respond_to?(:unicode_normalize) ? content.unicode_normalize(:nfkc) : content
          if normalized =~ DELIMITER_PATTERN
            raise SanitizationError,
                  "chain_record refused: content contains unsanitized delimiter #{Regexp.last_match(0).inspect}"
          end
          # PR3 hardening: also reject encoded forms (HTML entity, URL-encoded).
          # These have no legitimate reason to appear in chain bundle bodies and
          # are a strong injection signal if a downstream tool decodes them.
          if normalized =~ ENCODED_DELIMITER_PATTERN
            raise SanitizationError,
                  "chain_record refused: content contains encoded delimiter #{Regexp.last_match(0).inspect}"
          end
          nil
        end

        # Re-sanitize on read (defense in depth). Used by safe_load_bundle.
        # Walks finding-shaped structures and applies sanitize_finding_text to issue strings.
        #
        # @param bundle [Hash, Array, String, Object] arbitrary nested structure
        # @return [Object] same shape with sanitized leaf strings
        def self.re_sanitize(bundle)
          case bundle
          when Hash
            bundle.transform_values { |v| re_sanitize(v) }
          when Array
            bundle.map { |v| re_sanitize(v) }
          when String
            sanitize_finding_text(bundle, max_len: 8192) # higher limit for non-finding text
          else
            bundle
          end
        end

        def self.control_char?(char)
          ord = char.ord
          CONTROL_CHAR_RANGES.any? { |r| r.cover?(ord) }
        end
        private_class_method :control_char?
      end
    end
  end
end
