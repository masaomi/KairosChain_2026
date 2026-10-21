# frozen_string_literal: true

# Regression tests for the implementation review round R2, guard group:
# lib/agent/guard.rb, lib/agent/confinement.rb, hooks/agent_hook.rb and the
# plugin's PreToolUse command line. Confinement is checked with real
# sandbox-exec runs in tmp git worktrees, the hook script and the command
# line as subprocesses with HOME, KAIROS_DATA_DIR and CLAUDE_PROJECT_DIR in
# the tmpdir.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'socket'
require 'pathname'
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
      class TestAgent1R2Guard < Minitest::Test
        FakeRun = Struct.new(:id, :worktree, :target_repo, :branch, :created_paths, :pinned, keyword_init: true)
        SKILLSET = File.expand_path('..', __dir__)
        HOOK = File.join(SKILLSET, 'hooks', 'agent_hook.rb')
        HOOKS_JSON = File.join(SKILLSET, 'plugin', 'hooks.json')

        # The host's own commit form, with backticked words in the message.
        COMMIT = <<~SH.chomp
          git commit -m "$(cat <<'EOF'
          fix(guard): read heredocs as the shell does

          Use `open` mode; `kill` the child (1) and never `git push` here.
          2) `gh pr create` waits for the operator.

          Co-Authored-By: Claude <noreply@anthropic.com>
          EOF
          )"
        SH

        def setup
          @root = File.realpath(Dir.mktmpdir('r2g'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@root, 'global_bound_sessions.txt')
          @data = File.join(@root, '.kairos')
          @paths = Paths.new(@data)
          FileUtils.mkdir_p(@paths.policies_dir)
          FileUtils.mkdir_p(File.join(@root, 'log'))
          @run_id = "run_r2g_#{SecureRandom.hex(4)}"
          @wt = File.join(@root, '.claude', 'worktrees', "agent-run-#{@run_id}")
          FileUtils.mkdir_p(File.join(@wt, 'lib'))
          File.write(File.join(@wt, 'lib', 'a.rb'), "a = 1\n")
          @run = FakeRun.new(id: @run_id, worktree: @wt, target_repo: @root, branch: "agent-run/#{@run_id}",
                             created_paths: [], pinned: {})
          @guard = guard
        end

        def teardown
          FileUtils.rm_rf(@root)
          FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', @run_id))
        end

        def guard(**kw)
          Guard.new(run: @run, paths: @paths, policy: policy, project_root: @root, **kw)
        end

        def policy
          DSL.parse_policy("policy \"p\" do\n  stand_in may: [:precedent]\n  spend default: { stand_in_calls: 5 }\nend\n")
        end

        def bash(cmd, g = @guard, cwd: @root)
          g.decide('Bash', { 'command' => cmd }, cwd: cwd)
        end

        def assert_refused(cmd, g = @guard, cwd: @root)
          v = bash(cmd, g, cwd: cwd)
          assert v.refuse?, "#{cmd.inspect} should be refused, got #{v.kind}: #{v.reason}"
          v
        end

        def assert_confined(cmd, g = @guard, cwd: @root)
          v = bash(cmd, g, cwd: cwd)
          assert v.rewrite?, "#{cmd.inspect} should run confined, got #{v.kind}: #{v.reason}"
          assert_includes v.updated_input['command'], 'sandbox-exec'
        end

        # The operator's Bash rules as the hook script compiles them.
        def denying(*prefixes)
          guard(deny_patterns: prefixes.map { |p| /\A\s*#{Regexp.escape(p)}(?=\s|\z)/ })
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
        # on branch agent-run/<id>.
        def git_worktree!
          skip 'sandbox-exec unavailable' unless Confinement.available?
          FileUtils.rm_rf(@wt)
          git!('-C', @root, 'init', '-q', '-b', 'main')
          File.write(File.join(@root, '.gitignore'), ".kairos/\n.claude/\nlog/\nhome/\nadmin_elsewhere/\n")
          File.write(File.join(@root, 'README'), "r\n")
          git!('-C', @root, 'add', 'README', '.gitignore')
          git!('-C', @root, 'commit', '-q', '-m', 'init')
          git!('-C', @root, 'worktree', 'add', '-q', '-b', @run.branch, @wt, 'HEAD')
          @admin = File.read(File.join(@wt, '.git'))[/gitdir:\s*(.+)/, 1].strip
        end

        # A command as the host would run it after the guard's rewrite.
        def confined(cmd, g = @guard)
          v = bash(cmd, g)
          assert v.rewrite?, "#{cmd.inspect} should run confined, got #{v.kind}: #{v.reason}"
          Open3.capture3(git_env, '/bin/bash', '-c', v.updated_input['command'])
        end

        def confined_dir!
          skip 'sandbox-exec unavailable' unless Confinement.available?
          FileUtils.mkdir_p(@wt)
        end

        # --- confinement: network ------------------------------------------------

        # sandbox-exec cannot tell a loopback listener from one on 0.0.0.0 (its
        # local address filter takes only * or localhost and matches both), so
        # listening is left open; what must keep working does.
        def test_a_confined_command_can_serve_on_loopback_and_on_a_socket_in_its_places
          confined_dir!
          probe = "#{RbConfig.ruby} -rsocket -e 's = TCPServer.new(%q(127.0.0.1), 0); " \
                  "TCPSocket.new(%q(127.0.0.1), s.addr[1]).close; print :served'"
          # A loopback connect inside sandbox-exec is refused about once in a
          # hundred on macOS 14 (a stated residual); three tries.
          out, err, st = 3.times.lazy.map { confined(probe) }.find { |_, _, x| x.success? } || confined(probe)
          assert st.success?, "a loopback listener inside confinement: #{err}"
          assert_equal 'served', out

          scratch = File.join('/tmp', 'kairos_agent_runs', @run_id, 'scratch')
          sock = File.join(File.realpath('/tmp'), 'kairos_agent_runs', @run_id, 'scratch', 'c.sock')
          probe = "#{RbConfig.ruby} -rsocket -e 's = UNIXServer.new(ARGV[0]); UNIXSocket.new(ARGV[0]).close; " \
                  "print :served' #{sock}"
          out, err, st = confined(probe)
          assert st.success?, "a unix socket in the run's scratch: #{err}"
          assert_equal 'served', out
          assert File.directory?(scratch)
        end

        # --- confinement: names in any letter case -------------------------------

        # sandbox-exec on this volume already matches paths without case; the
        # profile spells the names case-blind so as not to depend on that.
        def test_confinement_denies_instruction_files_and_claude_dirs_in_any_letter_case
          prof = Confinement.profile(writable: [@wt], worktree: @wt)
          assert_includes prof, '[Cc][Ll][Aa][Uu][Dd][Ee]'
          assert_includes prof, '\\.[Mm][Dd]$'
          confined_dir!
          %w[claude.md Claude.local.md sub/agents.md sub/Gemini.MD].each do |rel|
            path = File.join(@wt, rel)
            _o, err, st = confined("mkdir -p #{File.dirname(path)} && printf x > #{path}")
            refute st.success?, "#{rel} was written inside confinement"
            assert_match(/not permitted/i, err)
            refute_includes Dir.children(File.dirname(path)).map(&:downcase), File.basename(rel).downcase, rel
          end
          %w[.Claude/x sub/.CLAUDE/settings.json].each do |rel|
            path = File.join(@wt, rel)
            _o, err, st = confined("mkdir -p #{File.dirname(path)} && printf x > #{path}")
            refute st.success?, "#{rel} was written inside confinement"
            assert_match(/not permitted/i, err)
            refute File.exist?(path), rel
          end
          _o, err, st = confined("printf ok > #{@wt}/claude_notes.md && printf ok > #{@wt}/sub/claudette/x.md 2>/dev/null || " \
                                 "{ mkdir -p #{@wt}/sub/claudette && printf ok > #{@wt}/sub/claudette/x.md; }")
          assert st.success?, "ordinary names stay writable: #{err}"
          assert_equal 'ok', File.read(File.join(@wt, 'claude_notes.md'))
        end

        # --- reading the shell line ---------------------------------------------

        def test_a_continued_line_is_joined_before_it_is_read
          assert_refused("git \\\n push origin main")
          assert_refused("git -C . \\\n  push")
          v = assert_refused("rm \\\n -rf build", denying('rm -rf'))
          assert_includes v.reason, 'permission rules'
          assert_confined("printf '%s\\n' \\\n  a b")
          # A backslash-newline in single quotes is text.
          assert_confined("echo 'git \\\n push'")
        end

        def test_the_hosts_commit_form_with_backticked_words_is_allowed
          assert_confined(COMMIT)
          assert_confined(COMMIT, denying('git push', 'gh', 'open'))
          assert_confined("git commit -F - <<'EOF'\nUse `open`; $(git push) is text here\nEOF")
          assert_confined("git commit -F - <<\"EOF\"\nUse `open`; $(git push) is text here\nEOF")
          assert_confined("git commit -F - <<\\EOF\nUse `open`\nEOF")
          # Control: under a bare delimiter the shell runs the body's substitutions.
          assert_refused("git commit -F - <<EOF\nmsg $(git push origin main)\nEOF")
          assert_refused("cat <<EOF > notes.md\n`gh pr create`\nEOF")
          # Control: a command substitution in the message itself runs.
          assert_refused('git commit -m "msg `gh pr create`"')
        end

        def test_a_heredoc_fed_to_a_shell_is_read_as_commands
          ["bash <<'EOF'\ngit push origin main\nEOF", "sh <<EOF\ngit push\nEOF", "zsh -s <<-'EOF'\n\tgit push\n\tEOF",
           "cat <<'EOF' | sh\necho hi\ngit push\nEOF", "env X=1 bash <<'EOF'\ngh pr create\nEOF"].each { |c| assert_refused(c) }
          v = assert_refused("bash <<'EOF'\nrm -rf build\nEOF", denying('rm -rf'))
          assert_includes v.reason, 'permission rules'
          assert_confined("cat <<'EOF' > plan.md\ngit push origin main\nEOF\necho written")
          assert_confined("bash -c 'echo hi' <<'EOF'\ngit push\nEOF")
          assert_refused("bash -lc 'git push origin main'")
        end

        def test_single_quoted_text_is_never_scanned_for_substitutions
          assert_confined("echo '$(git push)' '`gh pr create`'")
          assert_confined("grep -rn '`open`' lib", denying('open'))
          assert_refused('echo "$(git push)"')
          assert_refused("echo \"it's `gh pr create`\"")
          assert_refused('diff <(git push) x')
        end

        def test_a_comment_does_not_hide_the_commands_after_it
          assert_refused("# don't push yet\nls\ngit push origin main")
          assert_confined("ls # then git push, later\necho done")
          # Arithmetic << opens no heredoc.
          assert_refused("echo $((a << b))\ngit push")
        end

        # --- git crossings ---------------------------------------------------------

        def test_git_checkout_of_existing_paths_is_allowed_without_double_dash
          FileUtils.mkdir_p(File.join(@wt, 'test'))
          assert_confined('git checkout lib/a.rb', cwd: @wt)
          assert_confined('git checkout .', cwd: @wt)
          assert_confined('git checkout lib test', cwd: @wt)
          # A path in the worktree is read from it as well.
          assert_confined('git checkout lib/a.rb', cwd: @root)
          ['git checkout main', 'git checkout lib/missing.rb', 'git checkout lib/a.rb main', 'git checkout -b lib',
           'git switch lib', 'git checkout -', 'git switch -', 'git checkout --detach'].each { |c| assert_refused(c, cwd: @wt) }
          assert_confined('git checkout -p', cwd: @wt)
          assert_nil Guard.crossing(%w[git checkout lib/a.rb], cwd: @wt)
          refute_nil Guard.crossing(%w[git checkout lib/a.rb]), 'without a cwd no path can be shown to exist'
        end

        def test_git_config_of_one_key_and_branch_listing_are_reads
          ['git config user.email', 'git config --global user.name', 'git config get user.name',
           'git branch --contains HEAD~1', 'git branch --no-merged main', 'git branch -a', 'git branch -r',
           'git branch -vv', 'git branch --show-current', "git branch --format='%(refname:short)'",
           "git branch --list 'agent-run/*'", 'git branch --points-at HEAD'].each { |c| assert_confined(c) }
          ['git config user.email x@y', 'git config --unset user.email', 'git config --add a.b c',
           'git config --replace-all a.b c', 'git config -e', 'git branch other', 'git branch -d other',
           'git branch -D other', 'git branch -m a b', 'git branch -f other HEAD', 'git branch --unset-upstream',
           'git branch --contains HEAD -d other'].each { |c| assert_refused(c) }
        end

        def test_kill_is_left_to_confinement_which_keeps_signals_in_the_commands_own_group
          ['kill $PID', 'pkill -f puma', 'killall ruby'].each { |c| assert_confined(c) }
          skip 'sandbox-exec unavailable' unless Confinement.available?
          FileUtils.mkdir_p(@wt)
          other = Process.spawn('sleep', '30', pgroup: true)
          _o, err, st = confined("kill #{other}")
          refute st.success?, 'a process outside the command was signalled'
          assert_match(/not permitted/i, err)
          assert_nil Process.wait(other, Process::WNOHANG), 'the outside process is alive'
          out, err, st = confined('sleep 30 & c=$!; kill $c && wait $c; echo "status $?"')
          assert st.success?, err
          assert_equal 'status 143', out.strip, "the command's own child is stopped"
        ensure
          if other
            Process.kill('KILL', other)
            Process.wait(other)
          end
        end

        # --- Workflow ----------------------------------------------------------------

        def test_a_workflow_asking_for_worktree_or_remote_agents_is_refused
          plain = "export default async () => { await agent('outline', { label: 'o' }) }"
          assert @guard.decide('Workflow', { 'script' => plain }).allow?
          ["agent('x', { isolation: 'worktree' })", "agent('x', {isolation:\"remote\"})",
           "agent('x', { \"isolation\": \"worktree\" })"].each do |call|
            v = @guard.decide('Workflow', { 'script' => "export default async () => { await #{call} }" })
            assert v.refuse?, "#{call}: #{v.kind} #{v.reason}"
            assert_match(/isolated agents/, v.reason)
          end

          dir = File.join(@root, 'flows')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'iso.js'), "agent('x', { isolation: 'worktree' })")
          File.write(File.join(dir, 'ok.js'), plain)
          assert @guard.decide('Workflow', { 'scriptPath' => 'flows/iso.js' }, cwd: @root).refuse?
          assert @guard.decide('Workflow', { 'scriptPath' => File.join(dir, 'ok.js') }).allow?
          v = @guard.decide('Workflow', { 'scriptPath' => File.join(dir, 'missing.js') })
          assert v.refuse?
          assert_includes v.reason, 'cannot be read'
        end

        def test_a_saved_workflow_is_looked_up_by_name_and_read
          saved = File.join(@root, '.claude', 'workflows')
          FileUtils.mkdir_p(saved)
          name = "r2_flow_#{SecureRandom.hex(4)}"
          File.write(File.join(saved, "#{name}.js"), "agent('x', { isolation: 'remote' })")
          assert @guard.decide('Workflow', { 'name' => name }).refuse?
          File.write(File.join(saved, "#{name}.js"), "agent('x', {})")
          assert @guard.decide('Workflow', { 'name' => name }).allow?
          assert @guard.decide('Workflow', { 'name' => "#{name}_absent" }).refuse?, 'a workflow that cannot be read'
          assert @guard.decide('Workflow', {}).refuse?

          home = File.join(@root, 'home')
          FileUtils.mkdir_p(File.join(home, '.claude', 'workflows'))
          File.write(File.join(home, '.claude', 'workflows', 'mine.js'), "agent('x', { isolation: 'worktree' })")
          was = ENV['HOME']
          ENV['HOME'] = home
          assert @guard.decide('Workflow', { 'name' => 'mine' }).refuse?, "the user's saved workflows are read too"
        ensure
          ENV['HOME'] = was if was
        end

        # --- placement in the worktree -----------------------------------------------

        def test_only_the_worktrees_own_git_and_claude_dirs_govern_inside_it
          fixture = File.join(@wt, 'test', 'fixtures', 'repo', '.git', 'config')
          FileUtils.mkdir_p(File.dirname(fixture))
          File.write(fixture, "[core]\n")
          v = @guard.decide('Edit', { 'file_path' => fixture, 'old_string' => 'core', 'new_string' => 'core' })
          assert v.allow?, "a fixture repository's .git is the run's own: #{v.kind} #{v.reason}"
          assert @guard.decide('Write', { 'file_path' => File.join(@wt, 'vendor', 'gem', '.git', 'HEAD') }).allow?
          [File.join(@wt, '.git'), File.join(@wt, '.git', 'config'), File.join(@wt, '.GIT', 'hooks', 'pre-commit'),
           File.join(@wt, 'test', '.claude', 'settings.json'), File.join(@wt, 'docs', 'CLAUDE.md')].each do |p|
            v = @guard.decide('Write', { 'file_path' => p })
            assert v.refuse?, "#{p}: #{v.kind}"
            assert_includes v.reason, 'governs runs'
          end
          v = @guard.decide('Write', { 'file_path' => File.join(@root, 'log', 'repo', '.git', 'config') })
          assert_includes v.reason, 'governs runs', 'outside the worktree any .git still governs'
        end

        # --- git places from commondir ------------------------------------------------

        def test_git_places_follow_the_admin_dirs_commondir
          git_worktree!
          moved = File.join(@root, 'admin_elsewhere', 'wt1')
          FileUtils.mkdir_p(File.dirname(moved))
          FileUtils.mv(@admin, moved)
          File.write(File.join(@wt, '.git'), "gitdir: #{moved}\n")
          common = File.realpath(File.join(@root, '.git'))
          File.write(File.join(moved, 'commondir'), "#{Pathname(common).relative_path_from(Pathname(moved))}\n")
          File.write(File.join(moved, 'gitdir'), "#{File.join(@wt, '.git')}\n")
          assert_equal @run.branch, git!('-C', @wt, 'rev-parse', '--abbrev-ref', 'HEAD'), 'git itself follows commondir'

          _o, err, st = confined("cd #{@wt} && printf hi > a.txt && git add a.txt && git commit -q -m 'add a'")
          assert st.success?, "a commit on the run branch inside confinement: #{err}"
          assert_equal git!('-C', @wt, 'rev-parse', 'HEAD'), git!('-C', @root, 'rev-parse', @run.branch)
          main_ref = File.join(common, 'refs', 'heads', 'main')
          _o, _e, st = confined("printf x > #{main_ref}")
          refute st.success?, 'the other refs stay shut'
        end

        # --- the operator's path rules -------------------------------------------------

        def test_a_path_rule_matches_the_path_as_given_and_as_resolved
          tmp = "/tmp/kairos_r2g_#{SecureRandom.hex(4)}"
          g = guard(settings_rules: [{ 'kind' => 'deny', 'tool' => 'Edit', 'spec' => '//tmp/**' }])
          [File.join(tmp, 'x.txt'), File.join('/private', tmp, 'x.txt')].each do |p|
            v = g.decide('Write', { 'file_path' => p, 'content' => 'x' })
            assert v.refuse?, "#{p}: #{v.kind} #{v.reason}"
            assert_includes v.reason, "operator's own settings"
          end
          g = guard(settings_rules: [{ 'kind' => 'deny', 'tool' => 'Edit', 'spec' => '//private/tmp/**' }])
          assert_includes g.decide('Write', { 'file_path' => File.join(tmp, 'x.txt') }).reason, "operator's own settings"
          refute_includes g.decide('Write', { 'file_path' => File.join(@wt, 'lib', 'b.rb') }).reason.to_s,
                          "operator's own settings", 'control: a path elsewhere is not named'
        end

        # --- the hook script -----------------------------------------------------------

        def hook_env(troot, extra = {})
          home = File.join(troot, 'home')
          FileUtils.mkdir_p(home)
          { 'HOME' => home, 'KAIROS_DATA_DIR' => File.join(troot, '.kairos'), 'CLAUDE_PROJECT_DIR' => troot,
            'KAIROS_AGENT_GLOBAL' => File.join(troot, 'global_bound_sessions.txt'), 'KAIROS_MCP_LIB' => nil }.merge(extra)
        end

        def hook(troot, input, script: HOOK, env: {})
          out, err, st = Open3.capture3(hook_env(troot, env), RbConfig.ruby, script, stdin_data: JSON.generate(input),
                                                                                       chdir: troot)
          [out, err, st.exitstatus]
        end

        def with_bound_design_run
          t = TestAgent1HooksService.new('x')
          t.setup
          run = t.start_design_run
          yield t, run, t.instance_variable_get(:@root)
        ensure
          t&.teardown
          FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', run.id)) if run
        end

        def test_bash_prefix_rules_match_at_a_word_boundary
          skip 'sandbox-exec unavailable' unless Confinement.available?
          with_bound_design_run do |_t, _run, troot|
            FileUtils.mkdir_p(File.join(troot, '.claude'))
            File.write(File.join(troot, '.claude', 'settings.json'),
                       JSON.generate('permissions' => { 'deny' => ['Bash(mv:*)', 'Bash(rm:*)', 'Bash(./bin/:*)'] }))
            decide = lambda do |cmd|
              out, err, code = hook(troot, { 'hook_event_name' => 'PreToolUse', 'session_id' => 's1', 'tool_name' => 'Bash',
                                             'tool_use_id' => "tu_#{SecureRandom.hex(3)}", 'cwd' => troot,
                                             'tool_input' => { 'command' => cmd } })
              assert_equal 0, code, err
              JSON.parse(out).dig('hookSpecificOutput', 'permissionDecision')
            end
            ['mvn test', 'rmate lib/a.rb', 'ls && mvn -q package', 'echo rm'].each do |cmd|
              assert_equal 'allow', decide.call(cmd), "#{cmd} is not mv or rm"
            end
            ['mv a b', 'rm x', 'rm', 'ls; rm -rf build', './bin/setup', "mv\ta b"].each do |cmd|
              assert_equal 'deny', decide.call(cmd), cmd
            end
          end
        end

        def test_kairos_agent_tools_under_any_server_spelling_learn_session_and_project
          troot = @root
          %w[mcp__kairos_chain__agent_start mcp__kairos-chain__agent_status mcp__KairosChain__agent_items].each do |tool|
            out, _e, code = hook(troot, { 'hook_event_name' => 'PreToolUse', 'session_id' => 'u1', 'tool_name' => tool,
                                          'tool_input' => { 'goal' => 'g' }, 'cwd' => File.join(troot, 'sub') })
            assert_equal 0, code
            d = JSON.parse(out).fetch('hookSpecificOutput')
            assert_equal 'allow', d['permissionDecision'], tool
            assert_equal({ 'goal' => 'g', '_session_id' => 'u1', '_project_dir' => troot }, d['updatedInput'], tool)
          end
          out, = hook(troot, { 'hook_event_name' => 'PreToolUse', 'session_id' => 'u1',
                               'tool_name' => 'mcp__kairos_chain__agent_start', 'tool_input' => {}, 'cwd' => '/elsewhere' },
                      env: { 'CLAUDE_PROJECT_DIR' => nil })
          assert_equal '/elsewhere', JSON.parse(out).dig('hookSpecificOutput', 'updatedInput', '_project_dir'),
                       'without CLAUDE_PROJECT_DIR the call\'s cwd names the project'
          %w[mcp__acme__agent_start mcp__acme__kairos_agent_start].each do |tool|
            out, _e, code = hook(troot, { 'hook_event_name' => 'PreToolUse', 'session_id' => 'u1', 'tool_name' => tool,
                                          'tool_input' => {} })
            assert_equal 0, code
            assert_empty out, "#{tool} is not KairosChain's agent tool"
          end
        end

        # A copy of the script whose library only leaves a mark when loaded.
        def loads_library?(input)
          dir = File.join(@root, 'stub')
          FileUtils.mkdir_p([File.join(dir, 'hooks'), File.join(dir, 'lib', 'agent')])
          FileUtils.cp(HOOK, File.join(dir, 'hooks', 'agent_hook.rb'))
          File.write(File.join(dir, 'lib', 'agent', 'hooks.rb'), "File.write(ENV.fetch('AGENT_HOOK_LOADED'), 'loaded')\n")
          marker = File.join(@root, "loaded_#{SecureRandom.hex(4)}")
          hook(@root, input, script: File.join(dir, 'hooks', 'agent_hook.rb'), env: { 'AGENT_HOOK_LOADED' => marker })
          File.exist?(marker)
        end

        def test_agent_start_under_an_underscored_server_name_is_seen_after_the_call
          post = { 'hook_event_name' => 'PostToolUse', 'session_id' => 'u1', 'tool_input' => {}, 'tool_response' => [] }
          assert loads_library?(post.merge('tool_name' => 'mcp__kairos_chain__agent_start'))
          assert loads_library?(post.merge('tool_name' => 'mcp__kairos-chain__agent_start'))
          refute loads_library?(post.merge('tool_name' => 'mcp__acme__agent_start'))
          refute loads_library?(post.merge('tool_name' => 'mcp__kairos_chain__agent_status'))
        end

        def test_confirming_and_sending_back_words_are_kept
          prompt = { 'hook_event_name' => 'UserPromptSubmit', 'session_id' => 'u1', 'prompt_id' => 'p1' }
          ['design_review は確定で', 'design_review は差し戻し', 'D4は違う'].each do |words|
            assert loads_library?(prompt.merge('prompt' => words)), words
          end
          refute loads_library?(prompt.merge('prompt' => 'add the missing keys'))
        end

        # --- the plugin's PreToolUse command line --------------------------------------

        def pre_command
          JSON.parse(File.read(HOOKS_JSON)).dig('hooks', 'PreToolUse', 0, 'hooks', 0)
        end

        def shells
          %w[/bin/sh /bin/bash /bin/zsh /bin/dash].select { |s| File.executable?(s) }
        end

        # The command line as the host runs it, with the hook input on stdin.
        def run_pre_command(shell, sid, data, path: '/usr/bin:/bin')
          input = JSON.generate('session_id' => sid, 'hook_event_name' => 'PreToolUse', 'tool_name' => 'Bash',
                                'tool_input' => { 'command' => 'echo "session_id": "s1"' })
          env = { 'HOME' => File.join(@root, 'home'), 'KAIROS_DATA_DIR' => data, 'CLAUDE_PROJECT_DIR' => @root,
                  'KAIROS_AGENT_GLOBAL' => ENV['KAIROS_AGENT_GLOBAL'], 'PATH' => path }
          out, err, st = Open3.capture3(env, shell, '-c', pre_command['command'], stdin_data: input, chdir: @root,
                                                                                  unsetenv_others: true)
          [out, err, st.exitstatus]
        end

        def test_the_pre_tool_use_command_blocks_only_the_session_bound_here
          assert_equal 'block', pre_command['onFailure'], 'a timeout in a bound session still blocks'
          data = File.join(@root, 'data')
          bindings = File.join(data, 'storage', 'agent', 'bindings')
          FileUtils.mkdir_p(bindings)
          fake = File.join(@root, 'fakebin')
          FileUtils.mkdir_p(fake)
          File.write(File.join(fake, 'ruby'), "#!/bin/sh\necho 'rbenv: version `9.9.9` is not installed' >&2\nexit 1\n")
          File.chmod(0o755, File.join(fake, 'ruby'))
          shells.each do |sh|
            File.write(File.join(bindings, 's1'), 'run_x')
            assert_equal 0, run_pre_command(sh, 's2', data)[2], "#{sh}: no script, another session is bound"
            _o, err, code = run_pre_command(sh, 's1', data)
            assert_equal 2, code, "#{sh}: no script while this session is bound"
            assert_includes err, 'agent guard unavailable'
            File.delete(File.join(bindings, 's1'))
            assert_equal 0, run_pre_command(sh, 's1', data)[2], "#{sh}: no script, nothing bound"

            script = File.join(data, 'skillsets', 'agent', 'hooks', 'agent_hook.rb')
            FileUtils.mkdir_p(File.dirname(script))
            File.write(script, "puts 'never'\n")
            out, err, code = run_pre_command(sh, 's1', data, path: "#{fake}:/usr/bin:/bin")
            assert_equal 0, code, "#{sh}: ruby fails in an unbound session: #{err}"
            assert_empty out
            File.write(File.join(bindings, 's1.a-b'), 'run_x')
            _o, err, code = run_pre_command(sh, 's1.a-b', data, path: "#{fake}:/usr/bin:/bin")
            assert_equal 2, code, "#{sh}: ruby fails while this session is bound"
            assert_includes err, 'not installed'
            File.delete(File.join(bindings, 's1.a-b'))
            FileUtils.rm_rf(File.join(data, 'skillsets'))
          end
        end

        def test_the_pre_tool_use_command_passes_a_working_scripts_output
          data = File.join(@root, 'data')
          installed = File.join(data, 'skillsets', 'agent')
          FileUtils.mkdir_p(installed)
          FileUtils.cp_r(File.join(SKILLSET, 'hooks'), installed)
          FileUtils.cp_r(File.join(SKILLSET, 'lib'), installed)
          path = "#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin"
          shells.each do |sh|
            input = JSON.generate('session_id' => 'u9', 'hook_event_name' => 'PreToolUse',
                                  'tool_name' => 'mcp__kairos-chain__agent_status', 'tool_input' => {})
            env = { 'HOME' => File.join(@root, 'home'), 'KAIROS_DATA_DIR' => data, 'CLAUDE_PROJECT_DIR' => @root,
                    'KAIROS_AGENT_GLOBAL' => ENV['KAIROS_AGENT_GLOBAL'], 'PATH' => path }
            out, err, st = Open3.capture3(env, sh, '-c', pre_command['command'], stdin_data: input, chdir: @root,
                                                                                 unsetenv_others: true)
            assert_equal 0, st.exitstatus, "#{sh}: #{err}"
            d = JSON.parse(out).fetch('hookSpecificOutput')
            assert_equal 'u9', d.dig('updatedInput', '_session_id'), sh
            assert File.exist?(File.join(data, 'storage', 'agent', 'guard_seen', 'u9'))
          end
        end
      end
    end
  end
end
