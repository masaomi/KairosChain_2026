# frozen_string_literal: true

require 'net/http'
require 'uri'
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
                skill_id: { type: 'string', description: 'ID of the skill' },
                include_preview: { type: 'boolean', description: 'Include content preview (default: false)' }
              },
              required: %w[peer_id skill_id]
            }
          end

          def call(arguments)
            peer_id = arguments['peer_id']
            skill_id = arguments['skill_id']
            include_preview = arguments['include_preview'] || false

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

              details = if relay_mode
                get_details_relay(url, skill_id)
              else
                get_details_direct(endpoint, skill_id)
              end

              unless details
                return text_content(JSON.pretty_generate({ error: "Skill not found: #{skill_id}" }))
              end

              result = {
                peer_id: peer_id,
                peer_name: peer['name'] || peer[:name],
                skill: {
                  id: skill_id,
                  name: details['name'] || details[:name],
                  description: details['description'] || details[:description],
                  version: details['version'] || details[:version] || '1.0.0',
                  format: details['format'] || details[:format] || 'markdown',
                  tags: details['tags'] || details[:tags] || [],
                  size_bytes: details['size_bytes'] || details[:size_bytes]
                },
                hint: "To acquire: meeting_acquire_skill(peer_id: \"#{peer_id}\", skill_id: \"#{skill_id}\")"
              }

              text_content(JSON.pretty_generate(result))
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

          def get_details_relay(url, skill_id)
            uri = URI.parse("#{url}/place/v1/skills/metadata/#{URI.encode_www_form_component(skill_id)}")
            response = Net::HTTP.get_response(uri)
            response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body, symbolize_names: true) : nil
          rescue StandardError; nil
          end

          def get_details_direct(endpoint, skill_id)
            uri = URI.parse("#{endpoint}/meeting/v1/skill_details?skill_id=#{URI.encode_www_form_component(skill_id)}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 3; http.read_timeout = 5
            response = http.get(uri.request_uri)
            response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body, symbolize_names: true) : nil
          rescue StandardError; nil
          end
        end
      end
    end
  end
end
