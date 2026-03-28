# frozen_string_literal: true

require 'json'
require_relative '../lib/mcp_client'

module KairosMcp
  module SkillSets
    module McpClient
      module Tools
        class McpListRemote < KairosMcp::Tools::BaseTool
          def name
            'mcp_list_remote'
          end

          def description
            'List connected remote MCP servers and their available tools.'
          end

          def category
            :remote
          end

          def input_schema
            { type: 'object', properties: {} }
          end

          def call(arguments)
            conn_mgr = ConnectionManager.instance
            connections = conn_mgr.all_connections

            text_content(JSON.generate({
              'status' => 'ok',
              'connections' => connections.values.map { |c|
                { server_id: c[:server_id], url: c[:url], status: c[:status],
                  tool_count: c[:tools].length,
                  tools: c[:tools].map { |t|
                    { name: "#{c[:server_id]}/#{t['name']}",
                      description: t['description'] || '' }
                  } }
              },
              'total_remote_tools' => conn_mgr.all_remote_tools.length
            }))
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
          end
        end
      end
    end
  end
end
