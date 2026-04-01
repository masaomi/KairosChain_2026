# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module KairosMcp
  module SkillSets
    module SkillsetExchange
      module Tools
        class SkillsetBrowse < KairosMcp::Tools::BaseTool
          def name
            'skillset_browse'
          end

          def description
            'Browse SkillSets deposited to a connected Meeting Place. Returns DEE-compliant random sample (no ranking).'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting browse skillset exchange discover catalog search]
          end

          def related_tools
            %w[skillset_deposit skillset_acquire meeting_connect meeting_browse]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                search: { type: 'string', description: 'Search in SkillSet name/description/tags (optional)' },
                page_size: { type: 'integer', description: 'Number of results (default: 20, max: 50)' }
              },
              required: []
            }
          end

          def call(arguments)
            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({
                error: 'Not connected',
                hint: 'Use meeting_connect first'
              }))
            end

            url = connection['url'] || connection[:url]
            token = connection['session_token'] || connection[:session_token]

            begin
              page_size = [[arguments['page_size'] || 20, 50].min, 1].max
              params = { 'limit' => page_size.to_s }
              params['search'] = arguments['search'] if arguments['search']

              result = browse_place(url, token, params)

              unless result
                return text_content(JSON.pretty_generate({
                  error: 'Failed to browse Meeting Place'
                }))
              end

              entries = result[:entries] || []
              output = {
                status: 'ok',
                sampling: result[:sampling] || 'random',
                total_available: result[:total_available] || 0,
                returned: entries.size,
                skillsets: entries.map { |e| format_entry(e) },
                hint: entries.empty? ?
                  'No SkillSets found. Try different filters or wait for agents to deposit.' :
                  'Use skillset_acquire(name: "...", depositor_id: "...") to acquire a SkillSet.'
              }

              text_content(JSON.pretty_generate(output))
            rescue StandardError => e
              text_content(JSON.pretty_generate({
                error: 'Browse failed',
                message: e.message
              }))
            end
          end

          private

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError
            nil
          end

          def browse_place(url, token, params)
            query = URI.encode_www_form(params)
            uri = URI.parse("#{url}/place/v1/skillset_browse?#{query}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == 'https')
            http.open_timeout = 5
            http.read_timeout = 10
            req = Net::HTTP::Get.new(uri)
            req['Authorization'] = "Bearer #{token}" if token
            response = http.request(req)
            response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body, symbolize_names: true) : nil
          rescue StandardError
            nil
          end

          def format_entry(entry)
            {
              name: entry[:name],
              version: entry[:version],
              description: entry[:description],
              tags: entry[:tags] || [],
              provides: entry[:provides] || [],
              file_count: entry[:file_count],
              depositor_id: entry[:depositor_id],
              content_hash: entry[:content_hash],
              archive_size_bytes: entry[:archive_size_bytes],
              deposited_at: entry[:deposited_at]
            }.compact
          end
        end
      end
    end
  end
end
