# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'digest'

require_relative '../lib/multi_llm_review/pin_resolver'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestPinResolver < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr_pr5')
          @skillset = 'multi_llm_review'
          @env_var = PinResolver.env_var_name(@skillset)
          @prev_env = ENV[@env_var]
          ENV.delete(@env_var)
        end

        def teardown
          ENV[@env_var] = @prev_env
          FileUtils.rm_rf(@tmp)
        end

        def test_default_path_when_no_pin
          result = PinResolver.resolve(@skillset, project_root: @tmp)
          assert_equal :default, result[:source]
          assert_nil result[:version]
          assert result[:path].end_with?('.kairos/skillsets/multi_llm_review')
        end

        def test_env_pin_takes_precedence
          ENV[@env_var] = '0.2.3'
          result = PinResolver.resolve(@skillset, project_root: @tmp)
          assert_equal :env, result[:source]
          assert_equal '0.2.3', result[:version]
          assert result[:path].end_with?('skillsets_archive/multi_llm_review-0.2.3')
          assert_equal 'env', result[:provenance][:set_by]
        end

        def test_manifest_pin_used_when_no_env
          manifest = File.join(@tmp, '.kairos/skillsets_pin.yml')
          FileUtils.mkdir_p(File.dirname(manifest))
          File.write(manifest, <<~YAML)
            pins:
              multi_llm_review: "0.2.3"
          YAML
          result = PinResolver.resolve(@skillset, project_root: @tmp)
          assert_equal :manifest, result[:source]
          assert_equal '0.2.3', result[:version]
        end

        def test_manifest_pin_with_provenance_schema
          manifest = File.join(@tmp, '.kairos/skillsets_pin.yml')
          FileUtils.mkdir_p(File.dirname(manifest))
          File.write(manifest, <<~YAML)
            pins:
              multi_llm_review:
                version: "0.2.3"
                set_by: masa
                set_at: "2026-04-24"
                reason: "self-review of v0.3.0"
          YAML
          result = PinResolver.resolve(@skillset, project_root: @tmp)
          assert_equal :manifest, result[:source]
          assert_equal '0.2.3', result[:version]
          assert_equal 'masa', result[:provenance]['set_by']
          assert_equal 'self-review of v0.3.0', result[:provenance]['reason']
        end

        def test_env_overrides_manifest
          manifest = File.join(@tmp, '.kairos/skillsets_pin.yml')
          FileUtils.mkdir_p(File.dirname(manifest))
          File.write(manifest, "pins:\n  multi_llm_review: \"0.2.2\"\n")
          ENV[@env_var] = '0.2.3'
          result = PinResolver.resolve(@skillset, project_root: @tmp)
          assert_equal :env, result[:source]
          assert_equal '0.2.3', result[:version]
        end

        def test_unknown_skillset_falls_back_to_default
          manifest = File.join(@tmp, '.kairos/skillsets_pin.yml')
          FileUtils.mkdir_p(File.dirname(manifest))
          File.write(manifest, "pins:\n  other_skillset: \"1.0.0\"\n")
          result = PinResolver.resolve('not_pinned', project_root: @tmp)
          assert_equal :default, result[:source]
        end

        def test_malformed_manifest_falls_back_silently
          manifest = File.join(@tmp, '.kairos/skillsets_pin.yml')
          FileUtils.mkdir_p(File.dirname(manifest))
          File.write(manifest, 'not: valid: yaml: here')
          result = PinResolver.resolve(@skillset, project_root: @tmp)
          assert_equal :default, result[:source]
        end

        # Archive hash: tamper detection
        def test_archive_hash_is_deterministic
          dir = File.join(@tmp, 'archive1')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'a.rb'), 'puts 1')
          File.write(File.join(dir, 'b.rb'), 'puts 2')
          h1 = PinResolver.archive_hash(dir)
          h2 = PinResolver.archive_hash(dir)
          assert_equal h1, h2
          assert_equal 64, h1.length
        end

        def test_archive_hash_detects_content_tampering
          dir = File.join(@tmp, 'archive2')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'a.rb'), 'original')
          h1 = PinResolver.archive_hash(dir)
          File.write(File.join(dir, 'a.rb'), 'tampered')
          h2 = PinResolver.archive_hash(dir)
          refute_equal h1, h2
        end

        def test_archive_hash_detects_added_file
          dir = File.join(@tmp, 'archive3')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'a.rb'), 'x')
          h1 = PinResolver.archive_hash(dir)
          File.write(File.join(dir, 'b.rb'), 'y')
          h2 = PinResolver.archive_hash(dir)
          refute_equal h1, h2
        end

        def test_archive_hash_nil_for_missing_dir
          assert_nil PinResolver.archive_hash(File.join(@tmp, 'does_not_exist'))
        end

        def test_env_var_name_normalization
          assert_equal 'KAIROS_SKILLSET_PIN_MULTI_LLM_REVIEW',
                       PinResolver.env_var_name('multi_llm_review')
          assert_equal 'KAIROS_SKILLSET_PIN_LLM_CLIENT',
                       PinResolver.env_var_name('llm_client')
        end

        def test_env_var_name_rejects_invalid_names
          # Prevents foo-bar / foo_bar collision and other normalization hazards.
          assert_raises(ArgumentError) { PinResolver.env_var_name('foo-bar') }
          assert_raises(ArgumentError) { PinResolver.env_var_name('Foo') }
          assert_raises(ArgumentError) { PinResolver.env_var_name('') }
        end

        def test_archive_hash_rejects_escaping_symlink
          dir = File.join(@tmp, 'archive_escape')
          outside = File.join(@tmp, 'outside_target')
          FileUtils.mkdir_p(dir)
          File.write(outside, 'sensitive')
          File.symlink(outside, File.join(dir, 'leak'))
          assert_raises(ArgumentError) { PinResolver.archive_hash(dir) }
        end

        def test_archive_hash_detects_mode_change
          dir = File.join(@tmp, 'archive_mode')
          FileUtils.mkdir_p(dir)
          path = File.join(dir, 'a.rb')
          File.write(path, 'x')
          File.chmod(0o644, path)
          h1 = PinResolver.archive_hash(dir)
          File.chmod(0o755, path)
          h2 = PinResolver.archive_hash(dir)
          refute_equal h1, h2, 'mode change must affect archive_hash'
        end
      end
    end
  end
end
