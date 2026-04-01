# frozen_string_literal: true

require 'json'
require 'yaml'
require 'securerandom'
require_relative 'protocol'
require_relative 'version'
require_relative '../kairos_mcp'
require_relative 'auth/token_store'
require_relative 'auth/authenticator'
require_relative 'skills_config'
require_relative 'admin/router'
require_relative 'meeting_router'

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
    DEFAULT_HOST = '127.0.0.1'

    JSON_HEADERS = {
      'Content-Type' => 'application/json',
      'Cache-Control' => 'no-cache'
    }.freeze

    attr_reader :port, :host, :token_store, :authenticator, :admin_router, :meeting_router, :place_router

    def initialize(port: nil, host: nil, token_store_path: nil)
      http_config = SkillsConfig.load['http'] || {}

      @port = port || http_config['port'] || DEFAULT_PORT
      @host = host || http_config['host'] || DEFAULT_HOST

      # SkillSets must load BEFORE TokenStore.create so that plugins
      # (e.g. Multiuser) can register alternative backends first.
      eager_load_skillsets

      store_path = token_store_path || http_config['token_store']
      if store_path && !File.absolute_path?(store_path)
        store_path = File.join(KairosMcp.data_dir, store_path)
      end

      @token_store = Auth::TokenStore.create(
        backend: http_config['token_backend'],
        store_path: store_path
      )
      @authenticator = Auth::Authenticator.new(@token_store)
      @admin_router = Admin::Router.new(token_store: @token_store, authenticator: @authenticator)
      @meeting_router = MeetingRouter.new
      @place_router = nil
    end

    # Load SkillSets at startup so /meeting/* endpoints work immediately.
    # Without this, MMP module is not defined until the first MCP request.
    def eager_load_skillsets
      require_relative 'skillset_manager'
      SkillSetManager.new.enabled_skillsets.each(&:load!)
    rescue StandardError => e
      $stderr.puts "[HttpServer] SkillSet eager load: #{e.message}"
    end

    # Start the HTTP server with Puma
    def run
      KairosMcp.http_server = self
      check_dependencies!
      check_tokens!
      check_version_mismatch
      auto_start_meeting_place

      app = build_rack_app
      server = self

      log "Starting KairosChain MCP Server v#{VERSION} (Streamable HTTP)"
      log "Listening on #{@host}:#{@port}"
      log "MCP endpoint: POST /mcp"
      log "Health check: GET /health"
      log "Admin UI:     GET /admin"
      log "MMP P2P:      /meeting/v1/*"
      log "Place API:    /place/v1/*" if @place_router

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

        # MMP (Meeting Protocol) P2P endpoints
        if path.start_with?('/meeting/')
          return server.meeting_router.call(env)
        end

        # Hestia Meeting Place endpoints
        if path.start_with?('/place/')
          return server.handle_place(env)
        end

        case [request_method, path]
        when ['GET', '/health']
          server.handle_health
        when ['POST', '/mcp']
          server.handle_mcp(env)
        when ['DELETE', '/mcp']
          # Streamable HTTP spec: session termination (no-op in stateless mode)
          [204, {}, []]
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
        tokens_configured: !@token_store.empty?,
        place_started: !@place_router.nil?
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

      # 3. Parse request to detect method
      parsed = JSON.parse(body)
      method = parsed['method']

      # 4. Process MCP message with user context
      #
      # Stateless design: each request creates a fresh Protocol instance.
      # For non-initialize methods, we auto-initialize the Protocol first
      # so that @initialized=true and tools are available.
      # See L1 knowledge: kairoschain_operations "Streamable HTTP Transport: Stateless Design"
      user_context = auth_result.user_context

      # Inject remote_ip for Service Grant IP rate limiting (D-5).
      # Uses shared ClientIpResolver when available (Path A/B consistency).
      if user_context
        user_context[:remote_ip] = if defined?(ServiceGrant) && ServiceGrant.respond_to?(:ip_resolver) && ServiceGrant.ip_resolver
                                     ServiceGrant.ip_resolver.resolve(env)
                                   else
                                     env['HTTP_X_REAL_IP'] || env['REMOTE_ADDR']
                                   end
      end
      protocol = Protocol.new(user_context: user_context)

      if method == 'initialize'
        # First request in MCP handshake — process normally, return Mcp-Session-Id
        response = protocol.handle_message(body)
        session_id = SecureRandom.hex(32)
        headers = JSON_HEADERS.merge('Mcp-Session-Id' => session_id)
        [200, headers, [response.to_json]]
      elsif method == 'initialized'
        # Notification — no response body needed
        [204, {}, []]
      else
        # For tools/list, tools/call, etc.: auto-initialize the Protocol
        # so it doesn't reject the request due to @initialized being false.
        protocol.handle_message({
          'jsonrpc' => '2.0', 'id' => '_init', 'method' => 'initialize',
          'params' => { 'protocolVersion' => Protocol::HTTP_PROTOCOL_VERSION,
                        'capabilities' => {},
                        'clientInfo' => { 'name' => 'http-stateless', 'version' => '1.0' } }
        }.to_json)

        response = protocol.handle_message(body)
        if response
          [200, JSON_HEADERS, [response.to_json]]
        else
          [204, {}, []]
        end
      end
    rescue JSON::ParserError
      json_response(400, error: 'bad_request', message: 'Invalid JSON in request body')
    rescue StandardError => e
      $stderr.puts "[ERROR] MCP request failed: #{e.message}"
      $stderr.puts e.backtrace.first(5).join("\n")
      json_response(500, error: 'internal_error',
                         message: "Internal server error: #{e.message}")
    end

    # Handle /place/* routes via Hestia PlaceRouter
    def handle_place(env)
      unless @place_router
        return json_response(503, error: 'place_not_started',
                                  message: 'Meeting Place is not started. Use meeting_place_start tool first.')
      end
      @place_router.call(env)
    end

    # Start the Meeting Place (called by meeting_place_start tool or auto-start)
    #
    # @param hestia_config [Hash, nil] Full Hestia config hash. PlaceRouter
    #   expects the full config (it accesses config['meeting_place'] internally).
    #   When nil, PlaceRouter falls back to ::Hestia.load_config.
    def start_place(identity:, trust_anchor_client: nil, hestia_config: nil)
      require 'hestia'
      router = ::Hestia::PlaceRouter.new(config: hestia_config)
      router.start(
        identity: identity,
        session_store: @meeting_router.session_store,
        trust_anchor_client: trust_anchor_client
      )
      @place_router = router

      # Register place extensions from enabled SkillSets
      register_place_extensions(router)
    end

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    def json_response(status, body_hash)
      [status, JSON_HEADERS, [body_hash.to_json]]
    end

    private

    # Register place extensions from enabled SkillSets that declare place_extensions.
    # Uses KairosMcp.http_server pattern for late registration access.
    def register_place_extensions(router)
      require_relative 'skillset_manager'
      SkillSetManager.new.enabled_skillsets.each do |ss|
        next unless ss.place_extensions.any?

        ss.place_extensions.each do |ext_def|
          require_path = File.join(ss.path, ext_def['require'])
          require require_path
          ext_class = Object.const_get(ext_def['class'])
          router.register_extension(
            ext_class.new(router),
            route_action_map: ext_def['route_actions'] || {}
          )
        rescue StandardError => e
          $stderr.puts "[HttpServer] Failed to load extension '#{ext_def['class']}' " \
                       "from SkillSet '#{ss.name}': #{e.message}"
        end
      end
    rescue StandardError => e
      $stderr.puts "[HttpServer] Extension registration failed (non-fatal): #{e.message}"
    end

    # Auto-start Meeting Place if hestia.yml has meeting_place.enabled: true
    def auto_start_meeting_place
      require 'hestia'
      hestia_config = ::Hestia.load_config
      return unless hestia_config.dig('meeting_place', 'enabled')

      mmp_config = ::MMP.load_config rescue nil
      return unless mmp_config&.dig('enabled')

      identity = ::MMP::Identity.new(config: mmp_config)
      trust_anchor = nil
      if hestia_config.dig('trust_anchor', 'record_registrations')
        trust_anchor = ::Hestia.chain_client(config: hestia_config.dig('chain'))
      end

      start_place(identity: identity, trust_anchor_client: trust_anchor, hestia_config: hestia_config)
      log "Meeting Place auto-started (config: meeting_place.enabled = true)"
    rescue LoadError => e
      $stderr.puts "[HttpServer] Meeting Place auto-start skipped: Hestia SkillSet not available (#{e.message})"
    rescue StandardError => e
      $stderr.puts "[HttpServer] Meeting Place auto-start failed: #{e.message}"
    end

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
          [INFO] Local dev mode: no tokens configured.
          MCP endpoint accepts unauthenticated requests as local owner.
          For production, generate a token with: kairos-chain --init-admin

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
