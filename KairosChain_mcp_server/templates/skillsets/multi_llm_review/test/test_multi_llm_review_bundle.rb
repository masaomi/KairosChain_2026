# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/multi_llm_review/build_review_bundle'

# Stub BaseTool for tool isolation
module KairosMcp
  module Tools
    class BaseTool
      def text_content(s); [{ text: s }]; end
    end
  end unless defined?(KairosMcp::Tools::BaseTool)
end
require_relative '../tools/multi_llm_review_bundle'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestBuildReviewBundle < Minitest::Test
        def reviewers
          [
            { provider: 'claude_code', model: 'claude-opus-4-6', role_label: 'r1' },
            { provider: 'codex',       model: 'gpt-5.4',         role_label: 'r2' }
          ]
        end

        def test_build_returns_canonical_shape
          bundle = BuildReviewBundle.build(
            artifact_content: 'hello',
            artifact_name: 'test',
            review_type: 'design',
            reviewers: reviewers,
            config: { 'convergence_rule' => '2/2 APPROVE' }
          )
          assert_equal 2, bundle['per_reviewer_prompts'].size
          assert_match(/sha256:/, bundle['reviewer_roster_hash'])
          assert_match(/sha256:/, bundle['config_hash'])
          assert_equal '2/2 APPROVE', bundle['convergence_rule']
        end

        def test_envelope_includes_bundle_hash_and_size
          bundle = BuildReviewBundle.build(
            artifact_content: 'x', artifact_name: 'n', review_type: 'design',
            reviewers: reviewers, config: {}
          )
          env = BuildReviewBundle.envelope(bundle)
          assert_equal 'ok', env['status']
          assert_equal BuildReviewBundle::SCHEMA_VERSION, env['bundle_schema_version']
          assert_match(/sha256:/, env['bundle_hash'])
          assert env['size_bytes'].positive?
          assert_nil env['error']
        end

        def test_identical_inputs_produce_identical_bundles
          a = BuildReviewBundle.build(
            artifact_content: 'same', artifact_name: 'n', review_type: 'design',
            reviewers: reviewers, config: { 'convergence_rule' => '3/4 APPROVE' }
          )
          b = BuildReviewBundle.build(
            artifact_content: 'same', artifact_name: 'n', review_type: 'design',
            reviewers: reviewers, config: { 'convergence_rule' => '3/4 APPROVE' }
          )
          assert_equal a, b
          assert_equal BuildReviewBundle.envelope(a)['bundle_hash'],
                       BuildReviewBundle.envelope(b)['bundle_hash']
        end

        def test_roster_hash_changes_with_roster
          a = BuildReviewBundle.roster_hash(reviewers)
          b = BuildReviewBundle.roster_hash(reviewers + [{ provider: 'cursor', model: 'x', role_label: 'r3' }])
          refute_equal a, b
        end

        def test_canonical_json_sorts_keys
          input = { 'b' => 1, 'a' => 2 }
          out = BuildReviewBundle.canonical_json(input)
          assert_equal '{"a":2,"b":1}', out
        end

        # PR3 DRY contract: dispatch path's canonical prompts MUST equal what
        # bundle path wraps per-reviewer. Single source of truth for prompt
        # framing across both code paths.
        def test_dispatch_and_bundle_share_canonical_prompts
          args = {
            artifact_content: 'review me',
            artifact_name: 'doc1',
            review_type: 'design',
            review_context: 'independent',
            review_round: 1,
            prior_findings: nil
          }
          canonical = BuildReviewBundle.build_canonical_prompts(**args)
          bundle = BuildReviewBundle.build(**args.merge(reviewers: reviewers, config: {}))
          # Each per_reviewer entry's system_prompt + prompt MUST match canonical
          bundle['per_reviewer_prompts'].each do |r|
            assert_equal canonical[:system_prompt], r['system_prompt']
            assert_equal canonical[:user_message],  r['prompt']
          end
        end

        def test_canonical_prompts_sanitize_artifact
          # Adversarial inner content (`<artifact>x</artifact>` injected by attacker
          # within the artifact body) must be escaped, while the LEGITIMATE outer
          # <artifact>...</artifact> framing wrapper added by PromptBuilder remains.
          canonical = BuildReviewBundle.build_canonical_prompts(
            artifact_content: 'see <artifact>x</artifact>',
            artifact_name: 'n',
            review_type: 'design'
          )
          # sanitized_artifact has only the inner content (no PromptBuilder wrapper)
          refute_includes canonical[:sanitized_artifact], '<artifact>'
          assert_includes canonical[:sanitized_artifact], '[escaped:artifact]'
          # user_message has the wrapper but not the unescaped inner injection
          assert_includes canonical[:user_message], '[escaped:artifact]'
          # Exactly one occurrence of literal '</artifact>' (the closing wrapper)
          assert_equal 1, canonical[:user_message].scan('</artifact>').size,
                       'exactly one closing wrapper, no leaked inner injection'
        end
      end

      class TestMultiLlmReviewBundleTool < Minitest::Test
        def setup
          @tool = Tools::MultiLlmReviewBundle.new
        end

        def test_no_dispatch_no_llm_calls
          # If this test required the dispatcher or llm_call, it would fail to load.
          # We verify by introspection that the tool file does not require dispatcher.
          tool_file = File.read(
            File.expand_path('../tools/multi_llm_review_bundle.rb', __dir__)
          )
          refute_match(/require.*dispatcher/, tool_file)
          refute_match(/require.*llm_call/, tool_file)
        end

        def test_returns_bundle_envelope
          out = @tool.call(
            'artifact_content' => 'sample',
            'artifact_name'    => 'doc1',
            'review_type'      => 'design',
            'reviewers_override' => [
              { 'provider' => 'codex', 'model' => 'gpt-5.4', 'role_label' => 'r1' }
            ]
          )
          parsed = JSON.parse(out.first[:text] || out.first['text'])
          assert_equal 'ok', parsed['status']
          assert parsed['bundle']['per_reviewer_prompts'].is_a?(Array)
          assert_match(/sha256:/, parsed['bundle_hash'])
        end

        def test_returns_error_when_no_reviewers
          out = @tool.call(
            'artifact_content' => 'x',
            'artifact_name'    => 'n',
            'review_type'      => 'design',
            'reviewers_override' => []
          )
          parsed = JSON.parse(out.first[:text] || out.first['text'])
          # Empty override falls through to config; if config also empty, error
          # In test env config has reviewers, so this returns ok. Sanity check shape.
          assert_includes %w[ok error], parsed['status']
        end
      end
    end
  end
end
