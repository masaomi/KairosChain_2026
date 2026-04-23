# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Combine N orchestrator persona reviews into a single reviewer entry
      # that downstream Consensus can treat identically to any other reviewer.
      #
      # Design v0.2 §5: REJECT > REVISE > APPROVE precedence; concatenate
      # reasoning into raw_text so Consensus.aggregate_findings can re-extract
      # P0/P1/... lines uniformly.
      module PersonaAssembly
        MIN_PERSONAS = 2
        MAX_PERSONAS = 4

        # Size bounds to prevent pathological inputs (hallucinating LLMs,
        # adversarial callers) from exploding pending state file size.
        MAX_REASONING_LENGTH = 8192
        MAX_ISSUE_LENGTH = 1024
        MAX_FINDINGS_PER_PERSONA = 50

        # Safe identifier shape for persona names and orchestrator_model when
        # interpolated into raw_text headers / role_label / JSON identifiers.
        IDENT_RE = /\A[A-Za-z0-9_.\-]{1,64}\z/

        # Canonical verdicts recognized by downstream Consensus.
        ALLOWED_VERDICTS = %w[APPROVE REVISE REJECT].freeze
        # Additional verdict synonyms recognized during normalization.
        # The regexes accept underscore / hyphen / space as separators so
        # variants like NO_GO, NO-GO, NO GO, NEEDS_REVISION all normalize.
        APPROVE_ALIASES = /\b(?:APPROVE[DS]?|PASS(?:ED)?|ACCEPT(?:ED)?|LGTM|SHIP[_\s]*IT)\b/i
        REJECT_ALIASES  = /\b(?:REJECT(?:ED)?|FAIL(?:ED|URE)?|BLOCK(?:ED|ER|ING)?|NO[_\s\-]*GO|NACK|DENY|VETO)\b/i
        REVISE_ALIASES  = /\b(?:REVISE|CHANGES?[_\s]*REQUIRED|NEEDS?[_\s]*(?:WORK|REVISION|CHANGES?)|REWORK)\b/i

        module_function

        # @param orchestrator_reviews [Array<Hash>] each: {persona, verdict, findings, reasoning}
        # @param orchestrator_model [String]
        # @return [Hash] reviewer entry with :status, :verdict, :raw_text, :role_label, :provider, :model
        def assemble(orchestrator_reviews, orchestrator_model)
          validate_orchestrator_model!(orchestrator_model)
          validate!(orchestrator_reviews)

          verdicts = orchestrator_reviews.map { |r| normalize_verdict(r['verdict'] || r[:verdict]) }
          combined = if verdicts.include?('REJECT')
                       'REJECT'
                     elsif verdicts.include?('REVISE')
                       'REVISE'
                     else
                       'APPROVE'
                     end

          raw_text = build_raw_text(orchestrator_reviews, combined)

          {
            role_label: "claude_team_#{orchestrator_model}",
            provider: 'claude_code',
            model: orchestrator_model,
            raw_text: raw_text,
            elapsed_seconds: 0,
            error: nil,
            status: :success,
            synthetic: true
          }
        end

        def validate_orchestrator_model!(model)
          unless model.is_a?(String) && IDENT_RE.match?(model)
            raise ArgumentError,
              "invalid orchestrator_model (must match /\\A[A-Za-z0-9_.\\-]{1,64}\\z/): #{model.inspect}"
          end
        end

        def validate!(reviews)
          unless reviews.is_a?(Array)
            raise ArgumentError, 'orchestrator_reviews must be an array'
          end
          if reviews.size < MIN_PERSONAS
            raise ArgumentError, "need at least #{MIN_PERSONAS} persona reviews (got #{reviews.size})"
          end
          if reviews.size > MAX_PERSONAS
            raise ArgumentError, "no more than #{MAX_PERSONAS} persona reviews (got #{reviews.size})"
          end
          reviews.each_with_index do |r, i|
            unless r.is_a?(Hash)
              raise ArgumentError, "review #{i} must be a Hash"
            end
            persona = r['persona'] || r[:persona]
            verdict = r['verdict'] || r[:verdict]
            if persona.nil? || persona.to_s.empty?
              raise ArgumentError, "review #{i} missing required field: persona"
            end
            unless IDENT_RE.match?(persona.to_s)
              raise ArgumentError,
                "review #{i} invalid persona name (must match /\\A[A-Za-z0-9_.\\-]{1,64}\\z/): #{persona.inspect}"
            end
            if verdict.nil? || verdict.to_s.empty?
              raise ArgumentError, "review #{i} missing required field: verdict"
            end
          end
        end

        def normalize_verdict(raw, context: nil)
          upper = raw.to_s.upcase
          # Order: REJECT first, then APPROVE, then REVISE — if a string
          # contains both (e.g. "I approve but with concerns that may lead to
          # reject"), REJECT wins to stay on the safe side of precedence.
          return 'REJECT'  if upper.match?(REJECT_ALIASES)
          return 'APPROVE' if upper.match?(APPROVE_ALIASES)
          return 'REVISE'  if upper.match?(REVISE_ALIASES)
          # Conservative fallback: unknown verdicts are logged and treated as
          # REVISE (do not let them silently pass as APPROVE or silently block
          # as REJECT; REVISE requires orchestrator attention).
          ctx = context ? " (#{context})" : ''
          warn "[multi_llm_review::PersonaAssembly] unknown verdict#{ctx} #{raw.inspect} → REVISE"
          'REVISE'
        end

        # Truncate a string to at most `max_chars` Unicode codepoints,
        # handling ASCII-8BIT-forced inputs safely so multibyte codepoints
        # are never split. Returns a scrubbed UTF-8 string.
        def safe_truncate(text, max_chars)
          s = text.to_s.dup
          # Force UTF-8 interpretation; scrub any invalid sequences.
          if s.encoding == Encoding::ASCII_8BIT
            s.force_encoding(Encoding::UTF_8)
          end
          s = s.scrub('') unless s.valid_encoding?
          if s.each_char.count > max_chars
            s.each_char.first(max_chars).join + "\n...[truncated]"
          else
            s
          end
        end

        # Prevent user-supplied text from spoofing Consensus finding extraction.
        # Downstream Consensus.aggregate_findings matches /\*{0,2}(P[0-3])\*{0,2}[-\s]*\d*[.:]/i,
        # so we wrap any P0..P3 token in user-controlled text with brackets so
        # the regex no longer matches it. A legitimate "**P1**: issue" line
        # emitted BY the formatter itself uses a separate safe path.
        def neutralize_severity_patterns(text)
          text.to_s.gsub(/(P[0-3])/i, '[\1]')
        end

        def build_raw_text(reviews, combined_verdict)
          parts = ["**Overall Verdict**: #{combined_verdict}", '']
          reviews.each do |r|
            persona_raw = (r['persona'] || r[:persona]).to_s
            verdict_raw = (r['verdict'] || r[:verdict]).to_s
            reasoning = (r['reasoning'] || r[:reasoning] || '').to_s
            findings = Array(r['findings'] || r[:findings])

            # Truncate oversized reasoning (validated upstream; defense in depth).
            reasoning = safe_truncate(reasoning, MAX_REASONING_LENGTH)
            findings = findings[0, MAX_FINDINGS_PER_PERSONA]

            # persona was validated by IDENT_RE, so safe for header interpolation.
            parts << "## Persona: #{persona_raw} (verdict: #{normalize_verdict(verdict_raw)})"
            parts << ''
            unless reasoning.empty?
              parts << neutralize_severity_patterns(reasoning)
            end
            parts << ''
            findings.each do |f|
              if f.is_a?(Hash)
                sev = (f['severity'] || f[:severity] || 'P2').to_s
                sev = 'P2' unless sev.match?(/\AP[0-3]\z/i)
                issue = safe_truncate(f['issue'] || f[:issue] || '', MAX_ISSUE_LENGTH)
                # sev is emitted as a legit Consensus marker; issue is user-
                # content so neutralize internal severity patterns.
                parts << "**#{sev.upcase}**: #{neutralize_severity_patterns(issue)}"
              else
                issue = safe_truncate(f, MAX_ISSUE_LENGTH)
                parts << "**P2**: #{neutralize_severity_patterns(issue)}"
              end
            end
            parts << ''
          end
          parts.join("\n")
        end
      end
    end
  end
end
