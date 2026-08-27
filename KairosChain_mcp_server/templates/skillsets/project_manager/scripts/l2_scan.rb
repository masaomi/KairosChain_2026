#!/usr/bin/env ruby
# frozen_string_literal: true

# Report evidence of activity near each work item, from the L2 context store.
#
# L2 is the source of truth; pm/store.json is a derived memo. This script reads
# L2 and reports what it finds. It never writes store.json -- reconciliation is a
# separate, human-gated step.
#
# It does not claim that a matched document *belongs* to the item it is reported
# under. Tags name subjects; items name work that remains. One document can sit
# correctly under several items, so the output is evidence for an operator to
# judge, not an attribution. Column names and the comments below are held to
# that: nothing here is called an item's status.
#
# Design constraints, each established by measurement (2026-07-27, revised the
# same day after review):
#
#   1. Match on document name / path / tags only. Body-text matching measured
#      roughly 25% precision -- of twelve items whose result it changed, nine
#      changed to work belonging elsewhere.
#   2. An item that matches nothing is repaired in L2 by labelling the work, not
#      by widening the mapping. Widening trades a visible gap for an invisible
#      false positive.
#   3. The mapping needs exclusion as well as inclusion terms, because L2 names
#      nest (plugin_projector is a substring of pm_plugin_projection).
#   4. Report what each figure measures. The interval between the memo's last
#      touch and L2's last activity measures when someone last wrote something
#      down; it does not measure how stale the underlying fact is, and it has
#      been observed pointing the wrong way.
#   5. A document carries every date it declares. Preferring one field over the
#      others reported the earliest date under a name promising the latest;
#      twelve documents in this store declare an update later than their
#      creation with no separate date field.
#   6. Identity is content, not name. Contexts sharing a name across sessions are
#      successive revisions, not copies: of twenty-five same-name groups here,
#      none were byte-identical. Collapsing by name discards records.
#   7. No aggregate field carries a matched record's status. A status line lifted
#      whole is a statement about work this scan does not claim to attribute, and
#      it crosses the boundary the memo's own read surface is held to. Per-record
#      status is available under --item, where each line is plainly one record.
#
# Ported from Python (2026-08-20). The claim is the same observable behaviour as
# the original, and the exceptions are these -- all of them, stated here once and
# referenced from the report script rather than restated there.
#
#   1. Paths are derived from this file's own position, not by appending a
#      literal ".kairos" to the project root. A relocated instance was reported
#      as empty, and the report script had to undo that by reassigning this
#      file's constants after importing it. Deriving correctly deletes both.
#   2. A data directory whose name contains a closed bracket -- `projects[old]`
#      -- is read. Python's glob took it as a character class and found nothing.
#   3. Booleans and containers print in Ruby's spelling: `true`, `["a"]`,
#      `{"a" => 1}` where Python printed `True`, `['a']`, `{'a': 1}`.
#   4. `touched_at` holding a list is refused. Python's `[:10]` is a legal slice
#      on a list, so it produced a full report from a value that is not a date.
#   5. An `include`/`exclude` that is not a list is refused. Python iterated the
#      string into single-character terms, one of which matched every document
#      while displaying as the operator's own authored mapping.
#   6. The page escapes an apostrophe as `&#39;`; Python's html.escape wrote
#      `&#x27;`. Same character, different spelling of the same entity.
#   7. A frontmatter value stops at the end of its line. Python's `\s*` ran past
#      the newline, so `name:` with an empty value took the NEXT line as its
#      value and displayed `alpha_ctx: yes` as a document name.
#   8. A tag written with symbol letters -- U+24D0 and its kind -- stays in the
#      search text. Ruby's [[:word:]] matches them and Python's \w does not, so
#      an authored tag that matched here vanished there.
#   9. A store that is not valid UTF-8 is named as such in its own sentence,
#      where Python surfaced the decoder's exception.
#  10. A broken JSON file is reported in the parser's own words. Python named
#      `line 7 column 5`; Ruby's JSON::ParserError quotes the text and carries no
#      line number, and neither wording is recoverable from the other.
#
# Nothing else. `log/pm_l2_report_ruby_port/parity/` runs both implementations
# over 101 named input classes and fails if any difference lacks a number above.
#
# Usage:
#     ruby l2_scan.rb                 # evidence table
#     ruby l2_scan.rb --json          # the same, as JSON
#     ruby l2_scan.rb --item itm_xxx  # one item, listing every matched record

require 'date'
require 'digest'
require 'json'
require 'optparse'

module L2Scan
  DATE_FIELDS = %w[date created updated].freeze

  # The shape a date must have before anything parses it. `(?!0000)` because
  # Python's datetime.date starts at year 1 and raised on 0000-01-01, where
  # Ruby's Date accepts year zero: the page counted a 739,000-day lag from a
  # value Python had reported as unreadable. Four digits, so no upper bound is
  # needed. Referenced from both files -- one shape, one home.
  ISO_DAY = /\A(?!0000)\d{4}-\d{2}-\d{2}\z/.freeze

  # The calendar every parse in this SkillSet uses, stated once rather than
  # defaulted four times.
  #
  # Ruby's Date defaults to Date::ITALY: it reads anything before 1582-10-15 as
  # Julian and denies that 1582-10-05..14 ever happened. Python's datetime.date
  # is proleptic Gregorian at every year. Measured against 2026-08-01, the
  # default put 0001-01-01 two days out and 1000-01-01 five days out, and raised
  # on 1582-10-10 where Python returned a number -- so the page printed a wrong
  # day count at exit 0, and a row with an ordinary ISO marker vanished under
  # "memo 側の最終接触が読めない", which was not true of it.
  CALENDAR = Date::GREGORIAN

  # Where a scan reads from. Every path is derived from one directory, so a copy
  # of the SkillSet under a directory of any name is a complete instance.
  Paths = Struct.new(:data_dir) do
    # The project root is the data directory's parent. Used only to shorten a
    # displayed path; nothing is read through it.
    def root = File.dirname(data_dir)

    # RELATIVE, and resolved against data_dir by Dir.glob's `base:`. Dir.glob
    # reads its whole argument as a pattern, so an absolute prefix is pattern
    # too: a data dir under `Kairos{2026}` or `projects[old` matched nothing at
    # all and the scan reported zero contexts at exit 0 -- the same silence this
    # file's own path derivation was rewritten to remove, arriving through the
    # other door. Python's glob expands neither braces nor an unclosed bracket,
    # so `base:` restores parity there.
    #
    # A *closed* bracket is different and the earlier version of this comment had
    # it wrong: `projects[old]` is a character class in Python's glob too, so
    # Python already reported zero contexts under that name and this now indexes
    # them. Deliberate; exception 2 in the list at the top of this file.
    def context_glob = File.join('context', '**', '*.md')
    def mapping_path = File.join(data_dir, 'pm', 'l2_mapping.json')
    def store_path = File.join(data_dir, 'pm', 'store.json')
  end

  # <data dir>/skillsets/project_manager/scripts -> <data dir>.
  #
  # Not __dir__: that resolves symlinks and Python's os.path.abspath(__file__)
  # does not. Symlinking the SkillSet into the distribution tree -- the obvious
  # way to edit without re-copying -- then made Ruby derive the templates
  # directory as the data dir and write its page inside a git-tracked tree.
  def self.default_data_dir = File.expand_path('../../..', File.dirname(File.expand_path(__FILE__)))

  def self.paths(data_dir = default_data_dir) = Paths.new(data_dir)

  # Read one JSON file, refusing bytes that are not valid UTF-8.
  #
  # File.read TAGS the encoding and never validates it, and JSON.parse accepts
  # whatever it tags, so invalid bytes would travel into the haystack and raise
  # later out of String#include? -- far from the file that carries them. Python's
  # open(encoding="utf-8") decoded here and stopped here; abort keeps that, in one
  # line on stderr at exit 1 rather than through a traceback.
  def self.read_json(path)
    raw = File.read(path, encoding: 'UTF-8')
    abort("#{path}: not valid UTF-8") unless raw.valid_encoding?

    JSON.parse(raw)
  end

  # The middle of an already-sorted list, or nil for an empty one.
  #
  # Defined once and called from both files. It used to exist twice, identically,
  # and a round of review found the copy here untested while the copy in
  # pm_l2_report.rb was covered -- one invariant, two homes, one of them holding.
  def self.median(sorted)
    return nil if sorted.empty?

    mid = sorted.length / 2
    sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  # A mapping entry's include/exclude as a list of strings, or [].
  #
  # Defined here and called from both files. `l2_mapping.json` is hand-edited and
  # nothing checks its shape; `term_list`'s own history records the mis-edit of
  # writing a bare string where a list belongs. `spec['include'] || []` passed
  # that String straight through to `match`, which called `any?` on it: an
  # uncaught backtrace at exit 1, where Python iterated the string into
  # single-character terms and printed a full report at exit 0. Refusing is the
  # better answer than Python's, and it is the one the report side already gave.
  def self.term_list(value)
    return [] unless value.is_a?(Array)

    value.select { |t| t.is_a?(String) && !t.empty? }
  end

  # Whether a YYYY-MM-DD string names a day that exists. Shape is not existence:
  # 2026-02-30 passes ISO_DAY and is not a date.
  def self.valid_day?(text)
    Date.iso8601(text, CALENDAR)
    true
  rescue ArgumentError
    false
  end

  # The memo's last-touch marker as a string. Python did exactly this much here,
  # and no more: `item["touched_at"][:10]` raises TypeError on almost any
  # non-String, because Integer and NilClass are not subscriptable.
  #
  # Almost, not every: `[:10]` on a **list** is a legal Python slice, so
  # `"touched_at": ["2026-08-01"]` gives Python a full `--json` document where
  # this aborts. Refusing is the better answer and it stays; the earlier version
  # of this comment claimed "EVERY item" and was wrong.
  #
  # Ruby's Integer#[] with two arguments is a bit slice rather than a substring,
  # so the same expression turned the integer 20260701 into 861 and printed it in
  # a column promising a date. Hence the explicit type check where Python got one
  # from the language.
  #
  # Readability is NOT checked here. An earlier version of this function checked
  # both, and that hoisted work Python did later: Python parses the marker only
  # inside the fully-matched branch, so an unreadable marker on an item with no
  # mapping entry, or with no dated records, never stopped its run. Checking both
  # here made one such item abort the whole report. See marker_date.
  def self.marker_string(item_id, value)
    abort("#{item_id}: touched_at is not a string (#{value.inspect})") unless value.is_a?(String)

    value[0, 10]
  end

  # The marker as a date, at the one place Python parsed it: the delta, reached
  # only after an item has a mapping entry and at least one dated record.
  #
  # The gate is shape AND existence. Date.parse would read "2026-08-2" as the 2nd
  # — a wrong day rather than a refusal — and Date.iso8601 alone accepts the
  # shape-valid 2026-02-30.
  def self.marker_date(item_id, text)
    return Date.iso8601(text, CALENDAR) if ISO_DAY.match?(text) && valid_day?(text)

    abort("#{item_id}: touched_at is not a readable date (#{text.inspect})")
  end

  def self.frontmatter(text)
    return '' unless text.start_with?('---')

    # Ruby's limit counts the returned parts; Python's maxsplit counted the
    # splits. Three parts here is two splits there, and the off-by-one silently
    # returned the body as frontmatter.
    parts = text.split('---', 3)
    parts.length > 2 ? parts[1] : ''
  end

  # A POSIX [[:space:]] gsub rather than String#strip.
  #
  # The capture's own `\s*` is left ASCII-only on purpose. Widening it too was
  # written first and then reverted: a mutation putting it back could not be
  # killed, because the gsub already removes whatever `\s*` failed to consume.
  # One guard doing the work is better than two where only one is reachable.
  #
  # Ruby's \s is [ \t\r\n\f\v] and String#strip removes only ASCII whitespace;
  # Python's \s on a str and str.strip() are both Unicode-aware. A single U+3000
  # IDEOGRAPHIC SPACE after the colon -- what a Japanese IME emits on the space
  # bar in kana mode -- therefore survived both stages here and none there, and
  # the consequences were not cosmetic. `date:　2026-08-01` failed dates_of's
  # anchored match, fell through to the path-stamp fallback, and picked up the
  # session directory's date instead: measured, one context went from +12 days
  # in Python to -49 in Ruby, so the page reported the memo as the more recent
  # side when L2 was. And a name carrying a leading space no longer equals the
  # token inferred from an item's title, so the row said "no term overlaps an L2
  # name" while an L2 name overlapped it exactly.
  #
  # Whitespace first, then any run of quotes at either end -- the order the
  # Python original used, and the one that leaves `"a b"` as `a b`.
  #
  # BLANK is [[:space:]] plus U+001C-U+001F, which POSIX space omits and Python's
  # str.strip removes. The residual was stated rather than closed for four rounds
  # on the grounds that neither occurs in authored frontmatter; measured, one
  # U+001C after the colon left `date:` unparsed, dropped the value through to
  # the path-stamp fallback, and reported a nine-day lag as nineteen. The same
  # consequence the ideographic space had, so it gets the same guard.
  BLANK = /[[:space:]\u001C-\u001F]/.freeze

  def self.field(frontmatter_text, key)
    raw = frontmatter_text[/^#{key}:\s*(.+)$/, 1]
    return '' unless raw

    raw.gsub(/\A#{BLANK}+|#{BLANK}+\z/, '').sub(/\A["']+/, '').sub(/["']+\z/, '')
  end

  # Every date the document declares, earliest first.
  #
  # Constraint 5: a document that was created on one day and updated on another
  # was worked on both, so both are kept. The path stamp is a fallback only --
  # roughly a third of contexts declare no date field at all, and the session
  # directory is the only evidence they carry.
  def self.dates_of(frontmatter_text, path)
    found = DATE_FIELDS.filter_map { |key| field(frontmatter_text, key)[/\A\d{4}-\d{2}-\d{2}/] }
    if found.empty? && (stamp = path[/20\d{6}/])
      found << "#{stamp[0, 4]}-#{stamp[4, 2]}-#{stamp[6, 2]}"
    end
    found.uniq.sort
  end

  # Index every context. Undated documents are kept and counted, not dropped.
  #
  # Dropping them silently reported an invisible record as absent work, which is
  # one of the errors this scan exists to avoid making.
  def self.load_l2(paths)
    docs = []
    undated = 0
    prefix = File.basename(paths.data_dir)
    # Sorted: dedup keeps the first record of a given content, so an unsorted
    # walk would let the filesystem decide which of two identical files
    # survives -- and with it the surviving name and path. No such pair exists
    # today; the sort is what keeps that true if one appears.
    # end_with?, because Dir.glob follows the filesystem's case rules and Python's
    # glob does not: on this case-insensitive volume `*.md` returned `notes.MD`
    # too, which enlarged the haystack, moved contexts_indexed, and added digests
    # that decide which of two identical files survives dedup -- all at exit 0,
    # and all of it absent when the same store is read on Linux. The gem ships to
    # both, so the pattern's meaning is pinned here rather than left to the disk.
    Dir.glob(paths.context_glob, base: paths.data_dir)
       .select { |rel_path| rel_path.end_with?('.md') }
       .sort.each do |rel_path|
      # base:, so nothing outside `context/**/*.md` is read as a pattern. The
      # absolute path is rebuilt for reading, and is also what dates_of sees --
      # its path-stamp fallback looked at the whole path in Python too.
      path = File.join(paths.data_dir, rel_path)
      # scrub, not a raise: an undecodable byte in one context must not take the
      # whole index down. It also fixes the content digest below, which is only
      # ever compared within a single run.
      text = File.read(path, encoding: 'UTF-8').scrub
      fm = frontmatter(text)
      dates = dates_of(fm, path)
      undated += 1 if dates.empty?
      name = [field(fm, 'name'), field(fm, 'title'), File.basename(path, '.*')].find { |s| !s.empty? }
      rel = File.join(prefix, rel_path)
      # POSIX [[:word:]], not \w: Ruby's \w is ASCII-only, so a Japanese tag
      # would vanish from the haystack and stop matching an authored term.
      tags = field(fm, 'tags').downcase.scan(/[[:word:]]+/).join(' ')
      docs << {
        'name' => name,
        'path' => rel,
        'dates' => dates,
        'status' => field(fm, 'status'),
        # Constraint 1: the haystack is name + path + tags. Never the body.
        'handle' => "#{name} #{rel} #{tags}".downcase,
        # Constraint 6: identity is content.
        'digest' => Digest::SHA256.hexdigest(text)
      }
    end
    [docs, undated]
  end

  # Matched records: distinct content, deterministically ordered.
  #
  # Two files with identical content are one record however many sessions hold
  # them. Two files of the same name with different content are two records,
  # because they are revisions and the later one supersedes nothing -- both
  # happened. Ordering is (last date, name, path), all three needed: path is the
  # only field guaranteed unique, so it is what makes the order total.
  def self.match(docs, include, exclude)
    seen = {}
    hits = []
    docs.each do |doc|
      handle = doc['handle']
      next if exclude.any? { |term| handle.include?(term) }
      next unless include.any? { |term| handle.include?(term) }
      next if seen.key?(doc['digest'])

      seen[doc['digest']] = true
      hits << doc
    end
    hits.sort_by { |d| [d['dates'].last || '', d['name'], d['path']] }
  end

  # One row per store item. Iteration is over the store, not the mapping.
  #
  # Iterating the mapping made an item with no mapping entry vanish from the
  # output entirely, which is the same silence the mapping exists to remove. An
  # item is either matched, unmapped, or mapped-but-unmatched, and all three are
  # visible.
  def self.derive(docs, mapping, store)
    store['items'].map do |item_id, item|
      spec = mapping['items'][item_id]
      touched = marker_string(item_id, item['touched_at'])
      row = { 'id' => item_id, 'title' => item['title'],
              'store_status' => item['status'], 'store_touched' => touched }
      next row.merge('needs_mapping' => true) if spec.nil?

      hits = match(docs, term_list(spec['include']), term_list(spec['exclude']))
      dated = hits.select { |d| !d['dates'].empty? }
      row['records'] = hits.length
      row['undated_records'] = hits.length - dated.length
      if dated.empty?
        # Constraint 2: a gap in L2's labelling, not in the scan -- unless
        # records were found and none of them can be dated, which is a different
        # gap and must not be reported as a missing label.
        next row.merge((hits.empty? ? 'needs_l2_label' : 'records_all_undated') => true)
      end

      days = dated.flat_map { |d| d['dates'] }.uniq.sort
      row.merge(
        'first_activity' => days.first,
        'last_activity' => days.last,
        # Distinct days, not record count: review round-trips inflate the count
        # without reflecting how much work was done.
        'active_days' => days.length,
        # Named for what it is: a record near the item. Its status is not carried
        # here -- see constraint 7.
        'latest_nearby_record' => dated.last['name'],
        # The two ends are NOT gated alike, and an earlier version of this
        # comment said they were. `touched` goes through marker_date, which
        # checks shape and existence. `days.last` is shape-gated only —
        # dates_of's anchored match accepts 2026-02-30, and its path-stamp
        # fallback can synthesise 2026-99-99 from a directory named 20269999 —
        # so this subtraction still raises on a context declaring a day that
        # does not exist. That raise is what Python did (fromisoformat raises
        # ValueError on the same input), so it stays; the false claim does not.
        #
        # iso8601 rather than parse is therefore a choice, not a fix: on every
        # \d{4}-\d{2}-\d{2} input the two agree, so swapping them is an
        # equivalent mutation. The loose parser is kept out because it is what
        # read "2026-08-2" as the 2nd before marker_date existed.
        'touch_delta_days' => (Date.iso8601(days.last, CALENDAR) - marker_date(item_id, touched)).to_i
      )
    end
  end

  HEAD = '%-34s%4s%5s  %-11s%-11s%-11s%5s  %s'

  def self.report(rows, undated_total)
    matched = rows.select { |r| r.key?('last_activity') }
    puts format(HEAD, 'item', 'recs', 'days', 'first', 'L2 last', 'memo', 'delta',
                "most recent nearby record (not this item's status)")
    puts '=' * 150
    # The index, not a new tiebreaker. Python's sorted is stable, so tied rows kept
    # store order; Ruby's sort_by is not, and on the live store that printed 10 of
    # 26 rows in a different order and reshuffled untouched rows whenever an
    # unrelated item was added. Sorting by id would also be total, and would also
    # be a second behaviour difference — the index reproduces what Python did.
    #
    # Two conditions are needed before the instability appears at all: at least
    # two distinct key values, AND more than about sixteen rows, below which Ruby
    # uses insertion sort. Measured: with every key equal the order is preserved
    # at any length, and with two groups it reverses within each from n=17 up. A
    # test built from one delta therefore passes against an unstable sort, which
    # is how the first version of it did.
    matched.each_with_index.sort_by { |r, i| [-r['touch_delta_days'], i] }.each do |r, _i|
      delta = r['touch_delta_days']
      flag = delta.positive? ? '*' : (delta.zero? ? ' ' : '<')
      puts format(HEAD, r['title'][0, 34], r['records'], r['active_days'],
                  r['first_activity'], r['last_activity'], r['store_touched'],
                  format('%+d', delta), "#{flag} #{r['latest_nearby_record'][0, 52]}")
    end
    rows.each do |r|
      note = if r['needs_l2_label'] then '  no nearby record; needs an L2 name or tag'
             elsif r['records_all_undated'] then '  records found, none datable'
             elsif r['needs_mapping'] then '  needs a mapping entry'
             end
      next unless note

      count = r['records_all_undated'] ? r['records'].to_s : '-'
      puts format(HEAD, r['title'][0, 34], count, '', '', '', r['store_touched'], '', note)
    end
    puts '=' * 150
    deltas = matched.map { |r| r['touch_delta_days'] }
    ahead = deltas.select(&:positive?).sort
    puts "#{matched.length}/#{rows.length} items have nearby activity   " \
         "L2 more recent: #{ahead.length}   in step: #{deltas.count(&:zero?)}   " \
         "memo more recent: #{deltas.count(&:negative?)}"
    unless ahead.empty?
      puts "memo lag where L2 is more recent: median #{format('%g', median(ahead))}d, max #{ahead.last}d"
    end
    puts "#{undated_total} indexed contexts declare no date and carry none in their path."
    puts 'delta compares when each side was last written to. It does not measure ' \
         'how stale the underlying fact is, and has been seen pointing the wrong way.'
  end

  def self.main(argv)
    options = {}
    OptionParser.new do |o|
      o.banner = 'Usage: ruby l2_scan.rb [--json] [--item ITEM_ID]'
      o.on('--json', 'emit the derived aggregate as JSON') { options[:json] = true }
      o.on('--item ITEM_ID', 'show every record matched for one item id') { |v| options[:item] = v }
    end.parse!(argv)

    paths = self.paths
    mapping = read_json(paths.mapping_path)
    store = read_json(paths.store_path)
    docs, undated = load_l2(paths)

    if options[:item]
      spec = mapping['items'][options[:item]]
      abort "no mapping for #{options[:item]}" if spec.nil?

      hits = match(docs, term_list(spec['include']), term_list(spec['exclude']))
      puts "#{options[:item]}  #{spec['title']}"
      # The RAW values, not the filtered ones: --item is opened to see what the
      # mapping actually says, so an absent key must stay distinguishable from an
      # empty list and a mis-typed String must be visible as a String.
      puts "include=#{spec['include'].inspect}  exclude=#{spec['exclude'].inspect}"
      puts "#{hits.length} records near this item (nearness, not attribution):"
      hits.each do |d|
        span = d['dates'].empty? ? '(undated)' : d['dates'].join('/')
        puts format('  %-34s%-60s  %s', span, d['name'][0, 60], (d['status'] || '')[0, 30])
      end
      return
    end

    rows = derive(docs, mapping, store)
    if options[:json]
      puts JSON.pretty_generate('source' => 'L2 context store', 'claims_attribution' => false,
                                'contexts_indexed' => docs.length, 'contexts_undated' => undated,
                                'mapping_version' => mapping['version'], 'items' => rows)
    else
      puts "indexed #{docs.length} contexts\n\n"
      report(rows, undated)
    end
  end
end

L2Scan.main(ARGV) if __FILE__ == $PROGRAM_NAME
