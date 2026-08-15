# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'shellwords'

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
  # A real mode body is Japanese with § headings; the tool reads this file
  # back off disk before compiling. That read only feeds Digest::SHA256, which
  # works on bytes whatever the string is tagged, so these bytes make the
  # fixture honest rather than making the read's encoding falsifiable.
  BODY = "**Version:** 0.1.0\n## § 形\n応答は 60 行以内。長くなるなら図を一枚。\n"

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
    # The section name is Japanese with its §, like the mode it stands for.
    # It lands verbatim in the gate config file, so the config the tool writes
    # and re-reads carries non-ASCII bytes — which is what makes the plan
    # comparison read falsifiable: mis-tagged, those bytes compare unequal.
    {
      'mode_name' => 'testmode', 'version' => '1',
      'hooks' => { 'Stop' => [{ 'gate' => 'readable_gate',
                                'section' => '§ 形', 'params' => params }] }
    }
  end

  def with_projector(document: nil)
    Dir.mktmpdir do |dir|
      p = Projector.new
      p.root = dir
      p.document = document.nil? ? doc : document
      File.write(File.join(dir, 'body.md'), BODY, encoding: 'UTF-8')
      FileUtils.mkdir_p(File.join(dir, '.claude'))
      yield p, dir
    end
  end

  def settings_path(dir)
    File.join(dir, '.claude', 'settings.json')
  end

  def settings_file(dir)
    File.exist?(settings_path(dir)) ? JSON.parse(File.read(settings_path(dir), encoding: 'UTF-8')) : nil
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
      [f, File.file?(f) ? File.read(f, encoding: 'UTF-8') : :dir]
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
            # A hand-written hook carries the operator's own prose, Japanese
            # included. The settings read must bring these bytes back; an
            # ASCII-only settings fixture cannot fail when that read loses its
            # encoding argument under a US-ASCII locale.
            { 'hooks' => [{ 'command' => 'hand-written.sh --banner "§ 作業完了"' }] },
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
      File.write(settings_path(dir), JSON.pretty_generate(foreign), encoding: 'UTF-8')
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
      # The installed command is Shellwords-escaped, so the raw string never
      # contains '${' whether or not the token was substituted — an assertion
      # on the raw string cannot fail. Decode it first and look at the argv
      # the shell will actually deliver.
      argv = Shellwords.split(entry['command'])
      token = KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler::CONFIG_ROOT
      refute(argv.any? { |arg| arg.include?(token) },
             'every substitution token must be resolved')
      assert_includes argv,
                      File.join(dir, '.kairos', 'hook_configs',
                                'testmode.Stop.readable_gate.0.json'),
                      'the decoded command must name the resolved config path'

      cfg = JSON.parse(File.read(config_files(dir).first, encoding: 'UTF-8'))
      assert_equal 60, cfg['max_lines'], "the mode's number must reach the gate"
      assert_equal '§ 形', cfg['section'],
                   "the section name's non-ASCII bytes must reach the gate intact"
    end
  end

  # --- propose by default ---------------------------------------------------

  def test_default_call_proposes_and_writes_nothing
    with_projector do |p, dir|
      before = snapshot(dir)
      out = run_tool(p, {})
      assert_equal 'proposal', out['action']
      assert out['nothing_written']
      # The write set the operator confirms, stated in full: the settings
      # file and the one config, nothing else, and a chain record with them.
      assert_equal [settings_path(dir),
                    File.join(dir, '.kairos', 'hook_configs', 'testmode.Stop.readable_gate.0.json')],
                   out['writes_if_applied']
      assert out['also_records_to_chain']
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
  # Round 3 debt. The confirmation hash covers five components and only one of
  # them — the document — was ever falsified. Dropping any of the other four
  # left the suite green, and dropping the merged settings is the one that
  # matters: a third party editing settings.json between proposal and apply
  # would no longer invalidate the operator's confirmation.
  def test_every_component_of_the_confirmation_hash_is_load_bearing
    with_projector do |p, dir|
      base = run_tool(p, {})['plan_sha256']

      # A foreign hook appearing after the proposal changes the merged settings
      # and nothing else this tool produces.
      File.write(settings_path(dir),
                 JSON.generate('hooks' => { 'Stop' => [{ 'hooks' => [{ 'command' => 'x.sh' }] }] }),
                 encoding: 'UTF-8')
      refute_equal base, run_tool(p, {})['plan_sha256'],
                   'a change to the merged settings must change the hash'

      # A threshold edit changes the artifact and the config file contents while
      # leaving every command string identical.
      File.write(settings_path(dir), JSON.generate({}), encoding: 'UTF-8')
      restored = run_tool(p, {})['plan_sha256']
      p.document = doc('max_lines' => 40)
      refute_equal restored, run_tool(p, {})['plan_sha256'],
                   'a change to the config file contents must change the hash'
    end
  end

  # Round 4. The recorder guarded on `::KairosChain::Chain`, a top-level name
  # nothing defines — the class is nested under KairosMcp, and every other
  # SkillSet in the tree spells it that way. The guard was therefore always
  # false, apply! always returned refused_unrecorded, and stage 2 activation had
  # never once succeeded for anyone. No test could see it: the double below
  # replaces record_to_chain wholesale, so the real method was never executed.
  def test_the_recorder_names_a_chain_constant_that_can_exist
    src = File.read(File.join(File.dirname(__dir__), 'tools', 'mode_hooks_project.rb'),
                    encoding: 'UTF-8')
    body = src[/def record_to_chain.*?\n          end/m]
    refute_nil body, 'record_to_chain must exist'

    guarded = body.scan(/defined\?\(::([A-Za-z0-9_:]+)\)/).flatten.uniq
    called = body.scan(/::([A-Za-z0-9_:]+)\.new/).flatten.uniq
    assert_equal guarded, called,
                 'the recorder must guard on the same constant it calls'
    guarded.each do |name|
      refute_match(/\AKairosChain::/, name,
                   "#{name} is the top-level spelling; the class is nested under " \
                   'KairosMcp, so this guard can never be true and every apply ' \
                   'returns refused_unrecorded')
    end
  end

  # Drives the real record_to_chain rather than the double. A fake ledger stands
  # in for the chain, and the test refuses to run at all when the real one is
  # loaded — appending to a live ledger from a test is the worse of the two.
  def test_the_real_recorder_records_and_reports_the_block
    if defined?(::KairosMcp::KairosChain::Chain)
      skip 'the real chain is loaded; this test must not append to it'
    end

    block = Struct.new(:index, :hash).new(42, 'deadbeef')
    appended = []
    fake = Class.new do
      define_method(:add_block) do |data|
        appended << data
        block
      end
    end

    namespace_existed = defined?(::KairosMcp::KairosChain) ? true : false
    ::KairosMcp.const_set(:KairosChain, Module.new) unless namespace_existed
    ::KairosMcp::KairosChain.const_set(:Chain, fake)
    begin
      real = Projector.superclass.new
      compiled = KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler
                 .new.compile(mode_name: 'testmode', document: doc)
      out = real.send(:record_to_chain, 'testmode', compiled)
      assert out[:recorded], out.inspect
      assert_equal 42, out[:block_index]
      assert_equal 'deadbeef', out[:hash]
      assert_equal 1, appended.length, 'exactly one block is appended'
      assert_equal ['mode_hooks_project mode=testmode', JSON.generate(compiled.record)],
                   appended.first,
                   'the second element is the whole compile record — the payload Inv-7nr exists for'
    ensure
      ::KairosMcp::KairosChain.send(:remove_const, :Chain)
      ::KairosMcp.send(:remove_const, :KairosChain) unless namespace_existed
    end
  end

  # The confirmation binds five things. The earlier test moved a threshold,
  # which changes the document, the artifact and the file contents all at once
  # while the target path never varies — so three of the five could be deleted
  # from the hash and the suite stayed green. Each component is varied alone
  # here, against the real plan_hash.
  #
  # Artifact and document cannot be separated and that is by construction: the
  # artifact is a pure function of the document, so nothing can move one without
  # the other. They are covered together and this says so rather than implying
  # five independent axes.
  def test_each_component_of_the_confirmation_hash_moves_it_alone
    with_projector do |p, _dir|
      compiler = KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler
      compiled = compiler.new.compile(mode_name: 'testmode', document: doc)
      other = compiler.new.compile(mode_name: 'testmode', document: doc('max_lines' => 40))

      resolved = { 'settings_path' => '/root/.claude/settings.json',
                   'files' => { '/root/.kairos/hook_configs/a.json' => '{"max_lines":60}' } }
      desired = { 'hooks' => { 'Stop' => [{ 'hooks' => [] }] } }
      base = p.send(:plan_hash, resolved, desired, compiled)

      {
        'the target path' =>
          [resolved.merge('settings_path' => '/elsewhere/.claude/settings.json'),
           desired, compiled],
        'the file contents' =>
          [resolved.merge('files' => { '/root/.kairos/hook_configs/a.json' => '{"max_lines":1}' }),
           desired, compiled],
        'the merged settings' =>
          [resolved, { 'hooks' => { 'Stop' => [{ 'hooks' => [{ 'command' => 'x' }] }] } }, compiled],
        'the artifact and declaration together' =>
          [resolved, desired, other]
      }.each do |what, args|
        refute_equal base, p.send(:plan_hash, *args),
                     "#{what} must move the confirmation hash"
      end
    end
  end

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
      File.write(File.join(dir, 'body.md'), BODY, encoding: 'UTF-8')

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
      # A threshold move rewrites the config alone: the command strings are
      # unchanged, so settings.json is not in the write set.
      assert_equal [File.join(dir, '.kairos', 'hook_configs', 'testmode.Stop.readable_gate.0.json')],
                   out['writes_if_applied']

      apply_once(p)
      cfg = JSON.parse(File.read(config_files(dir).first, encoding: 'UTF-8'))
      assert_equal 40, cfg['max_lines']
    end
  end

  # The proposal above is half the contract; this is the other half. The
  # operator confirms writes_if_applied, which omits settings.json when the
  # command strings are unchanged — and apply! used to write it anyway,
  # replaying a snapshot read before record_to_chain's ledger wait over
  # anything written concurrently (a Claude Code "always allow" grant is the
  # ordinary case). The witness is the write, not the content: atomic_write
  # renames a fresh inode over the target, so a rewrite with identical bytes
  # still replaces the inode. A config-only apply must leave inode and mtime
  # alone.
  def test_a_config_only_apply_never_touches_the_settings_file
    with_projector do |p, dir|
      apply_once(p)
      before = File.stat(settings_path(dir))

      p.document = doc('max_lines' => 40)
      proposal = run_tool(p, {})
      refute_includes proposal['writes_if_applied'], settings_path(dir),
                      'premise: a threshold edit must not put settings.json in the write set'
      out = run_tool(p, 'apply' => true, 'confirm_sha256' => proposal['plan_sha256'])
      assert_equal 'applied', out['action']

      after = File.stat(settings_path(dir))
      assert_equal before.ino, after.ino,
                   'a plan that does not name settings.json must not replace its inode'
      assert_equal before.mtime, after.mtime,
                   'a plan that does not name settings.json must not rewrite it'
      assert_equal 40,
                   JSON.parse(File.read(config_files(dir).first, encoding: 'UTF-8'))['max_lines'],
                   'the config write itself still lands'
    end
  end

  # Round 9, N4 — the mirror of the round 8 defect above. The write guard
  # skips settings.json on a config-only apply, and the RESULT still named it:
  # settings_file plus "the hook is live", for a file this call never opened.
  # The probe is the one the code documents at ours?: a writer (Claude Code
  # recording an "always allow") lands while record_to_chain waits on the
  # ledger lock. The round 8 guard rightly lets that write stand — the window
  # is open by the 2026-08-13 operator ruling and stays open — but the old
  # result then asserted liveness over a settings.json carrying no hooks key
  # at all. The result must name the paths actually written, nothing more.
  def test_a_config_only_apply_result_names_only_the_paths_it_wrote
    racing = Class.new(Projector) do
      attr_accessor :race_write

      private

      # The concurrent writer, driven at the exact point the window opens:
      # inside record_to_chain, between the plan's settings read and the
      # (correctly skipped) settings write.
      def record_to_chain(_mode, _compiled)
        if race_write
          File.write(File.join(root, '.claude', 'settings.json'),
                     JSON.generate(race_write), encoding: 'UTF-8')
        end
        super
      end
    end

    Dir.mktmpdir do |dir|
      p = racing.new
      p.root = dir
      p.document = doc
      File.write(File.join(dir, 'body.md'), BODY, encoding: 'UTF-8')
      FileUtils.mkdir_p(File.join(dir, '.claude'))

      apply_once(p)
      p.document = doc('max_lines' => 40)
      p.race_write = { 'permissions' => { 'allow' => ['Bash(*)'] } }
      out = apply_once(p)

      assert_equal 'applied', out['action']
      # Premise, exactly as ruled: the racing write stands. No re-read, no
      # lock, no repair — the window itself is not under test here.
      assert_nil settings_file(dir)['hooks'],
                 'premise: the concurrent write stands; the window is open by ruling'

      refute out.key?('settings_file'),
             'the result must not name a settings file this call never opened'
      refute_match(/the hook is live/, out['next_step'].to_s,
                   'the result must not assert liveness this call did not write')
      # Round 10, DD-1: round 9's replacement sentence sent the operator to
      # hooks_status, which never opens settings.json's hooks table — its own
      # note and plugin/SKILL.md both say it reports which declarations
      # exist, not what is installed. The tool that does the fresh read is
      # mode_hooks_validate's installed check, and the name is pinned here
      # because round 9 left it unpinned.
      assert_match(/mode_hooks_validate/, out['next_step'].to_s,
                   'the liveness question must go to a tool that actually reads ' \
                   'settings.json')
      refute_match(/hooks_status/, out['next_step'].to_s,
                   'hooks_status cannot answer what is live')
      assert_equal [File.join(dir, '.kairos', 'hook_configs',
                              'testmode.Stop.readable_gate.0.json')],
                   out['config_files'],
                   'the result names the paths actually written, nothing more'
    end
  end

  # Round 10, DD-1 — the settings-changed branch, the one round 9 fixed the
  # mirror of and left unpinned. It said "the hook is live on the next turn;
  # no further step" unconditionally — including on the UNINSTALL this
  # SkillSet documents (emptying a declaration's hooks), where the call has
  # just removed every entry and settings.json carries no hooks key at all.
  # The corrected result states what was written and directs liveness to
  # mode_hooks_validate's installed check, the one that reads settings.json
  # fresh; the wording must hold for install AND removal, so both routes are
  # driven here.
  def test_a_settings_changed_result_states_the_write_and_defers_liveness
    with_projector do |p, dir|
      out = apply_once(p)
      assert_equal 'applied', out['action']
      assert_equal settings_path(dir), out['settings_file'],
                   'the write this call performed is stated'
      assert_match(/mode_hooks_validate/, out['next_step'],
                   'liveness goes to the tool that reads settings.json fresh')
      refute_match(/hooks_status/, out['next_step'],
                   'hooks_status reports declarations, not what is installed')
      refute_match(/is live/, out['next_step'],
                   'no liveness assertion this call did not verify')

      # The removal route — the only uninstall this SkillSet documents. The
      # old sentence asserted a live hook over a settings.json this very
      # call had just emptied of its hooks key.
      p.document = doc.merge('hooks' => {})
      out = apply_once(p)
      assert_equal 'applied', out['action']
      assert_nil settings_file(dir)['hooks'],
                 'premise: this apply removed the hooks key entirely'
      assert_equal settings_path(dir), out['settings_file'],
                   'the removal write is stated the same way'
      refute_match(/is live/, out['next_step'],
                   'a removal must never be reported as a live hook')
      refute_match(/no further step/, out['next_step'],
                   'after an uninstall the liveness question is still open')
      assert_match(/mode_hooks_validate/, out['next_step'],
                   'the removal route directs liveness to the fresh read too')
    end
  end

  # Round 10, DD-4. apply! wrote every entry in resolved['files'] while the
  # confirmed proposal's writes_if_applied named only config_changed: a
  # mixed apply whose proposal named one config rewrote two, the second with
  # identical bytes on a fresh inode — a write the operator never confirmed.
  # plan_for runs fresh in the same call as apply!, so a config it saw
  # unchanged already carries the desired bytes and is safe to skip. The
  # witness is the inode: atomic_write renames a fresh one over the target,
  # so an unchanged inode means no write happened.
  def test_a_mixed_apply_writes_only_the_configs_the_plan_named
    two = doc
    two['hooks']['Stop'] << { 'gate' => 'readable_gate', 'section' => '§ 二',
                              'params' => { 'max_lines' => 50 } }
    with_projector(document: two) do |p, dir|
      apply_once(p)
      cfg0 = File.join(dir, '.kairos', 'hook_configs', 'testmode.Stop.readable_gate.0.json')
      cfg1 = File.join(dir, '.kairos', 'hook_configs', 'testmode.Stop.readable_gate.1.json')
      before0 = File.stat(cfg0)

      changed = doc
      changed['hooks']['Stop'] << { 'gate' => 'readable_gate', 'section' => '§ 二',
                                    'params' => { 'max_lines' => 40 } }
      p.document = changed
      proposal = run_tool(p, {})
      assert_equal [cfg1], proposal['writes_if_applied'],
                   'premise: the plan names the changed config alone'

      out = run_tool(p, 'apply' => true, 'confirm_sha256' => proposal['plan_sha256'])
      assert_equal 'applied', out['action']
      assert_equal before0.ino, File.stat(cfg0).ino,
                   'a config the plan did not name must not be rewritten, ' \
                   'not even with identical bytes'
      assert_equal [cfg1], out['config_files'],
                   'the result names the paths actually written, nothing more'
      assert_equal 40, JSON.parse(File.read(cfg1, encoding: 'UTF-8'))['max_lines'],
                   'the write the operator did confirm still lands'
    end
  end

  # Round 10, DD-5 — the defect class round 8 closed in the validator's
  # config_bytes and round 9 in its settings_hooks, still open on the write
  # path: plan_for read each config with a bare File.read, so one chmod-000
  # config turned the whole proposal into a raw Errno::EACCES body through
  # call. Reachable here, unlike the equivalent-looking validator guard:
  # this tool runs no BootTimeAssertion, so nothing raises ahead of the
  # read (measured pre-fix — the raw error body did surface). Unreadable
  # degrades to "not known to carry the desired bytes": the config joins
  # the write set, and the apply restores the declared bytes over it.
  def test_an_unreadable_config_degrades_to_a_planned_rewrite_not_an_error
    with_projector do |p, dir|
      apply_once(p)
      cfg = config_files(dir).first
      File.chmod(0o000, cfg)
      begin
        out = run_tool(p, {})
        assert_nil out['error'],
                   "a proposal must not surface a raw read error: #{out.inspect[0, 200]}"
        assert_equal 'proposal', out['action']
        assert_includes out['config_changes'], File.basename(cfg),
                        'an unreadable config is not known to be desired; it is rewritten'

        applied = run_tool(p, 'apply' => true, 'confirm_sha256' => out['plan_sha256'])
        assert_equal 'applied', applied['action']
      ensure
        File.chmod(0o644, cfg) if File.exist?(cfg)
      end
      assert_equal 60, JSON.parse(File.read(cfg, encoding: 'UTF-8'))['max_lines'],
                   'the declared bytes are restored over the unreadable file'
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

  # Content equality is not the property — no write and no record is. This
  # test used to compare bytes, which cannot see a rewrite that produces
  # identical bytes nor the extra chain block, and both happened on every
  # idle apply. The witnesses here can: atomic_write renames a fresh inode
  # over the target, so an unchanged inode means no write; and the poisoned
  # chain result turns any attempt to record into refused_unrecorded, so
  # 'up_to_date' means the recorder was never reached.
  def test_a_second_apply_writes_nothing_and_records_nothing
    with_projector do |p, dir|
      apply_once(p)
      files = [settings_path(dir)] + config_files(dir)
      inodes = files.map { |f| File.stat(f).ino }
      p.chain_result = { recorded: false, reason: 'an idle apply must not reach the recorder' }

      out = apply_once(p)
      assert_equal 'up_to_date', out['action']
      assert out['nothing_written']
      assert_equal inodes, files.map { |f| File.stat(f).ino },
                   'no file is rewritten, not even with identical bytes'
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
                                  ), encoding: 'UTF-8')
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
                                  ), encoding: 'UTF-8')
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
        File.write(settings_path(dir), raw, encoding: 'UTF-8')
        before = File.read(settings_path(dir), encoding: 'UTF-8')
        out = apply_once(p)
        assert_equal before, File.read(settings_path(dir), encoding: 'UTF-8'),
                     "#{label}: the operator's file must be left alone"
        assert out.to_s.match?(/refus/i) || out['error'].to_s.match?(/refus/i),
               "#{label}: expected a refusal, got #{out.inspect[0, 200]}"
      end
    end
  end

  def test_unparseable_settings_file_is_never_rewritten
    with_projector do |p, dir|
      FileUtils.mkdir_p(File.dirname(settings_path(dir)))
      File.write(settings_path(dir), '{ this is not json', encoding: 'UTF-8')
      out = run_tool(p, {})
      assert_equal 'RuntimeError', out['error']
      assert_match(/not valid JSON/, out['detail'])
      assert_equal '{ this is not json', File.read(settings_path(dir), encoding: 'UTF-8')
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
