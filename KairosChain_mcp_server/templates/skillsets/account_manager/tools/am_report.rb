# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module AccountManagerSkillSet
      module Tools
        # Figures only. A proposal never reaches a figure here, though
        # reconciliation lists the waiting ones, because an unposted purchase
        # is a difference the operator can account for (INV-AM-7, INV-AM-10).
        class AmReport < KairosMcp::Tools::BaseTool
          include ::AccountManager::ToolHelpers

          def name = 'am_report'

          def description
            'Profit and loss and balance sheet by transaction date, and reconciliation by ' \
            'settlement date — the last always recomputed and never frozen by a close. Output as ' \
            'markdown, CSV, or the underlying figures.'
          end

          def category = :accounting
          def usecase_tags = %w[report profit loss balance sheet reconciliation accounting figures]
          def related_tools = %w[am_query am_close am_entry]

          def input_schema
            {
              type: 'object',
              properties: {
                report: { type: 'string', enum: %w[profit_and_loss balance_sheet reconciliation],
                          description: 'Which report' },
                ledger: { type: 'string', description: 'Ledger name (default: main)' },
                format: { type: 'string', enum: %w[markdown csv json], description: 'Output form (default: markdown)' },
                from: { type: 'string', description: 'Start of the span, inclusive (profit_and_loss)' },
                to: { type: 'string', description: 'End of the span, inclusive (profit_and_loss)' },
                as_of: { type: 'string', description: 'The date the report is taken at (balance_sheet/reconciliation)' },
                book: { type: 'string', description: 'Restrict to one book' },
                account: { type: 'string', description: 'The cash, bank or card account to reconcile' },
                actual_balance: { type: 'string', description: 'The real balance the account shows, in major units' }
              },
              required: %w[report]
            }
          end

          def call(arguments)
            args = arguments || {}
            am_respond(args) do
              reporter = am_report(args)
              figures = build(reporter, args)
              case (args['format'] || 'markdown').to_s
              when 'markdown' then { 'format' => 'markdown', 'body' => reporter.to_markdown(figures) }
              when 'csv'      then { 'format' => 'csv', 'body' => reporter.to_csv(figures) }
              when 'json'     then figures
              else raise ::AccountManager::Refused, "unknown format: #{args['format'].inspect}"
              end
            end
          end

          private

          def build(reporter, args)
            case args['report'].to_s
            when 'profit_and_loss'
              require_args!(args, %w[from to])
              reporter.profit_and_loss(from: args['from'], to: args['to'], book: args['book'])
            when 'balance_sheet'
              require_args!(args, %w[as_of])
              reporter.balance_sheet(as_of: args['as_of'], book: args['book'])
            when 'reconciliation'
              require_args!(args, %w[as_of account])
              reporter.reconcile(account: args['account'], as_of: args['as_of'],
                                 actual_balance: args['actual_balance'], book: args['book'])
            else
              raise ::AccountManager::Refused, "unknown report: #{args['report'].inspect}"
            end
          end

          def require_args!(args, keys)
            missing = keys.reject { |k| args[k] }
            raise ::AccountManager::Refused, "#{missing.join(' and ')} required for #{args['report']}" unless missing.empty?
          end
        end
      end
    end
  end
end
