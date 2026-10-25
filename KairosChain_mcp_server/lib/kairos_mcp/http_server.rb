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
require_relative 'tls_config'
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

    attr_reader :port, :host, :token_store, :authenticator, :admin_router,
                :meeting_router, :place_router, :tls, :meeting_only, :admission_config

    WILDCARD_HOSTS = ['0.0.0.0', '::', '[::]', ''].freeze

    # @param meeting_only [Boolean, nil] serve only /meeting/v1/* and /health
    #   (secure MMP v1, I5); nil reads http.meeting_only from config
    # @param admission [String, nil] direct-mode admission policy from
    #   --admission ('open' or a decider name); nil keeps today's open path
    # @param origins [Array<String>, nil] origins a direct proof may address
    def initialize(port: nil, host: nil, token_store_path: nil, tls: nil,
                   meeting_only: nil, admission: nil, origins: nil)
      http_config = SkillsConfig.load['http'] || {}

      @port = port || http_config['port'] || DEFAULT_PORT
      @host = host || http_config['host'] || DEFAULT_HOST
      @meeting_only = meeting_only.nil? ? http_config['meeting_only'] == true : meeting_only

      # TLS is opt-in and delegated to Puma/OpenSSL (Prop 2: execution
      # substrate). `tls: true` from the CLI (--tls) overrides the config.
      @tls = TlsConfig.new(http_config, data_dir: KairosMcp.data_dir, force_enabled: tls)

      # SkillSets must load BEFORE TokenStore.create so that plugins
      # (e.g. Multiuser) can register alternative backends first.
      @meeting_only ? load_meeting_skillsets : eager_load_skillsets

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
      @admission_config = {
        policy: admission&.to_s,
        origins: Array(origins).empty? ? [own_origin].compact : Array(origins),
        started_at: nil
      }
      @meeting_router = MeetingRouter.new(admission: @admission_config)
      @place_router = nil
    end

    # The origin a peer dials to reach this listener, or nil for a wildcard bind.
    def own_origin
      return nil if WILDCARD_HOSTS.include?(@host.to_s)

      host = @host.to_s
      host = "[#{host}]" if host.include?(':') && !host.start_with?('[')
      require_relative 'admission_commands'
      # Normalized exactly as senders normalize the origin they dial.
      AdmissionCommands.normalize_origin("#{@tls.scheme}://#{host}:#{@port}")
    end

    # Meeting-only listeners load mmp and every enabled SkillSet that depends
    # on it (that is where ext: handlers and admission deciders register),
    # each on its own, so one failing SkillSet cannot take the listener down.
    def load_meeting_skillsets
      require_relative 'skillset_manager'
      @skillset_load_failures = {}
      @skillsets_loaded = []
      SkillSetManager.new.enabled_skillsets.each do |ss|
        next unless ss.name == 'mmp' || ss.depends_on.include?('mmp')

        begin
          if ss.load! == false
            @skillset_load_failures[ss.name] = 'skipped (needs a newer core)'
          else
            @skillsets_loaded << ss.name
          end
        rescue StandardError, ScriptError => e
          @skillset_load_failures[ss.name] = "#{e.class}: #{e.message}"
          $stderr.puts "[HttpServer] SkillSet '#{ss.name}' failed to load: #{e.class}: #{e.message}"
        end
      end
    rescue StandardError => e
      $stderr.puts "[HttpServer] SkillSet discovery: #{e.message}"
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
      check_tls!
      @meeting_only ? check_meeting_only! : check_tokens!
      check_admission!
      check_version_mismatch
      auto_start_meeting_place unless @meeting_only
      @admission_config[:started_at] = Time.now.utc

      app = build_rack_app
      server = self

      log "Starting KairosChain MCP Server v#{VERSION} (Streamable HTTP)"
      log "Listening on #{@tls.scheme}://#{@host}:#{@port}"
      log "TLS: #{@tls.enabled? ? "enabled (cert: #{@tls.cert_path})" : 'disabled (plain HTTP)'}"
      log_tls_expiry
      log "MCP endpoint: POST /mcp" unless @meeting_only
      log "Health check: GET /health"
      if @meeting_only
        log "Meeting-only: /mcp, /admin and /place are not served"
        log "SkillSets:    #{(@skillsets_loaded || []).join(', ')}"
      else
        log "Admin UI:     GET /admin"
      end
      log "MMP P2P:      /meeting/v1/*"
      log "Admission:    #{admission_summary}"
      unless @meeting_router.send(:mmp_current?)
        $stderr.puts "[WARN] The installed mmp SkillSet is older than #{MeetingRouter::MIN_MMP_VERSION}: " \
                     '/meeting/* answers 503 until `kairos-chain upgrade --apply`.'
      end
      log "Place API:    /place/v1/*" if @place_router

      require 'puma'
      require 'puma/configuration'
      require 'puma/launcher'

      body_limit = @meeting_only ? MeetingRouter::MAX_BODY_BYTES : nil
      puma_config = Puma::Configuration.new do |config|
        config.bind server.bind_uri
        config.app app
        # Refused by Puma before buffering, so no peer can fill the disk.
        config.http_content_length_limit(body_limit) if body_limit
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

        # Meeting-only listener (I5): no owner endpoint exists at all.
        if server.meeting_only
          return server.meeting_router.call(env) if path.start_with?('/meeting/')
          return server.handle_health if request_method == 'GET' && path == '/health'

          return server.json_response(404, error: 'meeting_only',
                                           message: 'This listener serves /meeting/v1/* only.')
        end

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
        tls: @tls.enabled?,
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

    # Puma bind URI for the configured host/port. Scheme (tcp:// vs ssl://)
    # is decided by TlsConfig. Public for testability.
    def bind_uri
      @tls.bind_uri(@host, @port)
    end

    private

    # Fail-closed TLS check: if TLS is enabled but cert/key are missing,
    # abort with actionable guidance rather than starting plain HTTP.
    def check_tls!
      @tls.validate!
    rescue TlsConfigError => e
      $stderr.puts "[ERROR] #{e.message}"
      exit 1
    end

    # Surface certificate expiry so a self-signed cert does not silently stop
    # working after its validity window (no auto-renewal for --gen-cert).
    EXPIRY_WARN_DAYS = 30

    def log_tls_expiry
      return unless @tls.enabled?

      days = @tls.days_until_expiry
      return if days.nil?

      not_after = @tls.certificate_not_after
      if days.negative?
        $stderr.puts "[WARN] TLS certificate EXPIRED #{-days} day(s) ago (#{not_after}). " \
                     "Regenerate with 'kairos-chain --gen-cert' (delete the old cert first)."
      else
        log "TLS cert expires: #{not_after} (#{days} days)"
        if days <= EXPIRY_WARN_DAYS
          $stderr.puts "[WARN] TLS certificate expires in #{days} day(s). " \
                       "Regenerate with 'kairos-chain --gen-cert' (delete the old cert first)."
        end
      end
    end

    LOOPBACK_HOSTS = ['127.0.0.1', '::1', 'localhost'].freeze

    # Environment opt-out for the fail-closed open-endpoint guard.
    ALLOW_OPEN_ENDPOINT_ENV = 'KAIROS_ALLOW_OPEN_ENDPOINT'

    def loopback_only?
      LOOPBACK_HOSTS.include?(@host)
    end

    # Pure predicate (class method for testability): an empty token store means
    # unauthenticated owner access. That is only acceptable on a loopback bind
    # without TLS (local dev). Network-reachable (non-loopback) or TLS-enabled
    # (remote intent) + empty store = an open owner endpoint.
    def self.exposed_without_auth?(token_store_empty:, loopback:, tls_enabled:)
      token_store_empty && (!loopback || tls_enabled)
    end

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
          # public_routes (skillset web catalog design WC-2): pass only when the
          # installed hestia PlaceRouter supports it, so a newer gem composes
          # with an older hestia SkillSet (and vice versa) without breaking.
          supports_public = router.method(:register_extension).parameters.any? { |_type, name| name == :public_routes }
          if supports_public
            router.register_extension(
              ext_class.new(router),
              route_action_map: ext_def['route_actions'] || {},
              public_routes: ext_def['public_routes'] || []
            )
          else
            router.register_extension(
              ext_class.new(router),
              route_action_map: ext_def['route_actions'] || {}
            )
          end
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
        if @meeting_only
          require 'puma/configuration'
          unless Puma::DSL.method_defined?(:http_content_length_limit)
            $stderr.puts "[ERROR] --meeting-only needs Puma >= 6.1 (for its body-size limit); found #{Puma::Const::PUMA_VERSION}."
            exit 1
          end
        end
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

    # I5: with no owner endpoint the thing worth guarding is admission. A
    # meeting-only listener on a reachable address needs an explicit policy.
    def check_meeting_only!
      return if loopback_only? || !@admission_config[:policy].to_s.empty?

      $stderr.puts <<~MSG
        [ERROR] Refusing to start: --meeting-only on a network-reachable address
        (host=#{@host}) needs an explicit admission policy.

        Start with --admission pinned (only keys pinned with `kairos-chain peer pin add`),
        or --admission open to accept any peer as before.

      MSG
      exit 1
    end

    # A restricted policy needs an origin proofs can address; the decider's
    # absence is not fatal (nothing is admitted) but is said loudly.
    def check_admission!
      policy = @admission_config[:policy].to_s
      return if policy.empty? || policy == 'open'

      if @admission_config[:origins].empty?
        $stderr.puts <<~MSG
          [ERROR] Refusing to start: admission policy '#{policy}' on a wildcard bind
          (host=#{@host}) has no origin a peer's proof could address.
          Bind a specific address with --host, or name it with --origin URL.

        MSG
        exit 1
      end
    end

    def admission_summary
      policy = @admission_config[:policy].to_s
      return 'open (no --admission; any self-signed peer gets a session)' if policy.empty?
      return 'open (declared)' if policy == 'open'

      unless defined?(::MMP::Admission) && ::MMP::Admission.registered?(policy)
        failed = (@skillset_load_failures || {}).map { |n, e| "#{n}: #{e}" }.join('; ')
        return "#{policy} — CLOSED: no decider registered for '#{policy}'#{failed.empty? ? '' : " (failed: #{failed})"}"
      end

      require_relative 'admission_records'
      state = AdmissionRecords.for_data_dir.state
      return "#{policy} — CLOSED: #{state.status} #{state.cause}" unless state.ok?

      pins = AdmissionRecords.for_data_dir.admitted_pins.size
      "#{policy} — #{pins} pin#{pins == 1 ? '' : 's'}; origins #{@admission_config[:origins].join(', ')}"
    rescue StandardError => e
      "#{policy} — CLOSED: #{e.class}: #{e.message}"
    end

    def check_tokens!
      return unless @token_store.empty?

      # An empty token store means the MCP endpoint accepts unauthenticated
      # owner-level requests. On loopback without TLS that is convenient
      # local-dev. Exposed over the network (non-loopback, or TLS = remote
      # intent) it is an OPEN OWNER ENDPOINT — encrypting an open door.
      exposed = self.class.exposed_without_auth?(
        token_store_empty: true, loopback: loopback_only?, tls_enabled: @tls.enabled?
      )

      unless exposed
        $stderr.puts <<~MSG
          [INFO] Local dev mode: no tokens configured.
          MCP endpoint accepts unauthenticated requests as local owner.
          For production, generate a token with: kairos-chain --init-admin

        MSG
        return
      end

      # Fail-closed: refuse to start an open owner endpoint on a reachable
      # bind. The operator can opt out explicitly for intentional cases.
      if ENV[ALLOW_OPEN_ENDPOINT_ENV] == '1'
        $stderr.puts <<~MSG
          [SECURITY] No tokens configured and the endpoint is network-reachable
          (host=#{@host}#{@tls.enabled? ? ', TLS enabled' : ''}). Starting anyway
          because #{ALLOW_OPEN_ENDPOINT_ENV}=1. Unauthenticated requests are
          accepted as owner — anyone who can reach this port has full owner access.

        MSG
      else
        $stderr.puts <<~MSG
          [ERROR] Refusing to start: no tokens configured but the endpoint is
          network-reachable (host=#{@host}#{@tls.enabled? ? ', TLS enabled' : ''}).
          Unauthenticated requests would be accepted as owner — TLS encrypts the
          traffic but does NOT authenticate it, so this is an open owner endpoint.

          Generate an admin token first:  kairos-chain --init-admin
          Or bind to loopback (host 127.0.0.1) for local-only use.
          To start intentionally without auth, set #{ALLOW_OPEN_ENDPOINT_ENV}=1.

        MSG
        exit 1
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
