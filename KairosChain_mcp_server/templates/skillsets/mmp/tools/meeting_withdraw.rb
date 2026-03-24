# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingWithdraw < KairosMcp::Tools::BaseTool
          def name
            'meeting_withdraw'
          end

          def description
            'Withdraw (delete) a skill you previously deposited to a connected Meeting Place. Only the depositor can withdraw their own skills. Withdrawal is recorded on HestiaChain for audit.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting withdraw delete deposit cleanup]
          end

          def related_tools
            %w[meeting_deposit meeting_browse meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                skill_id: {
                  type: 'string',
                  description: 'ID of the skill to withdraw (same as the skill name used during deposit)'
                },
                reason: {
                  type: 'string',
                  description: 'Reason for withdrawal (required, recorded on chain as hash)'
                }
              },
              required: %w[skill_id reason]
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
            skill_id = arguments['skill_id']
            reason = arguments['reason']

            begin
              result = withdraw_from_place(url, token, skill_id, reason)

              if result[:status] == 'withdrawn'
                text_content(JSON.pretty_generate({
                  status: 'withdrawn',
                  skill_id: skill_id,
                  owner_agent_id: result[:owner_agent_id],
                  withdrawn_at: result[:withdrawn_at],
                  chain_recorded: result[:chain_recorded],
                  note: 'Agents who already acquired this skill keep their copy.'
                }))
              else
                text_content(JSON.pretty_generate({
                  error: result[:error] || 'Withdrawal failed',
                  message: result[:message] || 'Unknown error'
                }))
              end
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Withdraw failed', message: e.message }))
            end
          end

          private

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError; nil
          end

          def withdraw_from_place(url, token, skill_id, reason)
            encoded = URI.encode_www_form_component(skill_id)
            uri = URI.parse("#{url}/place/v1/deposit/#{encoded}")
            http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = (uri.scheme == 'https')
            http.open_timeout = 5; http.read_timeout = 10
            req = Net::HTTP::Delete.new(uri.path)
            req['Content-Type'] = 'application/json'
            req['Authorization'] = "Bearer #{token}" if token
            req.body = JSON.generate({ reason: reason })
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
