# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

# HooksStatus smoke test: the tool returns a well-formed response, the
# boot-time assertion reports passed when the tool body does not touch any
# watched file, and the declaration inventory looks where declarations
# actually live.
#
# This test deliberately stubs the BaseTool dependency rather than loading
# the full KairosChain MCP server gem, so that the tool's surface can be
# validated in isolation. Integration with the gem-level tool registration
# is verified at gem build / install time, not here.

module KairosMcp
  module Tools
    # Minimal stub of KairosMcp::Tools::BaseTool sufficient for smoke
    # testing. The real implementation lives in
    # KairosChain_mcp_server/lib/kairos_mcp/tools/base_tool.rb.
    class BaseTool
      def initialize(safety = nil, registry: nil); end

      def text_content(text)
        [{ type: 'text', text: text }]
      end
    end
  end
end unless defined?(::KairosMcp::Tools::BaseTool)

# Stub the KairosMcp module accessors the tool resolves its environment
# through: project_root for .claude/settings.json, skills_dir for the
# instance directory that holds mode bodies and their declarations.
module KairosMcp
  class << self
    attr_accessor :project_root unless method_defined?(:project_root)
    attr_accessor :skills_dir unless method_defined?(:skills_dir)
  end
end

require_relative '../tools/hooks_status'

class TestHooksStatus < Minitest::Test
  ToolClass = ::KairosMcp::SkillSets::KairosHookProjector::Tools::HooksStatus

  def setup
    @tmpdir = Dir.mktmpdir('kairos_hook_projector_smoke_')
    ::KairosMcp.project_root = @tmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
    ::KairosMcp.project_root = nil
  end

  def test_tool_returns_well_formed_response_with_assertion_passed
    response = ToolClass.new.call({})
    assert_kind_of Array, response
    assert_equal 'text', response.first[:type]

    body = JSON.parse(response.first[:text])

    # Shape invariants
    assert_equal 'kairos_hook_projector', body['skillset']
    assert_match(/^stage \d/, body['stage'])

    # The reported stage must not lag the shipped capability. A SkillSet that
    # can write to the harness config while still calling itself stage 0 is the
    # drift this whole SkillSet exists to catch, one level up.
    tool_classes = JSON.parse(
      File.read(File.join(File.expand_path('..', __dir__), 'skillset.json'), encoding: 'UTF-8')
    )['tool_classes']
    if tool_classes.any? { |c| c.end_with?('ModeHooksProject') }
      assert_match(/stage [2-9]/, body['stage'],
                   'projection tool is registered, so the reported stage must be 2 or later')
    end

    assert_equal @tmpdir, body['project_root']
    assert body['schema']['present'],
           'the shipped schema (_schema.json) must be present'
    assert_kind_of Integer, body['mode_hooks']['count']
    assert_kind_of Array, body['mode_hooks']['files']

    # Boot-time assertion outcome
    assert_equal 'passed', body['boot_time_assertion']['status']
    watched = body['boot_time_assertion']['watched_paths']
    assert_kind_of Array, watched
    refute_empty watched
    # The exact path, not a suffix. `end_with?('settings.json')` passes for a
    # watch set pointing anywhere at all, which is how the round 2 defect —
    # a target built from the tool file's own location rather than the project
    # root — survived a test written to catch it.
    assert_equal [File.join(body['project_root'], '.claude', 'settings.json')],
                 watched,
                 'the watched path must be the settings file under the reported ' \
                 'project root, and nothing else'
  end

  # The inventory must look where _EXAMPLE.json tells a consumer to put a
  # declaration: beside the mode body, named <mode>.mode_hooks.json. The
  # SkillSet's own mode_hooks/ directory ships only underscore-prefixed
  # non-modes, so an inventory pointed there reports count 0 while the
  # declaration below is live — which is exactly how the shipped defect read.
  def test_inventory_finds_a_declaration_beside_the_mode_body
    skills = File.join(@tmpdir, '.kairos', 'skills')
    FileUtils.mkdir_p(skills)
    File.write(File.join(skills, 'mymode.md'), "# mymode\n", encoding: 'UTF-8')
    declaration = File.join(skills, 'mymode.mode_hooks.json')
    File.write(declaration, JSON.generate('mode_name' => 'mymode', 'version' => '1'), encoding: 'UTF-8')
    ::KairosMcp.skills_dir = skills

    body = JSON.parse(ToolClass.new.call({}).first[:text])
    assert_equal 1, body['mode_hooks']['count']
    assert_equal [declaration], body['mode_hooks']['files'],
                 'the inventory must name the file the locator resolves, ' \
                 'not the contents of the SkillSet\'s own mode_hooks/ directory'
  ensure
    ::KairosMcp.skills_dir = nil
  end

  # "I could not look" must not read as "there is nothing". One raising
  # accessor wipes the whole enumeration — including a declaration that
  # resolves perfectly — so the body must say the enumeration failed and
  # claim no count, rather than report count 0 as fact. Same principle as
  # mode_hooks_validate's round 8 repair: a settings file it could not read
  # yields UNKNOWN_INSTALLED, not OK.
  def test_enumeration_failure_is_reported_not_swallowed
    skills = File.join(@tmpdir, '.kairos', 'skills')
    FileUtils.mkdir_p(skills)
    File.write(File.join(skills, 'mymode.md'), "# mymode\n", encoding: 'UTF-8')
    File.write(File.join(skills, 'mymode.mode_hooks.json'),
               JSON.generate('mode_name' => 'mymode', 'version' => '1'),
               encoding: 'UTF-8')
    ::KairosMcp.skills_dir = skills
    # No sibling test defines md_path on the stub module, so this raising
    # accessor is this test's own and is removed in the ensure below.
    ::KairosMcp.define_singleton_method(:md_path) { raise Errno::EACCES, 'developer mode body' }

    body = JSON.parse(ToolClass.new.call({}).first[:text])

    # The tool did not raise: the status body still composed around the failure.
    assert_equal 'kairos_hook_projector', body['skillset']
    assert_equal 'passed', body['boot_time_assertion']['status']

    error = body['mode_hooks']['enumeration_error']
    assert_kind_of String, error,
                   'a raising accessor must surface as mode_hooks.enumeration_error, ' \
                   'not vanish into an empty inventory'
    assert_match(/Errno::EACCES/, error, 'the error must say what failed')
    refute body['mode_hooks'].key?('count'),
           'no count may be claimed when the tool could not enumerate'
  ensure
    ::KairosMcp.singleton_class.send(:remove_method, :md_path)
    ::KairosMcp.skills_dir = nil
  end

  # Same contract as above, but driven through the REAL enumeration — no
  # stubbed raise. The stubbed test passed round 8 while Dir.glob still
  # answered [] for a directory it could not open, because glob's failure
  # mode is silence, not an exception. This test makes the directory itself
  # unreadable: the enumerator must raise (Dir.children does; Dir.glob does
  # not) for the failure to reach enumeration_error at all.
  def test_unreadable_skills_dir_reports_enumeration_error_not_count_zero
    skip 'chmod 000 does not restrict root' if Process.uid.zero?

    skills = File.join(@tmpdir, '.kairos', 'skills')
    FileUtils.mkdir_p(skills)
    File.write(File.join(skills, 'mymode.md'), "# mymode\n", encoding: 'UTF-8')
    File.write(File.join(skills, 'mymode.mode_hooks.json'),
               JSON.generate('mode_name' => 'mymode', 'version' => '1'),
               encoding: 'UTF-8')
    ::KairosMcp.skills_dir = skills
    File.chmod(0o000, skills)

    body = JSON.parse(ToolClass.new.call({}).first[:text])

    error = body['mode_hooks']['enumeration_error']
    assert_kind_of String, error,
                   'an unreadable skills directory must surface as ' \
                   'mode_hooks.enumeration_error, not read as an empty inventory'
    assert_match(/Errno::EACCES/, error, 'the error must say what failed')
    refute body['mode_hooks'].key?('count'),
           'no count may be claimed when the directory could not be opened'
  ensure
    File.chmod(0o755, skills) if skills && File.directory?(skills)
    ::KairosMcp.skills_dir = nil
  end

  # A skills path containing glob metacharacters must still resolve. With
  # Dir.glob the brackets in sk[1] were read as a character class, the glob
  # matched nothing, and this tool reported count 0 for a mode that
  # mode_hooks_validate — which joins the path instead of globbing —
  # resolved fine: two tools in one SkillSet disagreeing about whether the
  # mode exists. Dir.children does no pattern matching.
  def test_metacharacter_skills_path_still_resolves_declarations
    skills = File.join(@tmpdir, '.kairos', 'sk[1]')
    FileUtils.mkdir_p(skills)
    File.write(File.join(skills, 'mymode.md'), "# mymode\n", encoding: 'UTF-8')
    declaration = File.join(skills, 'mymode.mode_hooks.json')
    File.write(declaration, JSON.generate('mode_name' => 'mymode', 'version' => '1'), encoding: 'UTF-8')
    ::KairosMcp.skills_dir = skills

    body = JSON.parse(ToolClass.new.call({}).first[:text])
    assert_equal 1, body['mode_hooks']['count'],
                 'a declaration under a metacharacter path must be counted'
    assert_equal [declaration], body['mode_hooks']['files'],
                 'the inventory must name the declaration the locator resolves'
  ensure
    ::KairosMcp.skills_dir = nil
  end

  # The fix must not turn glob's one truthful empty into a false alarm: a
  # configured-but-absent skills directory is "no custom bodies", not a
  # failed enumeration. skills_dir in the gem is a joined path that no
  # accessor creates, so this is the normal fresh-install state — a bare
  # Dir.children would report Errno::ENOENT here forever.
  def test_nonexistent_skills_dir_is_an_empty_inventory_not_an_error
    ::KairosMcp.skills_dir = File.join(@tmpdir, '.kairos', 'does_not_exist')

    body = JSON.parse(ToolClass.new.call({}).first[:text])
    assert_equal 0, body['mode_hooks']['count'],
                 'an absent skills dir must read as zero custom bodies'
    refute body['mode_hooks'].key?('enumeration_error'),
           'an absent skills dir is not a failed enumeration'
  ensure
    ::KairosMcp.skills_dir = nil
  end
end
