# frozen_string_literal: true

require 'json'
require 'digest'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingAttestSkill < KairosMcp::Tools::BaseTool
          def name
            'meeting_attest_skill'
          end

          def description
            'Deposit an attestation (signed claim) on a skill at a connected Meeting Place. The attestation is a copy — the original proof stays in your local chain. Other agents can see your attestation in browse/preview and verify your signature via your public key.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting attestation trust claim verify skill]
          end

          def related_tools
            %w[meeting_browse meeting_preview_skill attestation_issue meeting_get_agent_profile]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                skill_id: {
                  type: 'string',
                  description: 'ID of the skill to attest'
                },
                owner_agent_id: {
                  type: 'string',
                  description: 'Agent ID of the skill owner (depositor)'
                },
                claim: {
                  type: 'string',
                  description: 'Attestation claim (e.g., "reviewed", "used_in_production", "philosophical_depth_verified")'
                },
                evidence: {
                  type: 'string',
                  description: 'Optional evidence text (hashed before sending — full text stays local)'
                }
              },
              required: %w[skill_id owner_agent_id claim]
            }
          end

          def call(arguments)
            client = build_place_client
            return client if client.is_a?(String)

            skill_id = arguments['skill_id']
            owner_agent_id = arguments['owner_agent_id']
            claim = arguments['claim']
            evidence = arguments['evidence']

            begin
              config = ::MMP.load_config
              identity = ::MMP::Identity.new(config: config)
              crypto = identity.crypto
              attester_id = identity.instance_id

              # Fetch current skill content_hash for version-bound attestation
              preview = client.preview_skill(skill_id: skill_id, owner: owner_agent_id, first_lines: 1)
              skill_content_hash = preview[:content_hash]

              # Build signed payload: canonical form with content_hash for cryptographic version binding
              timestamp = Time.now.utc.iso8601
              evidence_hash = evidence ? Digest::SHA256.hexdigest(evidence) : nil
              signed_payload = [attester_id, claim, skill_id, owner_agent_id, skill_content_hash, evidence_hash, timestamp].compact.join('|')
              signature = crypto&.has_keypair? ? crypto.sign(signed_payload) : nil

              result = client.attest_skill(
                skill_id: skill_id,
                owner_agent_id: owner_agent_id,
                claim: claim,
                evidence_hash: evidence_hash,
                signature: signature,
                signed_payload: signed_payload
              )

              if result[:valid] || result[:status] == 'attestation_deposited'
                text_content(JSON.pretty_generate({
                  status: 'attestation_deposited',
                  skill_id: skill_id,
                  owner_agent_id: owner_agent_id,
                  claim: claim,
                  evidence_hash: evidence_hash,
                  signed: !!signature,
                  deposited_at: result[:deposited_at],
                  note: 'Attestation copy deposited to Meeting Place. Other agents can see this in browse/preview and verify your signature via your public key.'
                }))
              else
                text_content(JSON.pretty_generate({
                  error: result[:error] || 'Attestation failed',
                  message: result[:message]
                }.compact))
              end
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Attestation failed', message: e.message }))
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
