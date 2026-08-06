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
        # Tags that wrap untrusted content. Deliberately NOT widened to the tags
        # the prompt uses as its own frame (`<task>`, `<artifact_reference>`,
        # `<grounding_rules>`, `<default_follow_through_policy>`), although a
        # replayed finding can forge those and this list does not stop it.
        #
        # That gap is real and is recorded as separate work rather than closed
        # here. Widening this constant changes a primitive three call sites and
        # a second SkillSet share, and the attempt measured its cost: every
        # artifact that merely *names* a tag came back rewritten, which for this
        # SkillSet means its own prompt-building source and its own design notes
        # arrive at reviewers with the tags replaced. A security widening that
        # corrupts the documents under review needs to be designed, not appended
        # to an evidence-fidelity fix.
        WRAPPER_TAGS = %w[artifact review_feedback finding persona].freeze

        # Human-readable form of the wrapper set, kept in sync by construction.
        # This constant and the escape pattern below were once two hand-written
        # lists of the same four tags, and an edit to this one escaped nothing.
        FORBIDDEN_DELIMITERS = WRAPPER_TAGS.flat_map do |tag|
          ["<#{tag}>", "</#{tag}>"]
        end.freeze

        # Maximum iterations of recursive delimiter substitution. Replacements eliminate
        # angle brackets so a fixed point is reached quickly; the cap protects against
        # future delimiter additions that could oscillate.
        MAX_SANITIZE_ITERATIONS = 8

        DEFAULT_MAX_LEN = 500

        # The bound for a finding on its way into the record, as opposed to on
        # its way into a prompt. One number used to serve both, and the shorter
        # of the two purposes won: the record kept what the display could show
        # rather than what the reviewer wrote.
        #
        # Raising this does not lengthen a prompt only because every path that
        # takes a finding into one applies DEFAULT_MAX_LEN itself — today
        # FeedbackFormatter for feedback_text, and PromptBuilder for the
        # findings a later round carries forward. That is a property of those
        # call sites, not of this constant: a new prompt path that interpolates
        # a record-bound finding directly would inherit 8000, and the bound
        # belongs at the injection point rather than here.
        #
        # This bounds one finding, not the response, and it is measured in BYTES
        # rather than characters — see clamp_finding_bytes, which is where it is
        # applied. The row count is capped by MAX_AGGREGATED_FINDINGS and the
        # per-row variant list by MAX_ISSUE_VARIANTS, so the response has a
        # ceiling of 200 rows x 9 texts x 8000 bytes ≈ 14.4 MB. That ceiling is
        # only reachable by a reply crafted to produce 1800 findings whose
        # openings collide in groups; it is accepted as bounded-but-large rather
        # than tightened, and lowering MAX_ISSUE_VARIANTS is the one knob that
        # moves it.
        #
        # An earlier attempt bounded the reply instead, at the transport, in
        # bytes. It did not work and the measurement is worth keeping: NFKC
        # normalisation runs after that bound and before the character cut, and
        # U+FDFA expands from 3 bytes to 18 characters, so five replies each
        # inside a 512 KB byte budget still produced a 26.9 MB response. A bound
        # upstream of an expanding transform bounds the wrong quantity. Cutting
        # here — after extraction, before sanitisation — fixes the size of what
        # is stored and the size of what is normalised with one number.
        FINDING_RECORD_MAX_LEN = 8000

        # The bound on reviews[].raw_text when the caller opts in. What is
        # stored under that bound is the sanitised transcription of the reply,
        # not the reply, and it can be shorter than this number says while the
        # reply was longer — the tool schema states both facts, because a
        # field quietly narrower than its name is the defect this change
        # exists to remove. Bounded because it lands in the caller's context
        # window.
        RAW_TEXT_FULL_MAX_LEN = 65_536

        # Cut text to a BYTE budget without splitting a codepoint and without
        # raising on invalid encoding. Applied twice on the way to the record:
        # once where a finding is extracted, so that normalisation, the
        # per-character control pass, the delimiter substitution and the JSON on
        # disk work on a known quantity — and once after sanitisation, because
        # sanitize_finding_text cuts in CHARACTERS while this bound is declared
        # in BYTES, and NFKC runs before that cut. Measured: U+3316 is three
        # bytes in and six characters out, so a finding clamped to 7,999 bytes
        # at extraction came back 23,926 bytes after sanitisation.
        #
        # `scrub` runs unconditionally rather than under `valid_encoding?`
        # because its job here is to drop invalid byte sequences from a
        # UTF-8-tagged string, so that `byteslice` cannot leave a partial
        # codepoint behind. It does not rescue a binary (ASCII-8BIT) string:
        # there `scrub` is a no-op and `unicode_normalize` raises downstream
        # either way.
        def self.clamp_finding_bytes(s, max_bytes: FINDING_RECORD_MAX_LEN)
          return '' if s.nil?

          s = s.to_s.scrub('')
          return s if s.bytesize <= max_bytes

          s.byteslice(0, max_bytes).scrub('')
        end

        # The bound a findings array carries on its way into the record, as
        # opposed to on its way into a prompt. This used to sanitize at the
        # 500-character default and hand one array to both the record and the
        # prompt, so the record was as short as the prompt needed to be.
        # FeedbackFormatter.build re-sanitizes each issue at the display bound
        # itself, so the prompt stays bounded without the record having to be.
        #
        # The clamp runs AFTER the sanitize because sanitize_finding_text cuts
        # in CHARACTERS while FINDING_RECORD_MAX_LEN is declared in BYTES, and
        # NFKC runs before that cut: U+3316 is three bytes in and six characters
        # out. The clamp that bounds the sanitizer's INPUT is applied where a
        # finding is extracted, in Consensus, not here.
        #
        # It lives here rather than in either tool because it existed twice,
        # byte-identical, inside multi_llm_review.rb and multi_llm_review_collect.rb,
        # and neither copy had an entry point — so a test meant to pin it copied
        # the expression instead of calling it, and a test that rewrites the
        # code under test goes green whatever that code does.
        #
        # The variants go through the same sanitize as the issue: a variant
        # reaches the payload by the same path.
        #
        # @param findings [Array<Hash>] finding rows with String keys
        # @return [Array<Hash>] the same rows, 'issue' and 'issue_variants' bound
        def self.bound_findings_for_record(findings)
          findings.map do |f|
            row = f.merge(
              'issue' => clamp_finding_bytes(
                sanitize_finding_text(f['issue'], max_len: FINDING_RECORD_MAX_LEN)
              )
            )
            if row['issue_variants']
              row = row.merge(
                'issue_variants' => Array(row['issue_variants']).map do |v|
                  clamp_finding_bytes(sanitize_finding_text(v, max_len: FINDING_RECORD_MAX_LEN))
                end
              )
            end
            row
          end
        end

        # Maximum bytes for artifact_content sanitization. Large enough to hold a
        # full design doc (Phase 12 v0.3 was ~30KB) but caps replay-time DoS.
        ARTIFACT_MAX_LEN = 262_144  # 256KB

        # Pattern that catches case-insensitive delimiter variants with optional
        # whitespace inside the angle brackets ("< Artifact >", "</ artifact >").
        # Built from FORBIDDEN_DELIMITERS at load time.
        # Derived from WRAPPER_TAGS rather than from a second hand-written list.
        # The two had drifted apart in exactly the way that matters: this pattern
        # was built from its own copy of the four tags while FORBIDDEN_DELIMITERS
        # named them separately, so editing that constant escaped nothing. A tag
        # that is framing in one place and not the other is the hole itself.
        DELIMITER_PATTERN = Regexp.union(
          WRAPPER_TAGS.flat_map do |tag|
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
          WRAPPER_TAGS.flat_map do |tag|
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
