# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'securerandom'
require 'fileutils'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingConnect < KairosMcp::Tools::BaseTool
          def name
            'meeting_connect'
          end

          def description
            'Connect to a Meeting Place or directly to another KairosChain peer. Discovers available agents and their skills for exchange.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting connect discover agents skills network p2p]
          end

          def related_tools
            %w[meeting_get_skill_details meeting_acquire_skill meeting_disconnect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                url: { type: 'string', description: 'URL of the Meeting Place or peer (e.g., http://localhost:8080)' },
                mode: { type: 'string', enum: %w[relay direct], description: 'Connection mode: relay (via Meeting Place) or direct (P2P). Default: relay' },
                filter_capabilities: { type: 'array', items: { type: 'string' }, description: 'Filter peers by capabilities' }
              },
              required: ['url']
            }
          end

          def call(arguments)
            url = arguments['url']
            mode = arguments['mode'] || 'relay'
            filter_caps = arguments['filter_capabilities'] || []

            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled', hint: 'Set enabled: true in the MMP SkillSet config/meeting.yml' }))
            end

            begin
              if mode == 'direct'
                result = connect_direct(url, config)
              else
                result = connect_relay(url, config, filter_caps)
              end

              save_connection_state(result)
              text_content(JSON.pretty_generate(result))
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Failed to connect', message: e.message, url: url }))
            end
          end

          private

          def connect_direct(url, config)
            identity = ::MMP::Identity.new(config: config)
            peer_mgr = ::MMP::PeerManager.new(identity: identity, config: config)
            peer = peer_mgr.add_peer(url)

            if peer
              { status: 'connected', mode: 'direct', url: url, peer: { id: peer.id, name: peer.name, url: peer.url }, peers: [{ agent_id: peer.id, name: peer.name, endpoint: peer.url, skills: (peer.introduction&.dig(:skills) || []).map { |s| { id: s[:id], name: s[:name] } } }] }
            else
              { status: 'failed', mode: 'direct', url: url, error: 'Could not connect to peer' }
            end
          end

          def connect_relay(url, config, filter_caps)
            agent_id = generate_agent_id(config)

            place_info = http_get("#{url}/place/v1/info") || { 'name' => 'Unknown' }

            register_result = http_post("#{url}/place/v1/register", {
              agent_id: agent_id,
              name: config.dig('identity', 'name') || 'KairosChain Instance',
              capabilities: config.dig('capabilities', 'supported_actions') || ['meeting_protocol']
            })

            agents_data = http_get("#{url}/place/v1/agents") || { agents: [] }
            agents = (agents_data[:agents] || agents_data['agents'] || [])
            agents = agents.reject { |a| (a['id'] || a[:id]) == agent_id }
            agents = agents.select { |a| filter_caps.empty? || (a['capabilities'] || []).any? { |c| filter_caps.include?(c) } }

            {
              status: 'connected', mode: 'relay', url: url, relay_mode: true,
              meeting_place: { url: url, name: place_info['name'] || place_info[:name] || 'Meeting Place' },
              self_agent_id: agent_id,
              peers: agents.map { |a| { agent_id: a['id'] || a[:id], name: a['name'] || a[:name], endpoint: a['endpoint'] || a[:endpoint], skills: [] } },
              hint: agents.empty? ? 'No peers found. Wait for others to connect.' : 'Use meeting_get_skill_details to learn about a skill.'
            }
          end

          def generate_agent_id(config)
            fixed = config.dig('identity', 'agent_id')
            return fixed if fixed
            name = config.dig('identity', 'name') || 'kairos'
            "#{name.downcase.gsub(/\s+/, '-')}-#{SecureRandom.hex(4)}"
          end

          def save_connection_state(result)
            state_dir = KairosMcp.storage_dir
            FileUtils.mkdir_p(state_dir)
            File.write(File.join(state_dir, 'meeting_connection.json'), JSON.pretty_generate(result.merge(connected: true, connected_at: Time.now.utc.iso8601)))
          rescue StandardError => e
            warn "[MeetingConnect] Failed to save state: #{e.message}"
          end

          def http_get(url)
            uri = URI.parse(url)
            response = Net::HTTP.get_response(uri)
            response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body, symbolize_names: true) : nil
          rescue StandardError
            nil
          end

          def http_post(url, body)
            uri = URI.parse(url)
            http = Net::HTTP.new(uri.host, uri.port)
            req = Net::HTTP::Post.new(uri.path)
            req['Content-Type'] = 'application/json'
            req.body = JSON.generate(body)
            response = http.request(req)
            response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body, symbolize_names: true) : nil
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
