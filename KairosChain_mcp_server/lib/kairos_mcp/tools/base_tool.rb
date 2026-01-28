module KairosMcp
  module Tools
    class BaseTool
      def initialize(safety = nil)
        @safety = safety
      end

      def name
        raise NotImplementedError
      end

      def description
        raise NotImplementedError
      end

      def input_schema
        raise NotImplementedError
      end

      def call(arguments)
        raise NotImplementedError
      end

      # Metadata methods for tool discovery and guidance
      # Override in subclasses to provide tool-specific metadata

      # Category for grouping tools in catalog
      # @return [Symbol] one of :chain, :knowledge, :context, :skills, :resource, :state, :guide, :utility
      def category
        :utility
      end

      # Tags for keyword-based search and recommendations
      # @return [Array<String>] list of usecase tags (e.g., ["save", "update", "L1"])
      def usecase_tags
        []
      end

      # Usage examples for this tool
      # @return [Array<Hash>] list of examples with :title and :code keys
      def examples
        []
      end

      # Related tools that are often used together
      # @return [Array<String>] list of tool names
      def related_tools
        []
      end

      # Schema for MCP protocol
      def to_schema
        {
          name: name,
          description: description,
          inputSchema: input_schema
        }
      end

      # Extended schema including metadata (for internal use)
      def to_full_schema
        {
          name: name,
          description: description,
          inputSchema: input_schema,
          _metadata: {
            category: category,
            usecase_tags: usecase_tags,
            examples: examples,
            related_tools: related_tools
          }
        }
      end

      protected

      def text_content(text)
        [
          {
            type: 'text',
            text: text
          }
        ]
      end
    end
  end
end
