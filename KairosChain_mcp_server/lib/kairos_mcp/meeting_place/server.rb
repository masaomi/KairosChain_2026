# frozen_string_literal: true

require 'json'
require 'rack'
require_relative 'registry'
require_relative 'bulletin_board'
require_relative 'message_relay'
require_relative 'audit_logger'

module KairosMcp
  module MeetingPlace
    # MeetingPlaceApp is a Rack application for the Meeting Place Server.
    # It provides a neutral rendezvous point where KairosChain agents can:
    # - Register their presence
    # - Browse the bulletin board
    # - Discover other agents
    # - Exchange encrypted messages (relay)
    #
    # IMPORTANT: This server acts as a ROUTER ONLY.
    # It NEVER decrypts or inspects message content.
    class MeetingPlaceApp
      attr_reader :registry, :bulletin_board, :message_relay, :audit_logger

      def initialize(config: {})
        @config = config
        @place_name = config[:name] || 'KairosChain Meeting Place'
        @place_description = config[:description] || 'A place for KairosChain agents to meet and exchange skills'
        
        # Initialize audit logger first (other components may use it)
        @audit_logger = AuditLogger.new(
          config: {
            anonymize_participants: config[:anonymize_participants] || false,
            anonymization_salt: config[:anonymization_salt]
          },
          log_path: config[:audit_log_path]
        )
        
        @registry = Registry.new(ttl_seconds: config[:registry_ttl] || 300)
        @bulletin_board = BulletinBoard.new(default_ttl_hours: config[:posting_ttl_hours] || 24)
        
        # Message relay for encrypted message forwarding
        @message_relay = MessageRelay.new(
          config: {
            ttl_seconds: config[:relay_ttl_seconds] || 3600,
            max_queue_size: config[:relay_max_queue_size] || 100,
            max_message_size: config[:relay_max_message_size] || 1_048_576
          },
          audit_logger: @audit_logger
        )
        
        # Public key storage (agent_id => public_key_pem)
        @public_keys = {}
        @keys_mutex = Mutex.new
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

        # Admin cleanup endpoints
        when '/place/v1/admin/cleanup/dead'
          handle_cleanup_dead(request)
        when '/place/v1/admin/cleanup/stale'
          handle_cleanup_stale(request)

        # Public key endpoints (for E2E encryption)
        when '/place/v1/keys/register'
          handle_key_register(request)
        when %r{^/place/v1/keys/(.+)$}
          handle_get_key(request, ::Regexp.last_match(1))

        # Message relay endpoints (encrypted messages only)
        when '/place/v1/relay/send'
          handle_relay_send(request)
        when '/place/v1/relay/receive'
          handle_relay_receive(request)
        when '/place/v1/relay/peek'
          handle_relay_peek(request)
        when '/place/v1/relay/status'
          handle_relay_status(request)
        when '/place/v1/relay/stats'
          handle_relay_stats(request)

        # Audit endpoints (metadata only, no content)
        when '/place/v1/audit'
          handle_audit(request)
        when '/place/v1/audit/stats'
          handle_audit_stats(request)

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
          version: '1.1.0',
          features: %w[registry bulletin_board message_relay e2e_encryption audit],
          agents_count: @registry.count,
          postings_count: @bulletin_board.count,
          pending_messages: @message_relay.stats[:total_messages],
          privacy_note: 'This server acts as a router only. Message content is end-to-end encrypted and never inspected.',
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
          message_relay: @message_relay.stats,
          audit: @audit_logger.stats,
          timestamp: Time.now.utc.iso8601
        })
      end

      # Admin cleanup handlers

      def handle_cleanup_dead(request)
        return method_not_allowed unless request.request_method == 'POST'
        
        result = @registry.cleanup_dead_agents
        
        @audit_logger.log_registry(
          action: 'cleanup_dead',
          removed_count: result[:removed_count],
          removed_agents: result[:removed_agents].map { |a| a[:id] }
        )
        
        json_response(result)
      end

      def handle_cleanup_stale(request)
        return method_not_allowed unless request.request_method == 'POST'
        
        body = parse_json_body(request)
        older_than = body[:older_than_seconds] || body['older_than_seconds'] || 3600  # Default 1 hour
        
        result = @registry.cleanup_stale(older_than_seconds: older_than.to_i)
        
        @audit_logger.log_registry(
          action: 'cleanup_stale',
          older_than_seconds: older_than,
          removed_count: result[:removed_count],
          removed_agents: result[:removed_agents].map { |a| a[:id] }
        )
        
        json_response(result)
      end

      # Public key handlers

      def handle_key_register(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        agent_id = body[:agent_id]
        public_key = body[:public_key]

        return error_response(400, 'agent_id is required') unless agent_id
        return error_response(400, 'public_key is required') unless public_key

        # Calculate fingerprint for logging (not the actual key content)
        fingerprint = calculate_key_fingerprint(public_key)

        @keys_mutex.synchronize do
          @public_keys[agent_id] = {
            public_key: public_key,
            fingerprint: fingerprint,
            registered_at: Time.now.utc.iso8601
          }
        end

        # Log key registration (fingerprint only, not the key itself)
        @audit_logger.log_key_registration(
          agent_id: agent_id,
          key_fingerprint: fingerprint
        )

        json_response({
          status: 'registered',
          agent_id: agent_id,
          fingerprint: fingerprint
        }, status: 201)
      end

      def handle_get_key(_request, agent_id)
        key_data = @keys_mutex.synchronize { @public_keys[agent_id] }
        return error_response(404, 'Public key not found for agent') unless key_data

        json_response({
          agent_id: agent_id,
          public_key: key_data[:public_key],
          fingerprint: key_data[:fingerprint],
          registered_at: key_data[:registered_at]
        })
      end

      # Message relay handlers
      # IMPORTANT: These handlers NEVER decrypt or inspect message content

      def handle_relay_send(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        from = body[:from]
        to = body[:to]
        encrypted_blob = body[:encrypted_blob]
        blob_hash = body[:blob_hash]
        message_type = body[:message_type] || 'unknown'

        return error_response(400, 'from is required') unless from
        return error_response(400, 'to is required') unless to
        return error_response(400, 'encrypted_blob is required') unless encrypted_blob
        return error_response(400, 'blob_hash is required') unless blob_hash

        begin
          result = @message_relay.enqueue(
            from: from,
            to: to,
            encrypted_blob: encrypted_blob,
            blob_hash: blob_hash,
            message_type: message_type
          )
          json_response(result, status: 201)
        rescue ArgumentError => e
          error_response(400, e.message)
        end
      end

      def handle_relay_receive(request)
        return method_not_allowed unless request.request_method == 'GET'

        agent_id = request.params['agent_id']
        limit = (request.params['limit'] || 10).to_i

        return error_response(400, 'agent_id is required') unless agent_id

        result = @message_relay.dequeue(agent_id, limit: limit)
        json_response(result)
      end

      def handle_relay_peek(request)
        return method_not_allowed unless request.request_method == 'GET'

        agent_id = request.params['agent_id']
        limit = (request.params['limit'] || 10).to_i

        return error_response(400, 'agent_id is required') unless agent_id

        result = @message_relay.peek(agent_id, limit: limit)
        json_response(result)
      end

      def handle_relay_status(request)
        return method_not_allowed unless request.request_method == 'GET'

        agent_id = request.params['agent_id']
        return error_response(400, 'agent_id is required') unless agent_id

        result = @message_relay.queue_status(agent_id)
        json_response(result)
      end

      def handle_relay_stats(_request)
        json_response(@message_relay.stats)
      end

      # Audit handlers (metadata only)

      def handle_audit(request)
        return method_not_allowed unless request.request_method == 'GET'

        limit = (request.params['limit'] || 100).to_i
        event_type = request.params['type']
        since = request.params['since']

        entries = @audit_logger.recent_entries(
          limit: limit,
          event_type: event_type,
          since: since
        )

        json_response({
          entries: entries,
          count: entries.size,
          note: 'Audit log contains metadata only. Message content is never recorded.'
        })
      end

      def handle_audit_stats(request)
        hours = (request.params['hours'] || 24).to_i

        json_response({
          summary: @audit_logger.stats,
          hourly: @audit_logger.hourly_stats(hours: hours)
        })
      end

      # Helper methods

      def calculate_key_fingerprint(public_key_pem)
        require 'digest'
        # Use SHA256 of the PEM for fingerprint
        hash = Digest::SHA256.hexdigest(public_key_pem)
        hash.scan(/../).join(':')[0, 47]
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

      def message_relay
        @app.message_relay
      end

      def audit_logger
        @app.audit_logger
      end
    end
  end
end
