# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'digest'
require 'fileutils'
require 'securerandom'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingAcquireSkill < KairosMcp::Tools::BaseTool
          def name
            'meeting_acquire_skill'
          end

          def description
            'Acquire a skill from another agent. Automates: introduce -> request -> receive -> validate -> save.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting skill acquire exchange transfer]
          end

          def related_tools
            %w[meeting_connect meeting_get_skill_details meeting_disconnect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                peer_id: { type: 'string', description: 'ID of the peer agent' },
                skill_id: { type: 'string', description: 'ID of the skill to acquire' },
                save_to_layer: { type: 'string', enum: %w[L1 L2], description: 'Target layer (default: L1)' }
              },
              required: %w[peer_id skill_id]
            }
          end

          def call(arguments)
            peer_id = arguments['peer_id']
            skill_id = arguments['skill_id']
            save_layer = arguments['save_to_layer'] || 'L1'

            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
            end

            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ error: 'Not connected', hint: 'Use meeting_connect first' }))
            end

            peer = find_peer(connection, peer_id)
            unless peer
              return text_content(JSON.pretty_generate({ error: "Peer not found: #{peer_id}" }))
            end

            begin
              relay_mode = connection['relay_mode'] || connection[:relay_mode]
              url = connection['url'] || connection[:url]
              endpoint = peer['endpoint'] || peer[:endpoint]

              # Use peer's endpoint if available, otherwise fall back to
              # the connection URL (e.g. Meeting Place's own MMP endpoint)
              target = endpoint || url
              token = connection['session_token'] || connection[:session_token]
              content_result = get_skill_direct(target, skill_id, bearer_token: token)

              unless content_result[:success]
                return text_content(JSON.pretty_generate({ error: 'Failed to receive skill', message: content_result[:error] }))
              end

              # Validate
              exchange = ::MMP::SkillExchange.new(config: config, workspace_root: KairosMcp.data_dir)
              validation = exchange.validate_received_skill(content_result)

              unless validation[:valid]
                return text_content(JSON.pretty_generate({ error: 'Validation failed', issues: validation[:errors] }))
              end

              # Save
              save_result = exchange.store_received_skill(
                { skill_name: content_result[:skill_name], content: content_result[:content], content_hash: content_result[:content_hash], format: content_result[:format], from: peer_id },
                target_layer: save_layer
              )

              # Auto-save trusted peer to L1 knowledge
              peer_name = peer['name'] || peer[:name] || peer_id
              place_url = connection['url'] || connection[:url]
              peer_saved = save_trusted_peer(
                agent_id: peer_id,
                name: peer_name,
                place_url: place_url,
                skill_acquired: { id: skill_id, name: content_result[:skill_name] }
              )

              result = {
                status: 'acquired', peer_id: peer_id,
                skill: { id: skill_id, name: content_result[:skill_name], format: content_result[:format], content_hash: content_result[:content_hash] },
                saved_to: { layer: save_layer, path: save_result[:path] },
                provenance: save_result[:provenance],
                trusted_peer_saved: peer_saved
              }

              text_content(JSON.pretty_generate(result))
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Failed to acquire skill', message: e.message }))
            end
          end

          private

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError; nil
          end

          def find_peer(connection, peer_id)
            (connection['peers'] || connection[:peers] || []).find { |p| (p['agent_id'] || p[:agent_id]) == peer_id }
          end

          MAX_TRUSTED_PEERS = 100

          # Save or update a trusted peer in L1 knowledge.
          # Returns true on success, false on failure.
          def save_trusted_peer(agent_id:, name:, place_url:, skill_acquired:)
            dir = File.join(KairosMcp.data_dir, 'knowledge', 'trusted_peers')
            FileUtils.mkdir_p(dir)
            filepath = File.join(dir, 'trusted_peers.md')
            now = Time.now.utc.iso8601

            peers = load_trusted_peers_data(filepath)

            # Find or create peer entry
            existing = peers.find { |p| p['agent_id'] == agent_id }
            if existing
              existing['name'] = name
              existing['last_interaction'] = now
              existing['places_seen'] ||= []
              existing['places_seen'] << place_url unless existing['places_seen'].include?(place_url)
              existing['skills_acquired'] ||= []
              unless existing['skills_acquired'].any? { |s| s['id'] == skill_acquired[:id] }
                existing['skills_acquired'] << { 'id' => skill_acquired[:id], 'name' => skill_acquired[:name], 'acquired_at' => now }
              end
            else
              peers << {
                'agent_id' => agent_id,
                'name' => name,
                'first_met' => now,
                'last_interaction' => now,
                'places_seen' => [place_url],
                'skills_acquired' => [{ 'id' => skill_acquired[:id], 'name' => skill_acquired[:name], 'acquired_at' => now }]
              }
            end

            # LRU eviction: keep most recently interacted peers
            if peers.size > MAX_TRUSTED_PEERS
              peers = peers.sort_by { |p| p['last_interaction'] || '' }.last(MAX_TRUSTED_PEERS)
            end

            write_trusted_peers(filepath, peers)
            true
          rescue StandardError => e
            warn "[MeetingAcquireSkill] Failed to save trusted peer: #{e.message}"
            false
          end

          def load_trusted_peers_data(filepath)
            return [] unless File.exist?(filepath)
            content = File.read(filepath)
            return [] unless content.start_with?('---')
            parts = content.split(/^---\s*$/, 3)
            return [] if parts.length < 3
            frontmatter = YAML.safe_load(parts[1]) rescue nil
            return [] unless frontmatter.is_a?(Hash)
            frontmatter['peers'] || []
          end

          def write_trusted_peers(filepath, peers)
            frontmatter = {
              'name' => 'trusted_peers',
              'tags' => %w[meeting peers bookmark trust],
              'updated_at' => Time.now.utc.iso8601,
              'peers' => peers
            }
            content = "---\n#{frontmatter.to_yaml}---\n\n# Trusted Peers\n\nPeers from whom skills were successfully acquired.\nAuto-managed by meeting_acquire_skill. Max #{MAX_TRUSTED_PEERS} entries (LRU).\n"
            File.write(filepath, content)
          end

          def get_skill_from_relay(url, skill_id)
            uri = URI.parse("#{url}/place/v1/skills/content/#{URI.encode_www_form_component(skill_id)}")
            response = Net::HTTP.get_response(uri)
            if response.is_a?(Net::HTTPSuccess)
              data = JSON.parse(response.body, symbolize_names: true)
              { success: true, skill_name: data[:name] || skill_id, format: data[:format] || 'markdown', content: data[:content], content_hash: data[:content_hash], size_bytes: data[:content]&.bytesize || 0 }
            else
              { success: false, error: "HTTP #{response.code}" }
            end
          rescue StandardError => e
            { success: false, error: e.message }
          end

          def get_skill_direct(endpoint, skill_id, bearer_token: nil)
            uri = URI.parse("#{endpoint}/meeting/v1/skill_content")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 5; http.read_timeout = 10
            req = Net::HTTP::Post.new(uri.path)
            req['Content-Type'] = 'application/json'
            req['Authorization'] = "Bearer #{bearer_token}" if bearer_token
            req.body = JSON.generate({ skill_id: skill_id })
            response = http.request(req)
            if response.is_a?(Net::HTTPSuccess)
              data = JSON.parse(response.body, symbolize_names: true)
              payload = data.dig(:message, :payload) || data[:payload] || data
              { success: true, skill_name: payload[:skill_name] || skill_id, format: payload[:format] || 'markdown', content: payload[:content], content_hash: payload[:content_hash], size_bytes: payload[:content]&.bytesize || 0 }
            else
              { success: false, error: response.body }
            end
          rescue StandardError => e
            { success: false, error: e.message }
          end
        end
      end
    end
  end
end
