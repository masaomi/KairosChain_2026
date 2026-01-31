# frozen_string_literal: true

require 'json'
require 'rack'
require 'digest'
require_relative '../meeting/identity'
require_relative '../meeting/meeting_protocol'
require_relative '../meeting/skill_exchange'
require_relative '../meeting/interaction_log'

module KairosMcp
  module Transport
    # MeetingApp is a Rack application that provides the Meeting Protocol HTTP API.
    # It can be run with any Rack-compatible server (Puma, etc.)
    class MeetingApp
      def initialize(workspace_root:, config: nil)
        @workspace_root = workspace_root
        @config = config || load_config

        # Initialize Meeting components
        @identity = Meeting::Identity.new(workspace_root: workspace_root)
        @protocol = Meeting::MeetingProtocol.new(identity: @identity)
        @skill_exchange = Meeting::SkillExchange.new(config: @config, workspace_root: workspace_root)
        @interaction_log = Meeting::InteractionLog.new(workspace_root: workspace_root)
      end

      # Rack call interface
      def call(env)
        request = Rack::Request.new(env)
        
        path = request.path_info
        method = request.request_method

        case path
        when '/health'
          handle_health(request)
        when '/meeting/v1/introduce'
          handle_introduce(request)
        when '/meeting/v1/capabilities'
          handle_capabilities(request)
        when '/meeting/v1/skills'
          handle_skills(request)
        when '/meeting/v1/message'
          handle_message(request)
        when '/meeting/v1/offer_skill'
          handle_offer_skill(request)
        when '/meeting/v1/request_skill'
          handle_request_skill(request)
        when '/meeting/v1/accept'
          handle_accept(request)
        when '/meeting/v1/decline'
          handle_decline(request)
        when '/meeting/v1/skill_content'
          handle_skill_content(request)
        when '/meeting/v1/reflect'
          handle_reflect(request)
        when '/meeting/v1/session/start'
          handle_start_session(request)
        when '/meeting/v1/session/end'
          handle_end_session(request)
        when '/meeting/v1/history'
          handle_history(request)
        # Discovery extension endpoints
        when '/meeting/v1/skill_details'
          handle_skill_details(request)
        when '/meeting/v1/skill_preview'
          handle_skill_preview(request)
        else
          not_found
        end
      rescue StandardError => e
        error_response(500, "Internal error: #{e.message}")
      end

      private

      def load_config
        config_path = File.join(@workspace_root, 'config', 'meeting.yml')
        if File.exist?(config_path)
          require 'yaml'
          YAML.load_file(config_path) || {}
        else
          {}
        end
      end

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

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      # Handlers

      def handle_health(_request)
        json_response({ status: 'ok', timestamp: Time.now.utc.iso8601 })
      end

      def handle_introduce(request)
        case request.request_method
        when 'GET'
          message = @protocol.create_introduce
          @interaction_log.log_outgoing(message)
          json_response(message.to_h)
        when 'POST'
          body = parse_json_body(request)
          @interaction_log.log_incoming(body)
          result = @protocol.process_message(body)
          json_response(result)
        else
          method_not_allowed
        end
      end

      def handle_capabilities(request)
        return method_not_allowed unless request.request_method == 'GET'

        json_response(@identity.capabilities)
      end

      def handle_skills(request)
        return method_not_allowed unless request.request_method == 'GET'

        public_only = request.params['public_only'] != 'false'
        skills = public_only ? @identity.public_skills : @identity.introduce[:skills]

        json_response({
          skills: skills,
          exchange_policy: @identity.introduce[:exchange_policy]
        })
      end

      def handle_message(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        @interaction_log.log_incoming(body)
        result = @protocol.process_message(body)

        if result[:action] == 'skill_content' && result[:status] == 'received'
          validation = @skill_exchange.validate_received_skill(
            content: result[:content],
            format: result[:format],
            content_hash: result[:content_hash]
          )
          result[:validation] = validation
        end

        json_response(result)
      end

      def handle_offer_skill(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        skill_id = body['skill_id']
        to = body['to']

        return error_response(400, 'skill_id is required') unless skill_id

        message = @protocol.create_offer_skill(skill_id: skill_id, to: to)
        @interaction_log.log_outgoing(message)
        json_response({ message: message.to_h })
      rescue ArgumentError => e
        error_response(400, e.message)
      end

      def handle_request_skill(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        description = body['description']
        to = body['to']

        return error_response(400, 'description is required') unless description

        message = @protocol.create_request_skill(description: description, to: to)
        @interaction_log.log_outgoing(message)
        json_response({ message: message.to_h })
      end

      def handle_accept(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        in_reply_to = body['in_reply_to']
        to = body['to']

        return error_response(400, 'in_reply_to is required') unless in_reply_to
        return error_response(400, 'to is required') unless to

        message = @protocol.create_accept(in_reply_to: in_reply_to, to: to)
        @interaction_log.log_outgoing(message)
        json_response({ message: message.to_h })
      end

      def handle_decline(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        in_reply_to = body['in_reply_to']
        to = body['to']
        reason = body['reason']

        return error_response(400, 'in_reply_to is required') unless in_reply_to
        return error_response(400, 'to is required') unless to

        message = @protocol.create_decline(in_reply_to: in_reply_to, to: to, reason: reason)
        @interaction_log.log_outgoing(message)
        json_response({ message: message.to_h })
      end

      def handle_skill_content(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        in_reply_to = body['in_reply_to']
        to = body['to']
        skill_id = body['skill_id']

        return error_response(400, 'in_reply_to is required') unless in_reply_to
        return error_response(400, 'to is required') unless to
        return error_response(400, 'skill_id is required') unless skill_id

        skill = @identity.introduce[:skills].find { |s| s[:id] == skill_id }
        return error_response(404, "Skill not found: #{skill_id}") unless skill

        packaged = @skill_exchange.package_skill(skill[:path])

        message = @protocol.create_skill_content(
          in_reply_to: in_reply_to,
          to: to,
          skill_id: skill_id,
          content: packaged[:content]
        )

        @interaction_log.log_outgoing(message)
        @interaction_log.log_skill_exchange(
          skill_name: skill[:name],
          skill_hash: packaged[:content_hash],
          direction: :sent,
          peer_id: to
        )

        json_response({
          message: message.to_h,
          packaged_skill: {
            name: packaged[:name],
            format: packaged[:format],
            content_hash: packaged[:content_hash],
            size_bytes: packaged[:size_bytes]
          }
        })
      rescue ArgumentError, SecurityError => e
        error_response(400, e.message)
      end

      def handle_reflect(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        to = body['to']
        reflection = body['reflection']
        in_reply_to = body['in_reply_to']

        return error_response(400, 'to is required') unless to
        return error_response(400, 'reflection is required') unless reflection

        message = @protocol.create_reflect(to: to, reflection: reflection, in_reply_to: in_reply_to)
        @interaction_log.log_outgoing(message)
        json_response({ message: message.to_h })
      end

      def handle_start_session(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        peer_id = body['peer_id']

        return error_response(400, 'peer_id is required') unless peer_id

        session_id = @interaction_log.start_session(peer_id: peer_id)
        json_response({ session_id: session_id, peer_id: peer_id, started_at: Time.now.utc.iso8601 })
      end

      def handle_end_session(request)
        return method_not_allowed unless request.request_method == 'POST'

        body = parse_json_body(request)
        summary = body['summary']

        session_id = @interaction_log.end_session(summary: summary)
        json_response({ session_id: session_id, ended_at: Time.now.utc.iso8601, summary: summary })
      end

      def handle_history(request)
        return method_not_allowed unless request.request_method == 'GET'

        peer_id = request.params['peer_id']
        limit = (request.params['limit'] || 50).to_i

        interactions = if peer_id
                         @interaction_log.history_with_peer(peer_id, limit: limit)
                       else
                         @interaction_log.all_interactions(limit: limit)
                       end

        json_response({
          interactions: interactions,
          summary: @interaction_log.summary
        })
      end

      # Discovery extension handlers

      def handle_skill_details(request)
        return method_not_allowed unless request.request_method == 'GET'

        skill_id = request.params['skill_id']
        return error_response(400, 'skill_id is required') unless skill_id

        # Find skill in available skills
        skill = @identity.introduce[:skills].find { |s| s[:id] == skill_id }
        
        unless skill
          return json_response({
            skill_id: skill_id,
            available: false,
            reason: 'skill_not_found'
          })
        end

        # Check if skill is public or discovery is allowed
        discovery_config = @config['discovery'] || {}
        expose_private = discovery_config['expose_private_skills'] || false
        
        unless skill[:public] || expose_private
          return json_response({
            skill_id: skill_id,
            available: false,
            reason: 'skill_not_public'
          })
        end

        # Read skill file for additional metadata
        skill_metadata = extract_skill_metadata(skill[:path])
        
        # Build response
        json_response({
          skill_id: skill_id,
          available: true,
          metadata: {
            name: skill[:name] || skill_metadata['name'],
            version: skill_metadata['version'] || '1.0.0',
            layer: skill_metadata['layer'] || 'L1',
            format: skill[:format] || 'markdown',
            description: skill_metadata['description'] || skill[:description],
            tags: skill_metadata['tags'] || skill[:tags] || [],
            author: skill_metadata['author'] || @identity.introduce[:identity][:name],
            created_at: skill_metadata['created_at'],
            updated_at: skill_metadata['updated_at'] || File.mtime(skill[:path]).utc.iso8601,
            size_bytes: File.size(skill[:path]),
            dependencies: skill_metadata['dependencies'] || skill_metadata['requires'] || [],
            usage_examples: skill_metadata['usage_examples'] || [],
            public: skill[:public]
          },
          exchange_info: {
            allowed_formats: @config.dig('skill_exchange', 'allowed_formats') || ['markdown'],
            requires_approval: @config.dig('skill_exchange', 'require_approval') != false
          }
        })
      rescue StandardError => e
        error_response(500, "Failed to get skill details: #{e.message}")
      end

      def handle_skill_preview(request)
        return method_not_allowed unless request.request_method == 'GET'

        skill_id = request.params['skill_id']
        preview_type = request.params['preview_type'] || 'head'
        lines = (request.params['lines'] || 10).to_i

        return error_response(400, 'skill_id is required') unless skill_id

        # Check if previews are allowed
        discovery_config = @config['discovery'] || {}
        unless discovery_config['allow_preview'] != false
          return json_response({
            skill_id: skill_id,
            error: 'preview_disabled',
            message: 'This agent does not allow skill previews'
          })
        end

        # Find skill
        skill = @identity.introduce[:skills].find { |s| s[:id] == skill_id }
        
        unless skill
          return json_response({
            skill_id: skill_id,
            error: 'skill_not_found'
          })
        end

        # Check max preview lines
        max_lines = discovery_config['max_preview_lines'] || 20
        lines = [lines, max_lines].min

        # Read and extract preview
        content = File.read(skill[:path])
        content_lines = content.lines
        total_lines = content_lines.length

        preview = case preview_type
                  when 'head'
                    content_lines.first(lines).join
                  when 'toc'
                    # Extract headers (markdown)
                    content_lines.select { |l| l.start_with?('#') }.first(lines).join
                  when 'summary'
                    # Try to extract description from frontmatter
                    extract_skill_metadata(skill[:path])['description'] || content_lines.first(lines).join
                  else
                    content_lines.first(lines).join
                  end

        json_response({
          skill_id: skill_id,
          preview_type: preview_type,
          preview: preview,
          preview_lines: [lines, total_lines].min,
          total_lines: total_lines,
          truncated: total_lines > lines,
          content_hash: "sha256:#{Digest::SHA256.hexdigest(content)}"
        })
      rescue StandardError => e
        error_response(500, "Failed to get skill preview: #{e.message}")
      end

      def extract_skill_metadata(path)
        return {} unless File.exist?(path)

        content = File.read(path)
        
        # Check for YAML frontmatter
        if content.start_with?('---')
          lines = content.lines
          end_idx = lines[1..].index { |l| l.strip == '---' }
          
          if end_idx
            frontmatter = lines[1..end_idx].join
            require 'yaml'
            return YAML.safe_load(frontmatter) || {}
          end
        end

        {}
      rescue StandardError
        {}
      end
    end

    # HTTPServer wraps MeetingApp with Puma for easy startup
    class HTTPServer
      DEFAULT_HOST = '127.0.0.1'
      DEFAULT_PORT = 8080

      attr_reader :host, :port

      def initialize(workspace_root:, host: nil, port: nil, config: nil)
        @workspace_root = workspace_root
        @config = config || load_config
        @host = host || @config.dig('http_server', 'host') || DEFAULT_HOST
        @port = port || @config.dig('http_server', 'port') || DEFAULT_PORT
        @app = MeetingApp.new(workspace_root: workspace_root, config: @config)
        @server = nil
      end

      def start
        require 'puma'
        require 'puma/configuration'
        require 'puma/launcher'

        conf = Puma::Configuration.new do |config|
          config.bind "tcp://#{@host}:#{@port}"
          config.app @app
          config.threads 1, 5
          config.workers 0  # Single process mode
          config.environment 'production'
          config.log_requests false
          config.quiet false
        end

        @launcher = Puma::Launcher.new(conf)
        
        $stderr.puts "[HTTPServer] Starting Puma on http://#{@host}:#{@port}"
        $stderr.puts "[HTTPServer] Press Ctrl+C to stop"
        
        @launcher.run
      end

      def stop
        @launcher&.stop
      end

      def url
        "http://#{@host}:#{@port}"
      end

      private

      def load_config
        config_path = File.join(@workspace_root, 'config', 'meeting.yml')
        if File.exist?(config_path)
          require 'yaml'
          YAML.load_file(config_path) || {}
        else
          {}
        end
      end
    end
  end
end
