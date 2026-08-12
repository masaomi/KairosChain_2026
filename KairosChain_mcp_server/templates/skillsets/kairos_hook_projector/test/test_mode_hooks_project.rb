# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'

module KairosMcp
  module Tools
    class BaseTool
      def text_content(str)
        str
      end
    end
  end
end

require_relative '../tools/mode_hooks_project'

# Stage 2 activation, after round 1 review moved the write off the harness
# configuration and onto this SkillSet's own plugin/hooks.json.
class TestModeHooksProject < Minitest::Test
  BODY = "**Version:** 0.1.0\n## Shape\nKeep it under 60 lines.\n"

  # Test double: the environment lookups and the chain are the impure surface.
  # Everything else — compile, plan, hash, merge, write — is the real thing.
  class Projector < KairosMcp::SkillSets::KairosHookProjector::Tools::ModeHooksProject
    attr_accessor :root, :document, :chain_result

    private

    def data_dir = File.join(@root, '.kairos')
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

  def hooks_path(dir)
    File.join(dir, '.kairos', 'skillsets', 'kairos_hook_projector', 'plugin', 'hooks.json')
  end

  def hooks_file(dir)
    File.exist?(hooks_path(dir)) ? JSON.parse(File.read(hooks_path(dir))) : nil
  end

  def config_files(dir)
    Dir.glob(File.join(dir, '.kairos', 'hook_configs', '*.json'))
  end

  def run_tool(p, args)
    JSON.parse(p.call(args))
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

  def test_the_harness_configuration_is_never_written
    with_projector do |p, dir|
      settings = File.join(dir, '.claude', 'settings.json')
      File.write(settings, JSON.pretty_generate('hooks' => { 'Stop' => [] },
                                                'permissions' => { 'allow' => ['Bash(*)'] }))
      before = File.read(settings)
      apply_once(p)
      assert_equal before, File.read(settings),
                   'PluginProjector is the single writer to the harness config; ' \
                   'this tool must reach only its own SkillSet'
    end
  end

  def test_what_is_written_is_the_projection_pipeline_input
    with_projector do |p, dir|
      out = apply_once(p)
      assert_equal 'applied', out['action']
      assert_equal hooks_path(dir), out['hooks_file']
      assert File.exist?(hooks_path(dir)), 'plugin/hooks.json is what the projector reads'
      assert_match(/plugin_project/, out['next_step'])

      entry = hooks_file(dir)['hooks']['Stop'][0]['hooks'][0]
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
  # Editing only `binding` or `version` leaves the artifact identical.
  def test_confirmation_covers_the_declaration_not_only_the_artifact
    with_projector do |p, _dir|
      stale = run_tool(p, {})['plan_sha256']
      p.document = doc.merge('binding' => { 'mode_version' => '9.9.9' })
      fresh = run_tool(p, {})['plan_sha256']
      refute_equal stale, fresh,
                   'a declaration edit that leaves the artifact identical must still ' \
                   'invalidate the confirmation'
      out = run_tool(p, 'apply' => true, 'confirm_sha256' => stale)
      assert_equal 'refused_confirmation', out['action']
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
      first = File.read(hooks_path(dir))
      apply_once(p)
      assert_equal first, File.read(hooks_path(dir))
    end
  end

  # --- what survives --------------------------------------------------------

  def test_entries_this_mode_does_not_own_survive
    with_projector do |p, dir|
      FileUtils.mkdir_p(File.dirname(hooks_path(dir)))
      File.write(hooks_path(dir), JSON.pretty_generate(
                                    'hooks' => {
                                      'Stop' => [{ 'hooks' => [{ 'command' => 'static.sh' }] },
                                                 { '_mode' => 'other',
                                                   'hooks' => [{ 'command' => 'other.sh' }] }]
                                    }
                                  ))
      out = apply_once(p)
      commands = hooks_file(dir)['hooks']['Stop']
                 .flat_map { |g| Array(g['hooks']).map { |h| h['command'] } }
      assert_includes commands, 'static.sh', 'a shipped static hook must survive'
      assert_includes commands, 'other.sh', "another mode's entry must survive"
      assert_equal 2, out['entries_left_alone']
    end
  end

  def test_withdrawing_a_declaration_removes_only_this_modes_entries
    with_projector do |p, dir|
      FileUtils.mkdir_p(File.dirname(hooks_path(dir)))
      File.write(hooks_path(dir), JSON.pretty_generate(
                                    'hooks' => { 'Stop' => [{ 'hooks' => [{ 'command' => 'static.sh' }] }] }
                                  ))
      apply_once(p)
      p.document = doc.merge('hooks' => {})
      apply_once(p)

      commands = hooks_file(dir)['hooks']['Stop']
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

  def test_unparseable_hooks_file_is_never_rewritten
    with_projector do |p, dir|
      FileUtils.mkdir_p(File.dirname(hooks_path(dir)))
      File.write(hooks_path(dir), '{ this is not json')
      out = run_tool(p, {})
      assert_equal 'RuntimeError', out['error']
      assert_match(/not valid JSON/, out['detail'])
      assert_equal '{ this is not json', File.read(hooks_path(dir))
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
