# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module AccountManagerSkillSet
      module Tools
        # The only door a figure comes through. Everything inferential happens
        # before this call, in the agent or in the operator's head; this tool
        # stores what it is given and refuses what the invariants forbid.
        class AmEntry < KairosMcp::Tools::BaseTool
          include ::AccountManager::ToolHelpers

          def name = 'am_entry'

          def description
            'Post a balanced journal entry, edit or note a posting whose range is open, correct a ' \
            'sealed year against the prior-period-adjustment account, record an operator-authored ' \
            'proposal, post or discard or undo-discard a proposal, and confirm a join. Interprets ' \
            'nothing: notes and reasons are stored verbatim and read by no tool.'
          end

          def category = :accounting

          def usecase_tags
            %w[ledger bookkeeping posting journal entry proposal correction double-entry]
          end

          def related_tools = %w[am_import am_query am_report am_receipt am_close]

          LINE_SCHEMA = {
            type: 'object',
            properties: {
              account: { type: 'string', description: 'Account id from the chart' },
              book: { type: 'string', description: 'Book this line belongs to' },
              debit: { type: 'string', description: 'Debit amount in major units, e.g. "42.30"' },
              credit: { type: 'string', description: 'Credit amount in major units' },
              tax_label: { type: 'string', description: 'Opaque label from tax_labels; omit to take the account default' },
              note: { type: 'string', description: 'Stored verbatim, read by nothing' },
              foreign: { type: 'string', description: 'Original currency and amount as text; nothing sums or parses it (INV-AM-3)' }
            },
            required: %w[account book]
          }.freeze

          def input_schema
            {
              type: 'object',
              properties: {
                command: { type: 'string',
                           enum: %w[post edit note correct_sealed propose post_proposal discard
                                    undo_discard confirm_join get],
                           description: 'Operation to perform' },
                ledger: { type: 'string', description: 'Ledger name (default: main)' },
                id: { type: 'string', description: 'Posting id (edit/note/get) or proposal id (post_proposal/discard/undo_discard/confirm_join)' },
                transaction_date: { type: 'string', description: 'The day the transaction happened. This alone places the posting in a range (INV-AM-5)' },
                settlement_date: { type: 'string', description: 'The day money settled. Omit when no money moved (INV-AM-10)' },
                description: { type: 'string', description: 'What this posting is' },
                lines: { type: 'array', items: LINE_SCHEMA, description: 'Both sides. Book crossings are completed through the configured pair' },
                author: { type: 'string', enum: %w[operator agent], description: 'Who authored this (default: operator)' },
                note: { type: 'string', description: 'Free note, stored verbatim' },
                corrects: { type: 'string', description: 'Posting id this corrects (correct_sealed)' },
                reason: { type: 'string', description: 'Why this proposal is discarded (discard)' },
                join_kind: { type: 'string', enum: %w[posting proposal], description: 'What the proposal is being joined to (confirm_join)' },
                join_id: { type: 'string', description: 'Id of the join target (confirm_join)' }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            args = arguments || {}
            am_respond(args) { dispatch(args) }
          end

          private

          def dispatch(args)
            store = am_store(args)
            case args['command']
            when 'post'
              store.post(**posting_args(args))
            when 'edit'
              require_id!(args)
              store.edit(args['id'], transaction_date: args['transaction_date'],
                                     description: args['description'], lines: args['lines'],
                                     settlement_date: args.key?('settlement_date') ? args['settlement_date'] : :unset,
                                     note: args['note'])
            when 'note'
              require_id!(args)
              raise ::AccountManager::Refused, 'note is required' unless args['note']

              store.annotate(args['id'], note: args['note'])
            when 'correct_sealed'
              raise ::AccountManager::Refused, 'corrects is required' unless args['corrects']

              store.correct_sealed_year(corrects: args['corrects'],
                                        transaction_date: args['transaction_date'],
                                        description: args['description'].to_s,
                                        lines: args['lines'], author: author(args),
                                        settlement_date: args['settlement_date'],
                                        note: args['note'])
            when 'propose'
              store.add_proposal(transaction_date: args['transaction_date'],
                                 description: args['description'].to_s, lines: args['lines'],
                                 settlement_date: args['settlement_date'], author: author(args),
                                 note: args['note'])
            when 'post_proposal'
              require_id!(args)
              store.post_proposal(args['id'], transaction_date: args['transaction_date'],
                                              description: args['description'], lines: args['lines'],
                                              settlement_date: args.key?('settlement_date') ? args['settlement_date'] : :unset)
            when 'discard'
              require_id!(args)
              store.discard_proposal(args['id'], reason: args['reason'].to_s)
            when 'undo_discard'
              require_id!(args)
              store.undo_discard(args['id'])
            when 'confirm_join'
              require_id!(args)
              store.confirm_join(proposal_id: args['id'], target_kind: args['join_kind'].to_s,
                                 target_id: args['join_id'])
            when 'get'
              require_id!(args)
              args['id'].to_s.start_with?('prp') ? store.fetch_proposal(args['id']) : store.fetch_posting(args['id'])
            else
              raise ::AccountManager::Refused, "unknown command: #{args['command'].inspect}"
            end
          end

          def posting_args(args)
            { transaction_date: args['transaction_date'], description: args['description'].to_s,
              lines: args['lines'], settlement_date: args['settlement_date'],
              author: author(args), note: args['note'] }
          end

          def author(args) = (args['author'] || 'operator').to_s

          def require_id!(args)
            raise ::AccountManager::Refused, 'id is required' unless args['id']
          end
        end
      end
    end
  end
end
