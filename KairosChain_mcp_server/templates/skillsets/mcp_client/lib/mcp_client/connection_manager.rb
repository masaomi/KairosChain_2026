# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'singleton'
require 'time'

module KairosMcp
  module SkillSets
    module McpClient
      class ConnectionManager
        include Singleton

        def initialize
          @connections = {}  # server_id => { client:, info: }
          @mutex = Mutex.new
        end

        def connect(server_id:, url:, token: nil, config: {})
          max_conn = config['max_connections'] || 5

          @mutex.synchronize do
            if @connections.size >= max_conn && !@connections.key?(server_id)
              raise RemoteToolError, "Max connections (#{max_conn}) reached"
            end
            # Remove old connection if reconnecting (before releasing mutex)
            @connections.delete(server_id)
          end

          client = Client.new(url: url, token: token,
                              timeout: config['default_timeout'] || 30)
          client.initialize_session
          tools = client.list_tools

          conn = {
            server_id: server_id, url: url, status: 'connected',
            tools: tools, connected_at: Time.now.iso8601
          }

          @mutex.synchronize do
            @connections[server_id] = { client: client, info: conn }
          end
          save_connection(server_id, conn)
          conn
        end

        def disconnect(server_id)
          @mutex.synchronize { @connections.delete(server_id) }
          update_connection_status(server_id, 'disconnected')
        end

        def client_for(server_id)
          @mutex.synchronize { @connections.dig(server_id, :client) }
        end

        def all_connections
          @mutex.synchronize { @connections.transform_values { |v| v[:info] } }
        end

        def all_remote_tools
          @mutex.synchronize do
            @connections.flat_map { |sid, v|
              v[:info][:tools].map { |t| t.merge('server_id' => sid) }
            }
          end
        end

        # Restore proxy tools into a new ToolRegistry instance.
        # Used for HTTP mode compatibility where Protocol creates fresh registries.
        def restore_proxy_tools(registry, safety)
          @mutex.synchronize do
            @connections.each do |server_id, conn|
              next unless conn[:info][:status] == 'connected'
              next unless conn[:client]&.connected?

              conn[:info][:tools].each do |rt|
                proxy = ProxyTool.new(
                  safety, registry: registry,
                  server_id: server_id,
                  remote_name: rt['name'],
                  remote_description: rt['description'] || '',
                  remote_schema: rt['inputSchema'] || { type: 'object', properties: {} },
                  connection_manager: self
                )
                registry.register_dynamic_tool(proxy)
              end
            end
          end
        end

        # Reset for testing
        def reset!
          @mutex.synchronize { @connections.clear }
        end

        private

        def save_connection(server_id, conn)
          dir = storage_path("mcp_connections/#{server_id}")
          # Token excluded from persistence (security)
          File.write(File.join(dir, 'connection.json'), JSON.pretty_generate(conn))
        end

        def update_connection_status(server_id, status)
          path = File.join(storage_path("mcp_connections/#{server_id}"), 'connection.json')
          return unless File.exist?(path)

          data = JSON.parse(File.read(path))
          data['status'] = status
          File.write(path, JSON.pretty_generate(data))
        rescue StandardError
          nil
        end

        def storage_path(subpath)
          if defined?(Autonomos) && Autonomos.respond_to?(:storage_path)
            Autonomos.storage_path(subpath)
          else
            path = File.join('.kairos', 'storage', subpath)
            FileUtils.mkdir_p(path)
            path
          end
        end
      end
    end
  end
end
