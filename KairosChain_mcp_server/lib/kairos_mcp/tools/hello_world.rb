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
