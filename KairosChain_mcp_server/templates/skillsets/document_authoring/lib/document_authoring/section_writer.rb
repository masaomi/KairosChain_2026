# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module DocumentAuthoring
      # Core write logic: builds LLM prompt, calls llm_call, writes output file.
      class SectionWriter
        def initialize(caller_tool, config)
          @caller = caller_tool
          @config = config
        end

        # Write a document section via LLM.
        # @return [Hash] result with 'status'/'error', 'word_count', etc.
        def write(section_name:, instructions:, context_text:, output_file:,
                  max_words: 500, language: 'en', append_mode: false,
                  invocation_context: nil)
          messages = [{
            'role' => 'user',
            'content' => build_user_prompt(section_name, instructions, context_text, max_words, language)
          }]

          llm_args = {
            'messages' => messages,
            'system' => system_prompt
          }

          # Forward InvocationContext via dispatch-level context: keyword only
          # (not duplicated in arguments — llm_call uses dispatch context)
          result = @caller.invoke_tool('llm_call', llm_args, context: invocation_context)

          # Parse pinned response contract:
          # { "status": "ok", "response": { "content": "..." }, "snapshot": {...} }
          # { "status": "error", "error": { "type": "...", "message": "..." } }
          raw = result.map { |b| b[:text] || b['text'] }.compact.join
          parsed = JSON.parse(raw)

          if parsed['status'] == 'error'
            error = parsed['error'] || {}
            error_msg = if error.is_a?(Hash)
                          "#{error['type']}: #{error['message']}"
                        else
                          error.to_s
                        end
            return { 'error' => "LLM call failed: #{error_msg}" }
          end

          generated_text = parsed.dig('response', 'content')
          if generated_text.nil? || generated_text.strip.empty?
            return { 'error' => 'LLM returned empty content' }
          end

          # Write to file
          if append_mode
            File.open(output_file, 'a') { |f| f.write("\n\n#{generated_text}") }
          else
            File.write(output_file, generated_text)
          end

          {
            'status' => 'ok',
            'section_name' => section_name,
            'output_file' => output_file,
            'word_count' => generated_text.split.size
          }
        rescue JSON::ParserError => e
          { 'error' => "Failed to parse LLM response: #{e.message}" }
        end

        private

        def system_prompt
          "You are a professional document writer. Write the requested section " \
            "following the instructions precisely. Use the provided context for accuracy. " \
            "Output ONLY the section content. You may use markdown formatting within the section."
        end

        def build_user_prompt(section_name, instructions, context_text, max_words, language)
          parts = [
            "## Section: #{section_name}",
            "## Instructions\n#{instructions}",
            "## Word limit: approximately #{max_words} words",
            "## Language: #{language}"
          ]
          parts << "## Reference Context\n#{context_text}" if context_text && !context_text.empty?
          parts << "\nWrite the section now."
          parts.join("\n\n")
        end
      end
    end
  end
end
