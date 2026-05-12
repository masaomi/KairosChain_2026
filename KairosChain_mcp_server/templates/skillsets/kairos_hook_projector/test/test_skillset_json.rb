# frozen_string_literal: true

require 'minitest/autorun'
require 'json'

class TestKairosHookProjectorSkillsetJson < Minitest::Test
  SKILLSET_ROOT = File.expand_path('..', __dir__)

  def setup
    @path = File.join(SKILLSET_ROOT, 'skillset.json')
    @json = JSON.parse(File.read(@path))
  end

  def test_skillset_json_parses
    assert_kind_of Hash, @json
  end

  def test_name_is_kairos_hook_projector
    assert_equal 'kairos_hook_projector', @json['name']
  end

  def test_layer_is_l1
    assert_equal 'L1', @json['layer']
  end

  def test_depends_on_plugin_projector
    deps = @json['depends_on']
    assert_kind_of Array, deps
    names = deps.map { |d| d['name'] }
    assert_includes names, 'plugin_projector'
  end

  def test_plugin_skill_md_exists
    skill_md = File.join(SKILLSET_ROOT, 'plugin', 'SKILL.md')
    assert File.exist?(skill_md), "plugin/SKILL.md must exist"
  end

  def test_plugin_hooks_json_is_empty_object
    hooks_json = File.join(SKILLSET_ROOT, 'plugin', 'hooks.json')
    assert File.exist?(hooks_json), "plugin/hooks.json must exist"
    parsed = JSON.parse(File.read(hooks_json))
    assert_equal({ 'hooks' => {} }, parsed,
                 'stage 0: hooks.json must be {"hooks":{}} — no projections yet')
  end
end
