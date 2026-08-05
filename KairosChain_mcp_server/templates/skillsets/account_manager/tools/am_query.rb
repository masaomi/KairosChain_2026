# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module AccountManagerSkillSet
      module Tools
        # Retrieval only. Proposals are visible here and counted by nothing
        # (INV-AM-7); the counts this tool returns are counts of records, not
        # figures, and are labelled as such.
        class AmQuery < KairosMcp::Tools::BaseTool
          include ::AccountManager::ToolHelpers

          def name = 'am_query'

          def description
            'Retrieve postings and proposals by date span, book, account, evidence state, author, ' \
            'key or range state. Proposals are returned alongside postings and are never counted ' \
            'as figures.'
          end

          def category = :accounting
          def usecase_tags = %w[query ledger search postings proposals audit]
          def related_tools = %w[am_entry am_report am_close]

          def input_schema
            {
              type: 'object',
              properties: {
                what: { type: 'string', enum: %w[postings proposals ranges], description: 'What to retrieve (default: postings)' },
                ledger: { type: 'string', description: 'Ledger name (default: main)' },
                from: { type: 'string', description: 'Earliest transaction date, inclusive' },
                to: { type: 'string', description: 'Latest transaction date, inclusive' },
                book: { type: 'string', description: 'Restrict to one book' },
                account: { type: 'string', description: 'Restrict to postings touching this account' },
                author: { type: 'string', enum: %w[operator agent], description: 'Who authored the record' },
                state: { type: 'string', enum: %w[undecided posted discarded], description: 'Proposal state' },
                unevidenced: { type: 'boolean', description: 'Only postings with no readable evidence' },
                profile: { type: 'string', description: 'Import profile the key names' },
                reference: { type: 'string', description: 'Source reference the key names' }
              }
            }
          end

          def call(arguments)
            args = arguments || {}
            am_respond(args) do
              store = am_store(args)
              case (args['what'] || 'postings').to_s
              when 'postings'  then { 'postings' => filter_postings(store, args) }
              when 'proposals' then { 'proposals' => filter_proposals(store, args) }
              when 'ranges'    then { 'ranges' => ranges(store, args) }
              else raise ::AccountManager::Refused, "unknown what: #{args['what'].inspect}"
              end
            end
          end

          private

          def filter_postings(store, args)
            result = args['unevidenced'] ? store.unevidenced_postings : store.postings
            result = within(result, args)
            result = result.select { |p| p['author'] == args['author'] } if args['author']
            result = result.select { |p| p['lines'].any? { |l| l['book'] == args['book'] } } if args['book']
            result = result.select { |p| p['lines'].any? { |l| l['account'] == args['account'] } } if args['account']
            result = result.select { |p| p.dig('key', 'profile') == args['profile'] } if args['profile']
            result = result.select { |p| p.dig('key', 'reference') == args['reference'] } if args['reference']
            result.sort_by { |p| [p['transaction_date'], p['id']] }
          end

          def filter_proposals(store, args)
            result = within(store.proposals, args)
            result = result.select { |p| p['state'] == args['state'] } if args['state']
            result = result.select { |p| p['author'] == args['author'] } if args['author']
            result = result.select { |p| p.dig('key', 'profile') == args['profile'] } if args['profile']
            result = result.select { |p| p.dig('key', 'reference') == args['reference'] } if args['reference']
            result.sort_by { |p| [p['transaction_date'].to_s, p['id']] }
          end

          def within(records, args)
            records = records.select { |r| r['transaction_date'].to_s >= args['from'].to_s } if args['from']
            records = records.select { |r| r['transaction_date'].to_s <= args['to'].to_s } if args['to']
            records
          end

          def ranges(store, args)
            seen = (store.postings + store.proposals).filter_map { |r| r['transaction_date'] }
                                                     .map { |d| store.range_of(d) }.uniq.sort
            seen = seen.select { |r| r >= store.range_of(args['from']) } if args['from']
            seen = seen.select { |r| r <= store.range_of(args['to']) } if args['to']
            seen.map { |r| store.range_report(r) }
          end
        end
      end
    end
  end
end
