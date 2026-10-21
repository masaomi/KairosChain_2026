# frozen_string_literal: true
#
# The agent SkillSet's stand-in needs two things from llm_client:
#   - no_fallback: an authentication failure on the configured provider is a
#     failure, not a silent switch to claude_code (design v0.5 §2 LLM route);
#   - isolated: `claude -p` in safe mode with no tools, so the prompt is the
#     whole input (design v0.5 INV-3).

require 'minitest/autorun'
require 'json'

require_relative '../lib/llm_client/call_router'
require_relative '../lib/llm_client/claude_code_adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      class AuthFailingAdapter
        def initialize(config)
          @config = config
        end

        def call(**)
          raise AuthError.new('no credentials', provider: @config['provider'])
        end
      end

      class TestNoFallback < Minitest::Test
        def setup
          @built = []
          built = @built
          CallRouter.singleton_class.send(:alias_method, :_nf_real_build_adapter, :build_adapter)
          CallRouter.singleton_class.send(:define_method, :build_adapter) do |config|
            built << config['provider']
            AuthFailingAdapter.new(config)
          end
        end

        def teardown
          CallRouter.singleton_class.send(:remove_method, :build_adapter)
          CallRouter.singleton_class.send(:alias_method, :build_adapter, :_nf_real_build_adapter)
          CallRouter.singleton_class.send(:remove_method, :_nf_real_build_adapter)
        end

        def test_no_fallback_returns_the_failure_of_the_configured_provider
          result = CallRouter.perform({ 'messages' => [], 'no_fallback' => true }, { 'provider' => 'bedrock' })
          assert_equal 'error', result['status']
          assert_equal %w[bedrock], @built, 'no second adapter may be built'
        end

        def test_isolated_flag_reaches_the_adapter_config
          captured = nil
          CallRouter.singleton_class.send(:define_method, :build_adapter) do |config|
            captured = config
            AuthFailingAdapter.new(config)
          end
          CallRouter.perform({ 'messages' => [], 'isolated' => true, 'no_fallback' => true },
                             { 'provider' => 'claude_code' })
          assert_equal true, captured['isolated']
        end
      end

      class TestClaudeCodeIsolation < Minitest::Test
        Status = Struct.new(:success?, :exitstatus)

        def capture_args(config)
          seen = {}
          SafeSubprocess.singleton_class.send(:alias_method, :_iso_real_capture, :safe_capture)
          SafeSubprocess.singleton_class.send(:define_method, :safe_capture) do |args, **kw|
            seen[:args] = args
            seen[:chdir] = kw[:chdir]
            body = { 'type' => 'result', 'result' => '{"ok":true}', 'is_error' => false,
                     'modelUsage' => { 'claude-opus-5-5' => {} } }
            [JSON.generate(body), '', Status.new(true, 0)]
          end
          seen[:response] = ClaudeCodeAdapter.new(config).call(messages: [{ 'role' => 'user', 'content' => 'q' }])
          seen
        ensure
          SafeSubprocess.singleton_class.send(:remove_method, :safe_capture)
          SafeSubprocess.singleton_class.send(:alias_method, :safe_capture, :_iso_real_capture)
          SafeSubprocess.singleton_class.send(:remove_method, :_iso_real_capture)
        end

        def test_isolated_runs_safe_mode_with_no_tools_in_the_sandbox_directory
          seen = capture_args('isolated' => true, 'model' => 'claude-opus-5-5')
          args = seen[:args]
          assert_includes args, '--safe-mode'
          i = args.index('--tools')
          refute_nil i
          assert_equal '', args[i + 1]
          refute_includes args, '--disallowedTools'
          assert_equal ClaudeCodeAdapter::SANDBOX_CWD, seen[:chdir]
          assert_includes args, '--no-session-persistence'
        end

        # 0.3.0: the reply says how the call was spawned, so the caller can
        # refuse one that did not run isolated.
        def test_an_isolated_reply_carries_how_it_was_spawned
          seen = capture_args('isolated' => true)
          assert_equal({ 'safe_mode' => true, 'tools' => '', 'cwd' => ClaudeCodeAdapter::SANDBOX_CWD },
                       seen[:response]['isolation'])
        end

        def test_sandbox_mode_without_isolation_is_unchanged
          seen = capture_args('sandbox_mode' => true)
          assert_includes seen[:args], '--disallowedTools'
          refute_includes seen[:args], '--safe-mode'
          refute seen[:response].key?('isolation')
        end
      end
    end
  end
end
