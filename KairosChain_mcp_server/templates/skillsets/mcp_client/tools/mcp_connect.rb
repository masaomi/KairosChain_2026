# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative '../lib/mcp_client'

module KairosMcp
  module SkillSets
    module McpClient
      module Tools
        class McpConnect < KairosMcp::Tools::BaseTool
          def name
            'mcp_connect'
          end

          def description
            'Connect to a remote MCP server and register its tools as local proxies. ' \
              'Remote tools become callable via invoke_tool("server_id/tool_name", args).'
          end

          def category
            :remote
          end

          def input_schema
            {
              type: 'object',
              properties: {
                url: { type: 'string', description: 'Remote MCP server URL (e.g., https://host:port/mcp)' },
                token: { type: 'string', description: 'Bearer token (or omit to use config)' },
                server_id: { type: 'string', description: 'Alias for this connection (default: derived from URL)' }
              },
              required: %w[url]
            }
          end

          def call(arguments)
            url = arguments['url']
            server_id = arguments['server_id'] || derive_server_id(url)
            config = load_config
            token = arguments['token'] || resolve_token_from_config(server_id, config)

            unless config['allow_untrusted'] || trusted?(url, config)
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => "Server #{url} is not in trusted_servers list. " \
                           "Add it to config or set allow_untrusted: true."
              }))
            end

            conn_mgr = ConnectionManager.instance

            # Unregister stale proxies if reconnecting same server_id
            old_conn = conn_mgr.all_connections[server_id]
            if old_conn
              old_conn[:tools].each { |rt| @registry.unregister_tool("#{server_id}/#{rt['name']}") }
            end

            conn = conn_mgr.connect(server_id: server_id, url: url,
                                    token: token, config: config)

            registered = register_proxy_tools(conn[:tools], server_id, conn_mgr)

            text_content(JSON.generate({
              'status' => 'ok', 'server_id' => server_id,
              'tools_registered' => registered.length,
              'tools' => registered.map(&:name)
            }))
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
          end

          private

          def register_proxy_tools(remote_tools, server_id, conn_mgr)
            remote_tools.map { |rt|
              proxy = ProxyTool.new(
                @safety, registry: @registry,
                server_id: server_id, remote_name: rt['name'],
                remote_description: rt['description'] || '',
                remote_schema: rt['inputSchema'] || { type: 'object', properties: {} },
                connection_manager: conn_mgr
              )
              @registry.register_dynamic_tool(proxy)
              proxy
            }
          end

          def derive_server_id(url)
            uri = URI.parse(url)
            "#{uri.host}_#{uri.port}"
          end

          def resolve_token_from_config(server_id, config)
            servers = config['servers'] || {}
            servers.dig(server_id, 'token')
          end

          def trusted?(url, config)
            patterns = config['trusted_servers'] || []
            return false if patterns.empty?
            patterns.any? { |p|
              pattern = p.is_a?(Hash) ? p['url_pattern'] : p.to_s
              File.fnmatch(pattern, url)
            }
          end

          def load_config
            path = File.join(__dir__, '..', 'config', 'mcp_client.yml')
            File.exist?(path) ? (YAML.safe_load(File.read(path)) || {}) : {}
          end
        end
      end
    end
  end
end
