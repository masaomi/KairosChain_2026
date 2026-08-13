# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'

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

require_relative '../tools/mode_hooks_project'

# Stage 2 activation, after round 1 review moved the write off the harness
# configuration and back again: round 2 tried plugin/hooks.json and round 2
# review rejected it, so this drives the one-step write into settings.json.
class TestModeHooksProject < Minitest::Test
  BODY = "**Version:** 0.1.0\n## Shape\nKeep it under 60 lines.\n"

  # Test double: the environment lookups and the chain are the impure surface.
  # Everything else — compile, plan, hash, merge, write — is the real thing.
  class Projector < KairosMcp::SkillSets::KairosHookProjector::Tools::ModeHooksProject
    attr_accessor :root, :document, :chain_result

    private

    def data_dir = File.join(@root, '.kairos')
    def project_root = @root
    def active_mode = 'testmode'
    def mode_body_path(_mode) = File.join(@root, 'body.md')
    def load_document(_mode, _body_path = nil) = @document

    def record_to_chain(_mode, _compiled)
      @chain_result || { recorded: true, block_index: 1, hash: 'stub' }
    end
  end

  def doc(params = { 'max_lines' => 60 })
    {
      'mode_name' => 'testmode', 'version' => '1',
      'hooks' => { 'Stop' => [{ 'gate' => 'readable_gate',
                                'section' => '§ Shape', 'params' => params }] }
    }
  end

  def with_projector(document: nil)
    Dir.mktmpdir do |dir|
      p = Projector.new
      p.root = dir
      p.document = document.nil? ? doc : document
      File.write(File.join(dir, 'body.md'), BODY)
      FileUtils.mkdir_p(File.join(dir, '.claude'))
      yield p, dir
    end
  end

  def settings_path(dir)
    File.join(dir, '.claude', 'settings.json')
  end

  def settings_file(dir)
    File.exist?(settings_path(dir)) ? JSON.parse(File.read(settings_path(dir))) : nil
  end

  # A group this tool owns carries BOTH markers. Anything else is somebody
  # else's and must survive untouched.
  def ours(dir, mode = 'testmode')
    (settings_file(dir)&.dig('hooks', 'Stop') || []).select do |g|
      g['_projected_by'] == 'kairos_hook_projector' && g['_mode'] == mode
    end
  end

  def config_files(dir)
    Dir.glob(File.join(dir, '.kairos', 'hook_configs', '*.json'))
  end


  # The stub's return shape depends on which test file loaded first, so read the
  # text out of either shape rather than depending on the winner.
  def tool_text(response)
    response.is_a?(Array) ? response.first[:text] : response.to_s
  end

  def run_tool(p, args)
    JSON.parse(tool_text(p.call(args)))
  end

  def compiled_artifact(document)
    JSON.generate(
      KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler.new.compile(
        mode_name: 'testmode', document: document, mode_body: BODY
      ).record['output']
    )
  end

  def apply_once(p)
    hash = run_tool(p, {})['plan_sha256']
    run_tool(p, 'apply' => true, 'confirm_sha256' => hash)
  end

  def snapshot(dir)
    Dir.glob(File.join(dir, '**/*'), File::FNM_DOTMATCH).sort.map do |f|
      [f, File.file?(f) ? File.read(f) : :dir]
    end
  end

  # --- THE property round 1 was about ---------------------------------------
  #
  # Round 1 asked for one writer on settings.json. Round 2 got there by not
  # writing it at all, and round 2 review showed that cost more than it bought.
  # The property that actually matters is narrower and is asserted here: this
  # tool changes only what it placed, for this mode. Everything else in the
  # file — PluginProjector's entries, another mode's, a hand-written hook with
  # no marker at all, and every key that is not `hooks` — comes back byte for
  # byte.

  def test_everything_this_tool_did_not_place_survives_byte_for_byte
    with_projector do |p, dir|
      foreign = {
        'hooks' => {
          'Stop' => [
            { 'hooks' => [{ 'command' => 'hand-written.sh' }] },
            { 'hooks' => [{ 'command' => 'projector.sh' }],
              '_projected_by' => 'kairos-chain' },
            { 'hooks' => [{ 'command' => 'other-mode.sh' }],
              '_projected_by' => 'kairos_hook_projector', '_mode' => 'other' },
            # Same mode name, someone else's marker. Ownership is an AND, so
            # this is not ours. Without this case the marker half of the AND is
            # untested: a falsifier that deletes it leaves the suite green.
            { 'hooks' => [{ 'command' => 'other-tool.sh' }],
              '_projected_by' => 'some-other-tool', '_mode' => 'testmode' }
          ],
          'SessionEnd' => [{ 'hooks' => [{ 'command' => 'untouched.sh' }] }]
        },
        'permissions' => { 'allow' => ['Bash(*)'] },
        'model' => 'opus'
      }
      File.write(settings_path(dir), JSON.pretty_generate(foreign))
      apply_once(p)

      after = settings_file(dir)
      assert_equal foreign['permissions'], after['permissions'], 'non-hook keys survive'
      assert_equal 'opus', after['model'], 'non-hook keys survive'
      assert_equal foreign['hooks']['SessionEnd'], after['hooks']['SessionEnd'],
                   'an untouched event survives'

      survivors = after['hooks']['Stop'].reject do |g|
        g['_projected_by'] == 'kairos_hook_projector' && g['_mode'] == 'testmode'
      end
      assert_equal foreign['hooks']['Stop'], survivors,
                   'a hand-written hook, PluginProjector\'s, and another mode\'s all survive'
      assert_equal 1, ours(dir).length, 'and exactly one group of ours is added'
    end
  end

  def test_reapplying_replaces_only_this_modes_group
    with_projector do |p, dir|
      apply_once(p)
      assert_equal 1, ours(dir).length

      p.document = doc('max_lines' => 40)
      apply_once(p)
      assert_equal 1, ours(dir).length, 'the old group is replaced, not appended to'
    end
  end

  def test_what_is_written_is_the_projection_pipeline_input
    with_projector do |p, dir|
      out = apply_once(p)
      assert_equal 'applied', out['action']
      assert_equal settings_path(dir), out['settings_file']
      assert File.exist?(settings_path(dir)), 'the harness configuration is the target'
      refute_match(/plugin_project/, out['next_step'], 'there is no second step now')

      entry = ours(dir).first['hooks'][0]
      assert_includes entry['command'], 'kairos-readable-gate'
      refute_includes entry['command'], '${', 'every substitution token must be resolved'

      cfg = JSON.parse(File.read(config_files(dir).first))
      assert_equal 60, cfg['max_lines'], "the mode's number must reach the gate"
    end
  end

  # --- propose by default ---------------------------------------------------

  def test_default_call_proposes_and_writes_nothing
    with_projector do |p, dir|
      before = snapshot(dir)
      out = run_tool(p, {})
      assert_equal 'proposal', out['action']
      assert out['nothing_written']
      assert_equal before, snapshot(dir)
    end
  end

  def test_apply_without_matching_hash_writes_nothing
    with_projector do |p, dir|
      before = snapshot(dir)
      out = run_tool(p, 'apply' => true, 'confirm_sha256' => 'not-the-hash')
      assert_equal 'refused_confirmation', out['action']
      assert_equal before, snapshot(dir)
    end
  end

  # The plan hash must cover the declaration, not just the compiled artifact.
  #
  # The field has to be one the artifact genuinely does not carry, and it has to
  # be checked rather than assumed. This test used `binding.mode_version`, which
  # DOES change the artifact — so the plan hash differed via the artifact and the
  # test passed while the document half of the hash was never exercised at all.
  # Removing 'document' from plan_hash left it green. These three were measured
  # artifact-identical and document-changed.
  def test_confirmation_covers_the_declaration_not_only_the_artifact
    [['version', '2'],
     ['not_gated', [{ 'section' => '§ X', 'reason' => 'prose only' }]],
     ['_comment', 'an author note']].each do |field, value|
      with_projector do |p, _dir|
        stale = run_tool(p, {})['plan_sha256']

        p.document = doc.merge(field => value)
        after = run_tool(p, {})

        # The premise is asserted, not assumed. `proposal` exposes no artifact
        # hash, and comparing a key that does not exist compares nil to nil and
        # passes for any field at all — which is how the original version of
        # this test came to rest on a field that does change the artifact.
        assert_equal compiled_artifact(doc), compiled_artifact(doc.merge(field => value)),
                     "#{field}: this test is only meaningful while the artifact is " \
                     'unchanged; pick another field'
        refute_equal stale, after['plan_sha256'],
                     "#{field}: a declaration edit that leaves the artifact identical " \
                     'must still invalidate the confirmation'

        out = run_tool(p, 'apply' => true, 'confirm_sha256' => stale)
        assert_equal 'refused_confirmation', out['action'], field
      end
    end
  end

  # Every part of a config filename is constrained upstream today: the mode name
  # by safe_segment?, the event by GATE_EVENTS, the gate by KNOWN_GATES, the
  # position by being an integer. So no declaration can currently drive this
  # branch, and the traversing-mode-name test does not reach it — the compiler
  # refuses first, with a different category. The guard still has to hold on its
  # own terms, for a symlinked root and for a future compiler that generates one
  # more name part. Drive resolve directly rather than leave it unfalsifiable.
  def test_a_config_filename_that_escapes_the_root_is_refused
    with_projector do |p, dir|
      artifact = { 'files' => { '../../pwned.json' => '{}' }, 'hooks' => {} }
      out = p.send(:resolve, 'testmode', artifact)

      assert_equal 'refused', out[:action]
      assert_equal 'unsafe_path', out[:refusal]['category']
      assert out[:nothing_written]
      refute File.exist?(File.join(dir, 'pwned.json')), 'nothing may be created outside the root'
      refute File.exist?(File.join(dir, '.kairos', 'pwned.json'))
    end
  end

  # A refusal from resolve carries symbol keys and no :error. Testing only for
  # :error let it fall through into planning, where it surfaced as a TypeError
  # instead of the refusal it was. Same reachability note as above: injected,
  # because no declaration can produce it.
  def test_a_refusal_from_resolution_is_returned_not_planned
    refusing = Class.new(Projector) do
      private

      def resolve(_mode, _artifact)
        { mode: 'testmode', action: 'refused', nothing_written: true,
          refusal: { 'category' => 'unsafe_path', 'detail' => 'injected' } }
      end
    end

    Dir.mktmpdir do |dir|
      p = refusing.new
      p.root = dir
      p.document = doc
      File.write(File.join(dir, 'body.md'), BODY)

      out = run_tool(p, 'apply' => true, 'confirm_sha256' => 'anything')

      assert_equal 'refused', out['action']
      assert_equal 'unsafe_path', out['refusal']['category']
      assert_nil settings_file(dir), 'a refusal must not write the settings file'
      assert_empty config_files(dir)
    end
  end

  def test_changing_a_threshold_is_visible_in_the_proposal
    with_projector do |p, dir|
      apply_once(p)
      p.document = doc('max_lines' => 40)

      out = run_tool(p, {})
      refute out['up_to_date']
      assert_equal 1, out['config_changes'].size

      apply_once(p)
      cfg = JSON.parse(File.read(config_files(dir).first))
      assert_equal 40, cfg['max_lines']
    end
  end

  def test_up_to_date_when_nothing_changed
    with_projector do |p, _dir|
      apply_once(p)
      out = run_tool(p, {})
      assert out['up_to_date']
      assert_empty out['writes_if_applied']
    end
  end

  def test_applying_twice_is_idempotent
    with_projector do |p, dir|
      apply_once(p)
      first = File.read(settings_path(dir))
      apply_once(p)
      assert_equal first, File.read(settings_path(dir))
    end
  end

  # --- what survives --------------------------------------------------------

  def test_entries_this_mode_does_not_own_survive
    with_projector do |p, dir|
      FileUtils.mkdir_p(File.dirname(settings_path(dir)))
      File.write(settings_path(dir), JSON.pretty_generate(
                                    'hooks' => {
                                      'Stop' => [{ 'hooks' => [{ 'command' => 'static.sh' }] },
                                                 { '_mode' => 'other',
                                                   'hooks' => [{ 'command' => 'other.sh' }] }]
                                    }
                                  ))
      out = apply_once(p)
      commands = settings_file(dir)['hooks']['Stop']
                 .flat_map { |g| Array(g['hooks']).map { |h| h['command'] } }
      assert_includes commands, 'static.sh', 'a shipped static hook must survive'
      assert_includes commands, 'other.sh', "another mode's entry must survive"
      assert_equal 2, out['entries_left_alone']
    end
  end

  def test_withdrawing_a_declaration_removes_only_this_modes_entries
    with_projector do |p, dir|
      FileUtils.mkdir_p(File.dirname(settings_path(dir)))
      File.write(settings_path(dir), JSON.pretty_generate(
                                    'hooks' => { 'Stop' => [{ 'hooks' => [{ 'command' => 'static.sh' }] }] }
                                  ))
      apply_once(p)
      p.document = doc.merge('hooks' => {})
      apply_once(p)

      commands = settings_file(dir)['hooks']['Stop']
                 .flat_map { |g| Array(g['hooks']).map { |h| h['command'] } }
      assert_equal ['static.sh'], commands
    end
  end

  # --- refusals -------------------------------------------------------------

  def test_compiler_refusal_writes_nothing
    with_projector(document: { 'mode_name' => 'testmode', 'version' => '1',
                               'extends' => ['x'] }) do |p, dir|
      before = snapshot(dir)
      out = run_tool(p, 'apply' => true, 'confirm_sha256' => 'anything')
      assert_equal 'refused', out['action']
      assert_equal 'composition_content_present', out['refusal']['category']
      assert_equal before, snapshot(dir)
    end
  end

  def test_drifted_mode_body_refuses_before_writing
    with_projector do |p, dir|
      before = snapshot(dir)
      p.document = doc.merge('binding' => {
                               'mode_version' => '0.1.0',
                               'mode_body_sha256' => Digest::SHA256.hexdigest('a different body')
                             })
      out = run_tool(p, 'apply' => true, 'confirm_sha256' => 'anything')
      assert_equal 'refused', out['action']
      assert_equal 'binding_mismatch', out['refusal']['category']
      assert_equal before, snapshot(dir)
    end
  end

  # Inv-7nr: a hook-composition change that cannot be recorded is not applied.
  def test_an_unrecordable_change_is_refused_not_applied
    with_projector do |p, dir|
      p.chain_result = { recorded: false, reason: 'chain unavailable in test' }
      before = snapshot(dir)
      hash = run_tool(p, {})['plan_sha256']
      out = run_tool(p, 'apply' => true, 'confirm_sha256' => hash)
      assert_equal 'refused_unrecorded', out['action']
      assert_equal before, snapshot(dir),
                   'nothing may land on disk when the change cannot be recorded'
    end
  end

  # Four shapes the merge cannot preserve. Each used to be silently dropped, and
  # the proposal reported only that settings.json would change — so an operator
  # with a forward-compatible or hand-edited entry lost it without being told.
  # Refusing is what the tool already does for JSON it cannot parse.
  def test_a_settings_shape_that_cannot_be_merged_is_refused_not_discarded
    {
      'a non-object top level' => '["not", "an", "object"]',
      'a non-object hooks key' => '{"hooks": "off"}',
      'an event that is not an array' => '{"hooks": {"Stop": {"a": 1}}}',
      'a group that is not an object' => '{"hooks": {"Stop": [null]}}'
    }.each do |label, raw|
      with_projector do |p, dir|
        File.write(settings_path(dir), raw)
        before = File.read(settings_path(dir))
        out = apply_once(p)
        assert_equal before, File.read(settings_path(dir)),
                     "#{label}: the operator's file must be left alone"
        assert out.to_s.match?(/refus/i) || out['error'].to_s.match?(/refus/i),
               "#{label}: expected a refusal, got #{out.inspect[0, 200]}"
      end
    end
  end

  def test_unparseable_settings_file_is_never_rewritten
    with_projector do |p, dir|
      FileUtils.mkdir_p(File.dirname(settings_path(dir)))
      File.write(settings_path(dir), '{ this is not json')
      out = run_tool(p, {})
      assert_equal 'RuntimeError', out['error']
      assert_match(/not valid JSON/, out['detail'])
      assert_equal '{ this is not json', File.read(settings_path(dir))
    end
  end

  def test_a_traversing_mode_name_never_reaches_a_path
    with_projector do |p, dir|
      evil = '../../../../pwned'
      p.document = doc.merge('mode_name' => evil)
      before = snapshot(dir)
      out = run_tool(p, 'mode' => evil, 'apply' => true, 'confirm_sha256' => 'anything')
      assert_equal 'refused', out['action']
      assert_equal 'unsafe_mode_name', out['refusal']['category']
      assert_equal before, snapshot(dir)
      refute Dir.exist?(File.join(dir, '..', 'pwned')), 'nothing may be created outside the root'
    end
  end
end
