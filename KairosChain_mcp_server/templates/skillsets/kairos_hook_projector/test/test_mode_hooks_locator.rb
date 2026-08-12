# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/mode_hooks_locator'

class TestModeHooksLocator < Minitest::Test
  L = KairosMcp::SkillSets::KairosHookProjector::ModeHooksLocator

  def with_dirs
    Dir.mktmpdir do |root|
      skills = File.join(root, 'skills')
      skillset = File.join(root, 'skillset')
      FileUtils.mkdir_p(skills)
      FileUtils.mkdir_p(File.join(skillset, 'mode_hooks'))
      body = File.join(skills, 'masa.md')
      File.write(body, "**Version:** 0.4.6\n")
      yield skills, skillset, body
    end
  end

  def test_finds_declaration_beside_the_mode_body
    with_dirs do |skills, skillset, body|
      path = File.join(skills, 'masa.mode_hooks.json')
      File.write(path, '{}')
      assert_equal path, L.find('masa', skillset_root: skillset, mode_body_path: body)
    end
  end

  def test_falls_back_to_the_skillset_directory
    with_dirs do |_skills, skillset, body|
      path = File.join(skillset, 'mode_hooks', 'masa.json')
      File.write(path, '{}')
      assert_equal path, L.find('masa', skillset_root: skillset, mode_body_path: body)
    end
  end

  # The declaration carries the mode's numbers. When both exist, the one the
  # author edits next to the body wins over anything a SkillSet ships.
  def test_beside_the_body_wins_over_the_skillset_copy
    with_dirs do |skills, skillset, body|
      beside = File.join(skills, 'masa.mode_hooks.json')
      File.write(beside, '{"mode_name":"beside"}')
      File.write(File.join(skillset, 'mode_hooks', 'masa.json'), '{"mode_name":"inside"}')
      assert_equal beside, L.find('masa', skillset_root: skillset, mode_body_path: body)
      assert_equal 'beside', L.load(L.find('masa', skillset_root: skillset, mode_body_path: body))['mode_name']
    end
  end

  def test_absent_declaration_is_nil_not_an_error
    with_dirs do |_skills, skillset, body|
      assert_nil L.find('masa', skillset_root: skillset, mode_body_path: body)
    end
  end

  def test_underscore_names_never_resolve
    with_dirs do |_skills, skillset, body|
      File.write(File.join(skillset, 'mode_hooks', '_EXAMPLE.json'), '{}')
      assert_nil L.find('_EXAMPLE', skillset_root: skillset, mode_body_path: body)
      assert_nil L.find('_schema', skillset_root: skillset, mode_body_path: body)
    end
  end

  def test_works_without_a_known_body_path
    with_dirs do |_skills, skillset, _body|
      path = File.join(skillset, 'mode_hooks', 'tutorial.json')
      File.write(path, '{}')
      assert_equal path, L.find('tutorial', skillset_root: skillset)
    end
  end

  def test_yaml_declarations_load
    with_dirs do |skills, skillset, body|
      File.write(File.join(skills, 'masa.mode_hooks.yml'), "mode_name: masa\nversion: '1'\n")
      doc = L.load(L.find('masa', skillset_root: skillset, mode_body_path: body))
      assert_equal 'masa', doc['mode_name']
    end
  end
end
