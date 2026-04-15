# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingBrowse < KairosMcp::Tools::BaseTool
          def name
            'meeting_browse'
          end

          def description
            'Browse skills available on a connected Meeting Place. Returns DEE-compliant random sample (no ranking).'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting browse discover skills catalog search]
          end

          def related_tools
            %w[meeting_connect meeting_get_skill_details meeting_acquire_skill meeting_deposit]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                tags: { type: 'array', items: { type: 'string' }, description: 'Filter by tags (optional)' },
                search: { type: 'string', description: 'Search in skill names (optional)' },
                type: { type: 'string', enum: %w[deposited_skill agent need], description: 'Filter by entry type (optional)' },
                page_size: { type: 'integer', description: 'Number of results (default: 20, max: 50)' }
              },
              required: []
            }
          end

          def call(arguments)
            client = build_place_client
            return client if client.is_a?(Array)

            begin
              page_size = [[arguments['page_size'] || 20, 50].min, 1].max

              result = client.browse(
                type: arguments['type'],
                search: arguments['search'],
                tags: arguments['tags'],
                limit: page_size
              )

              if result[:error]
                return text_content(JSON.pretty_generate({ error: 'Failed to browse Meeting Place', message: result[:error] }))
              end

              entries = result[:entries] || []
              output = {
                status: 'ok',
                sampling: result[:sampling] || 'random',
                total_available: result[:total_available] || 0,
                returned: entries.size,
                skills: entries.map { |e| format_entry(e) },
                hint: entries.empty? ? 'No skills found. Try different filters or wait for agents to deposit skills.' : 'Use meeting_acquire_skill(skill_id: "...") to acquire a skill.'
              }

              output[:place_trust] = result[:place_trust] if result[:place_trust]

              # Check for pending attestation nudge
              nudge_msg = nil
              begin
                nudge_msg = ::MMP::AttestationNudge.instance.pending_nudge
              rescue StandardError => e
                warn "[MMP] Nudge check failed: #{e.message}"
              end

              result_text = JSON.pretty_generate(output)
              result_text += "\n\n---\n#{nudge_msg}" if nudge_msg
              text_content(result_text)
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Browse failed', message: e.message }))
            end
          end

          private

          def build_place_client
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
              session_token: token, agent_id: agent_id
            )
          end

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError; nil
          end

          def format_entry(entry)
            base = {
              type: entry[:type] || entry[:format],
              name: entry[:name],
              skill_id: entry[:skill_id],
              owner_agent_id: entry[:agent_id],
              description: entry[:description],
              tags: entry[:tags] || [],
              format: entry[:format]
            }
            base[:size_bytes] = entry[:size_bytes] if entry[:size_bytes]
            base[:deposited_at] = entry[:deposited_at] if entry[:deposited_at]
            base[:trust_notice] = entry[:trust_notice] if entry[:trust_notice]
            base[:trust_metadata] = entry[:trust_metadata] if entry[:trust_metadata]
            base[:attestations] = entry[:attestations] if entry[:attestations]
            base[:summary] = entry[:summary] if entry[:summary]
            base[:sections] = entry[:sections] if entry[:sections]
            base[:content_hash] = entry[:content_hash] if entry[:content_hash]
            base[:version] = entry[:version] if entry[:version]
            base[:license] = entry[:license] if entry[:license]
            base.compact
          end
        end
      end
    end
  end
end
