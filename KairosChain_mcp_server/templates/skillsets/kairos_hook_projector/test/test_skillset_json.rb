# frozen_string_literal: true

require 'minitest/autorun'
require 'json'

class TestKairosHookProjectorSkillsetJson < Minitest::Test
  SKILLSET_ROOT = File.expand_path('..', __dir__)

  def setup
    @path = File.join(SKILLSET_ROOT, 'skillset.json')
    @json = JSON.parse(File.read(@path, encoding: 'UTF-8'))
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

  # plugin/hooks.json is gone. It was the round 2 write target and round 2
  # review found it was never read: this SkillSet's skillset.json declares no
  # `plugin` key, so PluginProjector's `has_plugin?` is false and it skipped the
  # SkillSet entirely. Nothing wrote it, nothing read it, and `system_upgrade`
  # restored it from the template — so an applied configuration placed there was
  # silently discarded on the next upgrade.
  def test_no_hooks_json_is_shipped
    refute File.exist?(File.join(SKILLSET_ROOT, 'plugin', 'hooks.json')),
           'the activation target is .claude/settings.json; nothing is projected via plugin/'
  end
end
