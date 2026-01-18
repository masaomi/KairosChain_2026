# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../context_manager'

module KairosMcp
  module Tools
    class ContextGet < BaseTool
      def name
        'context_get'
      end

      def description
        'Get the content of a specific L2 context. Includes frontmatter metadata and full content.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            session_id: {
              type: 'string',
              description: 'The session ID'
            },
            name: {
              type: 'string',
              description: 'The context name to retrieve'
            },
            include_scripts: {
              type: 'boolean',
              description: 'Include list of scripts (default: false)'
            },
            include_assets: {
              type: 'boolean',
              description: 'Include list of assets (default: false)'
            }
          },
          required: %w[session_id name]
        }
      end

      def call(arguments)
        session_id = arguments['session_id']
        name = arguments['name']

        return text_content("Error: session_id is required") unless session_id && !session_id.empty?
        return text_content("Error: name is required") unless name && !name.empty?

        manager = ContextManager.new
        context = manager.get_context(session_id, name)

        if context.nil?
          return text_content("Context '#{name}' not found in session '#{session_id}'")
        end

        output = build_output(context, arguments, manager, session_id)
        text_content(output)
      end

      private

      def build_output(context, arguments, manager, session_id)
        output = "## [#{context.name}] #{context.description || 'No description'}\n\n"
        output += "**Layer:** L2 (Context)\n"
        output += "**Session:** #{session_id}\n"
        output += "\n---\n\n"
        output += context.content
        output += "\n"

        if arguments['include_scripts'] && context.has_scripts?
          output += "\n---\n\n### Scripts\n\n"
          manager.list_scripts(session_id, context.name).each do |script|
            exec_flag = script[:executable] ? ' (executable)' : ''
            output += "- `#{script[:name]}`#{exec_flag}\n"
          end
        end

        if arguments['include_assets'] && context.has_assets?
          output += "\n---\n\n### Assets\n\n"
          manager.list_assets(session_id, context.name).each do |asset|
            output += "- `#{asset[:relative_path]}`\n"
          end
        end

        output
      end
    end
  end
end
