require_relative 'base_tool'
require_relative '../skills_parser'

module KairosMcp
  module Tools
    class SkillsList < BaseTool
      def name
        'skills_list'
      end

      def description
        'List all available KairosChain skills sections (Markdown).'
      end

      def input_schema
        {
          type: 'object',
          properties: {}
        }
      end

      def call(arguments)
        parser = SkillsParser.new
        sections = parser.list_sections

        if sections.empty?
          return text_content("No skills sections found. Check if skills/kairos.md exists.")
        end

        output = "Available KairosChain Skills Sections:\n\n"
        output += "| ID | Title | Use When |\n"
        output += "|-----|-------|----------|\n"

        sections.each do |section|
          use_when = section[:use_when] || '-'
          output += "| #{section[:id]} | #{section[:title]} | #{use_when} |\n"
        end

        output += "\nUse `skills_get` with a section ID to retrieve full content."
        text_content(output)
      end
    end
  end
end
