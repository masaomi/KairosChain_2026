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

# The tool resolves its project root through this accessor. Declared here as
# well as in test_hooks_status, and guarded for the same reason as the stub
# above: relying on another file to define it makes this file pass only when
# that one loaded first.
module KairosMcp
  class << self
    attr_accessor :project_root unless method_defined?(:project_root)
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
    raw = JSON.parse(File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_EXAMPLE.json')))
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
    schema = JSON.parse(File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_schema.json')))
    doc = strip_comments(JSON.parse(File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_EXAMPLE.json'))))

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
      File.write(settings, JSON.generate('hooks' => {}, 'permissions' => { 'allow' => [] }))
      before = File.read(settings)
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
      assert_equal before, File.read(settings), 'and the file is unchanged'
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
                 JSON.generate('hooks' => hooks))
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
    other = 'kairos-readable-gate --config /somewhere/othermode.Stop.readable_gate.0.json'
    owned = { 'hooks' => [{ 'command' => other }],
              '_projected_by' => 'kairos_hook_projector', '_mode' => 'testmode' }
    with_settings('Stop' => [owned]) do |root|
      out = @t.send(:check_installed, compiled, root, 'testmode')
      # Both directions at once: the declared gate is absent, and the one that
      # is there is no longer declared.
      assert_equal 'not_installed', out[:status],
                   'the same executable pointed at a different config is a different hook'
      assert_equal 1, out[:stale].length, "and the extra one is reported: #{out.inspect}"
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
  # that this tool installed it for this mode.
  def test_an_unowned_group_running_the_right_config_is_not_evidence_of_installation
    compiled = compiled_for_installed_test
    argv = compiled.artifact['hooks']['Stop'].first['argv']
    resolved = Shellwords.join(
      argv.map { |a| a.gsub(KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler::CONFIG_ROOT, '/somewhere/.kairos/hook_configs') }
    )
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
    installed = Shellwords.join(
      argv.map do |a|
        a.gsub(KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler::CONFIG_ROOT,
               '/somewhere else/.kairos/hook_configs')
      end
    )
    # The property is not which escaping style is used; it is that the string
    # still means the array. A path with a space is what broke the old
    # `.join(' ')`: --config received only the first word.
    resolved = argv.map do |a|
      a.gsub(KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler::CONFIG_ROOT,
             '/somewhere else/.kairos/hook_configs')
    end
    assert_equal resolved, Shellwords.split(installed),
                 'the joined command must split back into the same arguments'

    # Both ownership markers, because the reader now requires both. Without
    # them the group is somebody else's and reports not_installed, which is the
    # point of the check above.
    with_settings('Stop' => [{ 'hooks' => [{ 'command' => installed }],
                               '_projected_by' => 'kairos_hook_projector',
                               '_mode' => 'testmode' }]) do |root|
      out = @t.send(:check_installed, compiled, root, 'testmode')
      assert_equal 'ok', out[:status], 'the same gate under a resolved path is installed'
    end
  end

  def test_no_settings_file_is_unknown_not_installed
    Dir.mktmpdir do |root|
      out = @t.send(:check_installed, compiled_for_installed_test, root, 'testmode')
      assert_equal 'unknown', out[:status],
                   'an absent settings file is not evidence that the hook is installed'
    end
  end

  # The guard that makes a failed extraction refuse rather than match. No
  # shipped gate produces such a command today — every one carries a --config
  # path — so this drives it with a double. The alternative is to leave the
  # fail-closed half of the fix unfalsified, which is how the original defect
  # survived: the failing branch was the one nothing exercised.
  def test_a_command_naming_no_config_is_refused_not_matched
    fake = Class.new do
      def compiled? = true

      def artifact = { 'hooks' => { 'Stop' => [{ 'command' => 'some-future-gate --inline' }] } }
    end.new

    with_settings('Stop' => [{ 'hooks' => [{ 'command' => 'anything at all' }] }]) do |root|
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
