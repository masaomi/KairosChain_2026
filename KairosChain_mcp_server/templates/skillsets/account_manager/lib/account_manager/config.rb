# frozen_string_literal: true

require 'yaml'
require 'date'

module AccountManager
  # The loader's single refusal (INV-AM-6). It has a list of causes, not a
  # family of refusals: one raise, every cause named, nothing loads until the
  # configuration is put back.
  class ConfigError < StandardError
    attr_reader :causes

    def initialize(causes)
      @causes = causes
      super("configuration refused (#{causes.size} cause#{'s' if causes.size != 1}):\n- #{causes.join("\n- ")}")
    end
  end

  # Jurisdiction is data (INV-AM-6). No account name, no tax rate and no
  # country's rule appears in any tool's code; the whole of it is here, per
  # ledger, and the whole of it is validated before any of it is used.
  class Config
    ACCOUNT_TYPES       = %w[asset liability equity income expense].freeze
    BALANCE_SHEET_TYPES = %w[asset liability equity].freeze
    RESULT_TYPES        = %w[income expense].freeze

    attr_reader :ledger, :path, :data

    def self.ledger_dir(ledger)
      File.join(KairosMcp.data_dir, 'accounts', ledger)
    end

    def self.default_path(ledger)
      File.join(ledger_dir(ledger), 'config.yml')
    end

    # Shipped example. It is deliberately not a Swiss chart: a jurisdiction in
    # the package would be a jurisdiction in the code by another route.
    def self.example_path
      File.expand_path('../../config/accounts.yml', __dir__)
    end

    # store is optional: the causes that depend on what is already posted
    # (a retyped account, a changed currency) can only be checked against one.
    # A missing ledger configuration is refused, never substituted. The shipped
    # example declares currency XTS; falling back to it meant a mistyped ledger
    # name silently opened a new ledger and posted real money under the example
    # chart, after which the operator's own configuration was refused forever
    # because the currency had already been stamped into the store.
    def self.load(ledger: 'main', path: nil, store: nil)
      resolved = path || default_path(ledger)
      unless File.exist?(resolved)
        raise ConfigError, ["ledger #{ledger.inspect} has no configuration at #{resolved}. " \
                            "Copy the example at #{example_path} there and edit it — in particular " \
                            'the currency, which cannot be changed once anything is posted']
      end

      raw = YAML.safe_load_file(resolved, permitted_classes: [Date]) || {}
      new(raw, ledger: ledger, path: resolved).tap { |cfg| cfg.validate!(store) }
    end

    def initialize(data, ledger: 'main', path: nil)
      @data = data || {}
      @ledger = ledger
      @path = path
    end

    def currency = @data['currency']
    def books = Array(@data['books'])
    def tax_labels = Array(@data['tax_labels'])
    def fiscal_year_start_month = (@data['fiscal_year_start_month'] || 1).to_i
    def retained_earnings_account = @data['retained_earnings_account']
    def prior_period_adjustment_account = @data['prior_period_adjustment_account']

    # nil when the ledger permits no crossing; otherwise book => account id.
    def crossing
      c = @data['crossing']
      return nil if c.nil? || c == 'none' || c == false || (c.respond_to?(:empty?) && c.empty?)

      c
    end

    def accounts
      @accounts ||= Array(@data['chart_of_accounts']).each_with_object({}) do |a, h|
        h[a['id'].to_s] = a
      end
    end

    def account(id) = accounts[id.to_s]
    def account_type(id) = account(id)&.fetch('type', nil)
    def account_name(id) = account(id)&.fetch('name', nil) || id.to_s

    # Marks bank, cash and card accounts. Reconciliation needs it, and so does
    # the settlement-date refusal (INV-AM-10) — without it no tool can tell
    # whether money moved.
    def cash_account?(id) = account(id)&.fetch('cash', false) ? true : false

    def result_account?(id) = RESULT_TYPES.include?(account_type(id))
    def balance_sheet_account?(id) = BALANCE_SHEET_TYPES.include?(account_type(id))

    def default_tax_label(id) = account(id)&.fetch('default_tax_label', nil)

    def profiles
      @profiles ||= Array(@data['import_profiles']).each_with_object({}) do |p, h|
        h[p['name'].to_s] = p
      end
    end

    def profile(name) = profiles[name.to_s]

    # --- Fiscal year, labelled by the calendar year it starts in ---

    def fiscal_year_of(date)
      d = date.is_a?(Date) ? date : Date.parse(date.to_s)
      d.month >= fiscal_year_start_month ? d.year : d.year - 1
    end

    def fiscal_year_start(year) = Date.new(year.to_i, fiscal_year_start_month, 1)
    def fiscal_year_end(year) = fiscal_year_start(year).next_year.prev_day

    def snapshot
      { 'currency' => currency, 'books' => books, 'tax_labels' => tax_labels,
        'chart_of_accounts' => Array(@data['chart_of_accounts']),
        'crossing' => @data['crossing'], 'fiscal_year_start_month' => fiscal_year_start_month,
        'retained_earnings_account' => retained_earnings_account,
        'prior_period_adjustment_account' => prior_period_adjustment_account }
    end

    # INV-AM-6's one refusal. Every cause is collected before raising, so a
    # broken configuration is fixed in one pass rather than one cause per run.
    def validate!(store = nil)
      causes = []
      causes.concat(shape_causes)
      causes.concat(named_account_causes)
      causes.concat(crossing_causes)
      causes.concat(profile_causes)
      causes.concat(posting_dependent_causes(store)) if store
      raise ConfigError, causes unless causes.empty?

      self
    end

    private

    def shape_causes
      causes = []
      causes << 'currency is not declared' if currency.to_s.strip.empty?
      causes << 'books is empty; a ledger needs at least one book' if books.empty?
      unless (1..12).cover?(fiscal_year_start_month)
        causes << "fiscal_year_start_month #{fiscal_year_start_month.inspect} is not a month 1..12"
      end
      causes << 'chart_of_accounts is empty' if accounts.empty?
      # Duplicates in these three lists are silently collapsed by the hashes
      # built from them, which turns a typo into a shared namespace: two books
      # with one id let apply_crossing add a crossing line per duplicate, and
      # two profiles with one name put two sources in one key space, defeating
      # the (profile, reference) key entirely.
      %w[books chart_of_accounts import_profiles].each do |key|
        list = key == 'books' ? books : Array(@data[key]).map { |e| e[key == 'chart_of_accounts' ? 'id' : 'name'] }
        dupes = list.tally.select { |_, n| n > 1 }.keys
        causes << "#{key} names #{dupes.map(&:inspect).join(', ')} more than once" unless dupes.empty?
      end
      accounts.each do |id, a|
        causes << "account #{id} has type #{a['type'].inspect}, which is not one of #{ACCOUNT_TYPES.join('/')}" unless ACCOUNT_TYPES.include?(a['type'])
        causes << "account #{id} is marked cash but has type #{a['type']}; only a balance-sheet account holds money" if a['cash'] && !BALANCE_SHEET_TYPES.include?(a['type'])
        if a['default_tax_label'] && !tax_labels.include?(a['default_tax_label'])
          causes << "account #{id} defaults to tax label #{a['default_tax_label'].inspect}, which tax_labels does not declare"
        end
      end
      causes
    end

    def named_account_causes
      %w[retained_earnings_account prior_period_adjustment_account].filter_map do |key|
        id = @data[key]
        next "#{key} is not declared" if id.nil?
        next "#{key} names #{id.inspect}, which the chart does not hold" unless account(id)
        next unless account_type(id) != 'equity'

        "#{key} names #{id.inspect}, whose type is #{account_type(id).inspect}; the invariant requiring it names equity"
      end
    end

    def crossing_causes
      return [] if crossing.nil?

      crossing.filter_map do |book, id|
        next "crossing names book #{book.inspect}, which books does not declare" unless books.include?(book)
        next "crossing names account #{id.inspect} for book #{book}, which the chart does not hold" unless account(id)
        next unless RESULT_TYPES.include?(account_type(id))

        "crossing account #{id.inspect} has type #{account_type(id)}; a crossing is not income or expense"
      end
    end

    def profile_causes
      profiles.flat_map do |name, p|
        columns = p['columns'] || {}
        causes = []
        causes << "import profile #{name} declares no columns" if columns.empty?
        %w[transaction_date description amount].each do |required|
          causes << "import profile #{name} maps no column for #{required}" unless columns[required]
        end
        # A statement is a statement *of* an account, in a book. Without both,
        # a landed row has no side the ledger can hold.
        if p['account'].nil?
          causes << "import profile #{name} declares no account; a statement belongs to one"
        elsif !account(p['account'])
          causes << "import profile #{name} names account #{p['account'].inspect}, which the chart does not hold"
        end
        causes << "import profile #{name} names book #{p['book'].inspect}, which books does not declare" unless books.include?(p['book'])
        ref = p['reference_field']
        # The old form also accepted an unmapped reference whenever a column
        # merely named `reference` existed, which moved a configuration defect
        # into a per-row runtime refusal — the loader's job, done late.
        if ref && !columns.value?(ref)
          causes << "import profile #{name} names reference field #{ref.inspect}, which it does not map"
        end
        marker = p['debit_marker']
        if marker && !(marker['column'] && marker.key?('debit_value'))
          causes << "import profile #{name} has a debit_marker without both column and debit_value"
        end
        causes
      end
    end

    # These causes exist only against a store: what is already posted is what
    # makes an otherwise ordinary chart edit unsatisfiable.
    def posting_dependent_causes(store)
      causes = []
      posted_currency = store.currency
      if posted_currency && posted_currency != currency
        causes << "currency is #{currency.inspect} but #{store.postings.size} posting(s) were made in #{posted_currency.inspect}; a currency cannot change under postings"
      end
      # Moving the fiscal boundary re-files every posting into a different
      # year. Where a year is already sealed, that strands months in it which
      # no annual close can ever reach, and retained earnings stays short by
      # their result for good.
      sealed = store.closings.select { |c| c['action'] == 'annual_close' }
      if sealed.any? && store.fiscal_year_start_month_in_force &&
         store.fiscal_year_start_month_in_force != fiscal_year_start_month
        causes << "fiscal_year_start_month is #{fiscal_year_start_month} but #{sealed.size} " \
                  "sealed year(s) were closed under #{store.fiscal_year_start_month_in_force}; " \
                  'moving the fiscal boundary strands months no close can reach'
      end
      store.account_usage.each do |id, usage|
        unless account(id)
          causes << "account #{id} was removed while #{usage[:count]} posting line(s) reference it; renaming is safe, removing is not"
          next
        end
        next if usage[:types].all? { |t| t == account_type(id) }

        was = usage[:types].uniq.join('/')
        causes << "account #{id} is typed #{account_type(id)} but #{usage[:count]} posting line(s) were posted under type #{was}"
      end
      causes
    end
  end
end
