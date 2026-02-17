# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative 'protocol'
require_relative 'version'
require_relative '../kairos_mcp'
require_relative 'auth/token_store'
require_relative 'auth/authenticator'
require_relative 'skills_config'
require_relative 'admin/router'

module KairosMcp
  # HttpServer: Streamable HTTP transport for MCP
  #
  # Implements the MCP Streamable HTTP transport (2025-03-26 spec).
  # Uses Rack as the application interface and Puma as the web server.
  #
  # Endpoints:
  #   POST /mcp       - MCP JSON-RPC endpoint (requires Bearer token)
  #   GET  /health    - Health check (no auth required)
  #   GET  /admin/*   - Admin UI (requires owner Bearer token via session)
  #   POST /admin/*   - Admin operations (htmx, requires owner session)
  #
  # Usage:
  #   HttpServer.run(port: 8080)
  #
  # Configuration:
  #   Set in skills/config.yml under 'http' key, or via CLI options.
  #
  class HttpServer
    DEFAULT_PORT = 8080
    DEFAULT_HOST = '0.0.0.0'

    JSON_HEADERS = {
      'Content-Type' => 'application/json',
      'Cache-Control' => 'no-cache'
    }.freeze

    attr_reader :port, :host, :token_store, :authenticator, :admin_router

    def initialize(port: nil, host: nil, token_store_path: nil)
      http_config = SkillsConfig.load['http'] || {}

      @port = port || http_config['port'] || DEFAULT_PORT
      @host = host || http_config['host'] || DEFAULT_HOST
      # Resolve token store path: CLI option > config.yml > default.
      # Relative paths in config.yml are resolved against the data directory,
      # not the current working directory, to match --init-admin behavior.
      store_path = token_store_path || http_config['token_store']
      if store_path && !File.absolute_path?(store_path)
        store_path = File.join(KairosMcp.data_dir, store_path)
      end
      @token_store = Auth::TokenStore.new(store_path)
      @authenticator = Auth::Authenticator.new(@token_store)
      @admin_router = Admin::Router.new(token_store: @token_store, authenticator: @authenticator)
    end

    # Start the HTTP server with Puma
    def run
      check_dependencies!
      check_tokens!
      check_version_mismatch

      app = build_rack_app
      server = self

      log "Starting KairosChain MCP Server v#{VERSION} (Streamable HTTP)"
      log "Listening on #{@host}:#{@port}"
      log "MCP endpoint: POST /mcp"
      log "Health check: GET /health"
      log "Admin UI:     GET /admin"

      require 'puma'
      require 'puma/configuration'
      require 'puma/launcher'

      puma_config = Puma::Configuration.new do |config|
        config.bind "tcp://#{server.host}:#{server.port}"
        config.app app
        config.workers 0
        config.threads 1, 5
        config.environment 'production'
        config.log_requests false
        config.quiet false
      end

      launcher = Puma::Launcher.new(puma_config)
      launcher.run
    rescue Interrupt
      log "KairosChain HTTP Server interrupted."
    end

    # Build the Rack application (class method for testing)
    def self.build_app(token_store_path: nil)
      server = new(token_store_path: token_store_path)
      server.build_rack_app
    end

    # Build Rack application as a lambda
    #
    # Captures self (HttpServer instance) via closure.
    # Each POST /mcp request creates a new Protocol instance for thread safety.
    # Admin UI requests are delegated to Admin::Router.
    def build_rack_app
      server = self

      ->(env) do
        request_method = env['REQUEST_METHOD']
        path = env['PATH_INFO']

        # Admin UI routes
        if path.start_with?('/admin')
          return server.admin_router.call(env)
        end

        case [request_method, path]
        when ['GET', '/health']
          server.handle_health
        when ['POST', '/mcp']
          server.handle_mcp(env)
        when ['GET', '/mcp']
          # Streamable HTTP spec: GET /mcp for SSE streaming
          server.json_response(501, error: 'not_implemented',
                                    message: 'SSE streaming via GET /mcp is not yet supported')
        else
          server.json_response(404, error: 'not_found',
                                    message: 'Endpoint not found. Use POST /mcp for MCP requests.')
        end
      end
    end

    # -----------------------------------------------------------------------
    # Request Handlers (public for Rack lambda access)
    # -----------------------------------------------------------------------

    def handle_health
      body = {
        status: 'ok',
        server: 'kairos-chain',
        version: KairosMcp::VERSION,
        transport: 'streamable-http',
        tokens_configured: !@token_store.empty?
      }

      [200, JSON_HEADERS, [body.to_json]]
    end

    def handle_mcp(env)
      # 1. Authenticate
      auth_result = @authenticator.authenticate!(env)
      unless auth_result.success?
        return json_response(401, error: 'unauthorized', message: auth_result.message)
      end

      # 2. Read and validate request body
      body = env['rack.input']&.read
      if body.nil? || body.empty?
        return json_response(400, error: 'bad_request', message: 'Request body is required')
      end

      content_type = env['CONTENT_TYPE'] || ''
      unless content_type.include?('application/json')
        return json_response(400, error: 'bad_request',
                                  message: 'Content-Type must be application/json')
      end

      # 3. Process MCP message with user context
      user_context = auth_result.user_context
      protocol = Protocol.new(user_context: user_context)
      response = protocol.handle_message(body)

      if response
        [200, JSON_HEADERS, [response.to_json]]
      else
        # Some MCP messages (like 'initialized') return nil
        [204, {}, []]
      end
    rescue JSON::ParserError
      json_response(400, error: 'bad_request', message: 'Invalid JSON in request body')
    rescue StandardError => e
      $stderr.puts "[ERROR] MCP request failed: #{e.message}"
      $stderr.puts e.backtrace.first(5).join("\n")
      json_response(500, error: 'internal_error',
                         message: "Internal server error: #{e.message}")
    end

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    def json_response(status, body_hash)
      [status, JSON_HEADERS, [body_hash.to_json]]
    end

    private

    def check_dependencies!
      begin
        require 'puma'
        require 'rack'
      rescue LoadError => e
        $stderr.puts <<~MSG
          [ERROR] HTTP transport requires puma and rack gems.

          Install with:
            gem install puma rack
            bundle install --with http

          Or install individually:
            gem install puma rack

          Error: #{e.message}
        MSG
        exit 1
      end
    end

    def check_tokens!
      if @token_store.empty?
        $stderr.puts <<~MSG
          [WARNING] No active tokens found.
          No clients will be able to connect without a valid token.

          Generate an admin token with:
            kairos-chain --init-admin

        MSG
      end
    end

    def log(message)
      $stderr.puts "[INFO] #{message}"
    end

    # Check if data directory was initialized with a different gem version
    def check_version_mismatch
      meta_path = KairosMcp.meta_path
      return unless File.exist?(meta_path)

      meta = YAML.safe_load(File.read(meta_path)) rescue nil
      return unless meta.is_a?(Hash) && meta['kairos_mcp_version']

      data_version = meta['kairos_mcp_version']
      return if data_version == VERSION

      log "[KairosChain] Data directory was initialized with v#{data_version}, current gem is v#{VERSION}."
      log "[KairosChain] Run 'system_upgrade command=\"check\"' or 'kairos-chain upgrade' to see available updates."
    end
  end
end
