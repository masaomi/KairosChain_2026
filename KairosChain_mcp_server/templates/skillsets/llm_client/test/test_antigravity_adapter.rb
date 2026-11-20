# frozen_string_literal: true
# antigravity_adapter: `agy` stream-json transport (2026-11-15, confinement
# revised 2026-11-18). Every case drives AntigravityAdapter#call with
# SafeSubprocess.safe_capture stubbed, so no CLI runs and no model is called.

require 'minitest/autorun'
require 'json'
require 'timeout'
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)
require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/antigravity_adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      class TestAntigravityAdapter < Minitest::Test
        Status = Struct.new(:success?, :exitstatus)

        INIT = { 'event' => 'init',
                 'init' => { 'model' => 'gemini-4-hydrogen-high', 'cwd' => '/tmp/x',
                             'permission_mode' => 'strict', 'agent' => '__AGENT__' } }.freeze

        def result_line(status: 'SUCCESS', response: "VERDICT: APPROVE\n", error: nil)
          r = { 'status' => status, 'response' => response,
                'usage' => { 'input_tokens' => 11, 'output_tokens' => 7 } }
          r['error'] = error if error
          JSON.generate({ 'event' => 'result', 'result' => r })
        end

        def tool_step(name, state, error: nil, index: 2)
          step = { 'step_index' => index, 'step_type' => 'tool', 'tool_name' => name, 'state' => state }
          step['tool_info'] = { 'name' => name, 'error' => { 'type' => 'TOOL_ERROR', 'message' => error } } if error
          { 'event' => 'step_update', 'step_update' => step }
        end

        REFUSED = 'permission check failed for read_file "/x": Permission denied for read_file(/x). Matches user-configured deny rule.'

        def response_step
          { 'event' => 'step_update', 'step_update' => { 'step_type' => 'agent_response', 'state' => 'DONE' } }
        end

        def agent_of(args)
          args[args.index('--agent') + 1]
        end

        def stdout_of(*lines)
          lines.map { |l| l.is_a?(String) ? l : JSON.generate(l) }.join("\n") + "\n"
        end

        def setup
          @adapter = AntigravityAdapter.new({ 'timeout_seconds' => 30 })
          @calls = []
        end

        # Records, at the moment of the call, what the per-call directory held
        # and the agent definition's text, so the tests see what agy would see.
        def with_capture(stdout: '', stderr: '', status: Status.new(true, 0), raise_error: nil)
          calls = @calls
          SafeSubprocess.singleton_class.send(:alias_method, :_orig_safe_capture, :safe_capture)
          SafeSubprocess.singleton_class.send(:define_method, :safe_capture) do |args, **kw|
            dir = kw[:chdir]
            name = args[args.index('--agent') + 1]
            agent = File.join(dir, '.agents', 'agents', "#{name}.md")
            calls << { args: args, kw: kw, agent: name,
                       files: Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).reject { |f| f.end_with?('.') || File.directory?(File.join(dir, f)) },
                       agent_text: File.exist?(agent) ? File.read(agent) : nil }
            raise raise_error if raise_error

            [stdout.gsub('__AGENT__', name), stderr, status]
          end
          yield
        ensure
          SafeSubprocess.singleton_class.send(:remove_method, :safe_capture)
          SafeSubprocess.singleton_class.send(:alias_method, :safe_capture, :_orig_safe_capture)
          SafeSubprocess.singleton_class.send(:remove_method, :_orig_safe_capture)
        end

        def msg(text)
          [{ 'role' => 'user', 'content' => text }]
        end

        def settings_of(args)
          JSON.parse(args[args.index('--settings') + 1])
        end

        # --- confinement as built ---------------------------------------------

        def test_never_runs_plan_mode
          with_capture(stdout: stdout_of(INIT, result_line)) do
            @adapter.call(messages: msg('review this'), model: 'gemini-4-hydrogen-high')
          end
          args = @calls.first[:args]
          refute_includes args, '--mode', 'plan mode writes plan files; it is not read-only'
          refute_includes args, 'plan'
          assert_equal '', settings_of(args)['agentMode']
        end

        def test_settings_deny_every_permission_action_under_strict
          with_capture(stdout: stdout_of(INIT, result_line)) do
            @adapter.call(messages: msg('hi'), model: 'm')
          end
          s = settings_of(@calls.first[:args])
          assert_equal 'strict', s['toolPermission']
          assert_equal false, s['allowNonWorkspaceAccess']
          assert_equal true, s['enableTerminalSandbox']
          assert_equal true, s['disableSlashCommands']
          refute s.key?('artifactReviewPolicy'), 'no loosening setting is passed'
          %w[read_file write_file read_url execute_url command mcp unsandboxed].each do |action|
            assert_includes s.dig('permissions', 'deny'), "#{action}(*)"
          end
        end

        def test_flags_sandbox_slash_commands_agent_stream_and_model
          with_capture(stdout: stdout_of(INIT, result_line)) do
            @adapter.call(messages: msg('hi'), model: 'gemini-4-hydrogen-high')
          end
          args = @calls.first[:args]
          assert_equal ['--agent', agent_of(args), '--model', 'gemini-4-hydrogen-high'], args.last(4)
          assert_match(/\Akairos_review_seat_[0-9a-f]{12}\z/, agent_of(args))
          assert_includes args, '--sandbox'
          assert_includes args, '--disable-slash-commands'
          refute_includes args, '-p'
        end

        def test_nil_model_omits_flag
          with_capture(stdout: stdout_of(INIT, result_line)) do
            @adapter.call(messages: msg('hi'), model: nil)
          end
          args = @calls.first[:args]
          refute_includes args, '--model'
          assert_equal ['--agent', agent_of(args)], args.last(2)
        end

        def test_the_per_call_directory_holds_only_the_agent_with_no_tools_and_is_removed
          with_capture(stdout: stdout_of(INIT, result_line)) do
            @adapter.call(messages: msg('hi'), model: 'm')
          end
          call = @calls.first
          assert_equal [".agents/agents/#{call[:agent]}.md"], call[:files]
          front = call[:agent_text].split(/^---\s*$/)[1]
          require 'yaml'
          fm = YAML.safe_load(front)
          assert_equal call[:agent], fm['name']
          assert_equal [], fm['tools'], 'an empty allowlist is the only guard that removes search_web'
          assert_equal true, fm['mainAgent']
          assert_equal 'off', fm['commandExecutionPolicy']
          refute Dir.exist?(call[:kw][:chdir]), 'the per-call directory is removed afterwards'
        end

        def test_the_per_call_directory_is_removed_on_timeout_too
          assert_raises(ApiError) do
            with_capture(raise_error: Timeout::Error.new('slow')) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          refute Dir.exist?(@calls.first[:kw][:chdir])
        end

        # --- fail closed on what the session reports -----------------------------

        def test_the_agent_name_is_unique_per_call
          with_capture(stdout: stdout_of(INIT, result_line)) do
            2.times { @adapter.call(messages: msg('hi'), model: 'm') }
          end
          refute_equal @calls[0][:agent], @calls[1][:agent]
        end

        # Measured: init carries `agent` only when the definition was loaded.
        def test_a_session_without_the_agent_is_refused
          init = { 'event' => 'init', 'init' => { 'model' => 'm', 'permission_mode' => 'strict' } }
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(init, result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'tool allowlist not in effect'
          refute err.retryable
        end

        def test_a_session_under_another_agent_is_refused
          init = { 'event' => 'init', 'init' => { 'model' => 'm', 'permission_mode' => 'strict',
                                                  'agent' => 'kairos_review_seat' } }
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(init, result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'not this call'
        end

        def test_permission_mode_other_than_strict_is_refused
          init = { 'event' => 'init', 'init' => { 'model' => 'm', 'permission_mode' => 'request-review',
                                                  'agent' => '__AGENT__' } }
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(init, result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'not confined'
          assert_includes err.message, 'request-review'
          refute err.retryable
        end

        def test_missing_init_is_refused
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'no init event'
        end

        def test_a_tool_that_ran_refuses_the_reply
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, tool_step('search_web', 'ACTIVE'),
                                           tool_step('search_web', 'DONE'), result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'tool search_web reached DONE'
          refute err.retryable
        end

        def test_a_tool_the_cli_refused_is_not_a_failure
          out = nil
          with_capture(stdout: stdout_of(INIT, tool_step('read_file', 'ACTIVE'),
                                         tool_step('read_file', 'ERROR', error: REFUSED), result_line)) do
            out = @adapter.call(messages: msg('hi'), model: 'm')
          end
          assert_equal "VERDICT: APPROVE\n", out['content']
        end

        def test_a_tool_that_ran_and_then_failed_is_refused
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, tool_step('run_command', 'ERROR', error: 'exit status 1'), result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'tool run_command reached ERROR'
        end

        def test_a_tool_in_an_unrecognised_state_is_refused
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, tool_step('write_to_file', 'COMPLETED'), result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'tool write_to_file reached COMPLETED'
        end

        def test_an_unrecognised_step_type_is_refused
          step = { 'event' => 'step_update', 'step_update' => { 'step_type' => 'subagent', 'state' => 'DONE' } }
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, step, result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'unrecognised step type "subagent"'
        end

        def test_a_breach_on_a_failed_run_is_reported_as_a_breach
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, tool_step('search_web', 'DONE'),
                                           result_line(status: 'ERROR', response: '', error: 'model unavailable'))) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'not confined'
          assert_includes err.message, 'the run also failed'
          assert_includes err.message, 'model unavailable'
          refute err.retryable, 'a breach is never retried, even when the failure text looks transient'
        end

        def test_a_tool_step_left_active_is_refused
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, tool_step('search_web', 'ACTIVE'), result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'tool search_web never reported an outcome'
        end

        def test_refusal_text_inside_another_error_is_not_a_refusal
          [
            'exit status 1: permission check failed',
            'search failed for query "Matches user-configured deny rule."',
            "warning: #{REFUSED}"
          ].each do |message|
            err = assert_raises(ApiError, message) do
              with_capture(stdout: stdout_of(INIT, tool_step('run_command', 'ERROR', error: message), result_line)) do
                @adapter.call(messages: msg('hi'), model: 'm')
              end
            end
            assert_includes err.message, 'tool run_command reached ERROR', message
          end
        end

        def test_an_unrecognised_event_is_refused
          ev = { 'event' => 'subagent_step', 'subagent_step' => { 'tool_name' => 'write_to_file', 'state' => 'DONE' } }
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, ev, result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'unrecognised event "subagent_step"'
        end

        # Measured 2026-11-18 (missing_agent.ndjson): an unknown agent ends with
        # a result-only stream, ERROR, exit 1 and no init. Nothing ran.
        def test_a_run_that_failed_before_init_is_an_ordinary_failure
          line = JSON.generate({ 'event' => 'result', 'result' => { 'status' => 'ERROR', 'num_turns' => 0 } })
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(line), stderr: 'error: unknown agent "x" (no custom agents are available)',
                         status: Status.new(false, 1)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          refute_includes err.message, 'not confined'
          assert_includes err.message, 'unknown agent'
        end

        def test_a_successful_result_without_init_is_still_refused
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(result_line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'no init event'
        end

        # --- prompt transport ---------------------------------------------------

        def test_prompt_goes_to_stdin_as_one_user_event_line
          with_capture(stdout: stdout_of(INIT, result_line)) do
            @adapter.call(messages: msg("line one\nline two"), system: 'be strict', model: 'm')
          end
          stdin = @calls.first[:kw][:stdin_data]
          assert_equal 1, stdin.lines.size
          event = JSON.parse(stdin)
          assert_equal 'user', event['event']
          assert_equal "[System]: be strict\n\nline one\nline two", event.dig('message', 'content')
        end

        def test_a_100k_prompt_stays_one_line
          big = "word " * 20_000
          with_capture(stdout: stdout_of(INIT, result_line)) do
            @adapter.call(messages: msg(big), model: 'm')
          end
          stdin = @calls.first[:kw][:stdin_data]
          assert_operator stdin.bytesize, :>, 100_000
          assert_equal 1, stdin.lines.size
        end

        def test_prompt_opening_with_slash_is_tagged
          with_capture(stdout: stdout_of(INIT, result_line)) do
            @adapter.call(messages: msg('/help me'), model: 'm')
          end
          content = JSON.parse(@calls.first[:kw][:stdin_data]).dig('message', 'content')
          refute content.lstrip.start_with?('/')
          assert content.end_with?('/help me')
        end

        # --- the reply ----------------------------------------------------------

        def test_success_returns_response_usage_and_no_observed_model
          out = nil
          with_capture(stdout: stdout_of(INIT, response_step, 'not json', result_line)) do
            out = @adapter.call(messages: msg('hi'), model: 'gemini-4-hydrogen-high')
          end
          assert_equal "VERDICT: APPROVE\n", out['content']
          assert_equal 'gemini-4-hydrogen-high', out['model']
          assert_nil out['model_observed'], 'init names a model before any model answered'
          assert_equal 11, out['input_tokens']
          assert_equal 7, out['output_tokens']
        end

        def test_the_conversation_id_is_returned
          line = JSON.generate({ 'event' => 'result', 'result' => { 'status' => 'SUCCESS', 'response' => "ok\n",
                                                                    'conversation_id' => 'c0ffee' } })
          out = nil
          with_capture(stdout: stdout_of(INIT, line)) do
            out = @adapter.call(messages: msg('hi'), model: 'm')
          end
          assert_equal 'c0ffee', out['conversation_id']
        end

        def test_the_last_result_event_is_the_one_read
          out = nil
          with_capture(stdout: stdout_of(INIT, result_line(response: "first\n"), result_line(response: "second\n"))) do
            out = @adapter.call(messages: msg('hi'), model: 'm')
          end
          assert_equal "second\n", out['content']
        end

        def test_a_tool_use_sample_in_a_review_without_tools_stays_text
          reply = "**Overall Verdict**: REVISE\nP2: the sample ```json\n{\"tool_use\": [{\"name\": \"x\", \"input\": {}}]}\n``` is parsed [location: a:1]\n"
          out = nil
          with_capture(stdout: stdout_of(INIT, result_line(response: reply))) do
            out = @adapter.call(messages: msg('review'), model: 'm')
          end
          assert_equal reply, out['content']
          assert_nil out['tool_use']
        end

        def test_tool_use_is_read_when_the_caller_offered_tools
          reply = "```json\n{\"tool_use\": [{\"name\": \"lookup\", \"input\": {\"q\": 1}}]}\n```"
          out = nil
          with_capture(stdout: stdout_of(INIT, result_line(response: reply))) do
            out = @adapter.call(messages: msg('go'), model: 'm',
                                tools: [{ 'name' => 'lookup', 'description' => 'd' }])
          end
          assert_nil out['content']
          assert_equal 'lookup', out['tool_use'].first['name']
        end

        # --- failures, each named by what was observed --------------------------

        def test_exit_zero_with_empty_response_is_an_error_carrying_stderr
          denied = 'jetski: no output produced — a tool required the "command" permission'
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, result_line(response: '')), stderr: denied) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'empty response'
          assert_includes err.message, denied
          assert_equal 'antigravity', err.provider
        end

        def test_whitespace_only_reply_is_an_empty_response
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, result_line(response: "  \n\t\n"))) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'empty response'
        end

        def test_error_result_raises_with_its_message
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, result_line(status: 'ERROR', response: '', error: 'model unavailable')),
                         status: Status.new(false, 1)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'model unavailable'
          assert_includes err.message, 'result status ERROR'
          assert err.retryable, 'an unavailable model is worth one retry'
        end

        def test_result_without_status_says_none
          line = JSON.generate({ 'event' => 'result', 'result' => { 'response' => '' } })
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, line)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'result status (none)'
          refute_includes err.message, 'status :'
        end

        def test_no_result_event_raises
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT), stderr: '') do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'no result event'
          assert_includes err.message, 'stderr empty'
          refute err.retryable
        end

        def test_nonzero_exit_beside_a_success_result_is_named_as_such
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, result_line), status: Status.new(false, 2)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'result SUCCESS but the process exited non-zero'
          refute_includes err.message, 'no result event'
        end

        def test_no_exit_status_is_named_as_such
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, result_line), status: Status.new(false, nil)) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_includes err.message, 'ended without an exit status'
        end

        def test_a_bare_500_in_text_is_not_transient
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, result_line(status: 'ERROR', response: '', error: 'context used 500 tokens'))) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          refute err.retryable
        end

        def test_an_http_status_503_is_transient
          err = assert_raises(ApiError) do
            with_capture(stdout: stdout_of(INIT, result_line(status: 'ERROR', response: '', error: 'HTTP 503 from backend'))) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert err.retryable
        end

        def test_timeout_is_cli_timeout_and_retryable
          err = assert_raises(ApiError) do
            with_capture(raise_error: Timeout::Error.new('slow')) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_equal CliFailure::CLI_TIMEOUT, err.code
          assert err.retryable
        end

        def test_missing_binary_is_cli_missing
          CliFailure.singleton_class.send(:alias_method, :_orig_on_path, :binary_on_path?)
          CliFailure.singleton_class.send(:define_method, :binary_on_path?) { |_b| false }
          err = assert_raises(ApiError) do
            with_capture(raise_error: Errno::ENOENT.new('agy')) do
              @adapter.call(messages: msg('hi'), model: 'm')
            end
          end
          assert_equal CliFailure::CLI_MISSING, err.code
          refute err.retryable
        ensure
          CliFailure.singleton_class.send(:remove_method, :binary_on_path?)
          CliFailure.singleton_class.send(:alias_method, :binary_on_path?, :_orig_on_path)
          CliFailure.singleton_class.send(:remove_method, :_orig_on_path)
        end

        # --- the two places that build adapters ---------------------------------

        def test_router_builds_this_adapter_for_the_provider
          require_relative '../lib/llm_client/call_router'
          adapter = CallRouter.build_adapter({ 'provider' => 'antigravity' })
          assert_instance_of AntigravityAdapter, adapter
          assert CallRouter::PROVIDER_API_KEY_DEFAULTS.key?('antigravity')
          assert_nil CallRouter::PROVIDER_API_KEY_DEFAULTS['antigravity']
        end

        def test_the_llm_call_tool_builds_this_adapter_and_offers_the_provider
          require 'kairos_mcp/tools/base_tool'
          require_relative '../tools/llm_call'
          tool = Tools::LlmCall.new
          assert_instance_of AntigravityAdapter, tool.send(:build_adapter, { 'provider' => 'antigravity' })
          enum = tool.input_schema.dig(:properties, :provider_override, :enum) ||
                 tool.input_schema.dig('properties', 'provider_override', 'enum')
          assert_includes enum, 'antigravity'
        end
      end
    end
  end
end
