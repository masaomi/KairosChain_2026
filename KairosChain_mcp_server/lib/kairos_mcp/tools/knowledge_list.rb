# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../knowledge_provider'

module KairosMcp
  module Tools
    class KnowledgeList < BaseTool
      def name
        'knowledge_list'
      end

      def description
        'List all available L1 knowledge skills (Anthropic format). Returns name, description, tags, and subdirectory info.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            search: {
              type: 'string',
              description: 'Optional search query to filter results'
            }
          }
        }
      end

      def call(arguments)
        provider = KnowledgeProvider.new
        search_query = arguments['search']

        skills = if search_query && !search_query.empty?
                   provider.search(search_query)
                 else
                   provider.list
                 end

        if skills.empty?
          return text_content("No knowledge skills found.#{search_query ? " (search: #{search_query})" : ''}")
        end

        output = "## L1 Knowledge Skills\n\n"
        output += "| Name | Description | Tags | Scripts | Assets | Refs |\n"
        output += "|------|-------------|------|---------|--------|------|\n"

        skills.each do |skill|
          tags = skill[:tags]&.join(', ') || '-'
          scripts = skill[:has_scripts] ? '✓' : '-'
          assets = skill[:has_assets] ? '✓' : '-'
          refs = skill[:has_references] ? '✓' : '-'
          output += "| #{skill[:name]} | #{skill[:description] || '-'} | #{tags} | #{scripts} | #{assets} | #{refs} |\n"
        end

        output += "\nUse `knowledge_get` with a skill name to retrieve full content."
        text_content(output)
      end
    end
  end
end
