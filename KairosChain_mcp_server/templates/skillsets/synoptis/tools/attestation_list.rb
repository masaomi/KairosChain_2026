# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class AttestationList < KairosMcp::Tools::BaseTool
          def name
            'attestation_list'
          end

          def description
            'List attestation proofs. Filter by agent_id, claim_type, or status. Returns matching attestations with summary information.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[synoptis attestation list query trust]
          end

          def related_tools
            %w[attestation_verify trust_score_get]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                agent_id: {
                  type: 'string',
                  description: 'Filter by agent ID (matches both attester and attestee). Optional.'
                },
                claim_type: {
                  type: 'string',
                  enum: ::Synoptis::ClaimTypes.all_types,
                  description: 'Filter by claim type. Optional.'
                },
                status: {
                  type: 'string',
                  enum: %w[active revoked expired],
                  description: 'Filter by proof status. Optional.'
                }
              }
            }
          end

          def call(arguments)
            filters = {}
            filters[:agent_id] = arguments['agent_id'] if arguments['agent_id']
            filters[:claim_type] = arguments['claim_type'] if arguments['claim_type']
            filters[:status] = arguments['status'] if arguments['status']

            config = ::Synoptis.load_config
            storage_path = ::Synoptis.storage_path(config)
            registry = ::Synoptis::Registry::FileRegistry.new(storage_path: storage_path)

            proofs = registry.list_proofs(filters)

            # Dynamic expired check: proofs with expires_at in the past are expired
            now = Time.now.utc
            if filters[:status] == 'expired'
              # Include proofs whose expires_at has passed, even if status is still 'active'
              all_proofs = registry.list_proofs(filters.reject { |k, _| k == :status })
              proofs = all_proofs.select do |p|
                p[:status] == 'expired' ||
                  (p[:expires_at] && (Time.parse(p[:expires_at].to_s) rescue nil)&.<(now))
              end
            else
              # Exclude dynamically expired proofs from 'active' results
              if filters[:status] == 'active'
                proofs = proofs.reject do |p|
                  p[:expires_at] && (Time.parse(p[:expires_at].to_s) rescue nil)&.<(now)
                end
              end
            end

            output = {
              total_count: proofs.size,
              filters: filters.empty? ? 'none' : filters,
              proofs: proofs.map do |p|
                {
                  proof_id: p[:proof_id],
                  claim_type: p[:claim_type],
                  attester_id: p[:attester_id],
                  attestee_id: p[:attestee_id],
                  subject_ref: p[:subject_ref],
                  status: p[:status],
                  issued_at: p[:issued_at],
                  expires_at: p[:expires_at]
                }
              end
            }

            text_content(JSON.pretty_generate(output))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Failed to list attestations', message: e.message }))
          end
        end
      end
    end
  end
end
