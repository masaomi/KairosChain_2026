# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'shellwords'
require_relative '../lib/mode_hooks_schema'

# BaseTool stub: these tests exercise the validator's pure judgement, which is
# where the calibration lives. The MCP call path is covered by the tool's own
# BootTimeAssertion, not here.
# Guarded, and it has to be. Three test files defined this stub unconditionally
# and reopened the class, so whichever loaded last decided the return shape for
# everybody. Loading all nine files together made test_hooks_status fail — a
# failure invisible to a per-file run, which is how "107 tests pass" was true
# nine times over and false once.
module KairosMcp
  module Tools
    class BaseTool
      def initialize(safety = nil, registry: nil); end

      def text_content(text)
        [{ type: 'text', text: text }]
      end
    end
  end
end unless defined?(::KairosMcp::Tools::BaseTool)

# The tool resolves its project root through the first accessor — declared
# here as well as in test_hooks_status, and guarded for the same reason as the
# stub above: relying on another file to define it makes this file pass only
# when that one loaded first. The second is how mode_body_path finds the body
# of a mode that is not one of the three built-ins, which the UTF-8 fixture
# test below needs in order to drive the real body read.
module KairosMcp
  class << self
    attr_accessor :project_root unless method_defined?(:project_root)
    attr_accessor :skills_dir unless method_defined?(:skills_dir)
  end
end

require_relative '../tools/mode_hooks_validate'
require_relative '../lib/mode_hooks_compiler'

class TestModeHooksValidate < Minitest::Test
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  V = KairosMcp::SkillSets::KairosHookProjector::Tools::ModeHooksValidate

  def setup
    @t = V.new
  end

  # --- section splitting ---------------------------------------------------

  def test_sections_split_on_headings_and_keep_bodies
    body = "# Title\nintro\n\n## A\nforty lines here\n\n### B\nno limit\n"
    secs = @t.send(:sections, body)
    assert_equal %w[A B], secs.map(&:first)
    assert_includes secs[0][1], 'forty lines here'
  end

  # --- candidate detection: the calibration that justifies the regex -------

  def test_candidate_requires_a_quantity_with_a_unit
    hit = "## Shape\n本文は 60 行以内に収める。\n"
    assert_equal ['Shape'], @t.send(:candidates, hit, [], [])

    miss = "## Ethos\n必ず誠実であれ。決して省略するな。never omit.\n"
    assert_empty @t.send(:candidates, miss, [], []),
                 'absolute words alone must not make a section a candidate — ' \
                 'widening to them flags 24 of 53 sections on masa.md v0.4.6'
  end

  def test_candidate_detects_english_units_too
    body = "## Shape\nKeep it under 60 lines and 3 headings.\n"
    assert_equal ['Shape'], @t.send(:candidates, body, [], [])
  end

  def test_gated_and_declined_sections_are_not_candidates
    body = "## Shape\n60 行以内。\n\n## Other\n40 lines max.\n"
    assert_equal %w[Shape Other], @t.send(:candidates, body, [], [])
    assert_equal ['Other'], @t.send(:candidates, body, ['Shape'], [])
    assert_empty @t.send(:candidates, body, ['Shape'], ['Other'])
  end

  def test_section_matching_ignores_section_marks_and_case
    body = "## § Readable Output\n60 行以内。\n"
    assert_empty @t.send(:candidates, body, ['readable output'], []),
                 'a declaration must match its section despite § and case'
  end

  # check_declared is the sole source of the OPEN_QUESTIONS verdict and had no
  # test at all; these are the two branches the verdict turns on.
  def test_check_declared_is_open_without_a_document_and_ok_when_every_candidate_is_decided
    body = "## Shape\n60 行以内。\n\n## Other\n40 lines max.\n"
    out = @t.send(:check_declared, nil, nil, body)
    assert_equal 'open', out[:status], 'no declaration leaves every candidate an open question'
    assert_equal %w[Shape Other], out[:candidate_sections]

    doc = { 'hooks' => { 'Stop' => [{ 'section' => 'Shape' }] },
            'not_gated' => [{ 'section' => 'Other' }] }
    out = @t.send(:check_declared, doc, '/x/masa.mode_hooks.json', body)
    assert_equal 'ok', out[:status], out.inspect
    assert_empty out[:candidate_sections]
  end

  # --- drift ---------------------------------------------------------------

  def sha(str)
    Digest::SHA256.hexdigest(str)
  end

  def test_drift_ok_when_body_matches
    body = "**Version:** 0.4.6\ntext\n"
    doc = { 'binding' => { 'mode_version' => '0.4.6', 'mode_body_sha256' => sha(body) } }
    assert_equal 'ok', @t.send(:check_drift, doc, body, '/x/masa.md')[:status]
  end

  def test_drift_detected_when_body_edited_without_version_bump
    body = "**Version:** 0.4.6\ntext\n"
    doc = { 'binding' => { 'mode_version' => '0.4.6', 'mode_body_sha256' => sha(body) } }
    out = @t.send(:check_drift, doc, body + "edited\n", '/x/masa.md')
    assert_equal 'drift', out[:status]
    assert_match(/sha256/, out[:detail])
  end

  def test_drift_detected_on_version_mismatch
    body = "**Version:** 0.4.7\ntext\n"
    doc = { 'binding' => { 'mode_version' => '0.4.6', 'mode_body_sha256' => sha(body) } }
    out = @t.send(:check_drift, doc, body, '/x/masa.md')
    assert_equal 'drift', out[:status]
    assert_match(/version/, out[:detail])
  end

  def test_no_binding_means_unknown_not_ok
    out = @t.send(:check_drift, { 'hooks' => {} }, 'body', '/x/masa.md')
    assert_equal 'unknown', out[:status],
                 'a declaration with no binding must not report a clean bill of health'
  end

  # --- verdict ordering ----------------------------------------------------

  def checks(over = {})
    { drift: { status: 'ok' }, resolvable: { status: 'ok' },
      installed: { status: 'ok' }, declared: { status: 'ok' } }.merge(over)
  end

  def test_verdict_reports_the_most_severe_finding
    assert_equal 'OK', @t.send(:verdict, checks)
    assert_equal 'DRIFT', @t.send(:verdict, checks(drift: { status: 'drift' }))
    assert_equal 'REFUSED', @t.send(:verdict, checks(resolvable: { status: 'refused' }))
    assert_equal 'NOT_INSTALLED', @t.send(:verdict, checks(installed: { status: 'not_installed' }))
    assert_equal 'DIVERGED', @t.send(:verdict, checks(installed: { status: 'diverged' }))
    assert_equal 'OPEN_QUESTIONS', @t.send(:verdict, checks(declared: { status: 'open' }))
    assert_equal 'DRIFT',
                 @t.send(:verdict, checks(drift: { status: 'drift' },
                                          declared: { status: 'open' })),
                 'drift outranks an open question'
  end

  # --- the shipped example is not decoration -------------------------------

  def strip_comments(obj)
    case obj
    when Hash then obj.reject { |k, _| k.start_with?('_') }
                     .transform_values { |v| strip_comments(v) }
    when Array then obj.map { |v| strip_comments(v) }
    else obj
    end
  end

  # A copier following the example's own instructions must reach a projection.
  # Before this, they were refused twice: the mode_name field stayed "example"
  # and the note did not say to change it, and then a placeholder body hash
  # reported a drift that had not happened. Both refusals were reproduced by a
  # reviewer walking the consumer's path.
  def test_a_copy_of_the_shipped_example_compiles_after_the_documented_edits
    raw = JSON.parse(File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_EXAMPLE.json'),
                               encoding: 'UTF-8'))
    refute raw.key?('binding'),
           'a shipped placeholder digest refuses every projection of a copy'

    doc = strip_comments(raw)
    doc['mode_name'] = 'mymode' # the one documented edit
    result = KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler
             .new.compile(mode_name: 'mymode', document: doc,
                          mode_body: "# My Mode\n\n## § Readable output\n60 lines.\n")
    assert result.compiled?,
           "a copy edited as the example instructs must compile. " \
           "Got: #{result.record['refusal'].inspect}"
    assert_equal 1, result.record.dig('output', 'hook_count')
  end

  def test_shipped_example_validates_and_compiles
    schema = JSON.parse(File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_schema.json'),
                                  encoding: 'UTF-8'))
    doc = strip_comments(JSON.parse(File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_EXAMPLE.json'),
                                              encoding: 'UTF-8')))

    errors = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.validate(doc, schema).errors
    assert_empty errors, "shipped example must be schema-valid. Got: #{errors.inspect}"

    result = KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler
             .new.compile(mode_name: 'example', document: doc)
    assert result.compiled?, "shipped example must compile. Got: #{result.record['refusal'].inspect}"
    assert_equal 1, result.record.dig('output', 'hook_count')
  end

  # Round 3 debt. No test called this tool's entry point at all, so its
  # boot-time assertion — the thing that makes "every tool but the projector
  # writes nothing" checkable — was never armed. Inserting a write to the
  # watched settings file into the tool body left the whole suite green.
  def test_the_validate_tool_arms_its_assertion_and_touches_no_watched_file
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, '.claude'))
      settings = File.join(root, '.claude', 'settings.json')
      File.write(settings, JSON.generate('hooks' => {}, 'permissions' => { 'allow' => [] }),
                 encoding: 'UTF-8')
      before = File.read(settings, encoding: 'UTF-8')
      ::KairosMcp.project_root = root
      begin
        body = JSON.parse(@t.call('mode' => 'a_mode_that_does_not_exist').first[:text])
      ensure
        ::KairosMcp.project_root = nil
      end
      refute_equal 'StructuralAssertionFailure', body['error'],
                   "the tool wrote to a watched path: #{body.inspect}"
      # The positive half. Asserting only that nothing broke passed with the
      # whole assertion deleted, because this tool does not write anyway — four
      # separate deletions all left the suite green. The reported status is
      # derived from the post snapshot, so a missing verify_post! shows here.
      assert_equal 'passed', body.dig('boot_time_assertion', 'status'),
                   "the tool must report a verification it performed: #{body.inspect}"
      assert_equal [settings], body.dig('boot_time_assertion', 'watched_paths'),
                   'and the watched path is the settings file under the reported root'
      assert_equal before, File.read(settings, encoding: 'UTF-8'), 'and the file is unchanged'
    end
  end

  # Round 7 put `encoding: 'UTF-8'` on every read after a crash under a
  # US-ASCII default encoding — and every fixture in this suite was pure
  # ASCII, so each of those arguments could be removed again with the suite
  # green under LC_ALL=C. These fixtures are shaped like the real files this
  # tool reads (masa.md is Japanese; its section headings start with §) and
  # reach both of its reads: the mode body and the settings file. Removing
  # the encoding argument from either read fails this test under a C locale.
  def test_a_japanese_mode_body_and_settings_validate_under_any_default_encoding
    Dir.mktmpdir do |root|
      skills = File.join(root, 'skills')
      FileUtils.mkdir_p(File.join(root, '.claude'))
      FileUtils.mkdir_p(skills)
      File.write(File.join(skills, 'jamode.md'),
                 "# jamode\n\n**Version:** 0.1\n\n## § 一読可能性の関門\n本文は 60 行以内。\n",
                 encoding: 'UTF-8')
      File.write(File.join(root, '.claude', 'settings.json'),
                 JSON.generate('hooks' => { 'Stop' => [
                                 { 'hooks' => [{ 'command' => 'echo 一読可能性',
                                                 'statusMessage' => '§ 一読可能性の関門' }] }
                               ] }),
                 encoding: 'UTF-8')
      ::KairosMcp.project_root = root
      ::KairosMcp.skills_dir = skills
      begin
        body = JSON.parse(@t.call('mode' => 'jamode').first[:text])
      ensure
        ::KairosMcp.project_root = nil
        ::KairosMcp.skills_dir = nil
      end
      assert_nil body['error'], "a Japanese mode body must validate: #{body.inspect}"
      # The heading comes back intact, so the body was actually read and
      # split, not merely slurped without raising.
      assert_equal ['§ 一読可能性の関門'],
                   body.dig('checks', 'declared', 'candidate_sections')
      assert_equal 'nothing_declared', body.dig('checks', 'installed', 'status'),
                   "the non-ASCII settings file was read and parsed: #{body.inspect}"
    end
  end

  # --- installed-state check ------------------------------------------------
  #
  # This check had no test at all, and it had silently inverted: it extracted a
  # `*.py` basename from the wanted command, but once the interpreter was
  # unpinned the command named no .py file, so the extraction returned nil and
  # the comparison became `include?("")` — true for every string. It reported
  # `ok` for any hook on the event, including one it had never seen.
  #
  # The two cases below are the ones that distinguish a real check from that
  # one. A test that only asserts the happy path passes under both.

  def compiled_for_installed_test
    doc = { 'mode_name' => 'testmode', 'version' => '1',
            'hooks' => { 'Stop' => [{ 'gate' => 'readable_gate',
                                      'section' => '§ S',
                                      'params' => { 'max_lines' => 60 } }] } }
    KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler
      .new.compile(mode_name: 'testmode', document: doc)
  end

  def with_settings(hooks)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, '.claude'))
      File.write(File.join(root, '.claude', 'settings.json'),
                 JSON.generate('hooks' => hooks), encoding: 'UTF-8')
      yield root
    end
  end

  def test_an_unrelated_hook_is_not_read_as_the_declared_one
    compiled = compiled_for_installed_test
    with_settings('Stop' => [{ 'hooks' => [{ 'command' => 'totally-unrelated-hook.sh' }] }]) do |root|
      out = @t.send(:check_installed, compiled, root, 'testmode')
      assert_equal 'not_installed', out[:status],
                   'a foreign hook on the same event must not satisfy the check'
    end
  end

  # The foreign hook above shares nothing with the declared one, so a check that
  # matched on the executable name alone would still pass it. This one is the
  # same gate under a different mode's config — which is what a second mode, or
  # a config left behind by a renamed one, actually looks like on the event.
  # The group carries both ownership markers on purpose. Once ownership is
  # required, an unowned fixture is refused by the ownership check and the
  # basename check behind it is never reached — which masked two mutations that
  # had been red before ownership was added. This mode owning a group that runs
  # a config it did not declare is exactly what a renamed section leaves behind.
  def test_an_owned_group_running_a_different_config_is_not_the_declared_one
    compiled = compiled_for_installed_test
    Dir.mktmpdir do |cfg_root|
      # Both config files exist on disk. Under the old /somewhere/ paths the
      # File.exist? at the end of the presence AND refused everything first,
      # so nothing in front of it ever decided: the name comparison could be
      # weakened to substring inclusion — the round 5 defect — or forced to
      # true, and this test stayed green either way.
      other_cfg = File.join(cfg_root, 'othermode.Stop.readable_gate.0.json')
      near_cfg = File.join(cfg_root, 'old-testmode.Stop.readable_gate.0.json')
      File.write(other_cfg, '{}', encoding: 'UTF-8')
      # A basename that merely CONTAINS the declared one — what a config left
      # behind by a renamed mode looks like. Substring inclusion accepted it
      # as installed; only exact comparison rejects it. The containment is
      # prefix-shaped because config_path extracts only arguments whose
      # basename ends with '.json': the suffix shape (`…json.bak`, the round 5
      # reproduction) yields no path at all now and never reaches the name
      # comparison. The bytes are the declared ones on purpose — a leftover is
      # a copy — so the name comparison alone must reject it; diverged bytes
      # would let the content equality mask a weakened name check.
      File.write(near_cfg,
                 compiled.artifact['files'].fetch('testmode.Stop.readable_gate.0.json'),
                 encoding: 'UTF-8')
      other = "kairos-readable-gate --config #{other_cfg}"
      near = "kairos-readable-gate --config #{near_cfg}"
      owned = { 'hooks' => [{ 'command' => other }, { 'command' => near }],
                '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
      with_settings('Stop' => [owned]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        # Both directions at once: the declared gate is absent, and the ones that
        # are there are no longer declared.
        assert_equal 'not_installed', out[:status],
                     'the same executable pointed at a different config is a different hook'
        assert_equal ['testmode.Stop.readable_gate.0.json'],
                     out[:missing].map { |m| m[:config] },
                     'the missing hook is named by its config, which the artifact carries'
        assert_equal 2, out[:stale].length, "and the extra ones are reported: #{out.inspect}"
      end
    end
  end

  # The marker the reader extracts must be specific. When extraction fails it
  # used to become the empty string, which every command contains — the round 1
  # defect. The fixture is owned so the ownership check cannot refuse first.
  def test_an_owned_group_whose_command_names_no_config_is_not_a_match
    compiled = compiled_for_installed_test
    owned = { 'hooks' => [{ 'command' => 'kairos-readable-gate' }],
              '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
    with_settings('Stop' => [owned]) do |root|
      out = @t.send(:check_installed, compiled, root, 'testmode')
      assert_equal 'not_installed', out[:status],
                   'a command naming no config must not satisfy the declared one'
    end
  end

  # Ownership is an AND of two markers, and the reader has to apply both. A
  # config basename on its own is evidence that SOMETHING runs that file, not
  # that this tool installed it for this mode. Everything except ownership is
  # right on purpose — the config exists on disk with the compiled bytes — so
  # `ours?` is the only thing refusing, and dropping either marker from it
  # goes red here. Under the old /somewhere/ path the trailing File.exist?
  # refused first and the wrong-tool fixture never reached `ours?` at all.
  def test_an_unowned_group_running_the_right_config_is_not_evidence_of_installation
    compiled = compiled_for_installed_test
    argv = compiled.artifact['hooks']['Stop'].first['argv']
    Dir.mktmpdir do |cfg_root|
      cfg_dir = File.join(cfg_root, '.kairos', 'hook_configs')
      resolved_argv = argv.map do |a|
        a.gsub(KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler::CONFIG_ROOT,
               cfg_dir)
      end
      resolved = Shellwords.join(resolved_argv)
      config = resolved_argv.find { |a| a.end_with?('.json') }
      FileUtils.mkdir_p(cfg_dir)
      File.write(config, compiled.artifact['files'].fetch(File.basename(config)),
                 encoding: 'UTF-8')
      [{ 'hooks' => [{ 'command' => resolved }] }, # no markers at all
       { 'hooks' => [{ 'command' => resolved }], '_projected_by' => 'someone-else',
         '_mode' => 'testmode' },                  # wrong tool
       { 'hooks' => [{ 'command' => resolved }], '_projected_by' => 'kairos_hook_projector',
         '_mode' => 'other' }].each do |group|     # wrong mode
        with_settings('Stop' => [group]) do |root|
          out = @t.send(:check_installed, compiled, root, 'testmode')
          assert_equal 'not_installed', out[:status],
                       "#{group.inspect} must not count as this mode's projection"
        end
      end
    end
  end

  # The reverse direction. A withdrawn declaration used to report
  # nothing_declared while the gate it had installed went on blocking every
  # turn, which is the more dangerous of the two divergences.
  def test_a_gate_the_declaration_no_longer_asks_for_is_reported_as_stale
    empty = KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler
            .new.compile(mode_name: 'testmode',
                         document: { 'mode_name' => 'testmode', 'version' => '1',
                                     'hooks' => {} })
    left_behind = { 'hooks' => [{ 'command' => 'kairos-readable-gate --config ' \
                                               '/x/testmode.Stop.readable_gate.0.json' }],
                    '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
    with_settings('Stop' => [left_behind]) do |root|
      out = @t.send(:check_installed, empty, root, 'testmode')
      assert_equal 'stale_installed', out[:status], out.inspect
      assert_equal 1, out[:stale].length, out.inspect
      assert_equal 'STALE_INSTALLED',
                   @t.send(:verdict, checks(installed: out)), 'and it reaches the verdict'
    end

    # Another mode's leftovers are not this mode's business.
    theirs = left_behind.merge('_mode' => 'other')
    with_settings('Stop' => [theirs]) do |root|
      out = @t.send(:check_installed, empty, root, 'testmode')
      assert_equal 'nothing_declared', out[:status], out.inspect
    end
  end

  def test_the_declared_hook_is_recognised_once_its_path_token_is_resolved
    compiled = compiled_for_installed_test
    argv = compiled.artifact['hooks']['Stop'].first['argv']
    Dir.mktmpdir do |cfg_root|
      # A directory with a space, because a path with a space is what broke
      # the old `.join(' ')`: --config received only the first word.
      cfg_dir = File.join(cfg_root, 'somewhere else', '.kairos', 'hook_configs')
      resolved = argv.map do |a|
        a.gsub(KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler::CONFIG_ROOT,
               cfg_dir)
      end
      installed = Shellwords.join(resolved)
      # The property is not which escaping style is used; it is that the
      # string still means the array.
      assert_equal resolved, Shellwords.split(installed),
                   'the joined command must split back into the same arguments'

      # Installed now means the named config exists at the path the command
      # carries with the bytes the declaration compiles to, so the fixture
      # puts the compiled content there. It used to write '{}', which no
      # declaration compiles to — the fixture passed only because nothing
      # compared content, which is the defect the second half below pins.
      config = resolved.find { |a| a.end_with?('.json') }
      FileUtils.mkdir_p(File.dirname(config))
      File.write(config, compiled.artifact['files'].fetch(File.basename(config)),
                 encoding: 'UTF-8')

      # Both ownership markers, because the reader now requires both. Without
      # them the group is somebody else's and reports not_installed, which is
      # the point of the check above.
      with_settings('Stop' => [{ 'hooks' => [{ 'command' => installed }],
                                 '_projected_by' => 'kairos_hook_projector',
                                 '_mode' => 'testmode' }]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'ok', out[:status], 'the same gate under a resolved path is installed'

        # The shipped example's own week-two instruction: run report-only,
        # then flip blocking. A reviewer did exactly that and validate said
        # `installed: ok` while the projector reported a pending write — the
        # filename encodes no parameter, so name-plus-existence cannot see any
        # threshold change. The gate is installed and firing, so this is not
        # absence either: round 8 answered `not_installed` with a remedy
        # saying to install, about a gate that was live on every turn.
        File.write(config,
                   JSON.generate(JSON.parse(File.read(config, encoding: 'UTF-8'))
                                     .merge('blocking' => false)),
                   encoding: 'UTF-8')
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'diverged', out[:status],
                     'a live config that no longer carries the compiled bytes is diverged, not absent'
        assert_equal ['testmode.Stop.readable_gate.0.json'],
                     out[:diverged].map { |d| d[:config] }, out.inspect
        # Reversed in round 9 by operator ruling 甲 (2026-08-14): round 8 had
        # this assert the live command was ALSO listed under stale. The three
        # lists are exclusive now — a currently-declared gate is reported
        # once, as diverged, and stale keeps only what nothing else reports.
        assert_empty out[:stale],
                     "the declared gate's finding is the diverged entry, once: #{out.inspect}"
      end
    end
  end

  # Finding 58: no test pinned which equality decides `installed`. It is byte
  # equality — the same comparison plan_for applies when it decides
  # config_changed — and this pins it from the two directions a relaxation
  # would open: a trailing newline (what an editor's save appends) and a
  # pretty-printed but JSON-equal body (what a hand edit through a formatter
  # produces). Tolerating either here while plan_for keeps comparing bytes
  # re-opens the validate-versus-projector disagreement round 8 closed:
  # validate saying OK while the projector reports a pending write. The label
  # those bytes get is the round 9 repair: the gate is live, so the answer is
  # `diverged` with a re-apply remedy, never `not_installed` with an install
  # one. This used to pin a third direction — the stale list applying the
  # same byte equality — which round 9 reverses on operator ruling 甲
  # (2026-08-14): missing/diverged/stale are exclusive, so the live declared
  # command reports under diverged alone and stale stays empty.
  def test_a_json_equal_but_byte_different_config_is_diverged_never_ok
    compiled = compiled_for_installed_test
    name = 'testmode.Stop.readable_gate.0.json'
    declared = compiled.artifact['files'].fetch(name)
    Dir.mktmpdir do |cfg_root|
      cfg = File.join(cfg_root, name)
      owned = { 'hooks' => [{ 'command' => Shellwords.join(
        ['kairos-readable-gate', '--config', cfg]
      ) }], '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
      ["#{declared}\n", JSON.pretty_generate(JSON.parse(declared))].each do |bytes|
        assert_equal JSON.parse(declared), JSON.parse(bytes), 'fixture: JSON-equal on purpose'
        refute_equal declared, bytes, 'fixture: byte-different on purpose'
        File.write(cfg, bytes, encoding: 'UTF-8')
        with_settings('Stop' => [owned]) do |root|
          out = @t.send(:check_installed, compiled, root, 'testmode')
          assert_equal 'diverged', out[:status],
                       "#{bytes.inspect} does not carry the declared bytes and the gate " \
                       'is live: neither ok nor not_installed is true of it'
          assert_equal [name], out[:diverged].map { |d| d[:config] }, out.inspect
          # Reversed in round 9 by operator ruling 甲 (2026-08-14); see the
          # header comment. Round 8 asserted `1, out[:stale].length` here.
          assert_empty out[:stale],
                       "exclusive partition: diverged is the whole finding: #{out.inspect}"
          assert_match(/restores the declared bytes/, out[:remedy],
                       'the remedy is re-apply, not install')
          assert_equal 'DIVERGED', @t.send(:verdict, checks(installed: out)),
                       'and it reaches the verdict'
        end
      end
    end
  end

  # Round 9, N1 — the validator's core promise. `present` compared ownership,
  # the config BASENAME, and the config BYTES, and never the command around
  # them, so an owned `/bin/true --config <the correct config>` read
  # `installed: ok` while the gate never ran: the operator was told their
  # declared gate was enforcing when no enforcement occurred. The equality is
  # now the full expected command — the Shellwords join of the substituted
  # argv, executable and every argument included, resolved against the config
  # root the installed command itself carries — which is the same string
  # plan_for compares inside settings_changed, closing the executable-element
  # route on which validate and the projector could disagree. Both fixtures
  # carry the declared bytes on purpose: the command is the only defect, so
  # byte equality alone cannot catch either.
  def test_an_owned_command_that_is_not_the_declared_one_is_never_ok
    compiled = compiled_for_installed_test
    name = 'testmode.Stop.readable_gate.0.json'
    Dir.mktmpdir do |cfg_root|
      cfg = File.join(cfg_root, name)
      File.write(cfg, compiled.artifact['files'].fetch(name), encoding: 'UTF-8')
      wrong_executable = Shellwords.join(['/bin/true', '--config', cfg])
      extra_argument = Shellwords.join(['kairos-readable-gate', '--config', cfg, '--report-only'])
      [wrong_executable, extra_argument].each do |cmd|
        owned = { 'hooks' => [{ 'command' => cmd }],
                  '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
        with_settings('Stop' => [owned]) do |root|
          out = @t.send(:check_installed, compiled, root, 'testmode')
          refute_equal 'ok', out[:status],
                       "#{cmd.inspect} is not the declared command; what it runs, " \
                       'the declaration never asked for'
          assert_equal 'diverged', out[:status],
                       'the declared config is live and readable, so this is divergence, ' \
                       "not absence, and re-apply restores the declared command: #{out.inspect}"
          assert_equal [name], out[:diverged].map { |d| d[:config] }, out.inspect
        end
      end
    end
  end

  # Round 9, N7 — operator ruling 甲 (2026-08-14): `missing`, `diverged` and
  # `stale` are an exclusive partition. This REVERSES a deliberate round-8
  # choice (see the rewritten assertions above): round 8's stale filter
  # admitted every byte-unequal owned entry, so appending one newline to a
  # live config produced verdict DIVERGED, diverged: [the config], AND
  # stale: [the live command for that same config] — although stale's only
  # in-band definition is "hooks this mode no longer declares", which is
  # false of a currently-declared gate. Each defect now reports exactly
  # once. No verdict moves between the branches this reversal touches:
  # not_installed and diverged both outrank stale_installed.
  def test_missing_diverged_and_stale_are_exclusive
    compiled = compiled_for_installed_test
    name = 'testmode.Stop.readable_gate.0.json'
    declared = compiled.artifact['files'].fetch(name)
    Dir.mktmpdir do |cfg_root|
      cfg = File.join(cfg_root, name)
      good = Shellwords.join(['kairos-readable-gate', '--config', cfg])
      owned = lambda do |*cmds|
        { 'hooks' => cmds.map { |c| { 'command' => c } },
          '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
      end

      # The probed round 9 shape: one newline appended to a live config.
      File.write(cfg, declared + "\n", encoding: 'UTF-8')
      with_settings('Stop' => [owned.call(good)]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'diverged', out[:status], out.inspect
        assert_equal [name], out[:diverged].map { |d| d[:config] }, out.inspect
        # Array(): the diverged branch omits lists that are empty by
        # construction; nil and [] both mean "nothing reported here".
        assert_empty Array(out[:missing]), out.inspect
        assert_empty Array(out[:stale]),
                     "a currently-declared gate is never stale: #{out.inspect}"
      end

      # The vanished-declared shape: missing, and only missing.
      File.delete(cfg)
      with_settings('Stop' => [owned.call(good)]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'not_installed', out[:status], out.inspect
        assert_equal [name], out[:missing].map { |m| m[:config] }, out.inspect
        assert_empty out[:stale],
                     "the dead command IS the missing finding; twice is not more: #{out.inspect}"
      end

      # Exclusive is not invisible: what nothing else reports still lands in
      # stale. A surplus owned copy beside a valid realization is a hook the
      # declaration does not ask for — it asks for exactly one command for
      # this config, and the copy is not it. Round 8 could not see this entry
      # at all: its bytes are the declared ones, and bytes were the only
      # equality the stale filter applied.
      File.write(cfg, declared, encoding: 'UTF-8')
      surplus = Shellwords.join(['/bin/true', '--config', cfg])
      with_settings('Stop' => [owned.call(good, surplus)]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'stale_installed', out[:status], out.inspect
        assert_equal [surplus], out[:stale].map { |s| s[:command] }, out.inspect
        assert_empty Array(out[:missing]), out.inspect
        assert_empty Array(out[:diverged]), out.inspect
      end
    end
  end

  # Round 11. The round-9 stale filter keyed on config BASENAME alone, so an
  # owned entry running the declared command over the declared bytes on the
  # WRONG lifecycle event was filtered out as a valid realization, and the
  # tool answered `installed: ok` while an undeclared hook was live on an
  # event the declaration never names. The solely-moved shape reaches the
  # same end state through the tool's own remedy: it first reads
  # `not_installed`, re-applying reinstalls on the declared event and leaves
  # the moved copy, which the basename key then hid. The key is now
  # (event, basename). The ruling-甲 partition (exclusive missing/diverged/
  # stale) is unchanged: the wrong-event copy is a defect of its own — not
  # the declared config's finding — and reports exactly once, under stale.
  def test_a_declared_command_on_the_wrong_lifecycle_event_is_never_ok
    compiled = compiled_for_installed_test
    name = 'testmode.Stop.readable_gate.0.json'
    Dir.mktmpdir do |cfg_root|
      cfg = File.join(cfg_root, name)
      File.write(cfg, compiled.artifact['files'].fetch(name), encoding: 'UTF-8')
      cmd = Shellwords.join(['kairos-readable-gate', '--config', cfg])
      owned = lambda do
        { 'hooks' => [{ 'command' => cmd }],
          '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
      end

      # The duplicate shape: the declared event is correctly served, and a
      # byte-identical copy runs on an event the declaration never names.
      # Command, ownership, and bytes are all right on purpose — the event
      # is the only thing left to refuse, so a basename-keyed filter reads ok.
      with_settings('Stop' => [owned.call], 'PreToolUse' => [owned.call]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'stale_installed', out[:status],
                     'a declared command on an undeclared event is a hook the ' \
                     "declaration does not ask for: #{out.inspect}"
        assert_equal [['PreToolUse', cmd]],
                     out[:stale].map { |s| [s[:event], s[:command]] },
                     'the wrong-event copy is the finding, named by its event'
        assert_empty Array(out[:missing]), out.inspect
        assert_empty Array(out[:diverged]), out.inspect
      end

      # The solely-moved shape. `not_installed` is true — nothing serves the
      # declared event — but the moved copy must be surfaced beside the
      # missing entry: hiding it sent the operator through re-apply to the
      # duplicate shape above, which then read ok, so the undeclared hook
      # stayed live at the end of the tool's own instructions.
      with_settings('PreToolUse' => [owned.call]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'not_installed', out[:status], out.inspect
        assert_equal [name], out[:missing].map { |m| m[:config] }, out.inspect
        assert_equal [['PreToolUse', cmd]],
                     out[:stale].map { |s| [s[:event], s[:command]] },
                     'the moved copy is live on an undeclared event and is ' \
                     "reported, not hidden behind the missing entry: #{out.inspect}"
      end
    end
  end

  # Round 13, F3. Two byte-identical owned copies of the declared hook on the
  # DECLARED event each independently satisfied the stale filter's
  # valid-realization equality, so neither was reported and the answer read
  # `installed: ok` while a surplus live hook remained in the harness config —
  # the exact entry the filter's own contract ("a surplus owned copy beside a
  # valid realization of the same config") already promised under stale. The
  # declaration asks for exactly one command per (event, config): one
  # realization is consumed, the copy is surplus. No shipped path writes the
  # duplicate — apply is convergent — so the fixtures are what a hand edit or
  # an external settings merge leaves behind, in both shapes it can take: the
  # entry duplicated inside the owned group, and the whole owned group
  # duplicated. The projector reports settings_changed for both, so `ok` here
  # was also the round-8 validate-versus-projector disagreement reopening on
  # multiplicity; re-apply removes the copy, which is stale's remedy.
  def test_a_surplus_byte_identical_copy_of_a_declared_hook_is_stale_not_ok
    compiled = compiled_for_installed_test
    name = 'testmode.Stop.readable_gate.0.json'
    Dir.mktmpdir do |cfg_root|
      cfg = File.join(cfg_root, name)
      File.write(cfg, compiled.artifact['files'].fetch(name), encoding: 'UTF-8')
      cmd = Shellwords.join(['kairos-readable-gate', '--config', cfg])
      group = lambda do |*cmds|
        { 'hooks' => cmds.map { |c| { 'command' => c } },
          '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
      end

      { 'entry duplicated inside the owned group' => [group.call(cmd, cmd)],
        'owned group duplicated whole' => [group.call(cmd), group.call(cmd)] }
        .each do |shape, groups|
        with_settings('Stop' => groups) do |root|
          out = @t.send(:check_installed, compiled, root, 'testmode')
          assert_equal 'stale_installed', out[:status],
                       "#{shape}: the second copy is a hook the declaration " \
                       "does not ask for: #{out.inspect}"
          assert_equal [['Stop', cmd]],
                       out[:stale].map { |s| [s[:event], s[:command]] },
                       "#{shape}: one realization is consumed, exactly the " \
                       "surplus is reported: #{out.inspect}"
          assert_empty Array(out[:missing]), out.inspect
          assert_empty Array(out[:diverged]), out.inspect
        end
      end
    end
  end

  # Round 8 also replaced the presence File.exist? with an unguarded
  # File.read, so a config that exists but cannot be read — a directory here —
  # collapsed the whole answer into `{"error":"Errno::EISDIR"}`: no verdict,
  # no drift or resolvability check, and no boot_time_assertion marker,
  # because call's rescue sits outside verify_post!. An unreadable config must
  # degrade the installed check the way an absent one always has, and the
  # rest of the answer must still arrive.
  def test_a_config_that_cannot_be_read_degrades_the_check_not_the_whole_call
    Dir.mktmpdir do |root|
      skills = File.join(root, 'skills')
      FileUtils.mkdir_p(File.join(root, '.claude'))
      FileUtils.mkdir_p(skills)
      File.write(File.join(skills, 'bmode.md'),
                 "# bmode\n\n**Version:** 0.1\nprose without limits\n", encoding: 'UTF-8')
      File.write(File.join(skills, 'bmode.mode_hooks.json'),
                 JSON.generate('mode_name' => 'bmode', 'version' => '1',
                               'hooks' => { 'Stop' => [{ 'gate' => 'readable_gate',
                                                         'section' => '§ S',
                                                         'params' => { 'max_lines' => 60 } }] }),
                 encoding: 'UTF-8')
      dir_cfg = File.join(root, 'bmode.Stop.readable_gate.0.json')
      Dir.mkdir(dir_cfg) # a directory where the config file should be
      File.write(File.join(root, '.claude', 'settings.json'),
                 JSON.generate('hooks' => { 'Stop' => [
                                 { 'hooks' => [{ 'command' => Shellwords.join(
                                   ['kairos-readable-gate', '--config', dir_cfg]
                                 ) }],
                                   '_projected_by' => 'kairos_hook_projector',
                                   '_mode' => 'bmode' }
                               ] }),
                 encoding: 'UTF-8')
      ::KairosMcp.project_root = root
      ::KairosMcp.skills_dir = skills
      begin
        body = JSON.parse(@t.call('mode' => 'bmode').first[:text])
      ensure
        ::KairosMcp.project_root = nil
        ::KairosMcp.skills_dir = nil
      end
      assert_nil body['error'], "one unreadable config collapsed the whole answer: #{body.inspect}"
      assert_equal 'NOT_INSTALLED', body['verdict'],
                   'a gate whose config cannot be read enforces nothing'
      assert_equal 'passed', body.dig('boot_time_assertion', 'status'),
                   'the read-only guarantee is reported even when a config cannot be read'
    end
  end

  # Round 9, N2 — byte-for-byte the shape the test above closed for CONFIG
  # files, left open on the SETTINGS file: check_installed read it with a
  # bare JSON.parse(File.read(...)), so a trailing comma — in the file the
  # tool exists to check, and the one Claude Code writes itself — collapsed
  # the whole answer into an error body: no verdict, no drift or
  # resolvability check, and no boot_time_assertion marker, because call's
  # rescue sits outside verify_post!. The degraded status REUSES `unknown`,
  # the answer an absent settings file has always produced: in both states
  # what is installed cannot be determined, and the existing
  # UNKNOWN_INSTALLED verdict already says unanswered is not OK.
  def test_a_malformed_settings_file_degrades_to_unknown_not_an_error_body
    Dir.mktmpdir do |root|
      skills = File.join(root, 'skills')
      FileUtils.mkdir_p(File.join(root, '.claude'))
      FileUtils.mkdir_p(skills)
      File.write(File.join(skills, 'cmode.md'),
                 "# cmode\n\n**Version:** 0.1\nprose without limits\n", encoding: 'UTF-8')
      File.write(File.join(root, '.claude', 'settings.json'),
                 "{\"hooks\": {},}\n", encoding: 'UTF-8') # verified: this raises JSON::ParserError
      ::KairosMcp.project_root = root
      ::KairosMcp.skills_dir = skills
      begin
        body = JSON.parse(@t.call('mode' => 'cmode').first[:text])
      ensure
        ::KairosMcp.project_root = nil
        ::KairosMcp.skills_dir = nil
      end
      assert_nil body['error'],
                 "a malformed settings file collapsed the whole answer: #{body.inspect}"
      assert_equal 'unknown', body.dig('checks', 'installed', 'status'), body.inspect
      assert_equal 'UNKNOWN_INSTALLED', body['verdict'],
                   'what is installed cannot be determined, and unanswered is not OK'
      assert_equal 'passed', body.dig('boot_time_assertion', 'status'),
                   'the read-only guarantee is reported even when settings cannot be parsed'
    end
  end

  # The same defect across the shapes that reach it, driven at the check
  # level: unparseable JSON (zero bytes, a trailing comma, a truncation) and
  # parseable JSON that is not a settings object (an array top level, a
  # non-object `hooks`). Each degrades the one check that looked, carrying
  # the reason; none may raise out of the check.
  def test_settings_shapes_that_are_not_a_settings_object_degrade_to_unknown
    compiled = compiled_for_installed_test
    ['', "{\"hooks\": {},}", '{"hooks":', '[]', '{"hooks": []}', '{"hooks": "Stop"}']
      .each do |bytes|
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, '.claude'))
        File.write(File.join(root, '.claude', 'settings.json'), bytes, encoding: 'UTF-8')
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'unknown', out[:status],
                     "#{bytes.inspect} cannot answer what is installed: #{out.inspect}"
        refute_nil out[:detail], 'the reason travels with the degraded status'
      end
    end
  end

  # Round 10, DD-16. Two halves of the degraded `unknown` were unpinned.
  # It was the only non-ok installed status shipping no remedy — the
  # operator got UNKNOWN_INSTALLED, a reason, and no instruction, while its
  # three siblings each carry one. And the detail was decoration: replacing
  # the whole string with 'unavailable' left the suite green, although the
  # reason inside it — the parser's own message — is
  # what points the operator at their own typo. Both are pinned here, per
  # shape: the detail must carry the settings path and the real reason
  # verbatim, and the remedy must say what the operator can actually do.
  # Round 11 deleted a round-10 clause from the remedy: it promised "the
  # position of the typo", but json 2.9.1 emits an excerpt (`unexpected
  # token at '...'`), never a position, on truncated, zero-byte, and
  # trailing-comma inputs alike. The remedy may promise only what the
  # detail actually carries, and the refutation below pins that.
  # Hand repair, honestly: the projector's read_settings raises "refusing
  # to rewrite it" on exactly these inputs, so the siblings' "run the
  # mode_hooks_project tool" would be a false instruction here.
  def test_the_unknown_settings_answer_carries_a_remedy_and_the_real_reason
    compiled = compiled_for_installed_test
    malformed = "{\"hooks\": {},}"
    parse_reason = begin
      JSON.parse(malformed)
      nil
    rescue JSON::ParserError => e
      e.message
    end
    refute_nil parse_reason, 'fixture: the malformed bytes must fail to parse'

    { malformed => parse_reason,
      '[]' => 'top level is Array, not an object',
      '{"hooks": []}' => '`hooks` is Array, not an object' }.each do |bytes, reason|
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, '.claude'))
        settings = File.join(root, '.claude', 'settings.json')
        File.write(settings, bytes, encoding: 'UTF-8')
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'unknown', out[:status], out.inspect
        assert_includes out[:detail], settings,
                        'the detail names the file the operator must open'
        assert_includes out[:detail], reason,
                        "the detail carries the real reason, not a placeholder: #{out.inspect}"
        assert_match(/repair the settings file by hand/, out[:remedy],
                     "unknown must ship an instruction, as its three siblings do: #{out.inspect}")
        assert_match(/refuses to rewrite/, out[:remedy],
                     'and be honest that the projector refuses this same input')
        refute_match(/position/, out[:remedy],
                     'the remedy must not promise a parse position: the shipped ' \
                     'parser reports an excerpt (unexpected token at ...), never ' \
                     'a position, so the promise was false of every input that ' \
                     "reaches this branch: #{out.inspect}")
      end
    end
  end

  # The chmod-000 shape of the same defect, driven at the check level, plus
  # the pin on what unreadable means: the gate cannot read the file, so it
  # enforces nothing — that is absence, not divergence.
  def test_an_unreadable_config_file_counts_as_absent_not_diverged
    skip 'root reads through chmod 000; the fixture cannot exist' if Process.euid.zero?
    compiled = compiled_for_installed_test
    name = 'testmode.Stop.readable_gate.0.json'
    Dir.mktmpdir do |cfg_root|
      cfg = File.join(cfg_root, name)
      # The declared bytes on purpose: unreadability is the only defect.
      File.write(cfg, compiled.artifact['files'].fetch(name), encoding: 'UTF-8')
      File.chmod(0o000, cfg)
      owned = { 'hooks' => [{ 'command' => Shellwords.join(
        ['kairos-readable-gate', '--config', cfg]
      ) }], '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
      with_settings('Stop' => [owned]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'not_installed', out[:status],
                     'a config the gate cannot read enforces nothing'
        assert_equal [name], out[:missing].map { |m| m[:config] }, out.inspect
        # Reversed in round 9 by operator ruling 甲 (2026-08-14): round 8
        # asserted the dead command was listed under stale beside its missing
        # config. The lists are exclusive now; the config is declared, so its
        # whole finding is the missing entry.
        assert_empty out[:stale],
                     "the dead entry IS the missing finding, reported once: #{out.inspect}"
      end
    end
  end

  # The negative twin of the resolved-path test, and the case an independent
  # regrade marked BLOCKING: the settings entry survives a move or deletion of
  # `.kairos/hook_configs/` — relocating the data directory has actually been
  # done twice in this project — and a basename-only comparison answered
  # `installed: ok` while the gate found no config, exited 0 with empty
  # output, and enforced nothing. Presence must mean the config file exists
  # at the path the installed command itself carries.
  def test_a_command_whose_config_file_is_gone_is_not_counted_as_installed
    compiled = compiled_for_installed_test
    argv = compiled.artifact['hooks']['Stop'].first['argv']
    Dir.mktmpdir do |cfg_root|
      resolved = argv.map do |a|
        a.gsub(KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler::CONFIG_ROOT,
               File.join(cfg_root, '.kairos', 'hook_configs'))
      end
      config = resolved.find { |a| a.end_with?('.json') }
      refute File.exist?(config), 'fixture: the named config must not exist'

      with_settings('Stop' => [{ 'hooks' => [{ 'command' => Shellwords.join(resolved) }],
                                 '_projected_by' => 'kairos_hook_projector',
                                 '_mode' => 'testmode' }]) do |root|
        out = @t.send(:check_installed, compiled, root, 'testmode')
        assert_equal 'not_installed', out[:status],
                     'a command whose config file is gone enforces nothing ' \
                     'and must not be counted as installed'
        assert_equal ['testmode.Stop.readable_gate.0.json'],
                     out[:missing].map { |m| m[:config] }, out.inspect
        # Reversed in round 9 by operator ruling 甲 (2026-08-14): round 8 kept
        # the dead command under stale to distinguish this from
        # never-installed. missing/diverged/stale are exclusive now, so this
        # check no longer carries that distinction: the declared config's
        # whole finding is the missing entry, once.
        assert_empty out[:stale],
                     "exclusive partition: missing is the whole finding: #{out.inspect}"
      end
    end
  end

  def test_no_settings_file_is_unknown_not_installed
    Dir.mktmpdir do |root|
      out = @t.send(:check_installed, compiled_for_installed_test, root, 'testmode')
      assert_equal 'unknown', out[:status],
                   'an absent settings file is not evidence that the hook is installed'
      # Carried through like its stale sibling above. Asserting on the check
      # alone left the verdict unpinned, and verdict had no branch for
      # 'unknown': a fresh project — no checked-in settings.json — was told OK
      # on its very first validate, before anything had been installed.
      assert_equal 'UNKNOWN_INSTALLED', @t.send(:verdict, checks(installed: out)),
                   'and it reaches the verdict'
    end
  end

  # The guard that makes a failed extraction refuse rather than match. No
  # shipped gate produces such a command today — every one carries a --config
  # path — so this drives it with a double. The alternative is to leave the
  # fail-closed half of the fix unfalsified, which is how the original defect
  # survived: the failing branch was the one nothing exercised.
  # The installed group carries both ownership markers so the marker guard,
  # not `ours?`, is what decides — an unowned group is refused before the
  # guard this test names ever runs.
  def test_a_command_naming_no_config_is_refused_not_matched
    fake = Class.new do
      def compiled? = true

      def artifact = { 'hooks' => { 'Stop' => [{ 'command' => 'some-future-gate --inline' }] } }
    end.new

    with_settings('Stop' => [{ 'hooks' => [{ 'command' => 'anything at all' }],
                               '_projected_by' => 'kairos_hook_projector',
                               '_mode' => 'testmode' }]) do |root|
      out = @t.send(:check_installed, fake, root, 'testmode')
      assert_equal 'not_installed', out[:status],
                   'a command the check cannot identify must not be reported as present'
    end
  end

  # The shipped example lives in the same directory the compiler scans. The
  # underscore prefix is what keeps it out — the same convention that hides
  # _schema.json and _record_schema.json from the mode inventory.
  def test_example_filename_can_never_be_mistaken_for_a_mode
    assert_nil @t.send(:document_path, 'EXAMPLE'),
               'the example must not resolve as a mode document'
    assert_nil @t.send(:document_path, '_EXAMPLE'),
               'even asked for by its literal name, the example is not a mode'
  end
end
