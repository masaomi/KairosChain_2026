require_relative 'base_tool'
require_relative '../dsl_skills_provider'

module KairosMcp
  module Tools
    class SkillsDslGet < BaseTool
      def name
        'skills_dsl_get'
      end

      def description
        'Get the detailed content and metadata of a specific DSL skill by ID.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            skill_id: {
              type: 'string',
              description: 'The skill ID to retrieve'
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

        if skill.nil?
          available = provider.list_skills.map { |s| s[:id] }.join(', ')
          return text_content("Skill '#{skill_id}' not found. Available: #{available}")
        end

        output = "## [#{skill.id}] #{skill.title}\n"
        output += "**Use When:** #{skill.use_when}\n" if skill.use_when
        output += "**Requires:** #{skill.requires}\n" if skill.requires
        output += "**Guarantees:** #{skill.guarantees}\n" if skill.guarantees
        output += "**Depends On:** #{skill.depends_on}\n" if skill.depends_on
        output += "\n---\n\n"
        output += skill.content || "(No content)"

        text_content(output)
      end
    end
  end
end
