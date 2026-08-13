# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

# Stage 0 commit 3 smoke test: HooksStatus tool returns a well-formed
# response and the boot-time assertion reports passed when the tool body
# does not touch any watched file.
#
# This test deliberately stubs the BaseTool dependency rather than loading
# the full KairosChain MCP server gem, so that the SkillSet's stage 0 surface
# can be validated in isolation. Integration with the gem-level tool
# registration is verified at gem build / install time, not here.

module KairosMcp
  module Tools
    # Minimal stub of KairosMcp::Tools::BaseTool sufficient for stage 0
    # smoke testing. The real implementation lives in
    # KairosChain_mcp_server/lib/kairos_mcp/tools/base_tool.rb.
    class BaseTool
      def initialize(safety = nil, registry: nil); end

      def text_content(text)
        [{ type: 'text', text: text }]
      end
    end
  end
end unless defined?(::KairosMcp::Tools::BaseTool)

# Stub the KairosMcp module project_root accessor so the tool can resolve
# .claude/settings.json against our tmpdir.
module KairosMcp
  class << self
    attr_accessor :project_root unless method_defined?(:project_root)
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
      File.read(File.join(File.expand_path('..', __dir__), 'skillset.json'))
    )['tool_classes']
    if tool_classes.any? { |c| c.end_with?('ModeHooksProject') }
      assert_match(/stage [2-9]/, body['stage'],
                   'projection tool is registered, so the reported stage must be 2 or later')
    end

    assert_equal @tmpdir, body['project_root']
    assert body['schema']['present'],
           'stage 0 schema (_schema.json) must be present after commit 2'
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
end
