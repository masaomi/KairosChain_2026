# frozen_string_literal: true

require 'json'
require 'uri'

module KairosMcp
  # MeetingRouter handles MMP (Model Meeting Protocol) HTTP endpoints
  # for P2P direct mode communication between KairosChain instances.
  #
  # Endpoints are mounted under /meeting/v1/ on the HTTP server.
  # These are only active when the MMP SkillSet is installed and enabled.
  class MeetingRouter
    JSON_HEADERS = {
      'Content-Type' => 'application/json',
      'Cache-Control' => 'no-cache'
    }.freeze

    # Largest POST body accepted on /meeting/v1/* (secure MMP v1). An encrypted
    # peer message of the sender's maximum size fits; the sender checks the
    # encrypted size it is about to send.
    MAX_BODY_BYTES = 256 * 1024

    # Keys the router alone sets on messages it hands to extension handlers.
    RESERVED_PREFIXES = %w[_authenticated _admitted].freeze

    # One answer for every SkillSet that is not served, so the private set
    # cannot be enumerated by probing names.
    SKILLSET_NOT_FOUND = { error: 'not_found', message: 'SkillSet not found' }.freeze

    # @param admission [Hash, nil] { policy:, origins:, started_at: } from the
    #   listener's launch arguments. nil or policy 'open' keeps the open path.
    # mmp versions older than this lack the card, proof and admission code
    # this router calls; with one installed, /meeting/* answers 503 rather
    # than falling back to a card that would disclose private entries.
    MIN_MMP_VERSION = '1.3.0'

    def initialize(admission: nil)
      @protocol = nil
      @identity = nil
      @exchange = nil
      @session_store = nil
      @admission = admission || {}
      @direct_session = nil
      @memo_mutex = Mutex.new
    end

    attr_reader :admission

    # True when the listener was started with a policy other than open.
    def restricted?
      policy = @admission[:policy].to_s
      !policy.empty? && policy != 'open'
    end

    def call(env)
      return unavailable_response unless mmp_available?
      return upgrade_required_response unless mmp_current?

      request_method = env['REQUEST_METHOD']
      path = env['PATH_INFO']

      if request_method == 'POST'
        refused = load_body(env)
        return refused if refused
      end

      # Unauthenticated endpoints
      case [request_method, path]
      when ['GET', '/meeting/v1/introduce']
        return handle_get_introduce
      when ['POST', '/meeting/v1/introduce']
        return handle_post_introduce(env)
      when ['POST', '/meeting/v1/goodbye']
        return handle_goodbye(env)
      end

      # All other endpoints require Bearer token authentication
      auth_result = authenticate_meeting_request!(env)
      return auth_result unless auth_result.nil?

      case [request_method, path]
      when ['POST', '/meeting/v1/message']
        handle_message(env)
      when ['GET', '/meeting/v1/skills']
        handle_list_skills
      when ['GET', '/meeting/v1/skill_details']
        handle_skill_details(env)
      when ['POST', '/meeting/v1/skill_content']
        handle_skill_content(env)
      when ['POST', '/meeting/v1/request_skill']
        handle_request_skill(env)
      when ['POST', '/meeting/v1/reflect']
        handle_reflect(env)
      when ['GET', '/meeting/v1/skillsets']
        handle_list_skillsets
      when ['GET', '/meeting/v1/skillset_details']
        handle_skillset_details(env)
      when ['POST', '/meeting/v1/skillset_content']
        handle_skillset_content(env)
      else
        json_response(404, { error: 'not_found', message: "Unknown meeting endpoint: #{path}" })
      end
    rescue StandardError => e
      $stderr.puts "[MeetingRouter] Error: #{e.message}"
      $stderr.puts e.backtrace&.first(3)&.join("\n")
      json_response(500, { error: 'internal_error', message: 'An internal error occurred while processing the request' })
    end

    def reload_protocol
      @protocol = nil
    end

    # Public accessor for session store (testing). Built once under a lock:
    # two stores would orphan the tokens issued into one of them.
    def session_store
      @session_store || @memo_mutex.synchronize do
        @session_store ||= begin
          require_relative '../../templates/skillsets/mmp/lib/mmp/meeting_session_store'
          MMP::MeetingSessionStore.new
        end
      end
    end

    # True when the installed mmp provides what this router calls.
    def mmp_current?
      return false unless defined?(::MMP::VERSION)

      Gem::Version.new(::MMP::VERSION) >= Gem::Version.new(MIN_MMP_VERSION)
    rescue ArgumentError
      false
    end

    private

    def mmp_available?
      return false unless defined?(::MMP)

      config = ::MMP.load_config
      config['enabled'] == true
    rescue StandardError
      false
    end

    def unavailable_response
      json_response(503, {
        error: 'mmp_unavailable',
        message: 'MMP SkillSet is not installed or not enabled'
      })
    end

    def upgrade_required_response
      json_response(503, {
        error: 'mmp_upgrade_required',
        message: "The installed mmp SkillSet is older than #{MIN_MMP_VERSION}; run `kairos-chain upgrade --apply`."
      })
    end

    def identity
      @identity ||= ::MMP::Identity.new(
        workspace_root: KairosMcp.data_dir,
        config: ::MMP.load_config,
        auto_generate_key: !restricted?
      )
    end

    def protocol
      @protocol ||= ::MMP::Protocol.new(
        identity: identity,
        knowledge_root: mmp_knowledge_root,
        additional_knowledge_roots: depends_on_knowledge_roots
      )
    end

    def depends_on_knowledge_roots
      mmp_dir = File.join(KairosMcp.skillsets_dir, 'mmp')
      return [] unless File.exist?(File.join(mmp_dir, 'skillset.json'))
      config = JSON.parse(File.read(File.join(mmp_dir, 'skillset.json')))
      deps = config['depends_on'] || []
      deps.filter_map do |dep|
        dep_name = dep.is_a?(Hash) ? dep['name'] : dep
        dep_knowledge = File.join(KairosMcp.skillsets_dir, dep_name, 'knowledge')
        dep_knowledge if File.directory?(dep_knowledge)
      end
    rescue StandardError
      []
    end

    def exchange
      @exchange ||= ::MMP::SkillExchange.new(
        config: ::MMP.load_config,
        workspace_root: KairosMcp.data_dir
      )
    end

    def mmp_knowledge_root
      # Look for MMP SkillSet knowledge in installed location
      ss_dir = File.join(KairosMcp.skillsets_dir, 'mmp', 'knowledge')
      return ss_dir if File.directory?(ss_dir)

      KairosMcp.knowledge_dir
    end

    # GET /meeting/v1/introduce - Return self-introduction
    def handle_get_introduce
      json_response(200, card)
    end

    # The public card (I1): public L1 entries without paths, published
    # SkillSets, and only the actions the operator declared plus public
    # protocol-loader extensions — never actions registered by SkillSets.
    def card
      intro = identity.introduce
      declared = identity.capabilities_info[:supported_actions]
      ext_info = protocol.public_extension_info
      intro[:capabilities] = identity.capabilities_info(extensions: ext_info)
      intro[:capabilities][:supported_actions] = protocol.public_supported_actions(declared)
      intro
    end

    # POST /meeting/v1/introduce - Receive introduction from peer
    # If RSA signature verification succeeds, a session token is issued.
    # Under a restricted policy, issuance belongs to MMP::DirectSession.
    def handle_post_introduce(env)
      body = env['meeting.body']
      return handle_restricted_introduce(env, body) if restricted?

      # Signature verification (H2 fix: verify identity if signed)
      verified = false
      peer_id = body['identity'].is_a?(Hash) ? body['identity']['instance_id'] : nil
      public_key = body['public_key']

      if public_key.is_a?(String) && body['identity_signature'].is_a?(String) && body['identity'].is_a?(Hash)
        begin
          canonical = JSON.generate(body['identity'], sort_keys: true)
          crypto = MMP::Crypto.new(auto_generate: false)
          verified = crypto.verify_signature(canonical, body['identity_signature'], public_key)
        rescue StandardError => e
          $stderr.puts "[MeetingRouter] Signature verification failed: #{e.message}"
        end
      end

      result = protocol.process_message(body.merge('action' => 'introduce'))

      response = {
        status: 'received',
        peer_identity: card,
        identity_verified: verified,
        result: result
      }

      # Issue session token if signature was verified
      if verified && peer_id
        token = session_store.create_session(peer_id, public_key)
        response[:session_token] = token
      end

      json_response(200, response)
    end

    # POST /meeting/v1/goodbye - Revoke session token
    def handle_goodbye(env)
      token = extract_bearer_token(env)
      if token && restricted? && session_store.session_record(token)&.dig(:issuer) != 'mmp.direct'
        # Under an admission policy this router ends only sessions it issued.
        json_response(401, { error: 'invalid_or_expired_token', message: 'Unknown session' })
      elsif token
        session_store.revoke(token)
        json_response(200, { status: 'goodbye', message: 'Session ended' })
      else
        json_response(400, { error: 'no_token', message: 'No session token provided' })
      end
    end

    def handle_restricted_introduce(env, body)
      session = direct_session
      return json_response(403, { error: 'admission_refused' }) unless session

      status, response = session.admit(body, remote_addr: env['REMOTE_ADDR'])
      response = response.merge(peer_identity: identity.minimal_introduce) if status == 200
      json_response(status, response)
    end

    # MMP::DirectSession for this listener's policy, or nil when the installed
    # mmp does not provide it (then nothing is admitted).
    def direct_session
      return nil unless defined?(::MMP::DirectSession) && defined?(::MMP::Admission)

      return @direct_session if @direct_session

      store = session_store # resolved outside the lock it also takes
      @memo_mutex.synchronize do
        # One instance, so one nonce store: two would let a proof be used twice.
        @direct_session ||= ::MMP::DirectSession.new(
          policy: @admission[:policy],
          origins: @admission[:origins],
          started_at: @admission[:started_at] || Time.now.utc,
          session_store: store
        )
      end
    end

    # POST /meeting/v1/message - Generic MMP message handler
    # Hands extension handlers a fresh Hash: the peer's fields without any
    # reserved key, then the router's own attribution merged last (I3).
    def handle_message(env)
      body = env['meeting.body']
      message = body.reject { |k, _| RESERVED_PREFIXES.any? { |prefix| k.to_s.start_with?(prefix) } }
      message = message.merge(
        '_authenticated_peer_id' => env['meeting.authenticated_peer_id'],
        '_authenticated_peer_key_sha256' => env['meeting.authenticated_key_sha256'],
        '_admitted_as' => env['meeting.admitted_as']
      )
      result = protocol.process_message(message)
      json_response(200, result)
    end

    # GET /meeting/v1/skills - List available public skills
    def handle_list_skills
      skills = identity.public_skills.map do |s|
        {
          id: s[:id],
          name: s[:name],
          layer: s[:layer],
          format: s[:format],
          summary: s[:summary],
          tags: extract_tags(s),
          content_hash: s[:content_hash]
        }
      end

      json_response(200, { skills: skills, count: skills.size })
    end

    # GET /meeting/v1/skill_details?skill_id=xxx
    def handle_skill_details(env)
      params = parse_query(env)
      skill_id = params['skill_id']

      unless skill_id
        return json_response(400, { error: 'missing_param', message: 'skill_id is required' })
      end

      skills = identity.public_skills
      skill = skills.find { |s| s[:id] == skill_id || s[:name] == skill_id }

      unless skill
        return json_response(404, { error: 'not_found', message: "Skill not found: #{skill_id}" })
      end

      metadata = {
        id: skill[:id],
        name: skill[:name],
        layer: skill[:layer],
        format: skill[:format],
        summary: skill[:summary],
        content_hash: skill[:content_hash],
        available: true
      }

      json_response(200, { metadata: metadata })
    end

    # POST /meeting/v1/skill_content - Send skill content to requester
    def handle_skill_content(env)
      body = env['meeting.body']
      skill_id = body['skill_id'] || body[:skill_id]

      unless skill_id
        return json_response(400, { error: 'missing_param', message: 'skill_id is required' })
      end

      skills = identity.public_skills
      skill = skills.find { |s| s[:id] == skill_id || s[:name] == skill_id }

      unless skill
        return json_response(404, { error: 'not_found', message: "Skill not found: #{skill_id}" })
      end

      content = skill[:path] && File.exist?(skill[:path]) ? File.read(skill[:path]) : nil

      unless content
        return json_response(404, { error: 'content_unavailable', message: "Skill content unavailable" })
      end

      message = protocol.create_skill_content(
        in_reply_to: body['in_reply_to'] || body[:in_reply_to] || 'direct_request',
        to: body['to'] || body[:to] || 'requester',
        skill_id: skill_id,
        content: content
      )

      packaged = exchange.package_skill(skill[:path])

      json_response(200, {
        message: message.to_h,
        packaged_skill: packaged
      })
    end

    # POST /meeting/v1/request_skill - Receive a skill request
    def handle_request_skill(env)
      body = env['meeting.body']
      result = protocol.process_message({
        action: 'request_skill',
        from: body['from'] || body[:from],
        payload: { description: body['description'] || body[:description], skill_id: body['skill_id'] || body[:skill_id] }
      })

      json_response(200, result)
    end

    # POST /meeting/v1/reflect - Receive a reflection message
    def handle_reflect(env)
      body = env['meeting.body']
      result = protocol.process_message({
        action: 'reflect',
        from: body['from'] || body[:from],
        in_reply_to: body['in_reply_to'] || body[:in_reply_to],
        payload: { reflection: body['reflection'] || body[:reflection] }
      })

      json_response(200, result)
    end

    # GET /meeting/v1/skillsets - List exchangeable SkillSets
    def handle_list_skillsets
      return skillset_exchange_disabled_response unless skillset_exchange_enabled?

      manager = skillset_manager
      exchangeable = manager.all_skillsets.select { |ss| served_skillset?(ss) }

      skillsets = exchangeable.map do |ss|
        {
          name: ss.name,
          version: ss.version,
          layer: ss.layer.to_s,
          description: ss.description,
          knowledge_only: true,
          content_hash: ss.content_hash,
          file_count: ss.file_list.size
        }
      end

      json_response(200, { skillsets: skillsets, count: skillsets.size })
    end

    # GET /meeting/v1/skillset_details?name=xxx
    def handle_skillset_details(env)
      return skillset_exchange_disabled_response unless skillset_exchange_enabled?

      params = parse_query(env)
      name = params['name']

      unless name
        return json_response(400, { error: 'missing_param', message: 'name is required' })
      end

      manager = skillset_manager
      skillset = manager.find_skillset(name)
      return json_response(404, SKILLSET_NOT_FOUND) unless served_skillset?(skillset)

      json_response(200, {
        metadata: {
          name: skillset.name,
          version: skillset.version,
          layer: skillset.layer.to_s,
          description: skillset.description,
          author: skillset.author,
          depends_on: skillset.depends_on,
          provides: skillset.provides,
          content_hash: skillset.content_hash,
          file_list: skillset.file_list,
          knowledge_only: true,
          exchangeable: true
        }
      })
    end

    # POST /meeting/v1/skillset_content - Send a packaged SkillSet archive
    def handle_skillset_content(env)
      return skillset_exchange_disabled_response unless skillset_exchange_enabled?

      body = env['meeting.body']
      name = body['name'] || body[:name]

      unless name
        return json_response(400, { error: 'missing_param', message: 'name is required' })
      end

      manager = skillset_manager
      return json_response(404, SKILLSET_NOT_FOUND) unless served_skillset?(manager.find_skillset(name))

      begin
        pkg = manager.package(name)
        # Publication is checked again against the content actually packaged,
        # so a change between the first check and packaging serves nothing.
        require_relative 'admission_records'
        unless AdmissionRecords.for_data_dir.published?(name, pkg[:content_hash])
          return json_response(404, SKILLSET_NOT_FOUND)
        end

        json_response(200, { skillset_package: pkg })
      rescue SecurityError, ArgumentError
        json_response(404, SKILLSET_NOT_FOUND)
      end
    end

    # Served in direct mode only when exchangeable and its latest signed
    # publication record names its current content (I1, I4).
    def served_skillset?(skillset)
      return false unless skillset&.exchangeable?

      require_relative 'admission_records'
      AdmissionRecords.for_data_dir.published?(skillset.name, skillset.content_hash)
    rescue StandardError
      false
    end

    def skillset_manager
      require_relative 'skillset_manager'
      KairosMcp::SkillSetManager.new
    end

    def skillset_exchange_enabled?
      config = ::MMP.load_config
      ss_config = config['skillset_exchange'] || {}
      ss_config['enabled'] != false
    rescue StandardError
      false
    end

    def skillset_exchange_disabled_response
      json_response(403, {
        error: 'skillset_exchange_disabled',
        message: 'SkillSet exchange is not enabled in MMP configuration'
      })
    end

    # --- Authentication ---

    # Authenticate a meeting request via Bearer token.
    # Returns nil if authenticated, or an error response triple if not.
    def authenticate_meeting_request!(env)
      token = extract_bearer_token(env)

      unless token
        return json_response(401, {
          error: 'authentication_required',
          message: 'Bearer token required. Use POST /meeting/v1/introduce to obtain a session token.'
        })
      end

      peer_id = session_store.validate(token)
      unless peer_id
        return json_response(401, {
          error: 'invalid_or_expired_token',
          message: 'Session token is invalid or has expired. Re-introduce to obtain a new token.'
        })
      end

      unless session_store.check_rate_limit(token)
        return json_response(429, {
          error: 'rate_limited',
          message: 'Too many requests. Please wait before retrying.'
        })
      end

      if restricted?
        refused = authorize_restricted(env, token)
        return refused if refused
      else
        record = session_store.session_record(token)
        env['meeting.authenticated_key_sha256'] = record && record[:key_sha256]
      end

      env['meeting.authenticated_peer_id'] = peer_id
      nil # Authentication passed
    end

    # Under a restricted policy only sessions this router issued count, and
    # each request is decided again (I2). Tokens from other issuers (a Meeting
    # Place on the same host) are refused and never revoked.
    def authorize_restricted(env, token)
      record = session_store.session_record(token)
      unless record && record[:issuer] == 'mmp.direct'
        return json_response(401, { error: 'invalid_or_expired_token', message: 'Re-introduce to obtain a new token.' })
      end

      session = direct_session
      return json_response(403, { error: 'admission_refused' }) unless session

      result = session.authorize(record)
      unless result[:ok]
        session_store.revoke(token) if result[:revoke]
        return json_response(result[:status], { error: result[:error] })
      end

      env['meeting.authenticated_key_sha256'] = result[:key_sha256]
      env['meeting.admitted_as'] = result[:admitted_as]
      nil
    end

    def extract_bearer_token(env)
      auth_header = env['HTTP_AUTHORIZATION'] || ''
      return nil unless auth_header.start_with?('Bearer ')

      auth_header.sub('Bearer ', '').strip
    end

    # --- Helpers ---

    # Reads and parses a POST body into env['meeting.body'] (always a Hash).
    # Returns an error response for an oversized body or one that is not a
    # JSON object; nil when the body is usable.
    def load_body(env)
      declared = env['CONTENT_LENGTH'].to_i
      if declared > MAX_BODY_BYTES
        return json_response(413, { error: 'body_too_large', max_bytes: MAX_BODY_BYTES })
      end

      raw = env['rack.input']&.read(MAX_BODY_BYTES + 1).to_s
      if raw.bytesize > MAX_BODY_BYTES
        return json_response(413, { error: 'body_too_large', max_bytes: MAX_BODY_BYTES })
      end

      if raw.strip.empty?
        env['meeting.body'] = {}
        return nil
      end

      parsed = begin
        JSON.parse(raw, symbolize_names: false)
      rescue JSON::ParserError
        nil
      end
      return json_response(400, { error: 'invalid_body', message: 'Body must be a JSON object' }) unless parsed.is_a?(Hash)

      env['meeting.body'] = parsed
      nil
    end

    def parse_query(env)
      query = env['QUERY_STRING'] || ''
      URI.decode_www_form(query).to_h
    rescue StandardError
      {}
    end

    def extract_tags(skill)
      return [] unless skill[:path] && File.exist?(skill[:path])

      content = File.read(skill[:path])
      return [] unless content.start_with?('---')

      parts = content.split(/^---\s*$/, 3)
      return [] if parts.length < 3

      frontmatter = YAML.safe_load(parts[1]) rescue {}
      frontmatter['tags'] || []
    end

    def json_response(status, body)
      [status, JSON_HEADERS, [body.to_json]]
    end
  end
end
