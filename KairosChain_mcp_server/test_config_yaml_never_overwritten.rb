# frozen_string_literal: true

# Regression tests for: a YAML config file is never copied over during
# `upgrade --apply`, not even on the :auto_updatable path.
#
# The three-way comparison classifies each L0 template and the apply step used
# to route :auto_updatable to a wholesale `FileUtils.cp`. That routing makes the
# survival of every user value in skills/config.yml depend on the classification
# being right, and the classification rests on `template_hashes` in
# .kairos_meta.yml being a correct common ancestor — a ledger this same tool
# writes, and has already got wrong five times between 2026-06-09 and 2026-08-03
# (test_upgrade_meta_baseline.rb covers that defect). Each time, the observable
# result was skills/config.yml reverting instructions_mode from a user-selected
# mode to the template default, with no chain record.
#
# 3.58.2 corrected the ledger. These tests pin the complementary property: even
# when the ledger is wrong and the file is misclassified as unmodified, the
# user's values survive — because config_yaml now takes the structural merge on
# both paths. The merge needs no assertion about who edited what: it adds the
# template's new keys and keeps the instance's values, which is what the copy
# was for, plus what the copy destroyed.
#
# The third test pins the scope: L0 documents and the DSL are not key-structured
# and must still be copied.

require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'digest'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/initializer'
require 'kairos_mcp/upgrade_analyzer'
require 'kairos_mcp/config_merger'
require 'kairos_mcp/tools/system_upgrade'

class ConfigYamlNeverOverwrittenTest < Minitest::Test
  CONFIG = 'skills/config.yml'
  DOC = 'skills/kairos.md'
  KNOWLEDGE = 'demo_knowledge'

  def setup
    @original_env_data_dir = ENV.delete('KAIROS_DATA_DIR')
    KairosMcp.reset_data_dir!
    @tmpdir = Dir.mktmpdir('kc_test_config_merge_')
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

  # --- the property being pinned ------------------------------------------

  # The five observed reverts in one test: the baseline says the instance file is
  # the template it descends from (the ledger defect), the template has moved on,
  # so the file is classified :auto_updatable while actually carrying a user
  # value. Copying loses instructions_mode; merging keeps it AND takes the new
  # template key.
  def test_user_value_survives_a_wrong_auto_updatable_classification
    with_templates do
      init!
      set_mode('masa')
      poison_baseline!(CONFIG)
      set_meta_version('0.0.1')
      bump_template(CONFIG, 'tutorial', extra: "new_key: 1\n")

      assert_equal :auto_updatable, pattern(CONFIG),
                   'precondition: this test is about the misclassified case'

      output = apply!

      config = YAML.safe_load(File.read(user_path(CONFIG)))
      assert_equal 'masa', config['instructions_mode'],
                   'a user-selected mode must not be replaced by the template default'
      assert_equal 1, config['new_key'],
                   'the new template key must still arrive'
      assert_includes output, "[MERGED] #{CONFIG}",
                     'config_yaml must be reported as merged, not auto-updated'
    end
  end

  # The purpose of :auto_updatable — new template keys reach an instance that has
  # not been edited — must keep working through the merge.
  def test_new_template_keys_still_arrive_when_the_file_was_not_modified
    with_templates do
      init!
      set_meta_version('0.0.1')
      bump_template(CONFIG, 'tutorial', extra: "new_key: 1\n")

      assert_equal :auto_updatable, pattern(CONFIG)

      apply!

      config = YAML.safe_load(File.read(user_path(CONFIG)))
      assert_equal 1, config['new_key'], 'template additions must propagate'
      assert_equal 'tutorial', config['instructions_mode']
    end
  end

  # Scope: only config_yaml changes routing. A document has no keys to merge and
  # must still be replaced wholesale.
  def test_l0_documents_are_still_copied
    with_templates do
      init!
      set_meta_version('0.0.1')
      File.write(File.join(@templates_dir, DOC), "# rewritten by the gem\n")

      assert_equal :auto_updatable, pattern(DOC)

      output = apply!

      assert_equal "# rewritten by the gem\n", File.read(user_path(DOC))
      assert_includes output, "[AUTO-UPDATED] #{DOC}"
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

  # The whole apply path, exactly as the MCP tool and the CLI reach it.
  def apply!
    contents = KairosMcp::Tools::SystemUpgrade.new.call(
      'command' => 'apply', 'approved' => true
    )
    contents.map { |c| c[:text] }.compact.join
  end

  def analyzer
    a = KairosMcp::UpgradeAnalyzer.new
    a.analyze
    a
  end

  def pattern(template_name)
    analyzer.results[template_name][:pattern]
  end

  # --- meta manipulation --------------------------------------------------

  # Record the instance's own file as the baseline — the shape the pre-3.58.2
  # update_meta produced, and the shape any future ledger defect reproduces.
  def poison_baseline!(template_name)
    write_meta { |m| m['template_hashes'][template_name] = user_hash(template_name) }
  end

  def set_meta_version(version)
    write_meta { |m| m['kairos_mcp_version'] = version }
  end

  def write_meta
    meta = YAML.safe_load(File.read(KairosMcp.meta_path))
    yield meta
    File.write(KairosMcp.meta_path, YAML.dump(meta))
  end

  # --- paths and hashes ---------------------------------------------------

  def user_path(template_name)
    accessor = KairosMcp::TEMPLATE_FILES.find { |n, _| n == template_name }.last
    KairosMcp.send(accessor)
  end

  def set_mode(mode)
    File.write(user_path(CONFIG), "instructions_mode: #{mode}\n")
  end

  def user_hash(template_name)
    "sha256:#{Digest::SHA256.file(user_path(template_name)).hexdigest}"
  end
end
