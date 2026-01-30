# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require_relative 'crypto'

module KairosMcp
  module Meeting
    # PlaceClient connects to a Meeting Place Server and provides
    # methods to register, browse, and interact with the bulletin board.
    # Supports E2E encrypted message relay for secure communication.
    class PlaceClient
      attr_reader :place_url, :agent_id, :connected, :crypto

      def initialize(place_url:, identity:, timeout: 10, crypto: nil, keypair_path: nil)
        @place_url = place_url.chomp('/')
        @identity = identity
        @timeout = timeout
        @agent_id = nil
        @connected = false
        
        # E2E encryption support
        @crypto = crypto || Crypto.new(keypair_path: keypair_path, auto_generate: true)
        @peer_public_keys = {}  # Cache of peer public keys
      end

      # Connect to the Meeting Place
      def connect
        result = register
        if result && result[:agent_id]
          @agent_id = result[:agent_id]
          @connected = true
        end
        result
      end

      # Disconnect from the Meeting Place
      def disconnect
        return { status: 'not_connected' } unless @connected

        result = unregister
        @connected = false
        @agent_id = nil
        result
      end

      # Send heartbeat to stay registered
      def heartbeat
        return { error: 'Not connected' } unless @connected

        post('/place/v1/heartbeat', { agent_id: @agent_id })
      end

      # Get Meeting Place info
      def info
        get('/place/v1/info')
      end

      # Get stats
      def stats
        get('/place/v1/stats')
      end

      # === Registry Operations ===

      # Register this agent
      def register
        intro = @identity.introduce
        post('/place/v1/register', {
          id: intro.dig(:payload, :identity, :instance_id) || intro.dig(:identity, :instance_id),
          name: intro.dig(:payload, :identity, :name) || intro.dig(:identity, :name),
          description: intro.dig(:payload, :identity, :description) || intro.dig(:identity, :description),
          scope: intro.dig(:payload, :identity, :scope) || intro.dig(:identity, :scope),
          capabilities: intro.dig(:payload, :capabilities) || intro[:capabilities],
          endpoint: @identity.respond_to?(:endpoint) ? @identity.endpoint : nil,
          metadata: {
            version: intro.dig(:payload, :identity, :version) || intro.dig(:identity, :version)
          }
        })
      end

      # Unregister this agent
      def unregister
        post('/place/v1/unregister', { agent_id: @agent_id })
      end

      # List all agents in the Meeting Place
      def list_agents(scope: nil, capability: nil)
        params = {}
        params[:scope] = scope if scope
        params[:capability] = capability if capability

        get('/place/v1/agents', params)
      end

      # Get a specific agent
      def get_agent(agent_id)
        get("/place/v1/agents/#{agent_id}")
      end

      # === Bulletin Board Operations ===

      # Post an offer to share a skill
      def offer_skill(skill_name:, skill_summary:, skill_format: 'markdown', tags: [], ttl_hours: nil)
        return { error: 'Not connected' } unless @connected

        post('/place/v1/board/post', {
          agent_id: @agent_id,
          agent_name: @identity.introduce.dig(:payload, :identity, :name),
          type: 'offer_skill',
          skill_name: skill_name,
          skill_summary: skill_summary,
          skill_format: skill_format,
          tags: tags,
          ttl_hours: ttl_hours
        }.compact)
      end

      # Post a request for a skill
      def request_skill(skill_name:, skill_summary:, skill_format: 'markdown', tags: [], ttl_hours: nil)
        return { error: 'Not connected' } unless @connected

        post('/place/v1/board/post', {
          agent_id: @agent_id,
          agent_name: @identity.introduce.dig(:payload, :identity, :name),
          type: 'request_skill',
          skill_name: skill_name,
          skill_summary: skill_summary,
          skill_format: skill_format,
          tags: tags,
          ttl_hours: ttl_hours
        }.compact)
      end

      # Post an announcement
      def announce(message:, tags: [], ttl_hours: nil)
        return { error: 'Not connected' } unless @connected

        post('/place/v1/board/post', {
          agent_id: @agent_id,
          agent_name: @identity.introduce.dig(:payload, :identity, :name),
          type: 'announcement',
          skill_summary: message,
          tags: tags,
          ttl_hours: ttl_hours
        }.compact)
      end

      # Remove a posting
      def remove_posting(posting_id)
        return { error: 'Not connected' } unless @connected

        post('/place/v1/board/remove', {
          posting_id: posting_id,
          agent_id: @agent_id
        })
      end

      # Browse the bulletin board
      def browse(type: nil, skill_format: nil, search: nil, tags: nil, limit: nil)
        params = {}
        params[:type] = type if type
        params[:skill_format] = skill_format if skill_format
        params[:search] = search if search
        params[:tags] = Array(tags).join(',') if tags
        params[:limit] = limit if limit

        get('/place/v1/board/browse', params)
      end

      # Get a specific posting
      def get_posting(posting_id)
        get("/place/v1/board/posting/#{posting_id}")
      end

      # Get my postings
      def my_postings
        return { error: 'Not connected' } unless @connected

        get('/place/v1/board/my_postings', { agent_id: @agent_id })
      end

      # === Discovery ===

      # Find agents with specific capabilities
      def find_agents_with_capability(capability)
        list_agents(capability: capability)
      end

      # Find skill offers matching criteria
      def find_skill_offers(search: nil, tags: nil, format: nil)
        browse(type: 'offer_skill', search: search, tags: tags, skill_format: format)
      end

      # Find skill requests matching criteria
      def find_skill_requests(search: nil, tags: nil, format: nil)
        browse(type: 'request_skill', search: search, tags: tags, skill_format: format)
      end

      # === E2E Encryption Operations ===

      # Register our public key with the Meeting Place
      def register_public_key
        return { error: 'Not connected' } unless @connected
        return { error: 'No crypto keypair available' } unless @crypto&.has_keypair?

        post('/place/v1/keys/register', {
          agent_id: @agent_id,
          public_key: @crypto.export_public_key
        })
      end

      # Get another agent's public key
      def get_public_key(peer_agent_id)
        # Check cache first
        return @peer_public_keys[peer_agent_id] if @peer_public_keys[peer_agent_id]

        result = get("/place/v1/keys/#{peer_agent_id}")
        return result if result[:error]

        # Cache the public key
        @peer_public_keys[peer_agent_id] = result[:public_key]
        result[:public_key]
      end

      # Clear cached public keys
      def clear_key_cache
        @peer_public_keys.clear
      end

      # === Message Relay Operations (E2E Encrypted) ===

      # Send an encrypted message to another agent via the Meeting Place
      # The Meeting Place CANNOT read the content - only the recipient can decrypt it
      def send_encrypted(to:, message:, message_type: 'message')
        return { error: 'Not connected' } unless @connected
        return { error: 'No crypto keypair available' } unless @crypto&.has_keypair?

        # Get recipient's public key
        recipient_public_key = get_public_key(to)
        return { error: "Could not get public key for #{to}" } if recipient_public_key.is_a?(Hash) && recipient_public_key[:error]
        return { error: "Public key not found for #{to}" } unless recipient_public_key

        # Encrypt the message with recipient's public key
        encrypted = @crypto.encrypt(message, recipient_public_key)

        # Send via relay (Meeting Place only sees encrypted blob)
        post('/place/v1/relay/send', {
          from: @agent_id,
          to: to,
          message_type: message_type,
          encrypted_blob: encrypted[:encrypted_blob],
          blob_hash: encrypted[:blob_hash]
        })
      end

      # Receive and decrypt messages from the relay
      # Returns decrypted messages - Meeting Place never saw the plaintext
      def receive_and_decrypt(limit: 10)
        return { error: 'Not connected' } unless @connected
        return { error: 'No crypto keypair available' } unless @crypto&.has_keypair?

        result = get('/place/v1/relay/receive', { agent_id: @agent_id, limit: limit })
        return result if result[:error]

        messages = result[:messages] || []
        decrypted_messages = messages.map do |msg|
          begin
            plaintext = @crypto.decrypt(msg[:encrypted_blob])
            {
              id: msg[:id],
              from: msg[:from],
              message_type: msg[:message_type],
              content: plaintext,
              created_at: msg[:created_at],
              decryption_status: 'success'
            }
          rescue StandardError => e
            {
              id: msg[:id],
              from: msg[:from],
              message_type: msg[:message_type],
              content: nil,
              created_at: msg[:created_at],
              decryption_status: 'failed',
              decryption_error: e.message
            }
          end
        end

        { messages: decrypted_messages, count: decrypted_messages.size }
      end

      # Peek at pending messages (without removing them)
      def peek_messages(limit: 10)
        return { error: 'Not connected' } unless @connected

        get('/place/v1/relay/peek', { agent_id: @agent_id, limit: limit })
      end

      # Check relay queue status
      def relay_status
        return { error: 'Not connected' } unless @connected

        get('/place/v1/relay/status', { agent_id: @agent_id })
      end

      # Get relay statistics
      def relay_stats
        get('/place/v1/relay/stats')
      end

      # === High-level Encrypted Communication ===

      # Send a skill content securely via relay
      def send_skill_via_relay(to:, skill_name:, skill_content:, skill_hash:, provenance: nil)
        message = {
          action: 'skill_content',
          skill_name: skill_name,
          content: skill_content,
          content_hash: skill_hash,
          provenance: provenance,
          sent_at: Time.now.utc.iso8601
        }

        send_encrypted(to: to, message: message, message_type: 'skill_content')
      end

      # Send an introduction via relay
      def send_introduction_via_relay(to:)
        intro = @identity.introduce
        send_encrypted(to: to, message: intro, message_type: 'introduce')
      end

      # Send a protocol message via relay
      def send_protocol_message_via_relay(to:, action:, payload: {})
        message = {
          action: action,
          payload: payload,
          sent_at: Time.now.utc.iso8601
        }

        send_encrypted(to: to, message: message, message_type: action.to_s)
      end

      # === Audit Operations ===

      # Get audit log (metadata only - Meeting Place cannot see content)
      def get_audit_log(limit: 100, type: nil, since: nil)
        params = { limit: limit }
        params[:type] = type if type
        params[:since] = since if since

        get('/place/v1/audit', params)
      end

      # Get audit statistics
      def get_audit_stats(hours: 24)
        get('/place/v1/audit/stats', { hours: hours })
      end

      private

      def get(path, params = {})
        uri = URI.parse("#{@place_url}#{path}")
        uri.query = URI.encode_www_form(params) unless params.empty?

        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        request = Net::HTTP::Get.new(uri)
        request['Accept'] = 'application/json'

        response = http.request(request)
        parse_response(response)
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout => e
        { error: "Connection failed: #{e.message}" }
      end

      def post(path, body)
        uri = URI.parse("#{@place_url}#{path}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        request.body = JSON.generate(body)

        response = http.request(request)
        parse_response(response)
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout => e
        { error: "Connection failed: #{e.message}" }
      end

      def parse_response(response)
        data = JSON.parse(response.body, symbolize_names: true)
        
        if response.is_a?(Net::HTTPSuccess)
          data
        else
          { error: data[:error] || "HTTP #{response.code}", status: response.code.to_i }
        end
      rescue JSON::ParserError
        { error: "Invalid JSON response: #{response.body[0, 100]}" }
      end
    end
  end
end
