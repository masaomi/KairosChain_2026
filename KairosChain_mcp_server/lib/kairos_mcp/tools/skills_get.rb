require_relative 'base_tool'
require_relative '../skills_parser'

module KairosMcp
  module Tools
    class SkillsGet < BaseTool
      def name
        'skills_get'
      end

      def description
        'Get the content of a specific KairosChain skills section by ID (Markdown).'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[get read L0 markdown skill section content]
      end

      def examples
        [
          {
            title: 'Get skill section',
            code: 'skills_get(section_id: "PHILOSOPHY-010")'
          }
        ]
      end

      def related_tools
        %w[skills_list skills_dsl_get resource_read]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            section_id: {
              type: 'string',
              description: 'The section ID to retrieve (e.g., "ARCH-010")'
            }
          },
          required: ['section_id']
        }
      end

      def call(arguments)
        section_id = arguments['section_id']

        unless section_id && !section_id.empty?
          return text_content("Error: section_id is required")
        end

        parser = SkillsParser.new
        section = parser.get_section(section_id.upcase)

        if section.nil?
          available = parser.list_sections.map { |s| s[:id] }.join(', ')
          return text_content("Section '#{section_id}' not found.\n\nAvailable sections: #{available}")
        end

        output = "## [#{section.id}] #{section.title}\n\n"
        output += section.content

        text_content(output)
      end
    end
  end
end
