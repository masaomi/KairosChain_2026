# frozen_string_literal: true

require_relative 'sanitizer'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Builds review prompts from artifact content, review type metadata,
      # and L1 knowledge (multi_llm_review_workflow criteria).
      module PromptBuilder
        # Review-type-specific criteria loaded from L1 knowledge or defaults.
        REVIEW_CRITERIA = {
          'design' => {
            focus: 'Architecture, enforcement paths, threat model, layer boundaries',
            instructions: 'Evaluate the design for correctness, completeness, and security. ' \
              'Check that all components exist and APIs are correctly referenced.'
          },
          'implementation' => {
            focus: 'Code correctness, security, wiring, test coverage, edge cases',
            instructions: 'Review the implementation for bugs, missing error handling, ' \
              'race conditions, and deviation from the design specification.'
          },
          'fix_plan' => {
            focus: 'Completeness of fixes, correctness of proposed changes, prioritization',
            instructions: 'Verify each proposed fix addresses the original finding. ' \
              'Check for regressions and missed interactions between fixes.'
          },
          'document' => {
            focus: 'Accuracy, completeness, consistency, clarity',
            instructions: 'Review for factual accuracy, missing sections, and consistency ' \
              'with the codebase and other documentation.'
          }
        }.freeze

        module_function

        # Collapse every line break — and the runs of whitespace a fold
        # produces — into single spaces, so a value interpolated into a
        # one-line prompt entry stays on that line.
        def one_line(s)
          s.to_s.gsub(/[\r\n  ]+/, ' ').gsub(/\s{2,}/, ' ').strip
        end

        # Build the system prompt for a review call.
        # @param review_type [String] one of: design, implementation, fix_plan, document
        # @param review_context [String] 'independent' or 'project_aware'
        # @return [String]
        def build_system_prompt(review_type, review_context: 'independent')
          criteria = REVIEW_CRITERIA[review_type] || REVIEW_CRITERIA['implementation']

          parts = []
          parts << "You are an independent code reviewer."
          parts << "Do NOT read or reference any project-level instruction files (CLAUDE.md, .cursorrules, etc.)." if review_context == 'independent'
          parts << ""
          parts << "Focus: #{criteria[:focus]}"
          parts << criteria[:instructions]
          parts << ""
          parts << structured_output_contract
          parts.join("\n")
        end

        # Build the user message containing the artifact to review.
        # @param artifact_content [String, nil] the full artifact text (inline
        #   delivery). Ignored when artifact_reference is given.
        # @param artifact_name [String] artifact identifier
        # @param review_type [String] design, implementation, fix_plan, document
        # @param review_round [Integer] round number (1-based)
        # @param prior_findings [Array<Hash>, nil] findings from prior rounds
        # @param artifact_reference [Hash, nil] {path:, sha256:} — by_reference
        #   delivery (INV-R7): the seat reads the original where it lives, and
        #   the manifest is what crosses instead of the body.
        # @return [Array<Hash>] messages array for llm_call
        def build_messages(artifact_name:, review_type:, artifact_content: nil,
                           review_round: 1, prior_findings: nil,
                           artifact_reference: nil)
          parts = []
          parts << "<task>"
          parts << "Review the provided artifact for #{review_type} correctness."
          parts << "Target: #{artifact_name}"
          # The round number is deliberately NOT given to the reviewer
          # (2026-08-06). Telling a reviewer which round it is in — like
          # telling it its finding count is compared across rounds — turns the
          # count into something the reviewer performs, and selects for
          # finding-production over finding-weight. Convergence is measured by
          # the orchestrator from the record; the reviewer needs the artifact,
          # the criteria, and the prior findings to verify, nothing else.
          if review_round > 1 && prior_findings && !prior_findings.empty?
            parts << "Scope: Review the revisions addressing prior findings."
            parts << ""
            parts << "Prior findings to verify as resolved:"
            # Bounded and sanitized here, at the point where the text enters a
            # prompt. A carried-forward finding is round N-1's
            # aggregated_findings, which the record now keeps at
            # FINDING_RECORD_MAX_LEN rather than at the display bound — so
            # without this the record's widening would silently lengthen the
            # next round's prompt by the same factor. This is also the one
            # path that took reviewer-authored text into a prompt without
            # sanitizing it: the text is untrusted wherever it is replayed,
            # not only where it was first received.
            prior_findings.each_with_index do |f, i|
              # Newlines are folded, not stripped, and the fold happens here
              # rather than in the sanitizer. A newline is legitimate inside a
              # finding and the sanitizer keeps it for that reason; it is this
              # format that cannot survive one, because one finding is one line
              # and a reply that emits a newline otherwise writes as many lines
              # as it likes. Severity and the citation list are interpolated
              # too, so they are bounded the same way — the value is a token
              # this system chose, but nothing here re-checks that, and an
              # unchecked interpolation is the same hole whichever field it is.
              issue = one_line(Sanitizer.sanitize_finding_text(f[:issue] || f['issue']))
              severity = one_line(Sanitizer.sanitize_finding_text(
                                    f[:severity] || f['severity'], max_len: 16
                                  ))
              cited = one_line(Sanitizer.sanitize_finding_text(
                                 Array(f[:cited_by] || f['cited_by']).join(', '), max_len: 200
                               ))
              parts << "  #{i + 1}. [#{severity}] #{issue} (cited by: #{cited})"
            end
          else
            parts << "Scope: Initial review"
          end
          parts << "</task>"
          parts << ""
          if artifact_reference
            parts << "<artifact_reference>"
            parts << "The artifact is not inlined. Read the original from the repository:"
            parts << "path: #{artifact_reference[:path]}"
            parts << "sha256: #{artifact_reference[:sha256]}"
            parts << "Verify the file's sha256 matches before reviewing. If it does not " \
                     "match, or you cannot read the file, state that as your reply " \
                     "instead of reviewing."
            parts << "</artifact_reference>"
          else
            parts << "<artifact>"
            parts << artifact_content
            parts << "</artifact>"
            parts << ""
            parts << seat_access_note
          end
          parts << ""
          parts << grounding_rules

          [{ 'role' => 'user', 'content' => parts.join("\n") }]
        end

        def structured_output_contract
          <<~CONTRACT
            <structured_output_contract>
            Output a review with this structure.

            The FIRST line of your reply must be exactly one of these three
            lines, before any other text:

            **Overall Verdict**: APPROVE
            **Overall Verdict**: REVISE
            **Overall Verdict**: REJECT

            Nothing else on that line. A qualified verdict ("APPROVE, with
            reservations"), a restatement of these options on one line, or a
            verdict stated further down is NOT read as yours, and your review
            leaves the count with "no verdict" recorded beside your name. This
            is deliberate: your judgement is not guessed at from your prose,
            because guessing has read negations as approvals and terse
            approvals as rejections. Say which of the three, on line one.

            Quoting verdict headers elsewhere in your review is safe — only
            line one is read.

            For each finding, use this single-line format (one finding per line):
            P0: <issue description> [consequence: <who is harmed, and how, if this is never fixed>] [location: file:line]
            P1: <issue description> [consequence: ...] [location: file:line]
            P2: <issue description> [location: file:line]
            P3: <issue description> [location: file:line]

            The consequence clause is REQUIRED for P0 and recommended for
            P1; P1 findings are never demoted for lacking one. A finding can be
            factually correct and still cost nobody anything; the consequence
            clause is where you say who hits the defect and what happens to
            them. A P0 with no consequence clause, or an empty one, is
            recorded at P2. Do not restate the issue as its own consequence —
            name the person or process that is harmed.

            Example:
            P0: Missing input validation in dispatcher timeout path [consequence: a caller passing a negative timeout crashes the worker and the whole round's reviews are lost] [location: dispatcher.rb:120]
            P1: Thread safety issue with shared counter [consequence: concurrent collects double-count usage] [location: consensus.rb:45]

            If no issues found, state "No findings" and verdict APPROVE.
            </structured_output_contract>
          CONTRACT
        end

        # Why this note exists (2026-08-06): the claude_code subprocess seat
        # runs with tools disabled in an empty working directory, and on
        # implementation artifacts that cite file paths it tried to read the
        # code before judging — two rounds opened with pseudo-tool-call markup
        # and one with "the repository is not accessible", so the verdict
        # header never came first and the seat left the denominator as
        # no_verdict four rounds in a row (the same seat counted every round
        # on design artifacts in the same period). The wording is conditional
        # because seats differ — codex runs `--sandbox read-only` and can
        # verify against the repository — and the note is emitted only with an
        # inline artifact: by_reference delivery already instructs a seat that
        # cannot read the file to say so instead of reviewing.
        def seat_access_note
          <<~NOTE
            <seat_access>
            Your seat may have no file-system or tool access. If you cannot
            read the repository, do not attempt tool calls and do not open by
            saying you will read files: review the artifact text above on its
            own, mark claims you cannot verify as [INFERRED], and still put
            your verdict line first.
            </seat_access>
          NOTE
        end

        def grounding_rules
          <<~RULES
            <grounding_rules>
            Ground every finding in the provided artifact text.
            If a claim is an inference, label it: "[INFERRED] Based on X, this likely means Y."
            Do not invent files, methods, or runtime behavior not shown in the artifact.
            </grounding_rules>

            <default_follow_through_policy>
            Complete the full review in one pass. Do not ask clarifying questions.
            </default_follow_through_policy>
          RULES
        end
      end
    end
  end
end
