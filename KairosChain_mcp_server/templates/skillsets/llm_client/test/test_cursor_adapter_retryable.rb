# frozen_string_literal: true
# v0.3.1 meta-review bonus: cursor transient "Provider Error" → retryable.

require 'minitest/autorun'
require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/cursor_adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      class TestCursorAdapterRetryable < Minitest::Test
        # Mock Process::Status-like object
        Status = Struct.new(:success?, :exitstatus)

        def setup
          @adapter = CursorAdapter.new({ 'timeout_seconds' => 30 })
        end

        def stub_capture(stdout:, stderr:, status_ok: false, exitcode: 1)
          SafeSubprocess.singleton_class.send(:alias_method, :_orig_safe_capture, :safe_capture)
          SafeSubprocess.singleton_class.send(:define_method, :safe_capture) do |*_args, **_kw|
            [stdout, stderr, Status.new(status_ok, exitcode)]
          end
        end

        def restore_capture
          SafeSubprocess.singleton_class.send(:remove_method, :safe_capture)
          SafeSubprocess.singleton_class.send(:alias_method, :safe_capture, :_orig_safe_capture)
          SafeSubprocess.singleton_class.send(:remove_method, :_orig_safe_capture)
        end

        def test_transient_provider_error_is_retryable
          stub_capture(
            stdout: '',
            stderr: "I: Provider Error We're having trouble connecting to the model provider. This might be temporary - please try again in a moment.\n"
          )
          begin
            err = assert_raises(ApiError) do
              @adapter.call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
            end
            assert_equal true, err.retryable, 'transient provider error must be retryable'
          ensure
            restore_capture
          end
        end

        def test_transient_trouble_connecting_is_retryable
          stub_capture(stdout: '', stderr: 'trouble connecting to upstream')
          begin
            err = assert_raises(ApiError) { @adapter.call(messages: []) }
            assert_equal true, err.retryable
          ensure
            restore_capture
          end
        end

        def test_non_transient_error_stays_not_retryable
          stub_capture(stdout: '', stderr: 'invalid argument: --foo')
          begin
            err = assert_raises(ApiError) { @adapter.call(messages: []) }
            assert_equal false, err.retryable,
              'non-transient errors stay retryable: false'
          ensure
            restore_capture
          end
        end
      end
    end
  end
end
