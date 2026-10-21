# frozen_string_literal: true

# Verification of the fixes after implementation review R2, group "sessions":
# resume and take-over, the old session's refusals, SessionStart's offer, the
# session's project as agent_start's default repository (two projects sharing
# one data directory), AskUserQuestion / ExitPlanMode after an ending, the
# operator's "/agent <request>" prompt, and the plugin's fail-closed
# PreToolUse command line.
#
# Each fix is driven in the host's own order around the agent tools
# (PreToolUse → the service call → PostToolUse → Stop), in process and, where
# the host runs it, through hooks/agent_hook.rb (and the plugin's command
# line) as a subprocess with HOME, KAIROS_DATA_DIR and CLAUDE_PROJECT_DIR in
# the tmpdir. The stand-in is scripted; no real claude -p runs.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'fileutils'
require 'rbconfig'
require 'securerandom'
require_relative '../lib/agent/service'
require_relative 'test_agent1_hooks_service'

# The harness is reused; its own tests run in their own file.
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1HooksService)

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R2Sessions < TestAgent1HooksService
        TestAgent1HooksService.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }

        SKILLSET = File.expand_path('..', __dir__)
        HOOK = File.join(SKILLSET, 'hooks', 'agent_hook.rb')
        HOOKS_JSON = File.join(SKILLSET, 'plugin', 'hooks.json')
        ENV_KEYS = %w[KAIROS_AGENT_GLOBAL CLAUDE_PROJECT_DIR GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].freeze

        def setup
          @saved_env = ENV_KEYS.to_h { |k| [k, ENV.fetch(k, nil)] }
          # The in-process hooks read CLAUDE_PROJECT_DIR; a test sets it when it
          # plays a host that names the project.
          ENV.delete('CLAUDE_PROJECT_DIR')
          super
          @home = File.join(@root, 'home')
          FileUtils.mkdir_p(@home)
          File.write(File.join(@root, 'gitconfig'), '')
          ENV['GIT_CONFIG_GLOBAL'] = File.join(@root, 'gitconfig')
          ENV['GIT_CONFIG_NOSYSTEM'] = '1'
          @t2 = File.join(@root, 'transcript_s2.jsonl')
          File.write(@t2, '')
          @others = []
        end

        def teardown
          Run.all(@paths).each { |r| FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', r.id)) } if @paths && File.directory?(@root)
          @others.each { |d| FileUtils.rm_rf(d) }
          super
          @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
        end

        # --- harness --------------------------------------------------------------

        # Another directory beside the first project (its own tmpdir).
        def other_dir(name)
          d = File.realpath(Dir.mktmpdir(name))
          @others << d
          d
        end

        def design_args(goal = 'design the thing', glob = 'log/thing_design_v*.md')
          { 'goal' => goal, 'template' => 'design_only', 'design_glob' => glob }
        end

        def verdict_of(out)
          out&.dig('hookSpecificOutput', 'permissionDecision')
        end

        def reason_of(out)
          out&.dig('hookSpecificOutput', 'permissionDecisionReason').to_s
        end

        def context_of(out)
          out&.dig('hookSpecificOutput', 'additionalContext').to_s
        end

        # In-process PreToolUse, as the host sends it.
        def pre_in(sid, tool, tool_input = nil, cwd: @root, agent_id: nil, **given)
          tool_input ||= given
          input = { 'session_id' => sid, 'tool_name' => tool, 'tool_input' => tool_input, 'cwd' => cwd,
                    'tool_use_id' => "tu_#{SecureRandom.hex(3)}" }
          input['agent_id'] = agent_id if agent_id
          hooks.handle('PreToolUse', input)
        end

        # One agent tool call in the host's order: PreToolUse (the hooks name the
        # session and its project), the tool, then PostToolUse with its reply.
        # The PostToolUse output is kept in @post.
        def host_call(sid, tool, args, cwd: @root, transcript: @transcript)
          pre = hooks.handle('PreToolUse', 'session_id' => sid, 'tool_name' => "mcp__kairos-chain__#{tool}",
                                           'tool_input' => args, 'cwd' => cwd)
          assert_equal 'allow', verdict_of(pre), pre.inspect
          input = pre.dig('hookSpecificOutput', 'updatedInput')
          out = case tool
                when 'agent_start' then service.start(input)
                when 'agent_stop' then service.stop(input)
                when 'agent_advance' then service.advance(input)
                when 'agent_finish' then service.finish(input)
                when 'agent_items' then service.items(input)
                when 'agent_status' then service.status(input)
                end
          @post = hooks.handle('PostToolUse', 'session_id' => sid, 'tool_name' => "mcp__kairos-chain__#{tool}",
                                              'transcript_path' => transcript, 'cwd' => cwd, 'tool_input' => input,
                                              'tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }])
          out
        end

        def started(sid, args, cwd: @root, transcript: @transcript)
          out = host_call(sid, 'agent_start', args, cwd: cwd, transcript: transcript)
          assert_equal 'started', out['status'], out.inspect
          Run.load(@paths, out['run_id'])
        end

        def age_guard(sid, seconds)
          t = Time.now - seconds
          File.utime(t, t, File.join(@paths.guard_seen_dir, Run.safe(sid)))
        end

        def binding_file(sid)
          File.join(@paths.bindings_dir, Run.safe(sid))
        end

        # s1 holds a design run; its guard has been quiet for eleven minutes;
        # s2 takes the run up in the host's order.
        def taken_over_run
          run = start_design_run
          age_guard('s1', 11 * 60)
          out = host_call('s2', 'agent_start', { 'resume' => run.id }, transcript: @t2)
          assert_equal 'resumed', out['status'], out.inspect
          assert Run.taken_over?(@paths, 's1')
          run.reload
        end

        # hooks/agent_hook.rb as the host runs it: hook input on stdin, from the
        # project directory, every location in the tmpdir.
        def hook_script(input = nil, project: @root, data: @data, script: HOOK, **given)
          input ||= given
          env = { 'HOME' => @home, 'KAIROS_DATA_DIR' => data, 'CLAUDE_PROJECT_DIR' => project,
                  'KAIROS_AGENT_GLOBAL' => ENV['KAIROS_AGENT_GLOBAL'], 'KAIROS_MCP_LIB' => nil,
                  'GIT_CONFIG_GLOBAL' => ENV['GIT_CONFIG_GLOBAL'], 'GIT_CONFIG_NOSYSTEM' => '1' }
          out, err, st = Open3.capture3(env, RbConfig.ruby, script, stdin_data: JSON.generate(input), chdir: project)
          [out.strip.empty? ? nil : JSON.parse(out), err, st.exitstatus]
        end

        def pre_script(sid, tool, tool_input = nil, project: @root, cwd: project, agent_id: nil, **given)
          tool_input ||= given
          input = { 'hook_event_name' => 'PreToolUse', 'session_id' => sid, 'tool_name' => tool,
                    'tool_input' => tool_input, 'cwd' => cwd, 'tool_use_id' => "tu_#{SecureRandom.hex(3)}" }
          input['agent_id'] = agent_id if agent_id
          hook_script(input, project: project)
        end

        # The host's record of a command the operator typed with arguments:
        # origin human, no prompt source, the command tags only.
        def typed_command(args, prompt_id, name: '/agent', transcript: @transcript, extra: {})
          content = "<command-message>#{name.delete_prefix('/')}</command-message>\n" \
                    "<command-name>#{name}</command-name>\n<command-args>#{args}</command-args>"
          File.open(transcript, 'a') do |f|
            f.puts(JSON.generate({ 'type' => 'user', 'promptId' => prompt_id, 'origin' => { 'kind' => 'human' },
                                   'message' => { 'role' => 'user', 'content' => content } }.merge(extra)))
          end
        end

        def git!(dir, *args)
          system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', *args, exception: true,
                                                                                       out: File::NULL, err: File::NULL)
        end

        def git_repo!(dir, files)
          system('git', 'init', '-q', '-b', 'main', dir, exception: true)
          { '.gitignore' => ".kairos/\nlog/\n.claude/\n" }.merge(files).each do |rel, body|
            p = File.join(dir, rel)
            FileUtils.mkdir_p(File.dirname(p))
            File.write(p, body)
          end
          git!(dir, 'add', '-A')
          git!(dir, 'commit', '-q', '-m', 'base')
        end

        QUESTION = { 'questions' => [{ 'question' => '何席?', 'header' => '席', 'multiSelect' => false,
                                       'options' => [{ 'label' => '7 席' }, { 'label' => '8 席' }] }] }.freeze
        PLAN = { 'plan' => "1. write v0.2\n2. review it" }.freeze

        # --- resume while the run's own session is live -----------------------------

        def test_resume_is_refused_while_the_runs_session_is_live_and_taken_up_once_it_is_quiet
          run = start_design_run
          pre_in('s1', 'Read', 'file_path' => @transcript)

          offered = hooks.handle('SessionStart', 'session_id' => 's2', 'source' => 'startup')
          refute_includes context_of(offered), run.id, 'a run whose session is live is not offered to another session'
          out = host_call('s2', 'agent_start', { 'resume' => run.id }, transcript: @t2)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'live in another session'
          assert_nil @post, 'a refused resume binds nothing at PostToolUse'
          assert_equal 's1', run.reload.bound_session
          assert_equal run.id, File.read(binding_file('s1')).strip
          refute File.exist?(binding_file('s2'))
          refute Run.taken_over?(@paths, 's1')

          path = File.join(@root, 'log', 'thing_design_v0.1.md')
          assert_equal 'allow', verdict_of(pre_in('s1', 'Write', 'file_path' => path, 'content' => 'x')),
                       's1 keeps its run after the refused resume'

          age_guard('s1', 9 * 60)
          out = host_call('s2', 'agent_start', { 'resume' => run.id }, transcript: @t2)
          assert_equal 'refused', out['status'], 'a guard seen nine minutes ago is still live (ten-minute window)'

          age_guard('s1', 11 * 60)
          offered = hooks.handle('SessionStart', 'session_id' => 's3', 'source' => 'startup')
          assert_includes context_of(offered), "agent_start(resume: '#{run.id}')", 'once quiet, the run is offered'
          out = host_call('s2', 'agent_start', { 'resume' => run.id }, transcript: @t2)
          assert_equal 'resumed', out['status'], out.inspect
          assert_equal 's1', out['taken_over_from']
          assert_includes context_of(@post), "Run #{run.id} is bound to this session"
          assert_equal run.id, Run.bound_to(@paths, 's2')&.id
          assert Run.taken_over?(@paths, 's1')
          assert_nil Run.bound_to(@paths, 's1')
          assert_equal 'block', hooks.handle('Stop', 'session_id' => 's2', 'last_assistant_message' => 'Taken up.')&.dig('decision'),
                       'the new session carries the run on'
          assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Wrote the outline.'),
                     'the old session is not pushed on'
        end

        def test_an_ended_run_still_held_by_its_live_session_is_not_taken_until_the_operator_releases_it
          run = start_design_run
          out = host_call('s1', 'agent_stop', { 'run_id' => run.id, 'reason' => 'enough for today' })
          assert_equal 'stopped', out['status'], out.inspect
          assert_equal run.id, Run.bound_to(@paths, 's1')&.id, 'the guard stays after the ending'
          refused = host_call('s2', 'agent_start', { 'resume' => run.id }, transcript: @t2)
          assert_equal 'refused', refused['status'], 'its own session is live and still holds it'

          typed('今日はここまでで', 'p-rel')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '今日はここまでで', 'prompt_id' => 'p-rel',
                                           'transcript_path' => @transcript)
          pre_in('s1', 'Read', 'file_path' => @transcript)
          assert_nil Run.bound_to(@paths, 's1'), "the operator's typed words release the ended run"

          out = host_call('s2', 'agent_start', { 'resume' => run.id }, transcript: @t2)
          assert_equal 'resumed', out['status'], 'released, the run is no live session\'s'
          assert_nil out['taken_over_from']
          refute Run.taken_over?(@paths, 's1'), 'nothing was taken from s1'
        end

        # --- the old session after a take-over ---------------------------------------

        def test_after_a_takeover_the_old_session_refuses_what_acts_through_the_hook_script_and_reads_pass
          run = taken_over_run
          n = run.journal.entries.size
          acting = {
            'Bash' => { 'command' => 'echo hi > /dev/null' },
            'Write' => { 'file_path' => File.join(@root, 'log', 'thing_design_v0.2.md'), 'content' => 'x' },
            'Edit' => { 'file_path' => File.join(@root, 'log', 'notes.md'), 'old_string' => 'a', 'new_string' => 'b' },
            'MultiEdit' => { 'file_path' => File.join(@root, 'log', 'notes.md'),
                             'edits' => [{ 'old_string' => 'a', 'new_string' => 'b' }] },
            'NotebookEdit' => { 'notebook_path' => File.join(@root, 'log', 'n.ipynb'), 'new_source' => 'x' },
            'mcp__kairos-chain__knowledge_update' => { 'name' => 'k', 'content' => 'x' },
            'mcp__kairos-chain__context_save' => { 'name' => 'n', 'content' => 'x' },
            'Agent' => { 'prompt' => 'carry on', 'subagent_type' => 'general-purpose' },
            'WebFetch' => { 'url' => 'https://example.com', 'prompt' => 'x' }
          }
          acting.each do |tool, ti|
            out, err, code = pre_script('s1', tool, ti)
            assert_equal 0, code, "#{tool}: #{err}"
            assert_equal 'deny', verdict_of(out), "#{tool} acts: #{out.inspect} #{err}"
            assert_includes reason_of(out), 'taken over', tool
          end
          out, = pre_script('s1', 'Write', { 'file_path' => File.join(@root, 'log', 'sub.md'), 'content' => 'x' },
                            agent_id: 'a1b2c3d4e5f6')
          assert_equal 'deny', verdict_of(out), "the old session's subagents are refused too"

          { 'Read' => { 'file_path' => @transcript }, 'Grep' => { 'pattern' => 'x', 'path' => @root },
            'Glob' => { 'pattern' => '*.md' }, 'LS' => { 'path' => @root } }.each do |tool, ti|
            out, err, code = pre_script('s1', tool, ti)
            assert_equal 0, code, err
            assert_nil out, "#{tool} only reads: #{err}"
          end
          out, = pre_script('s1', 'mcp__kairos-chain__agent_advance', { 'run_id' => run.id })
          input = out.dig('hookSpecificOutput', 'updatedInput')
          assert_equal 's1', input['_session_id'], 'the agent tools still learn the session'
          assert_equal 'refused', service.advance(input)['status'], 'the old session no longer advances the run'

          %w[Stop SubagentStop].each do |ev|
            out, err, code = hook_script('hook_event_name' => ev, 'session_id' => 's1', 'agent_id' => 'a1b2c3d4e5f6',
                                         'last_assistant_message' => 'Wrote the outline. 次はどちらにしますか？')
            assert_equal 0, code, err
            assert_nil out, "#{ev} is silent in the old session"
          end
          out, = hook_script('hook_event_name' => 'PostToolUse', 'session_id' => 's1', 'tool_name' => 'Bash',
                             'tool_input' => { 'command' => 'ls' }, 'tool_response' => { 'stdout' => '' })
          assert_nil out
          run.reload
          assert_equal n, run.journal.entries.size, "nothing from s1 lands in the run's journal"
          assert_equal 's2', run.bound_session
          assert_equal 'running', run.status
          assert Run.taken_over?(@paths, 's1')

          typed('こっちはもういいです', 'p_s1')
          out, err, code = hook_script('hook_event_name' => 'UserPromptSubmit', 'session_id' => 's1',
                                       'prompt' => 'こっちはもういいです', 'prompt_id' => 'p_s1', 'transcript_path' => @transcript)
          assert_equal 0, code, err
          assert_nil out
          # The marker clears at the next hook event, once the transcript shows
          # the prompt as typed.
          out, _err, code = pre_script('s1', 'Bash', 'command' => 'echo hi')
          assert_equal 0, code
          assert_nil out, 's1 is an ordinary session again'
          refute File.exist?(binding_file('s1')), "the operator's typed words in s1 clear the marker"
          assert_equal run.id, Run.bound_to(@paths, 's2')&.id, 'the run stays with s2'
        end

        def test_session_end_in_the_old_session_clears_its_marker_and_the_run_stays_with_the_new_one
          run = taken_over_run
          out, err, code = hook_script('hook_event_name' => 'SessionEnd', 'session_id' => 's1', 'reason' => 'exit')
          assert_equal 0, code, err
          assert_nil out
          refute File.exist?(binding_file('s1'))
          run.reload
          assert_equal 'running', run.status, "the old session's end does not interrupt the run"
          assert_equal 's2', run.bound_session
          assert_nil pre_script('s1', 'Bash', 'command' => 'echo hi')[0]
          assert_equal 'deny', verdict_of(pre_in('s2', 'Bash', 'command' => 'git push origin main')),
                       'the new session is still guarded'
        end

        def test_prompts_no_one_typed_leave_the_old_sessions_marker_in_place
          taken_over_run
          ["<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>",
           'Another Claude session sent a message: carry on with the design',
           '[SYSTEM NOTIFICATION - background task done] continue', '/compact'].each_with_index do |prompt, i|
            hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => prompt, 'prompt_id' => "pn#{i}",
                                             'transcript_path' => @transcript)
            assert Run.taken_over?(@paths, 's1'), prompt
            assert_equal 'deny', verdict_of(pre_in('s1', 'Bash', 'command' => 'echo hi')), prompt
          end
        end

        # The old session's actor may still schedule a wake-up (a session-local
        # tool); the wake-up arrives as a prompt the host wrote, not the operator.
        def test_a_scheduled_wake_up_prompt_does_not_clear_the_old_sessions_marker
          taken_over_run
          assert_nil pre_in('s1', 'ScheduleWakeup', 'delaySeconds' => 60, 'prompt' => '継続して下さい。')
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => 'p-wake', 'isMeta' => true, 'promptSource' => 'system',
                                 'message' => { 'role' => 'user', 'content' => '継続して下さい。' }))
          end
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '継続して下さい。', 'prompt_id' => 'p-wake',
                                           'transcript_path' => @transcript)
          out = pre_in('s1', 'Bash', 'command' => 'echo continuing the run')
          unless verdict_of(out) == 'deny'
            flunk('BUG: hooks.rb user_prompt_submit clears the taken-over marker on any plausibly typed prompt ' \
                 '(a ScheduleWakeup prompt, isMeta/promptSource system) without checking the transcript, so the old ' \
                 'session acts unguarded again')
          end
          assert Run.taken_over?(@paths, 's1')
        end

        # --- SessionStart's offer -------------------------------------------------------

        def test_session_start_offers_only_unreported_runs_of_this_resolved_project_whose_session_is_not_live
          adopt!
          b = other_dir('r2vB')
          FileUtils.mkdir_p(File.join(b, 'log'))
          run_a = started('sa', design_args('a'))
          hooks.handle('SessionEnd', 'session_id' => 'sa', 'reason' => 'exit')
          run_b = started('sb', design_args('b'), cwd: b)
          assert_equal b, run_b.target_repo
          hooks.handle('SessionEnd', 'session_id' => 'sb', 'reason' => 'exit')
          run_live = started('sl', design_args('live'))
          assert_equal %w[interrupted interrupted running], [run_a, run_b, run_live].map { |r| r.reload.status }

          link = File.join(other_dir('r2vL'), 'projA')
          File.symlink(@root, link)
          out, err, code = hook_script({ 'hook_event_name' => 'SessionStart', 'session_id' => 'sn', 'source' => 'startup',
                                         'cwd' => link }, project: link)
          assert_equal 0, code, err
          text = context_of(out)
          assert_includes text, "agent_start(resume: '#{run_a.id}')", 'the project is compared resolved'
          refute_includes text, run_b.id, "another project's run is not offered"
          refute_includes text, run_live.id, 'a run whose session is live is not offered'

          out, err, = hook_script({ 'hook_event_name' => 'SessionStart', 'session_id' => 'sm', 'source' => 'startup',
                                    'cwd' => b }, project: b)
          text = context_of(out)
          assert_includes text, run_b.id, err
          refute_includes text, run_a.id
          refute_includes text, run_live.id

          age_guard('sl', 11 * 60)
          out, = hook_script({ 'hook_event_name' => 'SessionStart', 'session_id' => 'so', 'source' => 'startup',
                               'cwd' => link }, project: link)
          assert_includes context_of(out), run_live.id, 'once its session is quiet, the run is offered'
          out, = hook_script({ 'hook_event_name' => 'SessionStart', 'session_id' => 'sp', 'source' => 'startup',
                               'cwd' => b }, project: b)
          refute_includes context_of(out), run_live.id, 'but only in its own project'
        end

        # --- the session's project is the default repository ----------------------------------

        def test_the_hooks_name_the_sessions_project_and_agent_start_works_there_in_process
          adopt!
          b = other_dir('r2vB')
          FileUtils.mkdir_p(File.join(b, 'log'))
          args = design_args('b design', 'log/b_design_v*.md')
          input = pre_in('sb', 'mcp__kairos-chain__agent_start', args, cwd: b).dig('hookSpecificOutput', 'updatedInput')
          assert_equal b, input['_project_dir'], "without CLAUDE_PROJECT_DIR the call's cwd names the project"
          ENV['CLAUDE_PROJECT_DIR'] = b
          input = pre_in('sb', 'mcp__kairos-chain__agent_start', args, cwd: File.join(b, 'log'))
                  .dig('hookSpecificOutput', 'updatedInput')
          assert_equal b, input['_project_dir'], "the host's project directory wins over the call's cwd"

          run = started('sb', args, cwd: File.join(b, 'log'))
          assert_equal b, run.target_repo, 'the session\'s project, not the data directory\'s parent'
          assert_includes context_of(@post), "Main checkout: #{b}."
          stop = hooks.handle('Stop', 'session_id' => 'sb', 'last_assistant_message' => 'Started.')
          assert_includes stop['reason'], "in the main checkout (#{b})"

          path = File.join(b, 'log', 'b_design_v0.1.md')
          assert_equal 'allow', verdict_of(pre_in('sb', 'Write', { 'file_path' => path, 'content' => 'x' }, cwd: b))
          File.write(path, "# b v0.1\n")
          stray = File.join(@root, 'log', 'b_design_v0.1.md')
          assert_equal 'deny', verdict_of(pre_in('sb', 'Write', { 'file_path' => stray, 'content' => 'x' }, cwd: b)),
                       "the data directory's parent is not this run's checkout"
          adv = host_call('sb', 'agent_advance', { 'run_id' => run.id }, cwd: b)
          assert_equal 'phase_ended', adv['status'], adv.inspect
          assert File.directory?(File.join(b, 'log', 'agent_runs', run.id)), 'the report directory is in the project'
          refute File.exist?(File.join(@root, 'log', 'agent_runs', run.id))
        end

        def test_two_projects_sharing_one_data_dir_a_dev_cycle_starts_in_the_sessions_project_through_the_hook_script
          skip 'sandbox-exec unavailable' unless Confinement.available?
          adopt!
          b = other_dir('r2vB')
          git_repo!(b, 'test/test_ok.rb' => "exit 0\n", 'lib/b.rb' => "B = 1\n")
          tb = File.join(b, 'transcript_b.jsonl')
          File.write(tb, '')
          args = { 'goal' => 'b feature', 'template' => 'dev_cycle', 'design_glob' => 'log/b_design_v*.md',
                   'tests' => 'test' }

          out, err, code = hook_script({ 'hook_event_name' => 'PreToolUse', 'session_id' => 'sb', 'cwd' => b,
                                         'tool_name' => 'mcp__kairos-chain__agent_start', 'tool_input' => args,
                                         'transcript_path' => tb }, project: b)
          assert_equal 0, code, err
          input = out.dig('hookSpecificOutput', 'updatedInput')
          assert_equal b, input['_project_dir']
          # The service as Boot builds it: its project root is the data directory's parent (@root).
          res = service.start(input)
          assert_equal 'started', res['status'], res.inspect
          run = Run.load(@paths, res['run_id'])
          assert_equal b, run.target_repo
          assert run.worktree.start_with?(File.join(b, '.claude', 'worktrees') + '/'), run.worktree
          branches, = Open3.capture2('git', '-C', b, 'branch', '--list', 'agent-run/*')
          refute_empty branches.strip, 'the run branch is in the session\'s project'
          refute File.exist?(File.join(@root, '.claude', 'worktrees')), 'nothing is created under the data directory\'s parent'
          assert_equal File.join(run.worktree, 'test', 'test_ok.rb'), run.pinned['implement']['tests'].keys.first

          post, err, code = hook_script({ 'hook_event_name' => 'PostToolUse', 'session_id' => 'sb', 'cwd' => b,
                                          'tool_name' => 'mcp__kairos-chain__agent_start', 'tool_input' => input,
                                          'transcript_path' => tb,
                                          'tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(res) }] }, project: b)
          assert_equal 0, code, err
          assert_includes context_of(post), "Run #{run.id} is bound to this session"

          path = File.join(b, 'log', 'b_design_v0.1.md')
          out, err, = pre_script('sb', 'Write', { 'file_path' => path, 'content' => 'x' }, project: b)
          assert_equal 'allow', verdict_of(out), "a new design file in the session's project: #{out.inspect} #{err}"
          File.write(path, "# b v0.1\n")
          out, = pre_script('sb', 'Write', { 'file_path' => File.join(@root, 'log', 'b_design_v0.1.md'), 'content' => 'x' },
                            project: b)
          assert_equal 'deny', verdict_of(out), "the data directory's parent is outside this run"
          out, = pre_script('sb', 'Edit', { 'file_path' => File.join(run.worktree, 'lib', 'b.rb'), 'old_string' => 'B = 1',
                                            'new_string' => 'B = 2' }, project: b)
          assert_equal 'allow', verdict_of(out), 'the worktree in the session\'s project is the run\'s'
          adv = service.advance('run_id' => run.id, '_session_id' => 'sb')
          assert_equal 'phase_ended', adv['status'], adv.inspect
        end

        # --- decision tools after an ending -------------------------------------------------

        def test_ask_user_question_and_exit_plan_mode_after_a_stop_are_left_to_the_host
          run = start_design_run
          @script['question'] = { 'answer' => '8 席', 'class' => 'decided' }
          assert_equal 'allow', verdict_of(pre_in('s1', 'AskUserQuestion', QUESTION)), 'while running the stand-in answers'

          out = host_call('s1', 'agent_stop', { 'run_id' => run.id, 'reason' => 'enough' })
          assert_equal 'stopped', out['status'], out.inspect
          assert_equal 'block', hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Stopped.')&.dig('decision')
          asked = @stand_in.asked.size
          decisions = run.reload.decisions.size
          items = run.items.size

          assert_nil pre_in('s1', 'AskUserQuestion', QUESTION), 'the host asks the operator'
          assert_nil pre_in('s1', 'ExitPlanMode', PLAN), 'the host shows the plan to the operator'
          # The hook script's stand-in would need llm_client (absent here): a call would fail and deny.
          [['AskUserQuestion', QUESTION], ['ExitPlanMode', PLAN]].each do |tool, ti|
            out, err, code = pre_script('s1', tool, ti)
            assert_equal 0, code, err
            assert_nil out, "#{tool}: #{err}"
          end
          assert_equal asked, @stand_in.asked.size, 'the stand-in is not asked after the ending'
          run.reload
          assert_equal decisions, run.decisions.size, 'no stand-in decision is recorded after the ending'
          assert_equal items, run.items.size, 'nothing is queued for the operator, who is asked directly'
          assert_equal 'deny', verdict_of(pre_in('s1', 'mcp__kairos-chain__knowledge_update', 'name' => 'x')),
                       'the guard itself stays until the operator speaks'
        end

        def test_after_a_hazard_ending_and_after_finish_the_decision_tools_are_left_to_the_host
          run = start_design_run
          @script['hazard'] = { 'answer' => 'in_world', 'class' => 'decided' }
          out = hooks.handle('Stop', 'session_id' => 's1',
                                     'last_assistant_message' => 'The API key was printed to the public log and pushed.')
          assert_equal 'block', out['decision']
          assert_equal 'ended', run.reload.status
          n = run.decisions.size
          asked = @stand_in.asked.size
          assert_nil pre_in('s1', 'AskUserQuestion', QUESTION)
          assert_nil pre_in('s1', 'ExitPlanMode', PLAN)
          assert_equal n, run.reload.decisions.size
          assert_equal asked, @stand_in.asked.size

          material = JSON.parse(File.read(service.status('run_id' => run.id, 'report_material' => true)
                                                 .dig('report_material', 'material_path')))
          ids = (material['decisions'].map { |d| d['id'] } + material['items'].map { |i| i['id'] } +
                 material['phases'].map { |p| p['name'] }).join(' ')
          write_deck(run.reload, ids)
          fin = host_call('s1', 'agent_finish', { 'run_id' => run.id })
          assert_equal 'finished', fin['status'], fin.inspect
          assert_equal run.id, Run.bound_to(@paths, 's1')&.id
          n = run.reload.decisions.size
          assert_nil pre_in('s1', 'AskUserQuestion', QUESTION), 'after finish too'
          assert_nil pre_in('s1', 'ExitPlanMode', PLAN)
          assert_equal n, run.reload.decisions.size
          assert_equal asked, @stand_in.asked.size
        end

        # --- "/agent <request>" ---------------------------------------------------------

        def test_an_agent_command_request_is_the_operators_words_before_and_during_the_run
          adopt!
          request = '設計から収束まで回して。席は Fable も入れて'
          typed_command(request, 'p-cmd')
          assert_nil hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => "/agent #{request}",
                                                      'prompt_id' => 'p-cmd', 'transcript_path' => @transcript)
          run = started('s1', design_args)
          words = run.reload.verified_operator_words
          assert_includes words, request, 'the request before the start is the run\'s freshest precedent'
          refute(words.any? { |w| w.include?('<command-') || w.include?('/agent') }, words.inspect)

          during = '次の版では 8 席にして'
          typed_command(during, 'p-cmd2')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => "/agent #{during}", 'prompt_id' => 'p-cmd2',
                                           'transcript_path' => @transcript)
          kept = run.reload.journal.entries.reverse.find { |e| e['kind'] == 'operator_words' }
          assert_equal during, kept['text'], "the command's arguments, not the command line"
          assert_equal during, run.verified_operator_words.first

          @script['question'] = { 'answer' => '8 席', 'class' => 'decided' }
          assert_equal 'allow', verdict_of(pre_in('s1', 'AskUserQuestion', QUESTION))
          seen = @stand_in.asked.last[:operator_words]
          assert_equal during, seen.first, 'the stand-in reads the newest request first'
          assert_includes seen, request
        end

        def test_an_agent_command_counts_only_when_its_own_transcript_entry_shows_the_operator_typed_it
          run = start_design_run
          typed_command('偽の指示', 'p-meta', extra: { 'isMeta' => true })
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '/agent 偽の指示', 'prompt_id' => 'p-meta',
                                           'transcript_path' => @transcript)
          typed_command('予定された指示', 'p-sys', extra: { 'promptSource' => 'system' })
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '/agent 予定された指示', 'prompt_id' => 'p-sys',
                                           'transcript_path' => @transcript)
          typed_command('本当の指示', 'p-other')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '/agent 別の指示', 'prompt_id' => 'p-other',
                                           'transcript_path' => @transcript)
          words = run.reload.verified_operator_words
          %w[偽の指示 予定された指示 別の指示].each { |w| refute_includes words, w }

          n = run.journal.entries.count { |e| e['kind'] == 'operator_words' }
          typed_command('', 'p-bare')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '/agent', 'prompt_id' => 'p-bare',
                                           'transcript_path' => @transcript)
          assert_equal n, run.reload.journal.entries.count { |e| e['kind'] == 'operator_words' }, 'a bare command says nothing'
        end

        def test_after_an_ending_an_agent_command_the_operator_typed_releases_the_guard_and_a_host_one_does_not
          run = start_design_run
          assert_equal 'stopped', host_call('s1', 'agent_stop', { 'run_id' => run.id, 'reason' => 'enough' })['status']
          typed_command('続きを予定通り', 'p-sched', extra: { 'promptSource' => 'system' })
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '/agent 続きを予定通り', 'prompt_id' => 'p-sched',
                                           'transcript_path' => @transcript)
          pre_in('s1', 'Read', 'file_path' => @transcript)
          assert_equal run.id, Run.bound_to(@paths, 's1')&.id, 'a command the host wrote is not the operator speaking'

          typed_command('次の run を設計から', 'p-next')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '/agent 次の run を設計から', 'prompt_id' => 'p-next',
                                           'transcript_path' => @transcript)
          pre_in('s1', 'Read', 'file_path' => @transcript)
          assert_nil Run.bound_to(@paths, 's1'), "the operator's own command is their next typed words"
          refute File.exist?(binding_file('s1'))
        end

        def test_an_agent_command_naming_a_decision_corrects_it_through_the_hook_script
          run = start_design_run
          @script['question'] = { 'answer' => '7 席', 'class' => 'decided' }
          assert_equal 'allow', verdict_of(pre_in('s1', 'AskUserQuestion', QUESTION))
          d = run.reload.decisions.last['id']
          words = "#{d}は違う、8 席にして"
          typed_command(words, 'p-corr')
          out, err, code = hook_script('hook_event_name' => 'UserPromptSubmit', 'session_id' => 's1',
                                       'prompt' => "/agent #{words}", 'prompt_id' => 'p-corr', 'transcript_path' => @transcript)
          assert_equal 0, code, err
          assert_nil out
          kept = File.readlines(@paths.operator_words_path).map { |l| JSON.parse(l) }.last
          assert_equal words, kept['text'], 'the reference is kept as the operator\'s words'
          res = host_call('s1', 'agent_items', { 'action' => 'correct', 'run_id' => run.id, 'ref' => d })
          assert_equal 'recorded', res['status'], res.inspect
          stored = Precedents.new(@paths.precedents_dir).all.last
          assert_equal 'correction', stored['kind']
          assert_equal words, stored['words']
        end

        # --- the plugin's fail-closed PreToolUse command line ----------------------------------

        def pre_command
          JSON.parse(File.read(HOOKS_JSON)).dig('hooks', 'PreToolUse', 0, 'hooks', 0)
        end

        # The command line as the host runs it, hook input on stdin. The host
        # passes its own environment; its locale (UTF-8 here) is kept unless a
        # test asks for none.
        def run_pre_command(sid, path:, stdin: nil, tool: 'Bash', tool_input: { 'command' => 'ls' }, shell: '/bin/sh',
                            locale: true)
          stdin ||= JSON.generate('session_id' => sid, 'transcript_path' => @transcript, 'cwd' => @root,
                                  'hook_event_name' => 'PreToolUse', 'tool_name' => tool, 'tool_input' => tool_input)
          env = { 'HOME' => @home, 'KAIROS_DATA_DIR' => @data, 'CLAUDE_PROJECT_DIR' => @root,
                  'KAIROS_AGENT_GLOBAL' => ENV['KAIROS_AGENT_GLOBAL'], 'PATH' => path }
          env['LANG'] = locale ? (ENV['LANG'] || 'en_US.UTF-8') : nil
          env['LC_ALL'] = locale ? (ENV['LC_ALL'] || ENV['LANG'] || 'en_US.UTF-8') : nil
          out, err, st = Open3.capture3(env, shell, '-c', pre_command['command'], stdin_data: stdin, chdir: @root,
                                                                                  unsetenv_others: true)
          [out, err, st.exitstatus]
        end

        # A PATH with the shell's own tools and no ruby at all.
        def path_without_ruby
          dir = File.join(@root, 'noruby')
          FileUtils.mkdir_p(dir)
          %w[cat sed head].each do |t|
            src = %w[/bin /usr/bin].map { |d| File.join(d, t) }.find { |f| File.executable?(f) }
            File.symlink(src, File.join(dir, t)) if src && !File.exist?(File.join(dir, t))
          end
          dir
        end

        def ruby_path
          "#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin"
        end

        def install_skillset!
          installed = File.join(@data, 'skillsets', 'agent')
          FileUtils.mkdir_p(installed)
          FileUtils.cp_r(File.join(SKILLSET, 'hooks'), installed)
          FileUtils.cp_r(File.join(SKILLSET, 'lib'), installed)
          installed
        end

        def test_the_pre_tool_use_command_line_blocks_only_the_bound_session_when_ruby_is_missing
          assert_equal 'block', pre_command['onFailure']
          run = start_design_run
          install_skillset!
          noruby = path_without_ruby
          out, err, code = run_pre_command('s1', path: noruby)
          assert_equal 2, code, "no ruby while this session is bound: #{err}"
          assert_includes err, 'agent guard unavailable'
          assert_empty out
          out, err, code = run_pre_command('s9', path: noruby)
          assert_equal 0, code, "an unbound session goes on: #{err}"
          assert_empty out

          # The old session after a take-over is blocked as well, never let through.
          age_guard('s1', 11 * 60)
          assert_equal 'resumed', host_call('s2', 'agent_start', { 'resume' => run.id }, transcript: @t2)['status']
          assert Run.taken_over?(@paths, 's1')
          assert_equal 2, run_pre_command('s1', path: noruby)[2], 'the taken-over session is blocked'
          assert_equal 2, run_pre_command('s2', path: noruby)[2]

          # Without the script: the same.
          FileUtils.rm_rf(File.join(@data, 'skillsets', 'agent', 'hooks'))
          assert_equal 2, run_pre_command('s2', path: ruby_path)[2], 'no script while this session is bound'
          assert_equal 0, run_pre_command('s9', path: ruby_path)[2], 'no script, an unbound session goes on'
        end

        def test_the_pre_tool_use_command_line_with_a_failing_script_blocks_only_the_bound_session
          start_design_run
          installed = install_skillset!
          # The library cannot load: the script itself denies in the bound session.
          File.write(File.join(installed, 'lib', 'agent', 'hooks.rb'), "raise 'broken install'\n")
          out, err, code = run_pre_command('s1', path: ruby_path)
          assert_equal 0, code, err
          d = JSON.parse(out).fetch('hookSpecificOutput')
          assert_equal 'deny', d['permissionDecision'], 'a guard that cannot load refuses in the bound session'
          assert_includes d['permissionDecisionReason'], 'agent guard failed'
          out, err, code = run_pre_command('s9', path: ruby_path)
          assert_equal 0, code, err
          assert_empty out, 'an unbound session never loads the library'
          out, err, code = run_pre_command('s9', path: ruby_path, tool: 'mcp__kairos-chain__agent_status', tool_input: {})
          assert_equal 0, code, err
          assert_equal 's9', JSON.parse(out).dig('hookSpecificOutput', 'updatedInput', '_session_id'),
                       'the agent tools still learn the session without the library'

          # The script exits non-zero (input it cannot read).
          torn = '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":'
          _o, err, code = run_pre_command('s1', path: ruby_path, stdin: torn)
          assert_equal 2, code, "a failing script in the bound session blocks: #{err}"
          _o, err, code = run_pre_command('s9', path: ruby_path, stdin: torn.sub('"s1"', '"s9"'))
          assert_equal 0, code, "a failing script in an unbound session does not: #{err}"
        end

        def test_the_pre_tool_use_command_line_passes_a_working_guards_decisions_in_the_bound_session
          start_design_run
          install_skillset!
          design = File.join(@root, 'log', 'thing_design_v0.1.md')
          out, err, code = run_pre_command('s1', path: ruby_path, tool: 'Write',
                                                 tool_input: { 'file_path' => design, 'content' => 'x' })
          assert_equal 0, code, err
          assert_equal 'allow', JSON.parse(out).dig('hookSpecificOutput', 'permissionDecision'), "#{out} #{err}"
          policy = File.join(@paths.policies_dir, 'p2.rb')
          out, err, code = run_pre_command('s1', path: ruby_path, tool: 'Write',
                                                 tool_input: { 'file_path' => policy, 'content' => 'x' })
          assert_equal 0, code, err
          assert_equal 'deny', JSON.parse(out).dig('hookSpecificOutput', 'permissionDecision'),
                       'a governing write is refused through the command line'
          out, err, code = run_pre_command('s9', path: ruby_path, tool: 'Write',
                                                 tool_input: { 'file_path' => policy, 'content' => 'x' })
          assert_equal 0, code, err
          assert_empty out, 'an unbound session is left alone'
        end

        # A host started without locale variables (LANG, LC_ALL unset: Ruby reads
        # files as US-ASCII) still has a guard that decides; the run's journal
        # holds the operator's Japanese words from the start.
        def test_the_bound_sessions_guard_decides_without_a_utf8_locale
          start_design_run
          install_skillset!
          design = File.join(@root, 'log', 'thing_design_v0.1.md')
          out, err, code = run_pre_command('s1', path: ruby_path, tool: 'Write', locale: false,
                                                 tool_input: { 'file_path' => design, 'content' => 'x' })
          assert_equal 0, code, err
          d = JSON.parse(out).fetch('hookSpecificOutput')
          if d['permissionDecision'] == 'deny' && d['permissionDecisionReason'].to_s.include?('Encoding')
            flunk('BUG: lib/agent/journal.rb:59 (and Transcript/Hooks File.foreach) read JSONL in the default external ' \
                 "encoding; with no UTF-8 locale every tool of a bound session is denied: #{d['permissionDecisionReason']}")
          end
          assert_equal 'allow', d['permissionDecision'], out
        end
      end
    end
  end
end
