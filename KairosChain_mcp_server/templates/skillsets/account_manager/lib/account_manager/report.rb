# frozen_string_literal: true

require 'date'
require 'csv'

require 'account_manager/money'

module AccountManager
  # Figures, and the provenance of figures. Nothing here interprets: a report
  # counts postings and counts nothing else (INV-AM-1, INV-AM-7).
  class Report
    def initialize(store)
      @store = store
      @config = store.config
    end

    # Profit and loss, by transaction date (INV-AM-10).
    #
    # Closing entries are excluded. They transfer a year's result into equity
    # rather than producing one, so counting them would make every closed
    # year's result read as zero.
    def profit_and_loss(from:, to:, book: nil)
      from = Date.parse(from.to_s)
      to   = Date.parse(to.to_s)
      income = Hash.new(0)
      expense = Hash.new(0)

      each_line(from: from, to: to, book: book, skip_kinds: ['closing_entry']) do |line, _posting|
        case @config.account_type(line['account'])
        when 'income'  then income[line['account']]  += line['credit'] - line['debit']
        when 'expense' then expense[line['account']] += line['debit'] - line['credit']
        end
      end

      income_total = income.values.sum
      expense_total = expense.values.sum
      { 'kind' => 'profit_and_loss', 'from' => from.iso8601, 'to' => to.iso8601,
        'book' => book, 'currency' => @config.currency,
        'income' => named(income), 'expense' => named(expense),
        'income_total' => income_total, 'expense_total' => expense_total,
        'result' => income_total - expense_total }
    end

    # Balance sheet as of a transaction date.
    #
    # The identity assets = liabilities + equity + result holds over every
    # posting ever made, because each posting balances. No fiscal-year filter
    # and no exclusion is needed: once the annual close has posted its closing
    # entry, that year's result has moved into equity and stops appearing as an
    # open result on its own. That is what makes year two's sheet carry year
    # one's result.
    def balance_sheet(as_of:, book: nil)
      as_of = Date.parse(as_of.to_s)
      groups = { 'asset' => Hash.new(0), 'liability' => Hash.new(0), 'equity' => Hash.new(0) }
      result = 0

      each_line(from: nil, to: as_of, book: book) do |line, _posting|
        signed = line['debit'] - line['credit']
        case @config.account_type(line['account'])
        when 'asset'     then groups['asset'][line['account']]     += signed
        when 'liability' then groups['liability'][line['account']] -= signed
        when 'equity'    then groups['equity'][line['account']]    -= signed
        when 'income'    then result -= signed
        when 'expense'   then result -= signed
        end
      end

      assets = groups['asset'].values.sum
      liabilities = groups['liability'].values.sum
      equity = groups['equity'].values.sum
      { 'kind' => 'balance_sheet', 'as_of' => as_of.iso8601, 'book' => book,
        'currency' => @config.currency,
        'assets' => named(groups['asset']), 'liabilities' => named(groups['liability']),
        'equity' => named(groups['equity']),
        'assets_total' => assets, 'liabilities_total' => liabilities,
        'equity_total' => equity, 'result_not_yet_closed' => result,
        'balances' => assets == liabilities + equity + result }
    end

    # Reconciliation is the sole use of settlement date. It is never frozen by
    # a close and is recomputed every time (INV-AM-10).
    def reconcile(account:, as_of:, actual_balance: nil, book: nil)
      unless @config.cash_account?(account)
        raise Refused, "account #{account} is not marked cash in the chart, so there is no real " \
                       'balance to compare against (INV-AM-10)'
      end

      as_of = Date.parse(as_of.to_s)
      settled = 0
      unsettled = []
      # Read in the same direction the account's statement reads. A bank
      # statement of 100.00 means the asset is 100.00; a card statement of
      # 42.30 means the liability is 42.30 — and the ledger holds that as a
      # credit, so the raw debit-minus-credit is negative. Comparing the raw
      # figure against what the operator typed off the statement returned twice
      # the balance as a residue, on books that agreed to the cent.
      sign = @config.account_type(account) == 'liability' ? -1 : 1

      @store.postings.each do |posting|
        lines = posting['lines'].select { |l| l['account'] == account.to_s }
        lines = lines.select { |l| l['book'] == book } if book
        next if lines.empty?

        tx = Date.parse(posting['transaction_date'])
        settle = posting['settlement_date'] && Date.parse(posting['settlement_date'])
        # Settlement date decides settled-ness (INV-AM-10); transaction date
        # decides only whether the posting exists yet from the reader's point
        # of view. Filtering the whole loop by transaction date, as this used
        # to, dropped a posting settled before `as_of` but dated after it out
        # of BOTH buckets — a residue with an empty unsettled list, which is a
        # difference the operator cannot account for.
        amount = sign * lines.sum { |l| l['debit'] - l['credit'] }
        if settle && settle <= as_of
          settled += amount
        elsif tx <= as_of
          unsettled << { 'id' => posting['id'], 'transaction_date' => posting['transaction_date'],
                         'settlement_date' => posting['settlement_date'],
                         'description' => posting['description'], 'amount' => amount }
        end
      end

      # A purchase still waiting as a proposal is listed for the same reason an
      # unsettled posting is: it is a difference the operator can account for.
      # Only the ones that touch THIS account — an unrelated private proposal
      # is not a difference in a business bank reconciliation.
      waiting = @store.proposals.select do |p|
        p['state'] == 'undecided' && p['transaction_date'] &&
          Date.parse(p['transaction_date']) <= as_of && touches?(p, account, book)
      end

      actual = actual_balance.nil? ? nil : Money.to_minor(actual_balance)
      { 'kind' => 'reconciliation', 'account' => account.to_s, 'as_of' => as_of.iso8601,
        'book' => book, 'currency' => @config.currency,
        'settled_balance' => settled, 'actual_balance' => actual,
        'residue' => actual.nil? ? nil : actual - settled,
        'unsettled' => unsettled,
        'waiting_proposals' => waiting.map { |p| { 'id' => p['id'], 'transaction_date' => p['transaction_date'], 'description' => p['description'] } } }
    end

    # --- Rendering. CSV is the seam: plot from it, no chart lives here. ---

    def to_markdown(report)
      case report['kind']
      when 'profit_and_loss'
        lines = ["# Profit and loss — #{report['from']} to #{report['to']} (#{report['currency']})", '']
        lines << section_md('Income', report['income'])
        lines << section_md('Expense', report['expense'])
        lines << "**Result: #{Money.render(report['result'])}**"
        lines.join("\n")
      when 'balance_sheet'
        lines = ["# Balance sheet — as of #{report['as_of']} (#{report['currency']})", '']
        lines << section_md('Assets', report['assets'])
        lines << section_md('Liabilities', report['liabilities'])
        lines << section_md('Equity', report['equity'])
        lines << "Result not yet closed into equity: #{Money.render(report['result_not_yet_closed'])}"
        lines << ''
        lines << (report['balances'] ? '**Assets = liabilities + equity + result.**' : '**DOES NOT BALANCE — this is a defect, report it.**')
        lines.join("\n")
      when 'reconciliation'
        lines = ["# Reconciliation — #{report['account']} as of #{report['as_of']} (#{report['currency']})", '']
        lines << "Settled book balance: #{Money.render(report['settled_balance'])}"
        lines << "Real account balance: #{report['actual_balance'] ? Money.render(report['actual_balance']) : 'not given'}"
        lines << "**Residue: #{report['residue'] ? Money.render(report['residue']) : 'not computable without the real balance'}**"
        lines << ''
        lines << "## Not yet settled (#{report['unsettled'].size})"
        report['unsettled'].each { |u| lines << "- #{u['transaction_date']} #{u['description']} #{Money.render(u['amount'])} (#{u['id']})" }
        lines << ''
        lines << "## Waiting as proposals, counted by nothing (#{report['waiting_proposals'].size})"
        report['waiting_proposals'].each { |w| lines << "- #{w['transaction_date']} #{w['description']} (#{w['id']})" }
        lines.join("\n")
      else
        raise ArgumentError, "unknown report kind: #{report['kind']}"
      end
    end

    def to_csv(report)
      CSV.generate do |csv|
        case report['kind']
        when 'profit_and_loss'
          csv << %w[section account name amount]
          report['income'].each { |a| csv << ['income', a['account'], a['name'], Money.render(a['amount'])] }
          report['expense'].each { |a| csv << ['expense', a['account'], a['name'], Money.render(a['amount'])] }
          csv << ['result', nil, nil, Money.render(report['result'])]
        when 'balance_sheet'
          csv << %w[section account name amount]
          %w[assets liabilities equity].each do |section|
            report[section].each { |a| csv << [section, a['account'], a['name'], Money.render(a['amount'])] }
          end
          csv << ['result_not_yet_closed', nil, nil, Money.render(report['result_not_yet_closed'])]
        when 'reconciliation'
          csv << %w[section id transaction_date settlement_date description amount]
          report['unsettled'].each do |u|
            csv << ['unsettled', u['id'], u['transaction_date'], u['settlement_date'], u['description'], Money.render(u['amount'])]
          end
          report['waiting_proposals'].each do |w|
            csv << ['waiting_proposal', w['id'], w['transaction_date'], nil, w['description'], nil]
          end
          csv << ['residue', nil, report['as_of'], nil, nil, report['residue'] && Money.render(report['residue'])]
        else
          raise ArgumentError, "unknown report kind: #{report['kind']}"
        end
      end
    end

    private

    # A proposal's lines are drafts, so they may sit on the record itself or
    # only in the agent's suggestion. A proposal that names neither is not
    # attributable to any account and is left out rather than guessed at.
    def touches?(proposal, account, book)
      lines = proposal['lines'] || (proposal['suggested'] || {})['lines'] || []
      lines.any? do |l|
        l['account'].to_s == account.to_s && (book.nil? || l['book'].to_s == book.to_s)
      end
    end

    def each_line(from:, to:, book: nil, skip_kinds: [])
      @store.postings.each do |posting|
        next if skip_kinds.include?(posting['kind'])

        tx = Date.parse(posting['transaction_date'])
        next if from && tx < from
        next if to && tx > to

        posting['lines'].each do |line|
          next if book && line['book'] != book

          yield(line, posting)
        end
      end
    end

    def named(hash)
      hash.reject { |_, v| v.zero? }
          .sort_by { |account, _| account.to_s }
          .map { |account, amount| { 'account' => account, 'name' => @config.account_name(account), 'amount' => amount } }
    end

    def section_md(title, rows)
      out = ["## #{title}", '', '| account | name | amount |', '|---|---|---|']
      rows.each { |r| out << "| #{r['account']} | #{r['name']} | #{Money.render(r['amount'])} |" }
      out << "| | **total** | **#{Money.render(rows.sum { |r| r['amount'] })}** |"
      out << ''
      out.join("\n")
    end
  end
end
