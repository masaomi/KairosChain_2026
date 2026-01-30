require 'json'
require_relative 'tool_registry'
require_relative 'version'
require_relative 'meeting/identity'
require_relative 'meeting/meeting_protocol'
require_relative 'meeting/skill_exchange'
require_relative 'meeting/interaction_log'

module KairosMcp
  class Protocol
    PROTOCOL_VERSION = '2024-11-05'
    MEETING_PROTOCOL_VERSION = '1.0.0'

    def initialize
      @tool_registry = ToolRegistry.new
      @meeting_identity = nil  # Lazy initialized after workspace is set
      @meeting_protocol = nil  # Lazy initialized after identity is set
      @skill_exchange = nil    # Lazy initialized after workspace is set
      @interaction_log = nil   # Lazy initialized after workspace is set
      @workspace_root = nil
      @initialized = false
    end

    def handle_message(line)
      request = parse_json(line)
      return nil unless request

      id = request['id']
      method = request['method']
      params = request['params'] || {}

      result = case method
               when 'initialize'
                 handle_initialize(params)
               when 'initialized'
                 return nil
               when 'tools/list'
                 handle_tools_list
               when 'tools/call'
                 handle_tools_call(params)
               # Meeting Protocol methods (Phase 1)
               when 'meeting/introduce'
                 handle_meeting_introduce(params)
               when 'meeting/capabilities'
                 handle_meeting_capabilities(params)
               when 'meeting/skills'
                 handle_meeting_skills(params)
               # Meeting Protocol methods (Phase 2)
               when 'meeting/offer_skill'
                 handle_meeting_offer_skill(params)
               when 'meeting/request_skill'
                 handle_meeting_request_skill(params)
               when 'meeting/accept'
                 handle_meeting_accept(params)
               when 'meeting/decline'
                 handle_meeting_decline(params)
               when 'meeting/skill_content'
                 handle_meeting_skill_content(params)
               when 'meeting/reflect'
                 handle_meeting_reflect(params)
               when 'meeting/process_message'
                 handle_meeting_process_message(params)
               when 'meeting/start_session'
                 handle_meeting_start_session(params)
               when 'meeting/end_session'
                 handle_meeting_end_session(params)
               when 'meeting/interaction_history'
                 handle_meeting_interaction_history(params)
               else
                 return nil
               end

      format_response(id, result)
    rescue StandardError => e
      format_error(id, -32603, "Internal error: #{e.message}")
    end

    private

    def parse_json(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def handle_initialize(params)
      roots = params['roots'] || params['workspaceFolders']
      @tool_registry.set_workspace(roots)
      @initialized = true

      # Initialize Meeting components with workspace root
      @workspace_root = extract_workspace_root(roots)
      @meeting_identity = Meeting::Identity.new(workspace_root: @workspace_root)
      @meeting_protocol = Meeting::MeetingProtocol.new(identity: @meeting_identity)
      @skill_exchange = Meeting::SkillExchange.new(
        config: @meeting_identity.config,
        workspace_root: @workspace_root
      )
      @interaction_log = Meeting::InteractionLog.new(workspace_root: @workspace_root)

      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {
          tools: {},
          meeting: {
            version: MEETING_PROTOCOL_VERSION,
            supported_actions: %w[
              introduce capabilities skills
              offer_skill request_skill accept decline
              skill_content reflect process_message
              start_session end_session interaction_history
            ]
          }
        },
        serverInfo: {
          name: 'kairos-mcp-server',
          version: KairosMcp::VERSION
        }
      }
    end

    def extract_workspace_root(roots)
      return nil unless roots.is_a?(Array) && !roots.empty?
      
      root = roots.first
      if root.is_a?(Hash) && root['uri']
        root['uri'].sub(/^file:\/\//, '')
      elsif root.is_a?(String)
        root.sub(/^file:\/\//, '')
      end
    end

    def handle_tools_list
      {
        tools: @tool_registry.list_tools
      }
    end

    def handle_tools_call(params)
      name = params['name']
      arguments = params['arguments'] || {}
      
      content = @tool_registry.call_tool(name, arguments)
      
      {
        content: content
      }
    end

    # Meeting Protocol Handlers

    def handle_meeting_introduce(_params)
      ensure_meeting_identity!
      @meeting_identity.introduce
    end

    def handle_meeting_capabilities(_params)
      ensure_meeting_identity!
      @meeting_identity.capabilities
    end

    def handle_meeting_skills(params)
      ensure_meeting_identity!
      
      # Filter options
      public_only = params['public_only'] != false  # Default to true
      
      skills = if public_only
                 @meeting_identity.public_skills
               else
                 @meeting_identity.introduce[:skills]
               end

      {
        skills: skills,
        exchange_policy: @meeting_identity.introduce[:exchange_policy]
      }
    end

    def ensure_meeting_identity!
      return if @meeting_identity

      # Create with default config if not initialized
      @meeting_identity = Meeting::Identity.new
    end

    def ensure_meeting_protocol!
      ensure_meeting_identity!
      return if @meeting_protocol

      @meeting_protocol = Meeting::MeetingProtocol.new(identity: @meeting_identity)
    end

    def ensure_skill_exchange!
      ensure_meeting_identity!
      return if @skill_exchange

      @skill_exchange = Meeting::SkillExchange.new(
        config: @meeting_identity.config,
        workspace_root: @workspace_root
      )
    end

    def ensure_interaction_log!
      return if @interaction_log

      @interaction_log = Meeting::InteractionLog.new(workspace_root: @workspace_root)
    end

    # Phase 2 Handlers

    def handle_meeting_offer_skill(params)
      ensure_meeting_protocol!
      ensure_interaction_log!

      skill_id = params['skill_id']
      to = params['to']

      raise ArgumentError, 'skill_id is required' unless skill_id

      message = @meeting_protocol.create_offer_skill(skill_id: skill_id, to: to)
      @interaction_log.log_outgoing(message)

      { message: message.to_h }
    end

    def handle_meeting_request_skill(params)
      ensure_meeting_protocol!
      ensure_interaction_log!

      description = params['description']
      to = params['to']

      raise ArgumentError, 'description is required' unless description

      message = @meeting_protocol.create_request_skill(description: description, to: to)
      @interaction_log.log_outgoing(message)

      { message: message.to_h }
    end

    def handle_meeting_accept(params)
      ensure_meeting_protocol!
      ensure_interaction_log!

      in_reply_to = params['in_reply_to']
      to = params['to']

      raise ArgumentError, 'in_reply_to is required' unless in_reply_to
      raise ArgumentError, 'to is required' unless to

      message = @meeting_protocol.create_accept(in_reply_to: in_reply_to, to: to)
      @interaction_log.log_outgoing(message)

      { message: message.to_h }
    end

    def handle_meeting_decline(params)
      ensure_meeting_protocol!
      ensure_interaction_log!

      in_reply_to = params['in_reply_to']
      to = params['to']
      reason = params['reason']

      raise ArgumentError, 'in_reply_to is required' unless in_reply_to
      raise ArgumentError, 'to is required' unless to

      message = @meeting_protocol.create_decline(in_reply_to: in_reply_to, to: to, reason: reason)
      @interaction_log.log_outgoing(message)

      { message: message.to_h }
    end

    def handle_meeting_skill_content(params)
      ensure_meeting_protocol!
      ensure_skill_exchange!
      ensure_interaction_log!

      in_reply_to = params['in_reply_to']
      to = params['to']
      skill_id = params['skill_id']

      raise ArgumentError, 'in_reply_to is required' unless in_reply_to
      raise ArgumentError, 'to is required' unless to
      raise ArgumentError, 'skill_id is required' unless skill_id

      # Find and package the skill
      skill = @meeting_identity.introduce[:skills].find { |s| s[:id] == skill_id }
      raise ArgumentError, "Skill not found: #{skill_id}" unless skill

      packaged = @skill_exchange.package_skill(skill[:path])
      
      message = @meeting_protocol.create_skill_content(
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

      { message: message.to_h, packaged_skill: packaged.except(:content) }
    end

    def handle_meeting_reflect(params)
      ensure_meeting_protocol!
      ensure_interaction_log!

      to = params['to']
      reflection = params['reflection']
      in_reply_to = params['in_reply_to']

      raise ArgumentError, 'to is required' unless to
      raise ArgumentError, 'reflection is required' unless reflection

      message = @meeting_protocol.create_reflect(to: to, reflection: reflection, in_reply_to: in_reply_to)
      @interaction_log.log_outgoing(message)

      { message: message.to_h }
    end

    def handle_meeting_process_message(params)
      ensure_meeting_protocol!
      ensure_skill_exchange!
      ensure_interaction_log!

      message = params['message']
      raise ArgumentError, 'message is required' unless message

      @interaction_log.log_incoming(message)
      result = @meeting_protocol.process_message(message)

      # If skill content was received, validate it
      if result[:action] == 'skill_content' && result[:status] == 'received'
        validation = @skill_exchange.validate_received_skill(
          content: result[:content],
          format: result[:format],
          content_hash: result[:content_hash]
        )
        result[:validation] = validation
      end

      result
    end

    def handle_meeting_start_session(params)
      ensure_interaction_log!

      peer_id = params['peer_id']
      raise ArgumentError, 'peer_id is required' unless peer_id

      session_id = @interaction_log.start_session(peer_id: peer_id)

      { session_id: session_id, peer_id: peer_id, started_at: Time.now.utc.iso8601 }
    end

    def handle_meeting_end_session(params)
      ensure_interaction_log!

      summary = params['summary']
      session_id = @interaction_log.end_session(summary: summary)

      { session_id: session_id, ended_at: Time.now.utc.iso8601, summary: summary }
    end

    def handle_meeting_interaction_history(params)
      ensure_interaction_log!

      peer_id = params['peer_id']
      limit = params['limit'] || 50

      if peer_id
        interactions = @interaction_log.history_with_peer(peer_id, limit: limit)
      else
        interactions = @interaction_log.all_interactions(limit: limit)
      end

      {
        interactions: interactions,
        summary: @interaction_log.summary
      }
    end

    def format_response(id, result)
      {
        jsonrpc: '2.0',
        id: id,
        result: result
      }
    end

    def format_error(id, code, message)
      {
        jsonrpc: '2.0',
        id: id,
        error: {
          code: code,
          message: message
        }
      }
    end
  end
end
