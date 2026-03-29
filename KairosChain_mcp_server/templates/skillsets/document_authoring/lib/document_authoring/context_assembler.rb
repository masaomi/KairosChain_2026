# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module DocumentAuthoring
      # Retrieves L1/L2 context via resource_read and assembles into prompt text.
      # Uses the platform URI scheme (knowledge://, context://).
      class ContextAssembler
        # @param caller_tool [BaseTool] tool instance with invoke_tool access
        # @param max_chars_per_source [Integer] max characters per source
        # @param max_total_chars [Integer] total context budget
        # @param max_sources [Integer] max number of sources
        def initialize(caller_tool, max_chars_per_source: 4000,
                       max_total_chars: 16_000, max_sources: 10)
          @caller = caller_tool
          @max_chars_per_source = max_chars_per_source
          @max_total_chars = max_total_chars
          @max_sources = max_sources
        end

        # Assemble context from resource URIs.
        # @param sources [Array<String>] resource URIs (knowledge://, context://)
        # @param context [Object, nil] InvocationContext for policy inheritance
        # @return [Hash] { text: String, loaded: Integer, failed: Integer, warnings: Array<String> }
        def assemble(sources, context: nil)
          return { text: '', loaded: 0, failed: 0, warnings: [] } if sources.nil? || sources.empty?

          warnings = []
          texts = []
          loaded = 0
          failed = 0
          total_chars = 0

          if sources.size > @max_sources
            warnings << "Truncated to #{@max_sources} sources (#{sources.size} provided)"
          end

          sources.first(@max_sources).each do |uri|
            unless uri.match?(%r{\A(knowledge|context)://})
              warnings << "Unknown URI scheme, skipped: #{uri}"
              failed += 1
              next
            end

            begin
              result = @caller.invoke_tool('resource_read', { 'uri' => uri }, context: context)
              text = extract_text(result)

              if text.nil? || text.strip.empty?
                warnings << "Empty content from: #{uri}"
                failed += 1
                next
              end

              truncated = truncate_at_paragraph(text, @max_chars_per_source)
              remaining = @max_total_chars - total_chars
              truncated = truncated[0...remaining] if truncated.length > remaining

              texts << "### Source: #{uri}\n#{truncated}"
              total_chars += truncated.length
              loaded += 1
            rescue StandardError => e
              warnings << "Failed to load #{uri}: #{e.message}"
              failed += 1
            end

            break if total_chars >= @max_total_chars
          end

          { text: texts.join("\n\n"), loaded: loaded, failed: failed, warnings: warnings }
        end

        private

        def extract_text(result)
          return '' unless result.is_a?(Array)

          result.map { |b| b[:text] || b['text'] }.compact.join("\n")
        end

        def truncate_at_paragraph(text, max_chars)
          return text if text.length <= max_chars

          # Find last paragraph break (double newline) before max_chars
          cut = text.rindex("\n\n", max_chars)
          cut && cut > 0 ? text[0..cut] : text[0...max_chars]
        end
      end
    end
  end
end
