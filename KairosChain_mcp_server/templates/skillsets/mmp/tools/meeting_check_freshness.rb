# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingCheckFreshness < KairosMcp::Tools::BaseTool
          def name
            'meeting_check_freshness'
          end

          def description
            'Check if skills you previously acquired from a Meeting Place have been updated or withdrawn. Compares your local content_hash against the current deposit. Pull-only: does not auto-update.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting freshness update check stale]
          end

          def related_tools
            %w[meeting_acquire_skill meeting_browse meeting_preview_skill meeting_update_deposit]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                skills: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      skill_id: { type: 'string', description: 'ID of the acquired skill' },
                      known_hash: { type: 'string', description: 'Content hash from when you acquired it' },
                      owner_agent_id: { type: 'string', description: 'Depositor agent ID (optional)' }
                    },
                    required: %w[skill_id known_hash]
                  },
                  description: 'List of skills to check with their known content hashes'
                }
              },
              required: %w[skills]
            }
          end

          def call(arguments)
            client = build_place_client
            return client if client.is_a?(String)

            skills_to_check = arguments['skills'] || []
            if skills_to_check.empty?
              return text_content(JSON.pretty_generate({ error: 'No skills to check', hint: 'Provide a list of {skill_id, known_hash} pairs.' }))
            end

            begin
              results = skills_to_check.map do |skill|
                check_one(client, skill['skill_id'], skill['known_hash'], skill['owner_agent_id'])
              end

              fresh = results.count { |r| r[:status] == 'up_to_date' }
              stale = results.count { |r| r[:status] == 'updated' }
              gone = results.count { |r| r[:status] == 'withdrawn' }
              failed = results.count { |r| r[:status] == 'check_failed' }

              text_content(JSON.pretty_generate({
                checked: results.size,
                up_to_date: fresh,
                updated: stale,
                withdrawn: gone,
                check_failed: failed,
                results: results,
                hint: stale > 0 ? 'Use meeting_acquire_skill to get updated versions.' : nil
              }.compact))
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Freshness check failed', message: e.message }))
            end
          end

          private

          def check_one(client, skill_id, known_hash, owner)
            result = client.preview_skill(skill_id: skill_id, owner: owner, first_lines: 1)

            if result[:error]
              error_str = result[:error].to_s
              if error_str.include?('not_found') || error_str.include?('404')
                { skill_id: skill_id, status: 'withdrawn', note: 'Skill not found on Place (may have been withdrawn)' }
              else
                { skill_id: skill_id, status: 'check_failed', error: error_str, note: 'Could not reach Place or access denied — skill may still exist' }
              end
            elsif result[:content_hash] == known_hash
              { skill_id: skill_id, status: 'up_to_date', current_hash: result[:content_hash] }
            else
              { skill_id: skill_id, status: 'updated', known_hash: known_hash, current_hash: result[:content_hash],
                deposited_at: result[:deposited_at] }
            end
          end

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
            identity = ::MMP::Identity.new(config: config)
            client = ::MMP::PlaceClient.new(place_url: url, identity: identity, config: {})
            client.instance_variable_set(:@bearer_token, token)
            client.instance_variable_set(:@connected, true)
            client
          end

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError; nil
          end
        end
      end
    end
  end
end
