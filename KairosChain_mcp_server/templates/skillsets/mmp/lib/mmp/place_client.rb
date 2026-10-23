# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'time'

module MMP
  class PlaceClient
    attr_reader :place_url, :agent_id, :connected, :crypto

    DEFAULT_MAX_SESSION_MINUTES = 60
    DEFAULT_WARN_AFTER_INTERACTIONS = 50
    # Longest wait honoured when a Place says a proof was issued too early
    # (right after its restart) and names the earliest acceptable time.
    MAX_STALE_WAIT_SECONDS = 45

    NETWORK_ERRORS = [
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE,
      Net::OpenTimeout, Net::ReadTimeout,
      SocketError, OpenSSL::SSL::SSLError
    ].freeze

    def initialize(place_url:, identity:, timeout: 10, crypto: nil, keypair_path: nil, config: {})
      @place_url = place_url.chomp('/')
      @identity = identity
      @timeout = timeout
      @agent_id = nil
      @connected = false
      @bearer_token = nil
      @session_start_time = nil
      @interaction_count = 0
      @max_session_minutes = config[:max_session_minutes] || DEFAULT_MAX_SESSION_MINUTES
      @warn_after_interactions = config[:warn_after_interactions] || DEFAULT_WARN_AFTER_INTERACTIONS
      @crypto = crypto || Crypto.new(keypair_path: keypair_path, auto_generate: true)
      @peer_public_keys = {}
      @clock_offset = 0.0
    end

    # Reconnect using saved connection state (no re-registration)
    def self.reconnect(place_url:, identity:, session_token:, agent_id: nil, timeout: 10, config: {})
      client = new(place_url: place_url, identity: identity, timeout: timeout, config: config)
      client.instance_variable_set(:@bearer_token, session_token)
      client.instance_variable_set(:@agent_id, agent_id)
      client.instance_variable_set(:@connected, true)
      client
    end

    def connect
      result = register
      if result && result[:agent_id]
        @agent_id = result[:agent_id]
        @bearer_token = result[:session_token]
        @connected = true
        @session_start_time = Time.now
        @interaction_count = 0
      end
      result
    end

    def disconnect
      return { status: 'not_connected' } unless @connected
      result = unregister
      duration = session_duration_minutes
      @connected = false; @agent_id = nil; @session_start_time = nil
      result.merge(session_duration_minutes: duration, total_interactions: @interaction_count)
    end

    def session_duration_minutes
      return 0 unless @session_start_time
      ((Time.now - @session_start_time) / 60.0).round(1)
    end

    def session_status
      return { connected: false } unless @connected
      { connected: true, place_url: @place_url, agent_id: @agent_id, session_duration_minutes: session_duration_minutes, interaction_count: @interaction_count }
    end

    def register
      intro = @identity.introduce
      agent_id = @identity.respond_to?(:place_agent_id) ? @identity.place_agent_id : intro.dig(:identity, :instance_id)
      body = {
        id: agent_id,
        name: intro.dig(:identity, :name),
        capabilities: intro[:capabilities],
        public_key: intro[:public_key],
        description: intro.dig(:identity, :description),
        scope: intro.dig(:identity, :scope)
      }
      unless @crypto&.has_keypair?
        return { error: 'no_keypair', message: 'No MMP keypair available to sign the registration' }
      end

      info = place_info
      unless info.is_a?(Hash) && info[:registration_proof] == RegistrationProof::PROTOCOL
        # A Place older than registration proofs: only the legacy identity
        # signature is understood there. Newer Places never receive it.
        identity_data = intro[:identity]
        body[:identity] = identity_data
        body[:identity_signature] = @crypto.sign(JSON.generate(identity_data, sort_keys: true))
        return post('/place/v1/register', body)
      end

      audience = RegistrationProof.normalize_origin(@place_url)
      unless audience && (audience.start_with?('https://') || RegistrationProof.loopback?(audience))
        return { error: 'insecure_transport',
                 message: "Refusing to send a registration proof to #{@place_url} without TLS. Use the https:// address of the Meeting Place." }
      end

      result = post_registration(body, audience, agent_id)
      if result[:error] == 'registration_proof_stale'
        server_now = parse_time(result[:server_time])
        earliest = parse_time(result[:earliest_acceptable_at])
        if server_now
          @clock_offset = server_now - Time.now.utc
          wait = earliest ? (earliest - server_now) + 1 : 0
          if wait <= MAX_STALE_WAIT_SECONDS
            sleep(wait) if wait.positive?
            result = post_registration(body, audience, agent_id)
          end
        end
      end
      result
    end

    def unregister
      post('/place/v1/unregister', { agent_id: @agent_id })
    end

    def list_agents(scope: nil, capability: nil)
      params = {}; params[:scope] = scope if scope; params[:capability] = capability if capability
      get('/place/v1/agents', params)
    end

    def browse(type: nil, search: nil, tags: nil, limit: nil)
      params = {}
      params[:type] = type if type
      params[:search] = search if search
      params[:tags] = tags.is_a?(Array) ? tags.join(',') : tags if tags
      params[:limit] = limit if limit
      get('/place/v1/board/browse', params)
    end

    def deposit(skill)
      post('/place/v1/deposit', skill)
    end

    def get_skill_details(skill_id:)
      get('/meeting/v1/skill_details', { skill_id: skill_id })
    end

    def get_skill_content(skill_id:, owner: nil)
      params = {}
      params[:owner] = owner if owner
      get("/place/v1/skill_content/#{URI.encode_www_form_component(skill_id)}", params)
    end

    def request_skill_content(skill_id:)
      post('/meeting/v1/skill_content', { skill_id: skill_id })
    end

    def place_info
      get_unauthenticated('/place/v1/info')
    end

    def withdraw(skill_id:, reason:)
      delete("/place/v1/deposit/#{URI.encode_www_form_component(skill_id)}", { reason: reason })
    end

    def update_deposit(skill_id:, skill:)
      put("/place/v1/deposit/#{URI.encode_www_form_component(skill_id)}", skill)
    end

    def preview_skill(skill_id:, owner: nil, first_lines: 30)
      params = { first_lines: first_lines }
      params[:owner] = owner if owner
      get("/place/v1/preview/#{URI.encode_www_form_component(skill_id)}", params)
    end

    def get_agent_profile(agent_id:)
      get("/place/v1/agent_profile/#{URI.encode_www_form_component(agent_id)}")
    end

    def attest_skill(skill_id:, owner_agent_id:, claim:, evidence_hash: nil, signature: nil, signed_payload: nil)
      post('/place/v1/board/attest', {
        skill_id: skill_id, owner_agent_id: owner_agent_id, claim: claim,
        evidence_hash: evidence_hash, signature: signature, signed_payload: signed_payload
      })
    end

    # --- SkillSet Exchange methods ---

    def skillset_deposit(body)
      post('/place/v1/skillset_deposit', body)
    end

    def skillset_browse(search: nil, limit: 20)
      params = {}
      params[:search] = search if search
      params[:limit] = limit if limit
      get('/place/v1/skillset_browse', params)
    end

    def skillset_content(name:, depositor: nil, timeout: 45)
      params = { name: name }
      params[:depositor] = depositor if depositor && !depositor.to_s.empty?
      get('/place/v1/skillset_content', params, timeout: timeout)
    end

    def skillset_withdraw(name:, reason: nil)
      body = { name: name }
      body[:reason] = reason if reason && !reason.to_s.empty?
      post('/place/v1/skillset_withdraw', body)
    end

    def send_encrypted(to:, message:, message_type: 'message')
      return { error: 'Not connected' } unless @connected
      return { error: 'No keypair' } unless @crypto&.has_keypair?
      recipient_key = get_public_key(to)
      return { error: "No public key for #{to}" } unless recipient_key.is_a?(String)
      encrypted = @crypto.encrypt(message, recipient_key)
      post('/place/v1/relay/send', { from: @agent_id, to: to, message_type: message_type, encrypted_blob: encrypted[:encrypted_blob], blob_hash: encrypted[:blob_hash] })
    end

    def receive_and_decrypt(limit: 10)
      return { error: 'Not connected' } unless @connected
      result = get('/place/v1/relay/receive', { agent_id: @agent_id, limit: limit })
      return result if result[:error]
      messages = (result[:messages] || []).map do |msg|
        begin
          { id: msg[:id], from: msg[:from], content: @crypto.decrypt(msg[:encrypted_blob]), decryption_status: 'success' }
        rescue StandardError => e
          { id: msg[:id], from: msg[:from], content: nil, decryption_status: 'failed', error: e.message }
        end
      end
      { messages: messages, count: messages.size }
    end

    private

    def post_registration(body, audience, agent_id)
      fields = RegistrationProof.build(audience: audience, agent_id: agent_id, issued_at: Time.now.utc + @clock_offset)
      post('/place/v1/register', body.merge(registration: fields, registration_signature: @crypto.sign_registration(fields)))
    end

    def parse_time(value)
      value ? Time.iso8601(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    def get_public_key(peer_id)
      return @peer_public_keys[peer_id] if @peer_public_keys[peer_id]
      result = get("/place/v1/keys/#{peer_id}")
      return result if result[:error]
      @peer_public_keys[peer_id] = result[:public_key]
      result[:public_key]
    end

    def get(path, params = {}, timeout: nil)
      effective_timeout = timeout || @timeout
      uri = URI.parse("#{@place_url}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?
      http = Net::HTTP.new(uri.host, uri.port); http.open_timeout = effective_timeout; http.read_timeout = effective_timeout
      http.use_ssl = (uri.scheme == 'https')
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{@bearer_token}" if @bearer_token
      response = http.request(req)
      @interaction_count += 1
      parse_response(response)
    rescue *NETWORK_ERRORS => e
      { error: "Connection failed: #{e.message}" }
    end

    def get_unauthenticated(path, params = {})
      uri = URI.parse("#{@place_url}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?
      http = Net::HTTP.new(uri.host, uri.port); http.open_timeout = @timeout; http.read_timeout = @timeout
      http.use_ssl = (uri.scheme == 'https')
      req = Net::HTTP::Get.new(uri)
      response = http.request(req)
      @interaction_count += 1
      parse_response(response)
    rescue *NETWORK_ERRORS => e
      { error: "Connection failed: #{e.message}" }
    end

    def post(path, body)
      http_request(Net::HTTP::Post, path, body: body)
    end

    def put(path, body)
      http_request(Net::HTTP::Put, path, body: body)
    end

    def delete(path, body = nil)
      http_request(Net::HTTP::Delete, path, body: body)
    end

    def http_request(method_class, path, body: nil)
      uri = URI.parse("#{@place_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port); http.open_timeout = @timeout; http.read_timeout = @timeout
      http.use_ssl = (uri.scheme == 'https')
      req = method_class.new(uri.path)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{@bearer_token}" if @bearer_token
      req.body = JSON.generate(body) if body
      @interaction_count += 1
      parse_response(http.request(req))
    rescue *NETWORK_ERRORS => e
      { error: "Connection failed: #{e.message}" }
    end

    def parse_response(response)
      data = JSON.parse(response.body, symbolize_names: true)
      if response.is_a?(Net::HTTPSuccess)
        data
      else
        data[:error] ||= "HTTP #{response.code}"
        data
      end
    rescue JSON::ParserError
      { error: "Invalid JSON response (HTTP #{response.code})" }
    end
  end
end
