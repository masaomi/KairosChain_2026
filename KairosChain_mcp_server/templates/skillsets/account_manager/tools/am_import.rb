# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module AccountManagerSkillSet
      module Tools
        # Rows land as proposals and stop there. This tool creates no posting,
        # lets no proposal reach a report, merges nothing by content, and drops
        # no row whose content changed (INV-AM-7, INV-AM-9).
        class AmImport < KairosMcp::Tools::BaseTool
          include ::AccountManager::ToolHelpers

          def name = 'am_import'

          def description
            'Land CSV rows as proposals under a declared import profile, keyed by (profile, ' \
            'reference). A row whose key is present but whose content differs is reported, not ' \
            'dropped. A source with no reference field is reported as undeduplicable. Suggested ' \
            'accounts, labels and joins ride on the proposal; they are never applied.'
          end

          def category = :accounting
          def usecase_tags = %w[import csv bank statement proposal reconcile transcription]
          def related_tools = %w[am_entry am_query am_receipt]

          def input_schema
            {
              type: 'object',
              properties: {
                ledger: { type: 'string', description: 'Ledger name (default: main)' },
                profile: { type: 'string', description: 'Import profile name declared in the config' },
                csv_text: { type: 'string', description: 'CSV with a header row' },
                rows: { type: 'array', items: { type: 'object' },
                        description: 'Already-parsed rows, as an alternative to csv_text' },
                suggestions: {
                  type: 'array',
                  description: 'Aligned with rows by position. The agent\'s reading of the other side; stored as a suggestion, never applied',
                  items: {
                    type: 'object',
                    properties: {
                      account: { type: 'string' }, book: { type: 'string' },
                      tax_label: { type: 'string' }, note: { type: 'string' },
                      join: { type: 'string', description: 'Id this row is believed to belong with; the operator confirms it via am_entry confirm_join' }
                    }
                  }
                },
                batch: { type: 'string', description: 'Batch label; generated when omitted' },
                author: { type: 'string', enum: %w[operator agent], description: 'Who produced these rows (default: agent)' }
              },
              required: %w[profile]
            }
          end

          def call(arguments)
            args = arguments || {}
            am_respond(args) do
              raise ::AccountManager::Refused, 'profile is required' unless args['profile']

              am_importer(args).import(
                profile_name: args['profile'], rows: args['rows'], csv_text: args['csv_text'],
                suggestions: args['suggestions'], batch: args['batch'],
                author: (args['author'] || 'agent').to_s
              )
            end
          end
        end
      end
    end
  end
end
