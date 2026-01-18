# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../context_manager'

module KairosMcp
  module Tools
    class ContextList < BaseTool
      def name
        'context_list'
      end

      def description
        'List all contexts in a specific L2 session. Contexts contain temporary hypotheses, scratch work, etc.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            session_id: {
              type: 'string',
              description: 'The session ID to list contexts from'
            }
          },
          required: ['session_id']
        }
      end

      def call(arguments)
        session_id = arguments['session_id']
        return text_content("Error: session_id is required") unless session_id && !session_id.empty?

        manager = ContextManager.new
        contexts = manager.list_contexts_in_session(session_id)

        if contexts.empty?
          return text_content("No contexts found in session '#{session_id}'. Use `context_save` to create one.")
        end

        output = "## Contexts in Session: #{session_id}\n\n"
        output += "| Name | Description | Scripts | Assets | Refs |\n"
        output += "|------|-------------|---------|--------|------|\n"

        contexts.each do |ctx|
          scripts = ctx[:has_scripts] ? '✓' : '-'
          assets = ctx[:has_assets] ? '✓' : '-'
          refs = ctx[:has_references] ? '✓' : '-'
          output += "| #{ctx[:name]} | #{ctx[:description] || '-'} | #{scripts} | #{assets} | #{refs} |\n"
        end

        output += "\nUse `context_get` with session_id and name to retrieve full content."
        text_content(output)
      end
    end
  end
end
