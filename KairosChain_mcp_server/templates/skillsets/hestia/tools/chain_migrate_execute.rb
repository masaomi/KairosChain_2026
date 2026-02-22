# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Hestia
      module Tools
        class ChainMigrateExecute < KairosMcp::Tools::BaseTool
          def name
            'chain_migrate_execute'
          end

          def description
            'Migrate HestiaChain anchors from current backend to next stage. Stage 0→1 (in_memory→private) is self-contained. Higher stages require external dependencies.'
          end

          def category
            :chain
          end

          def usecase_tags
            %w[hestia chain migration execute backend upgrade]
          end

          def related_tools
            %w[chain_migrate_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                target_stage: {
                  type: 'integer',
                  description: 'Target stage number (1=private, 2=testnet, 3=mainnet). Must be exactly one stage above current.'
                },
                dry_run: {
                  type: 'boolean',
                  description: 'If true, only report what would be migrated without actually migrating. Default: false'
                },
                storage_path: {
                  type: 'string',
                  description: 'Custom storage path for private backend (stage 1). Default: storage/hestia_anchors.json'
                }
              },
              required: ['target_stage']
            }
          end

          def call(arguments)
            target_stage = arguments['target_stage'].to_i
            dry_run = arguments['dry_run'] == true
            storage_path = arguments['storage_path']

            config = ::Hestia.load_config
            chain_config = ::Hestia::Chain::Core::Config.new(config.dig('chain') || {})
            client = ::Hestia::Chain::Core::Client.new(config: chain_config)

            migrator = ::Hestia::ChainMigrator.new(current_backend: client.backend)
            result = migrator.migrate(
              target_stage: target_stage,
              dry_run: dry_run,
              storage_path: storage_path
            )

            text_content(JSON.pretty_generate(result))
          rescue ArgumentError => e
            text_content(JSON.pretty_generate({ error: 'Migration validation failed', message: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: 'Migration failed', message: e.message }))
          end
        end
      end
    end
  end
end
