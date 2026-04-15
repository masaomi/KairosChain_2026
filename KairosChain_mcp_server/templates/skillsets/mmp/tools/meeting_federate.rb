# frozen_string_literal: true

require 'json'
require 'digest'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        # Agent-initiated Place-to-Place skill bridging.
        #
        # DEE design: the agent decides what to federate.
        # No automatic forwarding — each federation is a deliberate act.
        # Provenance chain tracks origin and path (BGP AS-path pattern).
        class MeetingFederate < KairosMcp::Tools::BaseTool
          def name
            'meeting_federate'
          end

          def description
            'Bridge skills from one Meeting Place to another, maintaining provenance chain. Agent-initiated federation (no automatic forwarding).'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting federate bridge relay provenance]
          end

          def related_tools
            %w[meeting_connect meeting_browse meeting_deposit]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                source_url: { type: 'string', description: 'Source Place URL (e.g. http://localhost:9200)' },
                source_token: { type: 'string', description: 'Session token for source Place (from meeting_connect)' },
                target_url: { type: 'string', description: 'Target Place URL (e.g. http://localhost:9201)' },
                target_token: { type: 'string', description: 'Session token for target Place (from meeting_connect)' },
                skill_ids: { type: 'array', items: { type: 'string' }, description: 'Specific skill IDs to federate (optional, defaults to all deposited skills)' },
                tags: { type: 'array', items: { type: 'string' }, description: 'Filter source skills by tags (optional)' }
              },
              required: %w[source_url source_token target_url target_token]
            }
          end

          def call(arguments)
            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
            end

            source_url = arguments['source_url'].chomp('/')
            source_token = arguments['source_token']
            target_url = arguments['target_url'].chomp('/')
            target_token = arguments['target_token']
            filter_ids = arguments['skill_ids']
            filter_tags = arguments['tags']

            begin
              source_client = build_client_for(url: source_url, token: source_token)
              target_client = build_client_for(url: target_url, token: target_token, timeout: 15)

              # Resolve Place ID for provenance chain
              info_result = source_client.place_info
              source_place_id = info_result[:place_id] || source_url

              # Step 1: Browse source Place for deposited skills
              source_result = source_client.browse(type: 'deposited_skill', tags: filter_tags, limit: 50)
              if source_result[:error]
                return text_content(JSON.pretty_generate({ error: 'Failed to browse source Place', message: source_result[:error] }))
              end

              source_skills = (source_result[:entries] || []).map do |e|
                {
                  skill_id: e[:skill_id],
                  name: e[:name],
                  description: e[:description],
                  tags: e[:tags],
                  owner_agent_id: e[:agent_id],
                  deposited_at: e[:deposited_at],
                  trust_metadata: e[:trust_metadata]
                }
              end

              # Filter by skill_ids if specified
              if filter_ids && !filter_ids.empty?
                source_skills = source_skills.select { |s| filter_ids.include?(s[:skill_id]) }
              end

              if source_skills.empty?
                return text_content(JSON.pretty_generate({
                  status: 'no_skills',
                  message: 'No deposited skills found on source Place matching criteria.'
                }))
              end

              # Step 2: For each skill, GET content from source + POST to target with provenance
              federated = []
              failed = []

              source_skills.each do |skill_meta|
                # GET full content from source
                raw = source_client.get_skill_content(
                  skill_id: skill_meta[:skill_id],
                  owner: skill_meta[:owner_agent_id]
                )
                content_result = adapt_place_skill_content(raw, skill_meta[:skill_id])

                unless content_result[:success]
                  failed << { skill_id: skill_meta[:skill_id], error: content_result[:error] }
                  next
                end

                # Build provenance for federation
                source_provenance = skill_meta[:trust_metadata]&.dig(:provenance) || {}
                source_deposited_at = skill_meta[:deposited_at]
                provenance = build_federation_provenance(source_provenance, source_place_id, content_result, source_deposited_at)

                # Sign content with this agent's key
                identity = ::MMP::Identity.new(config: config)
                crypto = identity.crypto
                content = content_result[:content]
                content_hash = Digest::SHA256.hexdigest(content)
                signature = crypto.has_keypair? ? crypto.sign(content) : nil

                # POST to target Place with provenance
                deposit_result = target_client.deposit({
                  skill_id: skill_meta[:skill_id],
                  name: content_result[:name] || skill_meta[:name],
                  description: skill_meta[:description],
                  tags: skill_meta[:tags] || [],
                  format: content_result[:format] || 'markdown',
                  content: content,
                  content_hash: content_hash,
                  signature: signature,
                  provenance: provenance
                })

                if deposit_result && deposit_result[:status] == 'deposited'
                  federated << {
                    skill_id: skill_meta[:skill_id],
                    name: skill_meta[:name],
                    hop_count: provenance[:hop_count]
                  }
                else
                  error_msg = deposit_result&.dig(:reasons)&.join(', ') ||
                              deposit_result&.dig(:error) ||
                              'Unknown error'
                  failed << { skill_id: skill_meta[:skill_id], error: error_msg }
                end
              end

              output = {
                status: 'completed',
                source: source_url,
                target: target_url,
                federated: federated.size,
                failed: failed.size,
                details: {
                  federated: federated,
                  failed: failed
                }
              }

              output[:hint] = 'Use meeting_browse on target Place to verify federated skills.' if federated.any?

              text_content(JSON.pretty_generate(output))
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Federation failed', message: e.message }))
            end
          end

          private

          # Build PlaceClient for explicit URL/token (federate uses explicit args, not connection state)
          def build_client_for(url:, token:, timeout: 10)
            identity = ::MMP::Identity.new(config: ::MMP.load_config)
            ::MMP::PlaceClient.reconnect(
              place_url: url, identity: identity,
              session_token: token, timeout: timeout
            )
          end

          # Adapter A1: Place deposit skill content
          def adapt_place_skill_content(raw, skill_id)
            if raw[:error]
              { success: false, error: raw[:error] }
            else
              {
                success: true,
                name: raw[:name] || skill_id,
                skill_name: raw[:name] || skill_id,
                format: raw[:format] || 'markdown',
                content: raw[:content],
                content_hash: raw[:content_hash],
                size_bytes: raw[:content]&.bytesize || 0,
                depositor_id: raw[:depositor_id],
                trust_notice: raw[:trust_notice]
              }
            end
          end

          # Build provenance for the federated deposit.
          def build_federation_provenance(source_provenance, source_place_id, content_result, source_deposited_at)
            if source_provenance[:hop_count].to_i > 0
              {
                origin_place_id: source_provenance[:origin_place_id],
                origin_agent_id: source_provenance[:origin_agent_id] || content_result[:depositor_id],
                via: (source_provenance[:via] || []) + [source_place_id],
                hop_count: source_provenance[:hop_count].to_i + 1,
                deposited_at_origin: source_provenance[:deposited_at_origin]
              }
            else
              {
                origin_place_id: source_place_id,
                origin_agent_id: content_result[:depositor_id],
                via: [source_place_id],
                hop_count: 1,
                deposited_at_origin: source_deposited_at || Time.now.utc.iso8601
              }
            end
          end
        end
      end
    end
  end
end
