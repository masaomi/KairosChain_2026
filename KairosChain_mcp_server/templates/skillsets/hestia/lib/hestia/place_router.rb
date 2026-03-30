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

    attr_reader :registry, :skill_board, :heartbeat_manager, :session_store, :started_at,
                :web_router, :auditor

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
    # @param trust_scorer [Synoptis::TrustScorer, nil] Optional Synoptis trust scorer (DI)
    # @return [Hash] Start result
    def start(identity:, session_store:, trust_anchor_client: nil, trust_scorer: nil)
      place_config = @config['meeting_place'] || {}
      # Resolve storage paths relative to KairosMcp.data_dir (ensures Docker volume persistence)
      default_storage = defined?(KairosMcp) ? File.join(KairosMcp.storage_dir, '') : 'storage/'
      registry_path = place_config['registry_path'] || "#{default_storage}agent_registry.json"

      @session_store = session_store
      @trust_anchor_client = trust_anchor_client
      @registry = AgentRegistry.new(registry_path: registry_path, config: place_config)
      intro = identity.introduce
      @self_id = intro.dig(:identity, :instance_id)

      # Initialize SkillAuditor before SkillBoard (SkillBoard needs auditor DI)
      audit_config = place_config['skill_audit'] || {}
      if audit_config['enabled']
        audit_persist = audit_config['persist_path'] || "#{default_storage}audit_results.json"
        @auditor = SkillAuditor.new(
          config: audit_config,
          attestation_engine: nil,  # injected later if Synoptis loaded
          persist_path: audit_persist
        )
      end

      deposit_policy = place_config['deposit_policy'] || {}
      deposit_storage = place_config['deposit_storage_path'] || "#{default_storage}skill_board_state.json"
      federation_config = place_config['federation'] || {}
      @skill_board = SkillBoard.new(
        registry: @registry,
        config: deposit_policy,
        storage_path: deposit_storage,
        self_place_id: @self_id,
        federation_config: federation_config,
        trust_scorer: trust_scorer,
        auditor: @auditor,
        audit_config: audit_config
      )

      @heartbeat_manager = HeartbeatManager.new(
        registry: @registry,
        trust_anchor: trust_anchor_client,
        ttl_seconds: place_config['session_timeout'] || 3600,
        observer_id: @self_id
      )

      # Self-register: the Place IS also a participant (主客未分)
      @registry.self_register(identity)

      # Initialize WebRouter for public web UI and API
      web_config = {
        'name' => place_config['name'] || 'KairosChain Meeting Place',
        'place_url' => place_config['place_url'] || "http://localhost:8080",
        'preview_lines' => place_config.dig('web_ui', 'preview_lines') || 20
      }
      @web_router = WebRouter.new(
        skill_board: @skill_board,
        agent_registry: @registry,
        auditor: @auditor,
        config: web_config
      )

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

      # Public web UI and API — no authentication required
      if path.start_with?('/place/web/') || path.start_with?('/place/web') ||
         path.start_with?('/place/api/')
        return @web_router.call(env) if @web_router
        return json_response(404, { error: 'web_ui_not_available' })
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
        handle_unregister(env)
      when ['GET', '/place/v1/agents']
        handle_list_agents(env)
      when ['GET', '/place/v1/board/browse']
        handle_browse(env)
      when ['POST', '/place/v1/board/needs']
        handle_post_needs(env)
      when ['DELETE', '/place/v1/board/needs']
        handle_delete_needs(env)
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
        federation_cleanup: cleanup_result
      }
    end

    private

    # --- Handlers ---

    # GET /place/v1/info — Public, no auth
    def handle_info
      place_config = @config['meeting_place'] || {}
      json_response(200, {
        place_id: @self_id,
        name: place_config['name'] || 'KairosChain Meeting Place',
        version: Hestia::VERSION,
        registered_agents: @registry.count,
        max_agents: place_config['max_agents'] || 100,
        started_at: @started_at&.iso8601,
        deposit_limits: @skill_board&.deposit_limits,
        session_rate_limit_per_minute: place_config['session_rate_limit'] || 100
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

      # Register the agent (with enhanced profile fields)
      agent_description = body['description'] || identity_data&.dig('description')
      agent_scope = body['scope'] || identity_data&.dig('scope')

      result = @registry.register(
        id: agent_id,
        name: agent_name,
        capabilities: capabilities,
        public_key: public_key,
        is_self: false,
        description: agent_description,
        scope: agent_scope
      )

      # Issue session token if signature was verified
      session_token = nil
      if verified
        pubkey_hash = public_key ? Digest::SHA256.hexdigest(public_key) : nil
        session_token = @session_store.create_session(agent_id, public_key, pubkey_hash: pubkey_hash)
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
    # Publish knowledge needs to the board (session-only, in-memory)
    def handle_post_needs(env)
      body = parse_body(env)
      agent_id = body['agent_id']
      agent_name = body['agent_name'] || 'Unknown Agent'
      agent_mode = body['agent_mode'] || 'unknown'
      needs = body['needs'] || []

      unless agent_id
        return json_response(400, { error: 'missing_agent_id', message: 'agent_id is required' })
      end

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
    # Remove all needs posted by an agent
    def handle_delete_needs(env)
      body = parse_body(env)
      agent_id = body['agent_id']

      unless agent_id
        return json_response(400, { error: 'missing_agent_id', message: 'agent_id is required' })
      end

      @skill_board.remove_needs(agent_id)

      json_response(200, { status: 'removed', agent_id: agent_id })
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
    def resolve_action(route_segment)
      ROUTE_ACTION_MAP[route_segment] || route_segment
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

    # Service name for this Meeting Place instance
    def service_name
      @config.dig('meeting_place', 'service_name') || 'meeting_place'
    end
  end
end
