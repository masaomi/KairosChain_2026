# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module AccountManagerSkillSet
      module Tools
        # A close freezes a range; the two closes differ only in whether the
        # range can be re-opened (INV-AM-5).
        #
        # The annual close does not close a range of its own. It posts the
        # year's closing entry first and seals the year's month ranges second,
        # which is why an annual close after any number of period closes is
        # reachable rather than refused.
        class AmClose < KairosMcp::Tools::BaseTool
          include ::AccountManager::ToolHelpers

          def name = 'am_close'

          def description
            'Close a month range, re-open a period close, or take an annual close — which posts ' \
            'the year\'s income and expense into retained earnings and then seals every range of ' \
            'that fiscal year, after which nothing in it can be touched again. Also reports the ' \
            'state of a range and what a close would freeze.'
          end

          def category = :accounting
          def usecase_tags = %w[close period annual fiscal year seal reopen filing]
          def related_tools = %w[am_entry am_report am_query]

          def input_schema
            {
              type: 'object',
              properties: {
                command: { type: 'string', enum: %w[close reopen annual_close status],
                           description: 'Operation to perform' },
                ledger: { type: 'string', description: 'Ledger name (default: main)' },
                range: { type: 'string', description: 'Month range as YYYY-MM (close/reopen/status)' },
                year: { type: 'integer', description: 'Fiscal year, labelled by the calendar year it starts in (annual_close)' }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            args = arguments || {}
            am_respond(args) do
              store = am_store(args)
              case args['command']
              when 'close'
                require_range!(args)
                store.close_range(args['range'])
              when 'reopen'
                require_range!(args)
                store.reopen_range(args['range'])
              when 'annual_close'
                raise ::AccountManager::Refused, 'year is required' unless args['year']

                store.annual_close(args['year'])
              when 'status'
                if args['range']
                  store.range_report(args['range'])
                else
                  { 'closings' => store.closings.map { |c| c.slice('id', 'range', 'action', 'year', 'supersedes', 'closed_at', 'hash') } }
                end
              else
                raise ::AccountManager::Refused, "unknown command: #{args['command'].inspect}"
              end
            end
          end

          private

          def require_range!(args)
            raise ::AccountManager::Refused, 'range is required, as YYYY-MM' unless args['range'].to_s.match?(/\A\d{4}-\d{2}\z/)
          end
        end
      end
    end
  end
end
