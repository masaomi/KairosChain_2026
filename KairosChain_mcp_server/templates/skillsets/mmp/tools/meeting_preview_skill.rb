# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingPreviewSkill < KairosMcp::Tools::BaseTool
          def name
            'meeting_preview_skill'
          end

          def description
            'Preview a deposited skill on a connected Meeting Place without full download. Returns summary, section headers, first N lines, and trust metadata. Use this before meeting_acquire_skill to decide if a skill is relevant.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting preview inspect evaluate skill]
          end

          def related_tools
            %w[meeting_browse meeting_acquire_skill meeting_get_skill_details]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                skill_id: {
                  type: 'string',
                  description: 'ID of the skill to preview'
                },
                owner_agent_id: {
                  type: 'string',
                  description: 'Owner agent ID for exact match (optional, use when multiple agents deposited skills with the same name)'
                },
                first_lines: {
                  type: 'integer',
                  description: 'Number of content lines to include in preview (default: 30)'
                }
              },
              required: %w[skill_id]
            }
          end

          def call(arguments)
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

            begin
              result = preview_from_place(
                url, token,
                arguments['skill_id'],
                owner: arguments['owner_agent_id'],
                first_lines: arguments['first_lines'] || 30
              )

              if result[:error]
                return text_content(JSON.pretty_generate({
                  error: result[:error],
                  message: result[:message] || 'Preview failed'
                }))
              end

              output = {
                status: 'ok',
                skill_id: result[:skill_id],
                name: result[:name],
                description: result[:description],
                tags: result[:tags],
                format: result[:format],
                size_bytes: result[:size_bytes],
                deposited_at: result[:deposited_at],
                depositor_id: result[:depositor_id],
                summary: result[:summary],
                sections: result[:sections],
                first_lines: result[:first_lines],
                trust_metadata: result[:trust_metadata],
                hint: 'Use meeting_acquire_skill to download the full content.'
              }
              output[:input_output] = result[:input_output] if result[:input_output]

              text_content(JSON.pretty_generate(output))
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Preview failed', message: e.message }))
            end
          end

          private

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError; nil
          end

          def preview_from_place(url, token, skill_id, owner: nil, first_lines: 30)
            encoded = URI.encode_www_form_component(skill_id)
            params = { 'first_lines' => first_lines.to_s }
            params['owner'] = owner if owner
            query = URI.encode_www_form(params)
            uri = URI.parse("#{url}/place/v1/preview/#{encoded}?#{query}")
            http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = (uri.scheme == 'https')
            http.open_timeout = 5; http.read_timeout = 10
            req = Net::HTTP::Get.new(uri)
            req['Authorization'] = "Bearer #{token}" if token
            response = http.request(req)
            JSON.parse(response.body, symbolize_names: true)
          rescue StandardError => e
            { error: e.message }
          end
        end
      end
    end
  end
end
