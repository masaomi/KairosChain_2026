require_relative 'base_tool'

module KairosMcp
  module Tools
    class HelloWorld < BaseTool
      def name
        'hello_world'
      end

      def description
        'Returns a hello message from KairosChain MCP Server'
      end

      def category
        :guide
      end

      def usecase_tags
        %w[hello test greeting verify connection]
      end

      def examples
        [
          {
            title: 'Simple greeting',
            code: 'hello_world()'
          },
          {
            title: 'Personalized greeting',
            code: 'hello_world(name: "Kairos")'
          }
        ]
      end

      def related_tools
        %w[tool_guide chain_status]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'Name to greet (optional)'
            }
          }
        }
      end

      def call(arguments)
        name = arguments['name'] || 'World'
        text_content("Hello, #{name}! This is KairosChain MCP Server.")
      end
    end
  end
end
