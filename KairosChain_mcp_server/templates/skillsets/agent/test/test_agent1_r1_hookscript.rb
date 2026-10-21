# frozen_string_literal: true

# Regression tests for the implementation review R1 (2026-10-20), group
# "hookscript": hooks/agent_hook.rb run end to end as the host runs it — a
# Ruby subprocess with the hook input as JSON on stdin and HOME,
# KAIROS_DATA_DIR, CLAUDE_PROJECT_DIR and KAIROS_AGENT_GLOBAL inside a tmpdir.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'fileutils'
require 'rbconfig'
require 'securerandom'
require_relative '../lib/agent/service'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R1Hookscript < Minitest::Test
        SKILLSET = File.expand_path('..', __dir__)
        SCRIPT = File.join(SKILLSET, 'hooks', 'agent_hook.rb')
        HOOKS_JSON = File.join(SKILLSET, 'plugin', 'hooks.json')
        POLICY_SRC = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 8, stand_in_calls: 100 }
          end
        RUBY

        def setup
          @root = File.realpath(Dir.mktmpdir('a1hs'))
          @global = File.join(@root, 'global_bound_sessions.txt')
          ENV['KAIROS_AGENT_GLOBAL'] = @global
          @home = File.join(@root, 'home')
          FileUtils.mkdir_p(@home)
          @data = File.join(@root, '.kairos')
          @paths = Paths.new(@data)
          @transcript = File.join(@root, 'transcript.jsonl')
          File.write(@transcript, '')
          @run_ids = []
        end

        def teardown
          @run_ids.each { |id| FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', id)) }
          FileUtils.rm_rf(@root)
        end

        # --- harness ------------------------------------------------------------

        def child_env(extra = {})
          { 'HOME' => @home, 'KAIROS_DATA_DIR' => @data, 'CLAUDE_PROJECT_DIR' => @root,
            'KAIROS_AGENT_GLOBAL' => @global, 'KAIROS_MCP_LIB' => nil }.merge(extra)
        end

        # The script as the host runs it: hook input on stdin, from the project.
        def hook(input, script: SCRIPT, env: {})
          stdin = input.is_a?(String) ? input : JSON.generate(input)
          out, err, st = Open3.capture3(child_env(env), RbConfig.ruby, script, stdin_data: stdin, chdir: @root)
          [out, err, st.exitstatus]
        end

        def pre(sid, tool, tool_input = {})
          hook({ 'hook_event_name' => 'PreToolUse', 'session_id' => sid, 'tool_name' => tool,
                 'tool_input' => tool_input, 'cwd' => @root, 'tool_use_id' => "tu_#{SecureRandom.hex(3)}" })
        end

        def decision_of(out)
          JSON.parse(out)['hookSpecificOutput']
        end

        # A copy of the script whose library only leaves a mark when loaded:
        # tells whether an event pays for the library at all.
        def stub_script
          dir = File.join(@root, 'stub')
          FileUtils.mkdir_p([File.join(dir, 'hooks'), File.join(dir, 'lib', 'agent')])
          FileUtils.cp(SCRIPT, File.join(dir, 'hooks', 'agent_hook.rb'))
          File.write(File.join(dir, 'lib', 'agent', 'hooks.rb'), "File.write(ENV.fetch('AGENT_HOOK_LOADED'), 'loaded')\n")
          File.join(dir, 'hooks', 'agent_hook.rb')
        end

        def loads_library?(input)
          marker = File.join(@root, "loaded_#{SecureRandom.hex(4)}")
          hook(input, script: stub_script, env: { 'AGENT_HOOK_LOADED' => marker })
          File.exist?(marker)
        end

        def typed(text, prompt_id)
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => prompt_id, 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => text }))
          end
        end

        def policy
          @policy ||= DSL.parse_policy(POLICY_SRC)
        end

        # The policy file under <data>/skillsets/agent/config/policies, adopted
        # by the operator's typed words.
        def adopt_policy!
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'p1.rb'), POLICY_SRC)
          words = "adopt policy p1 #{policy.digest[0, 8]} でお願いします"
          typed(words, 'pr_adopt')
          Policies.new(@paths).adopt('p1', words: words, transcript_path: @transcript, prompt_id: 'pr_adopt')
        end

        # A run created through the library in the same data directory.
        def create_run(name = 'r1')
          adopt_policy! unless File.exist?(File.join(@paths.policies_dir, 'p1.rb'))
          wt = File.join(@root, '.claude', 'worktrees', name)
          FileUtils.mkdir_p(File.join(wt, 'lib'))
          File.write(File.join(wt, 'lib', 'x.rb'), "x = 1\n")
          plan = DSL.parse_plan(Templates.design_only(name: name, goal: 'g', design_glob: 'log/x_design_v*.md'))
          run = Run.create(@paths, goal: 'g', target_repo: @root, worktree: wt, branch: "agent-run/#{name}",
                                   plan: plan, policy: Policies.new(@paths).adopted)
          @run_ids << run.id
          run
        end

        # Bound to a session whose guard the host has just shown live.
        def bound_run(sid = 's1')
          run = create_run
          _, _, code = pre(sid, 'mcp__kairos-chain__agent_status', {})
          assert_equal 0, code
          run.bind(sid)
          assert File.exist?(File.join(@paths.bindings_dir, sid))
          run
        end

        def write_settings(path, deny)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.generate('permissions' => { 'deny' => deny }))
        end

        # --- unbound sessions -----------------------------------------------------

        def test_unreadable_stdin_exits_1_so_the_host_failure_policy_decides
          ['not json', '', '{"hook_event_name":"PreToolUse","session_id":'].each do |stdin|
            out, err, code = hook(stdin)
            assert_equal 1, code, "stdin #{stdin.inspect}"
            assert_empty out, 'no decision for input that names no session'
            assert_includes err, 'unreadable hook input'
          end
          refute File.exist?(@data), 'nothing is written for unattributable input'
        end

        def test_kairos_agent_tool_learns_its_session_in_an_unbound_session
          out, _, code = pre('u1', 'mcp__kairos-chain__agent_status', 'run_id' => 'run_x')
          assert_equal 0, code
          d = decision_of(out)
          assert_equal 'allow', d['permissionDecision']
          assert_equal({ 'run_id' => 'run_x', '_session_id' => 'u1' }, d['updatedInput'].except('_project_dir'))
          assert d['updatedInput'].key?('_project_dir'), 'the tool learns the session project too'
          assert File.exist?(File.join(@paths.guard_seen_dir, 'u1')), 'the guard is marked as seen'
          refute loads_library?('hook_event_name' => 'PreToolUse', 'session_id' => 'u1',
                                'tool_name' => 'mcp__kairos-chain__agent_status', 'tool_input' => {}),
                 'the session is told without loading the library'
        end

        def test_another_servers_agent_tools_get_no_output
          %w[mcp__acme__agent_stop mcp__other__agent_start].each do |tool|
            out, _, code = pre('u1', tool, 'run_id' => 'run_x')
            assert_equal 0, code, tool
            assert_empty out, "#{tool} is not KairosChain's agent tool"
            refute loads_library?('hook_event_name' => 'PreToolUse', 'session_id' => 'u1', 'tool_name' => tool,
                                  'tool_input' => {}), tool
          end
        end

        def test_an_ordinary_tool_in_an_unbound_session_gets_no_output
          out, _, code = pre('u1', 'Bash', 'command' => 'git push origin main')
          assert_equal 0, code
          assert_empty out
          assert File.exist?(File.join(@paths.guard_seen_dir, 'u1'))
          refute loads_library?('hook_event_name' => 'PreToolUse', 'session_id' => 'u1', 'tool_name' => 'Write',
                                'tool_input' => { 'file_path' => File.join(@root, 'x') }),
                 'an ordinary session pays one Ruby start and a file stat'
        end

        def test_a_correction_naming_a_decision_is_kept_from_an_unbound_session
          words = 'D4 は違う、8 席で'
          out, _, code = hook({ 'hook_event_name' => 'UserPromptSubmit', 'session_id' => 'u1', 'prompt' => words,
                                'prompt_id' => 'p4', 'transcript_path' => @transcript })
          assert_equal 0, code
          assert_empty out
          lines = File.readlines(@paths.operator_words_path).map { |l| JSON.parse(l) }
          assert_equal 1, lines.size
          assert_equal({ 'session_id' => 'u1', 'transcript_path' => @transcript, 'prompt_id' => 'p4', 'text' => words },
                       lines.first.slice('session_id', 'transcript_path', 'prompt_id', 'text'))
        end

        def test_a_prompt_naming_nothing_does_not_load_the_library
          prompt = { 'hook_event_name' => 'UserPromptSubmit', 'session_id' => 'u1', 'prompt' => 'hello',
                     'transcript_path' => @transcript }
          out, _, code = hook(prompt)
          assert_equal 0, code
          assert_empty out
          refute File.exist?(@paths.operator_words_path), 'nothing is written for words that name nothing'
          refute loads_library?(prompt)
          assert loads_library?(prompt.merge('prompt' => 'D4 は違う、8 席で')), 'control: a reference does load it'
        end

        # The service admits "D4は…" (its ref pattern is (?<![A-Za-z0-9])D4(?![0-9])),
        # but the recorder's \b sees no boundary between "4" and "は".
        def test_a_correction_typed_without_a_space_is_kept_too
          words = 'D4は違う、8席で'
          out, _, code = hook({ 'hook_event_name' => 'UserPromptSubmit', 'session_id' => 'u1', 'prompt' => words,
                                'prompt_id' => 'p5', 'transcript_path' => @transcript })
          assert_equal 0, code
          assert_empty out
          assert File.exist?(@paths.operator_words_path), "#{words.inspect} names D4 and must be kept"
          assert_equal words, JSON.parse(File.readlines(@paths.operator_words_path).last)['text']
        end

        def test_stop_in_an_unbound_session_exits_0_silently
          stop = { 'hook_event_name' => 'Stop', 'session_id' => 'u1',
                   'last_assistant_message' => 'The API key leaked. A と B、どちらにしますか？' }
          out, err, code = hook(stop)
          assert_equal 0, code
          assert_empty out
          assert_empty err
          refute loads_library?(stop)
        end

        # --- a bound session ------------------------------------------------------

        def test_bash_in_a_bound_session_is_rewritten_to_run_confined
          skip 'sandbox-exec unavailable' unless Confinement.available?
          run = bound_run
          inside = File.join(run.worktree, 'inside.txt')
          outside = File.join(@root, 'outside.txt')
          out, _, code = pre('s1', 'Bash', 'command' => "echo in > #{inside}; echo out > #{outside}")
          assert_equal 0, code
          d = decision_of(out)
          assert_equal 'allow', d['permissionDecision']
          cmd = d.dig('updatedInput', 'command')
          assert_match(%r{\Aenv TMPDIR\\?=\S+ /usr/bin/sandbox-exec -p }, cmd)
          assert cmd.end_with?(Shellwords.escape("echo in > #{inside}; echo out > #{outside}")), 'the original command runs inside'
          _, err, = Open3.capture3('/bin/bash', '-c', cmd, chdir: run.worktree)
          assert_equal "in\n", File.read(inside), 'the worktree is writable'
          refute File.exist?(outside), 'the main checkout is not'
          assert_includes err, 'Operation not permitted'
          assert(run.reload.journal.entries.any? { |e| e['kind'] == 'effect' && e['verdict'] == 'confined' })
        end

        def test_a_write_into_the_data_directory_is_denied
          run = bound_run
          [File.join(@paths.policies_dir, 'p1.rb'), File.join(@paths.bindings_dir, 's1'),
           File.join(@data, 'storage', 'agent', 'new.txt')].each do |target|
            before = File.exist?(target) ? File.read(target) : nil
            out, _, code = pre('s1', 'Write', 'file_path' => target, 'content' => 'x')
            assert_equal 0, code
            d = decision_of(out)
            assert_equal 'deny', d['permissionDecision'], target
            assert_includes d['permissionDecisionReason'], 'governs runs'
            assert_equal before.inspect, (File.exist?(target) ? File.read(target) : nil).inspect, 'the target is untouched'
          end
          assert_equal 3, run.reload.open_items.size, 'each refusal is an operator item'
        end

        def test_a_bash_deny_rule_refuses_any_segment_of_the_original_command
          run = bound_run
          write_settings(File.join(@home, '.claude', 'settings.json'), ['Bash(rm:*)'])
          ['cd /tmp && rm -rf x', 'rm -rf x', 'ls; rm x', 'true || rm x'].each do |cmd|
            out, _, code = pre('s1', 'Bash', 'command' => cmd)
            assert_equal 0, code
            d = decision_of(out)
            assert_equal 'deny', d['permissionDecision'], cmd
            assert_includes d['permissionDecisionReason'], "operator's own permission rules"
          end
          item = run.reload.open_items.first
          assert_equal 'cd /tmp && rm -rf x', item['command'], 'the item keeps the original command'
          next_out, = pre('s1', 'Bash', 'command' => 'echo hi')
          assert_equal 'allow', decision_of(next_out)['permissionDecision'], 'control: other commands still run' if Confinement.available?
        end

        def test_a_bash_deny_rule_sees_commands_inside_shell_grouping
          bound_run
          write_settings(File.join(@home, '.claude', 'settings.json'), ['Bash(rm:*)'])
          ['if [ -d x ]; then rm -rf x; fi', '(rm -rf x)'].each do |cmd|
            out, _, code = pre('s1', 'Bash', 'command' => cmd)
            assert_equal 0, code
            assert_equal 'deny', decision_of(out)['permissionDecision'], cmd
          end
        end

        # A guard allow would not suppress the host's own rules; the run's
        # operator is not answering, so the guard refuses and queues (design §8).
        def test_a_tool_the_operators_deny_rules_name_is_refused_and_queued
          run = bound_run
          file = File.join(run.worktree, 'lib', 'x.rb')
          edit = { 'file_path' => file, 'old_string' => 'x = 1', 'new_string' => 'x = 2' }
          out, = pre('s1', 'Edit', edit)
          assert_equal 'allow', decision_of(out)['permissionDecision'], 'control: an Edit in the worktree is allowed'

          write_settings(File.join(@home, '.claude', 'settings.json'), ['Edit'])
          out, _, code = pre('s1', 'Edit', edit)
          assert_equal 0, code
          assert_equal 'deny', decision_of(out)['permissionDecision'], 'user-level "Edit" is refused'
          assert_includes decision_of(out)['permissionDecisionReason'], "operator's own settings"

          write_settings(File.join(@home, '.claude', 'settings.json'), [])
          write_settings(File.join(@root, '.claude', 'settings.json'), ['Write(./secret/**)'])
          out, = pre('s1', 'Write', 'file_path' => File.join(run.worktree, 'new.rb'), 'content' => 'y')
          assert_equal 'allow', decision_of(out)['permissionDecision'], 'a path rule names only its own paths'
          out, = pre('s1', 'Write', 'file_path' => File.join(@root, 'secret', 'k.txt'), 'content' => 'y')
          assert_equal 'deny', decision_of(out)['permissionDecision'], 'project-level "Write(./secret/**)" is refused'

          out, = pre('s1', 'Write', 'file_path' => File.join(@data, 'evil.rb'), 'content' => 'y')
          assert_equal 'deny', decision_of(out)['permissionDecision'], 'a refusal stays a refusal'
        end

        def test_an_mcp_tool_the_operators_deny_rules_name_is_refused_and_queued
          bound_run
          tool = 'mcp__kairos-chain__knowledge_get'
          out, = pre('s1', tool, 'name' => 'x')
          assert_equal 'allow', decision_of(out)['permissionDecision'], 'control: a read-only kairos tool is allowed'
          write_settings(File.join(@home, '.claude', 'settings.json'), [tool])
          out, _, code = pre('s1', tool, 'name' => 'x')
          assert_equal 0, code
          assert_equal 'deny', decision_of(out)['permissionDecision'], "the operator's deny rule names #{tool}"
          write_settings(File.join(@home, '.claude', 'settings.json'), ['mcp__kairos-chain'])
          out, = pre('s1', tool, 'name' => 'x')
          assert_equal 'deny', decision_of(out)['permissionDecision'], 'a server-wide rule names every tool of the server'
        end

        # --- binding --------------------------------------------------------------

        def test_agent_start_from_another_server_does_not_bind
          run = create_run
          pre('s2', 'Read', 'file_path' => @transcript) # the guard is seen in s2
          response = [{ 'type' => 'text', 'text' => JSON.generate('status' => 'started', 'run_id' => run.id, 'bind' => true) }]
          post = { 'hook_event_name' => 'PostToolUse', 'session_id' => 's2', 'tool_name' => 'mcp__acme__agent_start',
                   'tool_input' => {}, 'tool_response' => response, 'transcript_path' => @transcript }
          out, _, code = hook(post)
          assert_equal 0, code
          assert_empty out
          refute File.exist?(File.join(@paths.bindings_dir, 's2'))
          assert_nil run.reload.bound_session

          # In a session already bound to another run, too.
          other = bound_run('s1')
          out, _, code = hook(post.merge('session_id' => 's1', 'tool_name' => 'mcp__other__agent_start'))
          assert_equal 0, code
          assert_empty out
          assert_nil run.reload.bound_session
          assert_equal other.id, File.read(File.join(@paths.bindings_dir, 's1')).strip

          # Control: KairosChain's own agent_start attaches the transcript to a
          # run the service bound to this session; it never takes a run over.
          out, _, code = hook(post.merge('tool_name' => 'mcp__kairos-chain__agent_start'))
          assert_equal 0, code
          assert_empty out, 'an unbound run is not bound by a PostToolUse'
          assert_nil run.reload.bound_session
          FileUtils.touch(File.join(@paths.guard_seen_dir, 's2'))
          run.bind('s2')
          out, _, code = hook(post.merge('tool_name' => 'mcp__kairos-chain__agent_start'))
          assert_equal 0, code
          assert_includes decision_of(out)['additionalContext'], "Run #{run.id} is bound to this session"
          assert_equal @transcript, run.reload.transcript_path
        end

        # --- the plugin's command line ----------------------------------------------

        def test_the_plugin_command_exits_0_when_the_script_is_absent
          hooks = JSON.parse(File.read(HOOKS_JSON))['hooks']
          commands = hooks.values.flatten.flat_map { |m| m['hooks'] }.map { |h| h['command'] }.uniq
          assert_equal 2, commands.size, 'one script for every event; PreToolUse fails closed while a run is bound'
          pre_cmd = hooks['PreToolUse'].first['hooks'].first['command']
          bound_dir = File.join(@root, 'bound_data')
          FileUtils.mkdir_p(File.join(bound_dir, 'storage', 'agent', 'bindings'))
          File.write(File.join(bound_dir, 'storage', 'agent', 'bindings', 's1'), 'run_x')
          _, err, st = Open3.capture3(child_env('KAIROS_DATA_DIR' => bound_dir), '/bin/sh', '-c', pre_cmd,
                                      stdin_data: '{"session_id":"s1","hook_event_name":"PreToolUse"}', chdir: @root)
          assert_equal 2, st.exitstatus, 'the script is missing while this session is bound: the tool call is blocked'
          assert_includes err, 'agent guard unavailable'
          _, _, st = Open3.capture3(child_env('KAIROS_DATA_DIR' => bound_dir), '/bin/sh', '-c', pre_cmd,
                                    stdin_data: '{"session_id":"other","hook_event_name":"PreToolUse"}', chdir: @root)
          assert_equal 0, st.exitstatus, 'another session is never blocked by this one\'s binding'
          envs = [{ 'KAIROS_DATA_DIR' => File.join(@root, 'absent') },
                  { 'KAIROS_DATA_DIR' => nil, 'CLAUDE_PROJECT_DIR' => File.join(@root, 'absent_project') }]
          commands.product(envs).each do |cmd, e|
            out, _, st = Open3.capture3(child_env(e), '/bin/sh', '-c', cmd, stdin_data: 'not json', chdir: @root)
            assert_equal 0, st.exitstatus, e.inspect
            assert_empty out
          end

          # Control: once installed under the data directory, the same line runs it.
          installed = File.join(@data, 'skillsets', 'agent')
          FileUtils.mkdir_p(installed)
          FileUtils.cp_r(File.join(SKILLSET, 'hooks'), installed)
          FileUtils.cp_r(File.join(SKILLSET, 'lib'), installed)
          commands.each do |cmd|
            _, _, st = Open3.capture3(child_env, '/bin/sh', '-c', cmd, stdin_data: 'not json', chdir: @root)
            # Unreadable input fails the script; PreToolUse's line turns a failure
            # into a block only for a bound session.
            assert_equal(cmd == pre_cmd ? 0 : 1, st.exitstatus)
            input = JSON.generate('hook_event_name' => 'PreToolUse', 'session_id' => 'u9',
                                  'tool_name' => 'mcp__kairos-chain__agent_status', 'tool_input' => {})
            out, _, st = Open3.capture3(child_env, '/bin/sh', '-c', cmd, stdin_data: input, chdir: @root)
            assert_equal 0, st.exitstatus
            assert_equal 'u9', decision_of(out).dig('updatedInput', '_session_id')
          end
        end
      end
    end
  end
end
