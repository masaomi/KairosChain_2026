# frozen_string_literal: true

require 'json'

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

    def initialize
      @protocol = nil
      @identity = nil
      @exchange = nil
    end

    def call(env)
      return unavailable_response unless mmp_available?

      request_method = env['REQUEST_METHOD']
      path = env['PATH_INFO']

      case [request_method, path]
      when ['GET', '/meeting/v1/introduce']
        handle_get_introduce
      when ['POST', '/meeting/v1/introduce']
        handle_post_introduce(env)
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
      else
        json_response(404, { error: 'not_found', message: "Unknown meeting endpoint: #{path}" })
      end
    rescue StandardError => e
      $stderr.puts "[MeetingRouter] Error: #{e.message}"
      json_response(500, { error: 'internal_error', message: e.message })
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

    def identity
      @identity ||= ::MMP::Identity.new(
        workspace_root: KairosMcp.data_dir,
        config: ::MMP.load_config
      )
    end

    def protocol
      @protocol ||= ::MMP::Protocol.new(
        identity: identity,
        knowledge_root: mmp_knowledge_root
      )
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
      intro = identity.introduce
      json_response(200, intro)
    end

    # POST /meeting/v1/introduce - Receive introduction from peer
    def handle_post_introduce(env)
      body = parse_body(env)
      result = protocol.process_message(body.merge(action: 'introduce'))

      json_response(200, {
        status: 'received',
        peer_identity: identity.introduce,
        result: result
      })
    end

    # POST /meeting/v1/message - Generic MMP message handler
    def handle_message(env)
      body = parse_body(env)
      result = protocol.process_message(body)
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
      body = parse_body(env)
      skill_id = body['skill_id'] || body[:skill_id]

      unless skill_id
        return json_response(400, { error: 'missing_param', message: 'skill_id is required' })
      end

      skills = identity.introduce[:skills] || []
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
      body = parse_body(env)
      result = protocol.process_message({
        action: 'request_skill',
        from: body['from'] || body[:from],
        payload: { description: body['description'] || body[:description], skill_id: body['skill_id'] || body[:skill_id] }
      })

      json_response(200, result)
    end

    # POST /meeting/v1/reflect - Receive a reflection message
    def handle_reflect(env)
      body = parse_body(env)
      result = protocol.process_message({
        action: 'reflect',
        from: body['from'] || body[:from],
        in_reply_to: body['in_reply_to'] || body[:in_reply_to],
        payload: { reflection: body['reflection'] || body[:reflection] }
      })

      json_response(200, result)
    end

    # Helpers

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
