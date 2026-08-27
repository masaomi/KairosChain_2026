# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'timeout'
require 'rbconfig'
require 'stringio'

HERE = __dir__
require_relative '../hooks/readable_gate'

G = KairosHookProjector::ReadableGate

class TestReadableGate < Minitest::Test
  SCRIPT = File.join(File.dirname(HERE), 'hooks', 'readable_gate.rb')

  # One heading over a cap of three: the shortest text that makes a blocking
  # gate actually block, so that "enforcement still runs" is falsifiable.
  FOUR_HEADINGS = "# a\n# b\n# c\n# d\n"

  def cfg(overrides = {})
    raw = { 'mode_name' => 'test', 'section' => '§ Test' }.merge(overrides)
    G::Config.new(raw, '<inline>')
  end

  # What Claude Code writes into the transcript when THIS gate blocks.
  #
  # Inert since 2026-08-26 and deliberately kept: the recheck used to read this
  # text back and infer from it which block was its own, and the inference is
  # what six rounds of review broke. Fixtures still put it in the transcript so
  # that "the gate ignores it" is falsifiable. The preface is written out here
  # rather than taken from the gate, because a fixture that borrows the value it
  # is testing against cannot fail when the value is wrong.
  BLOCK_PREFACE = 'Stop hook feedback:'

  def own_marker(detail = '- x', mode: 'test')
    "#{BLOCK_PREFACE}\n#{G::OWN_BLOCK_REASON}#{mode} § Test:\n#{detail}"
  end

  # What another blocking Stop hook writes. Same preface, no reason of this
  # gate's. Taken verbatim from the shape found live in this project: records
  # 267 and 270 of session 9fb5b88e, 7.0s apart with the foreign one newer.
  def foreign_marker(detail = '[agent を 1 周だけ走らせ…]')
    "#{BLOCK_PREFACE}\n#{detail}"
  end

  def measure(text, overrides = {})
    G.measure(text, cfg(overrides), nil)
  end

  # Drive the real script end to end and return what it emitted.
  #
  # Deliberately a subprocess: an in-test reimplementation of main cannot fail
  # when main breaks. The first version of these tests copied the decision logic
  # instead of driving it, and a mutation that removed the blocking check left
  # them green.
  #
  # The hard timeout is here as well as inside the gate. A mutation that removes
  # the gate's own bound must fail this suite, not hang it — a falsification
  # harness that never returns cannot report anything, and one that is killed
  # mid-run leaves the source mutated.
  def decide(text, rechecked: false, **overrides)
    raw = { 'mode_name' => 'test', 'section' => '§ Test' }
           .merge(overrides.transform_keys(&:to_s))
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, JSON.generate(
        'type' => 'assistant',
        'message' => { 'content' => [{ 'type' => 'text', 'text' => text }] }
      ) + "\n", encoding: 'UTF-8')

      out, err, status = run_script(
        cfg_path,
        JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => rechecked)
      )
      assert_equal 0, status.exitstatus, "gate exited #{status.exitstatus}: #{err[0, 300]}"
      out.strip.empty? ? {} : JSON.parse(out)
    end
  end

  def run_script(cfg_path, stdin_json, extra = [])
    out = err = nil
    status = nil
    Timeout.timeout(30) do
      out, err, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, '--config', cfg_path, *extra, stdin_data: stdin_json
      )
    end
    # The gate emits UTF-8 bytes; under a US-ASCII default external encoding
    # (LANG=C) Ruby tags the captured pipes US-ASCII and the first string op raises.
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), status]
  rescue Timeout::Error
    raise Minitest::Assertion, 'gate did not return within 30s'
  end

  # Every run writes its own log inside the temporary directory, and the log is
  # yielded alongside the process result.
  #
  # Asserting only "exit 0 and no block" is satisfied by a gate that died on its
  # first line: the outermost rescue turns any error into exit 0 with no output,
  # so absence-only assertions pass under every mutation that breaks the gate
  # outright. A log record is the positive evidence that the gate reached a
  # verdict, and it is what makes a fail-open case falsifiable at all.
  def run_raw(content, config, extra = [])
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'gate.log')
      File.write(cfg_path, JSON.generate({ 'log_path' => log_path }.merge(config)), encoding: 'UTF-8')
      File.write(tx_path, content, encoding: 'UTF-8')
      out, err, status = run_script(
        cfg_path,
        JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => false),
        extra
      )
      log = File.exist?(log_path) ? File.read(log_path, encoding: 'UTF-8') : ''
      yield out, err, status, tx_path, log
    end
  end

  # --- shape limits ---------------------------------------------------------

  def test_limits_are_off_when_the_mode_does_not_set_them
    m, f = measure((0...500).map { |i| "line #{i}" }.join("\n"))
    assert_empty f, 'no thresholds means no failures'
    assert_equal 500, m['lines'], 'metrics still measured'
  end

  def test_each_limit_fires_independently
    long_text = (0...70).map { |i| "line #{i}" }.join("\n")
    _, f = measure(long_text, 'max_lines' => 60)
    assert f.any? { |x| x.start_with?('LENGTH') }, f.inspect

    _, f = measure("# a\n## b\n### c\n#### d\n", 'max_headings' => 3)
    assert f.any? { |x| x.start_with?('HEADINGS') }, f.inspect

    tables = (['| a | b |', '|---|---|', '| 1 | 2 |'] * 3).join("\n")
    _, f = measure(tables, 'max_tables' => 2)
    assert f.any? { |x| x.start_with?('TABLES') }, f.inspect
  end

  def test_announcement_exempts_length_only
    long_text = "This answer is long.\n" + (0...70).map { |i| "line #{i}" }.join("\n")
    _, f = measure(long_text, 'max_lines' => 60, 'max_headings' => 3,
                              'announce_patterns' => ['(?i:\blong\b)'])
    assert_empty f, 'announcement exempts length'
  end

  def test_fenced_code_does_not_count_toward_length
    text = "intro\n```\n" + (['x'] * 200).join("\n") + "\n```\nend\n"
    m, f = measure(text, 'max_lines' => 60)
    assert_empty f, 'code block excluded'
    assert_equal 3, m['lines'], 'prose lines counted'
  end

  # --- the diagram floor ----------------------------------------------------
  #
  # Every other threshold here is a cap. This one is a floor, and it is the only
  # rule in the section that says what a message should contain rather than what
  # it should stay under. A fenced block is what a diagram is made of.

  def test_diagrams_are_counted_by_opening_not_by_fence
    text = "a\n```\nfigure one\n```\nb\n```\nfigure two\n```\nc\n"
    m, = measure(text)
    assert_equal 2, m['diagrams'], 'four fence lines, two diagrams'
    # a, b, c and the empty line the trailing newline leaves behind.
    assert_equal 4, m['lines'], 'and the diagrams are still out of the line count'
  end

  def test_a_long_explanation_carrying_no_diagram_is_caught
    text = (0...40).map { |i| "散文の行 #{i}" }.join("\n")
    _, f = measure(text, 'diagram_required_over_lines' => 30)
    assert f.any? { |x| x.start_with?('DIAGRAM') }, f.inspect
  end

  def test_one_diagram_clears_the_floor
    text = (0...40).map { |i| "散文の行 #{i}" }.join("\n") + "\n```\nA -> B\n```\n"
    _, f = measure(text, 'diagram_required_over_lines' => 30)
    assert_empty f.select { |x| x.start_with?('DIAGRAM') }, f.inspect
  end

  # The length cap yields to an announcement; this floor does not. Announcing
  # that a message is long says nothing about whether prose was the right
  # carrier for what is in it, so the two exemptions must not be shared.
  def test_announcing_the_length_does_not_clear_the_diagram_floor
    text = "長いです。\n" + (0...40).map { |i| "散文の行 #{i}" }.join("\n")
    _, f = measure(text, 'diagram_required_over_lines' => 30, 'max_lines' => 30,
                         'announce_patterns' => ['長い'])
    assert_empty f.select { |x| x.start_with?('LENGTH') }, 'the announcement clears length'
    assert f.any? { |x| x.start_with?('DIAGRAM') }, f.inspect
  end

  def test_the_floor_is_off_unless_the_mode_names_a_number
    text = (0...200).map { |i| "散文の行 #{i}" }.join("\n")
    _, f = measure(text)
    assert_empty f, 'the core supplies no floor of its own'
  end

  # --- vocabulary: the case that misfired in production ---------------------

  MASA_SHORTHAND =
    '(?<![A-Za-z0-9_])([A-Z]{1,4}★|[A-Z]{2,5}-\d+|[PR]\d+' \
    '|(?![vV]\d)[a-z]\d{1,2})(?![A-Za-z0-9_.]\d*)'
  GLOSS = ['[（(＝=]', '——', '—', '\bとは\b'].freeze
  SPECIMEN =
    '[（(]\s*[`\'"]?(?:[A-Z]{2,5}-\d+|[a-z]\d{1,2})[`\'"]?' \
    '(?:\s*[、,／/]\s*[`\'"]?(?:[A-Z]{2,5}-\d+|[a-z]\d{1,2})[`\'"]?)+\s*[）)]'

  def vocab(text)
    _, f = measure(text, 'shorthand_patterns' => [MASA_SHORTHAND],
                         'gloss_patterns' => GLOSS, 'vocab_min_lines' => 1)
    f
  end

  def spec(text)
    _, f = measure(text, 'shorthand_patterns' => [MASA_SHORTHAND],
                         'gloss_patterns' => GLOSS,
                         'specimen_patterns' => [SPECIMEN], 'vocab_min_lines' => 1)
    f
  end

  def test_coined_shorthand_without_a_gloss_is_caught
    %w[t0 a9 INV-22 P0 R2].each do |token|
      f = vocab("#{token} が壊れます。\n")
      assert f.any? { |x| x.include?('VOCABULARY') }, "#{token} -> #{f.inspect}"
    end
  end

  def test_an_inline_gloss_clears_it
    f = vocab("INV-22（事後の読み手を禁じる規則）が効きます。\n")
    assert_empty f, 'gloss on the same line clears'
    f = vocab("t0 は次の行で説明します。\n打ち手が最初に発話した時刻（手番の起点）。\n")
    assert_empty f, 'gloss on the next line clears'
  end

  def test_identifiers_are_not_coined_shorthand
    # 2026-08-12: an unbounded \d+ flagged `c341361` — a git commit id — and
    # blocked a message that merely cited one. Bounding the digit count is the
    # fix; these are the shapes that must stay silent.
    %w[c341361 f149134 4867dbb 7c84f718 3.64.0 v0.4.6].each do |token|
      f = vocab("commit #{token} を参照。\n")
      assert_empty f, "#{token} -> #{f.inspect}"
    end
  end

  def test_a_specimen_list_exhibits_tokens_rather_than_using_them
    # 2026-08-12: the gate blocked the message that explained the vocabulary
    # rule, because explaining it requires naming the shapes it governs.
    f = spec("本物の略号は短く（`t0`、`a9`）、識別子は長い。\n")
    assert_empty f, 'specimen list is exempt'
  end

  def test_a_specimen_exemption_does_not_leak_to_real_use
    ["`t0` を日付けることは例外ではない。\n",
     "（INV-24 が防ごうとした失敗）\n",
     "五席すべてが「`t0` を置ける者がいない」を挙げました。\n"].each do |text|
      f = spec(text)
      assert f.any? { |x| x.include?('VOCABULARY') }, "#{text[0, 18]} -> #{f.inspect}"
    end
  end

  def test_a_single_token_in_an_aside_is_a_citation_not_a_specimen
    f = spec("この失敗は（INV-24）で防げます。\n")
    assert f.any? { |x| x.include?('VOCABULARY') }, f.inspect
  end

  def test_only_the_first_use_is_reported
    f = vocab("t0 が壊れ、t0 がまた壊れ、t0 が三度壊れる。\n")
    assert_equal 1, f.sum { |x| x.scan('t0').length }, f.inspect
  end

  def test_short_notes_are_below_the_vocabulary_floor
    _, f = measure("R2 の改訂に入ります。\n",
                   'shorthand_patterns' => [MASA_SHORTHAND],
                   'gloss_patterns' => GLOSS, 'vocab_min_lines' => 8)
    assert_empty f, 'a one-line progress note is not an explanation'
  end

  # --- the decision seam: driven, never reimplemented ------------------------

  def test_blocking_false_reports_without_stopping_the_turn
    # mode_hooks/_schema.json documents `blocking` as "whether a failure stops
    # the turn (true) or is reported only (false)", and the compiler writes it
    # into every gate config. Until 2026-08-12 nothing read it.
    out = decide("# a\n## b\n### c\n#### d\n", max_headings: 3, blocking: false)
    refute out.key?('decision'), out.inspect
    assert_includes out['systemMessage'], 'FAIL'
    assert_includes out['systemMessage'], 'advisory'
  end

  def test_blocking_defaults_to_true
    out = decide("# a\n## b\n### c\n#### d\n", max_headings: 3)
    assert_equal 'block', out['decision'], out.inspect
  end

  # A failing rewrite is still measured and still reported; it is simply never
  # blocked a second time. A note has to be present for a verdict to be issued
  # at all — see "a recheck with no note issues no verdict" below.
  def test_a_rewrite_is_measured_and_reported_but_never_blocked_again
    out, log = drive(blocked_then(row_for('assistant', text: "# a\n## b\n### c\n#### d\n",
                                          uuid: 'BBB')),
                     note: 'AAA', max_headings: 3)
    refute out.key?('decision'), out.inspect
    assert_includes out.fetch('systemMessage', ''), 'FAIL'
    assert_includes out.fetch('systemMessage', ''), 'recheck'
    assert_includes log, 'RECHECK-FAIL', log.inspect
  end

  # --- the recheck must judge the rewrite, not what it already judged --------
  #
  # Until 2026-08-20 it judged what it had already judged. The blocked message
  # is still the newest record carrying text when the recheck runs, so the
  # existing wait — which only engages when the newest record has no text —
  # never engaged: over one instance's first 768 log records, 140 of 140
  # rechecks took the newest record immediately, and 110 of 140 reported
  # metrics identical to the verdict that had just blocked. Re-measuring 145
  # real rewrites from the transcripts showed 101 of them passing while the log
  # recorded RECHECK-FAIL. The two sweeps are two hours apart and are not one
  # evidence base.

  def row_for(type, text: nil, uuid: nil, parent: nil, thinking: false)
    content =
      if thinking then [{ 'type' => 'thinking', 'thinking' => 'x' }]
      elsif type == 'user' then text
      else [{ 'type' => 'text', 'text' => text }]
      end
    row = { 'type' => type, 'message' => { 'content' => content } }
    row['uuid'] = uuid if uuid
    row['parentUuid'] = parent if parent
    row
  end

  def rows_json(rows)
    rows.map { |r| JSON.generate(r) }.join("\n") + "\n"
  end

  # Drive the real script over a hand-built transcript and hand back both the
  # emitted object and the log. The log is what carries `rec=`, and a verdict
  # that names no record cannot be checked for naming the right one.
  # Drive the real script over a transcript, optionally with a carry-over note
  # already in place.
  #
  # `note:` is the uuid this gate is to have blocked. The note is written by
  # calling the gate's own write_note rather than by composing the file here: a
  # fixture that writes its own copy of the format stops driving the seam the
  # moment the two disagree, and disagreeing silently is the failure mode the
  # note replaced. `note_at:` shifts the recorded timestamp, which is the only
  # way to reach the staleness branch without sleeping.
  #
  # There is deliberately no parameter for writing the note somewhere else. A
  # note under a different mode or transcript lands at a different path, so the
  # gate finds none at all rather than a mismatched one; the mismatch branch is
  # reached only by a note that is at the right path and unusable, which "a note
  # that does not check out is refused" builds by hand.
  def drive(rows, rechecked: true, note: nil, note_at: nil, **overrides)
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'gate.log')
      raw = { 'mode_name' => 'test', 'section' => '§ Test', 'log_path' => log_path }
            .merge(overrides.transform_keys(&:to_s))
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json(rows), encoding: 'UTF-8')

      if note
        note_cfg = G::Config.new(raw, cfg_path)
        failure = G.write_note(tx_path, note_cfg, note)
        assert_nil failure, "the fixture could not write its note: #{failure}"
        backdate_note(tx_path, note_cfg, note_at) if note_at
      end

      out, err, status = run_script(
        cfg_path,
        JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => rechecked)
      )
      assert_equal 0, status.exitstatus, "gate exited #{status.exitstatus}: #{err[0, 300]}"
      log = File.exist?(log_path) ? File.read(log_path, encoding: 'UTF-8') : ''
      [out.strip.empty? ? {} : JSON.parse(out), log]
    end
  end

  # Rewrite only the timestamp of a note the gate wrote. Everything else stays
  # as write_note produced it, so a fixture testing staleness is not also
  # testing a hand-built file.
  def backdate_note(tx_path, note_cfg, seconds_ago)
    path = G.note_path(tx_path, note_cfg)
    data = JSON.parse(File.read(path))
    data['at'] = Time.now.to_f - seconds_ago
    File.write(path, JSON.generate(data))
    path
  end

  BLOCKED = "# a\n# b\n# c\n# d\n"
  REWRITE = "# a\n"

  # A transcript in which this gate blocked record AAA. The feedback record is
  # still here because Claude Code really does write it, and because a gate that
  # started reading it again would pass fixtures that omitted it.
  #
  # Pair every use with `note: 'AAA'` on drive. The two together are what "this
  # gate blocked here" now means: the transcript shows the block happened, the
  # note says it was this gate's.
  def blocked_then(*after)
    [row_for('assistant', text: BLOCKED, uuid: 'AAA'),
     row_for('user', text: own_marker("- HEADINGS: 4 (cap 3)."), parent: 'AAA',
                     uuid: 'MMM')] + after
  end

  def test_the_recheck_judges_the_rewrite_not_the_message_it_already_judged
    out, log = drive(blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB')),
                     note: 'AAA', max_headings: 3)
    assert_includes out.fetch('systemMessage', ''), 'PASS', out.inspect
    assert_includes out.fetch('systemMessage', ''), '1 headings',
                    'the rewrite has one heading; the blocked message had four'
    assert_includes log, 'rec=BBB', "the verdict must name the rewrite: #{log.inspect}"
    refute out.key?('decision')
  end

  def test_a_recheck_whose_rewrite_has_not_landed_records_no_verdict
    out, log = drive(blocked_then, note: 'AAA', max_headings: 3)
    assert_includes log, 'SKIP-awaiting-rewrite', log.inspect
    refute_includes log, 'RECHECK-FAIL',
                    'a verdict on the already-judged record is the defect itself'
    assert_includes out.fetch('systemMessage', ''), 'NOT RUN'
    refute out.key?('decision')
  end

  def test_the_blocked_record_is_never_judged_again_even_when_it_is_the_newest
    # Ordering that only a truncated tail or a rewritten transcript produces.
    # Position is what excludes the blocked record now: everything at or before
    # it is older by construction, so a walk that starts one past it cannot
    # reach it. A walk written as "at or after" instead of "after" fails here
    # and nowhere else.
    rows = [row_for('assistant', text: REWRITE, uuid: 'BBB'),
            row_for('user', text: own_marker, parent: 'AAA', uuid: 'MMM'),
            row_for('assistant', text: BLOCKED, uuid: 'AAA')]
    _out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes log, 'SKIP-awaiting-rewrite', log.inspect
    refute_includes log, 'rec=AAA', 'AAA is the record the note names'
    refute_includes log, 'rec=BBB', 'BBB lies before it, so it is older, not a rewrite'
  end

  # Two blocks in one session. The note names the second, so the first block's
  # rewrite is out of reach — which is the property the marker walk lost when it
  # was widened to step over foreign markers.
  def test_the_note_names_this_turns_block_not_an_earlier_one
    rows = [row_for('assistant', text: BLOCKED, uuid: 'AAA'),
            row_for('user', text: own_marker, parent: 'AAA', uuid: 'M1'),
            row_for('assistant', text: "#{BLOCKED}# e\n", uuid: 'BBB'),
            row_for('user', text: own_marker, parent: 'BBB', uuid: 'M2'),
            row_for('assistant', text: REWRITE, uuid: 'CCC')]
    out, log = drive(rows, note: 'BBB', max_headings: 3)
    assert_includes log, 'rec=CCC', log.inspect
    assert_includes out.fetch('systemMessage', ''), 'PASS'

    # The same transcript with the older block's note: everything after AAA is
    # in reach, and the newest of it is CCC, so the verdict is the same record.
    # What differs is what the gate would have done had the rewrite not landed.
    _out2, older = drive(rows[0..3], note: 'AAA', max_headings: 3)
    assert_includes older, 'rec=BBB', "AAA's rewrite is BBB: #{older}"
  end

  def test_a_recheck_with_no_note_issues_no_verdict
    # The fallback this replaces looked conservative and was the opposite: the
    # newest record it reached is the message this turn has just blocked, so it
    # re-judged it — reachable on any block after a session's first, and logged
    # as an ordinary verdict. A recheck never blocks, so declining to judge
    # costs only the line.
    out, log = drive([row_for('assistant', text: BLOCKED, uuid: 'AAA')], max_headings: 3)
    assert_includes log, 'SKIP-nonote', log.inspect
    refute_includes log, 'rec=AAA', 'AAA is the message that was just blocked'
    assert_includes out.fetch('systemMessage', ''), 'NOT RUN'
    refute out.key?('decision')
  end

  def test_the_first_read_is_unchanged_and_names_the_record_it_judged
    out, log = drive([row_for('assistant', text: BLOCKED, uuid: 'AAA')],
                     rechecked: false, max_headings: 3)
    assert_equal 'block', out['decision'], out.inspect
    assert_includes log, 'rec=AAA', log.inspect
    refute_includes log, 'nonote', 'a first read has no note to look for'
  end

  # The recheck's own flush race, driven with a real late write. The rewrite
  # record appears only after the first read has already come back empty.
  def test_the_recheck_waits_for_the_rewrite_to_land
    Dir.mktmpdir do |tmp|
      tx = File.join(tmp, 't.jsonl')
      c = cfg('log_path' => File.join(tmp, 'gate.log'))
      File.write(tx, rows_json(blocked_then), encoding: 'UTF-8')
      assert_nil G.write_note(tx, c, 'AAA')
      writer = Thread.new do
        sleep(G::POLL_DELAY * 3)
        File.write(tx, rows_json([row_for('assistant', text: 'landed late', uuid: 'BBB')]),
                   mode: 'a', encoding: 'UTF-8')
      end
      begin
        text, why, record_id = G.last_assistant_text(tx, c, true)
      ensure
        writer.join
      end
      assert_equal 'landed late', text
      assert_equal 'ok-after-wait', why
      assert_equal 'BBB', record_id
    end
  end

  # --- what round 1 of the 2026-08-21 review found the tests above missed ----
  #
  # Every fixture below was written against a mutation that the original seven
  # left green. A behaviour no mutation can kill is untested however many
  # assertions surround it.
  #
  # Three fixtures that stood here were retired on 2026-08-26 with the mechanism
  # they held: waiting for the marker as well as the rewrite, preferring the
  # newest marker to the oldest, and refusing a user record that merely mentions
  # the wording. None of them has anything left to fail against — the recheck
  # reads a note this gate wrote and never looks at the transcript's feedback
  # text at all. What replaced the first of them is below; the other two are
  # covered by "the note names this turn's block, not an earlier one".

  # The note is taken once, before the polling begins. Taking it inside the loop
  # spends it on attempt zero and finds nothing on attempt one, so a rewrite that
  # is even slightly late loses its verdict — with every unit fixture green,
  # because a note taken once and a note taken forty times are the same thing
  # whenever the rewrite has already landed.
  def test_the_note_is_taken_before_the_wait_not_during_it
    Dir.mktmpdir do |tmp|
      tx = File.join(tmp, 't.jsonl')
      c = cfg('log_path' => File.join(tmp, 'gate.log'))
      File.write(tx, rows_json(blocked_then), encoding: 'UTF-8')
      assert_nil G.write_note(tx, c, 'AAA')

      writer = Thread.new do
        sleep(G::POLL_DELAY * 3)
        File.write(tx, rows_json([row_for('assistant', text: REWRITE, uuid: 'BBB')]),
                   mode: 'a', encoding: 'UTF-8')
      end
      begin
        text, why, record_id = G.last_assistant_text(tx, c, true)
      ensure
        writer.join
      end
      assert_equal REWRITE, text, 'the note must outlive the first poll'
      assert_equal 'ok-after-wait', why
      assert_equal 'BBB', record_id
    end
  end

  # Superseded by round 2, and the comment that stood here said the opposite of
  # what ships: it recorded the round-1 ruling that the recheck searches backward
  # for text. Backward search happens only after the budget is spent — inside it,
  # the newest record is waited for. What this fixture still witnesses is the
  # outcome, which both shapes share: a rewrite under a later text-less record is
  # measured rather than called absent.
  def test_a_rewrite_behind_a_later_textless_record_is_still_measured
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB'),
                        row_for('assistant', uuid: 'CCC', thinking: true))
    out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes log, 'rec=BBB', log.inspect
    refute_includes log, 'awaiting-rewrite',
                    'the rewrite was in the tail; a trailing thinking record must not hide it'
    assert_includes out.fetch('systemMessage', ''), 'PASS', out.inspect
  end

  # This project discusses its own gate, so an assistant message opening with
  # Claude Code's feedback wording is not hypothetical. It is a rewrite like any
  # other and must be measured as one.
  def test_a_rewrite_that_quotes_the_feedback_wording_is_still_a_rewrite
    rows = blocked_then(row_for('assistant', text: "Stop hook feedback: 見出しなし\n", uuid: 'BBB'))
    _out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes log, 'rec=BBB', log.inspect
    refute_includes log, 'awaiting-rewrite', log.inspect
  end

  # The give-up exits used to be silent in exactly the cases they occur in, and
  # one of them borrowed the name of another. Each has to name itself.
  def test_a_recheck_that_finds_nothing_says_which_nothing_it_found
    _out, no_note = drive([row_for('assistant', uuid: 'AAA', thinking: true)], max_headings: 3)
    assert_includes no_note, 'SKIP-nonote', no_note.inspect
    refute_includes no_note, 'awaiting-rewrite',
                    'there was no note, so the rewrite was never the question'

    _out2, waiting = drive(blocked_then, note: 'AAA', max_headings: 3)
    assert_includes waiting, 'SKIP-awaiting-rewrite', waiting.inspect
    refute_includes waiting, 'nonote', 'the note was there; the rewrite was not'

    _out3, gone = drive([row_for('user', text: 'hello')], note: 'AAA', max_headings: 3)
    assert_includes gone, 'SKIP-blocked-record-gone', gone.inspect
    refute_includes gone, 'awaiting-rewrite', gone.inspect
  end

  # A rewrite carrying no uuid at all must still be measured. The exclusion is
  # positional now, so a missing uuid cannot be mistaken for the blocked one —
  # but the walk still has to survive reading it.
  def test_a_rewrite_with_no_uuid_is_measured_rather_than_skipped
    rows = [row_for('assistant', text: BLOCKED, uuid: 'AAA'),
            row_for('user', text: own_marker, uuid: 'MMM'),
            row_for('assistant', text: REWRITE)]
    out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes out.fetch('systemMessage', ''), 'PASS', out.inspect
    refute_includes log, 'awaiting-rewrite', log.inspect
  end

  # The budget's length is a claim in its own right, and nothing witnessed it:
  # cutting forty attempts back to the first read's fifteen left the whole suite
  # green. A rewrite that lands after 1.5s and before 4s is the only thing that
  # can tell the two budgets apart.
  def test_the_recheck_budget_outlasts_the_first_read_s
    Dir.mktmpdir do |tmp|
      tx = File.join(tmp, 't.jsonl')
      c = cfg('log_path' => File.join(tmp, 'gate.log'))
      File.write(tx, rows_json(blocked_then), encoding: 'UTF-8')
      assert_nil G.write_note(tx, c, 'AAA')
      writer = Thread.new do
        sleep((G::POLL_ATTEMPTS * G::POLL_DELAY) + 0.4)
        File.write(tx, rows_json([row_for('assistant', text: REWRITE, uuid: 'BBB')]),
                   mode: 'a', encoding: 'UTF-8')
      end
      begin
        text, why, record_id = G.last_assistant_text(tx, c, true)
      ensure
        writer.join
      end
      assert_equal REWRITE, text,
                   "a rewrite landing after the first read's budget must still be caught"
      assert_equal 'ok-after-wait', why
      assert_equal 'BBB', record_id
    end
  end

  # Every other fixture uses a three-character uuid, so nothing witnessed the
  # truncation against the thirty-six-character uuids production writes.
  def test_the_rec_column_carries_only_the_first_eight_characters
    long = 'abcdefgh-1234-5678-9abc-def012345678'
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: long))
    _out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes log, "rec=abcdefgh\t", log.inspect
    refute_includes log, "rec=#{long}", 'the whole uuid would push the metrics off the line'
  end

  # --- what round 2 of the review found the fixtures above still missed ------

  def second_block(*after)
    # A session already blocked once: the first rewrite passed and was
    # delivered, the operator asked something else, and that answer was blocked
    # too. Everything up to and including CCC is on disk. Pair with note: 'CCC'
    # for the second block, note: 'AAA' for the first.
    [row_for('assistant', text: BLOCKED, uuid: 'AAA'),
     row_for('user', text: own_marker, parent: 'AAA', uuid: 'M1'),
     row_for('assistant', text: REWRITE, uuid: 'BBB'),
     row_for('user', text: '次の質問です', uuid: 'Q'),
     row_for('assistant', text: BLOCKED, uuid: 'CCC')] + after
  end

  # The record that counts is the one the note names. Taking the newest block
  # feedback in the file instead let an older turn's feedback stand in for one
  # that had not landed, so the read skipped its wait and measured the message
  # it had just blocked — in 0.06s, logged as an ordinary RECHECK verdict. 128
  # of 170 real blocks are not a session's first.
  def test_the_previous_turns_rewrite_is_out_of_reach_of_this_turns_note
    _out, log = drive(second_block, note: 'CCC', max_headings: 3)
    assert_includes log, 'SKIP-awaiting-rewrite', log.inspect
    refute_includes log, 'rec=CCC', 'CCC is the message this turn just blocked'
    refute_includes log, 'rec=BBB', "BBB is the previous turn's delivered rewrite"
  end

  def test_the_second_blocks_rewrite_is_judged_once_it_lands
    rows = second_block(row_for('user', text: own_marker, parent: 'CCC', uuid: 'M2'),
                        row_for('assistant', text: REWRITE, uuid: 'DDD'))
    out, log = drive(rows, note: 'CCC', max_headings: 3)
    assert_includes log, 'rec=DDD', log.inspect
    assert_includes out.fetch('systemMessage', ''), 'PASS'
  end

  # A rewrite that calls a tool writes a short preamble, then tool records, then
  # its real answer. Stepping over the text-less records to find text reaches
  # the preamble and judges that, while the real rewrite is still being written.
  # Inside the budget the newest record is waited for instead.
  #
  # Reachable from the code, not observed. An earlier version of this comment
  # gave figures — RECHECK-PASS in 0.04s, the real four-heading FAIL 0.6s later
  # — and round 3 could not reproduce them: no RECHECK row in the log carries
  # lines= 6 or fewer, and of 184 real blocks the rewrite calls a tool in 0.
  def test_a_preamble_is_not_mistaken_for_the_rewrite_while_the_budget_remains
    Dir.mktmpdir do |tmp|
      tx = File.join(tmp, 't.jsonl')
      c = cfg('log_path' => File.join(tmp, 'gate.log'))
      File.write(tx, rows_json(blocked_then(row_for('assistant', text: "少し調べます\n", uuid: 'P1'),
                                            row_for('assistant', uuid: 'T1', thinking: true))),
                 encoding: 'UTF-8')
      assert_nil G.write_note(tx, c, 'AAA')
      writer = Thread.new do
        sleep(G::POLL_DELAY * 3)
        File.write(tx, rows_json([row_for('assistant', text: BLOCKED, uuid: 'REAL')]),
                   mode: 'a', encoding: 'UTF-8')
      end
      begin
        text, why, record_id = G.last_assistant_text(tx, c, true)
      ensure
        writer.join
      end
      assert_equal BLOCKED, text, 'the real rewrite, not the preamble that preceded it'
      assert_equal 'REAL', record_id
      assert_equal 'ok-after-wait', why
    end
  end

  # Kept as a last resort, and named apart so the log can count how often the
  # ordinary rule was not enough. Over the 3,248 transcripts of the 2026-08-21
  # scan this shape occurred 0 times, so it must never pre-empt the wait — only
  # outlive it.
  def test_text_under_a_newer_textless_record_is_reached_only_after_the_budget
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB'),
                        row_for('assistant', uuid: 'T1', thinking: true))
    out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes log, 'ok-after-wait-deep', log.inspect
    assert_includes log, 'rec=BBB', log.inspect
    assert_includes out.fetch('systemMessage', ''), 'PASS'
  end

  # Naming only the two expected reasons left the other exits silent, and all of
  # the silent ones are live: no note, a transcript momentarily unreadable, and
  # a rewrite that turned out to be whitespace. Each spent the budget and told
  # the operator nothing.
  def test_every_recheck_that_produces_no_verdict_says_so_on_screen
    no_note, = drive([row_for('assistant', uuid: 'AAA', thinking: true)], max_headings: 3)
    assert_includes no_note.fetch('systemMessage', ''), 'NOT RUN', no_note.inspect

    whitespace, = drive(blocked_then(row_for('assistant', text: "   \n", uuid: 'BBB')),
                        note: 'AAA', max_headings: 3)
    assert_includes whitespace.fetch('systemMessage', ''), 'NOT RUN', whitespace.inspect

    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      File.write(cfg_path, JSON.generate('mode_name' => 't', 'log_path' => File.join(tmp, 'g.log')),
                 encoding: 'UTF-8')
      out, _err, status = run_script(
        cfg_path,
        JSON.generate('transcript_path' => tmp, 'stop_hook_active' => true) # a directory
      )
      assert_equal 0, status.exitstatus
      assert_includes JSON.parse(out).fetch('systemMessage', ''), 'NOT RUN',
                      'an unreadable transcript on a recheck must not be silent'
    end
  end

  # The banner quotes a number. Hard-coding it left the suite green while the
  # figure the operator reads drifted away from the budget actually spent.
  def test_the_banner_quotes_the_budget_it_actually_spent
    out, = drive(blocked_then, note: 'AAA', max_headings: 3)
    expected = format('%.1f', G::RECHECK_POLL_ATTEMPTS * G::POLL_DELAY)
    assert_includes out.fetch('systemMessage', ''), "#{expected}s", out.inspect
  end

  def test_a_passing_message_never_blocks_either_way
    [true, false].each do |blocking|
      out = decide("短い応答。\n", max_headings: 3, blocking: blocking)
      refute out.key?('decision'), "blocking=#{blocking}: #{out.inspect}"
    end
  end

  # --- round 3: the instrument the evidence is read through ------------------
  #
  # Everything above measures the gate. The fixtures below measure the things
  # the design reads its own evidence with — the waited token, the order of the
  # last-resort walk, the step-over rule, the guard that skips the judged
  # record. Each survived all 91 earlier fixtures, so any of them could have
  # stopped discriminating without a test going red, and the design's headline
  # numbers are derived from them.

  # A tool result: a `user` record carrying no text at all. At 2026-08-22 05:22
  # UTC, 54,984 of the 62,179 user records in this instance's 3,205 transcripts
  # are these — the counts move by the hour, the ratio does not — so the marker
  # walk reaching past them is not an edge case, it is the ordinary path the
  # moment a blocked rewrite calls a tool.
  def tool_result_row(uuid = nil)
    row = { 'type' => 'user',
            'message' => { 'content' => [{ 'type' => 'tool_result',
                                           'tool_use_id' => 'toolu_x',
                                           'content' => 'ok' }] },
            'toolUseResult' => { 'stdout' => 'ok' } }
    row['uuid'] = uuid if uuid
    row
  end

  # Collapsing `attempt.zero? ? 'ok' : 'ok-after-wait'` to the constant
  # 'ok-after-wait' left 91 runs green: every fixture that asserted a waited
  # value asserted the waited one. That token is the sole basis of the design's
  # two headline numbers — 140 of 140 rechecks never waited, 404 of 608 first
  # reads did — so it could have stopped telling the two apart while the
  # measurement went on reporting a constant.
  def test_a_read_that_did_not_wait_says_so_and_not_the_other_way_round
    _out, recheck = drive(blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB')),
                          note: 'AAA', max_headings: 3)
    assert_includes recheck, "RECHECK-PASS-ok\trec=BBB",
                    "the rewrite was already there; nothing was waited for: #{recheck.inspect}"
    refute_includes recheck, 'ok-after-wait', recheck.inspect

    _out2, first = drive([row_for('assistant', text: FOUR_HEADINGS, uuid: 'AAA')],
                         rechecked: false, max_headings: 3)
    assert_includes first, "FAIL-ok\trec=AAA", first.inspect
    refute_includes first, 'ok-after-wait', first.inspect
  end

  # The last resort walks newest-first. Reversing it left 91 runs green, because
  # the only fixture that reached it had one text-bearing record after the
  # marker and both directions found the same one. Two of them tell the
  # directions apart, and the older one here is the message that failed.
  def test_the_last_resort_takes_the_newest_rewrite_not_the_oldest
    rows = blocked_then(row_for('assistant', text: FOUR_HEADINGS, uuid: 'OLD'),
                        row_for('assistant', text: REWRITE, uuid: 'NEW'),
                        row_for('assistant', uuid: 'T1', thinking: true))
    out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes log, 'ok-after-wait-deep', log.inspect
    assert_includes log, 'rec=NEW', "the newest rewrite, not the one before it: #{log.inspect}"
    refute_includes log, 'rec=OLD', log.inspect
    assert_includes out.fetch('systemMessage', ''), 'PASS', out.inspect
  end

  # Round 3 asked for the opposite rule — stop the walk at any text-less user
  # record — on the ground that image-only and document-only user records are
  # operator turns. At 2026-08-22 05:22 UTC there are 26 of them on the main
  # chain, every one follows a tool result and carries isMeta, and none follows
  # an assistant record, so every one is the harness writing tool output. The
  # probe is log/reviews/probe_textless_user_records_20260822.rb.
  #
  # What the rule lacked was this fixture: rewriting the guard to end the walk
  # left all 91 of round 3's runs green, and what it breaks is a blocked rewrite
  # that calls a tool — reachable from the code, though 0 of 184 real blocks
  # have taken it.
  def test_the_rewrite_is_still_reached_when_it_called_a_tool
    rows = blocked_then(row_for('assistant', text: '少し調べます', uuid: 'P1'),
                        tool_result_row('TR1'),
                        row_for('assistant', text: REWRITE, uuid: 'BBB'))
    out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes log, 'rec=BBB', "the tool result must not hide the rewrite: #{log.inspect}"
    refute_includes log, 'nonote', log.inspect
    assert_includes out.fetch('systemMessage', ''), 'PASS', out.inspect
  end

  # Two fixtures stood here and were retired on 2026-08-26 as duplicates of
  # tighter ones above. The uuid guard they exercised is gone — a rewrite is
  # excluded by position now, not by comparing uuids — so "a rewrite with no
  # uuid is measured rather than skipped" covers what is left of it. The
  # unreadable-exit budget is asserted against one poll interval rather than
  # half the budget by "the unreadable exit returns in well under one poll
  # interval", which is the tighter of the two.

  # --- round 4: what the log's own columns say, and where the walks end ------
  #
  # Round 4 shipped fixtures for the `waited` token and left the four columns
  # beside it unwitnessed, the two first-read exit names unasserted, and three
  # loop boundaries free. Every one of those is read by section 6 as a count.

  # Swapping headings= and tables= left 106 runs green. Section 2.2's headline —
  # 110 of 140 rechecks identical in all four columns — is read off these.
  def test_the_log_names_each_metric_in_its_own_column
    # Four different numbers, so a transposition of any pair is visible. One
    # each would have made the swap invisible, and the first version of this
    # fixture made exactly that mistake.
    text = "# a\n## b\n### c\n\n| x | y |\n|---|---|\n| 1 | 2 |\n" \
           "\n```\nfig one\n```\n\n```\nfig two\n```\n"
    _out, log = drive([row_for('assistant', text: text, uuid: 'AAA')],
                      rechecked: false, max_headings: 3)
    assert_includes log, "\tlines=10\theadings=3\ttables=1\tdiagrams=2\t",
                    "three headings, one table, two diagrams, in that order: #{log.inspect}"
  end

  # The first read's budget is fifteen attempts, and nothing said so: the
  # existing flush fixture lands its text at 0.3s, which a five-attempt budget
  # also catches. A flush that takes most of the budget is what tells them apart.
  def test_the_first_reads_budget_outlasts_a_flush_that_takes_most_of_it
    Dir.mktmpdir do |tmp|
      tx = File.join(tmp, 't.jsonl')
      File.write(tx, rows_json([row_for('assistant', uuid: 'AAA', thinking: true)]),
                 encoding: 'UTF-8')
      writer = Thread.new do
        sleep(G::POLL_DELAY * (G::POLL_ATTEMPTS - 6))
        File.write(tx, rows_json([row_for('assistant', text: REWRITE, uuid: 'BBB')]),
                   mode: 'a', encoding: 'UTF-8')
      end
      begin
        text, why, record_id = G.last_assistant_text(tx, cfg, false)
      ensure
        writer.join
      end
      assert_equal REWRITE, text, "the first read's budget must outlast this flush"
      assert_equal 'ok-after-wait', why
      assert_equal 'BBB', record_id
    end
  end

  # The first read's two no-verdict names live in the same shared log as the
  # recheck's. Renaming them into the recheck's families left the suite green,
  # and section 6 rule 3 greps that log by name.
  def test_the_first_reads_own_no_verdict_names_are_not_the_rechecks
    _out, none = drive([row_for('user', text: 'hello')], rechecked: false, max_headings: 3)
    assert_includes none, 'SKIP-no-assistant-record', none.inspect
    refute_includes none, 'nomarker', 'that suffix belongs to the recheck alone'

    Dir.mktmpdir do |tmp|
      tx = File.join(tmp, 't.jsonl')
      File.write(tx, rows_json([row_for('assistant', uuid: 'AAA', thinking: true)]),
                 encoding: 'UTF-8')
      _text, why, = G.last_assistant_text(tx, cfg, false)
      assert_equal 'race-timeout', why,
                   "the first read's give-up name, not the recheck's awaiting-rewrite"
    end
  end

  # The window is the last 512 KB of the transcript. A note naming a record that
  # fell above it has nothing to anchor on, and the walk must say so rather than
  # measure whatever it can reach. Reachable: the tail of one real 22 MB
  # transcript in this instance holds 14 records.
  def test_a_blocked_record_above_the_window_is_named_as_such
    filler = JSON.generate(row_for('assistant', text: 'x' * 900, uuid: 'F')) + "\n"
    rows = [JSON.generate(row_for('assistant', text: BLOCKED, uuid: 'AAA')) + "\n"]
    rows << filler while rows.join.bytesize <= G::TAIL_BYTES + 4096

    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'gate.log')
      raw = { 'mode_name' => 'test', 'max_headings' => 3, 'log_path' => log_path }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows.join, encoding: 'UTF-8')
      assert_operator File.size(tx_path), :>, G::TAIL_BYTES, 'the fixture must exceed the window'
      assert_nil G.write_note(tx_path, G::Config.new(raw, cfg_path), 'AAA')

      out, _err, status = run_script(
        cfg_path, JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => true)
      )
      assert_equal 0, status.exitstatus
      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'SKIP-blocked-record-gone', log.inspect
      refute_includes log, 'rec=F', 'the filler is not a rewrite of anything'
      assert_includes JSON.parse(out).fetch('systemMessage', ''),
                      'no longer in the part of the transcript'
    end
  end

  # The blocked record can be the oldest row in the window. A walk written as
  # `i > 0` rather than `i >= 0` cannot find it, and every other fixture puts
  # something in front of it.
  def test_a_blocked_record_that_is_the_oldest_row_in_the_window_is_still_found
    rows = [row_for('assistant', text: BLOCKED, uuid: 'AAA'),
            row_for('assistant', text: REWRITE, uuid: 'BBB')]
    out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes log, 'rec=BBB', log.inspect
    refute_includes log, 'blocked-record-gone', 'AAA was row 0, not absent'
    assert_includes out.fetch('systemMessage', ''), 'PASS'
  end

  # The declaration says this exit spends none of the budget. Asserting half of
  # it let a 1.5s sleep through, so the assertion has to be tight enough to be
  # the declaration.
  def test_the_unreadable_exit_returns_in_well_under_one_poll_interval
    Dir.mktmpdir do |tmp|
      c = cfg('log_path' => File.join(tmp, 'gate.log'))
      missing = File.join(tmp, 'no-such-transcript.jsonl')
      assert_nil G.write_note(missing, c, 'AAA')
      started = G.monotonic
      _text, why, = G.last_assistant_text(missing, c, true)
      elapsed = G.monotonic - started
      assert_equal 'unreadable', why
      assert_operator elapsed, :<, G::POLL_DELAY,
                      'this exit returns without polling at all'
    end
  end

  # The whitespace guard is only reached when a note was found and the record
  # after it is whitespace. Round 4's fixture had no marker, so the run exited
  # before the guard was ever evaluated; without a note the same is true here.
  def test_a_whitespace_only_rewrite_produces_no_verdict
    rows = blocked_then(row_for('assistant', text: "   \n", uuid: 'BBB'))
    out, log = drive(rows, note: 'AAA', max_headings: 3)
    assert_includes out.fetch('systemMessage', ''), 'NOT RUN', out.inspect
    refute_includes log, 'RECHECK-PASS', "whitespace is not a passing message: #{log.inspect}"
    refute_includes log, 'RECHECK-FAIL', log.inspect
  end

  # --- the reasons a recheck declines to judge -------------------------------
  #
  # Replaces round 3's three no-marker reasons. One word used to cover all of
  # them and the banner asserted the rarest — "Claude Code's feedback wording
  # may have changed" — which is a sentence the gate can no longer have an
  # opinion about, because it no longer reads that wording. The reasons that
  # remain are about this gate's own record of what it blocked, and each names
  # itself so the log can be counted by cause.

  # The one that carries a number worth having: how often another Stop hook
  # takes a turn this gate would otherwise have rechecked. Under the marker
  # scheme this was an inference; now it is whatever is left when the gate
  # knows it did not block.
  def test_a_turn_this_gate_did_not_block_is_named_as_such_and_not_as_a_wait
    out, log = drive(second_block, max_headings: 3)
    assert_includes log, 'SKIP-nonote', log.inspect
    refute_includes log, 'awaiting-rewrite',
                     'nothing was being waited for; this gate had blocked nothing'
    message = out.fetch('systemMessage', '')
    assert_includes message, 'did not block this turn', message
  end

  # Each declining reason gets its own word in the log, so the column can be
  # counted. Sharing one word made the count unreadable in both directions.
  #
  # Compared as whole fields, not as substrings: `SKIP-nonote` is a prefix of
  # `SKIP-nonote-stale`, so an assertion written with assert_includes cannot
  # tell a distinct reason from a shared one — which is the property under test.
  def test_each_declining_reason_is_named_apart_in_the_log
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB'))
    expected = {
      'SKIP-nonote' => drive(rows, max_headings: 3),
      'SKIP-nonote-stale' => drive(rows, note: 'AAA', note_at: G::NOTE_TTL_SECONDS + 60,
                                         max_headings: 3),
      'SKIP-blocked-record-gone' => drive(rows, note: 'GONE', max_headings: 3),
      'SKIP-awaiting-rewrite' => drive(blocked_then, note: 'AAA', max_headings: 3)
    }
    expected.each do |word, (_out, log)|
      verdicts = log.lines.map { |line| line.split("\t")[2].to_s.strip }
      assert_equal [word], verdicts, "#{word}: #{log.inspect}"
    end
  end

  # No assistant record in the window at all. With a note in hand this is the
  # same condition as the blocked record being gone, and it must not borrow the
  # first read's name for it.
  def test_a_window_holding_no_assistant_record_does_not_borrow_the_first_reads_name
    out, log = drive([row_for('user', text: 'hello')], note: 'AAA', max_headings: 3)
    assert_includes log, 'SKIP-blocked-record-gone', log.inspect
    refute_includes log, 'race-timeout', "that is the first read's give-up: #{log.inspect}"
    refute_includes log, 'no-assistant-record', log.inspect
    refute_includes out.fetch('systemMessage', ''), 'may have changed',
                    'the gate has no opinion about wording any more'
  end

  # --- round 2 hardening -----------------------------------------------------

  # The measurement bound, driven to its limit.
  #
  # Under Python this test used a single "coined term before a colon" rule with
  # nested quantifiers — `(\w+\s?)+:` — which backtracked without returning on
  # an ordinary 71-character prose line, burning the hook's whole budget every
  # turn. That pattern is not pathological here: measured 2026-08-12, Python
  # does not return within 3s and Ruby returns in under a millisecond, because
  # Ruby's matcher has been linear-time since 3.2. Every classic catastrophic
  # shape behaved the same way, including at 200,000 characters.
  #
  # So the bound survives the port for a different reason. One pattern can no
  # longer run away, but many patterns still accumulate, and the cost of the
  # scan is what the mode controls. This drives that: 200 declared patterns over
  # 4,000 lines exceeds a 1-second budget. Sized to stay under TAIL_BYTES so the
  # gate reads the whole thing.
  # 2,000 rather than the 200 this started with. At 200 the scan measured
  # 1.080-1.085s against the 1-second budget: an 8% margin, on a machine-speed
  # assertion, guarding a claim about the bound. A machine ~9% faster failed it.
  # At 2,000 the work is an order of magnitude over the budget, and the deadline
  # aborts the scan, so the test does not get slower for it.
  # §5-3: the deadline crossed by accumulation alone. Every single match here
  # is cheap — a few microseconds — so no Regexp::TimeoutError can pre-empt
  # the deadline, and the raise limb of the seam is the only thing that can
  # end the scan. Deleting that raise turns this red: the next grant is
  # negative, Regexp.timeout= raises ArgumentError past the MeasureTimeout
  # rescue, and the budget banner this fixture pins never appears. The
  # workload is roughly 4x the 9.5s budget (4,000 patterns; at 200 patterns
  # this shape measured ~1.08s), well off the crossing knife-edge.
  #
  # The wall-time band is the behavioural witness that the deadline sits where
  # deadline_for puts it. Its edges give ±0.25s: MARGIN's own mutations are
  # killed by the constant pin, not here.
  def test_an_accumulating_scan_is_cut_at_the_deadline_with_the_budget_banner
    patterns = (1..4000).map do |i|
      "(?<![A-Za-z0-9_])([A-Z]{1,4}★|[A-Z]{2,5}-#{i}\\d+|[PR]\\d+|[a-z]\\d{1,2})"
    end
    text = (['これは普通の散文の行で、INV-5 や a9 のような語を含みます。'] * 4000).join("\n")
    assert_operator text.bytesize, :<, G::TAIL_BYTES, 'the gate must read all of it'

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = decide(text, shorthand_patterns: patterns, gloss_patterns: ['[(（]'],
                       vocab_min_lines: 1, max_headings: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>, 9.3, format('took %.1fs — the budget was not used', elapsed)
    assert_operator elapsed, :<, 9.8, format('took %.1fs — the deadline did not cut', elapsed)
    refute out.key?('decision'), out.inspect
    assert_includes out.fetch('systemMessage', ''), 'measurement ran out of the hook budget'
  end

  # Where the deadline is read, driven on a clock this test controls rather than
  # on machine speed. The clock advances one second per reading. Three patterns
  # sit on one line and the deadline is one tick away: a check placed only at the
  # top of the line loop reads the clock twice — once per line, both in time —
  # and runs every pattern in between unbounded.
  def test_the_bound_is_consulted_between_patterns_not_only_between_lines
    ticks = (0..99).to_a
    original = G.method(:monotonic)
    G.define_singleton_method(:monotonic) { ticks.shift || 99 }
    begin
      # Patterns that match nothing. The match loop inside each one never
      # iterates, so the clock read between patterns is the only one available —
      # with matching patterns this case is masked by the bound inside the match
      # loop, and the first draft of this test was masked exactly that way.
      c = cfg('shorthand_patterns' => ['(zz1)', '(zz2)', '(zz3)'],
              'gloss_patterns' => ['[(（]'], 'vocab_min_lines' => 1)
      assert_raises(G::MeasureTimeout) { G.measure('a1 b2 c3', c, 1) }
    ensure
      G.define_singleton_method(:monotonic, original)
    end
  end

  # The other two places the deadline has to reach. Round 3 found both: the fix
  # that closed "checked once per line" bounded the shorthand loop and left the
  # specimen scan, which runs first, and the match loop inside a single pattern,
  # which can yield many times on one line. Same clock this test controls.
  def test_the_bound_reaches_inside_one_patterns_matches
    ticks = (0..99).to_a
    original = G.method(:monotonic)
    G.define_singleton_method(:monotonic) { ticks.shift || 99 }
    begin
      # One pattern, four matches on one line: the shorthand loop is entered once
      # and never re-entered, so only a check inside the match loop can fire.
      c = cfg('shorthand_patterns' => ['([a-z][0-9])'],
              'gloss_patterns' => ['[(（]'], 'vocab_min_lines' => 1)
      # No trailing newline, so there is exactly one line and no second
      # per-line check to raise instead. With the bound only outside the match
      # loop, the first draft of this test passed under its own mutation
      # because the empty line after the newline raised one tick later.
      assert_raises(G::MeasureTimeout) { G.measure('a1 b2 c3 d4', c, 1) }
    ensure
      G.define_singleton_method(:monotonic, original)
    end
  end

  def test_the_bound_reaches_the_specimen_scan
    ticks = (0..99).to_a
    original = G.method(:monotonic)
    G.define_singleton_method(:monotonic) { ticks.shift || 99 }
    begin
      # Three specimen patterns and no shorthand pattern at all: nothing after
      # the specimen scan can raise, so only a check inside it can.
      # Every pattern here matches nothing, specimen and shorthand alike, so no
      # match loop ever iterates and the only clock read available is the one
      # between specimen patterns. The first draft used specimen patterns that
      # matched, and then the check inside the match loop fired instead — the
      # test passed under its own mutation, which a reviewer found by running
      # it. One line, no trailing newline, so there is no second line either.
      c = cfg('shorthand_patterns' => ['(zz9)'],
              'specimen_patterns' => ['\(q1\)', '\(q2\)', '\(q3\)'],
              'gloss_patterns' => ['[(（]'], 'vocab_min_lines' => 1)
      assert_raises(G::MeasureTimeout) { G.measure('nothing matches here', c, 1) }
    ensure
      G.define_singleton_method(:monotonic, original)
    end
  end

  # The block reason is addressed to the agent under the mode's name. A mode
  # that declared no instruction must not have one invented for it: core prose
  # arriving under the mode's heading is indistinguishable, to the reader, from
  # something the mode said.
  def test_no_rewrite_instruction_is_invented_for_a_mode_that_declared_none
    text = "# a\n## b\n### c\n#### d\n"
    with_instruction = decide(text, max_headings: 3, section: '§ S',
                                    rewrite_instruction: 'Keep every number.')
    assert_includes with_instruction.fetch('reason', ''), 'Keep every number.',
                    'a declared instruction reaches the agent verbatim'

    without = decide(text, max_headings: 3, section: '§ S')
    assert_equal 'block', without['decision'], 'still blocks'
    reason = without.fetch('reason', '')
    assert_includes reason, 'HEADINGS', 'the failure is still reported'
    assert_equal reason.rstrip, reason, 'and nothing is appended after it'
    refute_match(/Rewrite/i, reason, 'no instruction is invented')
  end

  # --- round 3 test debt: properties the suite could not see the loss of ----
  #
  # A reviewer reported survivors against this suite. The cases below
  # are the survivors that named a property section 4 of the review spec claims.
  # Each is written against the deletion that used to leave the suite green.

  # The bound the Ruby 3.2 floor was raised for. Nothing asserted it was ever
  # measure_bounded owns what sits outside any single match: whatever bound the
  # caller had is saved and restored here, outside every per-match grant. The
  # grant-and-revoke inside the seam sets the global to nil between matches, so
  # without this restore a caller's own bound would be silently erased by the
  # measurement it invoked. Driven with a non-nil previous, because with nil the
  # restore assertion passes whether the restore exists or not — the exact
  # blindness the earlier version of this test had.
  def test_measure_bounded_restores_the_bound_the_caller_had
    previous = Regexp.timeout
    Regexp.timeout = 3.0
    begin
      G.measure_bounded("x\n", cfg, G.monotonic + 5)
      assert_equal 3.0, Regexp.timeout, 'the caller bound survives a measurement'
      G.stub(:measure, ->(*) { raise Regexp::TimeoutError }) do
        assert_raises(G::MeasureTimeout) { G.measure_bounded("x\n", cfg, G.monotonic + 5) }
      end
      assert_equal 3.0, Regexp.timeout, 'and survives a measurement that was cut'
    ensure
      Regexp.timeout = previous
    end
  end

  # §9.14 declares that `stop_hook_active` is read by Ruby truthiness, so the
  # string "false" takes the recheck path. A declaration with no fixture is a
  # sentence; this makes it a property.
  def test_stop_hook_active_is_read_by_truthiness_as_declared
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'gate.log')
      File.write(cfg_path, JSON.generate('mode_name' => 'test', 'max_headings' => 1,
                                         'log_path' => log_path), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: FOUR_HEADINGS, uuid: 'AAA')]),
                 encoding: 'UTF-8')
      out, _err, status = run_script(
        cfg_path, JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => 'false')
      )
      assert_equal 0, status.exitstatus
      refute JSON.parse(out).key?('decision'),
             'the string "false" is truthy in Ruby, so this took the recheck path'
      assert_includes File.read(log_path, encoding: 'UTF-8'), 'nonote',
                      'and a recheck with no note issues no verdict'
    end
  end

  # The window check this fixture drove is gone with the marker walk: whether
  # the tail was truncated only mattered for deciding which no-marker cause to
  # name. The window still bounds the read, and "a blocked record above the
  # window is named as such" is what witnesses it now.

  # Driven through the real script, because what the operator loses when this
  # goes wrong is a verdict. A mode declaring six seconds used to be clamped;
  # now the key does nothing at all, and the verdict arrives under the internal
  # budget. Part of the retired key's inertness pin (declared diffs d1/d3):
  # its siblings below drive 0, a negative and a string through the same seam.
  def test_a_mode_still_declaring_the_retired_key_gets_a_first_pass_verdict
    out, log = drive([row_for('assistant', text: FOUR_HEADINGS, uuid: 'AAA')],
                     rechecked: false, max_headings: 3, measure_timeout_seconds: 6)
    assert_equal 'block', out['decision'], out.inspect
    assert_includes log, 'FAIL-ok', log.inspect
    refute_includes log, 'SKIP-measure-timeout', 'an ignored key still yields a verdict'
  end

  # The values that used to be lethal. 0 and a negative passed the Integer type
  # check, reached Regexp.timeout= and killed the gate with exit 0, empty
  # stdout and no log file at all; a string drew a type-error NOT RUN. All
  # three now measure and judge — the key has no observable surface left.
  def test_the_retired_keys_lethal_values_now_measure_and_judge
    [0, -3, '5'].each do |value|
      out, log = drive([row_for('assistant', text: FOUR_HEADINGS, uuid: 'AAA')],
                       rechecked: false, max_headings: 3, measure_timeout_seconds: value)
      assert_equal 'block', out['decision'], "value #{value.inspect}: #{out.inspect}"
      assert_includes log, 'FAIL-ok', "value #{value.inspect}: #{log.inspect}"
    end
  end

  # d1's exact multi-problem form: with another key mistyped alongside the
  # retired one, the NOT RUN line carries the other key's clause ONLY — the
  # retired key's clause is gone, and the gate still does not run.
  def test_a_multi_problem_config_loses_only_the_retired_keys_clause
    out = decide(FOUR_HEADINGS, max_lines: '60', measure_timeout_seconds: '5')
    msg = out.fetch('systemMessage', '')
    assert_includes msg, 'NOT RUN'
    assert_includes msg, 'max_lines is string', msg
    refute_includes msg, 'measure_timeout_seconds', msg
    refute out.key?('decision'), 'the remaining problem still suppresses the run'
  end

  # Declared diff d1: the retired key produces no problem clause for ANY value
  # shape. It used to be an INT_KEY, so 5.0 drew "measure_timeout_seconds is
  # number, expected a number" and a NOT RUN; now it flows through checked()'s
  # unknown-key fall-through and is read by nobody. This is the diff the design
  # declares, pinned so it cannot half-return: a value shape drawing a clause
  # again means the key crept back into INT_KEYS.
  def test_the_retired_key_draws_no_problem_clause_for_any_value_shape
    [5, 60, 1, 0, -3, '5', 5.0, true, false, nil, [], {}].each do |value|
      problems = cfg('measure_timeout_seconds' => value).problems
      assert_empty problems, "value #{value.inspect} drew: #{problems.inspect}"
    end
  end

  # HOOK_TIMEOUT is declared twice and neither copy knew about the other:
  # mutating this one to 20.0 left 91 runs green, because the only assertion
  # that read it compared it against a constant derived from itself. The other
  # declaration is the compiler's, and it is what Claude Code is actually told.
  def test_the_hook_timeout_matches_the_limit_the_compiler_declares
    compiler = File.join(File.dirname(HERE), 'lib', 'mode_hooks_compiler.rb')
    source = File.read(compiler, encoding: 'UTF-8')
    declared = source[/'readable_gate'\s*=>\s*\{[^}]*?timeout:\s*(\d+(?:\.\d+)?)/, 1]
    refute_nil declared, "the compiler no longer declares a timeout for readable_gate: #{compiler}"
    assert_in_delta declared.to_f, G::HOOK_TIMEOUT, 1e-9,
                    'the gate and the compiler must name the same limit'
  end

  # The margin holds back interpreter start-up and the poll's own overhead —
  # everything the gate spends that is neither sleeping nor measuring. Asserting
  # only that it is positive left every value in (0, 1) alive, so this measures
  # the overhead instead of asserting a sign. A recheck with no rewrite spends
  # its whole 4s budget; everything above that is what the margin must cover.
  def test_the_headroom_covers_what_the_gate_spends_outside_sleeping
    started = G.monotonic
    drive(blocked_then, note: 'AAA', max_headings: 3)
    overhead = (G.monotonic - started) - (G::RECHECK_POLL_ATTEMPTS * G::POLL_DELAY)
    assert_operator overhead, :>, 0, 'the interpreter does not start for free'
    assert_operator overhead, :<, G::HOOK_TIMEOUT_MARGIN,
                    "measured overhead #{overhead.round(3)}s must fit the declared margin"
  end

  def test_a_transcript_that_cannot_be_read_is_recorded_as_a_skip
    Dir.mktmpdir do |tmp|
      log = File.join(tmp, 'gate.log')
      cfg_path = File.join(tmp, 'cfg.json')
      File.write(cfg_path, JSON.generate('mode_name' => 't', 'max_headings' => 1,
                                         'log_path' => log), encoding: 'UTF-8')
      # A directory, not a file: File.open succeeds and the read raises, which
      # is the branch no fixture reached because every other test writes a file.
      out, _, status = run_script(
        cfg_path, JSON.generate('transcript_path' => tmp, 'stop_hook_active' => false)
      )
      assert_equal 0, status.exitstatus
      refute_includes out, 'block'
      assert_includes File.read(log, encoding: 'UTF-8'), 'SKIP-unreadable',
                      'the reason the turn was let through is recorded'
    end
  end

  # Driven through main directly, not as a subprocess: the script's outermost
  # rescue would convert the missing guard into the same exit 0 and hide it.
  def test_a_config_that_is_not_json_returns_zero_rather_than_raising
    Dir.mktmpdir do |tmp|
      broken = File.join(tmp, 'cfg.json')
      File.write(broken, '{ not json', encoding: 'UTF-8')
      assert_equal 0, G.main(['--config', broken], StringIO.new('{}'))
    end
  end

  # The header states the exit status is always zero. This path said two, and
  # two is what Claude Code reads as a blocking stop — reached by anyone who
  # adds the executable to a hook by hand and forgets the argument.
  def test_a_missing_config_argument_still_exits_zero
    assert_equal 0, G.main([], StringIO.new('{}'))
  end

  def test_stdin_that_is_not_an_object_is_treated_as_an_empty_payload
    Dir.mktmpdir do |tmp|
      log = File.join(tmp, 'gate.log')
      cfg_path = File.join(tmp, 'cfg.json')
      File.write(cfg_path, JSON.generate('mode_name' => 't', 'max_headings' => 1,
                                         'log_path' => log), encoding: 'UTF-8')
      assert_equal 0, G.main(['--config', cfg_path], StringIO.new('[1,2]'))
      assert_includes File.read(log, encoding: 'UTF-8'), 'SKIP-',
                      'a list payload yields no transcript path and is recorded as a skip'
    end
  end

  # A mode pattern that can match the empty string. The scan advances past a
  # zero-width match by one character; without that it never terminates, and
  # nothing supplied such a pattern.
  def test_a_pattern_that_matches_the_empty_string_terminates
    c = cfg('shorthand_patterns' => ['(x?)'], 'gloss_patterns' => ['[(（]'],
            'vocab_min_lines' => 1)
    Timeout.timeout(5) { G.measure('abc def', c, nil) }
  end

  # Both were asserted only through substrings the hard-coded defaults also
  # produce, so replacing either with a literal left the suite green.
  def test_the_banner_prefix_and_section_are_the_modes_own
    out = decide("# a\n## b\n", max_headings: 1,
                                banner_prefix: 'zztop', section: '§ Quite Specific')
    assert_match(/\Azztop:/, out.fetch('systemMessage', ''),
                 'the banner opens with the prefix the mode declared')
    assert_includes out.fetch('reason', ''), '§ Quite Specific',
                    'and the reason names the section the mode declared'
  end

  # Rotation is housekeeping; the record is the point. When two gates cross the
  # size bound together the loser's rename fails, and the method-level rescue
  # used to swallow the append along with it. Driven with the rotation target
  # occupied by a non-empty directory, which makes the rename fail every time.
  def test_a_rotation_that_cannot_happen_does_not_cost_the_record
    Dir.mktmpdir do |dir|
      log = File.join(dir, 'gate.log')
      File.write(log, 'x' * 100, encoding: 'UTF-8')
      FileUtils.mkdir_p("#{log}.1")
      File.write(File.join("#{log}.1", 'occupied'), 'y', encoding: 'UTF-8')
      G.note(cfg('log_path' => log, 'log_max_bytes' => 10), 'PASS')
      assert_includes File.read(log, encoding: 'UTF-8'), 'PASS',
                      'the record survives a rotation that could not be performed'
    end
  end

  # The other half of the bound: a single match that does run away is turned
  # into the same outcome. Ruby raises Regexp::TimeoutError rather than letting
  # the scan continue, and the gate must convert that into NOT RUN rather than
  # let it escape. Driven at the seam because no pattern this project can write
  # reaches it — see the note above.
  def test_a_regexp_timeout_becomes_not_run_rather_than_an_escape
    c = cfg('shorthand_patterns' => ['(a)'], 'gloss_patterns' => ['x'],
            'vocab_min_lines' => 1)
    G.stub(:measure, ->(*) { raise Regexp::TimeoutError }) do
      assert_raises(G::MeasureTimeout) { G.measure_bounded("a\n", c, G.monotonic + 5) }
    end
    assert_nil Regexp.timeout, 'the bound must be restored after measurement'
  end

  def test_a_wrong_typed_threshold_reports_instead_of_crashing
    # `"max_lines": "60"` used to raise on every turn: non-zero exit, no
    # verdict, and no line in the log the operator would look at.
    out = decide("# a\n## b\n### c\n#### d\n", max_lines: '60', max_headings: '3')
    refute out.key?('decision'), out.inspect
    assert_includes out.fetch('systemMessage', ''), 'max_lines'
    assert_includes out.fetch('systemMessage', ''), 'max_headings'
  end

  def test_an_invalid_pattern_reports_instead_of_silently_disabling
    out = decide("some text\n", announce_patterns: ['(unclosed'])
    assert_includes out.fetch('systemMessage', ''), 'NOT RUN'
  end

  def test_a_pattern_list_given_as_a_bare_string_is_refused
    # A bare string would be used as a rule nobody wrote.
    out = decide("some text\n", shorthand_patterns: 'P\d')
    assert_includes out.fetch('systemMessage', ''), 'NOT RUN'
  end

  # --- transcripts the gate must survive -------------------------------------

  def test_malformed_transcript_records_do_not_raise
    # Guard-level, driven direct so that deleting a guard raises here: a
    # non-object message and a non-string text value fall through as "no
    # text", never raise, never coerce into measurable text.
    [nil, 'a string', 42, [1]].each do |message|
      assert_nil G.text_of({ 'type' => 'assistant', 'message' => message }),
                 "message=#{message.inspect}"
    end
    [42, { 'a' => 1 }, ['x']].each do |text|
      row = { 'message' => { 'content' => [{ 'type' => 'text', 'text' => text }] } }
      assert_nil G.text_of(row), "text=#{text.inspect}"
    end

    [nil, 'plain string', [nil, 7], [{ 'type' => 'text' }],
     [{ 'type' => 'text', 'text' => 42 }]].each do |content|
      line = JSON.generate('type' => 'assistant', 'message' => { 'content' => content }) + "\n"
      run_raw(line, 'mode_name' => 't', 'max_headings' => 1) do |out, err, status, _, log|
        assert_equal 0, status.exitstatus, "content=#{content.inspect}: #{err[0, 200]}"
        refute_includes out, 'block', "content=#{content.inspect}"
        # Which verdict is not the point and differs by case: a content that is
        # a bare string is readable text and measures to PASS, while a null one
        # yields nothing and records a skip. The point is that some verdict was
        # reached, which distinguishes reading the record from dying before it.
        assert_match(/\tt\t(PASS|FAIL|SKIP)/, log,
                     "content=#{content.inspect}: no verdict recorded")
      end
    end

    # A text value carrying a byte that is not valid UTF-8 — a record caught
    # mid-write, or tool output pasted into a message. The tail reader tags
    # the raw bytes UTF-8 and scrubs them before anything measures. Without
    # that tagging, JSON tolerates the binary line, the mis-tagged text
    # reaches its first String operation, and the gate dies before the log
    # line — so the PASS asserted here is what a lost scrub cannot produce.
    # The invalid pair is spliced in bytewise: JSON.generate refuses to emit
    # invalid UTF-8, and the file must carry it anyway.
    torn = JSON.generate(
      'type' => 'assistant',
      'message' => { 'content' => [{ 'type' => 'text', 'text' => '計測前に切れたXX の記録' }] }
    ).b.sub('XX'.b, "\xE3\x81".dup.force_encoding(Encoding::BINARY))
                 .force_encoding(Encoding::UTF_8) + "\n"
    run_raw(torn, 'mode_name' => 't', 'max_headings' => 1) do |out, err, status, _, log|
      assert_equal 0, status.exitstatus, err[0, 200]
      refute_includes out, 'block'
      assert_match(/\tt\tPASS/, log, 'the scrubbed record still reaches a verdict')
    end
  end

  def test_a_record_that_is_not_an_object_fails_open
    # A JSON line that parses to a scalar or list is still a malformed record.
    #
    # Placement is load-bearing. last_assistant_text scans the rows in reverse,
    # so a malformed row BEFORE the newest assistant record is never examined
    # and the case passes for the wrong reason. It must be at or after it.
    good = JSON.generate('type' => 'assistant',
                         'message' => { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] })
    ['"a string"', '42', '[1,2]', 'null', 'true'].each do |row|
      { 'last' => [good, row], 'only' => [row] }.each do |label, lines|
        run_raw(lines.join("\n") + "\n",
                'mode_name' => 't', 'max_headings' => 1) do |out, err, status, _, log|
          assert_equal 0, status.exitstatus, "row=#{row} (#{label}): #{err[0, 200]}"
          refute_includes out, 'block', "row=#{row} (#{label})"
          # With a usable record behind the malformed one the gate must reach a
          # verdict on it; with nothing usable it must record the skip. Both are
          # positive, and a gate that crashed satisfies neither.
          expected = label == 'last' ? 'PASS-' : 'SKIP-'
          assert_includes log, expected, "row=#{row} (#{label}): log=#{log.inspect}"
        end
      end
    end
  end

  def test_the_report_path_also_survives_a_record_that_is_not_an_object
    # --report reads through a second reader, which had the same defect.
    # tail_records was guarded and all_records was not. Fixing one reader and
    # leaving its twin is the failure this asserts against.
    good = JSON.generate('type' => 'assistant',
                         'message' => { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] })
    # The second measurable record is Japanese, and its coined token 甲 is
    # what the vocabulary rule must see. Read mis-tagged under a US-ASCII
    # locale, 甲 scrubs to '?', the pattern stops matching, and the FAIL
    # silently vanishes — the VOCABULARY assertion below is what a
    # whole-file reader without its encoding argument cannot produce.
    judged = JSON.generate('type' => 'assistant',
                           'message' => { 'content' => [{ 'type' => 'text',
                                                          'text' => '甲 の裁定を待ちます。' }] })
    content = [good, '42', '"a string"', 'null', judged].join("\n") + "\n"
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      File.write(cfg_path, JSON.generate('mode_name' => 't', 'max_headings' => 1,
                                         'shorthand_patterns' => ['(甲)'],
                                         'gloss_patterns' => ['[（(＝=]'],
                                         'vocab_min_lines' => 1), encoding: 'UTF-8')
      File.write(tx_path, content, encoding: 'UTF-8')
      out, err, status = run_script(cfg_path, '', ['--report', tx_path])
      assert_equal 0, status.exitstatus, err[0, 200]
      assert_equal 2, out.scan('lines=').length, out.inspect
      assert_includes out, 'FAIL=VOCABULARY',
                      'the unglossed 甲, read off disk, must be measured'
    end
  end

  def test_a_broken_transcript_fails_open
    ['', "{ not json\n"].each do |raw|
      run_raw(raw, 'mode_name' => 't', 'max_headings' => 1) do |out, err, status, _, log|
        assert_equal 0, status.exitstatus, err[0, 200]
        refute_includes out, 'block'
        assert_includes log, 'SKIP-', "raw=#{raw.inspect}: no verdict recorded"
      end
    end
  end

  # The flush race the retry exists for (round 3 condition 9): the harness can
  # invoke the Stop hook before the turn's text record has been flushed, so the
  # newest assistant record is thinking-only at first read. Driven with a real
  # late write, not a seam — a thread appends the text record after the first
  # read has already come back empty. Delete the retry and this returns nil.
  def test_the_retry_waits_out_a_slow_flush
    Dir.mktmpdir do |tmp|
      tx = File.join(tmp, 't.jsonl')
      File.write(tx, JSON.generate(
        'type' => 'assistant',
        'message' => { 'content' => [{ 'type' => 'thinking', 'thinking' => 'x' }] }
      ) + "\n", encoding: 'UTF-8')
      writer = Thread.new do
        sleep(G::POLL_DELAY * 3)
        File.write(tx, JSON.generate(
          'type' => 'assistant',
          'message' => { 'content' => [{ 'type' => 'text', 'text' => 'landed late' }] }
        ) + "\n", mode: 'a', encoding: 'UTF-8')
      end
      begin
        text, why = G.last_assistant_text(tx, cfg, false)
      ensure
        writer.join
      end
      assert_equal 'landed late', text, 'the text that landed late is the one measured'
      assert_equal 'ok-after-wait', why, 'and the outcome names the wait'
    end
  end

  # --- the shipped example must actually work --------------------------------

  def strip_comments(obj)
    case obj
    when Hash then obj.reject { |k, _| k.start_with?('_') }
                     .transform_values { |v| strip_comments(v) }
    when Array then obj.map { |v| strip_comments(v) }
    else obj
    end
  end

  def test_shipped_example_params_drive_the_gate
    path = File.join(File.dirname(HERE), 'mode_hooks', '_EXAMPLE.json')
    doc = strip_comments(JSON.parse(File.read(path, encoding: 'UTF-8')))
    entry = doc['hooks']['Stop'][0]
    params = entry['params']

    # The example ships report-only on purpose: its vocabulary rule is the one
    # thing here that cannot be got right by reading, so a copier should see
    # reports before they see a blocked turn. Nothing asserted this — both
    # example tests read only params — so flipping it left the suite green.
    assert_equal false, entry['blocking'],
                 'the shipped example must not block until its owner has measured'

    # The two shapes the example still claims: a lowercase letter welded to
    # digits, and a numbered label whose referent is not in the message.
    ['a9 が壊れます。', '#7 が壊れます。'].each do |line|
      _, f = measure("#{line}\n" * 10, params)
      assert f.any? { |x| x.include?('VOCABULARY') }, "#{line}: #{f.inspect}"
    end

    _, f = measure("commit c341361 を参照。\n" * 10, params)
    assert_empty f, f.inspect

    # The defect the example shipped with. A mode enforcing this rule on
    # Japanese text meets full-width digits, and the ASCII-only digit shorthand
    # does not match them: every such token passed, silently, on every turn.
    # Nothing asserted this until the falsification harness mutated the example
    # back and found the suite still green.
    _, f = measure("a９ が壊れます。\n" * 10, params)
    assert f.any? { |x| x.include?('VOCABULARY') },
           "full-width digits must be measured too: #{f.inspect}"

    # The shipped example must not be a trap. A reviewer copied it, ran ordinary
    # technical prose through it, and was blocked on the word for a character
    # encoding — because an uppercase-plus-digits branch cannot tell a coined
    # label from a protocol name. The example ships without that branch.
    # x86 is deliberately absent from this list: it matches the lowercase branch
    # the example does keep, and no shape separates it from a9. That residual is
    # why the example ships report-only rather than blocking.
    %w[UTF-8 SHA-256 MD5 S3 EC2 TLS1 CO2 HTTP2].each do |word|
      _, f = measure("#{word} を使います。\n" * 10, params)
      assert_empty f.select { |x| x.include?('VOCABULARY') },
                   "#{word} is an ordinary technical word, not coined vocabulary"
    end

    # And a diagram clears the floor while bare prose of the same length does not.
    long = "この行は散文です。\n" * 40
    _, f = measure(long, params)
    assert f.any? { |x| x.start_with?('DIAGRAM') }, f.inspect
    _, f = measure("#{long}```\nA -> B\n```\n", params)
    assert_empty f.select { |x| x.start_with?('DIAGRAM') }, f.inspect
  end

  # --- round 13 fix: the log_path family -------------------------------------
  #
  # Round 11 put log_path into STR_KEYS so a mistyped `"log_path": 123` would be
  # reported like any other mistyped key. That closed the non-string half and
  # left two holes, both measured in round 12 with one probe:
  #
  #   null           the key's own shipped default, and now a fatal config
  #                  error — a blocking gate answered NOT RUN every turn and
  #                  enforced nothing at all.
  #   "" or an       a string, so no config problem is raised;
  #   existing       File.expand_path("") is the working directory,
  #   directory      File.open(<a directory>, 'a') raises EISDIR, and note()'s
  #                  method-level rescue swallowed it. The gate blocked and
  #                  passed exactly as normal while nothing was ever recorded —
  #                  the example's own onboarding week produced no data.
  #
  # log_path leaves STR_KEYS again. nil alone means "no log declared"; every
  # other value is attempted, and a write that fails is named in the banner
  # without touching enforcement. One test per boundary the two rounds crossed.

  def test_the_shipped_default_for_log_path_is_nil
    assert_nil G::DEFAULTS['log_path'],
               'nil is what note() reads as "no log declared"; any other ' \
               'default makes every mode that omits the key attempt a write'
  end

  def test_declaring_the_default_leaves_the_gate_enforcing
    out = decide(FOUR_HEADINGS, log_path: nil, max_headings: 3)
    assert_equal 'block', out['decision'],
                 'null is this key\'s own default and must not disable the gate'
    refute_includes out.fetch('systemMessage', ''), 'NOT RUN'
    refute_includes out.fetch('systemMessage', ''), 'log not written',
                    'declaring no log is not a failure to write one'
  end

  def test_a_mistyped_log_path_is_named_and_costs_no_enforcement
    out = decide(FOUR_HEADINGS, log_path: 123, max_headings: 3)
    assert_equal 'block', out['decision'],
                 'a log the gate cannot write is not a reason to stop enforcing'
    refute_includes out.fetch('systemMessage', ''), 'NOT RUN'
    assert_includes out.fetch('systemMessage', ''), 'log not written'
    assert_includes out.fetch('systemMessage', ''), 'TypeError'
  end

  # `false` is the other way a mode author says "off", and Ruby's falsiness
  # would let it take nil's exit silently. Only nil is a declaration of no log;
  # everything else is attempted, so a mode that meant to switch logging off
  # this way is told the gate did not understand it rather than left guessing.
  def test_only_nil_means_no_log_was_declared
    out = decide("short\n", log_path: false)
    assert_includes out.fetch('systemMessage', ''), 'log not written'
  end

  def test_an_empty_log_path_is_named_rather_than_swallowed
    out = decide("short\n", log_path: '')
    assert_includes out.fetch('systemMessage', ''), 'PASS',
                    'measurement is untouched'
    assert_includes out.fetch('systemMessage', ''), 'log not written',
                    'expand_path("") is the working directory, and appending ' \
                    'to a directory raises where nobody could see it'
  end

  def test_a_directory_as_the_log_path_is_named_rather_than_swallowed
    Dir.mktmpdir do |dir|
      out = decide("short\n", log_path: dir)
      assert_includes out.fetch('systemMessage', ''), 'PASS'
      assert_includes out.fetch('systemMessage', ''), 'log not written'
      assert_includes out.fetch('systemMessage', ''), 'Is a directory',
                      'and the banner names the cause, not just the fact'
    end
  end

  # ~/.kairos/logs is the parent of the path the example suggests, so an
  # operator who writes the directory instead of the file inside it lands on
  # the case above. This is the other half: the file inside a parent that does
  # not exist yet has to be created, and nothing witnessed the mkdir_p.
  def test_a_log_under_a_parent_that_does_not_exist_yet_is_still_written
    Dir.mktmpdir do |dir|
      log = File.join(dir, 'nested', 'deep', 'gate.log')
      out = decide("short\n", log_path: log)
      assert_path_exists log, 'the gate creates the parent it was pointed at'
      assert_includes File.read(log, encoding: 'UTF-8'), 'PASS'
      refute_includes out.fetch('systemMessage', ''), 'log not written',
                      'and a write that succeeded says nothing at all'
    end
  end

  # The reason rides in the banner on every turn for as long as the mode stays
  # misconfigured, and a rescued message carries a path of any length. Driven
  # with a filename past the 255-byte component limit, which is the case where
  # the whole declared path lands in the message — a parent that cannot be
  # created reports only the component it stopped at, and is far too short to
  # tell a bounded reason from an unbounded one.
  def test_the_named_reason_is_bounded
    Dir.mktmpdir do |dir|
      out = decide("short\n", log_path: File.join(dir, "#{'y' * 300}.log"))
      msg = out.fetch('systemMessage', '')
      assert_includes msg, 'log not written'
      assert_operator msg.length, :<, 250, msg[0, 160]
    end
  end

  # --- round 13, second repair: bytes the gate cannot encode -----------------
  #
  # A config string carrying a byte invalid as UTF-8 killed the entire output:
  # exit 0, empty stdout, empty stderr — no banner, no verdict, no block.
  # Measured on this tree through log_path (the EILSEQ message embeds the
  # declared path, and String#tr raised on it inside note()'s rescue) and on
  # the pre-repair tree through mode_name (the block reason reaches
  # JSON.generate un-scrubbed, never passing note() at all). Two placements,
  # one witness each, so losing either scrub reddens the test that names it.
  #
  # JSON.generate refuses to emit invalid UTF-8, so the byte is spliced into
  # the config bytewise, the way the torn transcript fixture above splices its.

  def decide_with_bad_byte(config_with_marker, text)
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      raw = JSON.generate(config_with_marker)
                .b.sub("BADBYTE".b, "\xE3\x81".b).force_encoding(Encoding::UTF_8)
      File.binwrite(cfg_path, raw)
      File.write(tx_path, JSON.generate(
        'type' => 'assistant',
        'message' => { 'content' => [{ 'type' => 'text', 'text' => text }] }
      ) + "\n", encoding: 'UTF-8')
      out, err, status = run_script(
        cfg_path, JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => false)
      )
      assert_equal 0, status.exitstatus, err[0, 300]
      refute_empty out.strip, 'silence is the defect this witnesses: the gate must answer'
      JSON.parse(out)
    end
  end

  def test_a_byte_invalid_as_utf8_in_log_path_still_banners_and_still_blocks
    # The parent directory carries the byte, so mkdir_p refuses with EILSEQ —
    # measured on this project's darwin/APFS machines, where such a path cannot
    # exist on disk at all — and the refusal's message carries the byte into
    # the rescued reason.
    Dir.mktmpdir do |tmp|
      out = decide_with_bad_byte(
        { 'mode_name' => 'test', 'section' => '§ Test', 'max_headings' => 3,
          'log_path' => File.join(tmp, 'BADBYTEdir', 'gate.log') }, FOUR_HEADINGS
      )
      msg = out.fetch('systemMessage', '')
      assert_includes msg, 'FAIL', 'the banner arrives'
      assert_includes msg, 'log not written', 'and names the write it lost'
      assert_equal 'block', out['decision'], 'and the block arrives with it'
    end
  end

  def test_a_byte_invalid_as_utf8_in_mode_name_still_banners_and_still_blocks
    # The pre-existing sibling route: no log is declared, note() is never the
    # carrier, and the byte reaches the output only through the block reason —
    # which is exactly the route the scrub in note() cannot cover.
    out = decide_with_bad_byte(
      { 'mode_name' => 'mBADBYTEe', 'section' => '§ Test', 'max_headings' => 3 },
      FOUR_HEADINGS
    )
    assert_includes out.fetch('systemMessage', ''), 'FAIL', 'the banner arrives'
    assert_equal 'block', out['decision'], 'the block arrives'
    assert_includes out.fetch('reason', ''), 'HEADINGS',
                    'and the reason survives, its bad byte replaced'
  end

  # Rotation checked existence and size but never that the path is a regular
  # file. With the bound at or below a directory's on-disk size (96-160 bytes
  # on APFS), the operator's directory was renamed to <path>.1 and a regular
  # file took its name — and the banner said nothing, because the append then
  # succeeded. A directory must skip rotation and land where EISDIR is named.
  def test_rotation_never_renames_a_directory_out_of_its_place
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'logs')
      Dir.mkdir(target)
      File.write(File.join(target, 'precious'), 'operator data', encoding: 'UTF-8')
      out = decide("short\n", log_path: target, log_max_bytes: 1)
      assert File.directory?(target), 'the operator directory keeps its name'
      assert_path_exists File.join(target, 'precious'), 'and keeps its contents'
      refute File.exist?("#{target}.1"), 'nothing was renamed aside'
      msg = out.fetch('systemMessage', '')
      assert_includes msg, 'PASS', 'measurement untouched'
      assert_includes msg, 'log not written', 'the failed write is named'
      assert_includes msg, 'Is a directory', 'as the EISDIR the append raises'
    end
  end

  # --- round 13, gap 25: the NOT RUN banners' write-failure clause -----------
  #
  # Both NOT RUN branches append "; log not written: ..." when the skip record
  # itself could not be written. Suppressing the clause on either branch left
  # all 63 tests green — four seats measured it — so each branch gets one
  # witness driving it with an unwritable log_path.

  def test_the_bad_config_banner_names_the_log_it_could_not_write
    Dir.mktmpdir do |dir|
      out = decide("short\n", max_lines: '60', log_path: dir)
      msg = out.fetch('systemMessage', '')
      assert_includes msg, 'NOT RUN', 'the config problem still suppresses the run'
      assert_includes msg, 'max_lines', 'and is named'
      assert_includes msg, 'log not written', 'and the lost record is named beside it'
    end
  end

  def test_the_measure_timeout_banner_names_the_log_it_could_not_write
    # The branch is entered through its real seam — main's rescue of
    # MeasureTimeout around measure_bounded — with the measurement stubbed to
    # raise, the same seam test_a_regexp_timeout... drives. A genuine timeout
    # costs a second of wall clock per run and is already witnessed end to end
    # by the accumulating-scan test; this witness is about the clause, and the
    # note() failure it asserts is real: the log_path is a directory.
    Dir.mktmpdir do |dir|
      cfg_path = File.join(dir, 'cfg.json')
      tx = File.join(dir, 't.jsonl')
      unwritable = File.join(dir, 'logdir')
      Dir.mkdir(unwritable)
      File.write(cfg_path, JSON.generate('mode_name' => 't', 'log_path' => unwritable),
                 encoding: 'UTF-8')
      File.write(tx, JSON.generate(
        'type' => 'assistant',
        'message' => { 'content' => [{ 'type' => 'text', 'text' => 'x' }] }
      ) + "\n", encoding: 'UTF-8')
      out = nil
      G.stub(:measure_bounded, ->(*) { raise G::MeasureTimeout }) do
        out, _err = capture_io do
          assert_equal 0, G.main(['--config', cfg_path],
                                 StringIO.new(JSON.generate('transcript_path' => tx)))
        end
      end
      msg = JSON.parse(out).fetch('systemMessage', '')
      assert_includes msg, 'NOT RUN'
      # The declared d2 wording: the banner quotes the time actually spent and
      # the budget it ran out of, not a mode-declared value — the key that
      # carried one is retired. This is the pin that stops the wording drifting.
      assert_includes msg, 'measurement ran out of the hook budget',
                      'the timeout is what the banner explains'
      assert_includes msg, 'of 9.5s', 'and the budget it quotes is the internal one'
      assert_includes msg, 'log not written', 'and the lost record is named beside it'
    end
  end

  # --- round 11: boundary witnesses ------------------------------------------
  #
  # 45 mutations, 19 survivors, one cause: no fixture ever sat on a boundary.
  # Length was measured at 70 against a cap of 60, headings at 4 against 3, the
  # diagram floor at 40 against 30, the vocabulary floor at 1 line against 8 —
  # so `>` and `>=` were indistinguishable everywhere it mattered. Each case
  # below holds one comparison on its boundary from both sides.

  def test_the_length_cap_boundary
    at_cap = (0...60).map { |i| "line #{i}" }.join("\n")
    _, f = measure(at_cap, 'max_lines' => 60)
    assert_empty f.select { |x| x.start_with?('LENGTH') },
                 '60 lines at cap 60 is within the cap'
    over = (0...61).map { |i| "line #{i}" }.join("\n")
    _, f = measure(over, 'max_lines' => 60)
    assert f.any? { |x| x.start_with?('LENGTH') }, f.inspect
  end

  def test_the_headings_cap_boundary
    at_cap = "# a\n## b\n### c"
    _, f = measure(at_cap, 'max_headings' => 3)
    assert_empty f.select { |x| x.start_with?('HEADINGS') },
                 '3 headings at cap 3 is within the cap'
    _, f = measure(at_cap + "\n#### d", 'max_headings' => 3)
    assert f.any? { |x| x.start_with?('HEADINGS') }, f.inspect
  end

  def test_the_tables_cap_boundary
    table = "| a | b |\n|---|---|\n| 1 | 2 |"
    _, f = measure(([table] * 2).join("\n"), 'max_tables' => 2)
    assert_empty f.select { |x| x.start_with?('TABLES') },
                 '2 tables at cap 2 is within the cap'
    _, f = measure(([table] * 3).join("\n"), 'max_tables' => 2)
    assert f.any? { |x| x.start_with?('TABLES') }, f.inspect
  end

  def test_the_diagram_floor_boundary
    at_floor = (0...30).map { |i| "散文の行 #{i}" }.join("\n")
    _, f = measure(at_floor, 'diagram_required_over_lines' => 30)
    assert_empty f.select { |x| x.start_with?('DIAGRAM') },
                 '30 lines at floor 30 does not trip the floor'
    over = (0...31).map { |i| "散文の行 #{i}" }.join("\n")
    _, f = measure(over, 'diagram_required_over_lines' => 30)
    assert f.any? { |x| x.start_with?('DIAGRAM') }, f.inspect
  end

  # The floor under its own name. Until now its loss reddened only tests about
  # the timeout machinery, so a maintainer who broke it was shown the wrong
  # defect entirely.
  def test_the_vocabulary_floor_boundary
    overrides = { 'shorthand_patterns' => [MASA_SHORTHAND],
                  'gloss_patterns' => GLOSS, 'vocab_min_lines' => 8 }
    filler = (0...7).map { |i| "説明の行 #{i}" }
    _, f = measure((['t0 が壊れます。'] + filler).join("\n"), overrides)
    assert f.any? { |x| x.include?('VOCABULARY') },
           "8 lines at floor 8 enters the scan: #{f.inspect}"
    _, f = measure((['t0 が壊れます。'] + filler[0, 6]).join("\n"), overrides)
    assert_empty f.select { |x| x.include?('VOCABULARY') },
                 '7 lines stays below the floor'
  end

  # The specimen containment, made to actually execute. The three fixtures in
  # test_a_specimen_exemption_does_not_leak_to_real_use are single tokens in
  # parentheses — not lists — so specimen_spans returns [] there and the
  # end-bound of the containment expression is never evaluated. Here one line
  # carries a real specimen LIST and, past its closing parenthesis, a real use
  # of a governed token: the exemption must end at the span.
  def test_a_specimen_span_does_not_extend_past_its_closing_parenthesis
    f = spec("本物の略号は短く（`t0`、`a9`）、そのうえで t0 を裸で使う。\n")
    assert f.any? { |x| x.include?('VOCABULARY') && x.include?('t0') },
           "the t0 after the list is a use, not an exhibit: #{f.inspect}"
  end

  # The defaults that carry behaviour when a mode omits the key. Each drives
  # main() with the key absent and asserts the behaviour the default value
  # produces — a changed default has to redden one of these, not survive.

  def test_omitting_the_vocab_floor_admits_a_single_line
    out = decide('t0 が壊れます。', shorthand_patterns: ['([a-z]\d{1,2})'],
                                    gloss_patterns: ['[（(]'])
    assert_equal 'block', out['decision'], out.inspect
    assert_includes out.fetch('reason', ''), 'VOCABULARY'
  end

  # No mode-facing bound exists any more, so the default is structural: no
  # ambient Regexp.timeout is installed around the scan. Each match is granted
  # its bound inside bounded_match and the grant is revoked as the match ends;
  # between matches — which is where a stubbed measure observes — the global
  # is nil. The five-second default this test used to assert is retired with
  # the key (declared diff d3: the budget is now the hook's own remaining
  # time, ≈9.4s on a first read).
  def test_no_ambient_bound_is_installed_around_the_scan
    seen = :never_measured
    original = G.method(:measure)
    G.define_singleton_method(:measure) do |*|
      seen = Regexp.timeout
      [{ 'lines' => 1, 'headings' => 0, 'tables' => 0, 'diagrams' => 0,
         'announced' => false, 'unglossed' => [] }, []]
    end
    begin
      Dir.mktmpdir do |tmp|
        cfg_path = File.join(tmp, 'cfg.json')
        tx = File.join(tmp, 't.jsonl')
        File.write(cfg_path, JSON.generate('mode_name' => 't'), encoding: 'UTF-8')
        File.write(tx, JSON.generate(
          'type' => 'assistant',
          'message' => { 'content' => [{ 'type' => 'text', 'text' => 'x' }] }
        ) + "\n", encoding: 'UTF-8')
        capture_io do
          assert_equal 0, G.main(['--config', cfg_path],
                                 StringIO.new(JSON.generate('transcript_path' => tx)))
        end
      end
    ensure
      G.define_singleton_method(:measure, original)
    end
    assert_nil seen, 'no ambient bound: authorisation lives inside the seam, per match'
    assert_nil Regexp.timeout, 'and nothing is left behind afterwards'
  end

  def test_omitting_the_log_bound_rotates_at_exactly_one_megabyte
    { 1024 * 1024 => false, 1024 * 1024 + 1 => true }.each do |size, rotated|
      Dir.mktmpdir do |tmp|
        cfg_path = File.join(tmp, 'cfg.json')
        tx = File.join(tmp, 't.jsonl')
        log = File.join(tmp, 'gate.log')
        File.write(cfg_path, JSON.generate('mode_name' => 't', 'log_path' => log),
                   encoding: 'UTF-8')
        File.write(tx, JSON.generate(
          'type' => 'assistant',
          'message' => { 'content' => [{ 'type' => 'text', 'text' => 'x' }] }
        ) + "\n", encoding: 'UTF-8')
        File.write(log, 'x' * size, encoding: 'UTF-8')
        capture_io do
          assert_equal 0, G.main(['--config', cfg_path],
                                 StringIO.new(JSON.generate('transcript_path' => tx)))
        end
        assert_equal rotated, File.exist?("#{log}.1"),
                     "a #{size}-byte log must#{rotated ? '' : ' not'} rotate " \
                     'under the default one-megabyte bound'
        assert_includes File.read(log, encoding: 'UTF-8'), 'PASS',
                        'the record lands either way'
      end
    end
  end

  def test_the_log_is_append_only_across_turns
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx = File.join(tmp, 't.jsonl')
      log = File.join(tmp, 'gate.log')
      File.write(cfg_path, JSON.generate('mode_name' => 't', 'log_path' => log),
                 encoding: 'UTF-8')
      File.write(tx, JSON.generate(
        'type' => 'assistant',
        'message' => { 'content' => [{ 'type' => 'text', 'text' => 'x' }] }
      ) + "\n", encoding: 'UTF-8')
      2.times do
        capture_io do
          assert_equal 0, G.main(['--config', cfg_path],
                                 StringIO.new(JSON.generate('transcript_path' => tx)))
        end
      end
      lines = File.read(log, encoding: 'UTF-8').lines
      assert_equal 2, lines.length, "two turns, two records: #{lines.inspect}"
      assert(lines.all? { |l| l.include?("\tPASS") }, lines.inspect)
    end
  end

  def test_the_announcement_exemption_reads_only_the_first_line
    lines = (0...70).map { |i| "line #{i}" }
    lines[39] = 'This answer is long.'
    _, f = measure(lines.join("\n"), 'max_lines' => 60,
                                     'announce_patterns' => ['(?i:\blong\b)'])
    assert f.any? { |x| x.start_with?('LENGTH') },
           "an announcement buried on line 40 clears nothing: #{f.inspect}"
  end

  # --- the carry-over note ---------------------------------------------------
  #
  # Replaces round 6's marker fixtures wholesale. Those held a mechanism that no
  # longer exists: the recheck used to read Claude Code's block feedback back out
  # of the transcript and infer which block was its own, because one preface is
  # written for every blocking Stop hook. The inference is what six rounds of
  # review kept breaking, and the last attempt at it — step over a foreign marker
  # rather than stop at it — removed the only thing bounding the walk to one turn
  # and made the gate judge a previous turn's rewrite a second time.
  #
  # What the gate does now is record which record it blocked, at the moment it
  # blocks it. Every fixture below drives that: the note is written by the gate's
  # own write_note, never composed here.

  def test_the_first_read_writes_a_note_naming_the_record_it_blocked
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'gate.log')
      raw = { 'mode_name' => 'test', 'section' => '§ Test',
              'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'AAA')]),
                 encoding: 'UTF-8')
      out, _err, status = run_script(
        cfg_path, JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => false)
      )
      assert_equal 0, status.exitstatus
      assert_equal 'block', JSON.parse(out)['decision']

      path = G.note_path(tx_path, G::Config.new(raw, cfg_path))
      assert File.exist?(path), "the block left no note at #{path}"
      data = JSON.parse(File.read(path))
      assert_equal 'AAA', data['blocked_uuid'], data.inspect
      assert_equal tx_path, data['transcript'], data.inspect
      assert_equal 'test', data['mode'], data.inspect
      assert_in_delta Time.now.to_f, data['at'], 60.0, 'the note is stamped when it is written'
    end
  end

  # A first read that passes must leave nothing behind. A note written on every
  # turn would make the next recheck judge a turn this gate never blocked.
  def test_a_first_read_that_does_not_block_writes_no_note
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      raw = { 'mode_name' => 'test', 'log_path' => File.join(tmp, 'gate.log'),
              'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: REWRITE, uuid: 'AAA')]),
                 encoding: 'UTF-8')
      run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                         'stop_hook_active' => false))
      refute File.exist?(G.note_path(tx_path, G::Config.new(raw, cfg_path))),
             'nothing was blocked, so there is nothing to remember'
    end
  end

  # A mode that declares blocking false never blocks, so it never writes a note
  # and has no recheck verdicts. Stated rather than branched on: before the
  # note, such a mode did get verdicts, and they were keyed off another hook's
  # marker — wrong ones.
  def test_a_non_blocking_mode_writes_no_note
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      raw = { 'mode_name' => 'test', 'log_path' => File.join(tmp, 'gate.log'),
              'max_headings' => 3, 'blocking' => false }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'AAA')]),
                 encoding: 'UTF-8')
      out, = run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                                'stop_hook_active' => false))
      refute JSON.parse(out).key?('decision'), 'blocking false must not block'
      refute File.exist?(G.note_path(tx_path, G::Config.new(raw, cfg_path)))
    end
  end

  # The whole point, stated as a fixture: the transcript's block feedback is now
  # inert. Same rows that used to yield a verdict, no note, no verdict.
  def test_the_transcripts_block_feedback_is_no_longer_evidence
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB'))
    _out, log = drive(rows, max_headings: 3)
    assert_includes log, 'SKIP-nonote', log.inspect
    refute_includes log, 'rec=BBB',
                     'the feedback record alone must not produce a verdict any more'
  end

  # The defect the note was adopted to remove, driven in the arrangement the
  # pre-dispatch falsifier used on 2026-08-26: this gate blocked, the rewrite
  # landed and was judged, a text-less boundary follows, and then another hook
  # blocks. The stepping-over walk reached back past the turn boundary and
  # judged BBB a second time. With the note consumed by BBB's own recheck there
  # is nothing left to reach with.
  def test_a_turn_blocked_only_by_another_hook_reaches_no_earlier_rewrite
    rows = [row_for('assistant', text: BLOCKED, uuid: 'AAA'),
            row_for('user', text: own_marker, parent: 'AAA', uuid: 'MMM'),
            row_for('assistant', text: REWRITE, uuid: 'BBB'),
            row_for('user', uuid: 'IMG', text: nil),
            row_for('user', text: foreign_marker, parent: 'IMG', uuid: 'F1')]
    out, log = drive(rows, max_headings: 3)
    assert_includes log, 'SKIP-nonote', log.inspect
    refute_includes log, 'rec=BBB',
                     'BBB is the previous turn s rewrite and already carries a verdict'
    assert_includes out.fetch('systemMessage', ''), 'did not block this turn', out.inspect
    refute out.key?('decision'), 'a recheck never blocks'
  end

  # Consume on read. 28 of 240 blocks in the 2026-08-26 measurement drew no
  # recheck, so a note left in place outlives its turn about one time in nine.
  def test_the_note_is_spent_by_the_recheck_that_reads_it
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'gate.log')
      raw = { 'mode_name' => 'test', 'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json(blocked_then(row_for('assistant', text: REWRITE,
                                                         uuid: 'BBB'))), encoding: 'UTF-8')
      cfg_obj = G::Config.new(raw, cfg_path)
      assert_nil G.write_note(tx_path, cfg_obj, 'AAA')

      stdin = JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => true)
      run_script(cfg_path, stdin)
      refute File.exist?(G.note_path(tx_path, cfg_obj)), 'the note must be spent'

      run_script(cfg_path, stdin)
      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'RECHECK-PASS-ok\trec=BBB'.gsub('\t', "\t"), log.inspect
      assert_includes log, 'SKIP-nonote', "the second recheck must find nothing: #{log}"
      assert_equal 1, log.scan('rec=BBB').length,
                   "one verdict per rewrite, not one per recheck: #{log}"
    end
  end

  # The bound is 300s against a measured maximum of 109s over 212 rechecks. An
  # older note belongs to a turn that was interrupted.
  def test_a_note_older_than_the_bound_is_refused
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB'))
    _out, fresh = drive(rows, note: 'AAA', note_at: G::NOTE_TTL_SECONDS - 30, max_headings: 3)
    assert_includes fresh, 'rec=BBB', "just inside the bound must still be used: #{fresh}"

    out, stale = drive(rows, note: 'AAA', note_at: G::NOTE_TTL_SECONDS + 30, max_headings: 3)
    assert_includes stale, 'SKIP-nonote-stale', stale.inspect
    refute_includes stale, 'rec=BBB', 'a stale note must not name a record'
    assert_includes out.fetch('systemMessage', ''), 'interrupted', out.inspect
  end

  # A note stamped ahead of the clock reading it is as unusable as one from too
  # far back, and a bound written as a single greater-than lets it through.
  def test_a_note_stamped_in_the_future_is_refused
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB'))
    _out, log = drive(rows, note: 'AAA', note_at: -600, max_headings: 3)
    assert_includes log, 'SKIP-nonote-stale', log.inspect
    refute_includes log, 'rec=BBB', log.inspect
  end

  # The note's own fields are checked, not just its file name. A note that
  # cannot be parsed, or that names a different session, must stop the recheck
  # rather than be resolved in favour of judging something.
  def test_a_note_that_does_not_check_out_is_refused
    %w[corrupt wrong_transcript wrong_mode no_uuid bad_stamp].each do |kind|
      Dir.mktmpdir do |tmp|
        cfg_path = File.join(tmp, 'cfg.json')
        tx_path = File.join(tmp, 't.jsonl')
        log_path = File.join(tmp, 'gate.log')
        raw = { 'mode_name' => 'test', 'log_path' => log_path, 'max_headings' => 3 }
        File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
        File.write(tx_path, rows_json(blocked_then(row_for('assistant', text: REWRITE,
                                                           uuid: 'BBB'))), encoding: 'UTF-8')
        cfg_obj = G::Config.new(raw, cfg_path)
        path = G.note_path(tx_path, cfg_obj)
        FileUtils.mkdir_p(File.dirname(path))
        good = { 'transcript' => tx_path, 'mode' => 'test',
                 'blocked_uuid' => 'AAA', 'at' => Time.now.to_f }
        body =
          case kind
          when 'corrupt' then '{not json'
          when 'wrong_transcript' then JSON.generate(good.merge('transcript' => '/elsewhere'))
          when 'wrong_mode' then JSON.generate(good.merge('mode' => 'other'))
          when 'no_uuid' then JSON.generate(good.merge('blocked_uuid' => ''))
          else JSON.generate(good.merge('at' => 'noon'))
          end
        File.write(path, body)
        run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                           'stop_hook_active' => true))
        log = File.read(log_path, encoding: 'UTF-8')
        assert_includes log, 'SKIP-nonote-mismatch', "#{kind}: #{log}"
        refute_includes log, 'rec=', "#{kind} must not name a record: #{log}"
        refute File.exist?(path), "#{kind}: an unusable note must still be spent"
      end
    end
  end

  # The blocked record is written before the block, so if it is not in the
  # window it never will be. Spending the budget waiting for it is 4s of nothing.
  def test_a_note_naming_a_record_outside_the_window_gives_up_at_once
    rows = [row_for('assistant', text: REWRITE, uuid: 'BBB')]
    started = Time.now
    out, log = drive(rows, note: 'GONE', max_headings: 3)
    elapsed = Time.now - started
    assert_includes log, 'SKIP-blocked-record-gone', log.inspect
    refute_includes log, 'rec=BBB', 'nothing is known to lie after a record that is not there'
    assert_operator elapsed, :<, G::RECHECK_POLL_ATTEMPTS * G::POLL_DELAY,
                    'the give-up must not spend the recheck budget'
    assert_includes out.fetch('systemMessage', ''), 'no longer in the part of the transcript'
  end

  # mode_name is operator-supplied and defaults to '?'. Built into a file name
  # directly it is a path the operator steers.
  def test_a_mode_name_that_is_a_path_cannot_escape_the_note_directory
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'logs', 'gate.log')
      escape = File.join(tmp, 'ESCAPED')
      raw = { 'mode_name' => "../../#{File.basename(escape)}", 'log_path' => log_path,
              'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'AAA')]),
                 encoding: 'UTF-8')
      run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                         'stop_hook_active' => false))
      notes = File.join(File.dirname(log_path), 'readable_gate_notes')
      written = Dir.glob(File.join(notes, '*'))
      assert_equal 1, written.length, "the note must land inside #{notes}: #{written.inspect}"
      assert_match(/\A[0-9a-f]{32}\.json\z/, File.basename(written.first))
      refute File.exist?(escape), 'the mode name steered the write out of the directory'
      refute File.exist?("#{escape}.json"), 'the mode name steered the write out of the directory'
    end
  end

  # A note that cannot be written must not cost the block. Enforcement does not
  # depend on the note; only the recheck's verdict does.
  def test_a_note_that_cannot_be_written_still_blocks_and_says_so
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      logs = File.join(tmp, 'logs')
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, 'gate.log')
      raw = { 'mode_name' => 'test', 'section' => '§ Test',
              'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'AAA')]),
                 encoding: 'UTF-8')
      # Occupy the notes directory's name with a file, so mkdir_p cannot make it.
      File.write(File.join(logs, 'readable_gate_notes'), 'in the way')

      out, _err, status = run_script(
        cfg_path, JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => false)
      )
      assert_equal 0, status.exitstatus
      assert_equal 'block', JSON.parse(out)['decision'], 'the turn is still blocked'
      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'NOTE-WRITE-FAILED', "the failure must be visible: #{log}"
      assert_includes log, 'FAIL-ok', 'and the verdict is still recorded'
    end
  end

  # No log declared means no place for a note, and the gate says so by writing
  # neither rather than by raising. Enforcement is unaffected.
  def test_a_mode_with_no_log_blocks_but_keeps_no_note
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      raw = { 'mode_name' => 'test', 'section' => '§ Test', 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'AAA')]),
                 encoding: 'UTF-8')
      out, _err, status = run_script(
        cfg_path, JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => false)
      )
      assert_equal 0, status.exitstatus
      assert_equal 'block', JSON.parse(out)['decision']
      assert_nil G.note_path(tx_path, G::Config.new(raw, cfg_path)),
                 'no log path means no note path'
    end
  end

  # Two modes' gates can run against one session. Their notes must not be the
  # same file, or each spends the other's.
  def test_two_modes_on_one_session_keep_separate_notes
    Dir.mktmpdir do |tmp|
      tx_path = File.join(tmp, 't.jsonl')
      raw = { 'log_path' => File.join(tmp, 'gate.log') }
      a = G::Config.new(raw.merge('mode_name' => 'masa'), '<inline>')
      b = G::Config.new(raw.merge('mode_name' => 'tutorial'), '<inline>')
      refute_equal G.note_path(tx_path, a), G.note_path(tx_path, b)

      assert_nil G.write_note(tx_path, a, 'AAA')
      assert_nil G.write_note(tx_path, b, 'BBB')
      assert_equal ['AAA', nil], G.take_note(tx_path, a)
      assert_equal ['BBB', nil], G.take_note(tx_path, b),
                   "spending one mode's note must not spend the other's"
    end
  end

  # Two sessions of one mode, for the same reason.
  def test_two_sessions_of_one_mode_keep_separate_notes
    Dir.mktmpdir do |tmp|
      c = G::Config.new({ 'mode_name' => 'test', 'log_path' => File.join(tmp, 'gate.log') },
                        '<inline>')
      one = File.join(tmp, 'one.jsonl')
      two = File.join(tmp, 'two.jsonl')
      refute_equal G.note_path(one, c), G.note_path(two, c)

      assert_nil G.write_note(one, c, 'AAA')
      assert_equal [nil, 'nonote'], G.take_note(two, c)
      assert_equal ['AAA', nil], G.take_note(one, c)
    end
  end

  # emit scrubs on the way out, so write_note scrubs too; comparing the raw name
  # on one side only loses every recheck for exactly the modes whose name
  # carries a byte that is not valid UTF-8, and for no other mode.
  def test_a_mode_name_with_an_invalid_byte_still_finds_its_own_note
    Dir.mktmpdir do |tmp|
      c = G::Config.new({ 'mode_name' => "te\xFFst", 'log_path' => File.join(tmp, 'gate.log') },
                        '<inline>')
      tx = File.join(tmp, 't.jsonl')
      assert_nil G.write_note(tx, c, 'AAA')
      assert_equal ['AAA', nil], G.take_note(tx, c)
    end
  end

  # --- what the 2026-08-26 mutation run found unwitnessed --------------------
  #
  # Four mutations survived the first run against the note. One of them — the
  # mode name scrubbed twice in the block reason — turned out to be a no-op
  # rather than a gap, and the redundant scrub was deleted instead of pinned.
  # The three below are real gaps and these are what close them.

  # The reason the operator reads is a shipped string. Nothing asserted its
  # opening, so rewriting it — a colon added, the constant abandoned — left all
  # 122 tests green. Written out here rather than taken from the gate: a fixture
  # that borrows the value it is checking cannot fail when the value is wrong.
  def test_the_block_reason_opens_with_the_shipped_wording_and_the_mode_name
    out = decide(FOUR_HEADINGS, max_headings: 3, mode_name: 'masa')
    reason = out.fetch('reason', '')
    assert reason.start_with?('Your last message violates masa'),
           "the operator-facing opening is a shipped string: #{reason.inspect}"
    refute_includes reason, 'violates:', 'no colon between the wording and the mode name'
  end

  # The lifetime is a number with grounds — 300s against a measured maximum of
  # 109s over 212 rechecks — and every staleness fixture computed its backdate
  # from the constant, so the constant could take any value with the suite
  # green. These two pin the value itself: two minutes is inside the measured
  # range and must be honoured, ten minutes is far outside it and must not be.
  def test_the_note_lifetime_is_the_measured_one_not_merely_some_number
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB'))

    _out, recent = drive(rows, note: 'AAA', note_at: 120, max_headings: 3)
    assert_includes recent, 'rec=BBB',
                    "120s is inside the measured range and must be honoured: #{recent}"

    _out2, old = drive(rows, note: 'AAA', note_at: 600, max_headings: 3)
    assert_includes old, 'SKIP-nonote-stale',
                    "600s is far past any measured recheck and must not be: #{old}"
  end

  # A blocked record carrying no uuid leaves nothing to record. Inventing a
  # placeholder writes a note that names a record no transcript contains, so
  # every recheck of that turn reports the blocked record as gone — a wrong
  # answer in place of an honest refusal. Reachable: the first read takes the
  # uuid straight off the record, and a record without one is valid JSON.
  def test_a_block_with_no_record_id_records_nothing_and_says_so
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'gate.log')
      raw = { 'mode_name' => 'test', 'section' => '§ Test',
              'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED)]), encoding: 'UTF-8')

      out, = run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                                'stop_hook_active' => false))
      assert_equal 'block', JSON.parse(out)['decision'], 'the turn is still blocked'
      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'NOTE-WRITE-FAILED: no uuid to record', log
      notes = File.join(File.dirname(log_path), 'readable_gate_notes')
      assert_empty Dir.glob(File.join(notes, '*')),
                   'a placeholder note would name a record no transcript holds'
    end
  end

  # And the recheck of that same turn declines rather than guessing.
  def test_the_recheck_of_a_block_that_recorded_nothing_declines
    _out, log = drive(blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB')),
                      max_headings: 3)
    assert_includes log, 'SKIP-nonote', log
    refute_includes log, 'blocked-record-gone',
                    'nothing was recorded, so nothing is missing'
  end

  # --- what round 1 of the conformance review found ---------------------------

  # A note that could not be deleted has not been consumed. Using it anyway
  # leaves it on disk for the next turn to read again, and the review drove
  # exactly that: two RECHECK-PASS rows naming one record, which is the
  # invariant this design exists to hold.
  #
  # Every other unusable-note fixture in this file uses a deletable note, which
  # is why ten of them and a mutation run of 47 all passed over this.
  def test_a_note_that_cannot_be_deleted_is_refused_rather_than_reused
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      logs = File.join(tmp, 'logs')
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, 'gate.log')
      raw = { 'mode_name' => 'test', 'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json(blocked_then(row_for('assistant', text: REWRITE,
                                                         uuid: 'BBB'))), encoding: 'UTF-8')
      cfg_obj = G::Config.new(raw, cfg_path)
      assert_nil G.write_note(tx_path, cfg_obj, 'AAA')
      notes = File.dirname(G.note_path(tx_path, cfg_obj))

      stdin = JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => true)
      File.chmod(0o555, notes) # readable and listable, entries cannot be removed
      begin
        out, _err, status = run_script(cfg_path, stdin)
        assert_equal 0, status.exitstatus
        run_script(cfg_path, stdin)
      ensure
        File.chmod(0o755, notes)
      end

      log = File.read(log_path, encoding: 'UTF-8')
      assert_equal 2, log.scan('SKIP-nonote-unspent').length,
                   "both rechecks must refuse the note they could not spend: #{log}"
      refute_includes log, 'rec=BBB',
                       "an unspendable note must produce no verdict at all: #{log}"
      assert_includes JSON.parse(out).fetch('systemMessage', ''), 'could not be deleted',
                      'the operator is told why, and where to look'
      refute JSON.parse(out).key?('decision'), 'a recheck never blocks'
    end
  end

  # The design says the digest is taken over the transcript's absolute path. The
  # code hashed whatever the caller wrote, so one file reached by two spellings
  # produced two notes and the recheck lost its verdict.
  def test_the_note_is_found_through_a_different_spelling_of_one_transcript
    Dir.mktmpdir do |tmp|
      real = File.realpath(tmp)
      c = G::Config.new({ 'mode_name' => 'test', 'log_path' => File.join(real, 'gate.log') },
                        '<inline>')
      absolute = File.join(real, 't.jsonl')
      relative = File.join(real, 'sub', '..', 't.jsonl')

      assert_equal G.note_path(absolute, c), G.note_path(relative, c),
                   'two spellings of one file are one transcript'
      assert_nil G.write_note(relative, c, 'AAA')
      assert_equal ['AAA', nil], G.take_note(absolute, c),
                   'a note written through one spelling is found through the other'
    end
  end

  # The banner for a note stamped ahead of the clock used to assert the opposite
  # of what happened — "more than 300s old" for something from the future.
  def test_the_stale_banner_covers_both_halves_of_the_age_test
    rows = blocked_then(row_for('assistant', text: REWRITE, uuid: 'BBB'))

    old_out, = drive(rows, note: 'AAA', note_at: 600, max_headings: 3)
    future_out, = drive(rows, note: 'AAA', note_at: -600, max_headings: 3)

    [old_out, future_out].each do |out|
      message = out.fetch('systemMessage', '')
      assert_includes message, 'not from this turn', message
      assert_includes message, 'stamped ahead of the clock', message
    end
  end

  # --- what round 2 of the conformance review found ---------------------------
  #
  # A leftover note from an interrupted turn checks out as valid: fresh, same
  # session, deletable. When the next block's own note write fails, the recheck
  # read that leftover and judged the message this turn had just blocked — no
  # foreign hook involved, no filesystem failure needed (a record with no uuid
  # is enough). After a block, the note must be this block's or absent.

  def test_a_failed_note_write_also_spends_the_note_an_earlier_turn_left
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      log_path = File.join(tmp, 'gate.log')
      raw = { 'mode_name' => 'test', 'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'AAA'),
                                     row_for('assistant', text: BLOCKED)]),
                 encoding: 'UTF-8')
      cfg_obj = G::Config.new(raw, cfg_path)
      assert_nil G.write_note(tx_path, cfg_obj, 'AAA'), 'the interrupted turn left its note'

      out, = run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                                'stop_hook_active' => false))
      assert_equal 'block', JSON.parse(out)['decision'], 'the turn is still blocked'
      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'NOTE-WRITE-FAILED: no uuid to record; a stale note was deleted', log
      assert_empty Dir.glob(File.join(File.dirname(G.note_path(tx_path, cfg_obj)), '*')),
                   'the leftover would name a block this turn did not make'

      _out2, = run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                                  'stop_hook_active' => true))
      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'SKIP-nonote', "the recheck must decline, not judge: #{log}"
      refute_includes log, 'RECHECK-',
                      "a verdict here re-judges the message this turn blocked: #{log}"
    end
  end

  # When the leftover cannot be spent either, the two failures must compose to
  # the same refusal: the leftover stays, and the recheck refuses it as the
  # note it cannot delete.
  def test_a_leftover_the_failed_write_cannot_spend_is_refused_at_the_recheck
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      logs = File.join(tmp, 'logs')
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, 'gate.log')
      raw = { 'mode_name' => 'test', 'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'AAA'),
                                     row_for('assistant', text: BLOCKED, uuid: 'BBB')]),
                 encoding: 'UTF-8')
      cfg_obj = G::Config.new(raw, cfg_path)
      assert_nil G.write_note(tx_path, cfg_obj, 'AAA'), 'the interrupted turn left its note'
      notes = File.dirname(G.note_path(tx_path, cfg_obj))

      File.chmod(0o555, notes) # neither the new write nor the spend can touch it
      begin
        out, = run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                                  'stop_hook_active' => false))
        assert_equal 'block', JSON.parse(out)['decision'], 'the turn is still blocked'
        log = File.read(log_path, encoding: 'UTF-8')
        assert_includes log, 'a stale note could not be deleted',
                        "the second failure must be visible too: #{log}"

        run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                           'stop_hook_active' => true))
      ensure
        File.chmod(0o755, notes)
      end

      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'SKIP-nonote-unspent',
                      "the unspendable leftover must be refused: #{log}"
      refute_includes log, 'RECHECK-',
                      "a verdict here re-judges the message this turn blocked: #{log}"
    end
  end

  # Round 3: unspendability is not stable. A directory that refuses the unlink
  # at block time and permits it again before the recheck let the recheck spend
  # the leftover this block had failed to delete — round 2's defect through a
  # transient window. Deleting needs directory-write; truncating needs only
  # file-write; an emptied note fails the parse on every later read, whatever
  # the directory permits by then.
  def test_a_leftover_spent_by_truncation_stays_spent_after_the_window_lifts
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      logs = File.join(tmp, 'logs')
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, 'gate.log')
      raw = { 'mode_name' => 'test', 'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'AAA'),
                                     row_for('assistant', text: BLOCKED, uuid: 'BBB')]),
                 encoding: 'UTF-8')
      cfg_obj = G::Config.new(raw, cfg_path)
      assert_nil G.write_note(tx_path, cfg_obj, 'AAA'), 'the interrupted turn left its note'
      notes = File.dirname(G.note_path(tx_path, cfg_obj))

      File.chmod(0o555, notes) # the write and the unlink both fail; file-write does not
      begin
        out, = run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                                  'stop_hook_active' => false))
        assert_equal 'block', JSON.parse(out)['decision'], 'the turn is still blocked'
      ensure
        File.chmod(0o755, notes) # the window lifts before the recheck
      end
      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'a stale note could not be deleted and was emptied instead', log

      run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                         'stop_hook_active' => true))
      log = File.read(log_path, encoding: 'UTF-8')
      refute_includes log, 'RECHECK-',
                      "the emptied leftover must not yield a verdict once the window lifts: #{log}"
      assert_includes log, 'SKIP-nonote-mismatch',
                      "an emptied note fails the parse and is refused by name: #{log}"
    end
  end

  # --- what round 4 of the conformance review found ---------------------------
  #
  # The truncation fallback wrote through whatever the note's name pointed at.
  # A symlink planted at the note key — the directory then made unwritable so
  # the unlink cannot spend it — let the emptying reach a file outside the
  # notes directory. Two seats demonstrated it. The fix opens with NOFOLLOW and
  # leans to refusing: the link stays unspent, the file it names stays intact,
  # and every later recheck refuses the leftover by name.
  def test_the_truncation_does_not_follow_a_symlink_out_of_the_notes_directory
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      logs = File.join(tmp, 'logs')
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, 'gate.log')
      raw = { 'mode_name' => 'test', 'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'BBB')]),
                 encoding: 'UTF-8')
      cfg_obj = G::Config.new(raw, cfg_path)

      victim = File.join(tmp, 'victim.txt')
      File.write(victim, 'the operator wrote this', encoding: 'UTF-8')
      note_file = G.note_path(tx_path, cfg_obj)
      FileUtils.mkdir_p(File.dirname(note_file))
      File.symlink(victim, note_file)
      notes = File.dirname(note_file)

      File.chmod(0o555, notes) # the write and the unlink both fail; only the truncation is left
      begin
        out, = run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                                  'stop_hook_active' => false))
        assert_equal 'block', JSON.parse(out)['decision'], 'the turn is still blocked'
        assert_equal 'the operator wrote this', File.read(victim, encoding: 'UTF-8'),
                     'emptying the leftover must not reach through its name'
        log = File.read(log_path, encoding: 'UTF-8')
        assert_includes log, 'a stale note could not be deleted', log
        refute_includes log, 'was emptied instead',
                        'an emptying that was refused must not be reported as done'

        run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                           'stop_hook_active' => true))
      ensure
        File.chmod(0o755, notes)
      end

      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'SKIP-nonote-unspent',
                      "the surviving link must be refused, not read: #{log}"
      refute_includes log, 'RECHECK-',
                      "a verdict here judged whatever the link names: #{log}"
      assert_equal 'the operator wrote this', File.read(victim, encoding: 'UTF-8'),
                   'the recheck must not reach through the name either'
    end
  end

  # Round 6's corrected claim states two refusal arms, and this pins the second:
  # when the link's target exists but cannot be read, take_note's read fails
  # before the unlink is ever attempted, so the refusal is named nonote — not
  # nonote-unspent — and the linked bytes are never parsed. Round 5's claim said
  # nonote-unspent for every recheck; the codex seat refused it with this state.
  def test_a_link_to_an_unreadable_target_is_refused_as_nonote_before_the_unlink
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      logs = File.join(tmp, 'logs')
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, 'gate.log')
      raw = { 'mode_name' => 'test', 'log_path' => log_path, 'max_headings' => 3 }
      File.write(cfg_path, JSON.generate(raw), encoding: 'UTF-8')
      File.write(tx_path, rows_json([row_for('assistant', text: BLOCKED, uuid: 'BBB')]),
                 encoding: 'UTF-8')
      cfg_obj = G::Config.new(raw, cfg_path)

      victim = File.join(tmp, 'victim.txt')
      File.write(victim, 'the operator wrote this', encoding: 'UTF-8')
      note_file = G.note_path(tx_path, cfg_obj)
      FileUtils.mkdir_p(File.dirname(note_file))
      File.symlink(victim, note_file)
      notes = File.dirname(note_file)

      File.chmod(0o000, victim) # the read fails before the unlink can be tried
      File.chmod(0o555, notes)
      begin
        run_script(cfg_path, JSON.generate('transcript_path' => tx_path,
                                           'stop_hook_active' => true))
      ensure
        File.chmod(0o755, notes)
        File.chmod(0o644, victim)
      end

      log = File.read(log_path, encoding: 'UTF-8')
      assert_includes log, 'SKIP-nonote', "the failed read refuses by the nonote name: #{log}"
      refute_includes log, 'SKIP-nonote-unspent',
                      'the unlink was never reached, so its refusal name must not appear'
      refute_includes log, 'RECHECK-',
                      "a verdict here parsed bytes the read should never have used: #{log}"
      assert File.symlink?(note_file), 'the leftover stays: nothing consumed it'
      assert_equal 'the operator wrote this', File.read(victim, encoding: 'UTF-8'),
                   'the linked bytes are unchanged'
    end
  end

  # The exception path of the write — not just the no-uuid return — must spend
  # the leftover too. Driven in-process because the deterministic failure is a
  # directory squatting the temporary name, and that name carries the pid.
  def test_a_write_that_raises_spends_the_leftover_before_reporting
    Dir.mktmpdir do |tmp|
      c = G::Config.new({ 'mode_name' => 'test', 'log_path' => File.join(tmp, 'gate.log') },
                        '<inline>')
      tx = File.join(tmp, 't.jsonl')
      assert_nil G.write_note(tx, c, 'AAA'), 'the interrupted turn left its note'
      path = G.note_path(tx, c)
      FileUtils.mkdir_p("#{path}.#{Process.pid}.tmp") # the write raises, the spend can work

      failure = G.write_note(tx, c, 'BBB')
      refute_nil failure, 'the write must report its failure'
      assert_includes failure, 'a stale note was deleted', failure
      refute File.exist?(path), 'the leftover would name a block this turn did not make'
      assert_equal [nil, 'nonote'], G.take_note(tx, c),
                   'the recheck must find nothing rather than the wrong block'
    end
  end

  # --- the measurement bound: the seam, its floor, its witnesses (design v0.7)
  #
  # Every mode-supplied match passes through bounded_match: bound computed from
  # the time actually remaining, floor below a millisecond, grant revoked as
  # the match ends. The fixtures below are the design's §5 pass conditions.
  # Deadline-reaching fixtures assert a wall-time BAND (9.3 < wall < 9.8) and
  # the banner KIND, never just "something was emitted"; in-process fixtures
  # assert their own premise inside themselves (a fixture whose premise fails
  # silently is how three review rounds were spent).

  # The catastrophic pattern. Plain (a+)+b is neutralised by Ruby 3.4's
  # linear-time optimisation; the backreference disables it, and the subject
  # "x" + "a"*46 does not return within hours unbounded (a*40 was already
  # ~2^14 × 0.74s). Everything that must be CUT uses this; the one thing that
  # must FINISH unbounded (§5-13's second leg) uses a*27, about 1.5s.
  EVIL_SRC = '(x)(a+)+b\1'
  EVIL_SUBJECT = "x#{'a' * 46}".freeze

  # §5-1: two-stage — cheap matches burn most of the budget, then the runaway
  # meets its subject and is granted only what remains. The grant is the
  # remaining time, so the cut lands on the deadline wherever the cheap phase
  # ends (~6-7s here; the runaway absorbs the rest on any machine speed).
  # Deleting `Regexp.timeout = remaining` in the seam turns this red by the
  # 30s outer kill: the runaway would run for hours.
  #
  # Declared machine-speed premise: the cheap phase (~6.8s here) must finish
  # inside the 9.5s budget for the runaway to be reached at all; a ~1.4x
  # slower machine silently turns this into a second accumulation fixture.
  # Both outcomes keep the band and the banner, so the premise has no
  # in-fixture witness — the per-family fixtures below carry the runaway-cut
  # property independently either way.
  def test_a_runaway_late_in_the_scan_is_granted_only_the_remaining_time
    patterns = (1..1200).map do |i|
      "(?<![A-Za-z0-9_])([A-Z]{1,4}★|[A-Z]{2,5}-#{i}\\d+|[PR]\\d+|[a-z]\\d{1,2})"
    end
    patterns << EVIL_SRC
    text = (['これは普通の散文の行で、INV-5 や a9 のような語を含みます。'] * 3999)
           .join("\n") + "\n#{EVIL_SUBJECT}"

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = decide(text, shorthand_patterns: patterns, gloss_patterns: ['[(（]'],
                       vocab_min_lines: 1, max_headings: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>, 9.3, format('took %.1fs — the budget was not used', elapsed)
    assert_operator elapsed, :<, 9.8, format('took %.1fs — the runaway was not cut', elapsed)
    refute out.key?('decision'), out.inspect
    assert_includes out.fetch('systemMessage', ''), 'measurement ran out of the hook budget'
  end

  # §5-2: the same crossing driven on a RECHECK, where ~4s of poll have already
  # been spent before measurement begins — the transcript shape is the one the
  # natural construction does not produce (a newer text-less record above the
  # rewrite, so the wait runs its whole budget and deep_after_index resolves).
  # A deadline recomputed at the measurement call instead of main's head lands
  # at ≈13.6s here, past the band's top edge.
  #
  # The band cannot see whether the poll actually ran: the deadline is
  # absolute, so the total is ≈9.5s with or without it. The companion run below
  # is the premise assert — same transcript, cheap config, so its wall is
  # dominated by the poll itself (≈4.1s if the poll ran, ≈0.1s if not).
  # ONE transcript for the recheck fixture and its companion, built here so the
  # two cannot drift apart: the design requires the companion to share the
  # measured fixture's transcript, because the companion is what proves that
  # transcript actually spends the poll — a premise the band cannot see.
  def deep_poll_rows
    heavy = (['これは普通の散文の行で、INV-5 や a9 のような語を含みます。'] * 3999)
            .join("\n") + "\n#{EVIL_SUBJECT}"
    [row_for('assistant', text: FOUR_HEADINGS, uuid: 'AAA'),
     row_for('assistant', text: heavy, uuid: 'BBB'),
     row_for('assistant', uuid: 'CCC', thinking: true)]
  end

  def test_a_recheck_measurement_is_cut_at_the_same_absolute_deadline
    patterns = (1..1200).map { |i| "(?<![A-Za-z0-9_])([A-Z]{2,5}-#{i}\\d+|[a-z]\\d{1,2})" }
    patterns << EVIL_SRC

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, = drive(deep_poll_rows, note: 'AAA', shorthand_patterns: patterns,
                                 gloss_patterns: ['[(（]'], vocab_min_lines: 1, max_headings: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>, 9.3, format('took %.1fs — the budget was not used', elapsed)
    assert_operator elapsed, :<, 9.8, format('took %.1fs — poll and measurement did not share ' \
                                             'one absolute deadline', elapsed)
    assert_includes out.fetch('systemMessage', ''), 'measurement ran out of the hook budget'
    # No in-fixture premise token exists on this path: the measure-timeout log
    # row is SKIP-measure-timeout, which carries no why code, so the deep-poll
    # token never reaches the log here. The companion below is the premise
    # witness, and it shares this fixture's transcript so the two cannot drift.
  end

  def test_the_recheck_fixtures_transcript_really_spends_the_poll
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, = drive(deep_poll_rows, note: 'AAA', max_headings: 3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>=, 4.0,
                    format('took %.1fs — the poll was skipped, so the fixture above is ' \
                           'a duplicate of the first-read one', elapsed)
    message = out.fetch('systemMessage', '')
    assert_includes message, '(recheck', message
    refute_includes message, 'NOT RUN', 'the cheap companion must reach a verdict'
  end

  # §5-4: one runaway per pattern family, each with its reachability named.
  # A family bypassed around the seam runs at the ambient nil — unbounded —
  # and dies on the 30s outer kill; that this is observable AT ALL is the
  # revocation's doing (a bypassed match used to inherit the previous grant).

  # ① announce. Reachability: announce matches only the FIRST non-blank line,
  # and shorthand stays empty so the whole vocabulary block is skipped — the
  # path where nothing else would ever set a bound.
  def test_a_runaway_announce_pattern_is_cut_even_when_the_vocab_loop_never_runs
    text = "#{EVIL_SUBJECT}\nsecond line\n"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = decide(text, announce_patterns: [EVIL_SRC], max_lines: 10)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>, 9.3, format('took %.1fs', elapsed)
    assert_operator elapsed, :<, 9.8, format('took %.1fs', elapsed)
    assert_includes out.fetch('systemMessage', ''), 'measurement ran out of the hook budget'
  end

  # ② gloss, first operand. Reachability: one cheap shorthand pattern accepts
  # a token, and the runaway subject sits in the text after it on the same
  # line, which is gloss's first operand.
  def test_a_runaway_gloss_pattern_is_cut_on_the_same_line_operand
    text = "a1 #{EVIL_SUBJECT}\n"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = decide(text, shorthand_patterns: ['([a-z]\d)'], gloss_patterns: [EVIL_SRC],
                       vocab_min_lines: 1, max_headings: 3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>, 9.3, format('took %.1fs', elapsed)
    assert_operator elapsed, :<, 9.8, format('took %.1fs', elapsed)
    assert_includes out.fetch('systemMessage', ''), 'measurement ran out of the hook budget'
  end

  # ③ gloss, second operand. The || short-circuit means an operand-level
  # bypass on nxt alone survives an ②-shaped fixture: here the first operand
  # fails cheaply and the runaway subject is the NEXT line.
  def test_a_runaway_gloss_pattern_is_cut_on_the_next_line_operand
    text = "a1 zzz\n#{EVIL_SUBJECT}\n"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = decide(text, shorthand_patterns: ['([a-z]\d)'], gloss_patterns: [EVIL_SRC],
                       vocab_min_lines: 1, max_headings: 3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>, 9.3, format('took %.1fs', elapsed)
    assert_operator elapsed, :<, 9.8, format('took %.1fs', elapsed)
    assert_includes out.fetch('systemMessage', ''), 'measurement ran out of the hook budget'
  end

  # ④ specimen. Reachability: specimen_spans is called only inside the
  # vocabulary block, so a cheap shorthand pattern must be declared for the
  # specimen scan to run at all.
  def test_a_runaway_specimen_pattern_is_cut_inside_the_vocab_loop
    text = "a1 #{EVIL_SUBJECT}\n"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = decide(text, shorthand_patterns: ['([a-z]\d)'], specimen_patterns: [EVIL_SRC],
                       gloss_patterns: ['[(（]'], vocab_min_lines: 1, max_headings: 3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>, 9.3, format('took %.1fs', elapsed)
    assert_operator elapsed, :<, 9.8, format('took %.1fs', elapsed)
    assert_includes out.fetch('systemMessage', ''), 'measurement ran out of the hook budget'
  end

  # §5-5: the floor, witnessed on a clock this fixture owns. The stub replaces
  # the module helper, so `remaining` is exactly 5e-4 — positive, below the
  # floor — with no dependence on scheduling or on where the fixed value sits
  # relative to the real clock. Three self-monitoring asserts guard the
  # premise: the positive control proves a clear deadline still grants and
  # matches, and the call count proves the seam read the clock through the
  # stub exactly twice — a dead stub is 0 calls, an inlined clock is 0 calls,
  # and both are red here rather than a silent vacuous pass.
  def test_the_floor_refuses_a_positive_remaining_below_a_millisecond
    calls = 0
    fixed = 1000.0
    original = G.method(:monotonic)
    G.define_singleton_method(:monotonic) { calls += 1; fixed }
    begin
      assert_raises(G::MeasureTimeout) do
        G.bounded_match(/x/, 'x', 0, fixed + 5e-4)
      end
      m = G.bounded_match(/x/, 'x', 0, fixed + 2 * G::MIN_TIMEOUT)
      refute_nil m, 'positive control: a deadline clear of the floor grants and matches'
      assert_nil Regexp.timeout, 'and the grant is revoked as the match ends'
    ensure
      G.define_singleton_method(:monotonic, original)
    end
    # The count is the only machine-independent catcher of an inlined clock:
    # the positive control also reds when the real clock sits far from the
    # fixed value, but on a machine whose uptime is near 1000s the control
    # passes and this line alone goes red. Not redundant — do not tidy it out.
    # (The three older ticking-clock fixtures also stub monotonic, but they
    # pass under an inlined seam clock for the wrong reason; this fixture is
    # the only one whose green depends on the stub reaching the seam.)
    assert_equal 2, calls, 'both seam calls must read the clock through the module helper'
  end

  # §5-6: the floor constant, pinned in both directions, plus the property it
  # exists for: the floor itself must be a value Regexp.timeout= keeps, since
  # below 1e-9 the setter silently stores nil — no bound at all.
  def test_the_floor_constant_is_pinned_and_survives_the_setter
    assert_equal 0.001, G::MIN_TIMEOUT
    previous = Regexp.timeout
    begin
      Regexp.timeout = G::MIN_TIMEOUT
      refute_nil Regexp.timeout, 'the floor must be above the silent-nil threshold'
    ensure
      Regexp.timeout = previous
    end
  end

  # §5-7: the margin and the deadline formula, pinned by constants. The
  # wall-time bands witness the deadline behaviourally, but their flake
  # headroom and kill margin always sum to exactly the margin, so no band can
  # pin the margin's value from both sides — these asserts do.
  def test_the_margin_and_the_deadline_formula_are_pinned
    assert_equal 0.5, G::HOOK_TIMEOUT_MARGIN
    assert_in_delta 100.0 + (G::HOOK_TIMEOUT - G::HOOK_TIMEOUT_MARGIN),
                    G.deadline_for(100.0), 1e-9
  end

  # §5-9: why FENCE, HEADING and TABLE_SEP may stay outside the seam — Ruby
  # matches them in linear time, and the absolute quantity is capped by
  # TAIL_BYTES. The pin breaks the moment one of them gains a shape the
  # optimisation cannot take.
  def test_the_core_patterns_are_linear_time_and_may_stay_outside_the_seam
    [G::FENCE, G::HEADING, G::TABLE_SEP].each do |re|
      assert Regexp.linear_time?(re), re.source
    end
  end

  # §5-10: the budget oracle, declared diff d3 made falsifiable. A workload
  # sized past the retired 5-second budget must now COMPLETE and yield a
  # verdict. The wall floor is the premise assert: a faster machine finishing
  # under 5s would silently stop discriminating. Portability premise, declared:
  # a machine ~1.3x faster or slower than this one moves the workload out of
  # the (5.0, 9.4) window and this fixture reddens on unmutated code.
  def test_a_workload_past_the_retired_budget_now_completes_and_judges
    patterns = (1..1200).map do |i|
      "(?<![A-Za-z0-9_])([A-Z]{1,4}★|[A-Z]{2,5}-#{i}\\d+|[PR]\\d+|[a-z]\\d{1,2})"
    end
    # 4,200 lines targets ~7.0s, the centre of the (5.0, 9.4) window; 3,000
    # measured 5.02s against the >5.0 premise floor — the same 2%-margin
    # knife-edge the §5-3 comment above records a machine once failed on.
    text = (['これは普通の散文の行で、INV-5 や a9 のような語を含みます。'] * 4200).join("\n")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = decide(text, shorthand_patterns: patterns, gloss_patterns: ['[(（]'],
                       vocab_min_lines: 1, max_headings: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>, 5.0,
                    format('took %.1fs — under the retired budget, the oracle discriminates ' \
                           'nothing', elapsed)
    message = out.fetch('systemMessage', '')
    refute_includes message, 'NOT RUN',
                    format('took %.1fs — the workload must complete inside the new budget',
                           elapsed)
    # FAIL, not PASS: the workload's tokens are unglossed by construction, so
    # a completed measurement necessarily reaches the VOCABULARY verdict — a
    # stronger completion witness than a PASS that skipped the vocab loop.
    assert_includes message, 'FAIL', message
    assert_includes message, 'VOCABULARY', message
  end

  # §5-11: the --report path's smoke, with both reachability conditions and a
  # positive witness that the seam was entered. One cheap shorthand pattern
  # (no pattern at all short-circuits announce and skips the vocab block), the
  # default vocab_min_lines with one prose line (a higher floor skips the
  # block too), and an unglossed token whose VOCABULARY failure can only come
  # from inside the vocab loop. The exact line count catches a half-death
  # where a later record raises after earlier lines printed.
  def test_the_report_path_reaches_the_seam_and_prints_one_line_per_record
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx = File.join(tmp, 't.jsonl')
      File.write(cfg_path, JSON.generate(
                   'mode_name' => 't', 'shorthand_patterns' => ['([a-z]\d)'],
                   'gloss_patterns' => ['[（(]']
                 ), encoding: 'UTF-8')
      rows = Array.new(3) { row_for('assistant', text: "t0 が壊れます。\n") }
      File.write(tx, rows_json(rows), encoding: 'UTF-8')

      out, _err, status = run_script(cfg_path, '', ['--report', tx])
      assert_equal 0, status.exitstatus
      lines = out.lines
      assert_equal 3, lines.length, "one line per text-bearing record: #{out.inspect}"
      lines.each do |l|
        assert_includes l, 'VOCABULARY', 'reachable only through the vocab loop — the seam ran'
      end
    end
  end

  # §5-13: the grant dies with its match, on both exits that ever hold one.
  # Leg (i), completed: the deadline sits well clear of the floor (2x and
  # above), the MatchData proves the match ran, and the post-state is nil.
  # Leg (ii), cut: a runaway under a small live remaining raises Ruby's own
  # Regexp::TimeoutError — only possible while a finite bound was in force,
  # which is what excludes both vacuous paths (expired deadline raises
  # MeasureTimeout instead; nil deadline never raises) — and the post-state is
  # nil there too, which is what an `ensure` demoted to a plain trailing
  # statement cannot deliver. The runaway subject is a*27, ~1.5s even
  # unbounded: a mis-authored deadline fails an assert instead of hanging an
  # in-process fixture that has no outer kill.
  def test_the_grant_is_revoked_as_the_match_ends_on_both_exits
    m = G.bounded_match(/x/, 'x', 0, G.monotonic + 0.05)
    refute_nil m, 'the completed leg must actually run its match'
    assert_nil Regexp.timeout, 'completed: the grant must not outlive its match'

    evil = Regexp.new(EVIL_SRC)
    assert_raises(Regexp::TimeoutError) do
      G.bounded_match(evil, "x#{'a' * 27}", 0, G.monotonic + 0.05)
    end
    assert_nil Regexp.timeout, 'cut: the grant must not outlive its match either way'
  end

  # §5-14: the machine form of the family checklist. bounded_match's coverage
  # is defended by one runaway fixture per pattern family; this equality pin
  # breaks the moment a fifth list-shaped family is added and forces a fifth
  # fixture. Scope, stated: a pattern family added as a scalar key would live
  # in STR_KEYS and slip past this — widen the pin if that shape is chosen.
  def test_the_pattern_family_list_is_pinned
    assert_equal %w[announce_patterns shorthand_patterns gloss_patterns specimen_patterns],
                 G::LIST_KEYS
  end
end
