# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module SecureMmp
      module Tools
        # Read admission state and narrow it. Adding a pin is an operator act
        # (`kairos-chain peer pin add`), so no command here widens admission.
        class PeerPin < KairosMcp::Tools::BaseTool
          def name
            'peer_pin'
          end

          def description
            'Secure MMP: list the keys this instance admits in MMP direct mode, revoke one, or see and dismiss ' \
              'refused knocks. Adding a key is not possible here: the operator runs ' \
              '`kairos-chain peer pin add <alias> <key_sha256> --url http://HOST:PORT`.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting mmp p2p admission pin allowlist revoke security]
          end

          def related_tools
            %w[peer_message_send peer_message_inbox meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: { type: 'string', enum: %w[list revoke knocks dismiss_knock],
                           description: 'list (default), revoke, knocks, dismiss_knock' },
                target: { type: 'string', description: 'revoke: an alias or a full key hash; dismiss_knock: a full key hash' }
              },
              required: []
            }
          end

          def call(arguments)
            require 'kairos_mcp/admission_commands'
            case (arguments['command'] || 'list').to_s
            when 'list'
              r = KairosMcp::AdmissionCommands.pin_list
              respond(status: 'ok', records: r[:status].to_s, cause: r[:cause], pins: r[:pins],
                      ignored_records: r[:ignored_records].size, data_dir: r[:data_dir],
                      note: 'Pins are enforced only by a listener started with --admission pinned.')
            when 'revoke'
              target = arguments['target'].to_s
              return respond(status: 'error', message: 'target (alias or key hash) is required') if target.empty?

              r = KairosMcp::AdmissionCommands.pin_revoke(target)
              respond(status: 'revoked', alias: r[:record]['alias'], key_sha256: r[:record]['key_sha256'],
                      seq: r[:record]['seq'])
            when 'knocks'
              respond(status: 'ok', knocks: ::SecureMmp::Knocks.list,
                      note: 'Peer-supplied, unverified: claimed_name and instance_id are what the knocking key said ' \
                            'about itself. To admit a key the operator copies its full key_sha256 into ' \
                            '`kairos-chain peer pin add`.')
            when 'dismiss_knock'
              target = arguments['target'].to_s
              respond(status: ::SecureMmp::Knocks.dismiss(target) ? 'dismissed' : 'not_found', key_sha256: target)
            else
              respond(status: 'error', message: "unknown command #{arguments['command'].inspect}")
            end
          rescue KairosMcp::AdmissionRecords::Error => e
            respond(status: 'error', message: e.message)
          end

          private

          def respond(payload)
            text_content(JSON.pretty_generate(payload))
          end
        end
      end
    end
  end
end
