# frozen_string_literal: true

require_relative 'verdict_vocabulary'

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

        module_function

        # The name this system records a persona team under. Constructed here,
        # where the persona entry is built, and read from here by ObserverSet —
        # which needs it before the entry exists, to refuse a roster that
        # already contains that name.
        def role_label_for(model)
          "claude_team_#{model}"
        end

        # @param orchestrator_reviews [Array<Hash>] each: {persona, verdict, findings, reasoning}
        # @param orchestrator_model [String]
        # @return [Hash] reviewer entry with :status, :verdict, :raw_text, :role_label, :provider, :model
        def assemble(orchestrator_reviews, orchestrator_model)
          validate_orchestrator_model!(orchestrator_model)
          validate!(orchestrator_reviews)

          # Guaranteed readable by validate! above: every verdict field has
          # already been admitted by `stated`, so this map cannot produce nil.
          verdicts = orchestrator_reviews.map { |r| VerdictVocabulary.stated(r['verdict'] || r[:verdict]) }
          combined = if verdicts.include?('REJECT')
                       'REJECT'
                     elsif verdicts.include?('REVISE')
                       'REVISE'
                     else
                       'APPROVE'
                     end

          raw_text = build_raw_text(orchestrator_reviews, combined)

          {
            role_label: role_label_for(orchestrator_model),
            provider: 'claude_code',
            model: orchestrator_model,
            # INV-P1. The persona runs in the caller's harness, where this
            # system cannot see it, so this name is what the caller said and
            # not what was observed. Saying which of the two it is costs one
            # field and is the difference between a record and a guess.
            model_source: 'declared',
            # The team's verdict is decided here, from the personas' stated
            # verdicts, and is carried as a field rather than left to be
            # re-derived from the rendered text. Re-deriving it made the team
            # verdict a function of what the personas happened to quote: in
            # round 4 a persona quoted a JSON reply shape inside a finding and
            # three REVISE verdicts were recorded as an APPROVE.
            verdict: combined,
            # INV-P1 / INV-E4. This row is a declaration standing in for an
            # observer, not an observer that ran, and without a field saying
            # so it is shaped exactly like a dispatched slot whose transport
            # could not report its model.
            synthetic: true,
            # INV-E2 reaches the persona too, but not through the character
            # count used for free text: this entry is a structured submission,
            # so what makes it substantive is structural. A submission whose
            # personas carry neither reasoning nor findings is the hollow case
            # — a terse but structured one is not.
            substantive: orchestrator_reviews.any? { |r| persona_says_something?(r) },
            raw_text: raw_text,
            elapsed_seconds: 0,
            error: nil,
            status: :success
          }
        end

        def persona_says_something?(review)
          reasoning = (review['reasoning'] || review[:reasoning]).to_s.strip
          return true unless reasoning.empty?

          findings = review['findings'] || review[:findings]
          return false unless findings.respond_to?(:any?)

          # A findings array of nils or blanks is not a finding. Counting the
          # array's length alone let a verdict-only submission through by
          # padding it with empty entries.
          findings.any? { |f| finding_says_something?(f) }
        end

        # A severity with no issue text renders as an empty finding, so it is
        # not substance — the tag alone says nothing about what is wrong.
        def finding_says_something?(finding)
          case finding
          when Hash
            (finding['issue'] || finding[:issue]).to_s.strip != ''
          when nil then false
          else finding.to_s.strip != ''
          end
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
            # The verdict field must BE a verdict, whole-value, by the same
            # `stated` that reads it later. This is the boundary form of the
            # non-verdict landing: unlike an external reply, this submission
            # is authored by the caller mid-conversation and can be restated,
            # so a value that is not a verdict is refused here rather than
            # excluded silently or defaulted to a vote nobody cast. Round 13
            # measured what the previous REVISE fallback cost: a decorated
            # rejection ("REJECT (2 blockers)") became a non-rejecting row in
            # the denominator, a round the old word-search would have blocked
            # converged APPROVE, and the fallback left no trace in the
            # record. Refusing keeps INV-E2: nothing unread enters any
            # denominator. INV-E4 it satisfies by not engaging it — and that
            # holds by mechanism, not by the nature of refusals: this raise
            # fires before anything is composed or written (collect validates
            # before consuming), so no run record and no denominator arise,
            # and no recordable cause with them. A landing that refused one
            # persona and continued with the rest WOULD move the composition
            # and would owe the record its cause; the clause asks that every
            # cause that moved the denominator be readable from the record,
            # not that every refusal reach one.
            # (An earlier version of this paragraph claimed the error
            # satisfies INV-E4 by reaching the caller; round 14's review
            # refuted that — a transient tool reply is not the record.)
            # The error is simply how the caller learns; collect
            # validates before consuming, so the pending token survives a
            # refusal and the corrected submission can collect. What no
            # record shows — that a submission was refused and reshaped
            # before the one recorded — is a known gap, queued for the
            # record-schema revision alongside the other additions to what a
            # run's record carries.
            unless VerdictVocabulary.stated(verdict)
              shown = verdict.to_s.length > 80 ? "#{verdict.to_s[0, 80]}…" : verdict.to_s
              raise ArgumentError,
                "review #{i} (persona #{persona}) verdict #{shown.inspect} is not a verdict; " \
                'state APPROVE, REVISE or REJECT (or a vocabulary alias) as the whole value'
            end
          end
        end

        # There is no verdict fallback here any more. Until round 13 an
        # unreadable verdict field was word-searched; in round 13 it fell to
        # a logged REVISE; both manufactured a vote nobody cast, and the
        # round-13 review measured the REVISE fallback moving votes in the
        # direction that passes. Since round 14 the field is admitted by
        # validate! (whole-value, `stated`) before anything is combined, so
        # by the time a verdict is read here it is one.

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

            # persona was validated by IDENT_RE, verdict by `stated`, so both
            # are safe for header interpolation and the read cannot be nil.
            parts << "## Persona: #{persona_raw} (verdict: #{VerdictVocabulary.stated(verdict_raw)})"
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
