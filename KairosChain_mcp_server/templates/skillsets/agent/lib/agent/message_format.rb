# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      # Canonical intermediate message format for the cognitive loop.
      # Adapters (Anthropic, OpenAI, Bedrock) convert from this format
      # to provider-native format in their convert_messages methods.
      module MessageFormat
        # Assistant message containing tool use requests.
        # Canonical: role 'assistant' with tool_calls array [{id, name, input}].
        def self.assistant_tool_use(tu)
          {
            'role' => 'assistant',
            'content' => nil,
            'tool_calls' => [{ 'id' => tu['id'], 'name' => tu['name'], 'input' => tu['input'] }]
          }
        end

        # Tool result message.
        # Canonical: role 'tool' with tool_use_id.
        def self.tool_result(tool_use_id, content)
          { 'role' => 'tool', 'tool_use_id' => tool_use_id, 'content' => content }
        end

        # Plain user message (for repair loop feedback, etc.)
        def self.user_message(text)
          { 'role' => 'user', 'content' => text }
        end
      end
    end
  end
end
