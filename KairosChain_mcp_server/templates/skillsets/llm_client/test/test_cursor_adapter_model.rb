# frozen_string_literal: true
# Phase 12 PR3-β: cursor_adapter --model passthrough (multi-model roster).
# Backward compat: nil/empty model → no --model flag (cursor default = composer2).

require 'minitest/autorun'
require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/cursor_adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      class TestCursorAdapterModel < Minitest::Test
        Status = Struct.new(:success?, :exitstatus)

        def setup
          @adapter = CursorAdapter.new({ 'timeout_seconds' => 30 })
          @captured_args = nil
        end

        # Stub safe_capture to record the args[] handed to the subprocess
        # and return a successful canned response.
        def stub_capture_recording_args
          @captured_args = nil
          tc = self
          SafeSubprocess.singleton_class.send(:alias_method, :_orig_safe_capture, :safe_capture)
          SafeSubprocess.singleton_class.send(:define_method, :safe_capture) do |args, **_kw|
            tc.instance_variable_set(:@captured_args, args)
            ['{"content":"ok"}', '', Status.new(true, 0)]
          end
        end

        def restore_capture
          SafeSubprocess.singleton_class.send(:remove_method, :safe_capture)
          SafeSubprocess.singleton_class.send(:alias_method, :safe_capture, :_orig_safe_capture)
          SafeSubprocess.singleton_class.send(:remove_method, :_orig_safe_capture)
        end

        def test_nil_model_omits_flag_backward_compat
          stub_capture_recording_args
          begin
            @adapter.call(messages: [{ 'role' => 'user', 'content' => 'hi' }], model: nil)
            assert_equal ['agent', '-p'], @captured_args
            refute_includes @captured_args, '--model'
          ensure
            restore_capture
          end
        end

        def test_no_model_kwarg_omits_flag
          stub_capture_recording_args
          begin
            @adapter.call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
            assert_equal ['agent', '-p'], @captured_args
          ensure
            restore_capture
          end
        end

        def test_empty_string_model_omits_flag
          stub_capture_recording_args
          begin
            @adapter.call(messages: [{ 'role' => 'user', 'content' => 'hi' }], model: '')
            assert_equal ['agent', '-p'], @captured_args
          ensure
            restore_capture
          end
        end

        def test_whitespace_only_model_omits_flag
          stub_capture_recording_args
          begin
            @adapter.call(messages: [{ 'role' => 'user', 'content' => 'hi' }], model: '   ')
            refute_includes @captured_args, '--model'
          ensure
            restore_capture
          end
        end

        def test_explicit_model_passed_as_flag
          stub_capture_recording_args
          begin
            @adapter.call(messages: [{ 'role' => 'user', 'content' => 'hi' }], model: 'gpt-5.4-high')
            assert_equal ['agent', '-p', '--model', 'gpt-5.4-high'], @captured_args
          ensure
            restore_capture
          end
        end

        def test_response_attribution_uses_explicit_model
          stub_capture_recording_args
          begin
            resp = @adapter.call(messages: [{ 'role' => 'user', 'content' => 'hi' }], model: 'claude-sonnet-4-6')
            assert_equal 'claude-sonnet-4-6', resp[:model] || resp['model']
          ensure
            restore_capture
          end
        end

        def test_response_attribution_falls_back_to_default_when_nil
          stub_capture_recording_args
          begin
            resp = @adapter.call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
            assert_equal 'cursor-cli-default', resp[:model] || resp['model']
          ensure
            restore_capture
          end
        end
      end
    end
  end
end
