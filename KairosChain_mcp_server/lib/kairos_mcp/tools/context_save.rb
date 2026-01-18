# frozen_string_literal: true

require 'securerandom'
require_relative 'base_tool'
require_relative '../context_manager'

module KairosMcp
  module Tools
    class ContextSave < BaseTool
      def name
        'context_save'
      end

      def description
        'Save (create or update) a L2 context. No blockchain recording - free modification for temporary work.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            session_id: {
              type: 'string',
              description: 'The session ID (will be auto-generated if not provided for new sessions)'
            },
            name: {
              type: 'string',
              description: 'Context name'
            },
            content: {
              type: 'string',
              description: 'Full content including YAML frontmatter'
            },
            create_subdirs: {
              type: 'boolean',
              description: 'Create scripts/assets/references subdirectories (default: false)'
            }
          },
          required: %w[name content]
        }
      end

      def call(arguments)
        name = arguments['name']
        content = arguments['content']
        session_id = arguments['session_id']
        create_subdirs = arguments['create_subdirs'] || false

        return text_content("Error: name is required") unless name && !name.empty?
        return text_content("Error: content is required") unless content && !content.empty?

        manager = ContextManager.new

        # Generate session_id if not provided
        if session_id.nil? || session_id.empty?
          session_id = manager.generate_session_id
        end

        result = manager.save_context(session_id, name, content, create_subdirs: create_subdirs)

        if result[:success]
          output = "SUCCESS: Context #{result[:action]}\n\n"
          output += "**Session:** #{session_id}\n"
          output += "**Name:** #{name}\n"
          output += "\nNo blockchain recording (L2 is free modification)."
          text_content(output)
        else
          text_content("FAILED: #{result[:error]}")
        end
      end
    end
  end
end
