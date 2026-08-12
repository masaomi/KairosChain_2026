# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'timeout'
require 'rbconfig'

HERE = __dir__
require_relative '../hooks/readable_gate'

G = KairosHookProjector::ReadableGate

class TestReadableGate < Minitest::Test
  SCRIPT = File.join(File.dirname(HERE), 'hooks', 'readable_gate.rb')

  def cfg(overrides = {})
    raw = { 'mode_name' => 'test', 'section' => '§ Test' }.merge(overrides)
    G::Config.new(raw, '<inline>')
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
      File.write(cfg_path, JSON.generate(raw))
      File.write(tx_path, JSON.generate(
        'type' => 'assistant',
        'message' => { 'content' => [{ 'type' => 'text', 'text' => text }] }
      ) + "\n")

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
    [out, err, status]
  rescue Timeout::Error
    raise Minitest::Assertion, 'gate did not return within 30s'
  end

  def run_raw(content, config, extra = [])
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      File.write(cfg_path, JSON.generate(config))
      File.write(tx_path, content)
      out, err, status = run_script(
        cfg_path,
        JSON.generate('transcript_path' => tx_path, 'stop_hook_active' => false),
        extra
      )
      yield out, err, status, tx_path
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

  def test_a_rewrite_is_measured_and_reported_but_never_blocked_again
    out = decide("# a\n## b\n### c\n#### d\n", rechecked: true, max_headings: 3)
    refute out.key?('decision'), out.inspect
    assert_includes out.fetch('systemMessage', ''), 'FAIL'
    assert_includes out.fetch('systemMessage', ''), 'recheck'
  end

  def test_a_passing_message_never_blocks_either_way
    [true, false].each do |blocking|
      out = decide("短い応答。\n", max_headings: 3, blocking: blocking)
      refute out.key?('decision'), "blocking=#{blocking}: #{out.inspect}"
    end
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
  def test_the_measurement_bound_stops_an_accumulating_scan_and_never_blocks
    patterns = (1..200).map do |i|
      "(?<![A-Za-z0-9_])([A-Z]{1,4}★|[A-Z]{2,5}-#{i}\\d+|[PR]\\d+|[a-z]\\d{1,2})"
    end
    text = (['これは普通の散文の行で、INV-5 や a9 のような語を含みます。'] * 4000).join("\n")
    assert_operator text.bytesize, :<, G::TAIL_BYTES, 'the gate must read all of it'

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = decide(text, shorthand_patterns: patterns, gloss_patterns: ['[(（]'],
                       vocab_min_lines: 1, measure_timeout_seconds: 1, max_headings: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 20, format('took %.1fs', elapsed)
    refute out.key?('decision'), out.inspect
    assert_includes out.fetch('systemMessage', ''), 'NOT RUN'
  end

  # The other half of the bound: a single match that does run away is turned
  # into the same outcome. Ruby raises Regexp::TimeoutError rather than letting
  # the scan continue, and the gate must convert that into NOT RUN rather than
  # let it escape. Driven at the seam because no pattern this project can write
  # reaches it — see the note above.
  def test_a_regexp_timeout_becomes_not_run_rather_than_an_escape
    c = cfg('shorthand_patterns' => ['(a)'], 'gloss_patterns' => ['x'],
            'vocab_min_lines' => 1, 'measure_timeout_seconds' => 1)
    G.stub(:measure, ->(*) { raise Regexp::TimeoutError }) do
      assert_raises(G::MeasureTimeout) { G.measure_bounded("a\n", c) }
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
    [nil, 'plain string', [nil, 7], [{ 'type' => 'text' }]].each do |content|
      line = JSON.generate('type' => 'assistant', 'message' => { 'content' => content }) + "\n"
      run_raw(line, 'mode_name' => 't', 'max_headings' => 1) do |out, err, status, _|
        assert_equal 0, status.exitstatus, "content=#{content.inspect}: #{err[0, 200]}"
        refute_includes out, 'block', "content=#{content.inspect}"
      end
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
                'mode_name' => 't', 'max_headings' => 1) do |out, err, status, _|
          assert_equal 0, status.exitstatus, "row=#{row} (#{label}): #{err[0, 200]}"
          refute_includes out, 'block', "row=#{row} (#{label})"
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
    content = [good, '42', '"a string"', 'null', good].join("\n") + "\n"
    Dir.mktmpdir do |tmp|
      cfg_path = File.join(tmp, 'cfg.json')
      tx_path = File.join(tmp, 't.jsonl')
      File.write(cfg_path, JSON.generate('mode_name' => 't', 'max_headings' => 1))
      File.write(tx_path, content)
      out, err, status = run_script(cfg_path, '', ['--report', tx_path])
      assert_equal 0, status.exitstatus, err[0, 200]
      assert_equal 2, out.scan('lines=').length, out.inspect
    end
  end

  def test_a_broken_transcript_fails_open
    ['', "{ not json\n"].each do |raw|
      run_raw(raw, 'mode_name' => 't', 'max_headings' => 1) do |out, err, status, _|
        assert_equal 0, status.exitstatus, err[0, 200]
        refute_includes out, 'block'
      end
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
    params = doc['hooks']['Stop'][0]['params']

    _, f = measure("INV-5 が壊れます。\n" * 10, params)
    assert f.any? { |x| x.include?('VOCABULARY') }, f.inspect

    _, f = measure("commit c341361 を参照。\n" * 10, params)
    assert_empty f, f.inspect
  end
end
