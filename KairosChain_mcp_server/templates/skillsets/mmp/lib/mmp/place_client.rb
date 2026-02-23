# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module MMP
  class PlaceClient
    attr_reader :place_url, :agent_id, :connected, :crypto

    DEFAULT_MAX_SESSION_MINUTES = 60
    DEFAULT_WARN_AFTER_INTERACTIONS = 50

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
      body = {
        id: intro.dig(:identity, :instance_id),
        name: intro.dig(:identity, :name),
        capabilities: intro[:capabilities],
        public_key: intro[:public_key]
      }

      # Add RSA signature for server-side verification
      if intro[:identity] && @crypto&.has_keypair?
        identity_data = intro[:identity]
        canonical = JSON.generate(identity_data, sort_keys: true)
        body[:identity] = identity_data
        body[:identity_signature] = @crypto.sign(canonical)
      end

      post('/place/v1/register', body)
    end

    def unregister
      post('/place/v1/unregister', { agent_id: @agent_id })
    end

    def list_agents(scope: nil, capability: nil)
      params = {}; params[:scope] = scope if scope; params[:capability] = capability if capability
      get('/place/v1/agents', params)
    end

    def browse(type: nil, search: nil, tags: nil, limit: nil)
      params = {}; params[:type] = type if type; params[:search] = search if search; params[:limit] = limit if limit
      get('/place/v1/board/browse', params)
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

    def get_public_key(peer_id)
      return @peer_public_keys[peer_id] if @peer_public_keys[peer_id]
      result = get("/place/v1/keys/#{peer_id}")
      return result if result[:error]
      @peer_public_keys[peer_id] = result[:public_key]
      result[:public_key]
    end

    def get(path, params = {})
      uri = URI.parse("#{@place_url}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?
      http = Net::HTTP.new(uri.host, uri.port); http.open_timeout = @timeout; http.read_timeout = @timeout
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{@bearer_token}" if @bearer_token
      response = http.request(req)
      @interaction_count += 1
      parse_response(response)
    rescue Errno::ECONNREFUSED, Net::OpenTimeout => e
      { error: "Connection failed: #{e.message}" }
    end

    def post(path, body)
      uri = URI.parse("#{@place_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port); http.open_timeout = @timeout; http.read_timeout = @timeout
      req = Net::HTTP::Post.new(uri.path)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{@bearer_token}" if @bearer_token
      req.body = JSON.generate(body)
      @interaction_count += 1
      parse_response(http.request(req))
    rescue Errno::ECONNREFUSED, Net::OpenTimeout => e
      { error: "Connection failed: #{e.message}" }
    end

    def parse_response(response)
      data = JSON.parse(response.body, symbolize_names: true)
      response.is_a?(Net::HTTPSuccess) ? data : { error: data[:error] || "HTTP #{response.code}" }
    rescue JSON::ParserError
      { error: "Invalid JSON response" }
    end
  end
end
