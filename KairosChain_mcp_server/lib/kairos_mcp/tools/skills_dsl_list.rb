require_relative 'base_tool'
require_relative '../dsl_skills_provider'

module KairosMcp
  module Tools
    class SkillsDslList < BaseTool
      def name
        'skills_dsl_list'
      end

      def description
        'List all available KairosChain skills defined in Ruby DSL. Returns ID, title, and usage hints.'
      end

      def input_schema
        {
          type: 'object',
          properties: {}
        }
      end

      def call(arguments)
        provider = DslSkillsProvider.new
        skills = provider.list_skills

        if skills.empty?
          return text_content("No DSL skills found. Check if skills/kairos.rb exists and has definitions.")
        end

        output = "Available KairosChain DSL Skills:\n\n"
        output += "| ID | Title | Use When |\n"
        output += "|-----|-------|----------|\n"

        skills.each do |skill|
          use_when = skill[:use_when] || '-'
          output += "| #{skill[:id]} | #{skill[:title]} | #{use_when} |\n"
        end

        output += "\nUse `skills_dsl_get` with a skill ID to retrieve full content."
        text_content(output)
      end
    end
  end
end
