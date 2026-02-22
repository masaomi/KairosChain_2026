# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Hestia
      module Tools
        class ChainMigrateStatus < KairosMcp::Tools::BaseTool
          def name
            'chain_migrate_status'
          end

          def description
            'Show current HestiaChain backend stage, anchor count, and available migration paths. Read-only and always safe to call.'
          end

          def category
            :chain
          end

          def usecase_tags
            %w[hestia chain migration status backend stage]
          end

          def related_tools
            %w[chain_migrate_execute philosophy_anchor record_observation]
          end

          def input_schema
            {
              type: 'object',
              properties: {},
              required: []
            }
          end

          def call(_arguments)
            config = ::Hestia.load_config
            chain_config = ::Hestia::Chain::Core::Config.new(config.dig('chain') || {})
            client = ::Hestia::Chain::Core::Client.new(config: chain_config)

            migrator = ::Hestia::ChainMigrator.new(current_backend: client.backend)
            result = migrator.status.merge(
              client_status: client.status,
              backend_stats: client.backend.stats
            )

            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Failed to get migration status', message: e.message }))
          end
        end
      end
    end
  end
end
