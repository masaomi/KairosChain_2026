require_relative 'base_tool'
require_relative '../dsl_skills_provider'

module KairosMcp
  module Tools
    class DefinitionDecompile < BaseTool
      def name
        'definition_decompile'
      end

      def description
        'Decompile a skill\'s structural definition back to natural language. Shows what the AST nodes mean in human-readable form.'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[decompile definition AST natural-language reverse]
      end

      def examples
        [
          {
            title: 'Decompile evolution_rules definition',
            code: 'definition_decompile(skill_id: "evolution_rules")'
          }
        ]
      end

      def related_tools
        %w[definition_verify definition_drift skills_dsl_get]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            skill_id: {
              type: 'string',
              description: 'The skill ID to decompile'
            }
          },
          required: ['skill_id']
        }
      end

      def call(arguments)
        skill_id = arguments['skill_id']
        return text_content("Error: skill_id is required") unless skill_id && !skill_id.empty?

        provider = DslSkillsProvider.new
        skill = provider.get_skill(skill_id)

        unless skill
          available = provider.list_skills.map { |s| s[:id] }.join(', ')
          return text_content("Skill '#{skill_id}' not found. Available: #{available}")
        end

        unless skill.definition
          return text_content("## Decompile: #{skill_id}\n\nThis skill has no definition block to decompile.\nThe skill exists only as natural language content.")
        end

        require_relative '../dsl_ast/decompiler'
        markdown = DslAst::Decompiler.decompile(skill.definition)

        output = "## Decompile: #{skill_id}\n\n"
        output += "The following is a natural language reconstruction of the structural definition:\n\n"
        output += markdown

        text_content(output)
      end
    end
  end
end
