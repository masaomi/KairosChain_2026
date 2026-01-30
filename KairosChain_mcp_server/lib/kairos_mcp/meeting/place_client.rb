# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module KairosMcp
  module Meeting
    # PlaceClient connects to a Meeting Place Server and provides
    # methods to register, browse, and interact with the bulletin board.
    class PlaceClient
      attr_reader :place_url, :agent_id, :connected

      def initialize(place_url:, identity:, timeout: 10)
        @place_url = place_url.chomp('/')
        @identity = identity
        @timeout = timeout
        @agent_id = nil
        @connected = false
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
