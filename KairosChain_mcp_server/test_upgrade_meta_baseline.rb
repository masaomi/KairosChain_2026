# frozen_string_literal: true

# Regression tests for the .kairos_meta.yml baseline defect.
#
# `template_hashes` in .kairos_meta.yml is the common ancestor of the three-way
# comparison in UpgradeAnalyzer: for each L0 template it must record the *gem
# template* the user's file descends from. Initializer#write_meta does exactly
# that. SystemUpgrade#update_meta rebuilt it from the *user's own file*, which
# collapses the ancestor onto one side: on the following upgrade `user_modified`
# is necessarily false, so a user-modified file is classified :auto_updatable
# and silently overwritten.
#
# Observed symptom (five occurrences, 2026-06-09 .. 2026-08-03): skills/config.yml
# reverting instructions_mode from masa to tutorial with no chain record. The
# triggering condition is "the previous upgrade emitted KEPT" — a protected run
# is what arms the next one, which is why the tests below run several cycles.
#
# `knowledge_hashes` (L1) carries the identical defect and is covered here too.

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'digest'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/initializer'
require 'kairos_mcp/upgrade_analyzer'
require 'kairos_mcp/tools/system_upgrade'

class UpgradeMetaBaselineTest < Minitest::Test
  CONFIG = 'skills/config.yml'
  KNOWLEDGE = 'demo_knowledge'

  def setup
    @original_env_data_dir = ENV.delete('KAIROS_DATA_DIR')
    KairosMcp.reset_data_dir!
    @tmpdir = Dir.mktmpdir('kc_test_upgrade_meta_')
    @templates_dir = File.join(@tmpdir, 'templates')
    @data_dir = File.join(@tmpdir, 'data')
    build_templates
    KairosMcp.data_dir = @data_dir
  end

  def teardown
    ENV['KAIROS_DATA_DIR'] = @original_env_data_dir if @original_env_data_dir
    KairosMcp.reset_data_dir!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  # --- the defect itself -------------------------------------------------

  def test_update_meta_records_the_gem_template_not_the_user_file
    with_templates do
      init!
      set_mode('masa')

      update_meta!('9.9.9')

      assert_equal template_hash(CONFIG), meta['template_hashes'][CONFIG],
                   'baseline must be the gem template the user file descends from'
      refute_equal user_hash(CONFIG), meta['template_hashes'][CONFIG],
                   'baseline must not be rebuilt from the user file'
    end
  end

  def test_user_modification_survives_repeated_upgrades
    with_templates do
      init!
      set_mode('masa')

      # Each cycle mirrors handle_apply: analyze first, then update_meta.
      # The gem template is untouched across cycles, so every cycle must
      # classify the file as user_modified. Before the fix, cycle 1 passed
      # and cycle 2 reported :auto_updatable — the observed alternation.
      3.times do |i|
        assert_equal :user_modified, pattern(CONFIG),
                     "cycle #{i + 1}: user-modified config must be kept"
        update_meta!("9.9.#{i}")
      end

      assert_equal 'masa', YAML.safe_load(File.read(user_path(CONFIG)))['instructions_mode']
    end
  end

  def test_knowledge_user_modification_survives_repeated_upgrades
    with_templates do
      init!
      File.write(user_knowledge_path, "# demo\n\nedited by the user\n")

      3.times do |i|
        assert_equal :user_modified, knowledge_status(KNOWLEDGE),
                     "cycle #{i + 1}: user-modified knowledge must be kept"
        update_meta!("9.9.#{i}")
      end
    end
  end

  # --- the classifications that must keep working ------------------------

  def test_genuine_template_change_still_auto_updates
    with_templates do
      init!
      update_meta!('9.9.0')          # user has not touched config.yml
      bump_template(CONFIG, 'tutorial', extra: "new_key: 1\n")

      assert_equal :auto_updatable, pattern(CONFIG)
    end
  end

  def test_both_sides_changed_is_a_conflict
    with_templates do
      init!
      set_mode('masa')
      update_meta!('9.9.0')          # arms the defect: baseline was rebuilt here
      bump_template(CONFIG, 'tutorial', extra: "new_key: 1\n")

      assert_equal :conflict, pattern(CONFIG),
                   'user edit + template change must reach the structural merge, not auto-update'
    end
  end

  def test_untouched_file_is_unchanged
    with_templates do
      init!
      update_meta!('9.9.0')

      assert_equal :unchanged, pattern(CONFIG)
    end
  end

  private

  # --- fake gem templates -------------------------------------------------

  def build_templates
    KairosMcp::TEMPLATE_FILES.each do |template_name, _accessor|
      path = File.join(@templates_dir, template_name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, default_template_body(template_name))
    end

    knowledge = File.join(@templates_dir, 'knowledge', KNOWLEDGE)
    FileUtils.mkdir_p(knowledge)
    File.write(File.join(knowledge, "#{KNOWLEDGE}.md"), "# demo\n\nshipped by the gem\n")
  end

  def default_template_body(template_name)
    return "instructions_mode: tutorial\n" if template_name == CONFIG

    "# template #{template_name}\n"
  end

  def bump_template(template_name, mode, extra: '')
    File.write(File.join(@templates_dir, template_name),
               "instructions_mode: #{mode}\n#{extra}")
  end

  def with_templates(&block)
    KairosMcp.stub(:templates_dir, @templates_dir, &block)
  end

  # --- drive the real code ------------------------------------------------

  def init!
    initializer = KairosMcp::Initializer.new(quiet: true)
    initializer.send(:create_directories)
    initializer.send(:copy_templates)
    initializer.send(:copy_knowledge_templates)
    initializer.send(:write_meta)
  end

  def update_meta!(version)
    KairosMcp::Tools::SystemUpgrade.new.send(:update_meta, version)
  end

  def analyzer
    a = KairosMcp::UpgradeAnalyzer.new
    a.analyze
    a
  end

  def pattern(template_name)
    analyzer.results[template_name][:pattern]
  end

  def knowledge_status(name)
    analyzer.knowledge_results[name][:status]
  end

  # --- paths and hashes ---------------------------------------------------

  def meta
    YAML.safe_load(File.read(KairosMcp.meta_path))
  end

  def user_path(template_name)
    accessor = KairosMcp::TEMPLATE_FILES.find { |n, _| n == template_name }.last
    KairosMcp.send(accessor)
  end

  def user_knowledge_path
    File.join(KairosMcp.knowledge_dir, KNOWLEDGE, "#{KNOWLEDGE}.md")
  end

  def set_mode(mode)
    File.write(user_path(CONFIG), "instructions_mode: #{mode}\n")
  end

  def template_hash(template_name)
    "sha256:#{Digest::SHA256.file(File.join(@templates_dir, template_name)).hexdigest}"
  end

  def user_hash(template_name)
    "sha256:#{Digest::SHA256.file(user_path(template_name)).hexdigest}"
  end
end
