# frozen_string_literal: true

require 'json'
require_relative '../lib/mcp_client'

module KairosMcp
  module SkillSets
    module McpClient
      module Tools
        class McpDisconnect < KairosMcp::Tools::BaseTool
          def name
            'mcp_disconnect'
          end

          def description
            'Disconnect from a remote MCP server and unregister its proxy tools.'
          end

          def category
            :remote
          end

          def input_schema
            {
              type: 'object',
              properties: {
                server_id: { type: 'string', description: 'Server alias to disconnect' }
              },
              required: %w[server_id]
            }
          end

          def call(arguments)
            server_id = arguments['server_id']
            conn_mgr = ConnectionManager.instance
            conn = conn_mgr.all_connections[server_id]
            unless conn
              return text_content(JSON.generate({
                'status' => 'error', 'error' => "Not connected to #{server_id}"
              }))
            end

            # Unregister proxy tools
            conn[:tools].each { |rt| @registry.unregister_tool("#{server_id}/#{rt['name']}") }
            conn_mgr.disconnect(server_id)

            text_content(JSON.generate({ 'status' => 'ok', 'server_id' => server_id }))
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
          end
        end
      end
    end
  end
end
