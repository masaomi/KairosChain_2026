# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module AccountManagerSkillSet
      module Tools
        # Evidence in, never out. There is no delete command, and its absence
        # is the design: a retention obligation runs for years, and a tool that
        # cannot delete cannot delete wrongly (INV-AM-4).
        class AmReceipt < KairosMcp::Tools::BaseTool
          include ::AccountManager::ToolHelpers

          def name = 'am_receipt'

          def description
            'Import evidence into the ledger store under its content hash, bind it to a proposal ' \
            'or to a posting whose range is open, and report postings whose evidence is missing ' \
            'or unreadable. Nothing here deletes evidence.'
          end

          def category = :accounting
          def usecase_tags = %w[receipt evidence attachment document binding audit]
          def related_tools = %w[am_entry am_import am_query]

          def input_schema
            {
              type: 'object',
              properties: {
                command: { type: 'string', enum: %w[import bind list unevidenced],
                           description: 'Operation to perform' },
                ledger: { type: 'string', description: 'Ledger name (default: main)' },
                path: { type: 'string', description: 'File to copy in (import)' },
                filename: { type: 'string', description: 'Name to record; defaults to the source basename (import)' },
                hash: { type: 'string', description: 'Content hash of stored evidence (bind)' },
                target_kind: { type: 'string', enum: %w[posting proposal], description: 'What to bind to (bind)' },
                target_id: { type: 'string', description: 'Id of the posting or proposal (bind)' }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            args = arguments || {}
            am_respond(args) do
              store = am_store(args)
              case args['command']
              when 'import'
                raise ::AccountManager::Refused, 'path is required' unless args['path']

                store.import_evidence(source_path: args['path'], filename: args['filename'])
              when 'bind'
                raise ::AccountManager::Refused, 'hash, target_kind and target_id are required' unless args['hash'] && args['target_kind'] && args['target_id']

                store.bind_evidence(hash: args['hash'], target_kind: args['target_kind'].to_s,
                                    target_id: args['target_id'])
              when 'list'
                { 'evidence' => store.evidence.values, 'receipts_dir' => store.receipts_dir }
              when 'unevidenced'
                { 'unevidenced' => store.unevidenced_postings.map { |p| p.slice('id', 'transaction_date', 'description', 'evidence') } }
              else
                raise ::AccountManager::Refused, "unknown command: #{args['command'].inspect}"
              end
            end
          end
        end
      end
    end
  end
end
