# frozen_string_literal: true

# Regression tests for the implementation review round R1, guard group:
# the guard and confinement (INV-2), lib/agent/guard.rb and confinement.rb.
# Every trigger is taken from the R1 findings. Real confined commands run in
# tmp git worktrees; nothing outside the tmpdir and the run's /tmp scratch is
# touched.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'socket'
require 'rbconfig'
require 'shellwords'
require 'securerandom'
require_relative '../lib/agent/service'
require_relative 'test_agent1_hooks_service'

# The harness is reused for a bound run; its own tests run in their own file.
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1HooksService)

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R1Guard < Minitest::Test
        FakeRun = Struct.new(:id, :worktree, :target_repo, :branch, :created_paths, :pinned, keyword_init: true)
        HOOK = File.expand_path('../hooks/agent_hook.rb', __dir__)

        def setup
          @root = File.realpath(Dir.mktmpdir('r1g'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@root, 'global_bound_sessions.txt')
          @data = File.join(@root, '.kairos')
          @paths = Paths.new(@data)
          FileUtils.mkdir_p(@paths.policies_dir)
          FileUtils.mkdir_p(File.join(@data, 'knowledge'))
          FileUtils.mkdir_p(File.join(@root, 'log'))
          File.write(File.join(@root, 'log', 'old_design.md'), 'someone else')
          @run_id = "run_r1g_#{SecureRandom.hex(4)}"
          @wt = File.join(@root, '.claude', 'worktrees', "agent-run-#{@run_id}")
          FileUtils.mkdir_p(@wt)
          @run = FakeRun.new(id: @run_id, worktree: @wt, target_repo: @root, branch: "agent-run/#{@run_id}",
                             created_paths: [], pinned: {})
          @guard = Guard.new(run: @run, paths: @paths, policy: policy, project_root: @root)
        end

        def teardown
          FileUtils.rm_rf(@root)
          FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', @run_id))
        end

        def policy
          DSL.parse_policy("policy \"p\" do\n  stand_in may: [:precedent]\n  spend default: { stand_in_calls: 5 }\nend\n")
        end

        def write(path, guard = @guard)
          guard.decide('Write', { 'file_path' => path, 'content' => 'x' })
        end

        def bash(cmd)
          @guard.decide('Bash', { 'command' => cmd })
        end

        def assert_refused(cmd)
          v = bash(cmd)
          assert v.refuse?, "#{cmd.inspect} should be refused, got #{v.kind}: #{v.reason}"
        end

        def assert_confined(cmd)
          v = bash(cmd)
          assert v.rewrite?, "#{cmd.inspect} should run confined, got #{v.kind}: #{v.reason}"
          assert_includes v.updated_input['command'], 'sandbox-exec'
        end

        def case_insensitive_fs?
          File.exist?(File.join(@root, 'LOG'))
        end

        # --- git, for the real confined runs ------------------------------------

        def git_env
          @git_env ||= begin
            home = File.join(@root, 'home')
            FileUtils.mkdir_p(home)
            File.write(File.join(home, '.gitconfig'), '')
            { 'HOME' => home, 'GIT_CONFIG_GLOBAL' => File.join(home, '.gitconfig'), 'GIT_CONFIG_NOSYSTEM' => '1',
              'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t', 'GIT_COMMITTER_NAME' => 't',
              'GIT_COMMITTER_EMAIL' => 't@t' }
          end
        end

        def git!(*args)
          out, st = Open3.capture2e(git_env, 'git', *args)
          assert st.success?, "git #{args.join(' ')}: #{out}"
          out.strip
        end

        # The layout Service#start makes: <repo>/.claude/worktrees/agent-run-<id>
        # on branch agent-run/<id>, plus a sibling run branch.
        def git_worktree!
          skip 'sandbox-exec unavailable' unless Confinement.available?
          FileUtils.rm_rf(@wt)
          git!('-C', @root, 'init', '-q', '-b', 'main')
          File.write(File.join(@root, '.gitignore'), ".kairos/\n.claude/\nlog/\nhome/\n")
          File.write(File.join(@root, 'README'), "r\n")
          git!('-C', @root, 'add', 'README', '.gitignore')
          git!('-C', @root, 'commit', '-q', '-m', 'init')
          git!('-C', @root, 'branch', 'agent-run/other')
          git!('-C', @root, 'worktree', 'add', '-q', '-b', @run.branch, @wt, 'HEAD')
          @admin = File.read(File.join(@wt, '.git'))[/gitdir:\s*(.+)/, 1].strip
        end

        # A command as the host would run it after the guard's rewrite.
        def confined(cmd)
          v = bash(cmd)
          assert v.rewrite?, "#{cmd.inspect} should run confined, got #{v.kind}: #{v.reason}"
          Open3.capture3(git_env, '/bin/bash', '-c', v.updated_input['command'])
        end

        # --- a bound run and the hook script as a subprocess ---------------------

        def with_bound_design_run
          t = TestAgent1HooksService.new('x')
          t.setup
          run = t.start_design_run
          yield t, run, t.instance_variable_get(:@root)
        ensure
          t&.teardown
        end

        def hook_pre_tool_use(troot, cmd)
          home = File.join(troot, 'home')
          FileUtils.mkdir_p(home)
          env = { 'HOME' => home, 'KAIROS_DATA_DIR' => File.join(troot, '.kairos'), 'CLAUDE_PROJECT_DIR' => troot,
                  'KAIROS_AGENT_GLOBAL' => File.join(troot, 'global_bound_sessions.txt') }
          input = { 'hook_event_name' => 'PreToolUse', 'session_id' => 's1', 'tool_name' => 'Bash',
                    'tool_use_id' => "tu_#{SecureRandom.hex(3)}", 'cwd' => troot, 'tool_input' => { 'command' => cmd } }
          out, err, st = Open3.capture3(env, RbConfig.ruby, HOOK, stdin_data: JSON.generate(input), chdir: troot)
          assert st.success?, err
          JSON.parse(out).fetch('hookSpecificOutput')
        end

        def operator_denies(troot, *rules)
          FileUtils.mkdir_p(File.join(troot, '.claude'))
          File.write(File.join(troot, '.claude', 'settings.json'), JSON.generate('permissions' => { 'deny' => rules }))
        end

        # --- placement by realpath ----------------------------------------------

        def test_a_symlink_in_the_worktree_is_placed_where_it_leads
          File.symlink(@data, File.join(@wt, '.kairos'))
          v = write(File.join(@wt, '.kairos', 'skillsets', 'agent', 'config', 'policies', 'p1.rb'))
          assert v.refuse?, "a link to the data dir carried a policy write across the line: #{v.reason}"
          assert_includes v.reason, 'governs runs'

          File.symlink(File.join(@root, 'log', 'old_design.md'), File.join(@wt, 'notes.md'))
          v = @guard.decide('Edit', { 'file_path' => File.join(@wt, 'notes.md'), 'old_string' => 'a', 'new_string' => 'b' })
          assert v.refuse?, "a link to a shared file was placed in the worktree: #{v.reason}"
          assert_includes v.reason, 'shared state'

          assert write(File.join(@wt, 'lib', 'a.rb')).allow?, 'an ordinary worktree file stays inside'
        end

        def test_a_case_variant_of_an_existing_path_is_placed_by_its_real_location
          skip 'case-sensitive filesystem' unless case_insensitive_fs?
          v = write(File.join(@root, '.KAIROS', 'knowledge', 'x.md'))
          assert v.refuse?, ".KAIROS was placed as a new file: #{v.kind} #{v.reason}"
          assert_includes v.reason, File.join(@data, 'knowledge', 'x.md'), 'placed by the real, lower-case location'
          assert write(File.join(@root, 'LOG', 'old_design.md')).refuse?, 'an existing shared file under LOG/ is shared'
          assert write(File.join(@root, '.CLAUDE', 'settings.json')).refuse?, '.CLAUDE is the governing .claude'
        end

        def test_a_dangling_symlink_in_the_worktree_is_placed_by_its_target
          skip 'sandbox-exec unavailable' unless Confinement.available?
          target = File.join(@paths.policies_dir, 'evil.rb')
          link = File.join(@wt, 'p.rb')
          # The actor makes the link with confined Bash: the link itself lies in the worktree.
          _o, err, st = confined("ln -s #{Shellwords.escape(target)} #{Shellwords.escape(link)}")
          assert st.success?, err
          assert File.symlink?(link)
          v = write(link)
          assert v.refuse?, "Write through a dangling link would create #{target} (policies are loaded from every " \
                            "file there); the guard said #{v.kind}: #{v.reason}"
        end

        def test_a_case_variant_of_an_instruction_file_name_is_governing
          skip 'case-sensitive filesystem' unless case_insensitive_fs?
          File.write(File.join(@root, 'probe.md'), 'x')
          assert File.exist?(File.join(@root, 'PROBE.MD')), 'on this filesystem claude.md is read as CLAUDE.md'
          v = write(File.join(@wt, 'sub', 'claude.md'))
          assert v.refuse?, "<wt>/sub/claude.md is an instruction file here; guard said #{v.kind}: #{v.reason}"
          v = write(File.join(@root, 'docs', 'Claude.md'))
          assert v.refuse?, "<repo>/docs/Claude.md is an instruction file here; guard said #{v.kind}: #{v.reason}"
        end

        # --- KairosChain tools and host tools -------------------------------------

        def test_kairos_tools_that_render_record_or_reach_out_are_refused
          %w[resource_render dream_recall trust_query operator_report].each do |t|
            v = @guard.decide("mcp__kairos-chain__#{t}", {})
            assert v.refuse?, "#{t} must not pass as read-only: #{v.kind} #{v.reason}"
          end
          %w[resource_read resource_list knowledge_get].each do |t|
            assert @guard.decide("mcp__kairos-chain__#{t}", {}).allow?, "#{t} only reads"
          end
        end

        def test_multi_llm_review_is_refused_in_a_run
          %w[multi_llm_review multi_llm_review_bundle multi_llm_review_collect multi_llm_review_wait].each do |t|
            v = @guard.decide("mcp__kairos-chain__#{t}", { 'artifact_content' => 'x' })
            assert v.refuse?, "#{t}: #{v.kind}"
          end
        end

        def test_context_save_only_for_a_new_name
          v = @guard.decide('mcp__kairos-chain__context_save', { 'name' => 'handoff_new' })
          assert v.allow?
          assert_equal 'l2:handoff_new', v.created
          FileUtils.mkdir_p(File.join(@data, 'context', 'other_session', 'handoff_old'))
          assert @guard.decide('mcp__kairos-chain__context_save', { 'name' => 'handoff_old' }).refuse?,
                 'an L2 entry another session wrote is shared'
          FileUtils.mkdir_p(File.join(@data, 'context', 's1', 'mine'))
          @run.created_paths << 'l2:mine'
          assert @guard.decide('mcp__kairos-chain__context_save', { 'name' => 'mine' }).allow?,
                 'an entry this run created stays its own'
        end

        def test_agent_with_worktree_or_remote_isolation_is_refused
          %w[Agent Task].each do |tool|
            %w[worktree remote].each do |iso|
              assert @guard.decide(tool, { 'prompt' => 'x', 'isolation' => iso }).refuse?, "#{tool} isolation #{iso}"
            end
            assert @guard.decide(tool, { 'prompt' => 'x', 'subagent_type' => 'general-purpose' }).allow?
          end
        end

        def test_send_message_only_to_main_or_an_agent_id
          assert @guard.decide('SendMessage', { 'to' => 'main', 'message' => 'x' }).allow?
          assert @guard.decide('SendMessage', { 'to' => 'a1b2c3d4e5f6', 'message' => 'x' }).allow?
          %w[researcher team-lead peer@other-machine a1b2c3].each do |to|
            assert @guard.decide('SendMessage', { 'to' => to, 'message' => 'x' }).refuse?, "to #{to}"
          end
          assert @guard.decide('SendMessage', { 'to' => "main\nresearcher", 'message' => 'x' }).refuse?
        end

        def test_task_and_todo_tools_and_monitor_are_allowed_without_items
          with_bound_design_run do |t, run, troot|
            calls = { 'TaskCreate' => { 'subject' => 'outline', 'description' => 'write the outline' },
                      'TaskUpdate' => { 'taskId' => '1', 'status' => 'completed' },
                      'TodoWrite' => { 'todos' => [{ 'content' => 'x', 'status' => 'pending', 'activeForm' => 'x' }] },
                      'Monitor' => { 'command' => 'tail -f log/x.log', 'description' => 'watch the log' } }
            calls.each do |tool, ti|
              out = t.hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => tool, 'tool_input' => ti,
                                                 'cwd' => troot)
              assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), "#{tool}: #{out.inspect}"
            end
            assert_empty run.reload.open_items, 'no operator item for session-local tools'
          end
        end

        def test_monitor_runs_its_command_confined_like_bash
          v = @guard.decide('Monitor', { 'command' => 'git push origin main', 'description' => 'x' })
          assert v.refuse?, "Monitor's command crosses the line exactly as Bash's would: #{v.kind} #{v.reason}"
          v = @guard.decide('Monitor', { 'command' => "echo x > #{@data}/knowledge/x.md; tail -f /dev/null",
                                         'description' => 'x' })
          refute v.allow?, "an unconfined Monitor command writes governing files: #{v.kind} #{v.reason}"
        end

        def test_enter_worktree_and_cron_create_are_refused
          assert @guard.decide('EnterWorktree', { 'name' => 'x' }).refuse?
          assert @guard.decide('CronCreate', { 'cron' => '*/5 * * * *', 'prompt' => 'x' }).refuse?
        end

        # --- Bash: the operator's deny rules and the git crossings --------------

        def test_operator_deny_rules_match_every_segment
          with_bound_design_run do |_t, _run, troot|
            operator_denies(troot, 'Bash(rm -rf:*)')
            out = hook_pre_tool_use(troot, "cd #{troot}/log && rm -rf old")
            assert_equal 'deny', out['permissionDecision'], out.inspect
            assert_includes out['permissionDecisionReason'], 'permission rules'
            assert_equal 'deny', hook_pre_tool_use(troot, 'echo start; rm -rf build')['permissionDecision']
            ok = hook_pre_tool_use(troot, 'ls -la && echo ok')
            assert_equal 'allow', ok['permissionDecision'], ok.inspect
            assert_includes ok.dig('updatedInput', 'command'), 'sandbox-exec'
          end
        end

        def test_operator_deny_rules_match_after_shell_keywords_and_in_subshells
          with_bound_design_run do |_t, _run, troot|
            operator_denies(troot, 'Bash(rm -rf:*)')
            ['if [ -d build ]; then rm -rf build; fi', '(rm -rf build)', 'for d in a b; do rm -rf $d; done'].each do |cmd|
              assert_equal 'deny', hook_pre_tool_use(troot, cmd)['permissionDecision'], cmd
            end
          end
        end

        def test_git_crossings_behind_global_options_are_refused
          ["git -C #{@wt} push origin HEAD", 'git -c http.extraHeader=x push origin HEAD', 'git -C . -c k=v push',
           "git --git-dir=#{@root}/.git push origin main", "cd #{@wt} && git -C . push", "git -C #{@wt} tag v1",
           "git -C #{@wt} config user.name x", 'env GIT_TRACE=1 git -C . push'].each { |c| assert_refused(c) }
        end

        def test_git_tag_creation_is_refused_and_listing_is_not
          ['git tag v1', 'git tag -a v1 -m rel', 'git tag -d v0', 'git tag v1 HEAD~1'].each { |c| assert_refused(c) }
          ['git tag', 'git tag -l', "git tag -l 'v*'", 'git tag --list', 'git tag --contains HEAD',
           'git tag --points-at HEAD'].each { |c| assert_confined(c) }
        end

        def test_git_config_reads_stash_list_and_remote_listing_are_allowed
          ['git config --get user.name', 'git config --list', "git config --get-regexp '^remote\\.'",
           'git stash list', 'git stash show', 'git remote -v'].each { |c| assert_confined(c) }
          ['git config user.name x', 'git config --unset user.name', 'git stash', 'git stash push -m x',
           'git stash pop', 'git remote add x https://example.com/x.git'].each { |c| assert_refused(c) }
        end

        def test_git_checkout_of_another_branch_is_refused_but_checkout_of_files_is_not
          ['git checkout main', 'git switch main', 'git checkout -b other', 'git switch -c other'].each { |c| assert_refused(c) }
          ['git checkout main -- lib/a.rb', 'git checkout -- lib/a.rb', 'git checkout HEAD~1 -- test/x.rb',
           'git restore lib/a.rb'].each { |c| assert_confined(c) }
        end

        def test_commands_mentioning_open_or_mail_are_not_refused
          ['git commit -m "open the mail queue on start"', "git commit -am 'mail: open the inbox lazily'",
           "git commit -m \"$(cat <<'EOF'\nOpen mail lazily\n\nopen the inbox only when asked\nmail: none\nEOF\n)\"",
           'grep -rn "open " lib', 'grep -rn mail lib test', "rg 'File.open' lib",
           'curl -s http://localhost:3000/health', 'curl -s localhost:8080 && ls'].each { |c| assert_confined(c) }
          ['open https://example.com', 'echo hi | mail someone@example.com', 'ls && osascript -e 1'].each { |c| assert_refused(c) }
        end

        def test_a_heredoc_commit_message_is_not_read_as_commands
          assert_confined("git commit -F - <<'EOF'\nopen the mail handler lazily\nEOF")
          assert_confined("git commit -F - <<EOF\nfix: x\n\nmail is sent later\nEOF")
        end

        # --- the main checkout and the run's own places -------------------------

        def test_a_new_hidden_file_in_the_main_checkout_is_refused_and_a_new_log_file_is_allowed
          %w[.envrc .github/workflows/ci.yml .vscode/tasks.json].each do |rel|
            v = write(File.join(@root, rel))
            assert v.refuse?, "#{rel}: #{v.kind} #{v.reason}"
            assert_includes v.reason, 'hidden'
          end
          FileUtils.mkdir_p(File.join(@root, '.github', 'workflows'))
          assert write(File.join(@root, '.github', 'workflows', 'x.yml')).refuse?, 'also inside an existing hidden dir'
          path = File.join(@root, 'log', 'thing_design_v0.1.md')
          v = write(path)
          assert v.allow?, v.reason
          assert_equal path, v.created
        end

        def test_the_runs_report_dir_and_scratch_are_writable_by_file_tools
          report = File.join(@root, 'log', 'agent_runs', @run_id)
          FileUtils.mkdir_p(report)
          File.write(File.join(report, 'material.json'), '{}')
          assert write(File.join(report, 'material.json')).allow?, 'the report dir is the run\'s own'
          assert write(File.join(report, 'deck.html')).allow?
          scratch = File.join('/tmp', 'kairos_agent_runs', @run_id, 'scratch')
          FileUtils.mkdir_p(scratch)
          File.write(File.join(scratch, 'notes.txt'), 'x')
          assert write(File.join(scratch, 'notes.txt')).allow?, 'scratch is the run\'s own'
          assert write(File.join(scratch, 'sub', 'new.txt')).allow?
          other = File.join(@root, 'log', 'agent_runs', 'run_other')
          FileUtils.mkdir_p(other)
          File.write(File.join(other, 'deck.html'), 'theirs')
          assert write(File.join(other, 'deck.html')).refuse?, 'another run\'s report is shared'
        end

        # --- real confined commands ---------------------------------------------

        def test_confinement_denies_the_git_link_claude_dirs_instruction_files_and_git_admin_files
          git_worktree!
          link = File.join(@wt, '.git')
          before = File.read(link)
          confined("printf 'gitdir: /tmp/elsewhere\\n' > #{link}")
          assert_equal before, File.read(link), 'the worktree .git link is not writable'
          confined("rm -f #{link}")
          assert_equal before, File.read(link)

          confined("mkdir -p #{@wt}/.claude && printf x > #{@wt}/.claude/settings.local.json")
          refute File.exist?(File.join(@wt, '.claude', 'settings.local.json'))
          confined("mkdir -p #{@wt}/sub/.claude && printf x > #{@wt}/sub/.claude/x")
          refute File.exist?(File.join(@wt, 'sub', '.claude', 'x'))
          confined("printf x > #{@wt}/CLAUDE.md")
          refute File.exist?(File.join(@wt, 'CLAUDE.md'))
          confined("mkdir -p #{@wt}/docs && printf x > #{@wt}/docs/AGENTS.md")
          refute File.exist?(File.join(@wt, 'docs', 'AGENTS.md'))

          %w[commondir gitdir].each do |f|
            p = File.join(@admin, f)
            was = File.read(p)
            _o, err, st = confined("printf '/tmp/elsewhere\\n' > #{p}")
            refute st.success?
            assert_match(/not permitted/i, err)
            assert_equal was, File.read(p), "#{f} is not writable"
          end

          _o, err, st = confined("printf ok > #{@wt}/made.txt")
          assert st.success?, err
          assert_equal 'ok', File.read(File.join(@wt, 'made.txt')), 'the worktree itself is writable'
        end

        def test_a_real_git_commit_on_the_run_branch_works_confined_and_sibling_refs_stay_shut
          git_worktree!
          main_before = git!('-C', @root, 'rev-parse', 'main')
          other_before = git!('-C', @root, 'rev-parse', 'agent-run/other')
          _o, err, st = confined("cd #{@wt} && printf hi > a.txt && git add a.txt && git commit -q -m 'add a'")
          assert st.success?, "a commit on the run branch inside confinement: #{err}"
          head = git!('-C', @wt, 'rev-parse', 'HEAD')
          assert_equal head, git!('-C', @root, 'rev-parse', @run.branch), 'the run branch ref moved'
          refute_equal main_before, head
          assert_equal main_before, git!('-C', @root, 'rev-parse', 'main')

          sibling = File.join(@root, '.git', 'refs', 'heads', 'agent-run', 'other')
          _o, err, st = confined("printf '%s\\n' #{head} > #{sibling}")
          refute st.success?
          assert_match(/not permitted/i, err)
          assert_equal other_before, git!('-C', @root, 'rev-parse', 'agent-run/other'), 'another run\'s branch is shut'
          main_ref = File.join(@root, '.git', 'refs', 'heads', 'main')
          confined("printf '%s\\n' #{head} > #{main_ref}")
          assert_equal main_before, git!('-C', @root, 'rev-parse', 'main')
        end

        def test_a_unix_socket_outside_the_runs_places_is_unreachable
          skip 'sandbox-exec unavailable' unless Confinement.available?
          dir = File.join(@root, 's')
          FileUtils.mkdir_p(dir)
          outside = File.join(dir, 'a.sock')
          skip "socket path too long: #{outside}" if outside.bytesize > 100
          srv = UNIXServer.new(outside)
          probe = ->(p) { "#{RbConfig.ruby} -rsocket -e 'UNIXSocket.new(ARGV[0]).close; print :connected' #{p}" }
          out, err, st = confined(probe.call(outside))
          refute st.success?, 'connected to a socket outside the run\'s places'
          refute_equal 'connected', out
          assert_match(/not permitted/i, err)

          scratch = File.realpath(File.join('/tmp', 'kairos_agent_runs', @run_id, 'scratch'))
          srv2 = UNIXServer.new(File.join(scratch, 'b.sock'))
          out, err, st = confined(probe.call(File.join(scratch, 'b.sock')))
          assert st.success?, "a socket inside the run's scratch is reachable: #{err}"
          assert_equal 'connected', out
        ensure
          srv&.close
          srv2&.close
        end

        def test_open_and_osascript_cannot_be_launched_confined
          skip 'sandbox-exec unavailable' unless Confinement.available?
          # Indirections the guard's reading of the command cannot see.
          out, err, st = confined(%(P=/usr/bin/osascript; "$P" -e 'return 1'))
          refute st.success?
          refute_equal '1', out.strip
          assert_match(/not permitted/i, err)
          _o, err, st = confined(%(P=/usr/bin/open; "$P" -h))
          refute st.success?
          assert_match(/not permitted/i, err)
          script = File.join(@wt, 'x.sh')
          File.write(script, "#!/bin/bash\n/usr/bin/osascript -e 'return 1'\n")
          File.chmod(0o755, script)
          out, _e, st = confined(script)
          refute st.success?
          refute_equal '1', out.strip

          # The SkillSet's own confined runs.
          scratch = File.join('/tmp', 'kairos_agent_runs', @run_id, 'scratch')
          %w[/usr/bin/osascript /usr/bin/open].each do |prog|
            argv = Confinement.argv([prog, '-e', 'return 1'], writable: [@wt], scratch: scratch, worktree: @wt)
            out, err, st = Open3.capture3(*argv)
            refute st.success?, "#{prog} launched under Confinement.argv: #{out}"
            assert_match(/not permitted/i, err)
          end
        end
      end
    end
  end
end
