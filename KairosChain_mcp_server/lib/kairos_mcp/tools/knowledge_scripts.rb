# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../knowledge_provider'

module KairosMcp
  module Tools
    class KnowledgeScripts < BaseTool
      def name
        'knowledge_scripts'
      end

      def description
        'List all scripts in a L1 knowledge skill. Scripts can be Python, Bash, Node, or other executable files.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The knowledge skill name'
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
          return text_content("Knowledge '#{name}' not found")
        end

        scripts = provider.list_scripts(name)

        if scripts.empty?
          return text_content("No scripts found in '#{name}'. Scripts directory: #{skill.scripts_path}")
        end

        output = "## Scripts in '#{name}'\n\n"
        output += "| Name | Executable | Size |\n"
        output += "|------|------------|------|\n"

        scripts.each do |script|
          exec_flag = script[:executable] ? '✓' : '-'
          size = format_size(script[:size])
          output += "| #{script[:name]} | #{exec_flag} | #{size} |\n"
        end

        output += "\n**Scripts path:** `#{skill.scripts_path}`"
        text_content(output)
      end

      private

      def format_size(bytes)
        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)} KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(1)} MB"
        end
      end
    end
  end
end
