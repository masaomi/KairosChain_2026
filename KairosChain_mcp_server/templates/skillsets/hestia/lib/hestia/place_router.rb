# frozen_string_literal: true

require 'json'

module Hestia
  # PlaceRouter handles Meeting Place HTTP endpoints under /place/v1/*.
  #
  # Architecture A: embedded in HttpServer (same pattern as MeetingRouter).
  # Reuses MMP::MeetingSessionStore for Bearer token auth.
  #
  # Unauthenticated: GET /place/v1/info
  # RSA-verified:    POST /place/v1/register
  # Bearer-token:    POST /place/v1/unregister, GET /place/v1/agents,
  #                  GET /place/v1/board/browse, GET /place/v1/keys/:id
  class PlaceRouter
    JSON_HEADERS = {
      'Content-Type' => 'application/json',
      'Cache-Control' => 'no-cache'
    }.freeze

    attr_reader :registry, :skill_board, :heartbeat_manager, :session_store, :started_at

    def initialize(config: nil)
      @config = config || ::Hestia.load_config
      @registry = nil
      @skill_board = nil
      @heartbeat_manager = nil
      @session_store = nil
      @started = false
      @started_at = nil
      @self_id = nil
    end

    # Start the Meeting Place: initialize components and self-register.
    #
    # @param identity [MMP::Identity] This instance's identity
    # @param session_store [MMP::MeetingSessionStore] Reuse MeetingRouter's store
    # @param trust_anchor_client [Hestia::Chain::Core::Client, nil] For recording observations
    # @return [Hash] Start result
    def start(identity:, session_store:, trust_anchor_client: nil)
      place_config = @config['meeting_place'] || {}
      registry_path = place_config['registry_path'] || 'storage/agent_registry.json'

      @session_store = session_store
      @registry = AgentRegistry.new(registry_path: registry_path, config: place_config)
      @skill_board = SkillBoard.new(registry: @registry)

      intro = identity.introduce
      @self_id = intro.dig(:identity, :instance_id)

      @heartbeat_manager = HeartbeatManager.new(
        registry: @registry,
        trust_anchor: trust_anchor_client,
        ttl_seconds: place_config['session_timeout'] || 3600,
        observer_id: @self_id
      )

      # Self-register: the Place IS also a participant (主客未分)
      @registry.self_register(identity)

      @started = true
      @started_at = Time.now.utc

      {
        status: 'started',
        place_name: place_config['name'] || 'KairosChain Meeting Place',
        self_id: @self_id,
        registered_agents: @registry.count
      }
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

      # Unauthenticated endpoints
      if request_method == 'GET' && path == '/place/v1/info'
        return handle_info
      end

      # RSA-verified registration
      if request_method == 'POST' && path == '/place/v1/register'
        return handle_register(env)
      end

      # All other endpoints require Bearer token
      auth_result = authenticate!(env)
      return auth_result unless auth_result.nil?

      case [request_method, path]
      when ['POST', '/place/v1/unregister']
        handle_unregister(env)
      when ['GET', '/place/v1/agents']
        handle_list_agents(env)
      when ['GET', '/place/v1/board/browse']
        handle_browse(env)
      else
        # Check for /place/v1/keys/:id pattern
        if request_method == 'GET' && path.start_with?('/place/v1/keys/')
          handle_get_key(path)
        else
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
        last_heartbeat_check: heartbeat_result
      }
    end

    private

    # --- Handlers ---

    # GET /place/v1/info — Public, no auth
    def handle_info
      place_config = @config['meeting_place'] || {}
      json_response(200, {
        name: place_config['name'] || 'KairosChain Meeting Place',
        version: Hestia::VERSION,
        registered_agents: @registry.count,
        max_agents: place_config['max_agents'] || 100,
        started_at: @started_at&.iso8601
      })
    end

    # POST /place/v1/register — RSA signature verification
    def handle_register(env)
      body = parse_body(env)
      agent_id = body['id']
      agent_name = body['name'] || 'Unknown Agent'
      capabilities = body['capabilities']
      public_key = body['public_key']
      identity_data = body['identity']
      signature = body['identity_signature']

      unless agent_id
        return json_response(400, { error: 'missing_id', message: 'Agent id is required' })
      end

      # Check max agents
      place_config = @config['meeting_place'] || {}
      max = place_config['max_agents'] || 100
      if @registry.count >= max
        return json_response(503, { error: 'place_full', message: "Meeting Place is full (max #{max} agents)" })
      end

      # RSA signature verification (if provided)
      verified = false
      if public_key && signature && identity_data
        begin
          canonical = JSON.generate(identity_data, sort_keys: true)
          crypto = ::MMP::Crypto.new(auto_generate: false)
          verified = crypto.verify_signature(canonical, signature, public_key)
        rescue StandardError => e
          $stderr.puts "[PlaceRouter] Signature verification failed: #{e.message}"
        end
      end

      # Register the agent
      result = @registry.register(
        id: agent_id,
        name: agent_name,
        capabilities: capabilities,
        public_key: public_key,
        is_self: false
      )

      # Issue session token if signature was verified
      session_token = nil
      if verified
        session_token = @session_store.create_session(agent_id, public_key)
      end

      response = result.merge(identity_verified: verified)
      response[:session_token] = session_token if session_token

      json_response(200, response)
    end

    # POST /place/v1/unregister — Bearer token required
    def handle_unregister(env)
      body = parse_body(env)
      agent_id = body['agent_id']
      unless agent_id
        return json_response(400, { error: 'missing_agent_id', message: 'agent_id is required' })
      end

      result = @registry.unregister(agent_id)

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
      limit = (params['limit'] || SkillBoard::DEFAULT_MAX_RESULTS).to_i

      result = @skill_board.browse(type: type, search: search, limit: limit)
      json_response(200, result)
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

    # --- Auth ---

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

      unless @session_store.check_rate_limit(token)
        return json_response(429, { error: 'rate_limited', message: 'Too many requests.' })
      end

      # Update heartbeat on any authenticated request
      @heartbeat_manager.touch(peer_id)

      nil # Auth passed
    end

    def extract_bearer_token(env)
      auth = env['HTTP_AUTHORIZATION'] || ''
      return nil unless auth.start_with?('Bearer ')
      auth.sub('Bearer ', '').strip
    end

    # --- Helpers ---

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

    def json_response(status, body)
      [status, JSON_HEADERS, [body.to_json]]
    end
  end
end
