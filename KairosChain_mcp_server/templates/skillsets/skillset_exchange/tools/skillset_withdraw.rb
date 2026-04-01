# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'yaml'

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

            # 1. Load connection state
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
              # 2. Ensure extension is registered (withdraw POSTs to Place, may need local registration)
              ensure_extension_registered!

              # 3. POST /place/v1/skillset_withdraw
              withdraw_body = { name: ss_name }
              withdraw_body[:reason] = reason if reason && !reason.empty?

              result = post_to_place(url, token, '/place/v1/skillset_withdraw', withdraw_body)

              if result && result[:status] == 'withdrawn'
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

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError
            nil
          end

          def post_to_place(url, token, path, body)
            uri = URI.parse("#{url}#{path}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == 'https')
            http.open_timeout = 5
            http.read_timeout = 30
            req = Net::HTTP::Post.new(uri.path)
            req['Content-Type'] = 'application/json'
            req['Authorization'] = "Bearer #{token}" if token
            req.body = JSON.generate(body)
            response = http.request(req)
            if response.is_a?(Net::HTTPSuccess)
              JSON.parse(response.body, symbolize_names: true)
            else
              parsed = begin
                JSON.parse(response.body, symbolize_names: true)
              rescue StandardError
                {}
              end
              { error: parsed[:error] || "HTTP #{response.code}", message: parsed[:message] }
            end
          rescue StandardError => e
            { error: e.message }
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
