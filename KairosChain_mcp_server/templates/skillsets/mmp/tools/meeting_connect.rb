# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
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

            unless peer
              return { status: 'failed', mode: 'direct', url: url, error: 'Could not connect to peer' }
            end

            skill_counts = count_local_skills(config)
            peers_list = [{ agent_id: peer.id, name: peer.name, endpoint: peer.url, skills: (peer.introduction&.dig(:skills) || []).map { |s| { id: s[:id], name: s[:name] } } }]
            trusted_matches = find_trusted_peers_in(peers_list)

            result = {
              status: 'connected', mode: 'direct', url: url,
              peer: { id: peer.id, name: peer.name, url: peer.url },
              your_skills: skill_counts,
              peers: peers_list
            }

            if skill_counts[:public] == 0
              result[:suggestion] = "You have no public skills (#{skill_counts[:total]} total). Other agents cannot discover your skills. To share, set publish: true in skill frontmatter."
            end

            unless trusted_matches.empty?
              result[:trusted_peers_present] = trusted_matches
            end

            result
          end

          def connect_relay(url, config, filter_caps)
            identity = ::MMP::Identity.new(config: config)
            # Use Identity's own crypto to ensure the same keypair is used
            # for both signing (in PlaceClient.register) and the public key
            # attached to the introduction. Identity handles key generation,
            # saving, and loading from the correct path.
            identity_crypto = identity.crypto

            client = ::MMP::PlaceClient.new(
              place_url: url,
              identity: identity,
              crypto: identity_crypto,
              config: {
                max_session_minutes: config.dig('meeting_place', 'max_session_minutes') || 120,
                warn_after_interactions: config.dig('meeting_place', 'warn_after_interactions') || 50
              }
            )

            connect_result = client.connect
            agent_id = connect_result[:agent_id] || identity.introduce.dig(:identity, :instance_id)
            verified = connect_result[:identity_verified]
            session_token = connect_result[:session_token]

            place_info = http_get("#{url}/place/v1/info") || { 'name' => 'Unknown' }

            agents = []
            if verified && client.connected
              agents_data = client.list_agents || { agents: [] }
              agents = (agents_data[:agents] || [])
              agents = agents.reject { |a| (a[:id] || a['id']) == agent_id }
              agents = agents.select { |a| filter_caps.empty? || (a[:capabilities] || a['capabilities'] || []).is_a?(Hash) || filter_caps.empty? } unless filter_caps.empty?
            end

            # Also perform MMP introduce handshake to get a meeting session token
            # for accessing /meeting/v1/* endpoints on the Place
            meeting_session_token = nil
            begin
              intro = identity.introduce
              intro_result = http_post("#{url}/meeting/v1/introduce", intro)
              meeting_session_token = intro_result[:session_token] if intro_result
            rescue StandardError
              # Non-fatal: skill exchange may still work without this
            end

            # Scan local public skills for suggestion
            skill_counts = count_local_skills(config)

            # Check for trusted peers
            peers_list = agents.map { |a| { agent_id: a[:id] || a['id'], name: a[:name] || a['name'], endpoint: a[:endpoint] || a['endpoint'], skills: [] } }
            trusted_matches = find_trusted_peers_in(peers_list)

            result = {
              status: 'connected', mode: 'relay', url: url, relay_mode: true,
              identity_verified: verified,
              session_token: meeting_session_token,
              meeting_place: { url: url, name: place_info['name'] || place_info[:name] || 'Meeting Place' },
              self_agent_id: agent_id,
              your_skills: skill_counts,
              peers: peers_list,
              hint: agents.empty? ? 'No peers found. Wait for others to connect.' : 'Use meeting_get_skill_details to learn about a skill.'
            }

            # Add suggestion if no public skills
            if skill_counts[:public] == 0
              result[:suggestion] = "You have no public skills (#{skill_counts[:total]} total). Other agents cannot discover your skills. To share, set publish: true in skill frontmatter."
            elsif skill_counts[:public] > 0
              result[:deposit_hint] = "You have #{skill_counts[:public]} public skills. Use meeting_deposit to share them on this Meeting Place."
            end

            # Add trusted peer notification
            unless trusted_matches.empty?
              result[:trusted_peers_present] = trusted_matches
            end

            result
          end

          def generate_agent_id(config)
            fixed = config.dig('identity', 'agent_id')
            return fixed if fixed
            name = config.dig('identity', 'name') || 'kairos'
            "#{name.downcase.gsub(/\s+/, '-')}-#{SecureRandom.hex(4)}"
          end

          # Count local skills (total and public) by scanning knowledge directory
          def count_local_skills(config)
            knowledge_dir = File.join(KairosMcp.data_dir, 'knowledge')
            return { total: 0, public: 0 } unless Dir.exist?(knowledge_dir)

            exclude_dirs = %w[trusted_peers received received_skills]
            total = 0
            public_count = 0
            Dir.glob(File.join(knowledge_dir, '**', '*.md')).each do |f|
              next if exclude_dirs.any? { |d| f.include?("/#{d}/") }
              content = File.read(f)
              next unless content.start_with?('---')
              parts = content.split(/^---\s*$/, 3)
              next if parts.length < 3
              frontmatter = YAML.safe_load(parts[1]) rescue next
              next unless frontmatter.is_a?(Hash)
              total += 1
              public_count += 1 if frontmatter['publish'] == true
            end
            { total: total, public: public_count }
          rescue StandardError
            { total: 0, public: 0 }
          end

          # Load trusted_peers from L1 knowledge and match against connected peers
          def find_trusted_peers_in(peers_list)
            trusted_file = File.join(KairosMcp.data_dir, 'knowledge', 'trusted_peers', 'trusted_peers.md')
            return [] unless File.exist?(trusted_file)

            content = File.read(trusted_file)
            return [] unless content.start_with?('---')
            parts = content.split(/^---\s*$/, 3)
            return [] if parts.length < 3
            frontmatter = YAML.safe_load(parts[1]) rescue nil
            return [] unless frontmatter.is_a?(Hash)

            trusted_list = frontmatter['peers'] || []
            peer_ids = peers_list.map { |p| p[:agent_id] || p['agent_id'] }

            trusted_list.select { |t| peer_ids.include?(t['agent_id']) }
                        .map { |t| { agent_id: t['agent_id'], name: t['name'], previously_acquired: (t['skills_acquired'] || []).size } }
          rescue StandardError
            []
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
