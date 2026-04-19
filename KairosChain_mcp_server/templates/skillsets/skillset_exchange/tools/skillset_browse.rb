# frozen_string_literal: true

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
            client = build_place_client(timeout: 10)
            return client if client.is_a?(Array) # text_content error

            begin
              page_size = [[arguments['page_size'] || 20, 50].min, 1].max

              result = client.skillset_browse(search: arguments['search'], limit: page_size)

              if result[:error]
                return text_content(JSON.pretty_generate({
                  error: 'Failed to browse Meeting Place',
                  details: result[:error]
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

          def build_place_client(timeout: 10)
            if defined?(::MMP)
              config = ::MMP.load_config
              unless config['enabled']
                return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
              end
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

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
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
