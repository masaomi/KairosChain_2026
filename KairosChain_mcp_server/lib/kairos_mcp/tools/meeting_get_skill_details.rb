# frozen_string_literal: true

require_relative 'base_tool'
require 'net/http'
require 'uri'
require 'json'

module KairosMcp
  module Tools
    # Tool for getting detailed information about a skill from another agent.
    # This helps users understand what a skill does before acquiring it.
    class MeetingGetSkillDetails < BaseTool
      def name
        'meeting_get_skill_details'
      end

      def description
        <<~DESC
          Get detailed information about a skill from another agent.
          
          Use this after meeting_connect to learn more about a specific skill before
          deciding to acquire it. Returns metadata like description, version, usage
          examples, and dependencies.
          
          You can also request a preview of the skill content (first few lines).
          
          Example: meeting_get_skill_details(peer_id: "agent-xyz", skill_id: "translation_skill")
        DESC
      end

      def category
        :meeting
      end

      def usecase_tags
        %w[meeting skill details preview metadata discovery]
      end

      def examples
        [
          {
            title: 'Get skill details',
            code: 'meeting_get_skill_details(peer_id: "agent-b-001", skill_id: "translation_skill")'
          },
          {
            title: 'Get skill details with preview',
            code: 'meeting_get_skill_details(peer_id: "agent-b-001", skill_id: "translation_skill", include_preview: true)'
          }
        ]
      end

      def related_tools
        %w[meeting_connect meeting_acquire_skill meeting_disconnect]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            peer_id: {
              type: 'string',
              description: 'ID of the peer agent (from meeting_connect results)'
            },
            skill_id: {
              type: 'string',
              description: 'ID of the skill to get details for'
            },
            include_preview: {
              type: 'boolean',
              description: 'Whether to include a preview of the skill content (default: false)'
            },
            preview_lines: {
              type: 'integer',
              description: 'Number of lines to include in preview (default: 10)'
            }
          },
          required: %w[peer_id skill_id]
        }
      end

      def call(arguments)
        peer_id = arguments['peer_id']
        skill_id = arguments['skill_id']
        include_preview = arguments['include_preview'] || false
        preview_lines = arguments['preview_lines'] || 10

        # Check if Meeting Protocol is enabled
        unless meeting_enabled?
          return text_content(JSON.pretty_generate({
            error: 'Meeting Protocol is disabled',
            hint: 'Set enabled: true in config/meeting.yml to enable Meeting Protocol features'
          }))
        end

        # Load connection state
        connection = load_connection_state
        unless connection && connection['connected']
          return text_content(JSON.pretty_generate({
            error: 'Not connected to Meeting Place',
            hint: 'Use meeting_connect first to connect to a Meeting Place'
          }))
        end

        # Find the peer
        peer = find_peer(connection, peer_id)
        unless peer
          return text_content(JSON.pretty_generate({
            error: "Peer not found: #{peer_id}",
            available_peers: connection['peers'].map { |p| p['agent_id'] || p[:agent_id] },
            hint: 'Use one of the available peer IDs from meeting_connect results'
          }))
        end

        begin
          # Get skill details from the peer
          endpoint = peer['endpoint'] || peer[:endpoint]
          details = get_skill_details(endpoint, skill_id)
          
          unless details
            return text_content(JSON.pretty_generate({
              error: "Skill not found: #{skill_id}",
              peer_id: peer_id,
              hint: 'Check the skill_id from meeting_connect results'
            }))
          end

          # Get preview if requested
          preview = nil
          if include_preview
            preview = get_skill_preview(endpoint, skill_id, preview_lines)
          end

          # Build response
          result = {
            peer_id: peer_id,
            peer_name: peer['name'] || peer[:name],
            skill: {
              id: skill_id,
              name: details['name'] || details[:name],
              version: details['version'] || details[:version] || '1.0.0',
              layer: details['layer'] || details[:layer] || 'L1',
              format: details['format'] || details[:format] || 'markdown',
              description: details['description'] || details[:description],
              tags: details['tags'] || details[:tags] || [],
              author: details['author'] || details[:author],
              created_at: details['created_at'] || details[:created_at],
              updated_at: details['updated_at'] || details[:updated_at],
              size_bytes: details['size_bytes'] || details[:size_bytes],
              dependencies: details['dependencies'] || details[:dependencies] || [],
              usage_examples: details['usage_examples'] || details[:usage_examples] || [],
              public: details['public'] || details[:public]
            },
            exchange_info: {
              allowed_formats: details['allowed_formats'] || ['markdown'],
              requires_approval: details.dig('exchange_info', 'requires_approval') || true
            }
          }

          if preview
            result[:preview] = {
              content: preview['preview'] || preview[:preview],
              lines_shown: preview['preview_lines'] || preview[:preview_lines] || preview_lines,
              total_lines: preview['total_lines'] || preview[:total_lines],
              truncated: preview['truncated'] || preview[:truncated] || true,
              content_hash: preview['content_hash'] || preview[:content_hash]
            }
          end

          result[:hint] = "To acquire this skill, use: meeting_acquire_skill(peer_id: \"#{peer_id}\", skill_id: \"#{skill_id}\")"

          text_content(JSON.pretty_generate(result))
        rescue StandardError => e
          text_content(JSON.pretty_generate({
            error: "Failed to get skill details",
            message: e.message,
            peer_id: peer_id,
            skill_id: skill_id
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
        workspace_config = File.expand_path('../../../../config/meeting.yml', __FILE__)
        return workspace_config if File.exist?(workspace_config)
        nil
      end

      def load_connection_state
        state_file = File.expand_path('../../../../storage/meeting_connection.json', __FILE__)
        return nil unless File.exist?(state_file)

        JSON.parse(File.read(state_file))
      rescue StandardError
        nil
      end

      def find_peer(connection, peer_id)
        peers = connection['peers'] || connection[:peers] || []
        peers.find { |p| (p['agent_id'] || p[:agent_id]) == peer_id }
      end

      def get_skill_details(endpoint, skill_id)
        # First try the details endpoint
        uri = URI.parse("#{endpoint}/meeting/v1/skill_details?skill_id=#{URI.encode_www_form_component(skill_id)}")
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          return data['metadata'] || data if data['available'] != false
        end

        # Fallback: get from skills list
        uri = URI.parse("#{endpoint}/meeting/v1/skills")
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          skills = data['skills'] || data[:skills] || []
          skill = skills.find { |s| (s['id'] || s[:id]) == skill_id }
          return skill if skill
        end

        nil
      rescue StandardError
        nil
      end

      def get_skill_preview(endpoint, skill_id, lines)
        uri = URI.parse("#{endpoint}/meeting/v1/skill_preview?skill_id=#{URI.encode_www_form_component(skill_id)}&lines=#{lines}")
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          JSON.parse(response.body)
        else
          nil
        end
      rescue StandardError
        nil
      end
    end
  end
end
