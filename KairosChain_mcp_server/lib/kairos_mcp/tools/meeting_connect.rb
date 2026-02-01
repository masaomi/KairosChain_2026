# frozen_string_literal: true

require_relative 'base_tool'
require 'net/http'
require 'uri'
require 'json'
require 'securerandom'
require 'fileutils'

module KairosMcp
  module Tools
    # High-level tool for connecting to a Meeting Place and discovering peers/skills.
    # This tool combines: connect + register + discover + list skills
    # into a single user-friendly operation.
    class MeetingConnect < BaseTool
      def name
        'meeting_connect'
      end

      def description
        <<~DESC
          Connect to a Meeting Place server and discover available agents and their skills.
          
          This is the starting point for agent-to-agent communication. After connecting,
          you will see a list of available agents and their skills. You can then:
          - Use meeting_get_skill_details to learn more about specific skills
          - Use meeting_acquire_skill to obtain skills from other agents
          - Use meeting_disconnect when done
          
          Example: meeting_connect(url: "http://localhost:4568")
        DESC
      end

      def category
        :meeting
      end

      def usecase_tags
        %w[meeting connect discover agents skills network]
      end

      def examples
        [
          {
            title: 'Connect to a local Meeting Place',
            code: 'meeting_connect(url: "http://localhost:4568")'
          },
          {
            title: 'Connect with capability filter',
            code: 'meeting_connect(url: "http://meeting.example.com:4568", filter_capabilities: ["translation"])'
          }
        ]
      end

      def related_tools
        %w[meeting_get_skill_details meeting_acquire_skill meeting_disconnect]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            url: {
              type: 'string',
              description: 'URL of the Meeting Place server (e.g., http://localhost:4568)'
            },
            filter_capabilities: {
              type: 'array',
              items: { type: 'string' },
              description: 'Optional: Filter peers by required capabilities'
            },
            filter_tags: {
              type: 'array',
              items: { type: 'string' },
              description: 'Optional: Filter peers by tags'
            }
          },
          required: ['url']
        }
      end

      def call(arguments)
        url = arguments['url']
        filter_caps = arguments['filter_capabilities'] || []
        filter_tags = arguments['filter_tags'] || []

        # Check if Meeting Protocol is enabled
        unless meeting_enabled?
          return text_content(JSON.pretty_generate({
            error: 'Meeting Protocol is disabled',
            hint: 'Set enabled: true in config/meeting.yml to enable Meeting Protocol features'
          }))
        end

        begin
          # Step 1: Connect and get Meeting Place info
          place_info = get_meeting_place_info(url)
          
          # Step 2: Register ourselves (if not already registered)
          register_result = register_self(url)
          @current_agent_id = register_result[:agent_id]  # Store for self-exclusion
          
          # Step 3: Get list of available agents
          agents = list_agents(url, filter_caps, filter_tags)
          
          # Step 4: For each agent, get their skills summary
          # Note: Server returns 'id' not 'agent_id'
          peers_with_skills = agents.map do |agent|
            skills = get_agent_skills(agent)
            {
              agent_id: agent['id'] || agent[:id],
              name: agent['name'] || agent[:name],
              endpoint: agent['endpoint'] || agent[:endpoint],
              capabilities: agent['capabilities'] || agent[:capabilities] || [],
              skills: skills
            }
          end

          # Store connection state
          save_connection_state(url, peers_with_skills)

          # Build response
          result = {
            status: 'connected',
            meeting_place: {
              url: url,
              name: place_info['name'] || 'Meeting Place',
              features: place_info['features'] || []
            },
            self_registered: register_result[:registered],
            self_agent_id: register_result[:agent_id],
            peers_found: peers_with_skills.length,
            peers: peers_with_skills.map do |peer|
              {
                agent_id: peer[:agent_id],
                name: peer[:name],
                skill_count: peer[:skills].length,
                skills: peer[:skills].map { |s| { id: s[:id], name: s[:name], tags: s[:tags] || [] } }
              }
            end,
            hint: peers_with_skills.empty? ? 
              'No other agents found. Wait for others to connect or check the Meeting Place URL.' :
              'Use meeting_get_skill_details(peer_id, skill_id) to learn more about a skill.'
          }

          text_content(JSON.pretty_generate(result))
        rescue StandardError => e
          text_content(JSON.pretty_generate({
            error: "Failed to connect to Meeting Place",
            message: e.message,
            url: url
          }))
        end
      end

      private

      def meeting_enabled?
        config_path = find_meeting_config
        return false unless config_path && File.exist?(config_path)

        require 'yaml'
        config = YAML.load_file(config_path) || {}
        config['enabled'] == true
      end

      def find_meeting_config
        # Try workspace config first
        workspace_config = File.expand_path('../../../../config/meeting.yml', __FILE__)
        return workspace_config if File.exist?(workspace_config)
        nil
      end

      def load_meeting_config
        config_path = find_meeting_config
        return {} unless config_path && File.exist?(config_path)

        require 'yaml'
        YAML.load_file(config_path) || {}
      end

      def get_meeting_place_info(url)
        uri = URI.parse("#{url}/place/v1/info")
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          JSON.parse(response.body)
        else
          { 'name' => 'Unknown', 'features' => [] }
        end
      rescue StandardError
        { 'name' => 'Unknown', 'features' => [] }
      end

      def register_self(url)
        config = load_meeting_config
        identity = config['identity'] || {}
        
        agent_id = generate_agent_id
        
        uri = URI.parse("#{url}/place/v1/register")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        
        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate({
          agent_id: agent_id,
          name: identity['name'] || 'KairosChain Instance',
          endpoint: "http://localhost:#{config.dig('http_server', 'port') || 8080}",
          capabilities: config.dig('capabilities', 'supported_actions') || ['meeting_protocol']
        })
        
        response = http.request(request)
        
        if response.is_a?(Net::HTTPSuccess)
          { registered: true, agent_id: agent_id }
        else
          { registered: false, agent_id: agent_id, error: response.body }
        end
      rescue StandardError => e
        { registered: false, agent_id: generate_agent_id, error: e.message }
      end

      def generate_agent_id
        config = load_meeting_config
        identity = config['identity'] || {}
        name = identity['name'] || 'kairos'
        "#{name.downcase.gsub(/\s+/, '-')}-#{SecureRandom.hex(4)}"
      end

      def list_agents(url, filter_caps, filter_tags)
        uri = URI.parse("#{url}/place/v1/agents")
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          agents = data['agents'] || data[:agents] || []
          
          # Apply filters
          agents = agents.select do |agent|
            caps_match = filter_caps.empty? || 
              (agent['capabilities'] || []).any? { |c| filter_caps.include?(c) }
            tags_match = filter_tags.empty? ||
              (agent['tags'] || []).any? { |t| filter_tags.include?(t) }
            caps_match && tags_match
          end
          
          # Exclude self (server returns 'id', not 'agent_id')
          my_agent_id = @current_agent_id
          agents.reject { |a| (a['id'] || a[:id]) == my_agent_id }
        else
          []
        end
      rescue StandardError
        []
      end

      def get_agent_skills(agent)
        endpoint = agent['endpoint'] || agent[:endpoint]
        return [] unless endpoint
        
        uri = URI.parse("#{endpoint}/meeting/v1/skills")
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          skills = data['skills'] || data[:skills] || []
          skills.map do |s|
            {
              id: s['id'] || s[:id],
              name: s['name'] || s[:name],
              tags: s['tags'] || s[:tags] || [],
              format: s['format'] || s[:format] || 'markdown'
            }
          end
        else
          []
        end
      rescue StandardError
        []
      end

      def save_connection_state(url, peers)
        # Save connection state to a temp file for other tools to use
        state = {
          connected: true,
          url: url,
          connected_at: Time.now.utc.iso8601,
          peers: peers
        }
        
        state_dir = File.expand_path('../../../../storage', __FILE__)
        FileUtils.mkdir_p(state_dir)
        
        state_file = File.join(state_dir, 'meeting_connection.json')
        File.write(state_file, JSON.pretty_generate(state))
      end
    end
  end
end
