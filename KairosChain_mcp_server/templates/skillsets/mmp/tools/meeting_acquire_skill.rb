# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
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

              content_result = if relay_mode
                get_skill_from_relay(url, skill_id)
              else
                get_skill_direct(endpoint, skill_id)
              end

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

              result = {
                status: 'acquired', peer_id: peer_id,
                skill: { id: skill_id, name: content_result[:skill_name], format: content_result[:format], content_hash: content_result[:content_hash] },
                saved_to: { layer: save_layer, path: save_result[:path] },
                provenance: save_result[:provenance]
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

          def get_skill_direct(endpoint, skill_id)
            uri = URI.parse("#{endpoint}/meeting/v1/skill_content")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 5; http.read_timeout = 10
            req = Net::HTTP::Post.new(uri.path)
            req['Content-Type'] = 'application/json'
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
