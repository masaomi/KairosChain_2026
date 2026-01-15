require 'json'
require_relative 'tool_registry'
require_relative 'version'

module KairosMcp
  class Protocol
    PROTOCOL_VERSION = '2024-11-05'

    def initialize
      @tool_registry = ToolRegistry.new
      @initialized = false
    end

    def handle_message(line)
      request = parse_json(line)
      return nil unless request

      id = request['id']
      method = request['method']
      params = request['params'] || {}

      result = case method
               when 'initialize'
                 handle_initialize(params)
               when 'initialized'
                 return nil
               when 'tools/list'
                 handle_tools_list
               when 'tools/call'
                 handle_tools_call(params)
               else
                 return nil
               end

      format_response(id, result)
    rescue StandardError => e
      format_error(id, -32603, "Internal error: #{e.message}")
    end

    private

    def parse_json(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def handle_initialize(params)
      roots = params['roots'] || params['workspaceFolders']
      @tool_registry.set_workspace(roots)
      @initialized = true

      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {
          tools: {}
        },
        serverInfo: {
          name: 'kairos-mcp-server',
          version: KairosMcp::VERSION
        }
      }
    end

    def handle_tools_list
      {
        tools: @tool_registry.list_tools
      }
    end

    def handle_tools_call(params)
      name = params['name']
      arguments = params['arguments'] || {}
      
      content = @tool_registry.call_tool(name, arguments)
      
      {
        content: content
      }
    end

    def format_response(id, result)
      {
        jsonrpc: '2.0',
        id: id,
        result: result
      }
    end

    def format_error(id, code, message)
      {
        jsonrpc: '2.0',
        id: id,
        error: {
          code: code,
          message: message
        }
      }
    end
  end
end
