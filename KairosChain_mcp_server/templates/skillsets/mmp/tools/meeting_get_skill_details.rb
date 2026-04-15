# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingGetSkillDetails < KairosMcp::Tools::BaseTool
          def name
            'meeting_get_skill_details'
          end

          def description
            'Get detailed information about a skill from another agent before acquiring it.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting skill details preview metadata]
          end

          def related_tools
            %w[meeting_connect meeting_acquire_skill meeting_disconnect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                peer_id: { type: 'string', description: 'ID of the peer agent' },
                skill_id: { type: 'string', description: 'ID of the skill' }
              },
              required: %w[peer_id skill_id]
            }
          end

          def call(arguments)
            peer_id = arguments['peer_id']
            skill_id = arguments['skill_id']

            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ error: 'Not connected', hint: 'Use meeting_connect first' }))
            end

            peer = find_peer(connection, peer_id)
            unless peer
              return text_content(JSON.pretty_generate({ error: "Peer not found: #{peer_id}" }))
            end

            begin
              # Target: peer endpoint if available, otherwise Place URL
              endpoint = peer['endpoint'] || peer[:endpoint]
              url = connection['url'] || connection[:url]
              target = endpoint || url

              client = build_meeting_client(url_override: target, timeout: 5)
              return client if client.is_a?(Array)

              raw = client.get_skill_details(skill_id: skill_id)
              details = adapt_skill_details(raw)

              if details.nil?
                return text_content(JSON.pretty_generate({ error: "Skill not found: #{skill_id}" }))
              end

              if details[:error]
                return text_content(JSON.pretty_generate({ error: details[:error], message: details[:message] }))
              end

              result = {
                peer_id: peer_id,
                peer_name: peer['name'] || peer[:name],
                skill: {
                  id: skill_id,
                  name: details[:name],
                  description: details[:description],
                  version: details[:version],
                  format: details[:format],
                  tags: details[:tags],
                  size_bytes: details[:size_bytes]
                },
                hint: "To acquire: meeting_acquire_skill(peer_id: \"#{peer_id}\", skill_id: \"#{skill_id}\")"
              }

              # Check for pending attestation nudge
              nudge_msg = nil
              begin
                nudge_msg = ::MMP::AttestationNudge.instance.pending_nudge
              rescue StandardError => e
                warn "[MMP] Nudge check failed: #{e.message}"
              end

              result_text = JSON.pretty_generate(result)
              result_text += "\n\n---\n#{nudge_msg}" if nudge_msg
              text_content(result_text)
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Failed to get details', message: e.message }))
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

          # Adapter A3: skill_details response normalization
          # Distinguishes "not found" from auth/network errors (R3-1 fix)
          def adapt_skill_details(raw)
            if raw[:error]
              # Distinguish not_found from other errors
              if raw[:error].to_s.include?('not_found') || raw[:error].to_s.include?('404')
                nil
              else
                { error: raw[:error], message: raw[:message] }
              end
            else
              meta = raw[:metadata] || raw
              {
                name: meta[:name],
                description: meta[:description] || meta[:summary],
                version: meta[:version] || '1.0',
                format: meta[:format] || 'markdown',
                tags: meta[:tags] || [],
                size_bytes: meta[:size_bytes]
              }
            end
          end
        end
      end
    end
  end
end
