require_relative 'base_tool'
require_relative '../dsl_skills_provider'

module KairosMcp
  module Tools
    class SkillsDslList < BaseTool
      def name
        'skills_dsl_list'
      end

      def description
        'List all available KairosChain skills defined in Ruby DSL. Returns ID, title, and usage hints. Supports optional search query.'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[list search L0 DSL skills browse discover]
      end

      def examples
        [
          {
            title: 'List all DSL skills',
            code: 'skills_dsl_list()'
          },
          {
            title: 'Search DSL skills',
            code: 'skills_dsl_list(search: "safety")'
          }
        ]
      end

      def related_tools
        %w[skills_dsl_get skills_evolve skills_list]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            search: {
              type: 'string',
              description: 'Optional search query to filter results (uses semantic search if available)'
            }
          }
        }
      end

      def call(arguments)
        provider = DslSkillsProvider.new
        search_query = arguments['search']

        skills = if search_query && !search_query.empty?
                   provider.search_skills(search_query).map do |skill|
                     { id: skill.id, title: skill.title, use_when: skill.use_when }
                   end
                 else
                   provider.list_skills
                 end

        if skills.empty?
          return text_content("No DSL skills found.#{search_query ? " (search: #{search_query})" : ''}")
        end

        output = "Available KairosChain DSL Skills:\n\n"

        # Show search metadata if searching
        if search_query && !search_query.empty?
          vs_status = provider.vector_search_status
          search_method = vs_status[:semantic_available] ? 'semantic (RAG)' : 'keyword'
          output += "_Search: \"#{search_query}\" | Method: #{search_method}_\n\n"
        end

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
