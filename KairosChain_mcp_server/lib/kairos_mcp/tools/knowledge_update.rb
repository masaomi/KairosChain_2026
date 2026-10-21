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
        'Create, update, delete, or restore L1 knowledge skills; list the recorded history of an entry; ' \
        'or erase a stored body (irreversible, needs approved: true). ' \
        'Changes are recorded with hash references to the blockchain. ' \
        'Large content is supported (a ~40 KB update was verified over stdio on 2026-06-10; the earlier ~2 KB guidance ' \
        'generalized a single unreproduced nil-content incident). If content ever arrives as nil, the error message ' \
        'below explains recovery; no preemptive size limit applies.'
      end

      def category
        :knowledge
      end

      def usecase_tags
        %w[save update delete L1 knowledge project permanent]
      end

      def examples
        [
          {
            title: 'Create new knowledge',
            code: 'knowledge_update(command: "create", name: "api_guidelines", content: "---\nname: api_guidelines\ndescription: API design rules\n---\n# API Guidelines\n...")'
          },
          {
            title: 'Update existing knowledge',
            code: 'knowledge_update(command: "update", name: "api_guidelines", content: "...", reason: "Added auth section")'
          },
          {
            title: 'Delete knowledge',
            code: 'knowledge_update(command: "delete", name: "old_rule", reason: "No longer applicable")'
          }
        ]
      end

      def related_tools
        %w[knowledge_list knowledge_get context_save skills_promote]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "create", "update", "delete", "history", "restore", or "erase_body"',
              enum: %w[create update delete history restore erase_body]
            },
            content_hash: {
              type: 'string',
              description: 'Body content hash. Required for "restore" and "erase_body"'
            },
            approved: {
              type: 'boolean',
              description: 'Human approval. "erase_body" is irreversible and requires true'
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

        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)

        case command
        when 'create'
          handle_create(provider, name, content, reason, create_subdirs)
        when 'update'
          handle_update(provider, name, content, reason)
        when 'delete'
          handle_delete(provider, name, reason)
        when 'history'
          rows = provider.history(name)
          lines = rows.map do |row|
            parts = ["#{row[:index]}. #{row[:next_hash].to_s[0, 12]}",
                     row[:action].to_s,
                     "retrievable: #{row[:retrievable] ? 'yes' : 'no'}"]
            # A body recorded before the store was active cannot be fetched back,
            # only proved by its hash.
            parts << 'provable by hash only' unless row[:recorded_while_active]
            parts.join(' | ')
          end
          text = lines.empty? ? "No recorded history for '#{name}'" : "History for '#{name}':\n#{lines.join("\n")}"
          [{ type: 'text', text: text }]
        when 'restore'
          result = provider.restore(name, arguments['content_hash'], reason: reason)
          format_result(result, 'restored')
        when 'erase_body'
          # Irreversible: the body leaves the store for good, so demand the flag.
          unless arguments['approved'] == true
            return [{ type: 'text', text: 'erase_body requires approved: true (irreversible)' }]
          end

          result = provider.erase_body(name, arguments['content_hash'], reason: reason)
          format_result(result, 'body erased')
        else
          text_content("Unknown command: #{command}")
        end
      end

      private

      def handle_create(provider, name, content, reason, create_subdirs)
        return text_content(content_missing_error("create", content)) unless content && !content.empty?

        result = provider.create(name, content, reason: reason, create_subdirs: create_subdirs)
        format_result(result, 'created')
      end

      def handle_update(provider, name, content, reason)
        return text_content(content_missing_error("update", content)) unless content && !content.empty?

        result = provider.update(name, content, reason: reason)
        format_result(result, 'updated')
      end

      def handle_delete(provider, name, reason)
        result = provider.delete(name, reason: reason)
        format_result(result, 'deleted')
      end

      def content_missing_error(command, content)
        if content.nil?
          "Error: content is required for #{command}. " \
          "The content argument arrived as nil — the MCP transport or the calling LLM dropped it. " \
          "(A ~2 KB stdio limit was once suspected, but a ~40 KB update succeeded on 2026-06-10, " \
          "so size alone is unlikely to be the cause.) " \
          "Retry the call; if nil persists, write the content to a file and report the incident."
        else
          "Error: content is required for #{command} (received empty string)"
        end
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
