# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module KairosMcp
  module SkillSets
    module Hestia
      module Tools
        # Publish knowledge needs to a Meeting Place board.
        #
        # DEE compliance:
        # - Requires explicit opt_in: true (no silent publishing)
        # - Needs are session-only (in-memory on the Place, no persistence)
        # - No aggregation or ranking of needs (D3, D5)
        class MeetingPublishNeeds < KairosMcp::Tools::BaseTool
          def name
            'meeting_publish_needs'
          end

          def description
            'Publish knowledge needs (gaps) to a Meeting Place board. ' \
            'Other agents browsing the board can discover and offer relevant knowledge. ' \
            'Requires explicit opt-in and an active Meeting Place connection.'
          end

          def category
            :meeting_place
          end

          def usecase_tags
            %w[hestia meeting needs knowledge gaps cross-instance board publish]
          end

          def related_tools
            %w[skills_audit meeting_connect meeting_place_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                opt_in: {
                  type: 'boolean',
                  description: 'Explicit opt-in to publish knowledge needs. Must be true.'
                },
                mode_name: {
                  type: 'string',
                  description: 'Instruction mode name to check gaps for (defaults to current active mode)'
                }
              },
              required: ['opt_in']
            }
          end

          def call(arguments)
            unless arguments['opt_in'] == true
              return text_content(JSON.pretty_generate({
                error: 'opt_in_required',
                message: 'Publishing knowledge needs requires explicit opt-in. ' \
                         'Call with opt_in: true to confirm.'
              }))
            end

            # Load connection state
            connection_file = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            unless File.exist?(connection_file)
              return text_content(JSON.pretty_generate({
                error: 'not_connected',
                message: 'No active Meeting Place connection. Use meeting_connect first.'
              }))
            end

            connection = JSON.parse(File.read(connection_file), symbolize_names: true)
            unless connection[:connected]
              return text_content(JSON.pretty_generate({
                error: 'not_connected',
                message: 'Meeting Place connection is not active. Reconnect using meeting_connect.'
              }))
            end

            place_url = connection[:url] || connection.dig(:meeting_place, :url)
            agent_id = connection[:self_agent_id]

            unless place_url && agent_id
              return text_content(JSON.pretty_generate({
                error: 'invalid_connection',
                message: 'Connection state is missing url or agent_id. Reconnect using meeting_connect.'
              }))
            end

            # Compute knowledge needs using skills_audit logic
            audit_tool = KairosMcp::Tools::SkillsAudit.new
            mode_name = arguments['mode_name'] || audit_tool.send(:current_mode_name)
            needs_data = audit_tool.send(:build_knowledge_needs, mode_name)

            if needs_data[:needs].empty?
              return text_content(JSON.pretty_generate({
                status: 'no_needs',
                mode: mode_name,
                message: 'All baseline knowledge is present. Nothing to publish.'
              }))
            end

            # Read session token from connection state
            session_token = connection[:session_token]

            # POST needs to the Meeting Place board
            mmp_config = ::MMP.load_config rescue {}
            agent_name = mmp_config.dig('identity', 'name') || 'KairosChain Instance'

            post_body = {
              agent_id: agent_id,
              agent_name: agent_name,
              agent_mode: mode_name,
              needs: needs_data[:needs]
            }

            result = http_post(
              "#{place_url}/place/v1/board/needs",
              post_body,
              session_token
            )

            if result
              text_content(JSON.pretty_generate({
                status: 'published',
                mode: mode_name,
                needs_count: needs_data[:needs].size,
                needs: needs_data[:needs],
                place_url: place_url,
                session_only: true,
                hint: 'Needs are visible to other agents browsing the board. ' \
                      'They will be removed when you disconnect.'
              }))
            else
              text_content(JSON.pretty_generate({
                error: 'publish_failed',
                message: 'Failed to publish needs to Meeting Place. ' \
                         'The Place may be unreachable or the session may have expired.',
                place_url: place_url
              }))
            end
          rescue StandardError => e
            text_content(JSON.pretty_generate({
              error: 'unexpected_error',
              message: e.message
            }))
          end

          private

          def http_post(url, body, token = nil)
            uri = URI.parse(url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == 'https'
            req = Net::HTTP::Post.new(uri.path)
            req['Content-Type'] = 'application/json'
            req['Authorization'] = "Bearer #{token}" if token
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
