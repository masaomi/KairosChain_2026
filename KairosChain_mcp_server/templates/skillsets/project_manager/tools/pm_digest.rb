# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ProjectManagerSkillSet
      module Tools
        class PmDigest < KairosMcp::Tools::BaseTool
          include ::ProjectManager::ToolHelpers

          def name
            'pm_digest'
          end

          def description
            'Produce the session-start status digest: due/approaching commitments, items awaiting a ' \
            'human gate, and dormant-but-important items (split into neglected vs legitimately ' \
            'waiting — blocked or gated items surface as "still waiting", not as neglect). ' \
            'Read-only. How the digest is presented is the consumer\'s concern (secretary mode, Web UI).'
          end

          def category
            :project_management
          end

          def usecase_tags
            %w[digest session_start surfacing dormant keep_fire secretary]
          end

          def related_tools
            %w[pm_query pm_item]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                dormancy_days: { type: 'integer', description: 'Override the dormancy threshold (default from config, 14)' },
                approaching_days: { type: 'integer', description: 'Override the deadline horizon (default from config, 7)' }
              }
            }
          end

          def call(arguments)
            config = (pm_config['digest'] || {}).dup
            config['dormancy_days'] = arguments['dormancy_days'] if arguments['dormancy_days']
            config['approaching_days'] = arguments['approaching_days'] if arguments['approaching_days']
            digest = ::ProjectManager::Digest.new(pm_store, config)
            text_content(JSON.pretty_generate(digest.compute))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end
        end
      end
    end
  end
end
