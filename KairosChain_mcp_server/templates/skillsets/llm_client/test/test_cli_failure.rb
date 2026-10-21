# frozen_string_literal: true
#
# INV-H1 (multi_llm_review design v0.3.3): a CLI seat's failure is named only
# from what the CLI said about itself or what the adapter observed. These tests
# drive the real adapters with SafeSubprocess.safe_capture replaced by a script
# keyed on argv, so the seat call and the after-failure status command can
# answer differently.

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'timeout'

require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/cli_failure'
require_relative '../lib/llm_client/codex_adapter'
require_relative '../lib/llm_client/cursor_adapter'
require_relative '../lib/llm_client/claude_code_adapter'
require_relative '../lib/llm_client/error_taxonomy'
require_relative '../lib/llm_client/call_router'

module KairosMcp
  module SkillSets
    module LlmClient
      class TestCliFailure < Minitest::Test
        Status = Struct.new(:success?, :exitstatus)
        OK = Status.new(true, 0)
        FAIL = Status.new(false, 1)

        # Logged-out codex, as captured 2026-10-21: banner, the echoed prompt,
        # then codex's own error lines. Here the echoed prompt itself quotes
        # "401 Unauthorized" — the reviewed artifact talking about the marker.
        CODEX_STDERR_WITH_ECHO = <<~ERR
          OpenAI Codex v0.163.0
          --------
          workdir: /tmp/x
          model: gpt-6-astra
          --------
          user
          Review this design. It says a logged-out codex prints 401 Unauthorized and "Not logged in".
          2026-10-21T11:54:21.212824Z ERROR codex_api::endpoint::responses_websocket: stream disconnected
        ERR

        def setup
          @calls = []
          @script = {}
        end

        def teardown
          restore_capture if SafeSubprocess.singleton_class.method_defined?(:_orig_safe_capture)
          Thread.current[:cancelled] = nil
        end

        # script: { 'codex exec' => [out, err, status] or Exception, 'codex login status' => [...] }
        def stub_capture
          calls = @calls
          script = @script
          SafeSubprocess.singleton_class.send(:alias_method, :_orig_safe_capture, :safe_capture)
          SafeSubprocess.singleton_class.send(:define_method, :safe_capture) do |args, **kw|
            key = args.first(2).join(' ')
            key = args.first(3).join(' ') if script.key?(args.first(3).join(' '))
            calls << { key: key, env: kw[:env] }
            answer = script.fetch(key) { raise "unscripted call: #{args.inspect}" }
            raise answer if answer.is_a?(Class) || answer.is_a?(Exception)

            answer
          end
        end

        def restore_capture
          SafeSubprocess.singleton_class.send(:remove_method, :safe_capture)
          SafeSubprocess.singleton_class.send(:alias_method, :safe_capture, :_orig_safe_capture)
          SafeSubprocess.singleton_class.send(:remove_method, :_orig_safe_capture)
        end

        def call_codex
          CodexAdapter.new({ 'timeout_seconds' => 30 }).call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
        end

        def call_cursor
          CursorAdapter.new({ 'timeout_seconds' => 30 }).call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
        end

        def call_claude
          ClaudeCodeAdapter.new({ 'timeout_seconds' => 30 }).call(messages: [{ 'role' => 'user', 'content' => 'hi' }])
        end

        # --- the round-1 Y1 case: text that passed through the CLI never labels ---

        def test_codex_marker_in_echoed_prompt_does_not_label_when_cli_says_logged_in
          @script['codex exec'] = ['', CODEX_STDERR_WITH_ECHO, FAIL]
          @script['codex login status'] = ['', "Logged in using ChatGPT\n", OK]
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          assert_nil err.code, 'a marker inside the echoed prompt must not name a cause'
        end

        def test_codex_logged_out_is_named_from_its_own_status_words
          @script['codex exec'] = ['', CODEX_STDERR_WITH_ECHO, FAIL]
          @script['codex login status'] = ['', "Not logged in\n", FAIL]
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          assert_equal 'cli_unauthenticated', err.code
        end

        def test_codex_status_exit_code_alone_is_not_an_answer
          @script['codex exec'] = ['', "boom\n", FAIL]
          @script['codex login status'] = ['', "Error loading config.toml: invalid key\n", FAIL]
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          assert_nil err.code
        end

        def test_codex_workspace_refusal_is_the_whole_stderr_and_asks_nothing
          @script['codex exec'] = ['', "#{CliFailure::CODEX_WORKSPACE_REFUSAL}\n", FAIL]
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          assert_equal 'workspace_refused', err.code
          assert_equal ['codex exec'], @calls.map { |c| c[:key] }
        end

        def test_codex_refusal_line_inside_a_session_is_not_a_refusal
          stderr = "OpenAI Codex v0.163.0\n--------\nuser\n#{CliFailure::CODEX_WORKSPACE_REFUSAL}\n"
          @script['codex exec'] = ['', stderr, FAIL]
          @script['codex login status'] = ['', "Logged in using ChatGPT\n", OK]
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          assert_nil err.code
        end

        def test_message_is_built_as_before_so_taxonomy_type_does_not_move
          @script['codex exec'] = ['', CODEX_STDERR_WITH_ECHO, FAIL]
          @script['codex login status'] = ['', "Not logged in\n", FAIL]
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          # The message is the pre-0.4.0 head excerpt, byte for byte, so the type
          # ErrorTaxonomy derives from it is whatever it was before this change.
          # (Here that type is auth_error: the echoed prompt quotes the marker
          # inside the first 200 characters. That predates this change and is
          # left as it was; the cause this change adds travels in `code`.)
          assert_equal "codex exec exited with status 1: #{CODEX_STDERR_WITH_ECHO[0..200]}", err.message
          assert_equal 'cli_unauthenticated', err.code
        end

        # --- cursor and claude ---

        def test_cursor_logged_out_from_status_stdout
          @script['agent -p'] = ['', "Error: Authentication required. Please run 'agent login' first.\n", FAIL]
          @script['agent status'] = ["Not logged in\n", '', OK]
          stub_capture
          err = assert_raises(ApiError) { call_cursor }
          assert_equal 'cli_unauthenticated', err.code
        end

        def test_cursor_logged_in_status_gives_no_code
          @script['agent -p'] = ['', "Error: something else\n", FAIL]
          @script['agent status'] = ["✓ Logged in as someone@example.com\n", '', OK]
          stub_capture
          err = assert_raises(ApiError) { call_cursor }
          assert_nil err.code
          refute_includes err.message, 'someone@example.com', 'the status output never enters the record'
        end

        def test_claude_logged_out_from_status_json_in_the_seat_environment
          @script['claude -p'] = [JSON.generate('is_error' => true, 'result' => 'Not logged in'), '', FAIL]
          @script['claude auth status'] = [JSON.generate('loggedIn' => false, 'authMethod' => 'none'), '', FAIL]
          stub_capture
          err = assert_raises(ApiError) { call_claude }
          assert_equal 'cli_unauthenticated', err.code
          status_call = @calls.find { |c| c[:key] == 'claude auth status' }
          assert_equal({ '_auth_env_key' => 'ANTHROPIC_API_KEY' }, status_call[:env])
        end

        def test_claude_api_key_login_gives_no_code
          @script['claude -p'] = ['', 'overloaded', FAIL]
          @script['claude auth status'] = [JSON.generate('loggedIn' => true, 'authMethod' => 'api_key'), '', OK]
          stub_capture
          err = assert_raises(ApiError) { call_claude }
          assert_nil err.code
        end

        # --- the dispatcher's own kill, the status timer, missing binaries, timeouts ---

        def test_cancelled_dispatch_asks_the_cli_nothing
          Thread.current[:cancelled] = true
          @script['codex exec'] = ['', '', nil]
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          assert_nil err.code
          assert_equal ['codex exec'], @calls.map { |c| c[:key] }
        end

        def test_status_command_timeout_never_becomes_cli_timeout
          @script['codex exec'] = ['', "boom\n", FAIL]
          @script['codex login status'] = Timeout::Error.new('status timed out')
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          assert_nil err.code
        end

        def test_seat_timeout_is_cli_timeout
          @script['codex exec'] = Timeout::Error.new('seat timed out')
          stub_capture
          err = assert_raises(ApiError) { call_codex }
          assert_equal 'cli_timeout', err.code
        end

        def test_enoent_is_cli_missing_only_when_the_binary_is_not_on_path
          @script['codex exec'] = Errno::ENOENT.new('codex')
          stub_capture
          Dir.mktmpdir do |dir|
            with_path(dir) do
              err = assert_raises(ApiError) { call_codex }
              assert_equal 'cli_missing', err.code
            end
            exe = File.join(dir, 'codex')
            File.write(exe, "#!/bin/sh\n")
            File.chmod(0o755, exe)
            with_path(dir) do
              err = assert_raises(ApiError) { call_codex }
              assert_nil err.code, 'ENOENT with the binary present (e.g. a missing working directory) is not cli_missing'
            end
          end
        end

        # --- the error payload carries the code beside the message ---

        def test_call_router_carries_the_code
          @script['codex exec'] = ['', "#{CliFailure::CODEX_WORKSPACE_REFUSAL}\n", FAIL]
          stub_capture
          out = CallRouter.perform(
            { 'messages' => [{ 'role' => 'user', 'content' => 'hi' }], 'provider_override' => 'codex' },
            { 'provider' => 'codex', 'timeout_seconds' => 30 }
          )
          assert_equal 'error', out['status']
          assert_equal 'workspace_refused', out['error']['code']
        end

        def test_call_router_omits_code_when_none_was_established
          @script['codex exec'] = ['', "boom\n", FAIL]
          @script['codex login status'] = ['', "Logged in using ChatGPT\n", OK]
          stub_capture
          out = CallRouter.perform(
            { 'messages' => [{ 'role' => 'user', 'content' => 'hi' }], 'provider_override' => 'codex' },
            { 'provider' => 'codex', 'timeout_seconds' => 30 }
          )
          refute out['error'].key?('code')
        end

        private

        def with_path(path)
          old = ENV['PATH']
          ENV['PATH'] = path
          yield
        ensure
          ENV['PATH'] = old
        end
      end
    end
  end
end
