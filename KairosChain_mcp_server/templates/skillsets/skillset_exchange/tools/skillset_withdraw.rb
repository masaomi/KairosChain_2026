# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module SkillsetExchange
      module Tools
        class SkillsetWithdraw < KairosMcp::Tools::BaseTool
          def name
            'skillset_withdraw'
          end

          def description
            'Withdraw a previously deposited SkillSet from a connected Meeting Place. Only the original depositor can withdraw.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting withdraw skillset exchange remove]
          end

          def related_tools
            %w[skillset_deposit skillset_browse meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                name: { type: 'string', description: 'SkillSet name to withdraw' },
                reason: { type: 'string', description: 'Reason for withdrawal (recorded on chain)' }
              },
              required: ['name']
            }
          end

          def call(arguments)
            ss_name = arguments['name']
            reason = arguments['reason']

            # 1. Build PlaceClient (fail early)
            client = build_place_client
            return client if client.is_a?(Array) # text_content error

            begin
              # 2. Ensure extension is registered (withdraw POSTs to Place, may need local registration)
              ensure_extension_registered!

              # 3. POST /place/v1/skillset_withdraw via PlaceClient
              result = client.skillset_withdraw(name: ss_name, reason: reason)

              if result[:error]
                text_content(JSON.pretty_generate({
                  error: result[:error] || 'Withdrawal failed',
                  details: result
                }))
              elsif result[:status] == 'withdrawn'
                text_content(JSON.pretty_generate({
                  status: 'withdrawn',
                  name: result[:name],
                  version: result[:version],
                  depositor_id: result[:depositor_id],
                  chain_recorded: result[:chain_recorded],
                  note: result[:note] || 'Agents who already acquired this SkillSet keep their copy.'
                }))
              else
                text_content(JSON.pretty_generate({
                  error: 'Withdrawal failed',
                  details: result
                }))
              end
            rescue StandardError => e
              text_content(JSON.pretty_generate({
                error: 'Withdrawal failed',
                message: e.message
              }))
            end
          end

          private

          def build_place_client(timeout: 30)
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

          # Lazy extension registration (same pattern as skillset_deposit.rb)
          def ensure_extension_registered!
            return unless defined?(KairosMcp) && KairosMcp.respond_to?(:http_server)
            router = KairosMcp.http_server&.place_router
            return unless router
            return if router.extensions.any? { |e| e.is_a?(::SkillsetExchange::PlaceExtension) }
            require_relative '../lib/skillset_exchange/place_extension'
            ext = ::SkillsetExchange::PlaceExtension.new(router)
            route_actions = {
              'skillset_deposit' => 'deposit_skill',
              'skillset_browse' => 'browse',
              'skillset_content' => 'browse',
              'skillset_withdraw' => 'deposit_skill'
            }
            router.register_extension(ext, route_action_map: route_actions)
          rescue StandardError => e
            $stderr.puts "[SkillsetExchange] Late registration failed (non-fatal): #{e.message}"
          end
        end
      end
    end
  end
end
