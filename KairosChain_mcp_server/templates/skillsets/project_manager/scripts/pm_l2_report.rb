#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare the memo against L2, and render the comparison as one HTML page.
#
# Presentation over `l2_scan.rb`'s derivation, plus one addition: when the
# authored mapping has nothing to say about an item, the search terms are
# inferred from the item's own title and notes instead of the item going
# unreported. L2 is never asked to change; inference reads the memo.
#
# Read-only, and the reading is what enforces it rather than a comparison. There
# is no way to name an output path: the page always goes to `<data dir>/log/`, so
# no argument can point a write at the memo, the mapping, an L2 context, or
# `config/pm.yml`. An earlier version took `-o` and guarded it by comparing
# resolved paths, which failed three ways -- a case-only difference on a
# case-insensitive filesystem, a hardlink, and any read input that was not one of
# the two it knew about. Deleting the argument closed all three; a fourth guard
# would not have.
#
# Paths come from this file's own location and not from any hardcoded directory
# name. The script lives at `<data dir>/skillsets/project_manager/scripts/`, so
# the data dir is three levels up whatever it is called. `l2_scan` now derives
# its own the same way, so nothing here reassigns another file's constants; the
# Python version had to, because that file appended a literal `.kairos` and
# reported a relocated instance as empty.
#
# Ported from Python (2026-08-20) alongside `l2_scan.rb`. Where the port's
# behaviour differs from the original's on purpose, the whole list is at the top
# of `l2_scan.rb` -- one home, so a correction cannot land in one copy and miss
# the other. Exceptions 3, 6, 9 and 10 are reached through this file.
#
# It runs unattended from a SessionStart hook, so an exception is a defect. Every
# absence and every malformed input is reported in one line and exits: an absent
# memo is not an error (a fresh instance has none), a malformed one is. Stored
# values are not trusted to have a type: `pm_item` writes `due` and `touched_at`
# through with no check beyond a JSON type, and this SkillSet's own Ruby suite
# writes the integer 20260701 to both.
#
# Where terms come from, in order:
#
#   1. the authored mapping, when it has an entry that matches something. Kept
#      first because it is the operator's own judgment and reaches records
#      inference cannot: of 53 hand-authored terms, 43 appear nowhere in any
#      item's title or notes. They were written from knowledge of the work.
#   2. inference from the item's title and notes, when the mapping is absent or
#      matched nothing. Every row says which source it used.
#
# An authored `exclude` is NOT applied to inferred terms, and the page says so on
# the row. It was written to separate the authored include terms from a
# neighbouring subject whose name nests inside them; an inferred term is usually
# the item's own record name, which is what the exclude term is a substring of,
# so carrying it over suppressed the item's own primary record. Carrying it was
# itself a fix in an earlier round, and it turned out to trade one wrong answer
# for another.
#
# Inference is precision-first and refuses far more than it accepts. Two tiers,
# both capped by how many documents a term reaches:
#
#   tier A -- a token that is itself the name of an existing L2 document.
#   tier B -- a compound identifier (one containing an underscore).
#
# A bare English word is refused however rare it looks. And the ROW is capped,
# not only each term: if the union of everything the inferred terms match exceeds
# REACH_CAP, inference is refused for that item and the row says the terms were
# too broad. Truncating instead would have been silent, and it would have moved
# `last_activity` and the headline figures with it.
#
# Three measurements stand behind those rules, each from a reviewer who ran the
# code:
#
#   - Accepting bare words returned 51 and 82 records for the two items that in
#     fact have nearly none, because a defect is described with words like store,
#     write, file, tool, config and yaml, and those match hundreds of unrelated
#     names as substrings. With bare words refused, the same two return 2 and 17.
#   - Leaving tier A uncapped reopened the hole through a different door. A
#     document name is `name:` or `title:` or the basename, and 321 of 1177
#     contexts take it from a free-text `title:`. One context titled `Review`
#     made `review` a term reaching 351 records; titled `Context`, 1178 -- the
#     whole store.
#   - Capping each term and not the row left it open a third time. Twelve terms
#     each under the cap unioned to 124 of 1179 documents for one item, and a
#     note of the ordinary shape already reached 23.
#
# The per-term cap costs nothing measurable: of 1125 distinct document names none
# reaches more than 20, and across the 28 live items every inferred union is at
# most 20 today, so the row cap refuses nothing that currently works.
#
# Usage:
#     ruby pm_l2_report.rb            # writes <data dir>/log/pm_l2_report.html
#     ruby pm_l2_report.rb --quiet    # two lines instead of three, for the hook
#     ruby pm_l2_report.rb --open     # write, then open in a browser

require 'cgi'
require 'date'
require 'fileutils'
require 'json'
require 'optparse'

module PmL2Report
  # <data dir>/skillsets/project_manager/scripts -> <data dir>. Derived from this
  # file's position rather than from the name ".kairos", which is relocatable.
  #
  # Not __dir__: that resolves symlinks and Python's os.path.abspath(__file__)
  # does not. Symlinking the SkillSet into the distribution tree -- the obvious
  # way to edit without re-copying -- then made this derive the templates
  # directory and write the page inside a git-tracked tree, where it would ship.
  def self.script_dir = File.dirname(File.expand_path(__FILE__))
  def self.data_dir = File.expand_path('../../..', script_dir)
  def self.out_path = File.join(data_dir, 'log', 'pm_l2_report.html')

  # The largest number of L2 documents a term may reach, and also the largest
  # number of records an inferred row may end up with. See the comment at the top
  # of this file for what an uncapped tier A and an uncapped row each did.
  REACH_CAP = 20

  TOKEN = /[a-z][a-z0-9_]{3,}/.freeze

  # Python's `not d.get("resolved")`. Ruby treats 0 and "" as true, so a
  # dependency stored as `"resolved": 0` lost its chip while Python still called
  # it blocking. The values are listed because JSON can hold exactly these and no
  # other falsy ones; relying on Ruby truthiness here is what produced the defect.
  UNRESOLVED = [nil, false, 0, '', [], {}].freeze

  PREFIX = '[project_manager]'

  def self.say(message) = puts("#{PREFIX} #{message}")

  # An exception's message, flattened so it cannot break the one-line promise.
  #
  # Every message this file interpolates comes from a library, and two of them
  # are multi-line: JSON::ParserError quotes the document it choked on, and a
  # SyntaxError in the derivation quotes every offending line -- measured at 43
  # for l2_scan.rb parsed by Ruby 2.6. The hook that calls this file publishes
  # its output into a session, so an unbounded quote is an unbounded interruption.
  ONE_LINE_CAP = 160

  def self.one_line(message) = message.to_s.gsub(/[[:space:]]+/, ' ').strip[0, ONE_LINE_CAP].to_s

  # One line, then exit. Code 0 for an absence that is not a fault.
  def self.stop(message, code)
    say(message)
    exit(code)
  end

  # Load the derivation, reporting rather than raising if it is absent or broken.
  #
  # Unlike the Python original there is no bytecode to suppress: a `.pyc` written
  # inside the SkillSet sat inside Skillset#all_file_hashes and therefore inside
  # content_hash, the value recorded on chain, which made the recorded hash a
  # function of the local CPython build. Ruby writes nothing, so the guard that
  # existed for it is gone rather than translated.
  def self.load_scan
    path = File.join(script_dir, 'l2_scan.rb')
    stop("導出 l2_scan.rb が #{path} に見つかりません。SkillSet が壊れています。", 1) unless File.exist?(path)

    begin
      require_relative 'l2_scan'
    rescue ScriptError, StandardError => e
      # ScriptError as well as StandardError: a syntax error in the derivation is
      # not a StandardError, and an unattended run reports, never traces.
      stop("導出 l2_scan.rb を読み込めません: #{e.class}: #{one_line(e.message)}", 1)
    end
  end

  # Load one JSON file, or stop with one line saying which file and why.
  def self.read_json(path, label, missing_ok: false)
    unless File.exist?(path)
      return nil if missing_ok

      stop("#{label}が見つかりません（#{path}）。", 0)
    end
    begin
      raw = File.read(path, encoding: 'UTF-8')
      # File.read TAGS the encoding, it never validates it, and JSON.parse accepts
      # whatever it tags -- so the EncodingError in the rescue below cannot fire.
      # Python's open(encoding="utf-8") decoded at this boundary and raised
      # UnicodeDecodeError, which read_json reported in one line. Without this
      # check the bad bytes travel on to String#downcase, which does validate and
      # raises there instead, and on the branch where inference never runs they
      # reach the page: a file declaring charset=utf-8 that is not valid UTF-8,
      # written at exit 0 under a success message.
      stop("#{label}が UTF-8 として読めません（#{path}）。", 1) unless raw.valid_encoding?

      data = JSON.parse(raw)
    rescue SystemCallError, IOError, JSON::ParserError, EncodingError => e
      # One line, whatever the parser quotes. Ruby's JSON::ParserError embeds a
      # snippet of the document, and the snippet carries its newlines: a trailing
      # comma in a hand-edited store printed a four-line report from a hook that
      # promises one line. Python named `line 7 column 5` instead and stayed on
      # one line. The line number is not recoverable from Ruby's message, so what
      # is fixed is the shape and the length, and the wording difference is a
      # declared divergence rather than a defect.
      stop("#{label}を読めません（#{path}）: #{e.class}: #{one_line(e.message)}", 1)
    end
    stop("#{label}が object ではありません（#{path}）。", 1) unless data.is_a?(Hash)
    data
  end

  # A nested object, or {}. A truthy non-object reached .each and raised.
  def self.sub_hash(container, key)
    value = container[key]
    value.is_a?(Hash) ? value : {}
  end

  # Operator free text as a string. The store validates nothing it stores.
  def self.text_of(value)
    return value if value.is_a?(String)

    value.nil? ? '' : value.to_s
  end

  # The YYYY-MM-DD head of a stored timestamp, or "" if it is not a string.
  def self.date_prefix(value) = value.is_a?(String) ? value[0, 10] : ''

  # L2Scan's copy, not a second one here. `l2_mapping.json` is hand-edited and
  # nothing checks its shape: a bare string where a list belongs became eight
  # single-character terms in Python, one of which matched 1177 of 1177 documents
  # while displaying as the operator's own authored mapping. The check lived only
  # on this side for three rounds, and the scan raised an uncaught backtrace on
  # the same input.
  def self.term_list(value) = L2Scan.term_list(value)

  # Terms read out of the item's own title and notes. See the top of this file.
  def self.infer_terms(names, reach, item)
    text = "#{text_of(item['title'])} #{text_of(item['notes'])}".downcase
    capped = text.scan(TOKEN).uniq.select { |t| (1..REACH_CAP).cover?(reach.call(t)) }
    tier_a = capped.select { |t| names.include?(t) }.sort
    tier_b = capped.select { |t| t.include?('_') && !names.include?(t) }.sort
    tier_a + tier_b
  end

  # A date, or nil. Every date in this file is parsed here and nowhere else.
  #
  # Time and DateTime are narrowed rather than returned: a DateTime satisfies
  # `is_a?(Date)`, and returning one lets the subtraction in days_between yield a
  # Rational rather than a whole number of days.
  def self.as_date(value)
    return value.to_date if value.is_a?(Time) || value.is_a?(DateTime)
    return value if value.is_a?(Date)

    text = value.to_s[0, 10]
    # L2Scan::ISO_DAY, not a second copy here. Ruby's Date.iso8601 is looser than
    # the Python fromisoformat this was ported from -- it reads "20260701" as a
    # date and "2026-W01-1" as the Monday of week one -- so the shape is checked
    # before the value is parsed, and it is checked against the same shape the
    # scan uses. The identical copy that used to live at the top of this file was
    # deleted when the year-zero exclusion went in: two homes for one shape means
    # the next correction lands in one of them, which is the reason the median
    # was collapsed in an earlier round.
    return nil unless L2Scan::ISO_DAY.match?(text)

    begin
      # L2Scan::CALENDAR, not the default: Ruby's Date reads anything before
      # 1582-10-15 as Julian where Python's is Gregorian at every year, and the
      # rescue below turned the resulting Date::Error into "the memo marker is
      # unreadable" for a marker that was perfectly ordinary.
      Date.iso8601(text, L2Scan::CALENDAR)
    rescue ArgumentError, TypeError
      nil
    end
  end

  def self.days_between(start, finish)
    start = as_date(start)
    finish = as_date(finish)
    return nil if start.nil? || finish.nil?

    (finish - start).to_i
  end

  # One row per memo item. Iteration is over the memo, so no item can vanish.
  def self.build_rows(mapping, store, docs, now)
    names = docs.map { |d| d['name'].downcase }.to_h { |n| [n, true] }
    reach_cache = {}
    reach = lambda do |term|
      reach_cache[term] ||= docs.count { |d| d['handle'].include?(term) }
    end

    mapped = sub_hash(mapping, 'items')
    projects = sub_hash(store, 'projects').values
                                          .select { |p| p.is_a?(Hash) }
                                          .to_h { |p| [p['id'], text_of(p['name'])] }
    rows = []
    sub_hash(store, 'items').each do |item_id, item|
      next unless item.is_a?(Hash)

      spec = mapped[item_id].is_a?(Hash) ? mapped[item_id] : {}
      terms = term_list(spec['include'])
      exclude = term_list(spec['exclude'])
      records = terms.empty? ? [] : L2Scan.match(docs, terms, exclude)
      source = records.empty? ? nil : 'authored'
      if records.empty?
        # The authored exclude stops here. It was written against the authored
        # include terms; an inferred term is usually the item's own record name,
        # which the exclude term is a substring of, so applying it here dropped
        # the item's own primary record.
        exclude = []
        terms = infer_terms(names, reach, item)
        records = terms.empty? ? [] : L2Scan.match(docs, terms, [])
        if records.empty?
          source = 'none'
        elsif records.length > REACH_CAP
          # Refused rather than truncated: truncation is silent, and it moves
          # last_activity and the headline figures with it.
          source = 'too_broad'
          records = []
        else
          source = 'inferred'
        end
      end

      touched = date_prefix(item['touched_at'])
      deps = item['deps'].is_a?(Array) ? item['deps'] : []
      dated = records.select { |d| !d['dates'].empty? }
      days = dated.flat_map { |d| d['dates'] }.uniq.sort
      latest = days.empty? ? nil : as_date(days.last)
      row = {
        'id' => item_id,
        'title' => text_of(item['title']),
        'project' => (p = projects[item['project_id']]).nil? || p.empty? ? '—' : p,
        'store_status' => text_of(item['status']),
        'salience' => text_of(item['salience']),
        'due' => date_prefix(item['due']),
        'blocked_on' => deps.select { |d| d.is_a?(Hash) && UNRESOLVED.include?(d['resolved']) }
                            .map { |d| "#{text_of(d['kind'])}:#{text_of(d['ref'])}" },
        'store_touched' => touched,
        'memo_age_days' => days_between(touched, now),
        'terms' => { 'include' => terms, 'exclude' => exclude },
        'term_source' => source,
        'records' => records,
        'inferred_hits' => source == 'too_broad' ? L2Scan.match(docs, terms, []).length : nil,
        'latest_parses' => !latest.nil?,
        'marker_parses' => !as_date(touched).nil?
      }
      unless days.empty?
        row.merge!(
          'first_activity' => days.first,
          'last_activity' => days.last,
          # Distinct days, not record count: a review round-trip adds records
          # without adding work.
          'active_days' => days.length,
          'latest_nearby_record' => dated.last['name'],
          'touch_delta_days' => days_between(touched, latest)
        )
      end
      rows << row
    end
    rows
  end

  # Why a row has no comparison. Five causes, each worded for its own side.
  #
  # Collapsing any two of these has produced a false statement twice: records
  # that were perfectly datable reported as undatable, and then a memo marker
  # blamed for a date that L2 had written wrong. Which side is broken is the
  # whole content of this line, so each side gets its own sentence.
  def self.unmatched_reason(row)
    return '照合語が 1 つも作れない。題名と備考に、L2 の名前と重なる語が無い' if row['term_source'] == 'none'

    if row['term_source'] == 'too_broad'
      return "自動照合の語が広すぎる（#{row['inferred_hits']} 件に当たったので使わない）。対応表に語を書けば拾える"
    end
    return '照合語に当たる記録が無い' if row['records'].empty?
    return "#{row['records'].length} 件見つかったが、どれも日付を持たない" unless row['last_activity']

    unless row['latest_parses']
      return "記録は #{row['records'].length} 件あるが、最新として書かれた日付 " \
             "#{row['last_activity']} が日付として読めない。直すのは L2 の側"
    end

    "記録は #{row['records'].length} 件あり最新は #{row['last_activity']} だが、" \
      'memo 側の最終接触が読めない。直すのは memo の側'
  end

  def self.collect(paths, now)
    mapping = read_json(paths.mapping_path, '対応表 l2_mapping.json', missing_ok: true)
    if mapping.nil?
      # A fresh instance has no mapping and does not need one: every item falls
      # through to inference. Absence is the first-run state, not a fault.
      mapping = { 'items' => {} }
      say('対応表 l2_mapping.json がまだありません。全項目を自動照合で扱います。')
    end
    store = read_json(paths.store_path, 'memo store.json')
    stop('memo に項目がまだありません。比べるものが無いので何も出しません。', 0) if sub_hash(store, 'items').empty?

    docs, undated = L2Scan.load_l2(paths)
    { 'rows' => build_rows(mapping, store, docs, now), 'docs' => docs.length,
      'undated' => undated, 'mapping_version' => mapping['version'],
      'store_path' => paths.store_path }
  end

  def self.summary(rows)
    matched = rows.select { |r| !r['touch_delta_days'].nil? }
    deltas = matched.map { |r| r['touch_delta_days'] }
    ahead = deltas.select(&:positive?).sort
    {
      'items' => rows.length,
      'matched' => matched.length,
      'l2_newer' => ahead.length,
      'in_step' => deltas.count(&:zero?),
      'memo_newer' => deltas.count(&:negative?),
      # Median over lagging items only: including the rest would report a lag
      # smaller than any lagging item actually has. L2Scan's copy, not a second
      # one here: the two were identical and only one of them was ever tested.
      'median_lag' => L2Scan.median(ahead),
      'max_lag' => ahead.last,
      'inferred' => rows.count { |r| r['term_source'] == 'inferred' },
      'too_broad' => rows.count { |r| r['term_source'] == 'too_broad' },
      'no_terms' => rows.count { |r| r['term_source'] == 'none' },
      'bad_l2_date' => rows.count { |r| r['last_activity'] && !r['latest_parses'] },
      'no_marker' => rows.count { |r| r['last_activity'] && r['latest_parses'] && !r['marker_parses'] }
    }
  end

  CSS = <<~'CSS'
    :root { --bg:#fbfbfa; --fg:#1c1b1a; --dim:#6d6a66; --line:#e2e0dc; --card:#fff;
            --warn:#b3541e; --ok:#3d6b47; --accent:#2f5d8a; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#16151a; --fg:#e8e6e3; --dim:#98948e; --line:#2e2c33; --card:#1e1d23;
              --warn:#e0894f; --ok:#7fae8b; --accent:#7aa7d4; } }
    * { box-sizing:border-box }
    body { margin:0; padding:28px 22px 60px; background:var(--bg); color:var(--fg);
           font:14px/1.6 -apple-system,"Hiragino Sans","Noto Sans JP",sans-serif; }
    .wrap { max-width:1180px; margin:0 auto }
    h1 { font-size:19px; margin:0 0 4px; font-weight:650 }
    .sub { color:var(--dim); font-size:12.5px; margin-bottom:18px }
    .banner { background:var(--card); border:1px solid var(--line); border-left:3px solid var(--accent);
              border-radius:5px; padding:10px 14px; margin-bottom:18px; font-size:13px }
    .tiles { display:flex; flex-wrap:wrap; gap:10px; margin-bottom:22px }
    .tile { background:var(--card); border:1px solid var(--line); border-radius:6px;
            padding:9px 14px; min-width:112px }
    .tile b { display:block; font-size:21px; font-weight:650; line-height:1.25 }
    .tile span { color:var(--dim); font-size:11.5px }
    h2 { font-size:14.5px; margin:26px 0 9px; font-weight:650 }
    table { width:100%; border-collapse:collapse; background:var(--card);
            border:1px solid var(--line); border-radius:6px; overflow:hidden }
    th { text-align:left; font-size:11px; font-weight:600; color:var(--dim);
         padding:8px 9px; border-bottom:1px solid var(--line); white-space:nowrap }
    td { padding:8px 9px; border-bottom:1px solid var(--line); vertical-align:top; font-size:12.5px }
    tr:last-child td { border-bottom:none }
    .num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap }
    .d { color:var(--dim) }
    .lag { color:var(--warn); font-weight:600 }
    .same { color:var(--ok) }
    .title { font-weight:550 }
    .chip { display:inline-block; font-size:10.5px; padding:1px 6px; border:1px solid var(--line);
            border-radius:9px; color:var(--dim); margin-right:4px; white-space:nowrap }
    .chip.inf { border-color:var(--accent); color:var(--accent) }
    .bar { height:3px; background:var(--warn); border-radius:2px; margin-top:3px; opacity:.55 }
    details { margin:0 } summary { cursor:pointer; list-style:none }
    summary::-webkit-details-marker { display:none }
    summary::before { content:"▸ "; color:var(--dim) }
    details[open] summary::before { content:"▾ " }
    .recs { margin:7px 0 3px; padding:8px 10px; background:var(--bg);
            border:1px solid var(--line); border-radius:5px; font-size:11.5px }
    .recs div { padding:1.5px 0 } .recs .st { color:var(--warn) }
    .foot { margin-top:30px; color:var(--dim); font-size:11.5px; line-height:1.8;
            border-top:1px solid var(--line); padding-top:14px }
  CSS

  def self.e(text) = CGI.escapeHTML(text.nil? ? '' : text.to_s)

  # Terms as reading text. A Ruby array inspect is not operator-facing prose.
  def self.terms_text(terms) = terms.empty? ? 'なし' : terms.join('、')

  # The search terms, shown for every row including the ones that matched
  # nothing. A row that reports "no term could be built" while not showing what
  # it tried is a claim the operator cannot check at the point where it is wrong.
  def self.render_terms(row)
    origin = row['term_source'] == 'authored' ? '手書きの対応表' : '題名と備考から自動で抽出'
    out = +%(<div class="d">照合語（#{origin}）: #{e(terms_text(row['terms']['include']))})
    if !row['terms']['exclude'].empty?
      out << "　除外: #{e(terms_text(row['terms']['exclude']))}"
    elsif !%w[authored none].include?(row['term_source'])
      out << '　除外: なし（手書きの除外語は自動照合には適用しません）'
    end
    "#{out}</div>"
  end

  # The per-item record list -- the only place a record's own status appears.
  def self.render_records(row)
    return %(<div class="recs">#{render_terms(row)}</div>) if row['records'].empty?

    lines = row['records'].map do |d|
      span = d['dates'].empty? ? '(日付なし)' : d['dates'].join('/')
      status = d['status'].to_s.empty? ? '' : %( <span class="st">[#{e(d['status'])}]</span>)
      %(<div><span class="d">#{e(span)}</span>　#{e(d['name'])}#{status}</div>)
    end
    %(<details><summary class="d">#{row['records'].length} 件の近傍記録</summary>) +
      %(<div class="recs">#{render_terms(row)}#{lines.join}</div></details>)
  end

  def self.render(data, now)
    s = summary(data['rows'])
    matched = data['rows'].select { |r| !r['touch_delta_days'].nil? }
                          .sort_by { |r| [-r['touch_delta_days'], r['id']] }
    others = data['rows'].select { |r| r['touch_delta_days'].nil? }
    widest = matched.map { |r| r['touch_delta_days'] }.max || 1
    widest = 1 if widest.zero?

    tiles = [
      ["#{s['matched']}/#{s['items']}", '差を出せた項目'],
      [s['l2_newer'], 'L2 のほうが新しい'],
      [s['median_lag'].nil? ? '—' : "#{format('%g', s['median_lag'])}日", 'ずれの中央値'],
      [s['max_lag'].nil? ? '—' : "#{s['max_lag']}日", 'ずれの最大'],
      [s['in_step'], '一致している'],
      [s['memo_newer'], 'memo のほうが新しい'],
      [s['inferred'], '自動照合で拾った項目'],
      [s['too_broad'], '自動照合の語が広すぎた'],
      [s['bad_l2_date'], 'L2 の最新日付が読めない'],
      [s['no_marker'], 'memo の最終接触が読めない'],
      [s['no_terms'], '照合語が作れない']
    ]
    tile_html = tiles.map { |v, k| %(<div class="tile"><b>#{e(v)}</b><span>#{e(k)}</span></div>) }.join

    rows_html = matched.map do |r|
      delta = r['touch_delta_days']
      cls = delta.positive? ? 'lag' : (delta.zero? ? 'same' : 'd')
      bar = if delta.positive?
              width = format('%.0f', [100.0, delta.to_f / widest * 100].min)
              %(<div class="bar" style="width:#{width}%"></div>)
            else
              ''
            end
      chips = [
        %w[open].include?(r['store_status']) || r['store_status'].empty? ? nil : [r['store_status'], ''],
        r['salience'] == 'high' ? [r['salience'], ''] : nil,
        r['due'].empty? ? nil : ["締切 #{r['due']}", ''],
        *r['blocked_on'].map { |b| ["待ち #{b}", ''] },
        r['term_source'] == 'inferred' ? ['自動照合', ' inf'] : nil
      ].compact.map { |label, kind| %(<span class="chip#{kind}">#{e(label)}</span>) }.join
      <<~ROW
        <tr>
        <td><div class="title">#{e(r['title'])}</div>#{chips}
        <div class="d" style="font-size:11px">#{e(r['project'])}</div>#{render_records(r)}</td>
        <td class="num d">#{e(r['store_touched'])}<br><span style="font-size:11px">#{e(r['memo_age_days'])}日前</span></td>
        <td class="num">#{e(r['last_activity'])}<br><span class="d" style="font-size:11px">初 #{e(r['first_activity'])}</span></td>
        <td class="num #{cls}">#{format('%+d', delta)}日#{bar}</td>
        <td class="num d">#{r['records'].length}</td>
        <td class="num d">#{e(r['active_days'])}</td>
        <td class="d">#{e(r['latest_nearby_record'])}</td>
        </tr>
      ROW
    end.join

    other_html = others.map do |r|
      %(<tr><td><div class="title">#{e(r['title'])}</div>) +
        %(<div class="d" style="font-size:11px">#{e(r['project'])}</div>#{render_records(r)}</td>) +
        %(<td class="num d">#{r['store_touched'].empty? ? '（無し）' : e(r['store_touched'])}</td>) +
        %(<td class="d">#{e(unmatched_reason(r))}</td></tr>)
    end
    other_html << %(<tr><td colspan="3" class="d">なし — 全項目で差が出せています。</td></tr>) if other_html.empty?

    <<~HTML
      <!DOCTYPE html><html lang="ja"><meta charset="utf-8">
      <title>project_manager — memo と L2 の突き合わせ</title>
      <meta name="viewport" content="width=device-width,initial-scale=1"><style>#{CSS}</style>
      <div class="wrap">
      <h1>project_manager — memo と L2 の突き合わせ</h1>
      <div class="sub">生成 #{e(now.strftime('%Y-%m-%dT%H:%M:%S'))}　L2 文脈 #{data['docs']} 件を索引（うち日付を持たないもの #{data['undated']} 件）　対応表 v#{e(data['mapping_version'])}</div>
      <div class="banner"><b>この頁は読むだけです。</b>出力先は固定で、引数では変えられません。だから memo（<code>#{e(File.basename(data['store_path']))}</code>）にも、対応表にも、L2 の文脈にも、書き込む経路がありません。
      また、ある記録がある項目に<b>属すること</b>は主張していません。示しているのは「その項目の照合語に名前・経路・tag が一致した記録」であって、
      1 つの記録が複数の項目の近くに正しく現れます。反映するかどうかは操作者の判断です。</div>
      <div class="tiles">#{tile_html}</div>

      <h2>差を出せた項目（ずれの大きい順）</h2>
      <table><tr>
      <th>項目</th><th class="num">memo 最終</th><th class="num">L2 最終</th>
      <th class="num">差</th><th class="num">記録</th><th class="num">活動日</th><th>直近の近傍記録（この項目の状態ではない）</th>
      </tr>#{rows_html}</table>

      <h2>差を出せなかった項目</h2>
      <table><tr><th>項目</th><th class="num">memo 最終</th><th>理由</th></tr>#{other_html.join}</table>

      <div class="foot">
      <b>「差」</b>は memo と L2 の<b>どちらが最後に書かれたか</b>を比べた日数です。事実がどれだけ古いかではありません。実際に逆を指した例があります —
      memo のほうが新しく見えた 1 件は、L2 が記録した 3 週間後に操作者が手で入れた却下で、事実としては memo のほうが 3 週間古いものでした。<br>
      <b>「活動日」</b>は記録の件数ではなく、記録が書かれた<b>異なる日数</b>です。レビューが往復すると件数は増えますが、仕事量は増えていません。<br>
      <b>「自動照合」</b>の印がある行は、手書きの対応表に項目が無いか、あっても何も一致しなかったので、その項目の題名と備考から照合語を作った行です。
      拾えるのは L2 の文書名そのものと、下線を含む複合語で、いずれも L2 で #{REACH_CAP} 件以下にしか当たらないものだけです。
      <code>store</code> <code>config</code> のような普通の語は拒否します。さらに、<b>その行が集めた記録の合計</b>も #{REACH_CAP} 件以下でなければ、自動照合そのものを使いません。
      上限を語ごとにしか掛けなかったとき、各語は上限内なのに合計 124 件になった例があります。切って見せるのではなく使わないのは、切ると
      「最新の記録」と見出しの数字が黙って動くからです。<br>
      <b>手書きの除外語は、自動照合には適用しません。</b>除外語は手書きの照合語に対して書かれたもので、自動で選ばれた語は多くの場合その項目自身の記録名です。
      適用すると、その項目自身の記録が落ちました。<br>
      差が出せない理由は5つに書き分けています。照合語が作れない／自動照合の語が広すぎる／記録が日付を持たない／<b>L2 の最新日付が読めない</b>／<b>memo 側の最終接触が読めない</b>。
      最後の2つは壊れている側が違うので、同じ文にしません。<br>
      各記録自身の状態は、項目を展開したときの一覧にだけ出ます。要約の列には出しません。1 行が 1 記録だと分かる場所でしか読めないようにするためです。<br>
      照合は記録の<b>名前・経路・tag</b> のみで、本文は見ません（本文照合は 2026-07-27 の実測で精度およそ 25%）。
      </div></div></html>
    HTML
  end

  # Best effort. macOS has `open`, Linux has `xdg-open`, and the gem ships to both.
  def self.open_in_browser(path)
    %w[open xdg-open].each do |binary|
      return if system(binary, path, out: File::NULL, err: File::NULL)
    end
    say('開くための open / xdg-open が見つかりません。上の経路を手で開いてください。')
  end

  def self.parse_options(argv)
    options = {}
    parser = OptionParser.new do |o|
      o.banner = 'Usage: ruby pm_l2_report.rb [--quiet] [--open]'
      o.on('--quiet', 'two lines instead of three, for a session-start hook') { options[:quiet] = true }
      o.on('--open', 'open the written page in the default browser') { options[:open_after] = true }
    end
    begin
      parser.parse!(argv)
    rescue OptionParser::ParseError => e
      warn "#{parser.program_name}: unrecognized arguments: #{e.message}"
      exit(2)
    end
    unless argv.empty?
      warn "#{parser.program_name}: unrecognized arguments: #{argv.join(' ')}"
      exit(2)
    end
    options
  end

  def self.main(argv)
    options = parse_options(argv)
    load_scan
    now = Time.now
    data = collect(L2Scan.paths(data_dir), now.to_date)
    page = render(data, now)

    begin
      FileUtils.mkdir_p(File.dirname(out_path))
      File.write(out_path, page, encoding: 'UTF-8')
    rescue SystemCallError, IOError => e
      stop("出力を書けません（#{out_path}）: #{e.class}: #{e.message}", 1)
    end

    s = summary(data['rows'])
    lag = if s['median_lag'].nil?
            ''
          else
            "、ずれ中央値 #{format('%g', s['median_lag'])}日 / 最大 #{s['max_lag']}日"
          end
    say("memo #{s['items']} 項目のうち #{s['l2_newer']} 件で L2 のほうが新しい#{lag}" \
        '（帰属は主張しません。近くに何が書かれたかだけです）。')
    unless options[:quiet]
      puts "  差を出せた項目 #{s['matched']}/#{s['items']}" \
           "（自動照合 #{s['inferred']}、語が広すぎ #{s['too_broad']}、" \
           "L2 の日付が読めない #{s['bad_l2_date']}、memo の最終接触が読めない #{s['no_marker']}、" \
           "照合語が作れない #{s['no_terms']}）"
    end
    puts "  #{out_path}"
    open_in_browser(out_path) if options[:open_after]
  end
end

PmL2Report.main(ARGV) if __FILE__ == $PROGRAM_NAME
