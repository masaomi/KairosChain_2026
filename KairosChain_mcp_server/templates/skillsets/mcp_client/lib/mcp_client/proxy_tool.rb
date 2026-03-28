# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module McpClient
      class ProxyTool < KairosMcp::Tools::BaseTool
        attr_reader :remote_name, :server_id

        def initialize(safety, registry:, server_id:, remote_name:,
                       remote_description:, remote_schema:, connection_manager:)
          super(safety, registry: registry)
          @server_id = server_id
          @remote_name = remote_name
          @remote_description = remote_description
          @remote_schema = remote_schema
          @connection_manager = connection_manager
        end

        def name
          "#{@server_id}/#{@remote_name}"
        end

        def description
          "[Remote: #{@server_id}] #{@remote_description}"
        end

        def category
          :remote
        end

        def input_schema
          @remote_schema
        end

        def call(arguments)
          client = @connection_manager.client_for(@server_id)
          unless client&.connected?
            return text_content(JSON.generate({
              'status' => 'error',
              'error' => "Not connected to #{@server_id}. Use mcp_connect to reconnect."
            }))
          end

          result = client.call_tool(@remote_name, arguments)

          # MCP tools/call returns { content: [{ type: 'text', text: '...' }] }
          if result['content']
            result['content'].map { |c|
              { type: c['type'] || 'text', text: c['text'] || c.to_json }
            }
          else
            text_content(JSON.generate(result))
          end
        rescue RemoteToolError, StandardError => e
          text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
        end
      end
    end
  end
end
