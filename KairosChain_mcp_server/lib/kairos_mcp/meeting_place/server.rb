# frozen_string_literal: true

require 'json'
require 'rack'
require_relative 'registry'
require_relative 'bulletin_board'

module KairosMcp
  module MeetingPlace
    # MeetingPlaceApp is a Rack application for the Meeting Place Server.
    # It provides a neutral rendezvous point where KairosChain agents can:
    # - Register their presence
    # - Browse the bulletin board
    # - Discover other agents
    class MeetingPlaceApp
      attr_reader :registry, :bulletin_board

      def initialize(config: {})
        @config = config
        @registry = Registry.new(ttl_seconds: config[:registry_ttl] || 300)
        @bulletin_board = BulletinBoard.new(default_ttl_hours: config[:posting_ttl_hours] || 24)
        @place_name = config[:name] || 'KairosChain Meeting Place'
        @place_description = config[:description] || 'A place for KairosChain agents to meet and exchange skills'
      end

      # Rack call interface
      def call(env)
        request = Rack::Request.new(env)
        path = request.path_info
        method = request.request_method

        case path
        # Place info
        when '/place/v1/info'
          handle_info(request)

        # Registry endpoints
        when '/place/v1/register'
          handle_register(request)
        when '/place/v1/heartbeat'
          handle_heartbeat(request)
        when '/place/v1/unregister'
          handle_unregister(request)
        when '/place/v1/agents'
          handle_list_agents(request)
        when %r{^/place/v1/agents/(.+)$}
          handle_get_agent(request, ::Regexp.last_match(1))

        # Bulletin board endpoints
        when '/place/v1/board/post'
          handle_post(request)
        when '/place/v1/board/remove'
          handle_remove_post(request)
        when '/place/v1/board/browse'
          handle_browse(request)
        when %r{^/place/v1/board/posting/(.+)$}
          handle_get_posting(request, ::Regexp.last_match(1))
        when '/place/v1/board/my_postings'
          handle_my_postings(request)

        # Stats
        when '/place/v1/stats'
          handle_stats(request)

        # Health check
        when '/health'
          handle_health(request)

        else
          not_found
        end
      rescue StandardError => e
        error_response(500, "Internal error: #{e.message}")
      end

      private

      # Response helpers

      def json_response(data, status: 200)
        [
          status,
          { 'content-type' => 'application/json' },
          [JSON.generate(data)]
        ]
      end

      def error_response(status, message)
        json_response({ error: message }, status: status)
      end

      def not_found
        error_response(404, 'Not found')
      end

      def method_not_allowed
        error_response(405, 'Method not allowed')
      end

      def parse_json_body(request)
        body = request.body.read
        return {} if body.nil? || body.empty?

        JSON.parse(body, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      # Place info

      def handle_info(_request)
        json_response({
          name: @place_name,
          description: @place_description,
          version: '1.0.0',
          features: %w[registry bulletin_board],
          agents_count: @registry.count,
          postings_count: @bulletin_board.count,
          timestamp: Time.now.utc.iso8601
        })
      end

      def handle_health(_request)
        json_response({
          status: 'ok',
          place: @place_name,
          agents: @registry.count,
          postings: @bulletin_board.count,
          timestamp: Time.now.utc.iso8601
        })
      end

      # Registry handlers

      def handle_register(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        result = @registry.register(body)
        json_response(result)
      end

      def handle_heartbeat(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        agent_id = body[:agent_id] || body['agent_id']

        return error_response(400, 'agent_id is required') unless agent_id

        result = @registry.heartbeat(agent_id)
        return error_response(404, 'Agent not found') unless result

        json_response(result)
      end

      def handle_unregister(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        agent_id = body[:agent_id] || body['agent_id']

        return error_response(400, 'agent_id is required') unless agent_id

        result = @registry.unregister(agent_id)
        return error_response(404, 'Agent not found') unless result

        json_response(result)
      end

      def handle_list_agents(request)
        return method_not_allowed unless request.request_method == 'GET'

        filters = {}
        filters[:scope] = request.params['scope'] if request.params['scope']
        filters[:capability] = request.params['capability'] if request.params['capability']

        agents = @registry.list(filters: filters)
        json_response({ agents: agents, count: agents.size })
      end

      def handle_get_agent(_request, agent_id)
        agent = @registry.get(agent_id)
        return error_response(404, 'Agent not found') unless agent

        json_response(agent)
      end

      # Bulletin board handlers

      def handle_post(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        result = @bulletin_board.post(body)

        if result[:error]
          error_response(400, result[:error])
        else
          json_response(result, status: 201)
        end
      end

      def handle_remove_post(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        posting_id = body[:posting_id] || body['posting_id']
        agent_id = body[:agent_id] || body['agent_id']

        return error_response(400, 'posting_id is required') unless posting_id

        result = @bulletin_board.remove(posting_id, agent_id: agent_id)

        if result[:error]
          error_response(400, result[:error])
        else
          json_response(result)
        end
      end

      def handle_browse(request)
        return method_not_allowed unless request.request_method == 'GET'

        filters = {}
        filters[:type] = request.params['type'] if request.params['type']
        filters[:agent_id] = request.params['agent_id'] if request.params['agent_id']
        filters[:skill_format] = request.params['skill_format'] if request.params['skill_format']
        filters[:search] = request.params['search'] if request.params['search']
        filters[:limit] = request.params['limit'].to_i if request.params['limit']

        if request.params['tags']
          filters[:tags] = request.params['tags'].split(',').map(&:strip)
        end

        postings = @bulletin_board.browse(filters: filters)
        json_response({ postings: postings, count: postings.size })
      end

      def handle_get_posting(_request, posting_id)
        posting = @bulletin_board.get(posting_id)
        return error_response(404, 'Posting not found') unless posting

        json_response(posting)
      end

      def handle_my_postings(request)
        return method_not_allowed unless request.request_method == 'GET'

        agent_id = request.params['agent_id']
        return error_response(400, 'agent_id is required') unless agent_id

        postings = @bulletin_board.agent_postings(agent_id)
        json_response({ postings: postings, count: postings.size })
      end

      # Stats

      def handle_stats(_request)
        json_response({
          place: @place_name,
          registry: @registry.stats,
          bulletin_board: @bulletin_board.stats,
          timestamp: Time.now.utc.iso8601
        })
      end
    end

    # MeetingPlaceServer wraps MeetingPlaceApp with Puma
    class MeetingPlaceServer
      DEFAULT_HOST = '0.0.0.0'  # Public by default for Meeting Place
      DEFAULT_PORT = 8888

      attr_reader :host, :port

      def initialize(host: nil, port: nil, config: {})
        @host = host || config[:host] || DEFAULT_HOST
        @port = port || config[:port] || DEFAULT_PORT
        @app = MeetingPlaceApp.new(config: config)
        @launcher = nil
      end

      def start
        require 'puma'
        require 'puma/configuration'
        require 'puma/launcher'

        conf = Puma::Configuration.new do |c|
          c.bind "tcp://#{@host}:#{@port}"
          c.app @app
          c.threads 1, 10
          c.workers 0
          c.environment 'production'
          c.log_requests false
          c.quiet false
        end

        @launcher = Puma::Launcher.new(conf)

        $stderr.puts "[MeetingPlace] Starting server on http://#{@host}:#{@port}"
        $stderr.puts "[MeetingPlace] Press Ctrl+C to stop"

        @launcher.run
      end

      def stop
        @launcher&.stop
      end

      def url
        "http://#{@host}:#{@port}"
      end

      # Access to internal components for testing
      def registry
        @app.registry
      end

      def bulletin_board
        @app.bulletin_board
      end
    end
  end
end
