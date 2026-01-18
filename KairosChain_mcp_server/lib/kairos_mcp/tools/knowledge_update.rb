# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../knowledge_provider'
require_relative '../skills_config'

module KairosMcp
  module Tools
    class KnowledgeUpdate < BaseTool
      def name
        'knowledge_update'
      end

      def description
        'Create, update, or delete L1 knowledge skills. Changes are recorded with hash references to the blockchain.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "create", "update", or "delete"',
              enum: %w[create update delete]
            },
            name: {
              type: 'string',
              description: 'Knowledge skill name'
            },
            content: {
              type: 'string',
              description: 'Full content including YAML frontmatter (for create/update)'
            },
            reason: {
              type: 'string',
              description: 'Reason for the change (recorded in blockchain)'
            },
            create_subdirs: {
              type: 'boolean',
              description: 'Create scripts/assets/references subdirectories (for create, default: false)'
            }
          },
          required: %w[command name]
        }
      end

      def call(arguments)
        command = arguments['command']
        name = arguments['name']
        content = arguments['content']
        reason = arguments['reason']
        create_subdirs = arguments['create_subdirs'] || false

        return text_content("Error: name is required") unless name && !name.empty?

        # Check if L1 layer is enabled
        unless SkillsConfig.layer_enabled?(:L1)
          return text_content("Error: L1 (knowledge) layer is disabled")
        end

        provider = KnowledgeProvider.new

        case command
        when 'create'
          handle_create(provider, name, content, reason, create_subdirs)
        when 'update'
          handle_update(provider, name, content, reason)
        when 'delete'
          handle_delete(provider, name, reason)
        else
          text_content("Unknown command: #{command}")
        end
      end

      private

      def handle_create(provider, name, content, reason, create_subdirs)
        return text_content("Error: content is required for create") unless content && !content.empty?

        result = provider.create(name, content, reason: reason, create_subdirs: create_subdirs)
        format_result(result, 'created')
      end

      def handle_update(provider, name, content, reason)
        return text_content("Error: content is required for update") unless content && !content.empty?

        result = provider.update(name, content, reason: reason)
        format_result(result, 'updated')
      end

      def handle_delete(provider, name, reason)
        result = provider.delete(name, reason: reason)
        format_result(result, 'deleted')
      end

      def format_result(result, action)
        if result[:success]
          output = "SUCCESS: Knowledge #{action}\n\n"
          output += "**Hash:** #{result[:next_hash] || result[:prev_hash]}\n" if result[:next_hash] || result[:prev_hash]
          output += "**Prev Hash:** #{result[:prev_hash]}\n" if result[:prev_hash] && result[:next_hash]
          output += "\nChange recorded to blockchain (hash reference only)."
          text_content(output)
        else
          text_content("FAILED: #{result[:error]}")
        end
      end
    end
  end
end
