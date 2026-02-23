require 'json'
require_relative 'tool_registry'
require_relative 'skills_config'
require_relative 'version'

module KairosMcp
  class Protocol
    # Protocol versions
    STDIO_PROTOCOL_VERSION = '2024-11-05'
    HTTP_PROTOCOL_VERSION = '2025-03-26'

    # @param user_context [Hash, nil] Authenticated user info from HTTP mode
    #   { user: "name", role: "owner"|"member"|"guest", ... }
    def initialize(user_context: nil)
      @user_context = user_context
      @tool_registry = ToolRegistry.new(user_context: user_context)
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

    def protocol_version
      @user_context ? HTTP_PROTOCOL_VERSION : STDIO_PROTOCOL_VERSION
    end

    def handle_initialize(params)
      roots = params['roots'] || params['workspaceFolders']
      @tool_registry.set_workspace(roots)
      @initialized = true

      result = {
        protocolVersion: protocol_version,
        capabilities: {
          tools: {
            # Phase 2: Set to true when notifications/tools/list_changed is implemented
            listChanged: false
          }
        },
        serverInfo: {
          name: 'kairos-chain',
          version: KairosMcp::VERSION
        }
      }

      # Add instructions based on config mode (developer/user/none)
      instructions = load_instructions
      result[:instructions] = instructions if instructions

      result
    end

    # Load instructions based on instructions_mode in config.yml
    #
    # @return [String, nil] Instructions text or nil
    def load_instructions
      mode = SkillsConfig.load['instructions_mode'] || 'user'

      path = case mode
             when 'developer'
               KairosMcp.md_path           # Full philosophy (kairos.md)
             when 'user'
               KairosMcp.quickguide_path   # Quick guide (kairos_quickguide.md)
             when 'none'
               nil
             else
               # Dynamic custom mode: resolve to skills/{mode}.md
               File.join(KairosMcp.skills_dir, "#{mode}.md")
             end

      return nil unless path

      read_if_exists(path)
    end

    # Read file content if it exists
    #
    # @param path [String] File path
    # @return [String, nil] File content or nil
    def read_if_exists(path)
      File.exist?(path) ? File.read(path) : nil
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
