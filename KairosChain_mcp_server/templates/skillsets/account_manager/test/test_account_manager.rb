# frozen_string_literal: true

# Design-constraint tests for the account_manager SkillSet.
#
# Every test names the invariant or the worked case it verifies. Run from the
# project root:
#   ruby -I KairosChain_mcp_server/lib \
#        KairosChain_mcp_server/templates/skillsets/account_manager/test/test_account_manager.rb
#
# The seven worked cases (TestWorkedCases) are the review findings that three
# design rounds could not settle in prose. They are settled here, in figures.

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'json'
require 'date'

# Stub the gem module so lib loads without the kairos-chain gem (unit scope).
module KairosMcp
  class << self
    attr_accessor :data_dir_override

    def data_dir = data_dir_override || Dir.tmpdir
  end

  module Tools
    class BaseTool
      def text_content(str) = str
    end
  end
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'account_manager'

TOOL_DIR = File.expand_path('../tools', __dir__)
%w[am_entry am_import am_query am_report am_receipt am_close].each do |tool|
  load File.join(TOOL_DIR, "#{tool}.rb")
end

module LedgerFixture
  CHART = [
    { 'id' => 'cash',                    'name' => 'Cash on hand',      'type' => 'asset',     'cash' => true },
    { 'id' => 'bank',                    'name' => 'Bank',              'type' => 'asset',     'cash' => true },
    { 'id' => 'private_card',            'name' => 'Private card',      'type' => 'liability', 'cash' => true },
    { 'id' => 'business_claim',          'name' => 'Claim on business', 'type' => 'asset' },
    { 'id' => 'payable',                 'name' => 'Payable',           'type' => 'liability' },
    { 'id' => 'owner_account',           'name' => "Owner's account",   'type' => 'equity' },
    { 'id' => 'retained_earnings',       'name' => 'Retained earnings', 'type' => 'equity' },
    { 'id' => 'prior_period_adjustment', 'name' => 'Prior-period adj.', 'type' => 'equity' },
    { 'id' => 'income_services',         'name' => 'Services',          'type' => 'income',  'default_tax_label' => 'standard' },
    { 'id' => 'expense_supplies',        'name' => 'Supplies',          'type' => 'expense', 'default_tax_label' => 'standard' },
    { 'id' => 'expense_household',       'name' => 'Household',         'type' => 'expense' }
  ].freeze

  PROFILES = [
    { 'name' => 'example_bank', 'account' => 'bank', 'book' => 'business',
      'columns' => { 'transaction_date' => 'Date', 'settlement_date' => 'Booked',
                     'description' => 'Text', 'amount' => 'Amount', 'reference' => 'Ref' },
      'reference_field' => 'Ref', 'sign' => 'positive_is_debit' },
    { 'name' => 'other_bank', 'account' => 'cash', 'book' => 'private',
      'columns' => { 'transaction_date' => 'Date', 'description' => 'Text',
                     'amount' => 'Amount', 'reference' => 'Ref' },
      'reference_field' => 'Ref', 'sign' => 'positive_is_debit' },
    { 'name' => 'dictated', 'account' => 'cash', 'book' => 'private',
      'columns' => { 'transaction_date' => 'date', 'description' => 'description', 'amount' => 'amount' },
      'sign' => 'positive_is_debit' }
  ].freeze

  def self.config_hash(overrides = {})
    { 'currency' => 'XTS', 'books' => %w[business private],
      'crossing' => { 'business' => 'owner_account', 'private' => 'business_claim' },
      'fiscal_year_start_month' => 1,
      'retained_earnings_account' => 'retained_earnings',
      'prior_period_adjustment_account' => 'prior_period_adjustment',
      'chart_of_accounts' => CHART.map(&:dup), 'tax_labels' => %w[standard exempt],
      'import_profiles' => PROFILES.map(&:dup) }.merge(overrides)
  end

  def setup_ledger(overrides = {})
    @dir = Dir.mktmpdir
    KairosMcp.data_dir_override = @dir
    @config_path = File.join(@dir, 'accounts', 'main', 'config.yml')
    FileUtils.mkdir_p(File.dirname(@config_path))
    File.write(@config_path, YAML.dump(LedgerFixture.config_hash(overrides)))
    @store = AccountManager::Store.new(ledger: 'main')
  end

  def teardown
    KairosMcp.data_dir_override = nil
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # Fresh handle on the same files — proves a figure survived the write.
  def reopened = AccountManager::Store.new(ledger: 'main')

  def book_residue(posting, book)
    posting['lines'].select { |l| l['book'] == book }.sum { |l| l['debit'] - l['credit'] }
  end

  def line_for(posting, account) = posting['lines'].find { |l| l['account'] == account }
end

# --- INV-AM-1 / INV-AM-2: what a posting is ------------------------------------

class TestPostingIsBalanced < Minitest::Test
  include LedgerFixture
  def setup = setup_ledger

  # INV-AM-1: every stored posting is a balanced journal entry.
  def test_inv_am_1_unbalanced_posting_is_refused
    error = assert_raises(AccountManager::Refused) do
      @store.post(transaction_date: '2026-03-01', description: 'lopsided',
                  lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '10.00' },
                          { 'account' => 'bank', 'book' => 'business', 'credit' => '9.00' }])
    end
    assert_match(/does not balance/, error.message)
    assert_match(/INV-AM-1/, error.message)
    assert_empty @store.postings
  end

  # INV-AM-1: a line is one side or the other, and it carries an amount.
  def test_inv_am_1_line_with_both_sides_is_refused
    assert_raises(AccountManager::Refused) do
      @store.post(transaction_date: '2026-03-01', description: 'both sides',
                  lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '1.00', 'credit' => '1.00' },
                          { 'account' => 'cash', 'book' => 'business', 'credit' => '1.00' }])
    end
  end

  # INV-AM-1: amounts are exact. 0.1 + 0.2 must be 0.30, not 0.30000000000000004.
  def test_inv_am_1_amounts_are_exact_not_floating
    posting = @store.post(transaction_date: '2026-03-01', description: 'thirds',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => 0.1 },
                                  { 'account' => 'expense_household', 'book' => 'business', 'debit' => 0.2 },
                                  { 'account' => 'bank', 'book' => 'business', 'credit' => '0.30' }],
                          settlement_date: '2026-03-01')
    assert_equal 30, posting['lines'].sum { |l| l['credit'] }
    assert_equal '0.30', AccountManager::Money.render(30)
  end

  # INV-AM-2: each book balances on its own, completed through the crossing pair.
  def test_inv_am_2_crossing_makes_each_book_balance_alone
    posting = @store.post(transaction_date: '2026-03-01', description: 'crossing',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '20.00' },
                                  { 'account' => 'cash', 'book' => 'private', 'credit' => '20.00' }],
                          settlement_date: '2026-03-01')
    assert_equal 0, book_residue(posting, 'business')
    assert_equal 0, book_residue(posting, 'private')
    assert line_for(posting, 'owner_account')['crossing']
  end

  # INV-AM-1, R1 mutation N11: fewer than two lines. check_balance! passes
  # vacuously on an empty list (0 == 0), so the minimum-shape half of INV-AM-1
  # is the only thing standing between the store and a posting with no lines.
  def test_inv_am_1_posting_with_fewer_than_two_lines_is_refused
    [[], [{ 'account' => 'bank', 'book' => 'business', 'debit' => '1.00' }]].each do |lines|
      error = assert_raises(AccountManager::Refused) do
        @store.post(transaction_date: '2026-03-01', description: 'too few', lines: lines)
      end
      assert_match(/at least two lines/, error.message)
    end
    assert_empty @store.postings
  end

  # INV-AM-1, R1 mutation N12: a negative debit and a negative credit balance
  # each other, so nothing else in the chain catches them.
  def test_inv_am_1_negative_amounts_are_refused
    error = assert_raises(AccountManager::Refused) do
      @store.post(transaction_date: '2026-03-01', description: 'negative both sides',
                  lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '-10.00' },
                          { 'account' => 'bank', 'book' => 'business', 'credit' => '-10.00' }])
    end
    assert_match(/negative amount/, error.message)
    assert_empty @store.postings
  end

  # INV-AM-1, R1 mutation M10: an amount finer than one minor unit is refused
  # rather than rounded. Every fixture amount had exactly two decimals, so the
  # rounding rule of the one conversion every amount passes through was
  # completely unexercised.
  def test_inv_am_1_sub_minor_precision_is_refused_not_rounded
    error = assert_raises(AccountManager::Refused) { AccountManager::Money.to_minor('10.005') }
    assert_match(/finer than one minor unit/, error.message)
    assert_raises(AccountManager::Refused) { AccountManager::Money.to_minor('0.335') }
    assert_equal 1000, AccountManager::Money.to_minor('10.00')
    assert_equal 1234, AccountManager::Money.to_minor('12.34')
  end

  # INV-AM-2: a ledger that permits no crossing refuses instead of inventing one.
  def test_inv_am_2_ledger_without_crossing_refuses_a_crossing_posting
    teardown
    setup_ledger('crossing' => 'none')
    error = assert_raises(AccountManager::Refused) do
      @store.post(transaction_date: '2026-03-01', description: 'crossing',
                  lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '20.00' },
                          { 'account' => 'cash', 'book' => 'private', 'credit' => '20.00' }],
                  settlement_date: '2026-03-01')
    end
    assert_match(/permits no crossing/, error.message)
  end
end

# --- INV-AM-3 / INV-AM-8 / INV-AM-10: what a line and a date mean ---------------

class TestLinesAndDates < Minitest::Test
  include LedgerFixture
  def setup = setup_ledger

  # INV-AM-3: the foreign amount is a note nothing sums, converts or parses.
  def test_inv_am_3_foreign_note_is_stored_verbatim_and_never_parsed
    posting = @store.post(transaction_date: '2026-03-01', description: 'book bought abroad',
                          settlement_date: '2026-03-05',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '18.40',
                                    'foreign' => 'EUR 19.00 at the till' },
                                  { 'account' => 'bank', 'book' => 'business', 'credit' => '18.40' }])
    assert_equal 'EUR 19.00 at the till', line_for(posting, 'expense_supplies')['foreign']
    assert_equal 1840, line_for(posting, 'expense_supplies')['debit']
  end

  # INV-AM-8: the tax label is copied at posting time; a later chart edit cannot
  # restate a grouping already filed.
  def test_inv_am_8_tax_label_is_copied_at_posting_time
    posting = @store.post(transaction_date: '2026-03-01', description: 'supplies',
                          settlement_date: '2026-03-01',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '10.00' },
                                  { 'account' => 'bank', 'book' => 'business', 'credit' => '10.00' }])
    assert_equal 'standard', line_for(posting, 'expense_supplies')['tax_label']

    chart = LedgerFixture.config_hash['chart_of_accounts']
    chart.find { |a| a['id'] == 'expense_supplies' }['default_tax_label'] = 'exempt'
    File.write(@config_path, YAML.dump(LedgerFixture.config_hash('chart_of_accounts' => chart)))
    assert_equal 'standard', line_for(reopened.fetch_posting(posting['id']), 'expense_supplies')['tax_label']
  end

  # INV-AM-8: a label the configuration does not declare is refused, not stored.
  def test_inv_am_8_undeclared_tax_label_is_refused
    assert_raises(AccountManager::Refused) do
      @store.post(transaction_date: '2026-03-01', description: 'supplies',
                  lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '10.00', 'tax_label' => 'reduced' },
                          { 'account' => 'bank', 'book' => 'business', 'credit' => '10.00' }])
    end
  end

  # INV-AM-10: a posting where no money moved carries no settlement date, and
  # the chart's `cash` flag is what lets the tool tell (operator decision 10).
  def test_inv_am_10_settlement_date_refused_where_no_money_moved
    error = assert_raises(AccountManager::Refused) do
      @store.post(transaction_date: '2026-03-01', description: 'owner draw, no money',
                  settlement_date: '2026-03-01',
                  lines: [{ 'account' => 'owner_account', 'book' => 'business', 'debit' => '50.00' },
                          { 'account' => 'payable', 'book' => 'business', 'credit' => '50.00' }])
    end
    assert_match(/no money moved/, error.message)
    assert_match(/INV-AM-10/, error.message)
  end

  # INV-AM-10 / INV-AM-5: transaction date alone places a posting in a range.
  # A settlement date inside a closed range does not close the posting.
  def test_inv_am_5_range_membership_is_by_transaction_date_alone
    posting = @store.post(transaction_date: '2026-04-28', description: 'card payment',
                          settlement_date: '2026-05-03',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '25.00' },
                                  { 'account' => 'private_card', 'book' => 'private', 'credit' => '25.00' }])
    @store.close_range('2026-05')
    assert_equal 'closed', @store.range_state('2026-05')
    assert_equal 'open', @store.range_state('2026-04')
    # Editable: its range is April, decided by the transaction date, not May.
    edited = @store.edit(posting['id'], description: 'card payment, corrected')
    assert_equal 'card payment, corrected', edited['description']
  end
end

# --- INV-AM-6: the loader's one refusal ----------------------------------------

class TestConfigRefusal < Minitest::Test
  include LedgerFixture
  def setup = setup_ledger

  # INV-AM-6: one refusal, every cause named at once, so a broken chart is
  # fixed in one pass rather than one cause per run.
  def test_inv_am_6_loader_names_every_cause_in_one_refusal
    broken = LedgerFixture.config_hash(
      'retained_earnings_account' => 'bank',        # exists, wrong type
      'prior_period_adjustment_account' => 'ghost', # not in the chart
      'currency' => ''
    )
    error = assert_raises(AccountManager::ConfigError) do
      AccountManager::Config.new(broken, ledger: 'main').validate!
    end
    assert_operator error.causes.size, :>=, 3
    assert(error.causes.any? { |c| c.include?('currency is not declared') })
    assert(error.causes.any? { |c| c.include?('ghost') })
    assert(error.causes.any? { |c| c.include?('equity') })
  end

  # INV-AM-6: a retyped account is caught against what was already posted,
  # which is why the line carries the type it was posted under.
  def test_inv_am_6_retyping_a_referenced_account_is_refused
    @store.post(transaction_date: '2026-03-01', description: 'supplies',
                settlement_date: '2026-03-01',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '10.00' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '10.00' }])
    chart = LedgerFixture.config_hash['chart_of_accounts']
    chart.find { |a| a['id'] == 'expense_supplies' }['type'] = 'asset'
    error = assert_raises(AccountManager::ConfigError) do
      AccountManager::Config.new(LedgerFixture.config_hash('chart_of_accounts' => chart)).validate!(@store)
    end
    assert(error.causes.any? { |c| c.include?('expense_supplies') && c.include?('posted under type expense') })
  end

  # INV-AM-6: a currency cannot change under postings.
  def test_inv_am_6_currency_change_under_postings_is_refused
    @store.post(transaction_date: '2026-03-01', description: 'supplies',
                settlement_date: '2026-03-01',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '10.00' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '10.00' }])
    error = assert_raises(AccountManager::ConfigError) do
      AccountManager::Config.new(LedgerFixture.config_hash('currency' => 'ABC')).validate!(reopened)
    end
    assert(error.causes.any? { |c| c.include?('currency') })
  end

  # INV-AM-6: renaming a referenced account is always safe.
  def test_inv_am_6_renaming_a_referenced_account_is_safe
    @store.post(transaction_date: '2026-03-01', description: 'supplies',
                settlement_date: '2026-03-01',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '10.00' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '10.00' }])
    chart = LedgerFixture.config_hash['chart_of_accounts']
    chart.find { |a| a['id'] == 'expense_supplies' }['name'] = 'Materials and consumables'
    AccountManager::Config.new(LedgerFixture.config_hash('chart_of_accounts' => chart)).validate!(reopened)
  end
end

# --- INV-AM-7 / INV-AM-9: proposals, keys, and what a re-import says ------------

class TestProposalsAndKeys < Minitest::Test
  include LedgerFixture

  def setup
    setup_ledger
    @importer = AccountManager::Importer.new(@store)
  end

  def rows(*refs)
    refs.map.with_index do |ref, i|
      { 'Date' => "2026-05-0#{i + 1}", 'Booked' => "2026-05-0#{i + 2}", 'Text' => "row #{ref}",
        'Amount' => '-20.00', 'Ref' => ref }
    end
  end

  def suggestion = { 'account' => 'expense_supplies', 'book' => 'business' }

  # INV-AM-7: a proposal is counted by no report and no balance.
  def test_inv_am_7_a_proposal_reaches_no_figure
    @importer.import(profile_name: 'example_bank', rows: rows('R1'), suggestions: [suggestion])
    pl = AccountManager::Report.new(reopened).profit_and_loss(from: '2026-01-01', to: '2026-12-31')
    assert_equal 0, pl['expense_total']
    assert_equal 0, pl['result']
    assert_equal 1, reopened.proposals.size
  end

  # INV-AM-7: a proposal records who authored it, and the posting keeps it.
  def test_inv_am_7_authorship_travels_from_proposal_to_posting
    result = @importer.import(profile_name: 'example_bank', rows: rows('R1'), suggestions: [suggestion])
    posting = @store.post_proposal(result['proposed'].first)
    assert_equal 'agent', posting['author']
    assert_equal 'posted', @store.fetch_proposal(result['proposed'].first)['state']
  end

  # INV-AM-9: the key is (profile, reference), never the reference alone, so two
  # sources both numbering their bookings from 1 do not collide.
  def test_inv_am_9_key_is_namespaced_by_profile
    @importer.import(profile_name: 'example_bank', rows: rows('1'), suggestions: [suggestion])
    result = @importer.import(profile_name: 'other_bank', rows: rows('1'), suggestions: [suggestion])
    assert_equal 1, result['proposed'].size, 'the second source must not be mistaken for the first'
    assert_equal 2, reopened.proposals.size
  end

  # INV-AM-9: a discard is a decision, not a wall — it can be undone.
  def test_inv_am_9_a_discard_can_be_undone
    id = @importer.import(profile_name: 'example_bank', rows: rows('R1'), suggestions: [suggestion])['proposed'].first
    @store.discard_proposal(id, reason: 'mistook it for the other card')
    assert_equal 'discarded', @store.fetch_proposal(id)['state']
    @store.undo_discard(id)
    assert_equal 'undecided', @store.fetch_proposal(id)['state']
    assert_nil @store.fetch_proposal(id)['discard_reason']
  end

  # INV-AM-9: a discard needs a reason.
  def test_inv_am_9_discard_without_a_reason_is_refused
    id = @importer.import(profile_name: 'example_bank', rows: rows('R1'), suggestions: [suggestion])['proposed'].first
    assert_raises(AccountManager::Refused) { @store.discard_proposal(id, reason: '  ') }
  end

  # INV-AM-9: a source with no reference field is reported as undeduplicable, so
  # a re-import is visibly a re-import rather than silently deduplicated.
  def test_inv_am_9_identifierless_source_is_reported_as_undeduplicable
    row = [{ 'date' => '2026-05-01', 'description' => 'dictated line', 'amount' => '-8.00' }]
    first = @importer.import(profile_name: 'dictated', rows: row)
    second = @importer.import(profile_name: 'dictated', rows: row)
    assert first['undeduplicable']
    assert_equal 1, first['proposed'].size
    assert_equal 1, second['proposed'].size, 'a line dictated twice is proposed twice'
  end

  # INV-AM-7 / INV-AM-9: a join is confirmed, never inferred.
  def test_inv_am_9_join_is_recorded_only_on_confirmation
    id = @importer.import(profile_name: 'example_bank', rows: rows('R1'), suggestions: [suggestion])['proposed'].first
    posting = @store.post(transaction_date: '2026-05-01', description: 'the same purchase, entered by hand',
                          settlement_date: '2026-05-01',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '20.00' },
                                  { 'account' => 'cash', 'book' => 'business', 'credit' => '20.00' }])
    assert_nil @store.fetch_proposal(id)['joins']
    @store.confirm_join(proposal_id: id, target_kind: 'posting', target_id: posting['id'])
    assert_equal posting['id'], @store.fetch_proposal(id)['joins'].first['id']
  end

  # INV-AM-7: CSV text enters through the same call as parsed rows.
  def test_inv_am_7_csv_text_lands_as_proposals
    csv = "Date,Booked,Text,Amount,Ref\n2026-05-01,2026-05-02,coffee beans,-12.50,C1\n"
    result = @importer.import(profile_name: 'example_bank', csv_text: csv, suggestions: [suggestion])
    assert_equal 1, result['proposed'].size
    assert_equal 'coffee beans', reopened.fetch_proposal(result['proposed'].first)['description']
  end
end

# --- INV-AM-4: evidence ---------------------------------------------------------

class TestEvidence < Minitest::Test
  include LedgerFixture
  def setup = setup_ledger

  def a_receipt(content = 'RECEIPT 42.30')
    path = File.join(@dir, "receipt_#{content.hash.abs}.txt")
    File.write(path, content)
    path
  end

  def a_posting
    @store.post(transaction_date: '2026-03-01', description: 'supplies', settlement_date: '2026-03-01',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '42.30' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '42.30' }])
  end

  # INV-AM-4: evidence is identified by its content; identical bytes are one blob.
  def test_inv_am_4_identical_bytes_are_one_blob
    first = @store.import_evidence(source_path: a_receipt)
    second = @store.import_evidence(source_path: a_receipt('RECEIPT 42.30'))
    assert_equal first['hash'], second['hash']
    assert_equal 1, reopened.evidence.size
  end

  # INV-AM-4: no tool deletes evidence — there is no such command at all.
  def test_inv_am_4_no_delete_path_exists
    refute AccountManager::Store.instance_methods(false).any? { |m| m.to_s.match?(/delete|remove|purge/) },
           'a store that can delete evidence can delete it wrongly'
    commands = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmReceipt.new
                                                                            .input_schema[:properties][:command][:enum]
    refute_includes commands, 'delete'
  end

  # INV-AM-4: evidence that vanished by another route leaves its postings
  # unevidenced — a reported condition, not a silent one.
  def test_inv_am_4_vanished_evidence_is_reported_not_hidden
    posting = a_posting
    record = @store.import_evidence(source_path: a_receipt)
    @store.bind_evidence(hash: record['hash'], target_kind: 'posting', target_id: posting['id'])
    refute_includes @store.unevidenced_postings.map { |p| p['id'] }, posting['id']

    File.delete(File.join(@store.receipts_dir, record['hash']))
    assert_includes reopened.unevidenced_postings.map { |p| p['id'] }, posting['id']
  end

  # INV-AM-5: binding evidence to a posting inside a closed range would change
  # that posting, so it is refused.
  def test_inv_am_5_binding_evidence_into_a_closed_range_is_refused
    posting = a_posting
    record = @store.import_evidence(source_path: a_receipt)
    @store.close_range('2026-03')
    assert_raises(AccountManager::Refused) do
      @store.bind_evidence(hash: record['hash'], target_kind: 'posting', target_id: posting['id'])
    end
  end

  # Round 3 left this unspecified: posting a proposal carries its evidence.
  def test_evidence_follows_a_proposal_into_its_posting
    record = @store.import_evidence(source_path: a_receipt)
    proposal = @store.add_proposal(transaction_date: '2026-03-01', description: 'supplies',
                                   author: 'operator', evidence: [record['hash']],
                                   lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '42.30' },
                                           { 'account' => 'bank', 'book' => 'business', 'credit' => '42.30' }])
    posting = @store.post_proposal(proposal['id'])
    assert_equal [record['hash']], posting['evidence']
  end
end

# --- INV-AM-5: closing, re-opening, sealing ------------------------------------

class TestClosing < Minitest::Test
  include LedgerFixture
  def setup = setup_ledger

  def earn(amount, date, description = 'fee')
    @store.post(transaction_date: date, description: description, settlement_date: date,
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => amount },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => amount }])
  end

  def spend(amount, date, description = 'supplies')
    @store.post(transaction_date: date, description: description, settlement_date: date,
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => amount },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => amount }])
  end

  # INV-AM-5: ranges partition by construction — there is no range table to
  # overlap or to leave a gap, so every posting is in exactly one range.
  def test_inv_am_5_every_posting_is_in_exactly_one_range
    assert_equal '2026-03', AccountManager::Store.range_of('2026-03-01')
    assert_equal '2026-03', AccountManager::Store.range_of('2026-03-31')
    assert_equal '2026-04', AccountManager::Store.range_of('2026-04-01')
  end

  # INV-AM-5: a posting whose range is closed may not be touched at all.
  def test_inv_am_5_closed_range_refuses_post_edit_and_note
    posting = spend('10.00', '2026-03-05')
    @store.close_range('2026-03')
    assert_raises(AccountManager::Refused) { spend('5.00', '2026-03-06') }
    assert_raises(AccountManager::Refused) { @store.edit(posting['id'], description: 'x') }
    assert_raises(AccountManager::Refused) { @store.annotate(posting['id'], note: 'x') }
  end

  # INV-AM-5: a period close is re-openable, and the re-opening names the
  # closing record it supersedes, so the change is visible rather than absent.
  def test_inv_am_5_reopen_names_the_record_it_supersedes
    spend('10.00', '2026-03-05')
    closed = @store.close_range('2026-03')
    reopen = @store.reopen_range('2026-03')
    assert_equal closed['id'], reopen['supersedes']
    assert_equal 'open', @store.range_state('2026-03')
    assert_equal 2, @store.closings.size, 'the superseded record stays'
  end

  # INV-AM-5: a closing record freezes the values, not only a hash, so a closed
  # range's statements are reproducible after the chart has moved on.
  def test_inv_am_5_closing_record_freezes_values_and_chart
    spend('10.00', '2026-03-05')
    record = @store.close_range('2026-03')
    assert_equal 1, record['postings'].size
    assert_equal 1000, record['postings'].first['lines'].sum { |l| l['debit'] }
    assert(record['chart']['chart_of_accounts'].any? { |a| a['id'] == 'expense_supplies' })
    refute_nil record['hash']
  end

  # INV-AM-5: the closing record lists the proposals nobody decided, so a real
  # transaction the operator never identified is recorded as absent.
  def test_inv_am_5_closing_record_lists_undecided_proposals
    @store.add_proposal(transaction_date: '2026-03-09', description: 'unidentified card row', author: 'agent')
    record = @store.close_range('2026-03')
    assert_equal 1, record['undecided_proposals'].size
  end

  # INV-AM-5: an annual close after any number of period closes is reachable.
  # This is the defect the handoff named fatal: the annual close used to be
  # refused for overlapping the period closes it was meant to seal.
  def test_inv_am_5_annual_close_is_reachable_after_period_closes
    earn('1000.00', '2026-06-01')
    spend('400.00', '2026-06-02')
    (1..12).each { |m| @store.close_range(format('2026-%02d', m)) }
    result = @store.annual_close(2026)
    assert result['annual_close']
    assert_equal 12, result['sealed'].size
    assert_equal 'sealed', reopened.range_state('2026-12')
  end

  # Operator decision 12 (2026-08-05): the closing entry is the one posting
  # permitted into a period-closed range, and only the annual close may make it.
  def test_decision_12_only_the_annual_close_posts_into_a_closed_range
    earn('1000.00', '2026-06-01')
    @store.close_range('2026-12')
    result = @store.annual_close(2026)
    entry = result['closing_entry']
    assert_equal '2026-12-31', entry['transaction_date']
    assert_equal 'closing_entry', entry['kind']
    # No other route into a closed range exists.
    assert_raises(AccountManager::Refused) { spend('1.00', '2026-12-15') }
  end

  # INV-AM-5, R1 mutation N27: editing a posting's transaction date must not
  # move it into a closed range. Nothing tested the date-move path, so a closed
  # month's figures could silently change.
  def test_inv_am_5_edit_cannot_move_a_posting_into_a_closed_range
    posting = spend('50.00', '2026-04-10')
    @store.close_range('2026-03')
    error = assert_raises(AccountManager::Refused) do
      @store.edit(posting['id'], transaction_date: '2026-03-15')
    end
    assert_match(/move a posting into/, error.message)
    pl = AccountManager::Report.new(reopened).profit_and_loss(from: '2026-03-01', to: '2026-03-31')
    assert_equal 0, pl['expense_total'], "the closed month's figures did not move"
  end

  # Decision 12, R1 mutation M4: the closing entry's privilege stops at a seal.
  # A ledger whose fiscal boundary is later moved could otherwise have an
  # annual close post into a range another year had already sealed.
  def test_decision_12_closing_entry_privilege_stops_at_a_seal
    earn('100.00', '2026-06-01')
    @store.annual_close(2026)
    assert_equal 'sealed', @store.range_state('2026-06')
    # There is no public way to ask for the exception at all.
    refute AccountManager::Store.instance_method(:post).parameters.flatten.include?(:allow_closed_range),
           'the closed-range exception must not be a parameter any caller can pass'
    error = assert_raises(AccountManager::Refused) { earn('1.00', '2026-06-02') }
    assert_match(/sealed/, error.message)

    # Defence in depth, tested directly because it is not reachable end-to-end:
    # annual_close refuses an already-sealed year, and moving the fiscal
    # boundary under a sealed year is now a configuration refusal, so no route
    # remains by which the closing entry could meet a seal. The guard is
    # asserted at its own contract instead — widening it to trust the flag
    # alone leaves the suite green, and this is the test that says why.
    @store.instance_variable_set(:@posting_closing_entry, true)
    sealed = assert_raises(AccountManager::Refused) do
      @store.send(:guard_range_open!, '2026-06')
    end
    assert_match(/sealed/, sealed.message)
    @store.send(:guard_range_open!, '2027-01') # open: the flag is not the point
  ensure
    @store&.instance_variable_set(:@posting_closing_entry, false)
  end

  # R1 (a): a year is a year. `to_i` turned 'abc' into 0 and irreversibly
  # sealed 0000-01..0000-12, with no command able to remove them.
  def test_annual_close_refuses_a_year_that_is_not_a_year
    ['abc', '', '20x6', nil, 0, 99].each do |bad|
      assert_raises(AccountManager::Refused) { @store.annual_close(bad) }
    end
    assert_empty reopened.closings
  end

  # R1 (a): a range names a real month; 2026-99 used to close and persist.
  def test_close_refuses_a_range_that_is_not_a_month
    %w[2026-99 2026-00 2026-1 nonsense].each do |bad|
      assert_raises(AccountManager::Refused) { @store.close_range(bad) }
    end
    assert_empty reopened.closings
  end

  # INV-AM-5: a sealed range can never be re-opened.
  def test_inv_am_5_sealed_range_can_never_be_reopened
    earn('100.00', '2026-06-01')
    @store.annual_close(2026)
    error = assert_raises(AccountManager::Refused) { @store.reopen_range('2026-06') }
    assert_match(/sealed/, error.message)
    assert_raises(AccountManager::Refused) { @store.annual_close(2026) }
  end

  # INV-AM-5: the closing entry balances and zeroes the year's result accounts.
  def test_inv_am_5_closing_entry_zeroes_the_result_accounts
    earn('1000.00', '2026-06-01')
    spend('400.00', '2026-06-02')
    @store.annual_close(2026)
    report = AccountManager::Report.new(reopened)
    sheet = report.balance_sheet(as_of: '2026-12-31')
    assert_equal 0, sheet['result_not_yet_closed']
    assert sheet['balances']
    assert_equal 60_000, sheet['equity'].find { |e| e['account'] == 'retained_earnings' }['amount']
  end

  # R1 (a): retained earnings is credited in the book the result was earned in.
  # Putting the whole transfer in books.first made the crossing pair swallow the
  # other book's year: a business earning 800.00 reported 300.00, with 500.00
  # showing as an owner contribution nobody made — and both books still
  # reported balances=true, which is why it was invisible.
  def test_closing_entry_credits_retained_earnings_in_each_book
    earn('1000.00', '2026-06-01')
    spend('200.00', '2026-06-02')
    @store.post(transaction_date: '2026-06-03', description: 'groceries', settlement_date: '2026-06-03',
                lines: [{ 'account' => 'expense_household', 'book' => 'private', 'debit' => '500.00' },
                        { 'account' => 'cash', 'book' => 'private', 'credit' => '500.00' }])
    entry = @store.annual_close(2026)['closing_entry']

    business = entry['lines'].find { |l| l['account'] == 'retained_earnings' && l['book'] == 'business' }
    private_book = entry['lines'].find { |l| l['account'] == 'retained_earnings' && l['book'] == 'private' }
    assert_equal 80_000, business['credit'], 'the business earned 800.00 and retains 800.00'
    assert_equal 50_000, private_book['debit'], 'the household consumed 500.00'
    refute entry['lines'].any? { |l| l['crossing'] }, 'a closing entry invents no owner contribution'

    report = AccountManager::Report.new(reopened)
    assert_equal 80_000, report.balance_sheet(as_of: '2026-12-31', book: 'business')['equity']
                               .find { |e| e['account'] == 'retained_earnings' }['amount']
    assert_equal 0, report.balance_sheet(as_of: '2026-12-31')['result_not_yet_closed']
  end

  # R1 (a): with retained earnings per book, a ledger that permits no crossing
  # can close its year. Previously any result in the second book made the
  # annual close permanently unreachable, and the refusal blamed the closing
  # entry rather than the configuration.
  def test_annual_close_works_without_a_crossing_pair
    teardown
    setup_ledger('crossing' => 'none')
    @store.post(transaction_date: '2026-06-01', description: 'fee', settlement_date: '2026-06-01',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '100.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '100.00' }])
    @store.post(transaction_date: '2026-06-02', description: 'groceries', settlement_date: '2026-06-02',
                lines: [{ 'account' => 'expense_household', 'book' => 'private', 'debit' => '40.00' },
                        { 'account' => 'cash', 'book' => 'private', 'credit' => '40.00' }])
    result = @store.annual_close(2026)
    assert result['closing_entry']
    assert_equal 0, AccountManager::Report.new(reopened).balance_sheet(as_of: '2026-12-31')['result_not_yet_closed']
  end

  # R1 (a): post-and-seal is one act. A save between them left either a sealed
  # year with no closing entry, or an entry whose retry could not be repeated
  # because the residues were already zero.
  def test_annual_close_writes_nothing_when_it_fails_partway
    earn('100.00', '2026-06-01')
    before = JSON.generate(reopened.closings)
    @store.define_singleton_method(:ranges_in_fiscal_year) { |_| raise 'interrupted' }
    assert_raises(RuntimeError) { @store.annual_close(2026) }
    after = reopened
    assert_equal before, JSON.generate(after.closings), 'no closing record was written'
    refute after.postings.any? { |p| p['kind'] == 'closing_entry' }, 'no orphan closing entry was left'
  end

  # INV-AM-5: the profit and loss of a closed year still shows the result. The
  # closing entry is a transfer, not a result event, so it is excluded.
  def test_inv_am_5_closed_year_profit_and_loss_still_shows_the_result
    earn('1000.00', '2026-06-01')
    spend('400.00', '2026-06-02')
    @store.annual_close(2026)
    pl = AccountManager::Report.new(reopened).profit_and_loss(from: '2026-01-01', to: '2026-12-31')
    assert_equal 60_000, pl['result']
  end
end

# --- The seven worked cases (acceptance A5) ------------------------------------

class TestWorkedCases < Minitest::Test
  include LedgerFixture

  def setup
    setup_ledger
    @importer = AccountManager::Importer.new(@store)
  end

  # Worked case 1: a business expense paid on a private card. Each book must
  # still balance alone, which is what the crossing pair is for.
  def test_case_1_business_expense_on_a_private_card
    posting = @store.post(transaction_date: '2026-03-14', description: 'toner, paid privately',
                          settlement_date: '2026-03-20',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '42.30' },
                                  { 'account' => 'private_card', 'book' => 'private', 'credit' => '42.30' }])
    assert_equal 0, book_residue(posting, 'business')
    assert_equal 0, book_residue(posting, 'private')
    assert_equal 4230, line_for(posting, 'owner_account')['credit']
    assert_equal 4230, line_for(posting, 'business_claim')['debit']

    pl = AccountManager::Report.new(reopened).profit_and_loss(from: '2026-01-01', to: '2026-12-31', book: 'business')
    assert_equal 4230, pl['expense_total'], 'the expense belongs to the business book'
  end

  # Worked case 2: one till slip, two books. The business bought supplies and
  # the household bought groceries on the same receipt, paid from the business
  # account.
  def test_case_2_mixed_till_slip
    posting = @store.post(transaction_date: '2026-03-14', description: 'one receipt, two books',
                          settlement_date: '2026-03-14',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '12.30' },
                                  { 'account' => 'expense_household', 'book' => 'private', 'debit' => '30.00' },
                                  { 'account' => 'bank', 'book' => 'business', 'credit' => '42.30' }])
    assert_equal 0, book_residue(posting, 'business')
    assert_equal 0, book_residue(posting, 'private')
    assert_equal 3000, line_for(posting, 'owner_account')['debit'], 'the owner drew 30.00 from the business'
    assert_equal 3000, line_for(posting, 'business_claim')['credit']

    report = AccountManager::Report.new(reopened)
    assert_equal 1230, report.profit_and_loss(from: '2026-03-01', to: '2026-03-31', book: 'business')['expense_total']
    assert_equal 3000, report.profit_and_loss(from: '2026-03-01', to: '2026-03-31', book: 'private')['expense_total']
  end

  # Worked case 3: an overlapping re-import where one row was posted and one was
  # discarded. Each booking is proposed once, whichever decision it reached.
  def test_case_3_overlapping_reimport_proposes_nothing_twice
    rows = %w[A1 A2 A3].map.with_index do |ref, i|
      { 'Date' => "2026-05-0#{i + 1}", 'Booked' => "2026-05-0#{i + 2}", 'Text' => "row #{ref}",
        'Amount' => '-20.00', 'Ref' => ref }
    end
    suggestions = Array.new(3) { { 'account' => 'expense_supplies', 'book' => 'business' } }
    first = @importer.import(profile_name: 'example_bank', rows: rows, suggestions: suggestions)
    assert_equal 3, first['proposed'].size

    @store.post_proposal(first['proposed'][0])
    @store.discard_proposal(first['proposed'][1], reason: 'this was the private card, not the business one')

    again = @importer.import(profile_name: 'example_bank', rows: rows, suggestions: suggestions)
    assert_empty again['proposed'], 'a posted or discarded booking must not be proposed again'
    assert_equal 3, again['already_present'].size
    assert_equal 3, reopened.proposals.size
    assert_equal 1, reopened.postings.size
  end

  # Worked case 4: the bank revised a provisional amount. The row is reported,
  # never dropped — otherwise the stale figure stands because the tool
  # recognised the key and looked no further.
  def test_case_4_bank_revises_an_amount_on_reimport
    row = { 'Date' => '2026-05-01', 'Booked' => '2026-05-02', 'Text' => 'card settlement',
            'Amount' => '-10.00', 'Ref' => 'B9' }
    @importer.import(profile_name: 'example_bank', rows: [row])
    revised = row.merge('Amount' => '-12.00')
    result = @importer.import(profile_name: 'example_bank', rows: [revised])

    assert_empty result['proposed']
    assert_empty result['already_present']
    assert_equal 1, result['changed'].size
    change = result['changed'].first
    assert_equal '-10.00', change['stored_row']['Amount']
    assert_equal '-12.00', change['incoming_row']['Amount']
    stored = reopened.fetch_proposal(change['existing_id'])
    assert_equal '10.00', stored['suggested']['lines'].first['credit'],
                 'the stored proposal is not silently restated; the operator decides'
    assert_equal 'undecided', stored['state']
  end

  # Worked case 5: an error made in December and found in March. The year is
  # open, so the December range is re-opened, edited and closed again — and the
  # superseded closing record stays, so the change is visible.
  def test_case_5_december_error_found_in_march_year_open
    posting = @store.post(transaction_date: '2026-12-20', description: 'supplies',
                          settlement_date: '2026-12-20',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '100.00' },
                                  { 'account' => 'bank', 'book' => 'business', 'credit' => '100.00' }])
    @store.close_range('2026-12')
    assert_raises(AccountManager::Refused) { @store.edit(posting['id'], description: 'wrong amount') }

    @store.reopen_range('2026-12')
    @store.edit(posting['id'], description: 'supplies, corrected',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '130.00' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '130.00' }],
                settlement_date: '2026-12-20')
    @store.close_range('2026-12')

    pl = AccountManager::Report.new(reopened).profit_and_loss(from: '2026-12-01', to: '2026-12-31')
    assert_equal 13_000, pl['expense_total']
    actions = reopened.closings.select { |c| c['range'] == '2026-12' }.map { |c| c['action'] }
    assert_equal %w[close reopen close], actions
  end

  # Worked case 6: the same error found after the annual close. The sealed year
  # is untouchable, and the correction never reaches this year's result — one
  # side is equity, the other is the balance-sheet account actually misstated.
  def test_case_6_same_error_found_after_the_annual_close
    posting = @store.post(transaction_date: '2026-12-20', description: 'supplies',
                          settlement_date: '2026-12-20',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '100.00' },
                                  { 'account' => 'bank', 'book' => 'business', 'credit' => '100.00' }])
    @store.close_range('2026-12')
    @store.annual_close(2026)
    assert_raises(AccountManager::Refused) { @store.edit(posting['id'], description: 'x') }

    # The tempting correction — restating the expense — is refused, because the
    # expense is already inside retained earnings.
    error = assert_raises(AccountManager::Refused) do
      @store.correct_sealed_year(
        corrects: posting['id'], transaction_date: '2027-03-04', description: 'restate supplies',
        lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '30.00' },
                { 'account' => 'bank', 'book' => 'business', 'credit' => '30.00' }]
      )
    end
    assert_match(/income or expense/, error.message)

    correction = @store.correct_sealed_year(
      corrects: posting['id'], transaction_date: '2027-03-04',
      description: 'understated supplies in the sealed year 2026',
      lines: [{ 'account' => 'prior_period_adjustment', 'book' => 'business', 'debit' => '30.00' },
              { 'account' => 'bank', 'book' => 'business', 'credit' => '30.00' }]
    )
    assert_nil correction['settlement_date'], 'no money moves for a correction (INV-AM-10)'
    assert_equal posting['id'], correction['corrects']

    # R1 mutation N21: the prior-period-adjustment leg is required. Without it
    # the sealed year's misstatement stands with nothing in equity pointing at
    # it. And the correction may not restate retained earnings directly.
    assert_raises(AccountManager::Refused) do
      @store.correct_sealed_year(
        corrects: posting['id'], transaction_date: '2027-03-05', description: 'no equity leg',
        lines: [{ 'account' => 'payable', 'book' => 'business', 'debit' => '5.00' },
                { 'account' => 'bank', 'book' => 'business', 'credit' => '5.00' }]
      )
    end
    assert_raises(AccountManager::Refused) do
      @store.correct_sealed_year(
        corrects: posting['id'], transaction_date: '2027-03-06', description: 'straight into equity',
        lines: [{ 'account' => 'prior_period_adjustment', 'book' => 'business', 'debit' => '999.00' },
                { 'account' => 'retained_earnings', 'book' => 'business', 'credit' => '999.00' }]
      )
    end

    report = AccountManager::Report.new(reopened)
    assert_equal 0, report.profit_and_loss(from: '2027-01-01', to: '2027-12-31')['result'],
                 "the sealed year's error must not land in this year's profit"
    assert report.balance_sheet(as_of: '2027-12-31')['balances']
  end

  # Worked case 7: year two's balance sheet carries year one's result. Without
  # the closing entry the sheet is short by exactly that result on the first day
  # of year two.
  def test_case_7_year_two_balance_sheet_carries_year_ones_result
    @store.post(transaction_date: '2026-06-01', description: 'fee', settlement_date: '2026-06-01',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '1000.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '1000.00' }])
    @store.post(transaction_date: '2026-06-02', description: 'supplies', settlement_date: '2026-06-02',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '400.00' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '400.00' }])
    @store.annual_close(2026)
    @store.post(transaction_date: '2027-02-01', description: 'fee', settlement_date: '2027-02-01',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '200.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '200.00' }])

    sheet = AccountManager::Report.new(reopened).balance_sheet(as_of: '2027-02-28')
    assert sheet['balances'], 'assets = liabilities + equity + result'
    assert_equal 60_000, sheet['equity'].find { |e| e['account'] == 'retained_earnings' }['amount'],
                 "year one's result of 600.00 is carried in equity"
    assert_equal 20_000, sheet['result_not_yet_closed'], 'only year two is still open'
    assert_equal 80_000, sheet['assets_total']
  end
end

# --- Reconciliation -------------------------------------------------------------

class TestReconciliation < Minitest::Test
  include LedgerFixture
  def setup = setup_ledger

  # INV-AM-10: reconciliation is the sole use of settlement date, and it is
  # recomputed every time rather than frozen by a close.
  def test_inv_am_10_reconciliation_reports_unsettled_and_residue
    @store.post(transaction_date: '2026-03-01', description: 'settled', settlement_date: '2026-03-02',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '100.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '100.00' }])
    @store.post(transaction_date: '2026-03-28', description: 'in flight',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '25.00' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '25.00' }])

    result = AccountManager::Report.new(reopened).reconcile(account: 'bank', as_of: '2026-03-31',
                                                            actual_balance: '100.00')
    assert_equal 10_000, result['settled_balance']
    assert_equal 0, result['residue']
    assert_equal 1, result['unsettled'].size
    assert_equal(-2500, result['unsettled'].first['amount'])
  end

  # R1 mutation N4: the balance sheet's EXPENSE arm. Every previous sheet test
  # either closed the year first or posted income only, so flipping the expense
  # sign changed nothing that anyone checked — on the most ordinary report the
  # tool produces.
  def test_balance_sheet_counts_an_unclosed_expense_with_the_right_sign
    @store.post(transaction_date: '2026-06-01', description: 'fee', settlement_date: '2026-06-01',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '1000.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '1000.00' }])
    @store.post(transaction_date: '2026-06-02', description: 'supplies', settlement_date: '2026-06-02',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '400.00' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '400.00' }])
    sheet = AccountManager::Report.new(reopened).balance_sheet(as_of: '2026-06-30')
    assert_equal 60_000, sheet['result_not_yet_closed'], 'income 1000.00 less expense 400.00, mid-year'
    assert_equal 60_000, sheet['assets_total']
    assert sheet['balances']
  end

  # INV-AM-10: a close never freezes reconciliation.
  def test_inv_am_10_reconciliation_survives_a_close_unfrozen
    @store.post(transaction_date: '2026-03-01', description: 'settled', settlement_date: '2026-03-02',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '100.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '100.00' }])
    @store.close_range('2026-03')
    result = AccountManager::Report.new(reopened).reconcile(account: 'bank', as_of: '2026-04-30',
                                                            actual_balance: '90.00')
    assert_equal(-1000, result['residue'])
  end

  # R2 (a): a card statement reads in the liability's own direction. The raw
  # debit-minus-credit made the residue come out at twice the balance, with an
  # empty unsettled list, on books that agreed to the cent.
  def test_inv_am_10_a_cash_liability_reconciles_in_statement_direction
    @store.post(transaction_date: '2026-03-14', description: 'toner on the private card',
                settlement_date: '2026-03-14',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '42.30' },
                        { 'account' => 'private_card', 'book' => 'private', 'credit' => '42.30' }])
    result = AccountManager::Report.new(reopened).reconcile(account: 'private_card', as_of: '2026-03-31',
                                                            actual_balance: '42.30')
    assert_equal 4230, result['settled_balance'], 'the card statement says 42.30 is owed'
    assert_equal 0, result['residue']
    assert_empty result['unsettled']
  end

  # R2 (a): the sealed-year correction's settlement date must survive the tool,
  # not only the store. Dropped at the tool, the correction sat in unsettled
  # for ever — still there a decade later.
  def test_inv_am_10_correction_settlement_date_survives_the_tool
    posting = @store.post(transaction_date: '2026-12-20', description: 'supplies',
                          settlement_date: '2026-12-20',
                          lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '100.00' },
                                  { 'account' => 'bank', 'book' => 'business', 'credit' => '100.00' }])
    @store.annual_close(2026)
    response = JSON.parse(KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmEntry.new.call(
                            'command' => 'correct_sealed', 'corrects' => posting['id'],
                            'transaction_date' => '2027-03-04', 'settlement_date' => '2027-03-06',
                            'description' => 'understated supplies in 2026',
                            'lines' => [{ 'account' => 'prior_period_adjustment', 'book' => 'business', 'debit' => '30.00' },
                                        { 'account' => 'bank', 'book' => 'business', 'credit' => '30.00' }]
                          ))
    refute response['refused'], "tool refused: #{response['refused']}"
    assert_equal '2027-03-06', response['settlement_date']

    result = AccountManager::Report.new(reopened).reconcile(account: 'bank', as_of: '2027-12-31',
                                                            actual_balance: '-130.00')
    assert_equal 0, result['residue'], 'the correction clears instead of sitting unsettled for ever'
    assert_empty result['unsettled']
  end

  # Decision 10: reconciliation needs the `cash` flag, and says so rather than
  # returning a comparison against nothing.
  def test_decision_10_reconciling_a_non_cash_account_is_refused
    error = assert_raises(AccountManager::Refused) do
      AccountManager::Report.new(@store).reconcile(account: 'expense_supplies', as_of: '2026-03-31')
    end
    assert_match(/not marked cash/, error.message)
  end

  # INV-AM-7 / INV-AM-10: a purchase still waiting as a proposal is listed
  # beside the unsettled postings, for the same reason — but only if it touches
  # the account being reconciled. R1: an unrelated private proposal appeared as
  # a business-bank difference.
  def test_inv_am_7_waiting_proposals_are_listed_only_for_this_account
    @store.add_proposal(transaction_date: '2026-03-15', description: 'card payment abroad, amount unknown',
                        author: 'operator',
                        lines: [{ 'account' => 'bank', 'book' => 'business', 'credit' => '80.00' },
                                { 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '80.00' }])
    @store.add_proposal(transaction_date: '2026-03-16', description: 'household, nothing to do with the bank',
                        author: 'operator',
                        lines: [{ 'account' => 'cash', 'book' => 'private', 'credit' => '9.00' },
                                { 'account' => 'expense_household', 'book' => 'private', 'debit' => '9.00' }])
    result = AccountManager::Report.new(@store).reconcile(account: 'bank', as_of: '2026-03-31')
    assert_equal 1, result['waiting_proposals'].size
    assert_equal 'card payment abroad, amount unknown', result['waiting_proposals'].first['description']
    assert_equal 0, result['settled_balance']
  end

  # R1 (a): settlement date decides settled-ness; transaction date must not
  # filter the loop. A posting settled before as_of but dated after it used to
  # fall out of BOTH buckets, giving a residue with an empty unsettled list.
  def test_inv_am_10_posting_settled_before_as_of_but_dated_after_is_counted
    @store.post(transaction_date: '2026-02-05', description: 'rent paid in advance',
                settlement_date: '2026-01-30',
                lines: [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '300.00' },
                        { 'account' => 'bank', 'book' => 'business', 'credit' => '300.00' }])
    result = AccountManager::Report.new(@store).reconcile(account: 'bank', as_of: '2026-01-31',
                                                          actual_balance: '-300.00')
    assert_equal(-30_000, result['settled_balance'])
    assert_equal 0, result['residue'], 'the payment is settled, so the residue is nil not 300.00'
    assert_empty result['unsettled']
  end

  # R1 (a), mutation N6: settlement exactly on the as-of date is the ordinary
  # month-end case and was untested.
  def test_inv_am_10_settlement_on_the_as_of_date_counts_as_settled
    @store.post(transaction_date: '2026-03-31', description: 'settled on the day',
                settlement_date: '2026-03-31',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '100.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '100.00' }])
    result = AccountManager::Report.new(@store).reconcile(account: 'bank', as_of: '2026-03-31',
                                                          actual_balance: '100.00')
    assert_equal 10_000, result['settled_balance']
    assert_equal 0, result['residue']
    assert_empty result['unsettled']
  end
end

# --- Acceptance A2 and A4: the tool surface -------------------------------------

class TestToolSurface < Minitest::Test
  include LedgerFixture
  def setup = setup_ledger

  # A2: every class named in skillset.json's tool_classes resolves.
  def test_a2_every_declared_tool_class_resolves
    manifest = JSON.parse(File.read(File.expand_path('../skillset.json', __dir__)))
    manifest['tool_classes'].each do |class_name|
      klass = Object.const_get(class_name)
      tool = klass.new
      refute_nil tool.name
      refute_nil tool.input_schema
    end
    assert_equal 6, manifest['tool_classes'].size
  end

  # A4 (seam): this test drives the real am_entry tool into the real store.
  # Inserting `raise` into AccountManager::Store#post turns it red — verified by
  # doing exactly that, not by reasoning about it.
  def test_a4_seam_am_entry_tool_drives_the_real_store
    tool = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmEntry.new
    response = JSON.parse(tool.call(
                            'command' => 'post', 'transaction_date' => '2026-03-14',
                            'description' => 'driven through the tool', 'settlement_date' => '2026-03-14',
                            'lines' => [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '42.30' },
                                        { 'account' => 'bank', 'book' => 'business', 'credit' => '42.30' }]
                          ))
    refute response['refused'], "tool refused: #{response['refused']}"
    refute response['error'], "tool errored: #{response['error']}"
    assert_equal 'main', response['ledger']
    assert_equal 4230, response['lines'].sum { |l| l['debit'] }

    # The figure is in the store on disk, not only in the response.
    assert_equal 1, reopened.postings.size
    assert_equal response['id'], reopened.postings.first['id']
  end

  # R1 (a), the worst one: tool objects are registered once and reused, so a
  # Store cached on one tool held a snapshot taken before every write another
  # tool had made since — and saving it erased them. Here `invoice 2` was
  # posted, acknowledged with an id, and was absent from disk.
  def test_interleaved_tools_do_not_erase_each_others_writes
    entry   = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmEntry.new
    receipt = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmReceipt.new
    query   = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmQuery.new
    path = File.join(@dir, 'slip.txt')

    two_sided = lambda do |amount|
      [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => amount },
       { 'account' => 'bank', 'book' => 'business', 'credit' => amount }]
    end
    post = lambda do |date, description, amount|
      response = JSON.parse(entry.call('command' => 'post', 'transaction_date' => date,
                                       'description' => description, 'settlement_date' => date,
                                       'lines' => two_sided.call(amount)))
      refute response['refused'], "tool refused: #{response['refused']}"
      response['id']
    end

    post.call('2026-03-01', 'invoice 1', '10.00')
    File.write(path, 'SLIP A')
    receipt.call('command' => 'import', 'path' => path)
    post.call('2026-03-02', 'invoice 2', '20.00')
    File.write(path, 'SLIP B')
    receipt.call('command' => 'import', 'path' => path)

    on_disk = reopened
    assert_equal %w[invoice\ 1 invoice\ 2],
                 on_disk.postings.map { |p| p['description'] }.sort,
                 'a posting acknowledged with an id must still be on disk'
    assert_equal 2, on_disk.evidence.size
    assert_equal 2, JSON.parse(query.call('what' => 'postings'))['postings'].size,
                 'and the query tool must not serve a stale view of it'
  end

  # R1 (a): a ledger name reaches the filesystem. `..` in it addressed a
  # directory outside the accounts tree, and a mistyped name silently opened a
  # whole new ledger.
  def test_ledger_name_is_checked_before_it_reaches_the_filesystem
    response = JSON.parse(KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmQuery.new
                                                                                     .call('ledger' => '../../elsewhere', 'what' => 'postings'))
    assert_match(/not a plain name/, response['refused'].to_s)
  end

  # R1 (a): a missing ledger configuration is refused, never substituted by the
  # shipped XTS example — which used to accept real postings and then refuse
  # the operator's own chart forever, because the currency was already stamped.
  def test_missing_ledger_config_is_refused_not_substituted
    response = JSON.parse(KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmQuery.new
                                                                                     .call('ledger' => 'mian', 'what' => 'postings'))
    assert_match(/has no configuration/, response['refused'].to_s)
    refute File.exist?(File.join(@dir, 'accounts', 'mian', 'store.json'))
  end

  # R1 (a): bad amounts and bad dates are the caller's mistake and must arrive
  # as refusals, not as an internal error envelope.
  def test_bad_input_arrives_as_a_refusal_not_an_error
    entry = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmEntry.new
    bad_amount = JSON.parse(entry.call('command' => 'post', 'transaction_date' => '2026-03-01',
                                       'description' => 'junk',
                                       'lines' => [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => 'abc' },
                                                   { 'account' => 'bank', 'book' => 'business', 'credit' => '1.00' }]))
    assert bad_amount['refused'], "expected a refusal, got #{bad_amount.inspect}"
    refute bad_amount['error']

    bad_lines = JSON.parse(entry.call('command' => 'post', 'transaction_date' => '2026-03-01',
                                      'description' => 'junk', 'lines' => %w[nothash alsonot]))
    assert bad_lines['refused'], "expected a refusal, got #{bad_lines.inspect}"

    bad_date = JSON.parse(KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmReport.new
                                                                                      .call('report' => 'balance_sheet', 'as_of' => 'nope'))
    assert bad_date['refused'], "expected a refusal, got #{bad_date.inspect}"
    refute bad_date['error']
  end

  # R1 (a): the dead `or raise` meant every unknown id returned nil and its
  # callers crashed with NoMethodError instead of refusing.
  def test_unknown_ids_refuse_rather_than_return_nil
    assert_raises(AccountManager::Refused) { @store.fetch_posting('pst_deadbeef') }
    assert_raises(AccountManager::Refused) { @store.fetch_proposal('prp_deadbeef') }

    entry = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmEntry.new
    %w[edit note get].each do |command|
      response = JSON.parse(entry.call('command' => command, 'id' => 'pst_deadbeef', 'note' => 'x'))
      assert_match(/unknown posting/, response['refused'].to_s, "#{command} must refuse")
    end
  end

  # R1 (a): confirm_join is where the dead refusal wrote bad data rather than
  # crashing — a join persisted against a posting that does not exist.
  def test_confirm_join_refuses_a_target_that_does_not_exist
    proposal = @store.add_proposal(transaction_date: '2026-03-01', description: 'a row', author: 'agent')
    assert_raises(AccountManager::Refused) do
      @store.confirm_join(proposal_id: proposal['id'], target_kind: 'posting', target_id: 'pst_ghost')
    end
    assert_nil reopened.fetch_proposal(proposal['id'])['joins']
  end

  # A refusal reaches the caller as a refusal, keeping the invariant reference.
  def test_a4_seam_tool_returns_a_refusal_not_a_stack_trace
    tool = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmEntry.new
    response = JSON.parse(tool.call(
                            'command' => 'post', 'transaction_date' => '2026-03-14', 'description' => 'lopsided',
                            'lines' => [{ 'account' => 'expense_supplies', 'book' => 'business', 'debit' => '10.00' },
                                        { 'account' => 'bank', 'book' => 'business', 'credit' => '9.00' }]
                          ))
    assert_match(/INV-AM-1/, response['refused'])
    assert_empty reopened.postings
  end

  # The close tool drives the real annual close, including the closing entry.
  def test_a4_seam_am_close_tool_drives_the_real_annual_close
    @store.post(transaction_date: '2026-06-01', description: 'fee', settlement_date: '2026-06-01',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '500.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '500.00' }])
    response = JSON.parse(KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmClose.new
                                                                                     .call('command' => 'annual_close', 'year' => 2026))
    refute response['refused'], "tool refused: #{response['refused']}"
    assert_equal 12, response['sealed'].size
    assert_equal 'sealed', reopened.range_state('2026-06')
  end

  # am_report renders markdown and CSV from the same figures.
  def test_report_tool_renders_markdown_and_csv
    @store.post(transaction_date: '2026-06-01', description: 'fee', settlement_date: '2026-06-01',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '500.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '500.00' }])
    tool = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmReport.new
    markdown = JSON.parse(tool.call('report' => 'profit_and_loss', 'from' => '2026-01-01', 'to' => '2026-12-31'))
    assert_match(/Result: 500\.00/, markdown['body'])

    csv = JSON.parse(tool.call('report' => 'profit_and_loss', 'from' => '2026-01-01',
                               'to' => '2026-12-31', 'format' => 'csv'))
    assert_match(/^result,,,500\.00$/, csv['body'])
  end

  # am_query returns proposals beside postings and counts neither as a figure.
  def test_query_tool_separates_proposals_from_postings
    @store.add_proposal(transaction_date: '2026-06-01', description: 'unidentified', author: 'agent')
    @store.post(transaction_date: '2026-06-01', description: 'fee', settlement_date: '2026-06-01',
                lines: [{ 'account' => 'bank', 'book' => 'business', 'debit' => '500.00' },
                        { 'account' => 'income_services', 'book' => 'business', 'credit' => '500.00' }])
    tool = KairosMcp::SkillSets::AccountManagerSkillSet::Tools::AmQuery.new
    assert_equal 1, JSON.parse(tool.call('what' => 'postings'))['postings'].size
    assert_equal 1, JSON.parse(tool.call('what' => 'proposals'))['proposals'].size
    assert_equal 1, JSON.parse(tool.call('what' => 'ranges'))['ranges'].size
  end
end

# --- Acceptance A3: every adopted invariant is cited ----------------------------

class TestInvariantCoverage < Minitest::Test
  ADOPTED = (1..10).map { |n| "INV-AM-#{n}" }.freeze

  # A3, rewritten after review R1 showed the old version was a broken
  # instrument presenting itself as a gate. It accepted a comment as a
  # citation, so it passed against a file containing zero tests and one comment
  # block; and it matched by substring, so INV-AM-1 was satisfied by any
  # INV-AM-10 comment — 6 of its 11 "citations" were that.
  #
  # Now: the invariant must appear in a **test method name**, matched on a word
  # boundary. A name cannot be written without a body, and this file has no way
  # to claim coverage it does not have.
  def test_a3_every_adopted_invariant_names_a_test_method
    names = File.read(__FILE__).lines.filter_map { |l| l[/def (test_\w+)/, 1] }
    refute_empty names

    uncited = ADOPTED.reject do |inv|
      slug = inv.downcase.tr('-', '_')            # INV-AM-5 -> inv_am_5
      names.any? { |n| n.match?(/#{Regexp.escape(slug)}(?!\d)/) }
    end
    assert_empty uncited, "invariants adopted but named by no test method: #{uncited.join(', ')}"
  end

  # The gate above must fail when coverage is actually missing. Checking the
  # checker: an invariant that no test method names has to be reported.
  def test_a3_gate_fails_when_an_invariant_is_uncited
    names = %w[test_inv_am_1_something test_inv_am_10_other]
    uncited = ADOPTED.reject do |inv|
      slug = inv.downcase.tr('-', '_')
      names.any? { |n| n.match?(/#{Regexp.escape(slug)}(?!\d)/) }
    end
    assert_includes uncited, 'INV-AM-5', 'the gate must notice an invariant nobody named'
    refute_includes uncited, 'INV-AM-1'
    refute_includes uncited, 'INV-AM-10'
    assert_equal 8, uncited.size, 'INV-AM-1 must not be satisfied by INV-AM-10'
  end

  # INV-AM-11 was withdrawn with multi-currency in round 3. It must not
  # reappear in the implementation by accident.
  def test_inv_am_11_stayed_withdrawn_with_multi_currency
    lib = Dir[File.expand_path('../lib/**/*.rb', __dir__)].map { |f| File.read(f) }.join
    refute_match(/INV-AM-11/, lib)
    refute_match(/exchange_rate|convert_currency/, lib)
  end
end
