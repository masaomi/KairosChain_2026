require_relative 'base_tool'
require_relative '../kairos_chain/chain'
require_relative '../kairos_chain/formalization_decision'

module KairosMcp
  module Tools
    class FormalizationRecord < BaseTool
      def name
        'formalization_record'
      end

      def description
        'Record a formalization decision to the blockchain. Documents why a piece of natural language was (or was not) converted to a formal AST node.'
      end

      def category
        :chain
      end

      def usecase_tags
        %w[formalization record decision DSL AST blockchain provenance]
      end

      def examples
        [
          {
            title: 'Record a formalization decision',
            code: 'formalization_record(skill_id: "core_safety", skill_version: "1.1", source_text: "Evolution is disabled by default", result: "formalized", rationale: "Binary condition, measurable", formalization_category: "invariant")'
          }
        ]
      end

      def related_tools
        %w[formalization_history skills_dsl_get chain_history]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            skill_id: {
              type: 'string',
              description: 'The skill ID this decision applies to'
            },
            skill_version: {
              type: 'string',
              description: 'The skill version at the time of this decision'
            },
            source_text: {
              type: 'string',
              description: 'The natural language text being evaluated for formalization'
            },
            result: {
              type: 'string',
              description: 'Whether the text was formalized: "formalized" or "not_formalized"'
            },
            rationale: {
              type: 'string',
              description: 'Why this formalization decision was made'
            },
            formalization_category: {
              type: 'string',
              description: 'Category on the formalization spectrum: invariant, rule, guideline, policy, or philosophy'
            },
            source_span: {
              type: 'string',
              description: 'The original text span in the content (optional)'
            },
            ambiguity_before: {
              type: 'string',
              description: 'Ambiguity level before formalization: none, low, medium, high (optional)'
            },
            ambiguity_after: {
              type: 'string',
              description: 'Ambiguity level after formalization: none, low, medium, high (optional)'
            },
            decided_by: {
              type: 'string',
              description: 'Who made the decision: human, ai, or collaborative (default: human)'
            },
            model: {
              type: 'string',
              description: 'LLM model used if AI-assisted (optional)'
            },
            confidence: {
              type: 'number',
              description: 'Confidence score 0.0-1.0 (optional)'
            }
          },
          required: %w[skill_id skill_version source_text result rationale formalization_category]
        }
      end

      def call(arguments)
        # Validate required fields
        %w[skill_id skill_version source_text result rationale formalization_category].each do |field|
          unless arguments[field] && !arguments[field].to_s.empty?
            return text_content("Error: #{field} is required")
          end
        end

        # Validate result value
        unless %w[formalized not_formalized].include?(arguments['result'])
          return text_content("Error: result must be 'formalized' or 'not_formalized'")
        end

        # Validate formalization_category
        valid_categories = %w[invariant rule guideline policy philosophy]
        unless valid_categories.include?(arguments['formalization_category'])
          return text_content("Error: formalization_category must be one of: #{valid_categories.join(', ')}")
        end

        # Build the decision
        decision = KairosChain::FormalizationDecision.new(
          skill_id: arguments['skill_id'],
          skill_version: arguments['skill_version'],
          source_text: arguments['source_text'],
          source_span: arguments['source_span'],
          result: arguments['result'].to_sym,
          rationale: arguments['rationale'],
          formalization_category: arguments['formalization_category'].to_sym,
          ambiguity_before: arguments['ambiguity_before']&.to_sym,
          ambiguity_after: arguments['ambiguity_after']&.to_sym,
          decided_by: (arguments['decided_by'] || 'human').to_sym,
          model: arguments['model'],
          confidence: arguments['confidence']&.to_f
        )

        # Record to blockchain
        chain = KairosChain::Chain.new
        new_block = chain.add_block([decision.to_json])

        output = "## Formalization Decision Recorded\n\n"
        output += "**Block**: ##{new_block.index}\n"
        output += "**Hash**: #{new_block.hash[0..15]}...\n"
        output += "**Skill**: #{arguments['skill_id']} v#{arguments['skill_version']}\n"
        output += "**Result**: #{arguments['result']}\n"
        output += "**Category**: #{arguments['formalization_category']}\n"
        output += "**Rationale**: #{arguments['rationale']}\n"

        text_content(output)
      end
    end
  end
end
