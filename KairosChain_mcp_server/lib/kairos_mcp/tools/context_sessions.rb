# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../context_manager'

module KairosMcp
  module Tools
    class ContextSessions < BaseTool
      def name
        'context_sessions'
      end

      def description
        'List all active L2 context sessions. Sessions organize temporary contexts and hypotheses.'
      end

      def input_schema
        {
          type: 'object',
          properties: {}
        }
      end

      def call(_arguments)
        manager = ContextManager.new
        sessions = manager.list_sessions

        if sessions.empty?
          return text_content("No active sessions found. Use `context_save` to create a new session.")
        end

        output = "## L2 Context Sessions\n\n"
        output += "| Session ID | Contexts | Created | Modified |\n"
        output += "|------------|----------|---------|----------|\n"

        sessions.each do |session|
          created = session[:created_at].strftime('%Y-%m-%d %H:%M')
          modified = session[:modified_at].strftime('%Y-%m-%d %H:%M')
          output += "| #{session[:session_id]} | #{session[:context_count]} | #{created} | #{modified} |\n"
        end

        output += "\nUse `context_list` with a session_id to see contexts in a session."
        text_content(output)
      end
    end
  end
end
