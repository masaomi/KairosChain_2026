# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

module KairosMcp
  module SkillSets
    module McpClient
      class Client
        PROTOCOL_VERSION = '2025-03-26'
        CLIENT_INFO = { name: 'kairos-mcp-client', version: '1.0.0' }.freeze

        def initialize(url:, token: nil, timeout: 30)
          @url = URI.parse(url)
          @token = token
          @timeout = timeout
          @initialized = false
        end

        # MCP handshake: initialize + initialized notification
        def initialize_session
          result = request('initialize', {
            protocolVersion: PROTOCOL_VERSION,
            capabilities: { tools: {} },
            clientInfo: CLIENT_INFO
          })
          notify('notifications/initialized', {})
          @initialized = true
          result
        end

        def list_tools
          result = request('tools/list', {})
          result['tools'] || []
        end

        def call_tool(name, arguments)
          request('tools/call', { name: name, arguments: arguments })
        end

        def connected?
          @initialized
        end

        private

        def request(method, params)
          body = {
            jsonrpc: '2.0',
            id: SecureRandom.uuid,
            method: method,
            params: params
          }
          send_and_parse(body)
        end

        # Notification: no id, no response expected
        def notify(method, params)
          body = { jsonrpc: '2.0', method: method, params: params }
          send_http(body)
        rescue StandardError
          # Notifications are fire-and-forget
        end

        def send_and_parse(body)
          resp = send_http(body)

          unless resp.is_a?(Net::HTTPSuccess)
            raise RemoteToolError,
              "HTTP #{resp.code}: #{resp.message} (#{@url})"
          end

          begin
            parsed = JSON.parse(resp.body)
          rescue JSON::ParserError => e
            raise RemoteToolError,
              "Invalid JSON from #{@url}: #{e.message}"
          end

          if parsed['error']
            err = parsed['error']
            raise RemoteToolError,
              "JSON-RPC error #{err['code']}: #{err['message']}"
          end

          parsed['result']
        end

        def send_http(body)
          http = Net::HTTP.new(@url.host, @url.port)
          http.use_ssl = @url.scheme == 'https'
          http.open_timeout = @timeout
          http.read_timeout = @timeout

          path = @url.path.empty? ? '/mcp' : @url.path
          req = Net::HTTP::Post.new(path)
          req['Content-Type'] = 'application/json'
          req['Authorization'] = "Bearer #{@token}" if @token
          req.body = JSON.generate(body)

          http.request(req)
        end
      end

      class RemoteToolError < StandardError; end
    end
  end
end
