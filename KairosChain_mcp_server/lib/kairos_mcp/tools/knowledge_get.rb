# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../knowledge_provider'

module KairosMcp
  module Tools
    class KnowledgeGet < BaseTool
      def name
        'knowledge_get'
      end

      def description
        'Get the content of a specific L1 knowledge skill by name. Includes frontmatter metadata and full content.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The knowledge skill name to retrieve'
            },
            include_scripts: {
              type: 'boolean',
              description: 'Include list of scripts (default: false)'
            },
            include_assets: {
              type: 'boolean',
              description: 'Include list of assets (default: false)'
            },
            include_references: {
              type: 'boolean',
              description: 'Include list of references (default: false)'
            }
          },
          required: ['name']
        }
      end

      def call(arguments)
        name = arguments['name']
        return text_content("Error: name is required") unless name && !name.empty?

        provider = KnowledgeProvider.new
        skill = provider.get(name)

        if skill.nil?
          available = provider.list.map { |s| s[:name] }.join(', ')
          return text_content("Knowledge '#{name}' not found. Available: #{available}")
        end

        output = build_output(skill, arguments, provider)
        text_content(output)
      end

      private

      def build_output(skill, arguments, provider)
        output = "## [#{skill.name}] #{skill.description || 'No description'}\n\n"
        output += "**Layer:** L1 (Knowledge)\n"
        output += "**Version:** #{skill.version || '-'}\n"
        output += "**Tags:** #{skill.tags&.join(', ') || '-'}\n"
        output += "\n---\n\n"
        output += skill.content
        output += "\n"

        if arguments['include_scripts'] && skill.has_scripts?
          output += "\n---\n\n### Scripts\n\n"
          provider.list_scripts(skill.name).each do |script|
            exec_flag = script[:executable] ? ' (executable)' : ''
            output += "- `#{script[:name]}`#{exec_flag}\n"
          end
        end

        if arguments['include_assets'] && skill.has_assets?
          output += "\n---\n\n### Assets\n\n"
          provider.list_assets(skill.name).each do |asset|
            output += "- `#{asset[:relative_path]}`\n"
          end
        end

        if arguments['include_references'] && skill.has_references?
          output += "\n---\n\n### References\n\n"
          provider.list_references(skill.name).each do |ref|
            output += "- `#{ref[:relative_path]}`\n"
          end
        end

        output
      end
    end
  end
end
