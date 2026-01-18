# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../context_manager'

module KairosMcp
  module Tools
    class ContextCreateSubdir < BaseTool
      def name
        'context_create_subdir'
      end

      def description
        'Create a subdirectory (scripts, assets, or references) in a L2 context.'
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
              description: 'The context name'
            },
            subdir: {
              type: 'string',
              description: 'Subdirectory to create: "scripts", "assets", or "references"',
              enum: %w[scripts assets references]
            }
          },
          required: %w[session_id name subdir]
        }
      end

      def call(arguments)
        session_id = arguments['session_id']
        name = arguments['name']
        subdir = arguments['subdir']

        return text_content("Error: session_id is required") unless session_id && !session_id.empty?
        return text_content("Error: name is required") unless name && !name.empty?
        return text_content("Error: subdir is required") unless subdir && !subdir.empty?

        manager = ContextManager.new
        result = manager.create_subdir(session_id, name, subdir)

        if result[:success]
          text_content("SUCCESS: Created subdirectory\n\n**Path:** `#{result[:path]}`")
        else
          text_content("FAILED: #{result[:error]}")
        end
      end
    end
  end
end
