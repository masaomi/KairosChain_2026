# frozen_string_literal: true
# Tests for the shipped proactive_tutorial instruction mode.
#
# The property that justifies this mode: before projection, Claude Code passes
# only the head of an MCP server's `instructions` to the model (4,096
# characters by default, 2,048 in older versions, counted in UTF-16 code
# units). The six proactive items must therefore survive the smaller cap
# *after* the first-run setup hint that Protocol#load_instructions prepends.
# The test drives the real load_instructions path rather than re-assembling
# the string, so a longer hint or a reordered body fails it.

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/initializer'
require 'kairos_mcp/protocol'
require 'kairos_mcp/skills_config'
require 'kairos_mcp/tools/instructions_update'

class ProactiveTutorialModeTest < Minitest::Test
  TEMPLATE = 'skills/proactive_tutorial.md'
  OLD_CAP = 2048
  ITEMS = [
    '1. L2 (session memory)',
    '2. L1 (reusable knowledge)',
    '3. Tidy up',
    '4. Review',
    '5. Skill tips',
    '6. Own mode'
  ].freeze
  LIMIT_LINE = 'Limit: one suggestion at a time, at a natural break; never interrupt work. ' \
               'Do not repeat a declined offer until the situation changes.'
  CONSENT = 'Saving, promotion, archiving, recording and mode changes happen only after the user says yes.'

  def setup
    @original_env_data_dir = ENV.delete('KAIROS_DATA_DIR')
    KairosMcp.reset_data_dir!
    @tmpdir = Dir.mktmpdir('kc_test_proactive_tutorial_')
    @data_dir = File.join(@tmpdir, 'project', '.kairos')
    KairosMcp.data_dir = @data_dir
  end

  def teardown
    ENV['KAIROS_DATA_DIR'] = @original_env_data_dir if @original_env_data_dir
    KairosMcp.reset_data_dir!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  def test_registered_as_a_shipped_l0_document
    entry = KairosMcp::TEMPLATE_FILES.find { |name, _| name == TEMPLATE }
    refute_nil entry, 'proactive_tutorial.md must be in TEMPLATE_FILES so init and upgrade copy it'
    assert_equal :l0_doc, KairosMcp::TEMPLATE_FILE_TYPES[TEMPLATE]
    assert_equal File.join(KairosMcp.skills_dir, 'proactive_tutorial.md'),
                 KairosMcp.send(entry.last)
    assert File.exist?(File.join(KairosMcp.templates_dir, TEMPLATE)), 'template file must ship'
  end

  def test_protected_from_delete_like_the_other_shipped_modes
    assert_includes KairosMcp::Tools::InstructionsUpdate::PROTECTED_FILES, 'proactive_tutorial.md'
  end

  def test_fresh_instance_receives_the_mode_file
    initialize_instance!
    assert File.exist?(File.join(@data_dir, TEMPLATE)), 'init must copy the mode into the data directory'
  end

  def test_proactive_section_survives_the_older_cap_before_projection
    out = unprojected_instructions
    assert_includes out, 'kairos-chain first-run setup notice',
                    'precondition: the unprojected path prepends the setup hint'

    head = utf16_head(out, OLD_CAP)
    assert_includes head, CONSENT, "the consent sentence must be within #{OLD_CAP} characters"
    ITEMS.each { |item| assert_includes head, item, "#{item.inspect} must be within #{OLD_CAP} characters" }
    assert_includes head, LIMIT_LINE, "the limit line must be within #{OLD_CAP} characters"
  end

  def test_proactive_section_precedes_the_rest_of_the_body
    body = File.read(File.join(KairosMcp.templates_dir, TEMPLATE))
    headings = body.scan(/^## .*$/)
    assert_equal '## Use KairosChain proactively (read this first)', headings.first,
                 'the proactive section must be the first section of the body'
    limit_at = body.index(LIMIT_LINE)
    refute_nil limit_at
    second_heading = body.index("\n## ", body.index(headings.first) + 1)
    assert limit_at < second_heading, 'the six items and the limit line must form the first section'
  end

  def test_set_mode_warns_when_claude_md_carries_another_projected_mode
    initialize_instance!
    File.write(File.join(@data_dir, 'skills', 'config.yml'), "instructions_mode: tutorial\n")
    File.write(File.join(@data_dir, 'instruction_mode_manifest.json'),
               JSON.generate('mode_name' => 'tutorial', 'region_present' => true))
    out = set_mode!('proactive_tutorial')
    assert_includes out, 'Instructions mode changed', "precondition: set_mode succeeded, got: #{out}"
    assert_includes out, 'kairos-chain mode project'
    assert_includes out, '`tutorial` body'
  end

  def test_set_mode_is_quiet_when_nothing_else_is_projected
    initialize_instance!
    File.write(File.join(@data_dir, 'skills', 'config.yml'), "instructions_mode: tutorial\n")
    out = set_mode!('proactive_tutorial')
    assert_includes out, 'Instructions mode changed', "precondition: set_mode succeeded, got: #{out}"
    refute_includes out, 'kairos-chain mode project'
  end

  def test_set_mode_is_quiet_when_the_new_mode_is_the_projected_one
    initialize_instance!
    File.write(File.join(@data_dir, 'skills', 'config.yml'), "instructions_mode: tutorial\n")
    File.write(File.join(@data_dir, 'instruction_mode_manifest.json'),
               JSON.generate('mode_name' => 'proactive_tutorial', 'region_present' => true))
    out = set_mode!('proactive_tutorial')
    assert_includes out, 'Instructions mode changed', "precondition: set_mode succeeded, got: #{out}"
    refute_includes out, 'kairos-chain mode'
  end

  def test_set_mode_none_points_at_remove_not_project
    initialize_instance!
    File.write(File.join(@data_dir, 'skills', 'config.yml'), "instructions_mode: tutorial\n")
    File.write(File.join(@data_dir, 'instruction_mode_manifest.json'),
               JSON.generate('mode_name' => 'tutorial', 'region_present' => true))
    out = set_mode!('none')
    assert_includes out, 'kairos-chain mode remove'
    refute_includes out, 'kairos-chain mode project'
  end

  private

  def set_mode!(mode)
    tool = KairosMcp::Tools::InstructionsUpdate.new
    result = tool.call('command' => 'set_mode', 'mode_name' => mode,
                       'reason' => 'test', 'approved' => true)
    result.map { |c| c[:text] || c['text'] }.join
  end

  def initialize_instance!
    init = KairosMcp::Initializer.new(quiet: true)
    init.send(:create_directories)
    init.send(:copy_templates)
  end

  def unprojected_instructions
    initialize_instance!
    File.write(File.join(@data_dir, 'skills', 'config.yml'), "instructions_mode: proactive_tutorial\n")
    out = KairosMcp::Protocol.allocate.send(:load_instructions)
    refute_nil out, 'load_instructions must resolve the proactive_tutorial mode'
    out
  end

  def utf16_head(str, units)
    str.encode('UTF-16LE').byteslice(0, units * 2).force_encoding('UTF-16LE').encode('UTF-8')
  end
end
