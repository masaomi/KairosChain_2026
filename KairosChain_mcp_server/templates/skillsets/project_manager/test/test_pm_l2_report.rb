# frozen_string_literal: true

# Tests for scripts/pm_l2_report.rb.
#
# Every case exists because a reviewer demonstrated the defect it pins. The bar
# is not that a case is red against some earlier version -- it is that **breaking
# the guard by one line makes this suite red**. An audit of the Python original
# applied 65 one-line mutations and 36 survived, so the cases that survived
# mutation were rewritten rather than added to. Four habits came out of that
# audit and are followed here:
#
#   1. Guards are exercised through `main`, not only as functions. Two mutations
#      to `main` -- deleting the output-path guard's call, and shortening its
#      protected list -- left the old suite green, because nothing ran `main`.
#   2. A fixture must not be able to satisfy the assertion on its own. The old
#      impossible-date case built two documents, the second matching the same
#      term, so the valid date sorted last and the impossible one never reached
#      the parse point; the pre-fix call site stayed green.
#   3. Aggregation is tested with several items. Every case in the old suite
#      built at most one row, so counting every row as matched, taking the median
#      over all deltas, and reversing the sort order were all green.
#   4. Messages and exit codes are asserted by content, not by "non-zero" or "the
#      prefix is present". Emptying a diagnostic and changing an exit code to 137
#      were both green.
#
# The context store is synthetic; the derivation is the real `L2Scan` module, so
# `match` is driven rather than reimplemented.
#
# Run from the skillset root:
#   ruby test/test_pm_l2_report.rb

require 'minitest/autorun'
require 'date'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

SKILLSET = File.dirname(__dir__)
SCRIPTS = File.join(SKILLSET, 'scripts')

require_relative '../scripts/l2_scan'
require_relative '../scripts/pm_l2_report'

NOW = Date.new(2026, 8, 17)

module Fixtures
  # One indexed context, in the shape L2Scan.load_l2 produces.
  #
  # digest defaults to name+path, not name: two contexts sharing a name with
  # different content are two records, and a name-keyed digest collapsed them.
  def doc(name, dates, status: '', tags: '', path: nil, digest: nil)
    rel = path || ".kairos/context/s/#{name}.md"
    { 'name' => name, 'path' => rel, 'dates' => dates.dup, 'status' => status,
      'handle' => "#{name} #{rel} #{tags}".downcase, 'digest' => digest || "#{name}|#{rel}" }
  end

  def item(num = 1, **overrides)
    base = { 'id' => "itm_#{num}", 'project_id' => 'prj_1', 'title' => "t#{num}",
             'status' => 'open', 'deps' => [], 'salience' => 'normal',
             'touched_at' => '2026-08-01T00:00:00Z' }
    overrides.each { |k, v| base[k.to_s] = v }
    base
  end

  def store_of(*items)
    { 'projects' => { 'prj_1' => { 'id' => 'prj_1', 'name' => 'P' } },
      'items' => items.to_h { |i| [i['id'], i] } }
  end

  def rows_for(mapping, store, docs, now = NOW) = PmL2Report.build_rows(mapping, store, docs, now)
end

# A throwaway data directory laid out the way the script expects.
#
# The script derives every path from its own location, so a copy under a
# directory of any name is a complete instance. Used to drive main in a
# subprocess, which is the only way the wiring gets exercised.
class Instance
  attr_reader :root, :data, :scripts

  def initialize(tmp, data_dir_name: '.kairos')
    @root = tmp
    @data = File.join(tmp, data_dir_name)
    @scripts = File.join(@data, 'skillsets', 'project_manager', 'scripts')
    FileUtils.mkdir_p(@scripts)
    FileUtils.mkdir_p(File.join(@data, 'context', 's'))
    %w[l2_scan.rb pm_l2_report.rb].each { |f| FileUtils.cp(File.join(SCRIPTS, f), @scripts) }
  end

  def pm(store = nil, mapping = nil)
    FileUtils.mkdir_p(File.join(@data, 'pm'))
    write_json(File.join(@data, 'pm', 'store.json'), store) unless store.nil?
    write_json(File.join(@data, 'pm', 'l2_mapping.json'), mapping) unless mapping.nil?
  end

  def context(name, body)
    File.write(File.join(@data, 'context', 's', "#{name}.md"), body)
  end

  def write_json(path, value)
    File.write(path, value.is_a?(String) ? value : JSON.generate(value))
  end

  def run(*args)
    Open3.capture3(RbConfig.ruby, File.join(@scripts, 'pm_l2_report.rb'), *args)
  end

  def out_path = File.join(@data, 'log', 'pm_l2_report.html')
end

def with_instance(data_dir_name: '.kairos')
  Dir.mktmpdir { |tmp| yield Instance.new(tmp, data_dir_name: data_dir_name) }
end

# There is no output-path argument. Comparing paths failed three ways -- a
# case-only difference, a hardlink, and any read input the check did not know
# about -- so the argument was deleted instead of guarded a fourth time.
class TheProgramCannotBeAimedAtAnInput < Minitest::Test
  include Fixtures

  # Two DIFFERENT branches refuse this, and an earlier version of the case could
  # not tell them apart. `-o` is not an unknown option: OptionParser resolves it
  # as an abbreviation of `--open`, so it is the leftover `memo` argument that is
  # refused, by the `argv.empty?` check. Both branches emit the same phrase, so
  # asserting the phrase alone left the ParseError arm — and its exit code —
  # entirely free.
  def test_no_argument_can_set_the_output_path
    with_instance do |inst|
      inst.pm(store_of(item), { 'version' => 1, 'items' => {} })
      memo = File.join(inst.data, 'pm', 'store.json')
      _out, err, status = inst.run('-o', memo)
      assert_equal 2, status.exitstatus, '-o was accepted'
      assert_includes err, 'unrecognized arguments'
      assert_includes err, File.basename(memo), 'the leftover argument was not named'
      JSON.parse(File.read(memo)) # still valid JSON
      refute_path_exists inst.out_path
    end
  end

  # The other branch: a genuinely unknown option, refused by OptionParser itself.
  def test_an_unknown_option_is_refused_by_name
    with_instance do |inst|
      inst.pm(store_of(item), { 'version' => 1, 'items' => {} })
      _out, err, status = inst.run('--outfile', '/tmp/nowhere.html')
      assert_equal 2, status.exitstatus
      assert_includes err, 'invalid option'
      refute_path_exists inst.out_path
    end
  end

  def test_the_memo_is_byte_identical_across_a_successful_run
    with_instance do |inst|
      inst.pm(store_of(item(title: 'named_ctx_alpha の件')), { 'version' => 1, 'items' => {} })
      inst.context('named_ctx_alpha', "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
      memo = File.join(inst.data, 'pm', 'store.json')
      before = File.binread(memo)
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      assert_equal before, File.binread(memo)
    end
  end

  def test_the_page_goes_beside_the_data_dir_it_was_run_from
    with_instance do |inst|
      inst.pm(store_of(item), { 'version' => 1, 'items' => {} })
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      assert_path_exists inst.out_path, out
      assert_includes out, inst.out_path
    end
  end

  # The derivation appended a literal .kairos, so a relocated instance reported
  # itself empty at exit 0 on every session.
  def test_a_relocated_data_dir_is_found_whatever_it_is_called
    with_instance(data_dir_name: 'kairosdata') do |inst|
      inst.pm(store_of(item(title: 'named_ctx_alpha の件')), { 'version' => 1, 'items' => {} })
      inst.context('named_ctx_alpha', "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      refute_includes out, '見つかりません'
      assert_includes out, 'memo 1 項目'
      assert_path_exists inst.out_path
    end
  end

  # Dir.glob reads its whole argument as a pattern. Building the pattern from the
  # absolute data dir made every ancestor directory name pattern too, so a data
  # dir under Kairos{2026} or projects[old] matched nothing and the scan reported
  # zero contexts at exit 0 — the same silence the path derivation was rewritten
  # to remove, arriving through the other door. Python's glob expands neither.
  def test_a_data_dir_whose_name_contains_glob_metacharacters_is_still_read
    ['kdata{2026}', 'kdata[old]'].each do |name|
      with_instance(data_dir_name: name) do |inst|
        inst.pm(store_of(item(title: 'named_ctx_alpha の件')), { 'version' => 1, 'items' => {} })
        inst.context('named_ctx_alpha', "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
        out, err, status = inst.run
        assert_equal 0, status.exitstatus, out + err
        assert_includes out, '自動照合 1', "#{name}: the context was not indexed"
        assert_includes File.read(inst.out_path), '1 件の近傍記録'
      end
    end
  end

  # Ruby's __dir__ resolves symlinks; Python's os.path.abspath(__file__) does
  # not. Symlinking the SkillSet into the distribution tree — the obvious way to
  # edit without re-copying — made the derivation land in the REAL tree, so the
  # page was written inside a git-tracked directory that ships in the gem.
  def test_the_data_dir_is_the_one_the_symlink_was_reached_through
    with_instance do |inst|
      inst.pm(store_of(item(title: 'named_ctx_alpha の件')), { 'version' => 1, 'items' => {} })
      inst.context('named_ctx_alpha', "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
      # A second data dir whose skillset directory is a link to the first one's.
      linked = File.join(inst.root, 'linked')
      FileUtils.mkdir_p(File.join(linked, 'skillsets'))
      FileUtils.cp_r(File.join(inst.data, 'context'), File.join(linked, 'context'))
      FileUtils.cp_r(File.join(inst.data, 'pm'), File.join(linked, 'pm'))
      File.symlink(File.join(inst.data, 'skillsets', 'project_manager'),
                   File.join(linked, 'skillsets', 'project_manager'))
      out, err, status = Open3.capture3(
        RbConfig.ruby,
        File.join(linked, 'skillsets', 'project_manager', 'scripts', 'pm_l2_report.rb'), '--quiet'
      )
      assert_equal 0, status.exitstatus, out + err
      assert_path_exists File.join(linked, 'log', 'pm_l2_report.html')
      refute_path_exists inst.out_path, 'the page landed in the real tree, not the linked one'

      # l2_scan.rb derives its own, and only its CLI uses it — so the case above,
      # which drives pm_l2_report.rb, leaves that derivation untested. The two
      # trees must also DIFFER, or reading the wrong one gives the right answer:
      # the linked side gets a second context the real side does not have.
      File.write(File.join(linked, 'context', 's', 'only_linked.md'),
                 "---\nname: only_linked_ctx\ndate: 2026-08-11\n---\nb\n")
      inst.write_json(File.join(linked, 'pm', 'l2_mapping.json'),
                      { 'version' => 1, 'items' => { 'itm_1' => { 'include' => ['named_ctx_alpha'] } } })
      scan_out, scan_err, scan_status = Open3.capture3(
        RbConfig.ruby,
        File.join(linked, 'skillsets', 'project_manager', 'scripts', 'l2_scan.rb')
      )
      assert_equal 0, scan_status.exitstatus, scan_out + scan_err
      assert_includes scan_out, 'indexed 2 contexts',
                      'the scan read the real tree, not the one the symlink was reached through'
    end
  end
end

# pm_item writes due and touched_at through with no check beyond a JSON type, and
# this SkillSet's own Ruby suite writes the integer 20260701 to both.
class StoredValuesHaveNoGuaranteedType < Minitest::Test
  include Fixtures

  def test_date_prefix_of_a_non_string_is_empty
    [20_260_701, nil, { 'a' => 1 }, [1], 3.5, true].each do |value|
      assert_equal '', PmL2Report.date_prefix(value), value.inspect
    end
    assert_equal '2026-08-01', PmL2Report.date_prefix('2026-08-01T00:00:00Z')
  end

  def test_a_row_builds_when_touched_at_and_due_are_integers
    rows = rows_for({ 'items' => {} },
                    store_of(item(touched_at: 20_260_701, due: 20_260_701)),
                    [doc('alpha_beta_thing', ['2026-08-10'])])
    assert_equal '', rows[0]['store_touched']
    assert_equal '', rows[0]['due']
  end

  def test_the_whole_program_survives_an_integer_marker
    with_instance do |inst|
      inst.pm(store_of(item(touched_at: 20_260_701)), { 'version' => 1, 'items' => {} })
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      assert_empty err.strip
    end
  end

  def test_a_non_string_title_is_coerced
    rows = rows_for({ 'items' => {} }, store_of(item(title: 42, notes: nil)),
                    [doc('x_y_z_w', ['2026-08-10'])])
    assert_equal '42', rows[0]['title']
  end

  def test_a_non_object_projects_or_items_value_does_not_raise
    [[{ 'id' => 'x' }], 'string', 42, nil].each do |bad|
      rows = rows_for({ 'items' => {} },
                      { 'projects' => bad, 'items' => { 'itm_1' => item } },
                      [doc('x_y_z_w', ['2026-08-10'])])
      assert_equal '—', rows[0]['project'], bad.inspect
      assert_empty rows_for({ 'items' => {} }, { 'projects' => {}, 'items' => bad },
                            [doc('x_y_z_w', ['2026-08-10'])])
    end
  end

  # Content, not length. The earlier version built three deps none of which
  # carried `resolved`, so the filter's second half was constant-true across the
  # fixture and deleting it kept the suite green.
  def test_a_dependency_missing_kind_or_ref_does_not_raise
    rows = rows_for({ 'items' => {} },
                    store_of(item(deps: [{ 'ref' => 'x' }, { 'kind' => 'item' }, 'junk'])),
                    [doc('x_y_z_w', ['2026-08-10'])])
    assert_equal [':x', 'item:'], rows[0]['blocked_on']
  end

  # Python's `not d.get("resolved")`: 0 and "" are unresolved there and true in
  # Ruby, so a dep stored as `"resolved": 0` lost its chip while Python still
  # called it blocking.
  def test_python_falsy_resolved_values_are_still_blocking
    deps = [nil, false, 0, '', [], {}].each_with_index.map { |v, i| { 'kind' => 'k', 'ref' => "f#{i}", 'resolved' => v } }
    deps += [{ 'kind' => 'k', 'ref' => 'done', 'resolved' => true },
             { 'kind' => 'k', 'ref' => 'also', 'resolved' => 'yes' }]
    rows = rows_for({ 'items' => {} }, store_of(item(deps: deps)),
                    [doc('x_y_z_w', ['2026-08-10'])])
    assert_equal %w[k:f0 k:f1 k:f2 k:f3 k:f4 k:f5], rows[0]['blocked_on']
  end
end

# L2Scan validates that a declared date looks like a date, never that it exists,
# and the path fallback formats any 20nnnnnn run into a dashed date.
class ADateIsParsedInOnePlace < Minitest::Test
  include Fixtures

  def test_as_date_rejects_shape_valid_impossible_dates
    ['2026-02-30', '2026-13-45', '2026-00-01', nil, 42, '', 'not-a-date'].each do |bad|
      assert_nil PmL2Report.as_date(bad), bad.inspect
    end
    assert_equal NOW, PmL2Report.as_date('2026-08-17')
  end

  # Ruby's Date.iso8601 accepts shapes the Python fromisoformat this was ported
  # from rejects. Neither is written by the derivation, so both stay refused.
  def test_as_date_refuses_shapes_the_derivation_never_writes
    assert_nil PmL2Report.as_date('20260701')
    assert_nil PmL2Report.as_date('2026-W01-1')
  end

  # Python's datetime.date has no year zero — date(0, 1, 1) raises, and the
  # original counted such a context under "L2 の日付が読めない". Ruby's Date
  # accepts it, so the row instead reported a lag of roughly 739,000 days at
  # exit 0. Year 1 is the first Python accepts and stays accepted here.
  def test_as_date_refuses_year_zero_the_way_pythons_date_does
    assert_nil PmL2Report.as_date('0000-01-01')
    assert_nil PmL2Report.as_date('0000-12-31')
    assert_equal Date.new(1, 1, 1, Date::GREGORIAN), PmL2Report.as_date('0001-01-01')
  end

  # A DateTime satisfies is_a?(Date); returning one unchanged let the
  # subtraction in days_between yield a Rational rather than whole days.
  def test_as_date_narrows_a_time_to_a_date
    [Time.new(2026, 8, 17, 12, 30, 0), DateTime.new(2026, 8, 17, 12, 30, 0)].each do |value|
      got = PmL2Report.as_date(value)
      assert_equal NOW, got
      assert_instance_of Date, got
    end
    assert_equal 16, PmL2Report.days_between('2026-08-01', Time.new(2026, 8, 17, 12, 0, 0))
  end

  def test_days_between_guards_both_ends
    assert_nil PmL2Report.days_between('2026-02-30', NOW)
    assert_nil PmL2Report.days_between('2026-08-01', '2026-02-30')
    assert_equal 16, PmL2Report.days_between('2026-08-01', NOW)
  end

  # One document only, so the impossible date IS the latest and does reach the
  # parse point. The two-document version of this case was green against the
  # pre-fix code.
  def test_a_single_impossible_context_date_does_not_stop_the_program
    with_instance do |inst|
      inst.pm(store_of(item(title: 'bad_date_ctx の件')),
              { 'version' => 1, 'items' => { 'itm_1' => { 'include' => ['bad_date_ctx'] } } })
      inst.context('bad_date_ctx', "---\nname: bad_date_ctx\ndate: 2026-02-30\n---\nb\n")
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      assert_empty err.strip
      assert_includes File.read(inst.out_path), 'L2 の最新日付が読めない'
    end
  end
end

# Three separate holes were closed here: bare words, an uncapped document-name
# tier, and a capped-per-term but uncapped row.
class InferenceCannotFloodAndSaysWhenItRefuses < Minitest::Test
  include Fixtures

  def setup
    # 40 handles containing "review", one document named exactly "review".
    @docs = Array.new(40) { |n| doc("review_thread_#{n}", ['2026-08-01']) }
    @docs << doc('review', ['2026-08-02'])
    @names = @docs.map { |d| d['name'].downcase }.to_h { |n| [n, true] }
    @cache = {}
  end

  def reach = ->(t) { @cache[t] ||= @docs.count { |d| d['handle'].include?(t) } }

  def reach_over(docs) = ->(t) { docs.count { |d| d['handle'].include?(t) } }

  def names_of(docs) = docs.map { |d| d['name'].downcase }.to_h { |n| [n, true] }

  def test_a_document_name_over_the_cap_is_refused
    terms = PmL2Report.infer_terms(@names, reach, item(title: 'the review of things'))
    refute_includes terms, 'review', "'review' reaches #{reach.call('review')} documents"
  end

  def test_a_narrow_document_name_is_accepted
    docs = @docs + [doc('pm_store_write_guard', ['2026-08-03'])]
    terms = PmL2Report.infer_terms(names_of(docs), reach_over(docs),
                                   item(title: 'pm_store_write_guard の修正'))
    assert_includes terms, 'pm_store_write_guard'
  end

  # The lower bound, which the cap cases never reach. A compound the store has
  # never heard of would otherwise be accepted, and the row would then print
  # "no term could be built" directly above the list of terms it built.
  def test_a_term_that_reaches_nothing_is_not_a_term
    docs = [doc('one_ctx_only', ['2026-08-01'])]
    assert_empty PmL2Report.infer_terms(names_of(docs), reach_over(docs),
                                        item(title: 'pm_write_read_guard を直す'))
    row = rows_for({ 'items' => {} },
                   store_of(item(title: 'pm_write_read_guard を直す')), docs)[0]
    assert_equal 'none', row['term_source']
    assert_empty row['terms']['include'], 'the row lists a term while saying none could be built'
  end

  def test_a_bare_english_word_is_refused_even_when_narrow
    docs = [doc('one_ctx_only', ['2026-08-01'], tags: 'store')]
    assert_empty PmL2Report.infer_terms(names_of(docs), reach_over(docs), item(title: 'store の話'))
  end

  # Each term reaches at most 3 documents; their union is 30. The row cap is what
  # stops this -- per-term caps did not.
  def test_many_terms_each_under_the_cap_do_not_flood_the_row
    docs = (0...10).flat_map { |g| Array.new(3) { |n| doc("topic_#{g}_thread_#{n}", ['2026-08-01']) } }
    title = (0...10).map { |g| "topic_#{g}_thread_0" }.join(' ')
    store = store_of(item(title: title, notes: (0...10).map { |g| "topic_#{g}" }.join(' ')))
    row = rows_for({ 'items' => {} }, store, docs)[0]
    assert_equal 'too_broad', row['term_source'], "#{row['records'].length} records slipped through"
    assert_empty row['records']
    assert_operator row['inferred_hits'], :>, PmL2Report::REACH_CAP
    assert_includes PmL2Report.unmatched_reason(row), '自動照合の語が広すぎる'
    assert_equal 1, PmL2Report.summary([row])['too_broad']
  end

  # A term repeated in the title must appear once. The list is shown to the
  # operator on the row, and a duplicated term reads as two pieces of evidence.
  def test_a_term_repeated_in_the_item_text_is_returned_once
    docs = [doc('topic_a_thread_0', ['2026-08-01'])]
    terms = PmL2Report.infer_terms(names_of(docs), reach_over(docs),
                                   item(title: 'topic_a_thread_0 と topic_a_thread_0',
                                        notes: 'topic_a_thread_0'))
    assert_equal ['topic_a_thread_0'], terms
  end

  def test_a_row_just_inside_the_cap_is_still_reported
    docs = Array.new(PmL2Report::REACH_CAP) { |n| doc("topic_a_thread_#{n}", ['2026-08-01']) }
    rows = rows_for({ 'items' => {} },
                    store_of(item(title: 'topic_a_thread_0 の件', notes: 'topic_a')), docs)
    assert_equal 'inferred', rows[0]['term_source']
    assert_equal PmL2Report::REACH_CAP, rows[0]['records'].length
  end

  # The cap is on inference. The operator's own terms are their judgment.
  def test_an_authored_mapping_is_not_capped
    docs = Array.new(PmL2Report::REACH_CAP + 12) { |n| doc("authored_thread_#{n}", ['2026-08-01']) }
    rows = rows_for({ 'items' => { 'itm_1' => { 'include' => ['authored_thread'] } } },
                    store_of(item), docs)
    assert_equal 'authored', rows[0]['term_source']
    assert_equal PmL2Report::REACH_CAP + 12, rows[0]['records'].length
  end
end

# Carrying it into inference was itself an earlier fix, and it traded one wrong
# answer for another: an exclude term is a substring of document names, and an
# inferred term is usually the item's own record name.
class TheAuthoredExcludeStopsAtTheAuthoredTerms < Minitest::Test
  include Fixtures

  def test_the_exclude_is_not_applied_to_inferred_terms
    docs = [doc('guard_track_inv8_thing', ['2026-08-02'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['no_such_term'], 'exclude' => ['inv8'] } } }
    row = rows_for(mapping, store_of(item(title: 'guard_track_inv8_thing を直す')), docs)[0]
    assert_equal 'inferred', row['term_source']
    assert_empty row['terms']['exclude']
    assert_equal ['guard_track_inv8_thing'], row['records'].map { |d| d['name'] },
                 "the item's own record was suppressed by a carried exclude"
  end

  def test_the_exclude_still_applies_to_the_authored_terms
    docs = [doc('guard_track_slice_one', ['2026-08-01']), doc('guard_track_inv8_thing', ['2026-08-02'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['guard_track'], 'exclude' => ['inv8'] } } }
    row = rows_for(mapping, store_of(item), docs)[0]
    assert_equal 'authored', row['term_source']
    assert_equal ['guard_track_slice_one'], row['records'].map { |d| d['name'] }
    assert_equal ['inv8'], row['terms']['exclude']
  end

  def test_the_page_states_that_the_exclude_was_not_carried
    docs = [doc('guard_track_inv8_thing', ['2026-08-02'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['no_such_term'], 'exclude' => ['inv8'] } } }
    row = rows_for(mapping, store_of(item(title: 'guard_track_inv8_thing を直す')), docs)[0]
    assert_includes PmL2Report.render_terms(row), '自動照合には適用しません'
  end
end

class TheMappingsShapeIsNotTrusted < Minitest::Test
  include Fixtures

  def test_a_string_include_does_not_become_terms
    assert_empty PmL2Report.term_list('pm_store')
    assert_equal %w[a b], PmL2Report.term_list(['a', 3, nil, 'b', ''])
    assert_empty PmL2Report.term_list(nil)
  end

  def test_a_string_include_does_not_reach_the_page_as_authored
    docs = Array.new(30) { |n| doc("unrelated_#{n}", ['2026-08-01']) }
    rows = rows_for({ 'items' => { 'itm_1' => { 'include' => 'unrelated' } } },
                    store_of(item(title: '日本語のみ')), docs)
    refute_equal 'authored', rows[0]['term_source']
    assert_empty rows[0]['records']
  end

  def test_a_mapping_with_no_items_key_still_builds_rows
    rows = rows_for({ 'version' => 1 }, store_of(item), [doc('some_named_ctx', ['2026-08-10'])])
    assert_equal 1, rows.length
  end

  def test_a_non_object_mapping_items_value_still_builds_rows
    rows = rows_for({ 'items' => 'oops' }, store_of(item), [doc('some_named_ctx', ['2026-08-10'])])
    assert_equal 1, rows.length
  end
end

# Which side is broken is the whole content of this line. Collapsing any two of
# these produced a false statement twice.
class FiveReasonsAreWordedApart < Minitest::Test
  include Fixtures

  def row_for(docs, mapping, **item_kw) = rows_for(mapping, store_of(item(**item_kw)), docs)[0]

  def test_an_unreadable_memo_marker_blames_the_memo
    row = row_for([doc('named_ctx_alpha', ['2026-08-07'])],
                  { 'items' => { 'itm_1' => { 'include' => ['named_ctx_alpha'] } } },
                  touched_at: nil)
    assert_equal '2026-08-07', row['last_activity']
    assert row['latest_parses']
    refute row['marker_parses']
    assert_includes PmL2Report.unmatched_reason(row), '直すのは memo の側'
  end

  def test_an_unreadable_l2_date_blames_l2
    row = row_for([doc('named_ctx_beta', ['2026-02-30'])],
                  { 'items' => { 'itm_1' => { 'include' => ['named_ctx_beta'] } } })
    assert_equal '2026-08-01', row['store_touched']
    assert row['marker_parses']
    refute row['latest_parses']
    reason = PmL2Report.unmatched_reason(row)
    assert_includes reason, '直すのは L2 の側'
    refute_includes reason, 'memo 側の最終接触'
  end

  def test_undated_records_are_reported_as_such
    row = row_for([doc('named_ctx_gamma', [])],
                  { 'items' => { 'itm_1' => { 'include' => ['named_ctx_gamma'] } } })
    assert_includes PmL2Report.unmatched_reason(row), 'どれも日付を持たない'
  end

  def test_no_terms_is_reported_as_such
    row = row_for([doc('unrelated_ctx', ['2026-08-01'])], { 'items' => {} },
                  title: '日本語のみ', notes: nil)
    assert_equal 'none', row['term_source']
    assert_includes PmL2Report.unmatched_reason(row), '照合語が 1 つも作れない'
  end

  # Item 5 is broken on BOTH sides. It must be counted once, under L2, since that
  # is the side the reason names -- otherwise the memo tile absorbs rows whose
  # memo is not the problem.
  def test_the_five_counters_do_not_overlap
    docs = [doc('ctx_marker_bad', ['2026-08-07']), doc('ctx_l2_bad', ['2026-02-30']),
            doc('ctx_undated', []), doc('ctx_ok', ['2026-08-10']),
            doc('ctx_both_bad', ['2026-02-30'])]
    mapping = { 'items' => {
      'itm_1' => { 'include' => ['ctx_marker_bad'] }, 'itm_2' => { 'include' => ['ctx_l2_bad'] },
      'itm_3' => { 'include' => ['ctx_undated'] }, 'itm_4' => { 'include' => ['ctx_ok'] },
      'itm_5' => { 'include' => ['ctx_both_bad'] }
    } }
    store = store_of(item(1, touched_at: nil), item(2), item(3), item(4),
                     item(5, touched_at: nil), item(6, title: '日本語のみ'))
    rows = rows_for(mapping, store, docs)
    s = PmL2Report.summary(rows)
    assert_equal [1, 1, 2, 1, 6],
                 [s['matched'], s['no_marker'], s['bad_l2_date'], s['no_terms'], s['items']]
    both = rows.find { |r| r['id'] == 'itm_5' }
    assert_includes PmL2Report.unmatched_reason(both), '直すのは L2 の側'
  end

  def test_a_non_object_item_value_is_skipped_rather_than_read
    rows = rows_for({ 'items' => {} },
                    { 'projects' => {}, 'items' => { 'itm_1' => 'junk', 'itm_2' => item(2) } },
                    [doc('x_y_z_w', ['2026-08-10'])])
    assert_equal ['itm_2'], rows.map { |r| r['id'] }
  end
end

# Every case in the previous suite built one row, so counting all rows as
# matched, taking the median over all deltas, and reversing the order were green.
class AggregationIsComputedOverEveryRow < Minitest::Test
  include Fixtures

  def built_rows
    docs = [doc('ctx_lag_big', ['2026-08-15']), doc('ctx_lag_small', ['2026-08-03']),
            doc('ctx_in_step', ['2026-08-01']), doc('ctx_memo_ahead', ['2026-07-01']),
            doc('ctx_none_marker', ['2026-08-07'])]
    terms = %w[ctx_lag_big ctx_lag_small ctx_in_step ctx_memo_ahead ctx_none_marker]
    mapping = { 'items' => terms.each_with_index.to_h { |t, i| ["itm_#{i + 1}", { 'include' => [t] }] } }
    store = store_of(item(1), item(2), item(3), item(4), item(5, touched_at: nil))
    rows_for(mapping, store, docs)
  end

  def page_of(rows)
    PmL2Report.render({ 'rows' => rows, 'docs' => 5, 'undated' => 0, 'mapping_version' => 1,
                        'store_path' => '/x/store.json' }, Time.new(2026, 8, 17, 12, 0, 0))
  end

  def test_the_counters_split_lagging_in_step_and_memo_ahead
    s = PmL2Report.summary(built_rows)
    assert_equal [5, 4, 2, 1, 1, 1],
                 [s['items'], s['matched'], s['l2_newer'], s['in_step'], s['memo_newer'], s['no_marker']]
  end

  # Lags are 14 and 2, so the median over lagging items is 8. The median over all
  # four deltas would be 1, which is smaller than either lagging item.
  def test_the_median_is_taken_over_lagging_items_only
    s = PmL2Report.summary(built_rows)
    assert_equal 8, s['median_lag']
    assert_equal 14, s['max_lag']
  end

  # Defined once, in L2Scan, and reached from both files — it used to exist twice
  # with only one copy tested. built_rows yields two lagging items, so only the
  # even arm ever runs there; forced onto the even formula, three lags of 2, 9
  # and 14 report 5.5 — below every lagging item — on the tile and in the hook's
  # first line.
  def test_the_median_of_an_odd_number_of_lags_is_the_middle_one
    assert_equal 9, L2Scan.median([2, 9, 14])
    assert_equal 8, L2Scan.median([2, 14])
    assert_nil L2Scan.median([])
    # …and the report side reaches that one definition, not a copy of its own.
    assert_equal 9, PmL2Report.summary([{ 'touch_delta_days' => 2 }, { 'touch_delta_days' => 9 },
                                        { 'touch_delta_days' => 14 }])['median_lag']
  end

  # Eleven tiles carry the page's headline numbers, and four of those counters
  # appear nowhere else on it. Swapping a value under its label is otherwise
  # invisible: every other assertion routes AROUND the tiles, because the tile
  # labels collide with the table labels.
  def test_each_tile_carries_its_own_counter
    tiles = page_of(built_rows).scan(%r{<div class="tile"><b>(.*?)</b><span>(.*?)</span>})
    assert_equal ['差を出せた項目', 'L2 のほうが新しい', 'ずれの中央値', 'ずれの最大',
                  '一致している', 'memo のほうが新しい', '自動照合で拾った項目',
                  '自動照合の語が広すぎた', 'L2 の最新日付が読めない',
                  'memo の最終接触が読めない', '照合語が作れない'], tiles.map(&:last)
    s = PmL2Report.summary(built_rows)
    assert_equal ["#{s['matched']}/#{s['items']}", s['l2_newer'].to_s, '8日', '14日',
                  s['in_step'].to_s, s['memo_newer'].to_s, s['inferred'].to_s,
                  s['too_broad'].to_s, s['bad_l2_date'].to_s, s['no_marker'].to_s,
                  s['no_terms'].to_s], tiles.map(&:first)
  end

  # Pairing a value with its label proves nothing where two tiles show the SAME
  # value. built_rows renders three 1s and four 0s, so seven of the eleven could
  # be permuted invisibly — and the colliding counters are exactly the ones the
  # operator reads to decide whether the memo or L2 needs repair. This fixture
  # gives every tile a different number.
  def test_no_two_tiles_can_be_swapped_because_no_two_share_a_value
    rows = tile_fixture_rows
    tiles = page_of(rows).scan(%r{<div class="tile"><b>(.*?)</b><span>(.*?)</span>})
    assert_equal tiles.map(&:first).uniq.length, tiles.length,
                 "two tiles share a value: #{tiles.map(&:first).inspect}"
    assert_equal ['12/44', '5', '3日', '5日', '4', '3', '6', '2', '8', '9', '7'],
                 tiles.map(&:first)
  end

  # Rows built by hand rather than through build_rows: the eleven counters
  # overlap by construction there (an inferred row is also a lagging row), and
  # only disjoint groups can give eleven distinct numbers.
  def tile_fixture_rows
    matched = lambda do |delta, n|
      Array.new(n) do |i|
        tile_row(id: "m#{delta}_#{i}", 'touch_delta_days' => delta,
                 'first_activity' => '2026-08-01', 'last_activity' => '2026-08-10',
                 'active_days' => 1, 'latest_nearby_record' => 'r',
                 'records' => [doc('r', ['2026-08-10'])])
      end
    end
    unmatched = lambda do |n, over|
      Array.new(n) { |i| tile_row(**over.merge(id: "u#{over[:term_source]}#{over[:latest_parses]}#{over[:marker_parses]}_#{i}")) }
    end
    (1..5).flat_map { |d| matched.call(d, 1) } +           # l2_newer 5, median 3, max 5
      matched.call(0, 4) +                                  # in_step 4
      matched.call(-1, 3) +                                 # memo_newer 3
      unmatched.call(6, term_source: 'inferred', 'records' => [doc('u', [])]) +
      unmatched.call(2, term_source: 'too_broad', 'inferred_hits' => 99) +
      unmatched.call(7, term_source: 'none') +
      unmatched.call(8, 'last_activity' => '2026-02-30', 'latest_parses' => false,
                        'records' => [doc('b', ['2026-02-30'])]) +
      unmatched.call(9, 'last_activity' => '2026-08-10', 'marker_parses' => false,
                        'records' => [doc('c', ['2026-08-10'])])
  end

  def tile_row(**over)
    { 'id' => 'x', 'title' => 't', 'project' => 'P', 'store_status' => 'open',
      'salience' => 'normal', 'due' => '', 'blocked_on' => [], 'store_touched' => '2026-08-01',
      'memo_age_days' => 1, 'terms' => { 'include' => [], 'exclude' => [] },
      'term_source' => 'authored', 'records' => [], 'inferred_hits' => nil,
      'latest_parses' => true, 'marker_parses' => true }.merge(over.transform_keys(&:to_s))
  end

  def test_the_table_is_ordered_by_lag_descending
    page = page_of(built_rows)
    # Split on the headings, not the labels: the same words appear on the tiles.
    body = page.split('<h2>差を出せた項目')[1].split('<h2>差を出せなかった項目')[0]
    assert_operator body.index('+14日'), :<, body.index('+2日')
    assert_operator body.index('+2日'), :<, body.index('+0日')
  end

  # The report side re-derives these five fields itself rather than calling
  # L2Scan.derive, and every other fixture in the suite gives each item records
  # on ONE date — so `days.first` and `days.last` coincide and both are free.
  # `last_activity` also feeds unmatched_reason and two summary counters, so an
  # item whose earliest record is undatable would be reported as "fix the L2
  # side" when L2 is not the broken side.
  def test_a_row_spanning_several_days_reports_the_latest_and_counts_the_days
    docs = [doc('ctx_span_early', ['2026-08-03']), doc('ctx_span_late', ['2026-08-12'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['ctx_span'] } } }
    row = rows_for(mapping, store_of(item(1)), docs)[0]
    assert_equal ['2026-08-03', '2026-08-12', 2, 'ctx_span_late', 11],
                 [row['first_activity'], row['last_activity'], row['active_days'],
                  row['latest_nearby_record'], row['touch_delta_days']]
    assert_includes page_of([row]), 'ctx_span_late'
  end

  def test_an_in_step_item_stays_in_the_comparison_table
    rows = built_rows
    in_step = rows.find { |r| r['touch_delta_days']&.zero? }
    refute_nil in_step
    after = page_of(rows).split('差を出せなかった項目')[1]
    refute_includes after, in_step['title']
  end
end

class TheRenderedPageIsSafe < Minitest::Test
  include Fixtures

  def page_of(rows)
    PmL2Report.render({ 'rows' => rows, 'docs' => 1, 'undated' => 0, 'mapping_version' => 1,
                        'store_path' => '/x/store.json' }, Time.new(2026, 8, 17, 12, 0, 0))
  end

  def test_markup_is_escaped_in_the_comparison_table
    docs = [doc('named_ctx_alpha', ['2026-08-10'], status: '</span><b>PWNED</b>')]
    rows = rows_for({ 'items' => { 'itm_1' => { 'include' => ['named_ctx_alpha'] } } },
                    store_of(item(title: '</td></tr><script>alert(1)</script>')), docs)
    page = page_of(rows)
    refute_includes page, '<script>alert(1)</script>'
    refute_includes page, '<b>PWNED</b>'
    assert_includes page, '&lt;script&gt;'
  end

  def test_markup_is_escaped_in_the_no_comparison_table_too
    rows = rows_for({ 'items' => {} },
                    store_of(item(title: '<script>alert("unmatched")</script>')),
                    [doc('unrelated_ctx', ['2026-08-01'])])
    assert_nil rows[0]['touch_delta_days']
    page = page_of(rows)
    refute_includes page, '<script>alert("unmatched")</script>'
    assert_includes page, '&lt;script&gt;'
  end

  # Five chip kinds and nothing asserted any of them, so each predicate was free:
  # every fixture in the suite carries salience 'normal' and status 'open', which
  # is precisely the value each predicate excludes.
  def test_each_chip_appears_only_for_the_condition_it_names
    docs = [doc('named_ctx_alpha', ['2026-08-10'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['named_ctx_alpha'] } } }
    plain = rows_for(mapping, store_of(item(1)), docs)
    assert_empty page_of(plain).scan(%r{<span class="chip[^"]*">(.*?)</span>}).flatten,
                 'an open, normal, undated, unblocked item drew a chip'

    loud = rows_for(mapping, store_of(item(1, status: 'blocked', salience: 'high',
                                           due: '2026-09-06T00:00:00Z',
                                           deps: [{ 'kind' => 'item', 'ref' => 'itm_9' }])), docs)
    assert_equal ['blocked', 'high', '締切 2026-09-06', '待ち item:itm_9'],
                 page_of(loud).scan(%r{<span class="chip[^"]*">(.*?)</span>}).flatten
  end

  def test_a_records_own_status_appears_only_inside_a_details_block
    docs = [doc('named_ctx_alpha', ['2026-08-10'], status: 'FROZEN')]
    rows = rows_for({ 'items' => { 'itm_1' => { 'include' => ['named_ctx_alpha'] } } },
                    store_of(item), docs)
    page = page_of(rows)
    assert_includes page, 'FROZEN'
    refute_includes page.gsub(/<details>.*?<\/details>/m, ''), 'FROZEN'
  end

  def test_terms_are_shown_as_text_even_when_nothing_matched
    rows = rows_for({ 'items' => {} }, store_of(item(title: '日本語のみ')),
                    [doc('unrelated_ctx', ['2026-08-01'])])
    page = page_of(rows)
    assert_includes page, '照合語'
    # An array inspect would reach the page as [&quot;term&quot;, ...].
    refute_includes page, '[&quot;'
    # The origin label, which says whose terms these are. Emptying it lets a row
    # claim the operator's own mapping produced terms that were inferred.
    assert_includes page, '題名と備考から自動で抽出'
    # The empty-marker cell, which only renders when the memo has no readable
    # last-touch at all.
    no_marker = rows_for({ 'items' => {} }, store_of(item(title: '日本語のみ', touched_at: nil)),
                         [doc('unrelated_ctx', ['2026-08-01'])])
    assert_includes page_of(no_marker), '（無し）'
  end

  # Three render diagnostics that no assertion reached: the placeholder row shown
  # when every item got a comparison, the empty-marker cell, and the term-origin
  # label. Each can be emptied without the suite noticing.
  def test_the_placeholder_and_origin_labels_are_not_free
    docs = [doc('named_ctx_alpha', ['2026-08-10'])]
    rows = rows_for({ 'items' => { 'itm_1' => { 'include' => ['named_ctx_alpha'] } } },
                    store_of(item(1)), docs)
    page = page_of(rows)
    assert_includes page, 'なし — 全項目で差が出せています。'
    assert_includes page, '手書きの対応表'
  end

  # Accepted behaviour, not a fixed defect. A context declaring 9999-12-31
  # parses, so its lag dwarfs the others and their bars go to zero width. The
  # bars are relative to the widest lag, which is what they say they are; the
  # wrong number is in L2, and the row still shows its own +N日 figure. Recorded
  # as accepted rather than given a scaling rule, which would be arbitrary.
  # A middle bar, not only the 100% and 0% ends. Integer division truncates in
  # Ruby, so without the float conversion 7 of 14 renders as 0% while the +7日
  # label beside it stays correct — the picture and the number disagree.
  def test_a_bar_between_the_ends_is_proportional
    docs = [doc('ctx_wide', ['2026-08-15']), doc('ctx_half', ['2026-08-08'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['ctx_wide'] },
                             'itm_2' => { 'include' => ['ctx_half'] } } }
    page = page_of(rows_for(mapping, store_of(item(1), item(2)), docs))
    assert_equal [100, 50], page.scan(/class="bar" style="width:(\d+)%/).flatten.map(&:to_i)
    assert_includes page, '+7日'
  end

  def test_one_absurd_lag_renders_without_error_and_flattens_the_rest
    docs = [doc('ctx_far', ['9999-12-31']), doc('ctx_near', ['2026-08-15'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['ctx_far'] },
                             'itm_2' => { 'include' => ['ctx_near'] } } }
    page = page_of(rows_for(mapping, store_of(item(1), item(2)), docs))
    assert_equal [100, 0], page.scan(/class="bar" style="width:(\d+)%/).flatten.map(&:to_i)
    assert_includes page, '+14日' # the figure itself is still readable
  end
end

class RunningTheProgramLeavesNothingBehind < Minitest::Test
  include Fixtures

  # The Python original pinned that no .pyc was written: such a file sits inside
  # Skillset#all_file_hashes and therefore inside content_hash, the value
  # recorded on chain. Ruby writes no bytecode, so the assertion is generalised
  # to what the guard was protecting -- the SkillSet's own contents.
  def test_a_run_adds_no_file_inside_the_skillset
    with_instance do |inst|
      inst.pm(store_of(item), { 'version' => 1, 'items' => {} })
      before = Dir.glob(File.join(inst.scripts, '**', '*'), File::FNM_DOTMATCH).sort
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      after = Dir.glob(File.join(inst.scripts, '**', '*'), File::FNM_DOTMATCH).sort
      assert_equal before, after, "the run left files inside the SkillSet: #{after - before}"
    end
  end
end

class AbsencesAreReportedNotRaised < Minitest::Test
  include Fixtures

  def test_a_fresh_instance_names_the_missing_file_and_exits_zero
    with_instance do |inst|
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      assert_includes out, 'store.json'
      assert_includes out, '見つかりません'
    end
  end

  def test_a_malformed_memo_names_the_file_and_exits_nonzero
    with_instance do |inst|
      inst.pm('{ not json', { 'version' => 1, 'items' => {} })
      out, err, status = inst.run('--quiet')
      assert_equal 1, status.exitstatus
      assert_includes out, 'store.json'
      assert_includes out, '読めません'
      assert_empty err.strip
    end
  end

  # File.read TAGS the encoding and never validates it, and JSON.parse accepts
  # what it tags, so the EncodingError in read_json's rescue cannot fire. Without
  # the explicit check the bad bytes either raise out of String#downcase or, when
  # the item has a mapping entry and inference never runs, reach the page: a file
  # declaring charset=utf-8 that is not valid UTF-8, written at exit 0 under a
  # success message. Python decoded at this boundary and reported in one line.
  # JSON::ParserError quotes the document it choked on, newlines and all, so a
  # trailing comma in a hand-edited store printed a four-line report from a hook
  # that promises one. Python named `line 7 column 5` and stayed on one line; the
  # line number is not recoverable from Ruby's message, so what is pinned here is
  # the shape. Both multi-line sources are covered: the parser here, and a
  # SyntaxError in the derivation — 43 lines, measured, under Ruby 2.6.
  def test_a_malformed_memo_is_reported_in_exactly_one_line
    with_instance do |inst|
      inst.pm(%({\n  "projects": {},\n  "items": {\n    "itm_1": {\n      "id": "itm_1",\n    }\n  }\n}),
              { 'version' => 1, 'items' => {} })
      out, err, status = inst.run('--quiet')
      assert_equal 1, status.exitstatus
      assert_equal 1, out.lines.length, out
      assert_empty err.strip
    end
  end

  def test_one_line_flattens_and_caps_whatever_a_library_hands_it
    got = PmL2Report.one_line((['x' * 40] * 10).join("\n"))
    assert_equal 1, got.lines.length
    assert_equal PmL2Report::ONE_LINE_CAP, got.length
    assert_equal 'a b', PmL2Report.one_line("  a\n\tb  ")
  end

  def test_a_memo_that_is_not_valid_utf8_is_reported_and_writes_nothing
    [{ 'version' => 1, 'items' => { 'itm_1' => { 'include' => %w[named_ctx_alpha] } } },
     { 'version' => 1, 'items' => {} }].each do |mapping|
      with_instance do |inst|
        inst.pm(nil, mapping)
        # A context the authored term matches, so `records` is non-empty and
        # inference is SKIPPED — the branch on which the bad bytes reach the page
        # instead of raising out of downcase. Without it both iterations of this
        # loop write no contexts, take the same path, and the second is decoration.
        if mapping['items'].any?
          inst.context('named_ctx_alpha', "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
        end
        bad = %({"projects":{},"items":{"itm_1":{"id":"itm_1","title":"caf\xE9",) +
              %("status":"open","deps":[],"salience":"normal","touched_at":"2026-08-01T00:00:00Z"}}})
        File.binwrite(File.join(inst.data, 'pm', 'store.json'), bad)
        out, err, status = inst.run('--quiet')
        assert_equal 1, status.exitstatus, out + err
        assert_includes out, 'UTF-8 として読めません'
        assert_empty err.strip
        refute_path_exists inst.out_path
      end
    end
  end

  def test_a_store_that_is_not_an_object_is_reported
    with_instance do |inst|
      inst.pm('[1, 2, 3]', { 'version' => 1, 'items' => {} })
      out, _err, status = inst.run('--quiet')
      assert_equal 1, status.exitstatus
      assert_includes out, 'object ではありません'
    end
  end

  def test_an_empty_store_says_so_and_exits_zero
    with_instance do |inst|
      inst.pm({ 'projects' => {}, 'items' => {} }, { 'version' => 1, 'items' => {} })
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      assert_includes out, '項目がまだありません'
    end
  end

  # The previous version of this case asserted a substring that the
  # mapping-absent notice prints regardless, so it passed with inference switched
  # off entirely. It now asserts the inferred record count.
  def test_a_missing_mapping_really_falls_back_to_inference
    with_instance do |inst|
      inst.pm(store_of(item(title: 'some_named_ctx の続き')))
      inst.context('some_named_ctx', "---\nname: some_named_ctx\ndate: 2026-08-10\n---\nb\n")
      out, err, status = inst.run # not --quiet: the count is on the second line
      assert_equal 0, status.exitstatus, out + err
      assert_includes out, '自動照合 1'
      page = File.read(inst.out_path)
      assert_includes page, 'some_named_ctx'
      assert_includes page, '1 件の近傍記録'
    end
  end

  def test_an_absent_derivation_is_reported_not_raised
    with_instance do |inst|
      inst.pm(store_of(item), { 'version' => 1, 'items' => {} })
      FileUtils.rm(File.join(inst.scripts, 'l2_scan.rb'))
      out, err, status = inst.run('--quiet')
      assert_equal 1, status.exitstatus
      # The specific line, not just the filename: the load rescue below also
      # names the file, so asserting only that let the absence check be deleted.
      assert_includes out, 'SkillSet が壊れています'
      assert_empty err.strip
    end
  end

  def test_a_broken_derivation_is_reported_not_raised
    with_instance do |inst|
      inst.pm(store_of(item), { 'version' => 1, 'items' => {} })
      File.write(File.join(inst.scripts, 'l2_scan.rb'), "this is not ruby(\n")
      out, err, status = inst.run('--quiet')
      assert_equal 1, status.exitstatus
      # The distinguishing phrase, not the filename: a Ruby SyntaxError message
      # BEGINS with the path, so asserting 'l2_scan.rb' passed on the
      # interpolation alone and left this branch's own wording free. Its sibling
      # above was strengthened for exactly this reason; this one was missed.
      assert_includes out, '読み込めません'
      assert_empty err.strip
    end
  end

  # The count, not only the wording. A SyntaxError names every offending line —
  # measured at 43 for this file parsed by Ruby 2.6, which is what /usr/bin/ruby
  # is on macOS and what the hook reaches when rbenv is not on PATH. The hook
  # publishes into a session and hooks.json keeps stderr on purpose, so an
  # unbounded quote is an unbounded interruption. Its sibling below covers the
  # JSON parser, the other library that hands back a multi-line message.
  def test_a_broken_derivation_is_reported_in_exactly_one_line
    with_instance do |inst|
      inst.pm(store_of(item), { 'version' => 1, 'items' => {} })
      File.write(File.join(inst.scripts, 'l2_scan.rb'), (['def broken(' * 3] * 20).join("\n"))
      out, err, status = inst.run('--quiet')
      assert_equal 1, status.exitstatus
      assert_equal 1, out.lines.length, out
      assert_empty err.strip
    end
  end
end

# Emptying a diagnostic and changing an exit code to 137 were both green.
class TheOutputLinesAreAContract < Minitest::Test
  include Fixtures

  def populated(inst)
    inst.pm(store_of(item(title: 'named_ctx_alpha の件')), { 'version' => 1, 'items' => {} })
    inst.context('named_ctx_alpha', "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
  end

  def test_quiet_prints_two_lines_and_names_the_output
    with_instance do |inst|
      populated(inst)
      out, err, status = inst.run('--quiet')
      assert_equal 0, status.exitstatus, out + err
      lines = out.lines.map(&:chomp).reject { |l| l.strip.empty? }
      assert_equal 2, lines.length, out
      assert_includes lines[0], '項目のうち'
      assert_includes lines[1], inst.out_path
    end
  end

  def test_the_default_prints_three_lines_with_the_five_causes
    with_instance do |inst|
      populated(inst)
      out, err, status = inst.run
      assert_equal 0, status.exitstatus, out + err
      lines = out.lines.map(&:chomp).reject { |l| l.strip.empty? }
      assert_equal 3, lines.length, out
      ['自動照合', '語が広すぎ', 'L2 の日付が読めない',
       'memo の最終接触が読めない', '照合語が作れない'].each do |label|
        assert_includes lines[1], label
      end
    end
  end
end

# The derivation's own reading surface.
#
# The Python suite this was ported from drove `match` with hand-built documents
# and never ran `load_l2` at all, so the constraints stated at the top of
# l2_scan -- body never matched, every declared date kept, identity is content --
# had no test on either side. A mutation audit of the port found seven one-line
# changes in that file the ported suite could not see; each case below kills one.
# It is also where a port diverges most, so the two measured Ruby/Python
# differences are pinned here too.
class TheDerivationReadsWhatItSaysItReads < Minitest::Test
  include Fixtures

  # Not Dir.mktmpdir: it names the directory after today, and l2_scan reads a
  # 20nnnnnn run anywhere in the path as the document's date when the document
  # declares none. A dated scratch path would hand the undated case its answer.
  def setup
    letters = Array.new(12) { ('a'..'z').to_a.sample }.join
    @tmp = File.join(Dir.tmpdir, "pm_l2_scan_#{letters}")
    @data = File.join(@tmp, 'kdata')
    FileUtils.mkdir_p(File.join(@data, 'context'))
    refute_match(/20\d{6}/, @data, 'the scratch path carries a date stamp; see setup')
  end

  def teardown = FileUtils.remove_entry(@tmp)

  def write_context(rel, body)
    path = File.join(@data, 'context', rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def load_all = L2Scan.load_l2(L2Scan.paths(@data))

  # Constraint 1. Body matching measured roughly 25% precision: of twelve items
  # whose result it changed, nine changed to work belonging elsewhere.
  def test_the_body_is_not_part_of_the_haystack
    write_context('s/a.md', "---\nname: alpha_ctx\ndate: 2026-08-10\n---\nbeta_word_in_body\n")
    docs, = load_all
    assert_equal 1, docs.length
    refute_includes docs[0]['handle'], 'beta_word_in_body'
    assert_empty L2Scan.match(docs, ['beta_word_in_body'], [])
    refute_empty L2Scan.match(docs, ['alpha_ctx'], [])
  end

  # Dropping them silently reported an invisible record as absent work.
  def test_an_undated_document_is_indexed_and_counted_not_dropped
    write_context('s/dated.md', "---\nname: dated_ctx\ndate: 2026-08-10\n---\nb\n")
    write_context('s/plain.md', "---\nname: undated_ctx\n---\nb\n")
    docs, undated = load_all
    assert_equal %w[dated_ctx undated_ctx], docs.map { |d| d['name'] }.sort
    assert_equal 1, undated
    assert_empty docs.find { |d| d['name'] == 'undated_ctx' }['dates']
  end

  # Constraint 6. Of twenty-five same-name groups in the live store, none were
  # byte-identical: they are successive revisions, and collapsing by name
  # discards records.
  def test_two_documents_sharing_a_name_with_different_content_are_two_records
    write_context('s1/x.md', "---\nname: revised_ctx\ndate: 2026-08-01\n---\nfirst\n")
    write_context('s2/x.md', "---\nname: revised_ctx\ndate: 2026-08-09\n---\nsecond\n")
    docs, = load_all
    assert_equal 2, L2Scan.match(docs, ['revised_ctx'], []).length
  end

  # Which of two byte-identical contexts survives dedup is decided by the order
  # the walk hands them over, and with it the surviving path — which is inside
  # the haystack. The comment calls the guard forward-looking ("no such pair
  # exists today"); this is what makes the forward-looking claim measurable.
  def test_the_walk_order_decides_which_duplicate_survives
    body = "---\nname: dup_ctx\ndate: 2026-08-10\n---\nsame bytes\n"
    write_context('s2/x.md', body)
    write_context('s1/x.md', body)
    docs, = load_all
    assert_equal 1, L2Scan.match(docs, ['dup_ctx'], []).length
    assert_match(%r{s1/x\.md\z}, L2Scan.match(docs, ['dup_ctx'], []).first['path'])
  end

  # Ruby's \w is ASCII-only where Python's is not, so a Japanese tag dropped out
  # of the haystack and stopped matching an authored term written in Japanese.
  def test_a_japanese_tag_reaches_the_haystack
    write_context('s/a.md', "---\nname: tagged_ctx\ndate: 2026-08-10\ntags: 設計, review\n---\nb\n")
    docs, = load_all
    assert_includes docs[0]['handle'], '設計'
    refute_empty L2Scan.match(docs, ['設計'], [])
  end

  # Ruby's split limit counts the parts; Python's maxsplit counted the splits.
  # Off by one, the whole document became its own frontmatter.
  def test_a_body_containing_a_horizontal_rule_does_not_become_frontmatter
    fm = L2Scan.frontmatter("---\nname: ruled_ctx\ndate: 2026-08-05\n---\n\nintro\n\n---\n\nmore\n")
    assert_equal 'ruled_ctx', L2Scan.field(fm, 'name')
    refute_includes fm, 'more'
    # The case above pins the split LIMIT and leaves the length GUARD free: with
    # a closing delimiter there are three parts either way. A context opened and
    # never closed — a session killed mid-write — would otherwise have its whole
    # body returned as frontmatter, and the body would reach the haystack through
    # tags. Body matching measured roughly 25% precision.
    assert_equal '', L2Scan.frontmatter("---\nname: truncated_ctx\ntags: body_word\n")
    assert_equal '', L2Scan.frontmatter("intro\n---\nname: not_frontmatter\n---\n")
  end

  # Constraint 5. Twelve documents in the live store declare an update later
  # than their creation with no separate date field, and preferring one field
  # reported the earliest date under a name promising the latest.
  # The field order and the chronological order must DISAGREE, or the sort is
  # free. An earlier version of this case reversed the order in the text, which
  # proves nothing: filter_map walks DATE_FIELDS, not the text, so `date` was
  # emitted first and the list was already ascending before .sort ran.
  def test_every_declared_date_is_kept_earliest_first
    assert_equal %w[2026-08-01 2026-08-14],
                 L2Scan.dates_of("\nname: x\ndate: 2026-08-14\nupdated: 2026-08-01\n", '/x/a.md')
    assert_equal %w[2026-08-02 2026-08-10],
                 L2Scan.dates_of("\nname: x\ncreated: 2026-08-10\nupdated: 2026-08-02\n", '/x/a.md')
  end

  def test_a_document_with_no_date_field_falls_back_to_the_path_stamp
    assert_equal ['2026-08-20'], L2Scan.dates_of('', '/x/context/20260820_session/a.md')
    assert_empty L2Scan.dates_of('', '/x/context/plain/a.md')
    # A fallback, not an addition. Nearly every live session directory carries a
    # stamp, so if a declared date did not suppress it every dated document would
    # gain a second date and move first_activity, active_days and every delta.
    assert_equal ['2026-08-01'],
                 L2Scan.dates_of("\nname: x\ndate: 2026-08-01\n",
                                 '/x/context/20260820_session/a.md')
  end

  # Whitespace first, then quotes. Reversing the two leaves the closing quote
  # attached, because the leading quote is behind the spaces that have not been
  # removed yet.
  def test_the_field_value_is_stripped_of_whitespace_before_quotes
    assert_equal 'abc', L2Scan.field(%(\nname:   "abc"  \n), 'name')
    assert_equal 'a b', L2Scan.field(%(\ntitle: 'a b'\n), 'title')
  end

  # Ruby's \s is ASCII-only and String#strip removes ASCII whitespace only;
  # Python's \s and str.strip() are Unicode-aware. One U+3000 IDEOGRAPHIC SPACE
  # after the colon — what a Japanese IME emits on the space bar in kana mode —
  # survived both stages here and neither there. The expected values are Python's.
  def test_unicode_whitespace_around_a_field_value_is_removed_as_python_removes_it
    { "\ndate:　2026-08-01\n" => '2026-08-01',        # U+3000 leading
      "\ndate: 2026-08-01　\n" => '2026-08-01',       # U+3000 trailing
      "\ndate: 2026-08-01\n" => '2026-08-01',    # NBSP leading
      "\ndate: 2026-08-01 \n" => '2026-08-01',   # NBSP trailing
      "\ndate:\t2026-08-01\n" => '2026-08-01',
      "\ndate:　　\n" => '' }.each do |fm, want|
      assert_equal want, L2Scan.field(fm, 'date'), fm.inspect
    end
  end

  # Python's str.strip() also removes U+001C-U+001F, the four ASCII separators,
  # which POSIX [[:space:]] omits. Stated as a residual for four rounds on the
  # grounds that authored frontmatter carries none of them; measured afterwards,
  # one U+001C after the colon left the date unparsed, fell through to the
  # path-stamp fallback, and printed a nine-day lag as nineteen — the same
  # consequence the ideographic space had.
  def test_the_ascii_separators_are_removed_as_python_removes_them
    (0x1C..0x1F).each do |code|
      sep = code.chr(Encoding::UTF_8)
      assert_equal '2026-08-01', L2Scan.field("\ndate:#{sep}2026-08-01\n", 'date'),
                   format('U+%04X leading', code)
      assert_equal '2026-08-01', L2Scan.field("\ndate: 2026-08-01#{sep}\n", 'date'),
                   format('U+%04X trailing', code)
    end
  end

  # The consequence, end to end: without the fix the anchored date match fails,
  # the document falls through to the path-stamp fallback, and the delta's SIGN
  # flips — the page reports the memo as the more recent side when L2 is.
  def test_a_full_width_space_does_not_substitute_the_path_stamp_for_the_date
    write_context('session_20260601_x/a.md',
                  "---\nname: alpha_widget\ndate:　2026-08-10\ntags: alpha_widget\n---\nb\n")
    docs, = load_all
    assert_equal ['2026-08-10'], docs[0]['dates'],
                 'the declared date lost to the session directory stamp'
  end

  # Dir.glob asks the filesystem and this volume folds case, so `*.md` returned
  # `upper_ctx.MD` as well; Python's glob matches the pattern itself and never
  # did. The extras move contexts_indexed, enlarge the haystack, and add digests
  # that decide which of two identical files survives dedup — and none of it
  # happens when the same store is read on Linux, which the gem also ships to.
  def test_a_context_whose_extension_is_not_lowercase_md_is_left_out
    write_context('s/lower_ctx.md', "---\nname: lower_ctx\ndate: 2026-08-10\n---\nb\n")
    write_context('s/upper_ctx.MD', "---\nname: upper_ctx\ndate: 2026-08-10\n---\nb\n")
    docs, = load_all
    assert_equal ['lower_ctx'], docs.map { |d| d['name'] }
  end

  # Python read with errors="replace"; String#scrub is the port of that. hooks.json
  # keeps stderr on purpose, so one undecodable byte would put a backtrace in a
  # session instead of a report.
  def test_an_undecodable_context_is_indexed_rather_than_raising
    write_context('s/bad.md', "---\nname: bad_byte_ctx\ndate: 2026-08-10\n---\n\xFF\n".b)
    docs, = load_all
    assert_equal ['bad_byte_ctx'], docs.map { |d| d['name'] }
    refute_empty L2Scan.match(docs, ['bad_byte_ctx'], [])
  end

  # Identity feeds the haystack, so which field wins decides what matches at all —
  # not only what is displayed. 321 of 1177 live contexts take their name from a
  # free-text title.
  def test_the_name_field_wins_over_title_and_title_over_the_basename
    write_context('s/ignored_basename.md',
                  "---\nname: name_ctx\ntitle: title_ctx\ndate: 2026-08-10\n---\nb\n")
    write_context('s/also_ignored.md', "---\ntitle: title_only_ctx\ndate: 2026-08-10\n---\nb\n")
    write_context('s/bare_basename_ctx.md', "---\ndate: 2026-08-10\n---\nb\n")
    docs, = load_all
    assert_equal %w[bare_basename_ctx name_ctx title_only_ctx], docs.map { |d| d['name'] }.sort
  end

  # Two files with identical content are one record however many sessions hold
  # them -- the digest, not the name or the path, is what says so.
  def test_identical_content_under_two_paths_is_one_record
    docs = [doc('same_ctx', ['2026-08-01'], path: 'c/s1/x.md', digest: 'D'),
            doc('same_ctx', ['2026-08-01'], path: 'c/s2/x.md', digest: 'D'),
            doc('same_ctx', ['2026-08-02'], path: 'c/s3/x.md', digest: 'E')]
    got = L2Scan.match(docs, ['same_ctx'], [])
    assert_equal ['c/s1/x.md', 'c/s3/x.md'], got.map { |d| d['path'] }
  end

  # Path is the only field guaranteed unique, so it is what makes the order
  # total. Ordering by date alone leaves same-day records wherever the
  # filesystem walk happened to put them.
  def test_the_match_order_is_total_not_only_by_date
    names = %w[epsilon_ctx delta_ctx charlie_ctx bravo_ctx alpha_ctx]
    # Paths ascend in input order while names descend, so only the name key can
    # produce names.sort. The earlier fixture derived the path FROM the name, so
    # sorting by either gave the same answer and the case could not tell them apart.
    docs = names.each_with_index.map { |n, i| doc(n, ['2026-08-01'], path: "c/s#{i}/x.md") }
    assert_equal names.sort, L2Scan.match(docs, ['_ctx'], []).map { |d| d['name'] }
  end
end

# The derivation's writing surface: derive, report and marker_string. Neither the
# Python suite nor the first Ruby port called any of them — 112 of l2_scan.rb's
# lines, in which every mutation survived by construction. Two reviewers named
# this independently, and three of round 1's confirmed defects were hiding here.
class TheDerivationsWritingSurface < Minitest::Test
  include Fixtures

  # `l2_mapping.json` is hand-edited and unchecked. A bare String where a list
  # belongs reached `match`, which called `any?` on it: an uncaught backtrace at
  # exit 1, where Python iterated the string into single-character terms and
  # printed a full report at exit 0. Refusing is the better answer than Python's;
  # raising is not.
  def test_a_mis_typed_mapping_entry_does_not_raise_out_of_derive
    docs = [doc('ctx_ok', ['2026-08-10'])]
    [{ 'include' => 'ctx_ok' }, { 'include' => nil }, { 'include' => ['ctx_ok', 3, ''] },
     { 'include' => ['ctx_ok'], 'exclude' => 'nope' }].each do |spec|
      rows = L2Scan.derive(docs, { 'items' => { 'itm_1' => spec } }, store_of(item(1)))
      assert_equal 1, rows.length, spec.inspect
    end
    # The one well-formed entry still matches; refusing is not refusing everything.
    rows = L2Scan.derive(docs, { 'items' => { 'itm_1' => { 'include' => ['ctx_ok'] } } },
                         store_of(item(1)))
    assert_equal 9, rows[0]['touch_delta_days']
  end

  def test_derive_reports_matched_unmapped_undated_and_mapped_but_unmatched
    docs = [doc('ctx_ok', ['2026-08-10']), doc('ctx_undated', [])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['ctx_ok'] },
                             'itm_2' => { 'include' => ['ctx_undated'] },
                             'itm_3' => { 'include' => ['no_such_ctx'] } } }
    rows = L2Scan.derive(docs, mapping, store_of(item(1), item(2), item(3), item(4)))
    assert_equal [9, true, true, true],
                 [rows[0]['touch_delta_days'], rows[1]['records_all_undated'],
                  rows[2]['needs_l2_label'], rows[3]['needs_mapping']]
  end

  # Python's sorted is stable and kept tied rows in store order; Ruby's sort_by is
  # not. On the live store this printed 10 of 26 rows in a different order, and
  # adding one unrelated item reshuffled rows that had not changed. Store order,
  # not id order: sorting ties by id would be total and would still not be what
  # Python printed.
  # Twenty-six rows in TWO delta groups, which is the shape that actually breaks.
  # Measured: Ruby's sort_by preserves order when every key is equal, at any
  # length — a first version of this case used forty rows of one delta and could
  # not tell a stable sort from an unstable one. With two groups at twenty-six it
  # reverses within each group. Twenty-six is also the size of the live table.
  def test_the_scan_table_keeps_tied_rows_in_store_order
    ids = (0...26).to_a
    # Zero-padded so no term nests inside another: ctx_tie_01 is not a substring
    # of ctx_tie_10, where ctx_tie_1 would be.
    docs = ids.map { |n| doc(format('ctx_tie_%02d', n), [n.even? ? '2026-08-02' : '2026-08-01']) }
    mapping = { 'items' => ids.to_h { |n| ["itm_#{n}", { 'include' => [format('ctx_tie_%02d', n)] }] } }
    store = store_of(*ids.map { |n| item(n) })
    out, = capture_io { L2Scan.report(L2Scan.derive(docs, mapping, store), 0) }
    # Lag 1 first, then lag 0, each group in the order the store holds them.
    assert_equal ids.select(&:even?) + ids.reject(&:even?),
                 out.scan(/^t(\d+)\s/).flatten.map(&:to_i), out
  end

  # Integer#[] with two arguments is a bit slice: 20260701[0, 10] is 861, which
  # printed in a column promising a date. Date.parse reads "2026-08-2" as the 2nd,
  # a wrong day rather than a refusal. Python raised on both; so does this.
  # The scan's own JSON reader. File.read tags the encoding without validating it
  # and JSON.parse accepts what it tags, so invalid bytes would reach the haystack
  # and raise out of String#include? far from the file carrying them.
  def test_the_scan_refuses_a_json_file_that_is_not_valid_utf8
    dir = Dir.mktmpdir
    good = File.join(dir, 'good.json')
    bad = File.join(dir, 'bad.json')
    File.write(good, '{"a":1}')
    File.binwrite(bad, %({"a":"caf\xE9"}))
    assert_equal({ 'a' => 1 }, L2Scan.read_json(good))
    err = capture_io { assert_raises(SystemExit) { L2Scan.read_json(bad) } }[1]
    assert_includes err, 'not valid UTF-8'
    assert_includes err, 'bad.json'
  ensure
    FileUtils.remove_entry(dir)
  end

  # Python's slice raised TypeError on a non-String for EVERY item, so this half
  # is unconditional. Integer#[] with two arguments is a bit slice: 20260701[0, 10]
  # is 861, which printed in a column promising a date.
  def test_a_non_string_marker_stops_the_run_by_name
    [20_260_701, nil, ['2026-08-01'], { 'a' => 1 }, 2026.0, true].each do |bad|
      err = capture_io { assert_raises(SystemExit) { L2Scan.marker_string('itm_x', bad) } }[1]
      assert_includes err, 'itm_x', bad.inspect
      assert_includes err, 'is not a string', bad.inspect
    end
    assert_equal '2026-08-01', L2Scan.marker_string('itm_x', '2026-08-01T00:00:00Z')
  end

  # Readability is checked where Python checked it — at the delta. Date.parse
  # would read "2026-08-2" as the 2nd, and iso8601 alone accepts 2026-02-30.
  def test_an_unreadable_marker_stops_the_run_at_the_delta
    ['2026-08-2', '2026/08/20', '20260820', '2026-02-30', ''].each do |bad|
      err = capture_io { assert_raises(SystemExit) { L2Scan.marker_date('itm_x', bad) } }[1]
      assert_includes err, 'itm_x', bad.inspect
      assert_includes err, 'not a readable date', bad.inspect
    end
    assert_equal Date.new(2026, 8, 1), L2Scan.marker_date('itm_x', '2026-08-01')
  end

  # The scope half of the same fix, and the one a round of review caught. Python
  # parsed the marker only inside the fully-matched branch, so an unreadable
  # marker on an item with no mapping entry, or with no dated records, never
  # stopped its run. Checking readability earlier aborted the whole report on one
  # such item — and "2026-13-99" is written four times by this SkillSet's own
  # other suite.
  def test_an_unreadable_marker_on_an_unmatched_item_does_not_stop_the_run
    docs = [doc('ctx_ok', ['2026-08-10'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['ctx_ok'] },
                             'itm_3' => { 'include' => ['no_such_ctx'] } } }
    store = store_of(item(1), item(2, touched_at: '2026-13-99'),
                     item(3, touched_at: 'pending'))
    rows = L2Scan.derive(docs, mapping, store)
    assert_equal %w[itm_1 itm_2 itm_3], rows.map { |r| r['id'] }
    assert_equal 9, rows[0]['touch_delta_days']
    assert_equal '2026-13-99', rows[1]['store_touched']
    assert rows[1]['needs_mapping']
    assert rows[2]['needs_l2_label']
  end

  # Through derive, not in isolation. marker_string checks only the type, so the
  # marker arrives at the delta unread; without marker_date there, a matched item
  # holding "2026-08-2" raises Date::Error instead of stopping by name.
  def test_a_matched_item_with_an_unreadable_marker_stops_by_name
    docs = [doc('ctx_ok', ['2026-08-10'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['ctx_ok'] } } }
    store = store_of(item(1, touched_at: '2026-08-2'))
    err = capture_io { assert_raises(SystemExit) { L2Scan.derive(docs, mapping, store) } }[1]
    assert_includes err, 'itm_1'
    assert_includes err, 'not a readable date'
  end

  # Ruby's Date defaults to Date::ITALY, which reads anything before 1582-10-15
  # as Julian and denies 1582-10-05..14 ever happened; Python's date is proleptic
  # Gregorian at every year. Measured against 2026-08-01, the default put
  # 0001-01-01 two days out, 1000-01-01 five days out, and raised on 1582-10-10
  # where Python returned a number. The expected values below are Python's.
  def test_dates_before_the_gregorian_reform_use_pythons_calendar
    base = Date.iso8601('2026-08-01')
    { '0001-01-01' => -739_828, '1000-01-01' => -374_951,
      '1582-10-04' => -162_104, '1582-10-10' => -162_098,
      '1582-10-15' => -162_093, '1900-01-01' => -46_233 }.each do |text, days|
      assert_equal days, (L2Scan.marker_date('itm_x', text) - base).to_i, text
      assert_equal days, (PmL2Report.as_date(text) - base).to_i, "as_date #{text}"
    end
    # The shape and existence gates are unaffected by the calendar argument.
    capture_io { assert_raises(SystemExit) { L2Scan.marker_date('itm_x', '2026-02-30') } }
    assert_nil PmL2Report.as_date('2026-02-30')
    assert_nil PmL2Report.as_date('20260701')
  end

  # The L2 end of the same subtraction is shape-gated only: dates_of accepts
  # 2026-02-30, and its path-stamp fallback can synthesise 2026-99-99. It raises
  # here, which is what Python did — pinned so the parity is deliberate rather
  # than accidental, and so a later softening has to be a decision.
  def test_an_impossible_l2_date_raises_the_way_python_did
    docs = [doc('ctx_bad_day', ['2026-02-30'])]
    mapping = { 'items' => { 'itm_1' => { 'include' => ['ctx_bad_day'] } } }
    assert_raises(Date::Error) { L2Scan.derive(docs, mapping, store_of(item(1))) }
  end

  # report prints eight things; the tie case asserts one of them. Three distinct
  # lags so the median's odd arm runs, and one mapped-but-unmatched row so a note
  # branch runs.
  def test_the_scan_tables_summary_lines_say_what_they_measure
    docs = [doc('ctx_lag_a', ['2026-08-03']), doc('ctx_lag_b', ['2026-08-10']),
            doc('ctx_lag_c', ['2026-08-15']), doc('ctx_early', ['2026-08-02'])]
    mapping = { 'items' => {
      'itm_1' => { 'include' => ['ctx_lag_a'] }, 'itm_2' => { 'include' => ['ctx_lag_b'] },
      'itm_3' => { 'include' => %w[ctx_lag_c ctx_early] }, 'itm_4' => { 'include' => ['no_such'] }
    } }
    store = store_of(item(1), item(2), item(3), item(4))
    out, = capture_io { L2Scan.report(L2Scan.derive(docs, mapping, store), 7) }
    assert_includes out, '3/4 items have nearby activity   L2 more recent: 3   in step: 0   memo more recent: 0'
    assert_includes out, 'memo lag where L2 is more recent: median 9d, max 14d'
    assert_includes out, '  no nearby record; needs an L2 name or tag'
    assert_includes out, '7 indexed contexts declare no date and carry none in their path.'
    # itm_3 matches two dated records; the column headed "most recent" names the LATER one.
    assert_match(/^t3\s.*ctx_lag_c/, out)
    refute_match(/^t3\s.*ctx_early/, out)
  end
end

# It ships inside the gem, so it must pass with no instance present at all.
class TheSuiteRunsAnywhere < Minitest::Test
  def test_the_module_under_test_does_not_read_the_live_store_at_load
    assert_respond_to PmL2Report, :build_rows
    assert PmL2Report.out_path.end_with?(File.join('log', 'pm_l2_report.html'))
  end
end
