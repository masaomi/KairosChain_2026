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

      def to_schema
        {
          name: name,
          description: description,
          inputSchema: input_schema
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
