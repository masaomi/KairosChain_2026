# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'digest'
require 'date'
require 'time'

require 'account_manager/money'
require 'account_manager/config'

module AccountManager
  # The ledger's whole state: postings, proposals, closings, evidence.
  #
  # A *range* is one calendar month of transaction dates. Ranges partition the
  # ledger by construction (INV-AM-5) — there is no range table to overlap or
  # to leave a gap, so the refusals that would have guarded those conditions do
  # not exist. Membership is by transaction date alone; settlement date belongs
  # to reconciliation (INV-AM-10).
  class Store
    AUTHORS       = %w[operator agent].freeze
    POSTING_KINDS = %w[ordinary opening closing_entry prior_period_correction].freeze

    attr_reader :ledger, :path, :config

    def initialize(ledger: 'main', path: nil, config: nil)
      @ledger = ledger
      @path = path || File.join(Config.ledger_dir(ledger), 'store.json')
      @data = load_data
      @config = config || Config.load(ledger: ledger, store: self)
    end

    def receipts_dir = File.join(File.dirname(@path), 'receipts')

    # --- Ranges ---

    def self.range_of(date)
      d = date.is_a?(Date) ? date : Date.parse(date.to_s)
      format('%04d-%02d', d.year, d.month)
    end

    def range_of(date) = self.class.range_of(date)

    def range_last_day(range)
      y, m = range.split('-').map(&:to_i)
      Date.new(y, m, -1)
    end

    # Folded from the append-only closing log. A range is open until closed,
    # open again once re-opened, and sealed once its year is closed — and a
    # seal is final because nothing appends after it.
    def range_state(range)
      state = 'open'
      @data['closings'].each do |record|
        next unless record['range'] == range

        state = case record['action']
                when 'close'  then 'closed'
                when 'reopen' then 'open'
                when 'seal'   then 'sealed'
                else state
                end
      end
      state
    end

    def year_sealed?(year)
      @data['closings'].any? { |r| r['action'] == 'annual_close' && r['year'].to_i == year.to_i }
    end

    # The fiscal boundary the sealed years were actually closed under, read
    # from the chart each closing record froze. nil while nothing is closed.
    def fiscal_year_start_month_in_force
      record = @data['closings'].reverse.find { |c| c['chart'].is_a?(Hash) && c['chart']['fiscal_year_start_month'] }
      record && record['chart']['fiscal_year_start_month'].to_i
    end

    def ranges_in_fiscal_year(year)
      first = @config.fiscal_year_start(year)
      last  = @config.fiscal_year_end(year)
      ranges = []
      cursor = Date.new(first.year, first.month, 1)
      while cursor <= last
        ranges << range_of(cursor)
        cursor = cursor.next_month
      end
      ranges
    end

    # --- Reads ---

    def postings = @data['postings'].values
    def proposals = @data['proposals'].values
    def closings = @data['closings']
    def evidence = @data['evidence']
    def currency = @data['currency']

    # Written long-hand on purpose. The endless form
    #   def fetch_posting(id) = @data['postings'][id] or raise Refused, '...'
    # parses as `(def ...) or raise`: the raise runs once at load and never at
    # call, so every unknown id returned nil and eleven call sites crashed with
    # NoMethodError instead of refusing. Found by review R1, 2026-08-05.
    def fetch_posting(id)
      @data['postings'][id] || raise(Refused, "unknown posting: #{id}")
    end

    def fetch_proposal(id)
      @data['proposals'][id] || raise(Refused, "unknown proposal: #{id}")
    end

    def postings_in_range(range)
      postings.select { |p| range_of(p['transaction_date']) == range }
    end

    def undecided_proposals_in_range(range)
      proposals.select do |p|
        p['state'] == 'undecided' && p['transaction_date'] && range_of(p['transaction_date']) == range
      end
    end

    # Which accounts the postings actually reference, and under which type they
    # were posted. The type travels with the line so a chart edit can be
    # checked against what was already recorded (INV-AM-6).
    def account_usage
      postings.each_with_object({}) do |posting, usage|
        posting['lines'].each do |line|
          entry = usage[line['account']] ||= { count: 0, types: [] }
          entry[:count] += 1
          entry[:types] << line['account_type']
        end
      end
    end

    # --- Postings ---

    # Every stored posting is a balanced journal entry (INV-AM-1) that balances
    # within each book as well (INV-AM-2), which is what the crossing pair is
    # for. Nothing else in this file may create a posting.
    # There is deliberately no `allow_closed_range:` parameter. Decision 12
    # grants the closed-range exception to *the annual close*, not to whoever
    # passes a flag; it lives in a private guard that only post_closing_entry
    # raises, and no caller can reach it.
    def post(transaction_date:, description:, lines:, settlement_date: nil, author: 'operator',
             kind: 'ordinary', evidence: [], note: nil, key: nil, corrects: nil,
             from_proposal: nil, now: Time.now)
      raise Refused, "unknown author: #{author} (#{AUTHORS.join('/')})" unless AUTHORS.include?(author)
      raise Refused, "unknown posting kind: #{kind}" unless POSTING_KINDS.include?(kind)

      tx = parse_date!(transaction_date, 'transaction_date')
      settle = settlement_date.nil? ? nil : parse_date!(settlement_date, 'settlement_date')
      built = build_lines(lines)
      # Balance first, cross second. A crossing redistributes a residue between
      # books; it must never absorb one, or a posting that is simply wrong by
      # ten would land as a crossing of ten and INV-AM-1 would hold vacuously.
      check_balance!(built)
      built = apply_crossing(built)
      check_settlement!(built, settle)

      range = range_of(tx)
      guard_range_open!(range)

      id = generate_id('pst')
      posting = {
        'id' => id, 'ledger' => @ledger, 'kind' => kind,
        'transaction_date' => tx.iso8601, 'settlement_date' => settle&.iso8601,
        'description' => description.to_s, 'lines' => built,
        'evidence' => Array(evidence).uniq, 'author' => author, 'note' => note,
        'key' => key || { 'source' => 'none', 'local' => id },
        'corrects' => corrects, 'from_proposal' => from_proposal,
        'created_at' => now.utc.iso8601
      }
      @data['postings'][id] = posting
      @data['currency'] ||= @config.currency
      save
      posting
    end

    # One rule, no branches (INV-AM-5): a posting whose range is open may be
    # edited; a posting whose range is closed may not be touched at all.
    def edit(id, transaction_date: nil, description: nil, lines: nil, settlement_date: :unset,
             note: nil, now: Time.now)
      posting = fetch_posting(id)
      guard_range_open!(range_of(posting['transaction_date']), verb: 'edit')

      tx = transaction_date ? parse_date!(transaction_date, 'transaction_date') : Date.parse(posting['transaction_date'])
      guard_range_open!(range_of(tx), verb: 'move a posting into') if range_of(tx) != range_of(posting['transaction_date'])

      built = posting['lines']
      if lines
        built = build_lines(lines)
        check_balance!(built)
        built = apply_crossing(built)
      end
      settle =
        if settlement_date == :unset
          posting['settlement_date'] ? Date.parse(posting['settlement_date']) : nil
        elsif settlement_date.nil?
          nil
        else
          parse_date!(settlement_date, 'settlement_date')
        end
      check_balance!(built)
      check_settlement!(built, settle)

      posting['transaction_date'] = tx.iso8601
      posting['settlement_date'] = settle&.iso8601
      posting['description'] = description.to_s if description
      posting['lines'] = built
      posting['note'] = note if note
      posting['edited_at'] = now.utc.iso8601
      save
      posting
    end

    # A sealed year is corrected by one new posting in an open range. It never
    # touches an income or expense account: those balances are already inside
    # retained earnings, so one side is the prior-period-adjustment account
    # (equity) and the other is the balance-sheet account actually misstated.
    # It may carry a settlement date when the side that was wrong is a cash
    # account, because money does move then; check_settlement! still refuses
    # one where nothing moved (INV-AM-10).
    def correct_sealed_year(corrects:, transaction_date:, description:, lines:,
                            settlement_date: nil, author: 'operator', note: nil, now: Time.now)
      original = fetch_posting(corrects)
      original_year = @config.fiscal_year_of(Date.parse(original['transaction_date']))
      unless year_sealed?(original_year)
        raise Refused, "posting #{corrects} is in fiscal year #{original_year}, which is not sealed; " \
                       'edit it in place if its range is open, or re-open that range (INV-AM-5)'
      end

      built = build_lines(lines)
      offenders = built.select { |l| @config.result_account?(l['account']) }
      unless offenders.empty?
        raise Refused, "a sealed-year correction may not touch an income or expense account; " \
                       "#{offenders.map { |l| l['account'] }.uniq.join(', ')} would put the correction in " \
                       'this year\'s result. Post the balancing side against ' \
                       "#{@config.prior_period_adjustment_account} (equity)"
      end
      unless built.any? { |l| l['account'].to_s == @config.prior_period_adjustment_account.to_s }
        raise Refused, "a sealed-year correction must post one side against the prior-period-adjustment " \
                       "account #{@config.prior_period_adjustment_account.inspect}"
      end
      # The other side must be the account that was actually misstated. Posting
      # straight into retained earnings restates the sealed year by an
      # arbitrary amount and leaves nothing pointing at what was wrong.
      if built.any? { |l| l['account'].to_s == @config.retained_earnings_account.to_s }
        raise Refused, "a sealed-year correction may not touch the retained-earnings account " \
                       "#{@config.retained_earnings_account.inspect}; the prior-period-adjustment " \
                       'account is what carries it into equity'
      end
      others = built.reject { |l| l['account'].to_s == @config.prior_period_adjustment_account.to_s }
      if others.empty?
        raise Refused, 'a sealed-year correction needs the account that was actually misstated on its other side'
      end

      # A correction against a cash account may carry a settlement date: money
      # does move when the bank is the side that was wrong. It stays optional,
      # and check_settlement! still refuses one where nothing moved.
      post(transaction_date: transaction_date, description: description, lines: lines,
           settlement_date: settlement_date, author: author, kind: 'prior_period_correction',
           note: note, corrects: corrects, now: now)
    end

    def annotate(id, note:, now: Time.now)
      posting = fetch_posting(id)
      guard_range_open!(range_of(posting['transaction_date']), verb: 'note')
      posting['note'] = note
      posting['edited_at'] = now.utc.iso8601
      save
      posting
    end

    # --- Proposals (INV-AM-7: nothing becomes a figure without the operator) ---

    def add_proposal(transaction_date:, description:, author:, lines: nil, settlement_date: nil,
                     key: nil, row: nil, evidence: [], suggested: nil, note: nil, now: Time.now)
      raise Refused, "unknown author: #{author} (#{AUTHORS.join('/')})" unless AUTHORS.include?(author)

      tx = parse_date!(transaction_date, 'transaction_date')
      id = generate_id('prp')
      proposal = {
        'id' => id, 'ledger' => @ledger, 'state' => 'undecided',
        'transaction_date' => tx.iso8601,
        'settlement_date' => settlement_date.nil? ? nil : parse_date!(settlement_date, 'settlement_date').iso8601,
        'description' => description.to_s, 'lines' => lines, 'suggested' => suggested,
        'author' => author, 'key' => key || { 'source' => 'none', 'local' => id },
        'row' => row, 'evidence' => Array(evidence).uniq, 'note' => note,
        'content_hash' => row ? content_hash(row) : nil,
        'created_at' => now.utc.iso8601
      }
      @data['proposals'][id] = proposal
      save
      proposal
    end

    # Posting a proposal carries its evidence onto the posting. Round 3 left
    # this as "a behaviour to specify at implementation"; this is the choice.
    def post_proposal(id, transaction_date: nil, description: nil, lines: nil,
                      settlement_date: :unset, now: Time.now)
      proposal = fetch_proposal(id)
      raise Refused, "proposal #{id} is #{proposal['state']}, not undecided" unless proposal['state'] == 'undecided'

      settle = settlement_date == :unset ? proposal['settlement_date'] : settlement_date
      # One act, one save. Saving the posting before marking the proposal
      # decided leaves a window where a retry posts the same figure twice.
      atomically do
        posting = post(
          transaction_date: transaction_date || proposal['transaction_date'],
          description: description || proposal['description'],
          lines: lines || proposal['lines'] || (proposal['suggested'] || {})['lines'],
          settlement_date: settle, author: proposal['author'], evidence: proposal['evidence'],
          key: proposal['key'], from_proposal: id, now: now
        )
        proposal = fetch_proposal(id)
        proposal['state'] = 'posted'
        proposal['posted_as'] = posting['id']
        proposal['decided_at'] = now.utc.iso8601
        posting
      end
    end

    # A discard is a decision, not a wall: the record is kept so a re-import
    # does not re-propose it, and the discard can be undone (INV-AM-9).
    def discard_proposal(id, reason:, now: Time.now)
      proposal = fetch_proposal(id)
      raise Refused, "proposal #{id} is #{proposal['state']}, not undecided" unless proposal['state'] == 'undecided'
      raise Refused, 'a discard needs a reason' if reason.to_s.strip.empty?

      proposal['state'] = 'discarded'
      proposal['discard_reason'] = reason
      proposal['decided_at'] = now.utc.iso8601
      save
      proposal
    end

    def undo_discard(id, now: Time.now)
      proposal = fetch_proposal(id)
      raise Refused, "proposal #{id} is #{proposal['state']}, not discarded" unless proposal['state'] == 'discarded'

      proposal['state'] = 'undecided'
      proposal['undiscarded_at'] = now.utc.iso8601
      proposal.delete('discard_reason')
      save
      proposal
    end

    # A join is the operator's confirmation, never a tool's inference
    # (INV-AM-9). It records the pairing; it posts nothing.
    def confirm_join(proposal_id:, target_kind:, target_id:, now: Time.now)
      proposal = fetch_proposal(proposal_id)
      case target_kind
      when 'posting'  then fetch_posting(target_id)
      when 'proposal' then fetch_proposal(target_id)
      else raise Refused, "unknown join target kind: #{target_kind} (posting/proposal)"
      end
      (proposal['joins'] ||= []) << { 'kind' => target_kind, 'id' => target_id,
                                      'confirmed_at' => now.utc.iso8601 }
      save
      proposal
    end

    def find_by_key(profile, reference)
      wanted = { 'profile' => profile.to_s, 'reference' => reference.to_s }
      (proposals + postings).find { |r| r['key'] == wanted }
    end

    # --- Evidence (INV-AM-4: identified by content, never removed in v0.1) ---

    def import_evidence(source_path:, filename: nil, now: Time.now)
      raise Refused, "no such file: #{source_path}" unless File.file?(source_path)

      bytes = File.binread(source_path)
      hash = ::Digest::SHA256.hexdigest(bytes)
      FileUtils.mkdir_p(receipts_dir)
      target = File.join(receipts_dir, hash)
      File.binwrite(target, bytes) unless File.exist?(target)
      record = @data['evidence'][hash] ||= {
        'hash' => hash, 'filename' => filename || File.basename(source_path),
        'bytes' => bytes.bytesize, 'imported_at' => now.utc.iso8601
      }
      save
      record
    end

    def bind_evidence(hash:, target_kind:, target_id:)
      raise Refused, "unknown evidence hash: #{hash}" unless @data['evidence'][hash]

      case target_kind
      when 'posting'
        posting = fetch_posting(target_id)
        guard_range_open!(range_of(posting['transaction_date']), verb: 'bind evidence to')
        (posting['evidence'] ||= []) << hash
        posting['evidence'].uniq!
        save
        posting
      when 'proposal'
        proposal = fetch_proposal(target_id)
        (proposal['evidence'] ||= []) << hash
        proposal['evidence'].uniq!
        save
        proposal
      else
        raise Refused, "unknown evidence target kind: #{target_kind} (posting/proposal)"
      end
    end

    # Evidence that vanished by some other route leaves its postings
    # unevidenced, which is a reported condition rather than a silent one.
    def unevidenced_postings
      postings.select do |p|
        cited = Array(p['evidence'])
        cited.empty? || cited.any? { |h| !File.exist?(File.join(receipts_dir, h)) }
      end
    end

    # --- Closing (INV-AM-5) ---

    # A range names a real month. `2026-99` used to close and persist.
    def valid_range!(range)
      unless range.to_s.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)
        raise Refused, "range #{range.inspect} is not a month; write it as YYYY-MM"
      end

      range.to_s
    end

    def close_range(range, now: Time.now)
      range = valid_range!(range)
      state = range_state(range)
      raise Refused, "range #{range} is #{state}; only an open range can be closed" unless state == 'open'

      append_closing(range: range, action: 'close', now: now)
    end

    def reopen_range(range, now: Time.now)
      range = valid_range!(range)
      state = range_state(range)
      raise Refused, "range #{range} is sealed by an annual close and can never be re-opened (INV-AM-5)" if state == 'sealed'
      raise Refused, "range #{range} is #{state}; only a closed range can be re-opened" unless state == 'closed'

      predecessor = @data['closings'].reverse.find { |r| r['range'] == range && r['action'] == 'close' }
      append_closing(range: range, action: 'reopen', supersedes: predecessor&.fetch('id'), now: now)
    end

    # The annual close does not close a range (handoff §4.1). It posts the
    # year's closing entry first and seals every range of the fiscal year
    # second. Order matters: sealing first would leave the entry homeless.
    #
    # The entry is dated the fiscal year's last day, which lands it in the
    # year's last range even when that range is already period-closed. That is
    # the one posting permitted into a closed range, and it is permitted only
    # here (operator decision 12, 2026-08-05): refusing it would make the
    # annual close unreachable in the ordinary month-by-month workflow.
    def annual_close(year, now: Time.now)
      year = whole_year!(year)
      raise Refused, "fiscal year #{year} is already sealed" if year_sealed?(year)

      # Post and seal are one act. Half of it on disk is a year sealed with no
      # closing entry, or a closing entry with no seal — and the retry cannot
      # tell, because the entry it would post has already zeroed the residues.
      atomically do
        closing_entry = post_closing_entry(year, now: now)
        records = ranges_in_fiscal_year(year).map do |range|
          append_closing(range: range, action: 'seal', year: year, now: now, save_now: false)
        end
        annual = {
          'id' => generate_id('cls'), 'action' => 'annual_close', 'year' => year,
          'ledger' => @ledger, 'closing_entry' => closing_entry&.fetch('id'),
          'sealed_ranges' => records.map { |r| r['range'] }, 'closed_at' => now.utc.iso8601
        }
        annual['hash'] = ::Digest::SHA256.hexdigest(JSON.generate(annual))
        @data['closings'] << annual
        { 'annual_close' => annual, 'closing_entry' => closing_entry, 'sealed' => records }
      end
    end

    def range_report(range)
      { 'range' => range, 'state' => range_state(range),
        'postings' => postings_in_range(range).size,
        'undecided_proposals' => undecided_proposals_in_range(range).map { |p| p['id'] } }
    end

    def save
      return if @deferring_saves

      FileUtils.mkdir_p(File.dirname(@path))
      # A unique temp name: one fixed name means two writers race on the same
      # file and one rename lands on a half-written body.
      tmp = "#{@path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      File.write(tmp, JSON.pretty_generate(@data))
      File.rename(tmp, @path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp.to_s)
    end

    private

    # Several operations are one act in two or three writes — posting a
    # proposal and marking it decided, posting the closing entry and sealing
    # the year. Saving between them leaves a state no operator asked for: an
    # undecided proposal whose retry duplicates the figure, or a sealed year
    # with no closing entry. One save at the end, or none.
    def atomically
      return yield if @deferring_saves

      @deferring_saves = true
      snapshot = deep_copy(@data)
      begin
        result = yield
        @deferring_saves = false
        save
        result
      rescue StandardError
        @data = snapshot
        raise
      ensure
        @deferring_saves = false
      end
    end

    def load_data
      unless File.exist?(@path)
        return { 'version' => 1, 'postings' => {}, 'proposals' => {},
                 'closings' => [], 'evidence' => {}, 'currency' => nil }
      end

      JSON.parse(File.read(@path))
    end

    def generate_id(prefix) = "#{prefix}_#{SecureRandom.hex(4)}"

    def content_hash(row) = ::Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))

    def parse_date!(value, field)
      Date.parse(value.to_s)
    rescue ArgumentError, TypeError, Date::Error
      raise Refused, "#{field} is not a date: #{value.inspect}"
    end

    # `year.to_i` turned 'abc' into 0 and sealed ranges 0000-01..0000-12
    # irreversibly, with no command able to remove them. A seal is permanent,
    # so what it is applied to is checked before it is applied.
    def whole_year!(value)
      unless value.is_a?(Integer) || value.to_s.match?(/\A-?\d+\z/)
        raise Refused, "year #{value.inspect} is not a year"
      end

      year = value.to_i
      unless (1000..9999).cover?(year)
        raise Refused, "year #{year} is outside 1000..9999; an annual close cannot be undone"
      end

      year
    end

    def guard_range_open!(range, verb: 'post into')
      state = range_state(range)
      return if state == 'open'
      # Decision 12's single exception. `closed` only — a seal is terminal and
      # the annual close never reaches past it, which is why this reads the
      # state rather than trusting the flag alone.
      return if @posting_closing_entry && state == 'closed'

      raise Refused, "cannot #{verb} range #{range}: it is #{state} (INV-AM-5). " \
                     "#{state == 'sealed' ? 'A sealed year is corrected by a new posting against the ' \
                        'prior-period-adjustment account.' : 'Re-open the range first.'}"
    end

    # Turns caller lines into stored lines. The account's type and its default
    # tax label are copied at this moment (INV-AM-8): a later chart edit cannot
    # restate a grouping already filed.
    def build_lines(lines)
      raw = Array(lines)
      raise Refused, 'a posting needs at least two lines (INV-AM-1)' if raw.size < 2

      raw.each_with_index.map do |line, index|
        raise Refused, "line #{index + 1} is not an object with an account and a book" unless line.respond_to?(:transform_keys)

        line = line.transform_keys(&:to_s)
        account = line['account'].to_s
        book = line['book'].to_s
        raise Refused, "line #{index + 1} names account #{account.inspect}, which the chart does not hold" unless @config.account(account)
        raise Refused, "line #{index + 1} names book #{book.inspect}, which the configuration does not declare" unless @config.books.include?(book)

        debit  = line['debit'].nil? ? 0 : Money.to_minor(line['debit'])
        credit = line['credit'].nil? ? 0 : Money.to_minor(line['credit'])
        raise Refused, "line #{index + 1} carries both a debit and a credit; a line is one or the other" if debit.positive? && credit.positive?
        raise Refused, "line #{index + 1} carries no amount" if debit.zero? && credit.zero?
        raise Refused, "line #{index + 1} carries a negative amount; use the other side instead" if debit.negative? || credit.negative?

        label = line.key?('tax_label') ? line['tax_label'] : @config.default_tax_label(account)
        if label && !@config.tax_labels.include?(label)
          raise Refused, "line #{index + 1} carries tax label #{label.inspect}, which tax_labels does not declare"
        end

        { 'account' => account, 'account_type' => @config.account_type(account), 'book' => book,
          'debit' => debit, 'credit' => credit, 'tax_label' => label,
          'note' => line['note'], 'foreign' => line['foreign'] }.compact
      end
    end

    # Each book balances on its own (INV-AM-2). A posting that crosses books
    # is completed through the configured owner-draw pair rather than refused,
    # and a ledger that permits no crossing refuses instead.
    def apply_crossing(lines)
      residues = @config.books.filter_map do |book|
        d = lines.select { |l| l['book'] == book }.sum { |l| l['debit'] - l['credit'] }
        [book, d] unless d.zero?
      end
      return lines if residues.empty?

      if @config.crossing.nil?
        raise Refused, "this posting does not balance within #{residues.map(&:first).join(' and ')}, " \
                       'and this ledger permits no crossing between books (INV-AM-2)'
      end

      crossed = lines.dup
      residues.each do |book, residue|
        account = @config.crossing[book]
        unless account
          raise Refused, "this posting crosses out of book #{book}, for which no crossing account is configured (INV-AM-2)"
        end

        crossed << { 'account' => account.to_s, 'account_type' => @config.account_type(account),
                     'book' => book, 'debit' => residue.negative? ? -residue : 0,
                     'credit' => residue.positive? ? residue : 0, 'tax_label' => nil,
                     'crossing' => true }
      end
      crossed
    end

    def check_balance!(lines)
      debits  = lines.sum { |l| l['debit'] }
      credits = lines.sum { |l| l['credit'] }
      return if debits == credits

      raise Refused, "this posting does not balance: debits #{Money.render(debits)} against credits " \
                     "#{Money.render(credits)} (INV-AM-1)"
    end

    # A posting for which no money moved carries no settlement date, and the
    # `cash` flag on the chart is what lets the tool tell (decision 10).
    def check_settlement!(lines, settlement_date)
      return if settlement_date.nil?
      return if lines.any? { |l| @config.cash_account?(l['account']) }

      raise Refused, 'this posting carries a settlement date but touches no cash, bank or card ' \
                     'account, so no money moved (INV-AM-10). Mark the account cash: true in the ' \
                     'chart, or drop the settlement date'
    end

    # The closing entry: every income and expense balance of the fiscal year is
    # transferred to the retained-earnings account, so the next year opens with
    # those accounts at zero and the balance sheet carries the result forward.
    #
    # Retained earnings is credited **in the book the result was earned in**.
    # Putting the whole transfer in one book made the crossing pair absorb the
    # other book's entire year: review R1 showed a business earning 800.00
    # reporting retained earnings of 300.00, with 500.00 appearing as an owner
    # contribution nobody made — and both books still reported as balancing,
    # which is why it was invisible. Per-book also means a ledger with
    # `crossing: none` can still close its year, which it previously could not.
    def post_closing_entry(year, now:)
      first = @config.fiscal_year_start(year)
      last  = @config.fiscal_year_end(year)
      residues = Hash.new(0)
      postings.each do |posting|
        tx = Date.parse(posting['transaction_date'])
        next unless tx >= first && tx <= last

        posting['lines'].each do |line|
          next unless @config.result_account?(line['account'])

          residues[[line['account'], line['book']]] += line['debit'] - line['credit']
        end
      end
      residues.reject! { |_, v| v.zero? }
      return nil if residues.empty?

      lines = residues.map do |(account, book), residue|
        { 'account' => account, 'book' => book,
          'debit' => residue.negative? ? Money.render(-residue) : nil,
          'credit' => residue.positive? ? Money.render(residue) : nil }.compact
      end
      per_book = residues.each_with_object(Hash.new(0)) { |((_, book), v), h| h[book] += v }
      per_book.each do |book, total|
        next if total.zero?

        lines << { 'account' => @config.retained_earnings_account, 'book' => book,
                   'debit' => total.positive? ? Money.render(total) : nil,
                   'credit' => total.negative? ? Money.render(-total) : nil }.compact
      end

      @posting_closing_entry = true
      post(transaction_date: last.iso8601, description: "closing entry for fiscal year #{year}",
           lines: lines, settlement_date: nil, author: 'operator', kind: 'closing_entry', now: now)
    ensure
      @posting_closing_entry = false
    end

    def append_closing(range:, action:, supersedes: nil, year: nil, now: Time.now, save_now: true)
      record = {
        'id' => generate_id('cls'), 'ledger' => @ledger, 'range' => range, 'action' => action,
        'year' => year, 'supersedes' => supersedes, 'closed_at' => now.utc.iso8601,
        'postings' => postings_in_range(range).map { |p| deep_copy(p) },
        'chart' => @config.snapshot,
        'undecided_proposals' => undecided_proposals_in_range(range).map { |p| deep_copy(p) }
      }.compact
      record['hash'] = ::Digest::SHA256.hexdigest(JSON.generate(record))
      @data['closings'] << record
      save if save_now
      record
    end

    def deep_copy(obj) = JSON.parse(JSON.generate(obj))
  end
end
