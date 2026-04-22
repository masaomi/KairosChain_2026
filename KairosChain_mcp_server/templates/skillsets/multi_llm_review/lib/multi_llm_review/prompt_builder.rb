# frozen_string_literal: true

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
        # @param artifact_content [String] the full artifact text
        # @param artifact_name [String] artifact identifier
        # @param review_type [String] design, implementation, fix_plan, document
        # @param review_round [Integer] round number (1-based)
        # @param prior_findings [Array<Hash>, nil] findings from prior rounds
        # @return [Array<Hash>] messages array for llm_call
        def build_messages(artifact_content:, artifact_name:, review_type:,
                           review_round: 1, prior_findings: nil)
          parts = []
          parts << "<task>"
          parts << "Review the provided artifact for #{review_type} correctness."
          parts << "Target: #{artifact_name}"
          parts << "Round: R#{review_round}"
          if review_round > 1 && prior_findings && !prior_findings.empty?
            parts << "Scope: Review the revisions addressing prior findings."
            parts << ""
            parts << "Prior findings to verify as resolved:"
            prior_findings.each_with_index do |f, i|
              parts << "  #{i + 1}. [#{f[:severity]}] #{f[:issue]} (cited by: #{Array(f[:cited_by]).join(', ')})"
            end
          else
            parts << "Scope: Initial review"
          end
          parts << "</task>"
          parts << ""
          parts << "<artifact>"
          parts << artifact_content
          parts << "</artifact>"
          parts << ""
          parts << grounding_rules

          [{ 'role' => 'user', 'content' => parts.join("\n") }]
        end

        def structured_output_contract
          <<~CONTRACT
            <structured_output_contract>
            Output a review with this structure:

            **Overall Verdict**: APPROVE / REJECT

            For each finding, use this single-line format (one finding per line):
            P0: <issue description> [location: file:line]
            P1: <issue description> [location: file:line]
            P2: <issue description> [location: file:line]
            P3: <issue description> [location: file:line]

            Example:
            P0: Missing input validation in dispatcher timeout path [location: dispatcher.rb:120]
            P1: Thread safety issue with shared counter [location: consensus.rb:45]

            If no issues found, state "No findings" and verdict APPROVE.
            </structured_output_contract>
          CONTRACT
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
