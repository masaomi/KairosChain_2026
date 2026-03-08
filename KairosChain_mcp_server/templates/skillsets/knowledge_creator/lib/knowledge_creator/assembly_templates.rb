# frozen_string_literal: true

module KnowledgeCreator
  # Generates structured Persona Assembly prompts for knowledge evaluation.
  # These templates guide the LLM to perform multi-perspective evaluation;
  # the tool itself does NOT execute evaluation autonomously.
  module AssemblyTemplates
    module_function

    EVALUATION_PERSONAS = {
      'evaluator' => {
        role: 'Knowledge Quality Inspector',
        bias: 'High bar for evidence; superficial compliance is failure',
        focus: 'Can I cite specific evidence for each criterion?'
      },
      'guardian' => {
        role: 'L0/L1 Boundary Guardian',
        bias: 'Conservative; protect layer integrity',
        focus: 'Does this knowledge stay within its declared layer?'
      },
      'pragmatic' => {
        role: 'Practical Value Assessor',
        bias: 'Real-world utility over theoretical purity',
        focus: 'Will an LLM actually use this knowledge effectively?'
      }
    }.freeze

    COMPARE_PERSONAS = {
      'kairos' => {
        role: 'Philosophy Alignment Reviewer',
        bias: 'Self-referential consistency',
        focus: 'Which version better serves KairosChain principles?'
      },
      'pragmatic' => {
        role: 'Practical Value Assessor',
        bias: 'Real-world utility',
        focus: 'Which version is more actionable?'
      },
      'skeptic' => {
        role: 'Critical Analyst',
        bias: 'Doubt first; prove value',
        focus: 'Which version has fewer weaknesses?'
      }
    }.freeze

    EVALUATION_DIMENSIONS = [
      { name: 'Triggering quality', question: 'Does `description` enable accurate identification from knowledge_list?' },
      { name: 'Self-containedness', question: 'No session-specific context leaks?' },
      { name: 'Progressive disclosure', question: 'Body vs references/ balance appropriate?' },
      { name: 'Evidence', question: 'Are claims factual and verifiable?' },
      { name: 'Discrimination', question: 'Does this provide information the base LLM does not have?' },
      { name: 'Redundancy', question: 'Overlap with existing L1 knowledge?' },
      { name: 'Safety alignment', question: 'No L0 conflicts?' }
    ].freeze

    def evaluation_prompt(target_name:, target_content:, personas: nil, mode: 'oneshot')
      persona_names = personas || %w[evaluator guardian pragmatic]
      persona_defs = persona_names.map { |p| EVALUATION_PERSONAS[p] || { role: p, bias: 'General', focus: 'Overall quality' } }

      <<~PROMPT
        ## Persona Assembly: Knowledge Quality Evaluation

        ### Mode: #{mode}

        ### Target Knowledge: #{target_name}

        ### Evaluation Task
        Evaluate the following L1 knowledge from multiple perspectives.
        For each dimension, cite specific evidence from the content.
        PASS requires citing specific evidence. Surface-level compliance is FAIL.

        ### Personas
        #{persona_names.each_with_index.map { |name, i|
          d = persona_defs[i]
          "- **#{name}** (#{d[:role]}): Bias: #{d[:bias]}. Focus: #{d[:focus]}"
        }.join("\n")}

        ### Knowledge Content
        ```
        #{target_content}
        ```

        ### Evaluation Dimensions
        #{EVALUATION_DIMENSIONS.each_with_index.map { |dim, i|
          "#{i + 1}. **#{dim[:name]}** — #{dim[:question]}"
        }.join("\n")}

        ### Output Format

        #### Readiness Assessment
        **Level**: READY / REVISE / DRAFT

        | Level | Meaning |
        |-------|---------|
        | READY | Meets L1 quality standards; safe to promote |
        | REVISE | Has potential but specific issues need fixing |
        | DRAFT | Not yet stable enough for L1 |

        #### Per-Persona Evaluation
        For each persona, for each dimension:
        - **{Dimension}**: PASS/FAIL — Evidence: "quoted text or specific observation"

        #### Summary Table
        | Criterion | Pass Count | Fail Count |
        |-----------|-----------|-----------|

        #### Improvement Suggestions
        Numbered list of specific, actionable improvements.
      PROMPT
    end

    def analysis_prompt(target_name:, target_content:, creation_guide_content: nil)
      <<~PROMPT
        ## Structural Pattern Analysis: #{target_name}

        ### Task
        Analyze the structural patterns used in this knowledge and suggest improvements
        based on the KairosChain creation guide patterns.

        ### Knowledge Content
        ```
        #{target_content}
        ```

        #{creation_guide_content ? "### Reference: Creation Guide Patterns\n```\n#{creation_guide_content}\n```" : ''}

        ### Analysis Dimensions
        1. Which structural pattern(s) does this knowledge use? (Quick Reference Table, Deterministic Workflow, Critical Rules, Multi-Tool Selection, QA-First, Session Distillation)
        2. Is the chosen pattern appropriate for the content type?
        3. What structural improvements would increase utility?
        4. Is the frontmatter (description, tags) well-designed?

        ### Output Format
        - **Current patterns**: List detected patterns
        - **Pattern fit**: GOOD / IMPROVABLE / MISMATCH
        - **Suggestions**: Specific structural changes with examples
      PROMPT
    end

    def comparison_prompt(version_a_content:, version_b_content:, blind: true, personas: nil)
      persona_names = personas || %w[kairos pragmatic skeptic]
      persona_defs = persona_names.map { |p| COMPARE_PERSONAS[p] || { role: p, bias: 'General', focus: 'Overall quality' } }

      label_a = blind ? 'Version A' : 'Version A (current)'
      label_b = blind ? 'Version B' : 'Version B (candidate)'

      <<~PROMPT
        ## Persona Assembly: Knowledge Version Comparison

        ### Task
        Compare two versions of knowledge. #{blind ? 'Labels are anonymized.' : ''}
        Evaluate which version better serves KairosChain L1 quality standards.

        ### Personas
        #{persona_names.each_with_index.map { |name, i|
          d = persona_defs[i]
          "- **#{name}** (#{d[:role]}): #{d[:focus]}"
        }.join("\n")}

        ### #{label_a}
        ```
        #{version_a_content}
        ```

        ### #{label_b}
        ```
        #{version_b_content}
        ```

        ### Comparison Dimensions
        #{EVALUATION_DIMENSIONS.map { |dim| "- **#{dim[:name]}**: #{dim[:question]}" }.join("\n")}

        ### Output Format
        Per persona:
        - **Preferred version**: A / B / Equivalent
        - **Key differences**: 2-3 specific observations with evidence
        - **Recommendation**: Specific action (keep A, adopt B, merge specific sections)

        #### Final Recommendation
        Majority vote with rationale.
      PROMPT
    end
  end
end
