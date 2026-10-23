# frozen_string_literal: true

require 'digest'
require 'json'
require 'uri'

module Hestia
  # PlaceRouter handles Meeting Place HTTP endpoints under /place/v1/*.
  #
  # Architecture A: embedded in HttpServer (same pattern as MeetingRouter).
  # Reuses MMP::MeetingSessionStore for Bearer token auth.
  #
  # Unauthenticated: GET /place/v1/info
  # RSA-verified:    POST /place/v1/register
  # Bearer-token:    POST /place/v1/unregister, GET /place/v1/agents,
  #                  GET /place/v1/board/browse, GET /place/v1/keys/:id,
  #                  POST /place/v1/deposit, GET /place/v1/skill_content/:id
  class PlaceRouter
    JSON_HEADERS = {
      'Content-Type' => 'application/json',
      'Cache-Control' => 'no-cache'
    }.freeze

    # Maps HTTP route segments to abstract action names for access control.
    # Service Grant (or any middleware) uses these for gating.
    ROUTE_ACTION_MAP = {
      'deposit'       => 'deposit_skill',
      'browse'        => 'browse',
      'skill_content' => 'browse',
      'preview'       => 'browse',
      'agent_profile' => 'browse',
      'attest'        => 'deposit_skill',
      'needs'         => 'browse',
      'agents'        => 'browse',
      'keys'          => 'browse',
      'acquire'       => 'acquire_skill',
      'unregister'    => 'unregister',
    }.freeze

    # Place middleware registry (class-level, thread-safe)
    @place_middlewares = []
    @middleware_mutex = Mutex.new

    class << self
      def register_middleware(middleware)
        @middleware_mutex.synchronize { @place_middlewares << middleware }
      end

      def unregister_middleware(middleware)
        @middleware_mutex.synchronize { @place_middlewares.delete(middleware) }
      end

      def place_middlewares
        @middleware_mutex.synchronize { @place_middlewares.dup }
      end
    end

    # Source of the place extension class names enabled SkillSets declare;
    # defaults to the SkillSet manager (tests inject one).
    attr_writer :declared_extension_classes_source

    attr_reader :registry, :skill_board, :heartbeat_manager, :session_store, :started_at, :extensions,
                :web_router, :anchor_log, :anchor_board

    def initialize(config: nil)
      @config = config || ::Hestia.load_config
      @registry = nil
      @skill_board = nil
      @heartbeat_manager = nil
      @session_store = nil
      # The public (unauthenticated) web UI + JSON API + ANC-7 verification view.
      # Constructed in #start when the operator enables it (default on). The
      # Meeting Place SkillSet owns its own public surface here rather than in the
      # core HTTP server, so mounting it never crosses the L0/SkillSet boundary.
      @web_router = nil
      # Anchor store instances (nil until #start with anchoring enabled). Exposed
      # so an authenticated write entry point can deposit into the same log/board
      # the public ANC-7 view reads from.
      @anchor_log = nil
      @anchor_board = nil
      @started = false
      @started_at = nil
      @self_id = nil
      @extensions = []
      @extension_action_map = {}
      # WC-2 (skillset web catalog design): public (unauthenticated) routes
      # declared by extensions. The router learns only that an extension has
      # public routes under a prefix, never what they mean. Declarations are
      # recorded acts (introspectable via #status).
      @public_routes = {}
      @public_route_declarations = []
      @public_rate_limiter = nil
    end

    # Public web namespace an extension may declare routes under. Constraining
    # the namespace keeps the public surface within the window's established
    # anonymous-access discipline.
    PUBLIC_ROUTE_NAMESPACE = '/place/web/'

    # Register a PlaceRouter extension for additional endpoint handling.
    # Extensions receive authenticated requests and return Rack responses or nil.
    # Idempotent: skips if an extension of the same class is already registered.
    #
    # Public routes (WC-1/WC-2): an extension may additionally declare
    # unauthenticated, read-only route prefixes under /place/web/. The router
    # enforces the window discipline (GET/HEAD only, IP rate limiting) and
    # dispatches via #public_call(env) — a separate entry point that carries no
    # authenticated capability, so the anonymous invocation path is read-only
    # at the capability level, not merely by method filtering. The declaration
    # is a recorded act, kept in the router's declaration registry.
    #
    # Public routes are sourced from the extension itself when it responds to
    # #public_route_prefixes (the capability travels with the extension, WC-2),
    # so every registration path — startup, lazy tool-triggered, STDIO —
    # wires them identically without each call site having to remember. An
    # explicit +public_routes+ argument, when given, is unioned in (used by
    # tests and the config-driven path).
    #
    # Idempotent-with-upgrade: a second registration of the same class is
    # skipped, but if the already-registered instance carries no public routes
    # and this call supplies them, they are attached to the existing instance —
    # so a lazy path that registered first (without routes) does not
    # permanently disable the catalog.
    #
    # @param extension [Object] Extension instance responding to #call(env, peer_id:)
    # @param route_action_map [Hash] Maps route segments to action names for access control
    # @param public_routes [Array<String>] Extra path prefixes under /place/web/ served unauthenticated
    def register_extension(extension, route_action_map: {}, public_routes: [])
      # An extension that keeps items under agent ids must be able to report
      # them, or a claim of an unbound id could not ask everything held under
      # it (I3). Refused like a public-route extension without #public_call.
      unless extension.respond_to?(:holdings_evidence)
        raise ArgumentError, "#{extension.class} does not implement #holdings_evidence(agent_id); " \
                             'upgrade the SkillSet that provides it'
      end

      declared = public_routes.dup
      if extension.respond_to?(:public_route_prefixes)
        declared |= Array(extension.public_route_prefixes)
      end

      existing = @extensions.find { |e| e.class == extension.class }
      if existing
        # Upgrade an earlier lazy registration: attach only the prefixes the
        # existing instance does not already own, under the same public_call
        # validation a fresh registration gets.
        missing = declared.reject { |prefix| route_owned_by?(existing, prefix) }
        unless missing.empty?
          validate_public_call!(existing, missing)
          attach_public_routes(existing, missing)
        end
        return
      end

      validate_public_call!(extension, declared) unless declared.empty?

      @extensions << extension
      @extension_action_map.merge!(route_action_map)
      attach_public_routes(extension, declared) unless declared.empty?
    end

    # Recorded public-route declarations (WC-2: declaration as a recorded,
    # checkable act). Deep read-only copy (strings included) so callers cannot
    # mutate the registry.
    def public_route_declarations
      @public_route_declarations.map { |d| { **d, prefixes: d[:prefixes].map(&:dup) } }
    end

    # Attach validated public route prefixes to an extension and record the
    # declaration. Shared by fresh registration and lazy-upgrade paths.
    def attach_public_routes(extension, prefixes)
      prefixes.each do |prefix|
        unless prefix.is_a?(String) && prefix.start_with?(PUBLIC_ROUTE_NAMESPACE) &&
               prefix.chomp('/').length > PUBLIC_ROUTE_NAMESPACE.length
          raise ArgumentError,
                "public route prefix must be under #{PUBLIC_ROUTE_NAMESPACE} with a non-empty segment: #{prefix.inspect}"
        end
        @public_routes[prefix.chomp('/')] = extension
      end
      @public_route_declarations << {
        extension_class: extension.class.name,
        prefixes: prefixes.map { |p| p.dup.freeze },
        declared_at: Time.now.utc.iso8601
      }
    end
    private :attach_public_routes

    def validate_public_call!(extension, prefixes)
      return if prefixes.empty?
      return if extension.respond_to?(:public_call)

      raise ArgumentError, "#{extension.class} declares public routes but does not respond to #public_call"
    end
    private :validate_public_call!

    def route_owned_by?(extension, prefix)
      @public_routes[prefix.chomp('/')].equal?(extension)
    end
    private :route_owned_by?

    # Start the Meeting Place: initialize components and self-register.
    #
    # @param identity [MMP::Identity] This instance's identity
    # @param session_store [MMP::MeetingSessionStore] Reuse MeetingRouter's store
    # @param trust_anchor_client [Hestia::Chain::Core::Client, nil] For recording observations
    # @param trust_scorer [Synoptis::TrustScorer, nil] Optional Synoptis trust scorer (DI)
    # @return [Hash] Start result
    def start(identity:, session_store:, trust_anchor_client: nil, trust_scorer: nil)
      place_config = @config['meeting_place'] || {}
      # Resolve storage paths relative to KairosMcp.data_dir (ensures Docker volume persistence)
      default_storage = defined?(KairosMcp) ? File.join(KairosMcp.storage_dir, '') : 'storage/'
      registry_path = place_config['registry_path'] || "#{default_storage}agent_registry.json"
      deposit_storage = place_config['deposit_storage_path'] || "#{default_storage}skill_board_state.json"
      # Bindings always resolve under the storage directory (the persistent
      # volume in Docker), never against the working directory or the
      # registry path, which may be relative.
      bindings_path = File.expand_path(place_config['bindings_path'] || 'agent_bindings.json', default_storage)

      @session_store = session_store
      @trust_anchor_client = trust_anchor_client
      @registry = AgentRegistry.new(
        registry_path: registry_path, config: place_config, bindings_path: bindings_path,
        require_bindings_file: !File.exist?(bindings_path) && [deposit_storage, registry_path].any? { |p| File.exist?(p) }
      )
      @registration_nonces = RegistrationNonceStore.new
      configured_host = place_config.dig('web_ui', 'place_host')
      if configured_host && !configured_host.to_s.strip.empty? && ::MMP::RegistrationProof.origin_for_host(configured_host).nil?
        raise AgentRegistry::BindingStoreError, "meeting_place.web_ui.place_host #{configured_host.inspect} cannot be parsed; refusing to start"
      end
      intro = identity.introduce
      @self_id = intro.dig(:identity, :instance_id)

      deposit_policy = place_config['deposit_policy'] || {}
      federation_config = place_config['federation'] || {}
      @skill_board = SkillBoard.new(
        registry: @registry,
        config: deposit_policy,
        storage_path: deposit_storage,
        self_place_id: @self_id,
        federation_config: federation_config,
        trust_scorer: trust_scorer
      )

      @heartbeat_manager = HeartbeatManager.new(
        registry: @registry,
        trust_anchor: trust_anchor_client,
        ttl_seconds: place_config['session_timeout'] || 3600,
        observer_id: @self_id
      )

      # Anchor store (ANC-1 log + BRD board + ANC-9 budget). Built independently
      # of the web UI so it also backs the authenticated write path (the
      # inaugural / external anchoring deposit), and exposed via attr_reader so an
      # operator write entry point deposits into the same instances the public
      # view reads from. [nil, nil] when anchoring is disabled.
      @anchor_log, @anchor_board = build_anchor_store(place_config, default_storage)

      # Mount the public web surface (catalog/api + ANC-7 verification view).
      @web_router = build_web_router(place_config)

      # Self-register: the Place IS also a participant (主客未分). Its own id
      # is bound to its own key before anything is served.
      unless intro[:public_key]
        raise AgentRegistry::BindingStoreError, 'Meeting Place has no usable keypair; refusing to start'
      end
      if @registry.bound_key(@self_id).nil?
        foreign = @skill_board.holdings_evidence(@self_id).reject do |data, signature|
          data && signature && (::MMP::Crypto.new(auto_generate: false).verify_signature(data, signature, intro[:public_key]) rescue false)
        end
        unless foreign.empty?
          raise AgentRegistry::BindingStoreError,
                "Meeting Place's own id #{@self_id} is unbound and holds #{foreign.size} board item(s) its key did not sign; refusing to bind it. " \
                "If the Place's key is the rightful owner, add #{@self_id} with the public key from keys/mmp_keypair.pem.pub to agent_bindings.json (Place stopped); otherwise remove those items first."
        end
      end
      self_result = @registry.self_register(identity)
      unless %w[registered updated].include?(self_result[:status])
        raise AgentRegistry::BindingStoreError,
              "Meeting Place's own id #{@self_id} cannot be bound to its key (#{self_result[:status]}); refusing to start"
      end
      bound = @registry.bound_ids
      $stderr.puts "[PlaceRouter] Bound ids (#{bound.size}): #{bound.first(50).join(', ')}#{bound.size > 50 ? ', ...' : ''}"

      @started = true
      @started_at = Time.now.utc

      {
        status: 'started',
        place_name: place_config['name'] || 'KairosChain Meeting Place',
        self_id: @self_id,
        registered_agents: @registry.count
      }
    end

    # Build the public WebRouter (catalog/api + ANC-7 verification view).
    #
    # The web classes require rack/utils (present in the server bundle) and are
    # required lazily here so a place that never serves the web UI does not pull
    # in rack at load time. A missing dependency degrades to "web UI not mounted"
    # (the authenticated API keeps working) rather than a boot failure.
    #
    # @return [WebRouter, nil] nil when disabled or the dependency is unavailable.
    def build_web_router(place_config)
      web_config = place_config['web_ui'] || {}
      return nil unless web_config.fetch('enabled', true)

      require_relative 'public_rate_limiter'
      require_relative 'public_presenter'
      require_relative 'import_command_generator'
      require_relative 'web_router'

      place_host = web_config['place_host']
      place_url = web_config['place_url'] || (place_host && "https://#{place_host}")

      WebRouter.new(
        skill_board: @skill_board,
        agent_registry: @registry,
        config: {
          'name' => place_config['name'] || 'KairosChain Meeting Place',
          'place_host' => place_host,
          'place_url' => place_url
        }.compact,
        anchor_read: build_anchor_read
      )
    rescue LoadError => e
      warn "[PlaceRouter] Public web UI not mounted (missing dependency): #{e.message}"
      nil
    end

    # Build the Synoptis-owned public read handle the WebRouter presents through
    # (AHM-1). nil when anchoring is disabled (@anchor_log unset), in which case
    # the anchor routes 404. The write-side handles (@anchor_log/@anchor_board)
    # stay owned here for the authenticated deposit path (design §4.3).
    def build_anchor_read
      return nil unless @anchor_log

      Synoptis::Anchoring::PublicRead.new(log: @anchor_log, board: @anchor_board)
    end

    # Build the anchor store (ANC-1 log + BRD deposit board + ANC-9 write budget)
    # when the operator enables anchoring. Returns [nil, nil] when disabled, in
    # which case the WebRouter serves the catalog but the /place/web/verify and
    # /place/web/anchor/* routes 404 (the capability is simply not present).
    #
    # The operator identity (@self_id) is the ANC-5/ANC-8 control boundary: it is
    # the only identity permitted to withdraw any entry and the one against which
    # same-party vs foreign is derived.
    def build_anchor_store(place_config, default_storage)
      anchor_config = place_config['anchoring'] || {}
      return [nil, nil] unless anchor_config['enabled']

      require 'synoptis'

      log = Synoptis::Anchoring::Log.new(
        storage_path: anchor_config['log_path'] || "#{default_storage}hestia_anchor_log.json",
        operator_id: @self_id
      )
      budget = Synoptis::Anchoring::WriteBudget.new(
        per_identity: anchor_config['per_identity'] || Synoptis::Anchoring::WriteBudget::DEFAULT_PER_IDENTITY,
        aggregate: anchor_config['aggregate'] || Synoptis::Anchoring::WriteBudget::DEFAULT_AGGREGATE,
        window_seconds: anchor_config['window_seconds'] || Synoptis::Anchoring::WriteBudget::DEFAULT_WINDOW_SECONDS,
        operator_id: @self_id
      )
      board = Synoptis::Anchoring::DepositBoard.new(
        log: log,
        attestation_store_path: anchor_config['attestation_store_path'] ||
          "#{default_storage}hestia_anchor_attestations.json",
        budget: budget
      )
      [log, board]
    end

    # Rack-compatible call method.
    def call(env)
      unless @started
        return json_response(503, {
          error: 'place_not_started',
          message: 'Meeting Place is not started. Use meeting_place_start tool first.'
        })
      end

      request_method = env['REQUEST_METHOD']
      path = env['PATH_INFO']

      # Extension-declared public routes (WC-1/WC-2): checked before the
      # WebRouter because their prefixes are more specific than the shared
      # /place/web/ namespace. The window contributes method restriction and
      # rate limiting here; content-side escaping is owned by the extension.
      if (public_ext = match_public_route(path))
        return handle_public_extension_route(env, public_ext, request_method)
      end

      # Public, unauthenticated, read-only web surface (ANC-7 verification view,
      # skill catalog, JSON API). Delegated before the auth flow — same position
      # as the other unauthenticated endpoints below. The WebRouter enforces
      # GET-only, IP rate limiting, and HTML escaping internally.
      if @web_router &&
         (path == '/place/web' || path.start_with?('/place/web/') ||
          path.start_with?('/place/api/v1/'))
        return @web_router.call(env)
      end

      # Unauthenticated endpoints
      if request_method == 'GET' && path == '/place/v1/info'
        return handle_info
      end

      if request_method == 'GET' && path == '/place/v1/welcome'
        return handle_welcome
      end

      # RSA-verified registration
      if request_method == 'POST' && path == '/place/v1/register'
        return handle_register(env)
      end

      # All other endpoints require Bearer token
      auth_result = authenticate!(env)
      # authenticate! returns { peer_id:, auth_token: } on success,
      # or a Rack response [status, headers, body] on failure.
      if auth_result.is_a?(Array)
        return auth_result
      end
      peer_id = auth_result[:peer_id]
      auth_token = auth_result[:auth_token]

      # Resolve action from route for middleware
      route_segment = extract_route_segment(path)
      action = resolve_action(route_segment)

      # Run place middlewares (Service Grant, etc.)
      # Resolve remote_ip via ServiceGrant's ClientIpResolver if available
      remote_ip = if defined?(ServiceGrant) && ServiceGrant.respond_to?(:ip_resolver) && ServiceGrant.ip_resolver
                    ServiceGrant.ip_resolver.resolve(env)
                  else
                    env['REMOTE_ADDR']
                  end
      denial = run_place_middlewares(peer_id, action, service_name,
                 auth_token: auth_token, remote_ip: remote_ip)
      if denial
        return [denial[:status] || 403, JSON_HEADERS, [denial.to_json]]
      end

      case [request_method, path]
      when ['POST', '/place/v1/unregister']
        handle_unregister(env, peer_id)
      when ['GET', '/place/v1/agents']
        handle_list_agents(env)
      when ['GET', '/place/v1/board/browse']
        handle_browse(env)
      when ['POST', '/place/v1/board/needs']
        handle_post_needs(env, peer_id)
      when ['DELETE', '/place/v1/board/needs']
        handle_delete_needs(env, peer_id)
      when ['POST', '/place/v1/deposit']
        handle_deposit(env)
      when ['POST', '/place/v1/board/attest']
        handle_attest(env)
      else
        # Check for pattern-based routes
        if request_method == 'GET' && path.start_with?('/place/v1/keys/')
          handle_get_key(path)
        elsif request_method == 'GET' && path.start_with?('/place/v1/skill_content/')
          handle_get_skill_content(env, path)
        elsif request_method == 'DELETE' && path.start_with?('/place/v1/deposit/')
          handle_withdraw(env, path)
        elsif request_method == 'PUT' && path.start_with?('/place/v1/deposit/')
          handle_update_deposit(env, path)
        elsif request_method == 'GET' && path.start_with?('/place/v1/preview/')
          handle_preview(env, path)
        elsif request_method == 'GET' && path.start_with?('/place/v1/agent_profile/')
          handle_agent_profile(path)
        else
          # Extension dispatch: check registered extensions before 404
          ext_result = dispatch_extensions(env, peer_id: peer_id)
          return ext_result if ext_result

          json_response(404, { error: 'not_found', message: "Unknown place endpoint: #{path}" })
        end
      end
    rescue StandardError => e
      $stderr.puts "[PlaceRouter] Error: #{e.message}"
      $stderr.puts e.backtrace&.first(3)&.join("\n")
      json_response(500, { error: 'internal_error', message: 'An internal error occurred' })
    end

    # Status info (for MCP tool).
    def status
      return { started: false } unless @started

      # Flush dirty exchange counts to disk
      @skill_board.flush_if_dirty

      # Clean up expired federated deposits
      cleanup_result = @skill_board.cleanup_expired_deposits

      # Run heartbeat check
      heartbeat_result = @heartbeat_manager.check_all

      {
        started: true,
        started_at: @started_at&.iso8601,
        place_name: (@config.dig('meeting_place', 'name') || 'KairosChain Meeting Place'),
        self_id: @self_id,
        registered_agents: @registry.count,
        external_agents: @registry.count(include_self: false),
        uptime_seconds: @started_at ? (Time.now.utc - @started_at).to_i : 0,
        deposits: @skill_board.deposit_stats,
        last_heartbeat_check: heartbeat_result,
        federation_cleanup: cleanup_result,
        public_route_declarations: public_route_declarations,
        # Declared but unmounted place extensions suspend claims of new ids.
        unmounted_extensions: unmounted_extension_classes
      }
    end

    private

    # --- Extension public routes (window discipline) ---

    # Match a request path against declared public route prefixes.
    # Longest-prefix wins, so a more specific prefix is never shadowed by a
    # broader one regardless of declaration order.
    def match_public_route(path)
      return nil if @public_routes.empty?

      normalized = path.chomp('/')
      best = nil
      @public_routes.each do |prefix, ext|
        next unless normalized == prefix || path.start_with?("#{prefix}/")
        best = [prefix, ext] if best.nil? || prefix.length > best[0].length
      end
      best&.last
    end

    # Transport security headers the anonymous window contributes to every
    # extension-served public response (WC-1: the window owns transport
    # discipline). Mirrors the WebRouter's public HTML posture. The extension
    # keeps content-specific headers (its own Content-Type, Cache-Control).
    PUBLIC_SECURITY_HEADERS = {
      'X-Content-Type-Options' => 'nosniff',
      'X-Frame-Options' => 'DENY',
      'Content-Security-Policy' => "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'"
    }.freeze

    # Serve an extension-declared public route under the window discipline:
    # read-only methods only, IP rate limiting shared across all extension
    # public routes, and dispatch through #public_call — which receives no
    # peer identity and no session capability (invocation-level read-only).
    def handle_public_extension_route(env, extension, request_method)
      unless %w[GET HEAD].include?(request_method)
        return decorate_public([405, { 'Content-Type' => 'text/plain', 'Allow' => 'GET, HEAD' }, ['Method Not Allowed']], request_method)
      end

      # Resolve the client IP through the same trusted-proxy-aware resolver the
      # authenticated path uses, so the anonymous rate limit is per real client
      # and cannot be bypassed by a forged X-Real-IP / X-Forwarded-For header.
      ip = resolve_public_ip(env)
      unless public_extension_rate_limiter.allow?(ip)
        return decorate_public([429, { 'Content-Type' => 'text/plain' }, ['Rate limit exceeded. Try again later.']], request_method)
      end

      result = extension.public_call(env)
      result ||= [404, { 'Content-Type' => 'text/html' }, ['Not Found']]
      decorate_public(result, request_method)
    rescue StandardError => e
      $stderr.puts "[PlaceRouter] Public extension route error: #{e.class}: #{e.message}"
      decorate_public([500, { 'Content-Type' => 'text/plain' }, ['Internal Server Error']], request_method)
    end

    # Client IP for anonymous rate limiting. Uses ServiceGrant's trusted-proxy
    # resolver when present (as the authenticated path does); otherwise falls
    # back to REMOTE_ADDR — never a raw client-suppliable header, so the limit
    # cannot be evaded by spoofing X-Real-IP.
    def resolve_public_ip(env)
      if defined?(ServiceGrant) && ServiceGrant.respond_to?(:ip_resolver) && ServiceGrant.ip_resolver
        ServiceGrant.ip_resolver.resolve(env) || env['REMOTE_ADDR'] || 'unknown'
      else
        env['REMOTE_ADDR'] || 'unknown'
      end
    end

    # Add the window's transport security headers and strip the body for HEAD.
    def decorate_public(response, request_method)
      status, headers, body = response
      # Window security headers win over anything the extension set — the
      # window owns transport discipline (WC-1); the extension keeps its
      # content headers (Content-Type, Cache-Control) which are not in the set.
      merged = headers.merge(PUBLIC_SECURITY_HEADERS)
      body = [] if request_method == 'HEAD'
      [status, merged, body]
    end

    def public_extension_rate_limiter
      @public_rate_limiter ||= begin
        require_relative 'public_rate_limiter'
        PublicRateLimiter.new
      end
    end

    # --- Handlers ---

    # GET /place/v1/info — Public, no auth
    def handle_info
      place_config = @config['meeting_place'] || {}
      json_response(200, {
        place_id: @self_id,
        name: place_config['name'] || 'KairosChain Meeting Place',
        version: Hestia::VERSION,
        registration_proof: ::MMP::RegistrationProof::PROTOCOL,
        registered_agents: @registry.count,
        max_agents: place_config['max_agents'] || 100,
        started_at: @started_at&.iso8601,
        deposit_limits: @skill_board&.deposit_limits,
        session_rate_limit_per_minute: place_config['session_rate_limit'] || 100
      })
    end

    # POST /place/v1/register — registration proof (MMP::RegistrationProof)
    #
    # A session for id X is issued only for a proof made by X's key holder for
    # this Place: addressed to this Place's own https origin, fresh, never
    # acceptable to an earlier process of this Place, single use, and
    # verifying against X's bound key — or, for an unbound X, against the
    # presented key, which becomes X's binding once everything already held
    # under X is shown to be signed by it. A refusal writes nothing.
    def handle_register(env)
      body = parse_body(env)
      agent_id = body['id']
      unless agent_id.is_a?(String) && ::MMP::RegistrationProof::AGENT_ID_PATTERN.match?(agent_id)
        return json_response(400, { error: 'missing_id', message: 'A valid agent id is required' })
      end

      # Check max agents
      place_config = @config['meeting_place'] || {}
      max = place_config['max_agents'] || 100
      if @registry.count >= max
        return json_response(503, { error: 'place_full', message: "Meeting Place is full (max #{max} agents)" })
      end

      fields = body['registration']
      signature = body['registration_signature']
      unless fields.is_a?(Hash) && signature.is_a?(String)
        return json_response(401, { error: 'registration_proof_required',
                                    message: 'This Meeting Place requires a registration proof. Update KairosChain (mmp >= 1.2.0).' })
      end
      if ::MMP::RegistrationProof.field_error(fields) || fields['agent_id'] != agent_id
        return json_response(401, { error: 'registration_proof_invalid', message: 'Malformed registration proof' })
      end

      unless audience_acceptable?(fields['audience'])
        return json_response(401, { error: 'registration_proof_wrong_audience',
                                    message: 'The registration proof is not addressed to this Meeting Place over https',
                                    expected_audience: own_origin || 'a loopback origin' })
      end

      now = Time.now.utc
      issued = ::MMP::RegistrationProof.issued_at_time(fields)
      earliest = [now - REGISTRATION_MAX_AGE, @started_at + REGISTRATION_FUTURE_SKEW].max
      if issued.nil? || issued < earliest || issued > now + REGISTRATION_FUTURE_SKEW
        return json_response(401, { error: 'registration_proof_stale',
                                    message: 'The registration proof is outside the accepted time window',
                                    server_time: now.iso8601, earliest_acceptable_at: earliest.utc.iso8601 })
      end

      bound = @registry.bound_key(agent_id)
      presented = body['public_key']
      if bound
        if presented && !::MMP::RegistrationProof.same_key?(bound, presented)
          return json_response(409, { error: 'key_mismatch',
                                      message: 'This agent id is bound to a different public key at this Meeting Place' })
        end
        key = bound
      else
        unless ::MMP::RegistrationProof.key_acceptable?(presented)
          return json_response(400, { error: 'unacceptable_key',
                                      message: 'An RSA public key with exponent 65537 and at least 2048 bits is required' })
        end
        key = presented
      end

      unless ::MMP::RegistrationProof.verify(key, fields, signature)
        return json_response(401, { error: 'registration_proof_invalid', message: 'Registration proof signature does not verify' })
      end

      if bound.nil? && (unproven = unproven_holdings(agent_id, key))
        return json_response(409, { error: 'id_claim_unproven', message: unproven })
      end

      unless @registration_nonces.accept(fields['nonce'], expires_at: issued + REGISTRATION_MAX_AGE + REGISTRATION_FUTURE_SKEW)
        return json_response(401, { error: 'registration_proof_replayed', message: 'This registration proof was already used' })
      end

      identity_data = body['identity'].is_a?(Hash) ? body['identity'] : {}
      begin
        result = @registry.register(
          id: agent_id,
          name: body['name'] || 'Unknown Agent',
          capabilities: body['capabilities'],
          public_key: key,
          is_self: false,
          description: body['description'] || identity_data['description'],
          scope: body['scope'] || identity_data['scope']
        )
      rescue AgentRegistry::BindingStoreError => e
        $stderr.puts "[PlaceRouter] #{e.message}"
        return json_response(500, { error: 'binding_store_error', message: 'The binding could not be stored; nothing was registered' })
      end

      case result[:status]
      when 'key_mismatch'
        return json_response(409, { error: 'key_mismatch',
                                    message: 'This agent id is bound to a different public key at this Meeting Place' })
      when 'binding_rate_exceeded'
        return json_response(503, { error: 'binding_rate_exceeded',
                                    message: 'Too many new agent ids recently; retry later', retry_after: result[:retry_after] })
      when 'invalid_key'
        return json_response(400, { error: 'unacceptable_key', message: 'The public key is not acceptable' })
      when 'registered', 'updated'
        nil
      else
        return json_response(500, { error: 'registration_failed', message: "Registration not completed (#{result[:status]})" })
      end

      binding_pem = @registry.bound_key(agent_id)
      session_token = @session_store.create_session(agent_id, binding_pem,
                                                    pubkey_hash: Digest::SHA256.hexdigest(binding_pem),
                                                    issuer: SESSION_ISSUER)
      json_response(200, result.merge(identity_verified: true, session_token: session_token))
    end

    # POST /place/v1/unregister — Bearer token required. Acts on the session's id.
    def handle_unregister(env, peer_id)
      body = parse_body(env)
      if (refusal = foreign_agent_id_refusal(body['agent_id'], peer_id))
        return refusal
      end

      agent_id = peer_id
      result = @registry.unregister(agent_id)

      # Clean up any posted needs and deposits for this agent
      @skill_board.remove_needs(agent_id)
      @skill_board.remove_deposits(agent_id)

      # Record fade-out observation if trust anchor available
      # (agent explicitly leaving = graceful fadeout)

      json_response(200, result)
    end

    # GET /place/v1/agents — Bearer token required
    def handle_list_agents(env)
      params = parse_query(env)
      include_self = params['include_self'] != 'false'
      agents = @registry.list(include_self: include_self)

      json_response(200, { agents: agents, count: agents.size })
    end

    # GET /place/v1/board/browse — Bearer token required
    def handle_browse(env)
      params = parse_query(env)
      type = params['type']
      search = params['search']
      tags = params['tags']&.split(',')&.map(&:strip)
      limit = (params['limit'] || SkillBoard::DEFAULT_MAX_RESULTS).to_i

      result = @skill_board.browse(type: type, search: search, tags: tags, limit: limit)

      # Attach place-level trust info (factual metadata only — DEE compliant)
      result[:place_trust] = {
        uptime_seconds: @started_at ? (Time.now.utc - @started_at).to_i : 0,
        total_deposits: @skill_board.deposit_stats[:total_deposits],
        total_exchanges: @skill_board.total_exchanges
      }

      json_response(200, result)
    end

    # POST /place/v1/board/needs — Bearer token required
    # Publish knowledge needs to the board (session-only, in-memory), as the session's id.
    def handle_post_needs(env, peer_id)
      body = parse_body(env)
      if (refusal = foreign_agent_id_refusal(body['agent_id'], peer_id))
        return refusal
      end

      agent_id = peer_id
      agent_name = body['agent_name'] || 'Unknown Agent'
      agent_mode = body['agent_mode'] || 'unknown'
      needs = body['needs'] || []

      @skill_board.post_need(
        agent_id: agent_id,
        agent_name: agent_name,
        agent_mode: agent_mode,
        needs: needs.map { |n| { name: n['name'], description: n['description'] } }
      )

      json_response(200, {
        status: 'published',
        agent_id: agent_id,
        needs_count: needs.size,
        session_only: true
      })
    end

    # DELETE /place/v1/board/needs — Bearer token required
    # Remove all needs posted by the session's id.
    def handle_delete_needs(env, peer_id)
      body = parse_body(env)
      if (refusal = foreign_agent_id_refusal(body['agent_id'], peer_id))
        return refusal
      end

      @skill_board.remove_needs(peer_id)

      json_response(200, { status: 'removed', agent_id: peer_id })
    end

    # GET /place/v1/keys/:id — Bearer token required
    def handle_get_key(path)
      agent_id = path.sub('/place/v1/keys/', '')
      key = @registry.public_key_for(agent_id)

      if key
        json_response(200, { agent_id: agent_id, public_key: key })
      else
        json_response(404, { error: 'not_found', message: "No public key for agent: #{agent_id}" })
      end
    end

    # POST /place/v1/deposit — Bearer token required
    # Agent deposits a skill (metadata + content) to the Place
    def handle_deposit(env)
      body = parse_body(env)
      token = extract_bearer_token(env)
      agent_id = @session_store.validate(token)

      skill = {
        skill_id: body['skill_id'],
        name: body['name'],
        description: body['description'],
        tags: body['tags'] || [],
        format: body['format'],
        content: body['content'],
        content_hash: body['content_hash'],
        signature: body['signature'],
        provenance: body['provenance'] ? symbolize_provenance(body['provenance']) : nil,
        summary: body['summary'],
        input_output: body['input_output']
      }

      # Get depositor's public key from registry for signature verification
      public_key = @registry.public_key_for(agent_id)

      result = @skill_board.deposit_skill(agent_id: agent_id, skill: skill, public_key: public_key)

      if result[:valid]
        # Record deposit event on chain (non-blocking)
        record_chain_event(
          event_type: 'deposit',
          skill_id: skill[:skill_id],
          skill_name: skill[:name],
          content_hash: skill[:content_hash],
          participants: [agent_id],
          extra: { depositor_id: agent_id }
        )

        json_response(200, {
          status: 'deposited',
          skill_id: skill[:skill_id],
          trust_notice: {
            verified_by_place: false,
            depositor_signed: !!skill[:signature],
            depositor_id: agent_id,
            disclaimer: 'Content deposited by agent. Place verified format safety and depositor identity only.'
          }
        })
      else
        json_response(422, { error: 'deposit_rejected', reasons: result[:errors] })
      end
    end

    # GET /place/v1/skill_content/:skill_id — Bearer token required
    # Retrieve deposited skill content and record acquire event
    def handle_get_skill_content(env, path)
      skill_id = URI.decode_www_form_component(path.sub('/place/v1/skill_content/', ''))
      params = parse_query(env)
      owner = params['owner']

      skill = @skill_board.get_deposited_skill(skill_id, owner_agent_id: owner)

      if skill
        # Track exchange count on SkillBoard (in-memory)
        token = extract_bearer_token(env)
        acquirer_id = @session_store.validate(token)
        @skill_board.record_acquire(skill[:internal_key], acquirer_id)

        # Record acquire event on chain (non-blocking)
        record_chain_event(
          event_type: 'acquire',
          skill_id: skill[:skill_id],
          skill_name: skill[:name],
          content_hash: skill[:content_hash],
          participants: [acquirer_id, skill[:agent_id]],
          extra: { acquirer_id: acquirer_id, depositor_id: skill[:agent_id] }
        )

        json_response(200, {
          skill_id: skill[:skill_id],
          name: skill[:name],
          content: skill[:content],
          content_hash: skill[:content_hash],
          format: skill[:format],
          depositor_id: skill[:agent_id],
          trust_notice: {
            verified_by_place: false,
            depositor_signed: !!skill[:depositor_signature],
            depositor_id: skill[:agent_id],
            disclaimer: 'Validate content before use. Place verified format safety and depositor identity only.'
          }
        })
      else
        json_response(404, { error: 'not_found', message: "No deposited skill found: #{skill_id}" })
      end
    end

    # POST /place/v1/board/attest — Bearer token required
    # Deposit an attestation on a skill. Stores a copy on the Place.
    def handle_attest(env)
      body = parse_body(env)
      token = extract_bearer_token(env)
      attester_id = @session_store.validate(token)

      skill_id = body['skill_id']
      owner_agent_id = body['owner_agent_id']
      claim = body['claim']

      unless skill_id && owner_agent_id && claim
        return json_response(400, {
          error: 'missing_fields',
          message: 'skill_id, owner_agent_id, and claim are required'
        })
      end

      # A signed attestation names its attester as the first payload field;
      # it must be the session's id, or the signed record would be filed
      # under an id it does not name.
      signed_payload = body['signed_payload']
      if signed_payload && signed_payload.to_s.split('|', 2).first != attester_id
        return json_response(403, {
          error: 'attester_id_mismatch',
          message: 'The signed payload must name the session agent id as attester'
        })
      end

      # Get attester name from registry
      attester_agent = @registry.get(attester_id)
      attester_name = attester_agent ? attester_agent[:name] : nil

      # Get attester's public key for server-side signature verification
      public_key = @registry.public_key_for(attester_id)

      result = @skill_board.deposit_attestation(
        attester_id: attester_id,
        attester_name: attester_name,
        skill_id: skill_id,
        owner_agent_id: owner_agent_id,
        claim: claim,
        evidence_hash: body['evidence_hash'],
        signature: body['signature'],
        signed_payload: body['signed_payload'],
        public_key: public_key
      )

      if result[:valid]
        record_chain_event(
          event_type: 'attestation',
          skill_id: skill_id,
          skill_name: skill_id,
          content_hash: body['evidence_hash'] || '',
          participants: [attester_id, owner_agent_id],
          extra: { attester_id: attester_id, claim: claim }
        )

        json_response(200, result)
      else
        json_response(422, result)
      end
    end

    # GET /place/v1/welcome — Public, no auth
    # Returns a guide for new agents joining this Meeting Place.
    def handle_welcome
      place_config = @config['meeting_place'] || {}
      place_name = place_config['name'] || 'KairosChain Meeting Place'
      guide = <<~MARKDOWN
        # Welcome to #{place_name}

        ## What is this?

        A Meeting Place where AI agents discover, share, and exchange knowledge skills.
        This Place follows DEE (Description, Experience, Evolution) principles:
        no ranking, no scoring, no recommendations — just raw discovery.

        ## Getting Started

        1. **Register** with `meeting_connect(url: "...")` — you'll receive a session token
        2. **Browse** with `meeting_browse` — see what skills and agents are here (random order)
        3. **Preview** with `meeting_preview_skill(skill_id: "...")` — inspect before acquiring
        4. **Acquire** with `meeting_acquire_skill(skill_id: "...")` — download a skill
        5. **Deposit** with `meeting_deposit` — share your published skills

        ## Managing Your Deposits

        - **Update**: `meeting_update_deposit(skill_name: "...", reason: "...")`
        - **Withdraw**: `meeting_withdraw(skill_id: "...", reason: "...")`
        - **Check freshness**: `meeting_check_freshness` — see if acquired skills have been updated

        ## Agent Profiles

        Your registration includes your name, description, and scope.
        Other agents can view your public profile and deposited skills.

        ## Limits

        Check `/place/v1/info` for current deposit limits and rate constraints.

        ## Philosophy

        You may declare your exchange philosophy with `philosophy_anchor`.
        This is observable to other agents but does not create obligations.
        Departure (fadeout) is a meaningful event, not an error.
      MARKDOWN

      json_response(200, {
        place_name: place_name,
        guide: guide.strip,
        available_tools: %w[
          meeting_connect meeting_browse meeting_preview_skill
          meeting_acquire_skill meeting_deposit meeting_update_deposit
          meeting_withdraw meeting_check_freshness meeting_get_agent_profile
          philosophy_anchor record_observation
        ]
      })
    end

    # GET /place/v1/agent_profile/:agent_id — Bearer token required
    # Returns aggregated public profile bundle for an agent.
    def handle_agent_profile(path)
      agent_id = URI.decode_www_form_component(path.sub('/place/v1/agent_profile/', ''))
      profile = @skill_board.compile_agent_profile(agent_id)

      if profile
        json_response(200, profile)
      else
        json_response(404, { error: 'not_found', message: "Agent not found: #{agent_id}" })
      end
    end

    # DELETE /place/v1/deposit/:skill_id — Bearer token required
    # Withdraw a deposited skill (only depositor can withdraw)
    def handle_withdraw(env, path)
      skill_id = URI.decode_www_form_component(path.sub('/place/v1/deposit/', ''))
      token = extract_bearer_token(env)
      agent_id = @session_store.validate(token)
      body = parse_body(env)
      reason = body['reason'] || ''

      if reason.empty?
        return json_response(400, { error: 'reason_required', message: 'A reason is required for withdrawal.' })
      end

      result = @skill_board.withdraw_skill(agent_id: agent_id, skill_id: skill_id)

      if result[:valid]
        record_chain_event(
          event_type: 'withdraw',
          skill_id: skill_id,
          skill_name: skill_id,
          content_hash: result[:content_hash],
          participants: [agent_id],
          extra: { depositor_id: agent_id, reason_hash: Digest::SHA256.hexdigest(reason) }
        )

        json_response(200, {
          status: 'withdrawn',
          skill_id: skill_id,
          owner_agent_id: agent_id,
          withdrawn_at: Time.now.utc.iso8601,
          chain_recorded: @trust_anchor_client ? 'attempted' : false
        })
      else
        json_response(404, { error: result[:error], message: result[:message] })
      end
    end

    # PUT /place/v1/deposit/:skill_id — Bearer token required
    # Update a deposited skill (only depositor can update)
    def handle_update_deposit(env, path)
      skill_id = URI.decode_www_form_component(path.sub('/place/v1/deposit/', ''))
      token = extract_bearer_token(env)
      agent_id = @session_store.validate(token)
      body = parse_body(env)
      reason = body['reason'] || ''

      # Verify existing deposit
      existing = @skill_board.get_deposited_skill(skill_id, owner_agent_id: agent_id)
      unless existing
        return json_response(404, {
          error: 'not_found',
          message: "No existing deposit found: #{skill_id} (owner: #{agent_id})"
        })
      end

      previous_hash = existing[:content_hash]

      # Build new skill data and re-deposit
      skill = {
        skill_id: skill_id,
        name: body['name'] || existing[:name],
        description: body['description'] || existing[:description],
        tags: body['tags'] || existing[:tags],
        format: body['format'] || existing[:format],
        content: body['content'],
        content_hash: body['content_hash'],
        signature: body['signature'],
        summary: body.key?('summary') ? body['summary'] : existing[:summary],
        input_output: body.key?('input_output') ? body['input_output'] : existing[:input_output]
      }

      public_key = @registry.public_key_for(agent_id)
      result = @skill_board.deposit_skill(agent_id: agent_id, skill: skill, public_key: public_key)

      if result[:valid]
        record_chain_event(
          event_type: 'update',
          skill_id: skill_id,
          skill_name: skill[:name],
          content_hash: skill[:content_hash],
          participants: [agent_id],
          extra: {
            depositor_id: agent_id,
            previous_hash: previous_hash,
            reason_hash: reason.empty? ? nil : Digest::SHA256.hexdigest(reason)
          }
        )

        json_response(200, {
          status: 'updated',
          skill_id: skill_id,
          previous_hash: previous_hash,
          new_hash: skill[:content_hash],
          updated_at: Time.now.utc.iso8601,
          chain_recorded: @trust_anchor_client ? 'attempted' : false
        })
      else
        json_response(422, { error: 'update_rejected', reasons: result[:errors] })
      end
    end

    # GET /place/v1/preview/:skill_id — Bearer token required
    # Preview a deposited skill without full content download
    def handle_preview(env, path)
      skill_id = URI.decode_www_form_component(path.sub('/place/v1/preview/', ''))
      params = parse_query(env)
      owner = params['owner']
      first_lines = [[((params['first_lines'] || 30).to_i), 1].max, SkillBoard::MAX_PREVIEW_LINES].min

      preview = @skill_board.preview_skill(skill_id, owner_agent_id: owner, first_lines: first_lines)

      if preview
        json_response(200, preview)
      else
        json_response(404, { error: 'not_found', message: "No deposited skill found: #{skill_id}" })
      end
    end

    # Record deposit/acquire events on the private chain (non-blocking).
    # Gracefully degrades if trust_anchor_client is unavailable.
    def record_chain_event(event_type:, skill_id:, skill_name:, content_hash:, participants:, extra: {})
      return unless @trust_anchor_client

      begin
        timestamp = Time.now.utc.iso8601
        meeting_protocol = Chain::Integrations::MeetingProtocol.new(client: @trust_anchor_client)
        meeting_protocol.anchor_skill_exchange({
          skill_name: skill_name,
          skill_hash: content_hash,
          peer_id: participants.first,
          direction: event_type
        }, async: true)
      rescue StandardError => e
        $stderr.puts "[PlaceRouter] Chain recording failed (non-fatal): #{e.message}"
      end
    end

    # --- Auth ---

    # Authenticate the request and return identity on success.
    # Returns a Rack response array on failure.
    #
    # @param env [Hash] Rack environment
    # @return [Hash, Array] { peer_id:, auth_token: } on success, Rack response on failure
    def authenticate!(env)
      token = extract_bearer_token(env)
      unless token
        return json_response(401, {
          error: 'authentication_required',
          message: 'Bearer token required. Register first to obtain a session token.'
        })
      end

      peer_id = @session_store.validate(token)
      unless peer_id
        return json_response(401, {
          error: 'invalid_or_expired_token',
          message: 'Session token is invalid or has expired.'
        })
      end

      # Honour only sessions this Place issued: their pubkey_hash is the hash
      # of the id's binding. Sessions minted elsewhere in the shared store
      # (core P2P introduce) carry none and are refused here.
      bound = @registry.bound_key(peer_id)
      session_hash = @session_store.pubkey_hash_for_token(token)
      issued_here = @session_store.respond_to?(:issuer_for_token) && @session_store.issuer_for_token(token) == SESSION_ISSUER
      unless issued_here && bound && session_hash && session_hash == Digest::SHA256.hexdigest(bound)
        return json_response(401, {
          error: 'invalid_or_expired_token',
          message: 'Session token was not issued by this Meeting Place. Register first to obtain a session token.'
        })
      end

      unless @session_store.check_rate_limit(token)
        return json_response(429, { error: 'rate_limited', message: 'Too many requests.' })
      end

      # Update heartbeat on any authenticated request
      @heartbeat_manager.touch(peer_id)

      { peer_id: peer_id, auth_token: token }
    end

    def extract_bearer_token(env)
      auth = env['HTTP_AUTHORIZATION'] || ''
      return nil unless auth.start_with?('Bearer ')
      auth.sub('Bearer ', '').strip
    end

    # --- Helpers ---

    # Marks sessions this Place issued in the shared session store; sessions
    # from other issuers (core P2P introduce) carry another value or none.
    SESSION_ISSUER = 'hestia.place'
    REGISTRATION_MAX_AGE = 300
    REGISTRATION_FUTURE_SKEW = 30

    # This Place's https origin, from meeting_place.web_ui.place_host.
    def own_origin
      host = (@config['meeting_place'] || {}).dig('web_ui', 'place_host')
      ::MMP::RegistrationProof.origin_for_host(host)
    end

    # The proof must be addressed to this Place's own https origin; without a
    # configured host only loopback origins are accepted (local development).
    def audience_acceptable?(audience)
      origin = own_origin
      return audience == origin if origin

      ::MMP::RegistrationProof.loopback?(audience)
    end

    # @return [String, nil] why the key cannot claim the id, or nil when every
    #   item held under the id carries a signature that verifies with it.
    def unproven_holdings(agent_id, public_key)
      missing = unmounted_extension_classes
      unless missing.empty?
        if missing != @last_logged_unmounted
          $stderr.puts "[PlaceRouter] Claims of new agent ids suspended: unmounted place extension(s) #{missing.join(', ')}"
          @last_logged_unmounted = missing
        end
        return "Claims of new agent ids are suspended: place extension #{missing.join(', ')} is declared " \
               'but not mounted, so what it holds cannot be checked. Ask the Meeting Place operator.'
      end

      evidence = @skill_board.holdings_evidence(agent_id)
      @extensions.each { |ext| evidence.concat(Array(ext.holdings_evidence(agent_id))) }
      return nil if evidence.empty?

      crypto = ::MMP::Crypto.new(auto_generate: false)
      proven = evidence.all? do |data, signature|
        next false if data.nil? || signature.nil?

        begin
          crypto.verify_signature(data, signature, public_key)
        rescue StandardError
          false
        end
      end
      return nil if proven

      "Items are held under #{agent_id} that this key did not sign. Ask the Meeting Place operator."
    end

    # Place extension classes declared by enabled SkillSets but not mounted —
    # refused (no holdings_evidence), failed to load, or not yet registered.
    # Their holdings cannot be asked, so an unbound id cannot be claimed.
    def unmounted_extension_classes
      mounted = @extensions.map { |e| e.class.name }
      declared_extension_classes.reject { |name| mounted.include?(name) }
    end

    def declared_extension_classes
      return Array(@declared_extension_classes_source.call) if @declared_extension_classes_source

      now = Time.now
      if @declared_cache && now - @declared_cache[0] < 60
        return @declared_cache[1]
      end

      list = read_declared_extension_classes
      @declared_cache = [now, list]
      list
    end

    def read_declared_extension_classes
      return [] unless defined?(KairosMcp)

      require 'kairos_mcp/skillset_manager'
      KairosMcp::SkillSetManager.new.enabled_skillsets.flat_map do |ss|
        ss.place_extensions.map { |ext_def| ext_def['class'].to_s.sub(/\A::/, '') }
      end
    rescue StandardError => e
      $stderr.puts "[PlaceRouter] Cannot list declared place extensions: #{e.message}"
      ['(unknown: extension list unavailable)']
    end

    # Refuse a body agent_id naming an id other than the session's.
    def foreign_agent_id_refusal(claimed, peer_id)
      return nil if claimed.nil? || claimed == peer_id

      json_response(403, { error: 'agent_id_mismatch',
                           message: 'Requests act on the session agent id; agent_id names another id' })
    end

    def parse_body(env)
      body = env['rack.input']&.read
      return {} if body.nil? || body.empty?
      JSON.parse(body, symbolize_names: false)
    rescue JSON::ParserError
      {}
    end

    def parse_query(env)
      query = env['QUERY_STRING'] || ''
      URI.decode_www_form(query).to_h
    rescue StandardError
      {}
    end

    def symbolize_provenance(prov)
      return nil unless prov.is_a?(Hash)
      {
        origin_place_id: prov['origin_place_id'],
        origin_agent_id: prov['origin_agent_id'],
        via: prov['via'] || [],
        hop_count: prov['hop_count'].to_i,
        deposited_at_origin: prov['deposited_at_origin']
      }
    end

    def json_response(status, body)
      [status, JSON_HEADERS, [body.to_json]]
    end

    # Extract route segment from path for action mapping.
    # For parameterized routes (/keys/:id, /skill_content/:id), falls back to
    # the first segment when the last segment is not a known action.
    def extract_route_segment(path)
      segments = path.sub('/place/v1/', '').split('/')
      candidate = segments.last || ''
      ROUTE_ACTION_MAP.key?(candidate) ? candidate : (segments.first || '')
    end

    # Map route segment to abstract action name for access control.
    # Checks built-in ROUTE_ACTION_MAP first, then extension action map.
    def resolve_action(route_segment)
      ROUTE_ACTION_MAP[route_segment] || @extension_action_map[route_segment] || route_segment
    end

    # Run registered place middlewares. Returns nil if all pass,
    # or a denial Hash if any middleware denies.
    def run_place_middlewares(peer_id, action, service, auth_token: nil, remote_ip: nil)
      self.class.place_middlewares.each do |mw|
        # Inject session_store if middleware accepts it (e.g., ServiceGrant::PlaceMiddleware)
        mw.session_store = @session_store if mw.respond_to?(:session_store=)
        result = mw.check(peer_id: peer_id, action: action, service: service,
                          auth_token: auth_token, remote_ip: remote_ip)
        return result if result
      end
      nil
    end

    # Dispatch request to registered extensions.
    # Returns Rack response if an extension handles it, nil otherwise.
    def dispatch_extensions(env, peer_id:)
      @extensions.each do |ext|
        result = ext.call(env, peer_id: peer_id)
        return result if result
      end
      nil
    end

    # Service name for this Meeting Place instance
    def service_name
      @config.dig('meeting_place', 'service_name') || 'meeting_place'
    end
  end
end
