# frozen_string_literal: true

# Checks what the shipped files of trust_gate claim about each other:
#   ruby -I KairosChain_mcp_server/lib <this file>
# TRUST_GATE_ROOT points the checks at a copy, so that a broken copy can be
# shown to fail without touching the shipped files.
require 'minitest/autorun'
require 'json'
require 'yaml'
require 'kairos_mcp'
require 'kairos_mcp/skillset'

class TestTrustGate < Minitest::Test
  ROOT = ENV['TRUST_GATE_ROOT'] || File.expand_path('..', __dir__)
  ENTRY_NAME = 'trust_boundary_questions'
  ENTRY = File.join(ROOT, 'knowledge', ENTRY_NAME, "#{ENTRY_NAME}.md")
  AGENT = File.join(ROOT, 'plugin', 'agents', 'gatekeeper.md')
  SKILL = File.join(ROOT, 'plugin', 'SKILL.md')
  ALLOWED = %w[Read Grep Glob mcp__kairos-chain__knowledge_get mcp__kairos-chain__safe_file_list].freeze

  def frontmatter(path)
    YAML.safe_load(File.read(path)[/\A---\s*\n(.*?)\n---\s*\n/m, 1])
  end

  def body(path)
    File.read(path).sub(/\A---\s*\n.*?\n---\s*\n/m, '')
  end

  def tool_list(value)
    Array(value).flat_map { |t| t.to_s.split(',') }.map(&:strip).reject(&:empty?)
  end

  def test_loads_as_a_skillset_that_adds_no_tools
    ss = KairosMcp::Skillset.new(ROOT)
    assert ss.valid?, 'skillset.json is not valid'
    assert_empty ss.tool_class_names
    assert ss.has_plugin?, 'plugin is not projected without the key and the directory'
    assert ss.load!
  end

  def test_the_entry_resolves_under_the_name_the_gatekeeper_asks_for
    declared = JSON.parse(File.read(File.join(ROOT, 'skillset.json')))['knowledge_dirs']
    assert_equal ["knowledge/#{ENTRY_NAME}"], declared
    assert File.file?(ENTRY), 'entry file is missing'
    assert_equal ENTRY_NAME, frontmatter(ENTRY)['name']
    assert_match(/knowledge_get` with name `#{ENTRY_NAME}`/, body(AGENT))
  end

  def test_the_gatekeeper_is_given_only_tools_that_read
    fm = frontmatter(AGENT)
    assert_equal ALLOWED.sort, tool_list(fm['tools']).sort
    %w[Write Edit Bash].each { |t| assert_includes tool_list(fm['disallowedTools']), t }
  end

  def test_the_answer_form_is_defined_in_the_entry_and_nowhere_else
    assert_match(/^## Answering$/, body(ENTRY))
    assert_includes body(ENTRY), 'path:line'
    assert_includes body(ENTRY), 'no entrance here'
    refute_includes body(AGENT), 'path:line'
    refute_includes body(AGENT), 'no entrance here'
  end

  def test_the_caller_is_told_to_hand_over_paths_not_pasted_material
    assert_includes body(SKILL), 'Do not paste the material'
  end

  def test_a_report_carries_its_own_limit_to_the_operator
    assert_includes body(ENTRY).gsub(/\s+/, ' '), 'This is what one reading found. It is not a complete inventory.'
    assert_includes body(SKILL), 'Relay its report to the operator whole.'
    refute_match(/safe to let/, File.read(SKILL))
  end

  def test_nothing_shipped_is_specific_to_one_instance
    [ENTRY, AGENT, SKILL].each do |path|
      text = File.read(path)
      refute_match(%r{/Users/|/home/}, text, "#{path} names a home directory")
      refute_includes text, '.kairos/context', "#{path} names an instance record"
    end
  end
end
