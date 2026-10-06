# frozen_string_literal: true
# A cursor seat only answers: `agent -p` has every tool (write and shell
# included), so it runs read-only (--mode plan) in an empty directory made for
# the call and removed afterwards, never in the MCP server's working directory.

require 'minitest/autorun'
require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/cursor_adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      class TestCursorAdapterReadonly < Minitest::Test
        Status = Struct.new(:success?, :exitstatus)

        def test_runs_read_only_in_an_empty_private_directory
          seen = {}
          SafeSubprocess.singleton_class.send(:alias_method, :_orig_safe_capture, :safe_capture)
          SafeSubprocess.singleton_class.send(:define_method, :safe_capture) do |args, **kw|
            seen[:args] = args
            seen[:chdir] = kw[:chdir]
            seen[:entries_at_launch] = Dir.children(kw[:chdir])
            seen[:chdir_real] = File.realpath(kw[:chdir])
            seen[:pwd_real] = File.realpath(Dir.pwd)
            ['{"content":"ok"}', '', Status.new(true, 0)]
          end
          begin
            CursorAdapter.new({ 'timeout_seconds' => 30 }).call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
          ensure
            SafeSubprocess.singleton_class.send(:remove_method, :safe_capture)
            SafeSubprocess.singleton_class.send(:alias_method, :safe_capture, :_orig_safe_capture)
            SafeSubprocess.singleton_class.send(:remove_method, :_orig_safe_capture)
          end

          assert_includes seen[:args].each_cons(2).to_a, ['--mode', 'plan']
          assert_includes seen[:args], '--trust'
          refute_includes seen[:args], '--force'
          refute_includes seen[:args], '--yolo'
          refute_nil seen[:chdir]
          refute_equal seen[:pwd_real], seen[:chdir_real], 'the seat must not run in the caller\'s working directory'
          assert_empty seen[:entries_at_launch]
          refute File.exist?(seen[:chdir]), 'the per-call directory is removed after the call'
        end
      end
    end
  end
end
