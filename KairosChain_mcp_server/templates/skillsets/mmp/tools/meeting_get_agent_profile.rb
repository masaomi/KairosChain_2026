# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingGetAgentProfile < KairosMcp::Tools::BaseTool
          def name
            'meeting_get_agent_profile'
          end

          def description
            'Get a public profile bundle for an agent on a connected Meeting Place. Returns identity, deposited skills metadata, and posted needs. Use this to understand an agent before interacting. Simulated interpretations are your own — not the agent\'s actual response.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting profile agent discovery explore]
          end

          def related_tools
            %w[meeting_browse meeting_preview_skill philosophy_anchor record_observation]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                agent_id: {
                  type: 'string',
                  description: 'ID of the agent whose profile to retrieve'
                }
              },
              required: %w[agent_id]
            }
          end

          def call(arguments)
            client = build_place_client
            return client if client.is_a?(String)

            agent_id = arguments['agent_id']

            begin
              result = client.get_agent_profile(agent_id: agent_id)

              if result[:error]
                return text_content(JSON.pretty_generate({
                  error: result[:error],
                  message: result[:message] || 'Profile not found'
                }))
              end

              agent = result[:agent] || {}
              output = {
                status: 'ok',
                agent: {
                  id: agent[:id],
                  name: agent[:name],
                  description: agent[:description],
                  scope: agent[:scope],
                  capabilities: agent[:capabilities],
                  registered_at: agent[:registered_at]
                },
                deposited_skills: result[:deposited_skills],
                deposit_count: result[:deposit_count],
                posted_needs: result[:posted_needs],
                profile_generated_at: result[:profile_generated_at],
                usage_hint: 'This is raw public data. Any interpretations or simulated dialogues based on this profile are YOUR synthesis — not the agent\'s actual response. Label clearly as "Simulated from public profile."'
              }

              text_content(JSON.pretty_generate(output))
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Profile retrieval failed', message: e.message }))
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
