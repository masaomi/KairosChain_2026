# frozen_string_literal: true

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
                peer_id: { type: 'string', description: 'ID of the peer agent (optional if acquiring from Place deposits)' },
                skill_id: { type: 'string', description: 'ID of the skill to acquire' },
                owner_agent_id: { type: 'string', description: 'Owner agent ID for deposited skills (optional, used with Place deposits)' },
                save_to_layer: { type: 'string', enum: %w[L1 L2], description: 'Target layer (default: L1)' }
              },
              required: %w[skill_id]
            }
          end

          def call(arguments)
            peer_id = arguments['peer_id']
            skill_id = arguments['skill_id']
            owner_agent_id = arguments['owner_agent_id']
            save_layer = arguments['save_to_layer'] || 'L1'

            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ error: 'Not connected', hint: 'Use meeting_connect first' }))
            end

            begin
              url = connection['url'] || connection[:url]

              if peer_id
                # Peer direct path: /meeting/v1/skill_content
                peer = find_peer(connection, peer_id)
                unless peer
                  return text_content(JSON.pretty_generate({ error: "Peer not found: #{peer_id}" }))
                end
                endpoint = peer['endpoint'] || peer[:endpoint]
                target = endpoint || url

                meeting_client = build_meeting_client(url_override: target)
                return meeting_client if meeting_client.is_a?(Array)

                raw = meeting_client.request_skill_content(skill_id: skill_id)
                content_result = adapt_peer_skill_content(raw, skill_id)
                source_id = peer_id
                source_name = peer['name'] || peer[:name] || peer_id
              else
                # Place deposit path: /place/v1/skill_content/:id
                place_client = build_place_client
                return place_client if place_client.is_a?(Array)

                raw = place_client.get_skill_content(skill_id: skill_id, owner: owner_agent_id)
                content_result = adapt_place_skill_content(raw, skill_id)
                source_id = content_result[:depositor_id] || owner_agent_id || 'place'
                source_name = source_id
              end

              unless content_result[:success]
                return text_content(JSON.pretty_generate({ error: 'Failed to receive skill', message: content_result[:error] }))
              end

              # Validate (client-side check)
              exchange = ::MMP::SkillExchange.new(config: config, workspace_root: KairosMcp.data_dir)
              validation = exchange.validate_received_skill(content_result)

              unless validation[:valid]
                return text_content(JSON.pretty_generate({ error: 'Validation failed', issues: validation[:errors] }))
              end

              # Save
              save_result = exchange.store_received_skill(
                { skill_name: content_result[:skill_name], content: content_result[:content], content_hash: content_result[:content_hash], format: content_result[:format], from: source_id },
                target_layer: save_layer
              )

              # Auto-save trusted peer to L1 knowledge
              place_url = url
              peer_saved = save_trusted_peer(
                agent_id: source_id,
                name: source_name,
                place_url: place_url,
                skill_acquired: { id: skill_id, name: content_result[:skill_name] }
              )

              # Register for attestation nudge tracking
              begin
                ::MMP::AttestationNudge.instance.register_acquisition(
                  skill_id: skill_id,
                  skill_name: content_result[:skill_name],
                  owner_agent_id: source_id,
                  content_hash: content_result[:content_hash],
                  file_path: save_result[:path]
                )
              rescue StandardError => e
                warn "[MeetingAcquireSkill] Nudge registration failed: #{e.message}"
              end

              result = {
                status: 'acquired',
                source: peer_id ? 'peer' : 'place_deposit',
                source_id: source_id,
                skill: { id: skill_id, name: content_result[:skill_name], format: content_result[:format], content_hash: content_result[:content_hash] },
                saved_to: { layer: save_layer, path: save_result[:path] },
                provenance: save_result[:provenance],
                trusted_peer_saved: peer_saved
              }

              # Include trust_notice if from Place deposit
              result[:trust_notice] = content_result[:trust_notice] if content_result[:trust_notice]

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

          # Build PlaceClient with session_token for /place/v1/* endpoints
          def build_place_client(timeout: 10)
            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
            end
            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ error: 'Not connected', hint: 'Use meeting_connect first' }))
            end
            url = connection['url'] || connection[:url]
            token = connection['session_token'] || connection[:session_token]
            agent_id = connection['agent_id'] || connection[:agent_id]
            identity = ::MMP::Identity.new(config: config)
            ::MMP::PlaceClient.reconnect(
              place_url: url, identity: identity,
              session_token: token, agent_id: agent_id, timeout: timeout
            )
          end

          # Build PlaceClient with meeting_session_token for /meeting/v1/* endpoints
          def build_meeting_client(url_override: nil, timeout: 10)
            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
            end
            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ error: 'Not connected', hint: 'Use meeting_connect first' }))
            end
            url = url_override || connection['url'] || connection[:url]
            token = connection['meeting_session_token'] || connection[:meeting_session_token]
            unless token
              return text_content(JSON.pretty_generate({
                error: 'No meeting session token',
                hint: 'meeting_connect may have failed the /meeting/v1/introduce handshake. Reconnect.'
              }))
            end
            identity = ::MMP::Identity.new(config: config)
            ::MMP::PlaceClient.reconnect(
              place_url: url, identity: identity,
              session_token: token, timeout: timeout
            )
          end

          # Adapter A1: Place deposit skill content
          def adapt_place_skill_content(raw, skill_id)
            if raw[:error]
              { success: false, error: raw[:error] }
            else
              {
                success: true,
                name: raw[:name] || skill_id,
                skill_name: raw[:name] || skill_id,
                format: raw[:format] || 'markdown',
                content: raw[:content],
                content_hash: raw[:content_hash],
                size_bytes: raw[:content]&.bytesize || 0,
                depositor_id: raw[:depositor_id],
                trust_notice: raw[:trust_notice]
              }
            end
          end

          # Adapter A2: Peer direct skill content
          def adapt_peer_skill_content(raw, skill_id)
            if raw[:error]
              { success: false, error: raw[:error] }
            else
              payload = raw.dig(:message, :payload) || raw[:payload] || raw
              {
                success: true,
                skill_name: payload[:skill_name] || skill_id,
                format: payload[:format] || 'markdown',
                content: payload[:content],
                content_hash: payload[:content_hash],
                size_bytes: payload[:content]&.bytesize || 0
              }
            end
          end

          MAX_TRUSTED_PEERS = 100

          def save_trusted_peer(agent_id:, name:, place_url:, skill_acquired:)
            dir = File.join(KairosMcp.data_dir, 'knowledge', 'trusted_peers')
            FileUtils.mkdir_p(dir)
            filepath = File.join(dir, 'trusted_peers.md')
            now = Time.now.utc.iso8601

            peers = load_trusted_peers_data(filepath)

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
        end
      end
    end
  end
end
