# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'

module KairosMcp
  module SkillSets
    module SkillsetExchange
      module Tools
        class SkillsetDeposit < KairosMcp::Tools::BaseTool
          def name
            'skillset_deposit'
          end

          def description
            'Deposit a knowledge-only SkillSet to a connected Meeting Place so other agents can browse and acquire it.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting deposit skillset exchange publish share]
          end

          def related_tools
            %w[skillset_browse skillset_acquire skillset_withdraw meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                name: { type: 'string', description: 'SkillSet name to deposit' },
                description_override: { type: 'string', description: 'Optional description override for the board listing' }
              },
              required: ['name']
            }
          end

          def call(arguments)
            ss_name = arguments['name']

            # 1. Build PlaceClient (fail early before expensive packaging)
            client = build_place_client
            return client if client.is_a?(Array) # text_content error

            begin
              # 2. Validate with ExchangeValidator
              require_relative '../lib/skillset_exchange/exchange_validator'
              config = load_skillset_config
              validator = ::SkillsetExchange::ExchangeValidator.new(config: config)
              manager = ::KairosMcp::SkillSetManager.new

              validation = validator.validate_for_deposit(ss_name, manager: manager)
              unless validation[:valid]
                return text_content(JSON.pretty_generate({
                  error: 'Deposit validation failed',
                  errors: validation[:errors]
                }))
              end

              # 3. Package with SkillSetManager
              pkg = manager.package(ss_name)

              # 4. Sign content_hash
              mmp_config = ::MMP.load_config
              identity = ::MMP::Identity.new(config: mmp_config)
              crypto = identity.crypto
              signature = crypto.has_keypair? ? crypto.sign(pkg[:content_hash]) : nil

              # 5. Ensure extension is registered (lazy registration)
              ensure_extension_registered!

              # 6. POST to place via PlaceClient
              ss = manager.find_skillset(ss_name)
              deposit_body = {
                name: pkg[:name],
                version: pkg[:version],
                description: arguments['description_override'] || ss.description,
                content_hash: pkg[:content_hash],
                archive_base64: pkg[:archive_base64],
                signature: signature,
                file_list: pkg[:file_list],
                tags: ss.metadata['tags'] || [],
                provides: ss.metadata['provides'] || []
              }

              result = client.skillset_deposit(deposit_body)

              if result[:error]
                text_content(JSON.pretty_generate({
                  error: 'Deposit failed',
                  details: result
                }))
              elsif result[:status] == 'deposited'
                text_content(JSON.pretty_generate({
                  status: 'deposited',
                  name: result[:name],
                  version: result[:version],
                  content_hash: result[:content_hash],
                  file_count: result[:file_count],
                  trust_notice: result[:trust_notice],
                  hint: 'Use skillset_browse to verify your SkillSet is visible.'
                }))
              else
                text_content(JSON.pretty_generate({
                  error: 'Deposit failed',
                  details: result
                }))
              end
            rescue StandardError => e
              text_content(JSON.pretty_generate({
                error: 'Deposit failed',
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

          def build_place_client(timeout: 30)
            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ error: 'Not connected', hint: 'Use meeting_connect first' }))
            end
            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
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

          def load_skillset_config
            config_path = File.join(KairosMcp.skillsets_dir, 'skillset_exchange', 'config', 'skillset_exchange.yml')
            File.exist?(config_path) ? (YAML.safe_load(File.read(config_path)) || {}) : {}
          rescue StandardError
            {}
          end

          # Lazy extension registration for late enablement (design Section 9.B)
          def ensure_extension_registered!
            return unless defined?(KairosMcp) && KairosMcp.respond_to?(:http_server)

            router = KairosMcp.http_server&.place_router
            return unless router
            return if router.extensions.any? { |e| e.is_a?(::SkillsetExchange::PlaceExtension) }

            # Late registration
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
