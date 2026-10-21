# frozen_string_literal: true

# Verification of the fixes after implementation review R2, group
# "checkreview": the implementation check (what a glob pins, tests failing
# on the base commit, non-ASCII test names, test_command), the review rounds
# (closure against commits added after dispatch, unchanged bundles, the
# labeller's evidence, finding ids) and the report (material.json, who built
# the deck, the kit's check.py under confinement).
#
# Every agent tool is called as the host calls it: PreToolUse (which hands
# the tool its session) -> the service -> PostToolUse, with the turn's Stop
# where the host fires it. File edits and shell commands go through the
# guard; shell commands run as the guard rewrote them (confined). Real git
# and sandbox-exec under a temporary directory; HOME, KAIROS_DATA_DIR and
# CLAUDE_PROJECT_DIR point into it. The stand-in and the review tools are
# scripted. Reuses the "check" harness without re-running its tests.
require 'shellwords'
require_relative 'test_agent1_r1_check'

# The harness's own tests run in their own file, not again here.
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1R1Check)

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R2Checkreview < TestAgent1R1Check
        # Only this file's tests run here; the harness's own run in theirs.
        TestAgent1R1Check.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }

        SUBAGENT = 'a1b2c3d4e5f6'
        KIT = Service::KIT_DIR
        GIT_ID = 'git -c user.email=t@t -c user.name=t -c commit.gpgsign=false'
        MY_ENV = %w[HOME KAIROS_DATA_DIR CLAUDE_PROJECT_DIR RBENV_ROOT PLAYWRIGHT_BROWSERS_PATH].freeze
        TOOLS = { 'start' => :start, 'status' => :status, 'advance' => :advance, 'items' => :items,
                  'finish' => :finish, 'stop' => :stop }.freeze
        APPROVE = [{ 'role_label' => 'codex', 'verdict' => 'APPROVE', 'raw_text' => 'Overall Verdict: APPROVE' },
                   { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'APPROVE' }].freeze

        def setup
          @my_saved = MY_ENV.to_h { |k| [k, ENV.fetch(k, nil)] }
          real_home = ENV.fetch('HOME')
          super
          home = File.join(@tmp, 'home')
          FileUtils.mkdir_p(home)
          # The confined test runs and the kit find ruby and the browser where
          # they are installed (read only); everything else sees a tmp HOME.
          rbenv = File.join(real_home, '.rbenv')
          ENV['RBENV_ROOT'] ||= rbenv if File.directory?(rbenv)
          ENV['PLAYWRIGHT_BROWSERS_PATH'] ||= File.join(real_home, 'Library', 'Caches', 'ms-playwright')
          ENV['HOME'] = home
          ENV['KAIROS_DATA_DIR'] = File.join(@root, '.kairos')
          ENV['CLAUDE_PROJECT_DIR'] = @root
        end

        def teardown
          ids = @paths && File.directory?(@paths.runs_dir) ? Run.all(@paths).map(&:id) : []
          super
          ids.each { |id| FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_report_check', id)) }
        ensure
          @my_saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
        end

        # --- the host -----------------------------------------------------------

        def next_id
          @n = (@n || 0) + 1
          "toolu_r2v_#{@n}"
        end

        # An agent tool as the host calls it: PreToolUse, the tool with the
        # input the hook handed it, PostToolUse with the tool's reply.
        def host_tool(name, args, agent_id: nil, svc: service)
          input = { 'session_id' => 's1', 'tool_name' => "mcp__kairos-chain__agent_#{name}", 'tool_input' => args,
                    'cwd' => @root, 'transcript_path' => @transcript, 'tool_use_id' => next_id }
          input['agent_id'] = agent_id if agent_id
          pre = hooks.handle('PreToolUse', input)
          assert_equal 'allow', pre.dig('hookSpecificOutput', 'permissionDecision'), pre.inspect
          out = svc.public_send(TOOLS.fetch(name), pre.dig('hookSpecificOutput', 'updatedInput'))
          hooks.handle('PostToolUse', input.merge('tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }]))
          out
        end

        def host_start(args)
          adopt! unless Policies.new(@paths).adopted
          host_tool('start', { 'goal' => 'make x work' }.merge(args))
        end

        def started(args)
          out = host_start(args)
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          assert_equal 's1', run.bound_session
          run
        end

        def host_advance(run)
          host_tool('advance', { 'run_id' => run.id })
        end

        def host_stop(msg = 'Done for this turn.')
          hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => msg, 'transcript_path' => @transcript)
        end

        # A file tool through the guard; the host applies it only when allowed.
        def host_file(tool, path, input, cwd:, agent_id: nil)
          data = { 'session_id' => 's1', 'tool_name' => tool, 'tool_input' => { 'file_path' => path }.merge(input),
                   'cwd' => cwd, 'tool_use_id' => next_id }
          data['agent_id'] = agent_id if agent_id
          out = hooks.handle('PreToolUse', data)
          decision = out&.dig('hookSpecificOutput', 'permissionDecision')
          if decision == 'allow'
            FileUtils.mkdir_p(File.dirname(path))
            yield
            hooks.handle('PostToolUse', data.merge('tool_response' => { 'filePath' => path, 'success' => true }))
          end
          decision
        end

        def host_write(path, content, cwd:, agent_id: nil)
          host_file('Write', path, { 'content' => content }, cwd: cwd, agent_id: agent_id) { File.write(path, content) }
        end

        def host_edit(path, old, new, cwd:)
          host_file('Edit', path, { 'old_string' => old, 'new_string' => new }, cwd: cwd) do
            File.write(path, File.read(path).sub(old) { new })
          end
        end

        # A Bash call through the guard, run as the guard rewrote it.
        def host_bash(cmd, cwd:, agent_id: nil, execute: true)
          data = { 'session_id' => 's1', 'tool_name' => 'Bash', 'tool_input' => { 'command' => cmd }, 'cwd' => cwd,
                   'tool_use_id' => next_id }
          data['agent_id'] = agent_id if agent_id
          pre = hooks.handle('PreToolUse', data)
          assert_equal 'allow', pre&.dig('hookSpecificOutput', 'permissionDecision'), "#{cmd}: #{pre.inspect}"
          wrapped = pre.dig('hookSpecificOutput', 'updatedInput', 'command')
          assert_includes wrapped, Confinement::SANDBOX_EXEC
          out = ''
          ok = true
          if execute
            out, st = Open3.capture2e('/bin/bash', '-c', wrapped, chdir: cwd)
            ok = st.success?
          end
          hooks.handle('PostToolUse', data.merge('tool_response' => { 'stdout' => out, 'stderr' => '', 'interrupted' => false }))
          [out, ok]
        end

        def host_commit(run, msg)
          out, ok = host_bash("git add -A && #{GIT_ID} commit -q -m #{Shellwords.escape(msg)}", cwd: run.worktree)
          assert ok, "the confined commit failed: #{out}"
          git_out(run.worktree, 'rev-parse', 'HEAD')
        end

        # --- fixtures ----------------------------------------------------------

        def repo_files!(files, executable: [])
          system('git', 'init', '-q', '-b', 'main', @root, exception: true)
          { '.gitignore' => GITIGNORE }.merge(files).each { |rel, body| put(@root, rel, body) }
          executable.each { |rel| File.chmod(0o755, File.join(@root, rel)) }
          git!(@root, 'add', '-A')
          git!(@root, 'commit', '-q', '-m', 'base')
        end

        def collect_round(reviews:, p0_lines: [], counted: 2)
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = {
            'status' => 'ok', 'reviews' => reviews,
            'aggregated_findings' => p0_lines.map { |t| { 'severity' => 'P0', 'issue' => t } },
            'vote_tally' => { 'successful_count' => counted, 'min_quorum' => 2 }
          }
        end

        def labels(list)
          @script['review_labels'] = { 'answer' => list, 'class' => 'decided' }
        end

        def write_design(version, body)
          path = File.join(@root, 'log', "x_design_v#{version}.md")
          assert_equal 'allow', host_write(path, body, cwd: @root)
          path
        end

        def design_run(rounds: nil)
          review_rounds!(rounds) if rounds
          run = started('template' => 'design_only', 'design_glob' => 'log/x_design_v*.md')
          write_design('0.1', "# x design v0.1\nINV-1: the cache holds at most 100 entries.\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          run
        end

        # A design-only run whose review closed; the host's Stop then asks for
        # the report.
        def closed_design_run
          run = design_run
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: APPROVE)
          labels([])
          out = host_advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          block = host_stop('The design review closed.')
          assert_equal 'block', block&.dig('decision'), 'all phases ended: the host is told to build the report'
          assert_includes block['reason'], 'subagent'
          run.reload
        end

        def report_dir(run)
          File.join(@root, 'log', 'agent_runs', run.id)
        end

        def skip_unless_kit
          _, st = Open3.capture2e('python3', '-c', 'import json, html')
          skip 'python3 is unavailable' unless st.success?
        rescue SystemCallError
          skip 'python3 is unavailable'
        end

        def playwright_ready?
          _, st = Open3.capture2e('python3', '-c', 'import playwright.async_api')
          browsers = ENV['PLAYWRIGHT_BROWSERS_PATH'].to_s
          st.success? && !Dir.glob(File.join(browsers, 'chromium*')).empty?
        rescue SystemCallError
          false
        end

        # The report subagent as report_step tells it: agent_status writes
        # material.json, the kit's generator runs through confined Bash, and
        # the subagent's turn ends.
        def subagent_builds_deck(run)
          st = host_tool('status', { 'run_id' => run.id, 'report_material' => true }, agent_id: SUBAGENT)
          material = st.dig('report_material', 'material_path')
          deck = File.join(report_dir(run), 'deck.html')
          cmd = "python3 #{Shellwords.escape(File.join(KIT, 'make_report_deck.py'))} #{Shellwords.escape(material)} " \
                "#{Shellwords.escape(deck)}"
          out, ok = host_bash(cmd, cwd: @root, agent_id: SUBAGENT)
          assert ok, "the kit's generator failed confined: #{out}"
          assert_nil hooks.handle('SubagentStop', 'session_id' => 's1', 'agent_id' => SUBAGENT,
                                                  'last_assistant_message' => 'deck.html is built from material.json.')
          deck
        end

        # A service whose run_cmd runs everything for real, check.py included.
        def real_service
          real = Service.allocate
          run_cmd = lambda do |argv, chdir, timeout|
            @cmds << argv
            real.send(:default_run_cmd, argv, chdir, timeout)
          end
          Service.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in },
                      invoke: ->(name, args) { @invoked << [name, args]; @mlr.fetch(name) { {} } },
                      chain: ->(logs) { @chain << logs; @chain.size }, run_cmd: run_cmd)
        end

        # --- what a glob pins ----------------------------------------------------

        # Trigger (operator_proxy P0): tests "srv/test_*.rb" pinned srv/lib/bar.rb,
        # and its Edit went to the stand-in and was denied.
        def test_a_glob_under_a_directory_pins_only_the_tests_it_matches
          repo!('srv/test_foo.rb' => "require_relative 'lib/x'\nexit(X == 1 ? 0 : 1)\n", 'srv/lib/x.rb' => "X = 1\n",
                'srv/lib/bar.rb' => "BAR = 1\n", 'srv/README.md' => "srv\n")
          run = started('template' => 'impl_cycle', 'tests' => 'srv/test_*.rb')
          wt = run.worktree
          foo = File.join(wt, 'srv', 'test_foo.rb')
          assert_equal [foo], run.pinned['implement']['tests'].keys, 'only the file the glob matches is pinned'

          assert_equal 'allow', host_edit(File.join(wt, 'srv', 'lib', 'x.rb'), 'X = 1', 'X = 1 # documented', cwd: wt)
          assert_equal 'allow', host_write(File.join(wt, 'srv', 'lib', 'bar.rb'), "BAR = 2\n", cwd: wt)
          assert_equal 'allow', host_write(File.join(wt, 'srv', 'lib', 'baz.rb'), "BAZ = 1\n", cwd: wt)
          assert_empty asks('pinned_test_change'), 'source beside the tests is edited without a stand-in call'

          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          assert_equal 'deny', host_edit(foo, 'X == 1', 'true', cwd: wt)
          assert_equal 1, asks('pinned_test_change').size, 'the matched test is pinned'

          host_commit(run, 'document x')
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal 1, out['ran']
          assert_equal [['ruby', '-Ilib', '-Itest', foo]], checks_ran
          assert_equal 1, asks('pinned_test_change').size, 'the source edits are not ruled at the check either'
          assert_equal 'block', host_stop&.dig('decision'), 'the check moved the run: the turn continues'
        end

        # --- a baseline for tests failing on the base commit -----------------------

        # Trigger (operator_proxy P1): a test file failing on main blocked the
        # implement phase forever.
        def test_a_test_failing_on_the_base_commit_does_not_block_but_a_new_failure_does
          repo!('test/test_broken_on_main.rb' => "require 'minitest/autorun'\nclass TestBrokenOnMain < Minitest::Test\n  " \
                                                 "def test_known_broken = assert(false, 'already failing on main')\nend\n",
                'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n", 'lib/x.rb' => "X_VALUE = 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'test')
          wt = run.worktree
          broken = File.join(wt, 'test', 'test_broken_on_main.rb')
          tx = File.join(wt, 'test', 'test_x.rb')
          added = File.join(wt, 'test', 'test_added.rb')

          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 2', cwd: wt)
          assert_equal 'allow', host_write(added, "exit 1 # a new test that fails\n", cwd: wt)
          host_commit(run, 'break x and add a failing test')
          out = host_advance(run)
          assert_equal 'tests_failed', out['status'], out.inspect
          assert_equal [added, tx], out['failed'].map { |f| f['file'] }.sort,
                       'a test the run broke and a test the run added block; the one failing on main does not'
          check = entries(run, 'check').last
          assert_equal [false, [broken]], [check['ok'], check['failing_before_the_run']]
          assert_equal 'implement', run.reload.current_phase
          assert_empty run.open_items_for('implement', %w[blocking]), 'a failing check is the actor\'s to fix, not an item'
          assert_equal 'block', host_stop('The tests fail; fixing them next.')&.dig('decision')

          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 2', 'X_VALUE = 1 # restored', cwd: wt)
          assert_equal 'allow', host_write(added, "exit 0 # the new test passes\n", cwd: wt)
          host_commit(run, 'fix')
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal 3, out['ran']
          assert_equal [broken], out['failing_before_the_run'], 'reported as failing before the run'
          assert_equal [broken], entries(run, 'check').last['failing_before_the_run']
          base = entries(run, 'baseline').group_by { |e| e['file'] }
          assert_equal({ 'test/test_added.rb' => [true], 'test/test_broken_on_main.rb' => [false], 'test/test_x.rb' => [true] },
                       base.transform_values { |es| es.map { |e| e['ok'] } }, 'each failing file is run on the base once per run')
        end

        # --- a non-ASCII test name ---------------------------------------------------

        # Trigger (fable P1): ls-tree quoted a non-ASCII path, the pin named a
        # file that did not exist, and every check reported it removed.
        def test_a_test_file_with_a_non_ascii_name_is_pinned_and_checked
          name = 'test_データ.rb'
          repo!("test/#{name}" => "exit 0\n", 'test/日本語/test_b.rb' => "exit 0\n", 'lib/x.rb' => "X = 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'test')
          wt = run.worktree
          t1 = File.join(wt, 'test', name)
          t2 = File.join(wt, 'test', '日本語', 'test_b.rb')
          pinned = run.pinned['implement']['tests']
          assert_equal [t1, t2].sort, pinned.keys.sort
          pinned.each_key { |k| assert File.file?(k), "#{k} is pinned by a path that exists" }
          assert_equal git_out(@root, 'rev-parse', "HEAD:test/#{name}"), pinned[t1]

          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          assert_equal 'deny', host_edit(t2, 'exit 0', 'exit 0 # weakened', cwd: wt), 'the guard knows it as a pinned test'
          assert_equal 1, asks('pinned_test_change').size

          # Changed through the shell, which the guard does not read: ruled at the check.
          out, ok = host_bash("printf 'exit 0 # weakened\\n' > '#{t1}' && git add -A && #{GIT_ID} commit -q -m weaken", cwd: wt)
          assert ok, out
          res = host_advance(run)
          assert_equal 'check_refused', res['status'], res.inspect
          assert_equal [t1], res['changed']
          ask = asks('pinned_test_change').last
          assert_equal "test/#{name}", ask[:evidence]['path']
          assert_equal "exit 0\n", ask[:evidence]['old'], 'the base text is read by the non-ASCII path'
          assert_equal "exit 0 # weakened\n", ask[:evidence]['new']

          out, ok = host_bash("git checkout #{run.base_commit} -- 'test/#{name}' && #{GIT_ID} commit -q -m restore", cwd: wt)
          assert ok, out
          res = host_advance(run)
          assert_equal 'phase_ended', res['status'], res.inspect
          assert_equal 2, res['ran']
          assert_empty res['removed_tests'], 'nothing reads as removed'
          assert_equal [t1, t2].sort, checks_ran.map(&:last).sort
        end

        # --- test_command ---------------------------------------------------------------

        # Trigger (sonnet P2, codex P1): ls, touch and inline code passed the
        # runner check.
        def test_a_test_command_names_a_runner_or_a_script_the_repository_tracks
          repo_files!({ 'bin/test' => "#!/bin/sh\nexec ruby -Ilib \"$@\"\n", 'test/test_ok.rb' => "exit 0\n" },
                      executable: ['bin/test'])
          File.write(File.join(@root, 'not_tracked.sh'), "#!/bin/sh\nexit 0\n")
          File.chmod(0o755, File.join(@root, 'not_tracked.sh'))
          ['ls', 'touch', 'git', 'wc', 'diff', './not_tracked.sh', 'ruby -e0', 'python3 -c pass'].each do |cmd|
            out = host_start('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => cmd)
            assert_equal 'refused', out['status'], "#{cmd.inspect} => #{out.inspect}"
            assert_match(/test_command/, out['reason'], cmd)
          end
          assert_empty Run.all(@paths), 'a refused command creates no run'
          assert_equal 'main', git_out(@root, 'branch', '--format=%(refname:short)'), 'nor a branch'
          assert_nil Run.bound_to(@paths, 's1')

          assert_nil Service.allocate.test_command_problem('./bin/test', @root), './bin/test is the tracked script'
          run = started('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => 'bin/test')
          assert_equal 'bin/test', run.plan.phase(:implement).args[:command]
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal [['bin/test', File.join(run.worktree, 'test', 'test_ok.rb')]], checks_ran
        end

        # The same inline code behind a combined switch (ruby -we0 is -w -e0;
        # python3 -Bc pass is -B -c pass) exits 0 whatever test file follows.
        def test_inline_code_behind_a_combined_switch_is_refused_too
          repo!('test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n", 'lib/x.rb' => "X_VALUE = 1\n")
          svc = Service.allocate
          let_through = ['ruby -we0', 'python3 -Bc pass', 'perl -le0'].select { |c| svc.test_command_problem(c, @root).nil? }
          if let_through.include?('ruby -we0')
            run = started('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => 'ruby -we0')
            assert_equal 'allow', host_edit(File.join(run.worktree, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 2', cwd: run.worktree)
            host_commit(run, 'break x')
            res = host_advance(run)
            if res['status'] == 'phase_ended'
              flunk("BUG: test_command_problem (service.rb:563) reads only a switch that starts with -e/-c; #{let_through.join(', ')} " \
                   'pass, and with "ruby -we0" a broken test/test_x.rb ended the implement phase')
            end
          end
          assert_empty let_through
        end

        # Trigger (sonnet P2, verbatim): "ruby /tmp/x.rb followed by the test
        # file as an ignored argument" passed the runner check. The test file
        # is appended after the script, so ruby runs the script, not the test.
        def test_a_runner_given_a_script_of_its_own_runs_that_script_not_the_tests
          repo!('test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n", 'lib/x.rb' => "X_VALUE = 1\n")
          script = File.join(@tmp, 'x.rb')
          File.write(script, "exit 0\n")
          cmd = "ruby #{script}"
          if Service.allocate.test_command_problem(cmd, @root).nil?
            run = started('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => cmd)
            assert_equal 'allow', host_edit(File.join(run.worktree, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 2', cwd: run.worktree)
            host_commit(run, 'break x')
            res = host_advance(run)
            if res['status'] == 'phase_ended'
              flunk("BUG: test_command_problem (service.rb:563) lets an interpreter take a positional script: \"ruby <tmp>/x.rb\" " \
                   "started, the check ran #{checks_ran.last.map { |a| File.basename(a) }.inspect}, and a broken " \
                   'test/test_x.rb ended the implement phase')
            end
          end
          assert_equal 'refused', host_start('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => cmd)['status']
        end

        # The tracked script runs from the run's worktree, where the run can
        # change it: a check judged by a rewritten script judges nothing.
        def test_the_tracked_test_script_is_not_the_runs_to_rewrite
          repo_files!({ 'bin/test' => "#!/bin/sh\nexec ruby -Ilib \"$@\"\n",
                        'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n", 'lib/x.rb' => "X_VALUE = 1\n" },
                      executable: ['bin/test'])
          run = started('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => 'bin/test')
          wt = run.worktree
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 2', cwd: wt)
          verdict = host_edit(File.join(wt, 'bin', 'test'), 'exec ruby -Ilib "$@"', 'exit 0', cwd: wt)
          host_commit(run, 'break x; simplify bin/test')
          res = host_advance(run)
          if verdict == 'allow' && asks('pinned_test_change').empty? && res['status'] == 'phase_ended'
            flunk('BUG: the tracked test script named by test_command (tracked_script?, service.rb:572) is neither pinned ' \
                 '(pin_tests, service.rb:365) nor run from the base (test_argv, service.rb:533): an Edit of bin/test to "exit 0" in the worktree is ' \
                 'allowed without a stand-in call and a broken test/test_x.rb ends the implement phase')
          end
          refute_equal 'phase_ended', res['status'], res.inspect
        end

        # --- the implementation review sees the commits it closes on --------------------

        # Trigger (codex P1): a round collected after new commits closed the
        # phase on replies that never saw them.
        def test_an_implementation_round_collected_after_new_commits_does_not_close
          repo!('test/test_x.rb' => "require 'x'\nexit(X_VALUE >= 1 ? 0 : 1)\n", 'lib/x.rb' => "X_VALUE = 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'test')
          wt = run.worktree
          x = File.join(wt, 'lib', 'x.rb')
          assert_equal 'allow', host_edit(x, 'X_VALUE = 1', 'X_VALUE = 2', cwd: wt)
          c1 = host_commit(run, 'v2')
          assert_equal 'phase_ended', host_advance(run)['status']
          out = host_advance(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal c1, entries(run, 'review_dispatched').last['commit']
          assert_equal 'block', host_stop('Round 1 is running.')&.dig('decision'), 'a round in flight: collect it'

          # The actor keeps working while the round runs.
          assert_equal 'allow', host_edit(x, 'X_VALUE = 2', 'X_VALUE = 3', cwd: wt)
          c2 = host_commit(run, 'v3 while round 1 ran')
          collect_round(reviews: APPROVE)
          labels([])
          out = host_advance(run)
          assert_equal 'open', out['status'], out.inspect
          run.reload
          assert_equal 'implementation_review', run.current_phase
          assert_empty run.provisional_closures
          assert(run.open_items.none? { |i| i['item_kind'] == 'closure' })
          sent = asks('review_labels').last[:evidence]['artifact_as_sent']
          assert_includes sent, 'X_VALUE = 2', 'the labeller reads the bundle round 1 was sent'
          refute_includes sent, 'X_VALUE = 3'
          assert_equal 'block', host_stop('Round 1 came back.')&.dig('decision')

          out = host_advance(run)
          assert_equal 'dispatched', out['status'], out.inspect
          recheck = entries(run, 'check').last
          assert_equal [c2, true, true], [recheck['commit'], recheck['recheck'], recheck['ok']], 'the new HEAD is checked first'
          assert_equal c2, entries(run, 'review_dispatched').last['commit']
          assert_includes dispatched.last.last['artifact_content'], 'X_VALUE = 3'
          out = host_advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal %w[implementation_review], run.reload.provisional_closures
          assert_equal 2, dispatched.size
        end

        # --- an unchanged bundle is not sent again ----------------------------------------

        # Trigger (lifecycle_tester P2): after a quorate round with an open P0,
        # an advance with no new design file sent the same artifact again and
        # spent a round toward the bound.
        def test_an_unchanged_artifact_is_not_sent_again_right_after_a_quorate_round
          run = design_run
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: [{ 'role_label' => 'codex', 'verdict' => 'REVISE', 'raw_text' => 'P0: the cache has no eviction' },
                                  { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'APPROVE' }],
                        p0_lines: ['the cache has no eviction'])
          labels([{ 'seat' => 'codex', 'text' => 'the cache has no eviction', 'label' => 'new' }])
          assert_equal 'open', host_advance(run)['status']
          assert_equal 'block', host_stop('Round 1 has one open P0.')&.dig('decision')

          out = host_advance(run) # no new design version
          if out['status'] == 'dispatched'
            flunk('BUG: review.rb:84-87 compares the whole bundle digest, and the bundle after a round with open P0s ' \
                 'carries them while the round\'s own bundle did not; so the unchanged design v0.1 is dispatched again ' \
                 "as round 2 (#{dispatched.size} dispatches) right after quorate round 1")
          end
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'nothing changed'
          assert_equal 1, dispatched.size
          assert_equal 1, run.reload.counters['review_rounds']
        end

        def test_the_same_bundle_is_refused_after_a_quorate_round_and_sent_again_after_a_round_without_quorum
          run = design_run
          p0 = 'the cache has no eviction'
          revise = [{ 'role_label' => 'codex', 'verdict' => 'REVISE', 'raw_text' => "P0: #{p0}" },
                    { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'APPROVE' }]
          # Round 1, quorate; its first labelling fails and is done again.
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: revise, p0_lines: [p0])
          @script['review_labels'] = { 'answer' => nil, 'class' => 'operator_item' }
          assert_equal 'labelling_failed', host_advance(run)['status']
          labels([{ 'seat' => 'codex', 'text' => p0, 'label' => 'new' }])
          assert_equal 'open', host_advance(run)['status']
          # Round 2 on v0.2, quorate; the P0 is still open in the same words.
          write_design('0.2', "# x design v0.2\nINV-1: the cache holds at most 100 entries (LRU).\n")
          assert_equal 'dispatched', host_advance(run)['status']
          labels([{ 'seat' => 'codex', 'text' => p0, 'label' => 'carried_over', 'earlier_id' => 'DR1.F1' }])
          assert_equal 'open', host_advance(run)['status']
          assert_equal 'block', host_stop('Round 2 still has the P0.')&.dig('decision')

          out = host_advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'nothing changed since round 2'
          assert_equal 2, dispatched.size
          assert_equal 2, run.reload.counters['review_rounds'], 'no round is spent'

          # Round 3 on v0.3 without quorum: the same bundle may go again.
          write_design('0.3', "# x design v0.3\nINV-1: an LRU of 100 entries; eviction on insert.\n")
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: revise.first(1), p0_lines: [p0], counted: 1)
          assert_equal 'no_quorum', host_advance(run)['status']
          out = host_advance(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 4, out['round']
          shas = entries(run, 'review_dispatched').map { |e| e['bundle_sha256'] }
          assert_equal shas[2], shas[3], 'round 4 carries the very bundle round 3 had'

          # Every labelling read the bundle its round was sent.
          sent = dispatched.map { |_, a| a['artifact_content'] }
          assert_equal [sent[0], sent[0], sent[1], sent[2]], asks('review_labels').map { |a| a[:evidence]['artifact_as_sent'] }
          assert_includes sent[1], "[DR1.F1] [codex] #{p0}", 'the carried P0 is in the bundle the labeller reads'
        end

        # --- finding ids carry their phase -----------------------------------------------

        # Trigger (operator_proxy P2): finding ids restarted in each phase
        # (R1.F1 in both reviews).
        def test_finding_ids_carry_the_phase_across_one_dev_cycle
          repo!('test/test_ok.rb' => "exit 0\n", 'lib/x.rb' => "X = 1\n")
          run = started('template' => 'dev_cycle', 'design_glob' => 'log/x_design_v*.md', 'tests' => 'test')
          write_design('0.1', "# x design v0.1\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: [{ 'role_label' => 'codex', 'verdict' => 'REVISE', 'raw_text' => 'P0: the cache is unbounded' },
                                  { 'role_label' => 'sonnet', 'verdict' => 'REJECT', 'raw_text' => 'No.' }],
                        p0_lines: ['the cache is unbounded'])
          labels([{ 'seat' => 'codex', 'text' => 'the cache is unbounded', 'label' => 'new' }])
          assert_equal 'open', host_advance(run)['status']
          write_design('0.2', "# x design v0.2\nThe cache is an LRU of 100.\n")
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: APPROVE)
          grounds = 'v0.2 section 1 bounds the cache as an LRU of 100 entries.'
          labels([{ 'seat' => 'codex', 'text' => 'the cache is unbounded', 'label' => 'fixed', 'earlier_id' => 'DR1.F1', 'grounds' => grounds },
                  { 'seat' => 'sonnet', 'text' => 'sonnet rejected', 'label' => 'fixed', 'earlier_id' => 'DR1.sonnet', 'grounds' => grounds }])
          assert_equal 'closed_provisionally', host_advance(run)['status']
          assert_equal 'block', host_stop('Design review closed provisionally.')&.dig('decision')

          wt = run.worktree
          assert_equal 'allow', host_write(File.join(wt, 'lib', 'parser.rb'), "def parse(s) = s.lines[0..-2]\n", cwd: wt)
          host_commit(run, 'parser')
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: [{ 'role_label' => 'codex', 'verdict' => 'REVISE', 'raw_text' => 'P0: the parser drops the last line' },
                                  { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'APPROVE' }],
                        p0_lines: ['the parser drops the last line'])
          labels([{ 'seat' => 'codex', 'text' => 'the parser drops the last line', 'label' => 'new' }])
          assert_equal 'open', host_advance(run)['status']

          ids = ->(phase, round) do
            e = entries(run, 'review_labelled').find { |l| l['phase'] == phase && l['round'] == round }
            e['labels'].map { |l| l['id'] }
          end
          assert_equal %w[DR1.F1 DR1.sonnet], ids.('design_review', 1)
          assert_equal %w[DR1.F1 DR1.sonnet], ids.('design_review', 2), 'a fixed P0 keeps its id'
          assert_equal %w[IR1.F1], ids.('implementation_review', 1)

          st = host_tool('status', { 'run_id' => run.id, 'report_material' => true }, agent_id: SUBAGENT)
          m = JSON.parse(File.read(st.dig('report_material', 'material_path')))
          by_round = m['review_rounds'].to_h { |r| ["#{r['phase']} #{r['round']}", Array(r['labels']).map { |l| l['id'] }] }
          assert_equal({ 'design_review 1' => %w[DR1.F1 DR1.sonnet], 'design_review 2' => %w[DR1.F1 DR1.sonnet],
                         'implementation_review 1' => %w[IR1.F1] }, by_round)
          assert_empty by_round['design_review 1'] & by_round['implementation_review 1'], 'no id names two findings'
        end

        # --- report material -------------------------------------------------------------------

        # Trigger (operator_proxy P1): a real run's material exceeded the host's
        # output cap and the subagent was told to Write it.
        def test_report_material_is_written_to_material_json_and_the_reply_names_it
          run = closed_design_run
          st = host_tool('status', { 'run_id' => run.id, 'report_material' => true }, agent_id: SUBAGENT)
          rm = st['report_material']
          path = File.join(report_dir(run), 'material.json')
          assert_equal path, rm['material_path']
          assert File.file?(path)
          m = JSON.parse(File.read(path))
          assert_equal run.id, m['run_id']
          assert_equal [m['decisions'].size, m['items'].size, m['phases'].size, m['effects'].size, m['review_rounds'].size],
                       rm.values_at('decisions', 'items', 'phases', 'effects', 'review_rounds'), 'the reply counts what the file holds'
          assert(rm.values_at('decisions', 'items', 'phases', 'effects').all?(Integer), 'counts, not the material itself')
          assert_operator JSON.generate(rm).bytesize, :<, File.size(path)
          assert(m['items'].any? { |i| i['item_kind'] == 'merge' } || run.branch.nil?)
          ids = m['decisions'].map { |d| d['id'] } + m['items'].map { |i| i['id'] } + m['phases'].map { |p| p['name'] }
          assert_empty service.completeness(run.reload, ids.join(' ')), 'the file names every id the report needs'
          assert_includes Guidance.report_step(run), "#{report_dir(run)}/material.json"
          assert(run.journal.entries.none? { |e| e['kind'] == 'effect' && e['path'].to_s.end_with?('material.json') },
                 'the SkillSet writes it; no tool call of the run did')
        end

        # --- who built the report ------------------------------------------------------------

        # Trigger (sonnet P2, operator_proxy P1, fable P3): a main-context ls,
        # cat or check.py on the deck refused agent_finish.
        def test_main_context_reads_of_the_deck_do_not_count_but_a_redirect_into_it_does
          skip_unless_kit
          run = closed_design_run
          deck = subagent_builds_deck(run)
          dir = report_dir(run)
          svc = service
          assert svc.built_by_subagent?(run, deck)
          ["ls -la #{dir}", "cat #{deck} | head -20", "wc -c #{deck} && grep -c '<section' #{deck}",
           "python3 #{File.join(KIT, 'check.py')} #{deck}"].each do |cmd|
            host_bash(cmd, cwd: @root, execute: !cmd.include?('check.py'))
            assert svc.built_by_subagent?(run, deck), "the main context only read the deck: #{cmd}"
          end

          host_bash("echo '<!-- main context -->' >> #{deck}", cwd: @root)
          assert_includes File.read(deck), 'main context'
          refute svc.built_by_subagent?(run, deck), 'a redirect into the deck is a write'
          out = host_tool('finish', { 'run_id' => run.id })
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'subagent'

          subagent_builds_deck(run)
          host_bash("ls #{dir} && python3 #{File.join(KIT, 'check.py')} #{deck}", cwd: @root, execute: false)
          out = host_tool('finish', { 'run_id' => run.id })
          assert_equal 'finished', out['status'], out.inspect
          assert_equal true, run.reload.report['built_by_subagent']
          assert_nil host_stop('The report is built.'), 'a finished run rests'
        end

        def test_a_main_context_redirect_into_the_deck_after_cd_counts_as_a_write
          skip_unless_kit
          run = closed_design_run
          deck = subagent_builds_deck(run)
          host_bash("cd #{report_dir(run)} && echo '<!-- edited by the main context -->' >> deck.html", cwd: @root)
          assert_includes File.read(deck), 'edited by the main context'
          out = host_tool('finish', { 'run_id' => run.id })
          if out['status'] == 'finished'
            flunk('BUG: writes_report? (service.rb:955-960) matches a redirect only when the target after > names ' \
                 'agent_runs; "cd <report dir> && echo … >> deck.html" by the main context is not a write, so ' \
                 'agent_finish accepted a deck the acting context edited last')
          end
          assert_equal 'refused', out['status'], out.inspect
        end

        def test_a_main_context_copy_of_the_deck_elsewhere_is_a_read
          skip_unless_kit
          run = closed_design_run
          deck = subagent_builds_deck(run)
          out, ok = host_bash("cp #{deck} \"$TMPDIR/deck_copy.html\"", cwd: @root)
          assert ok, out
          unless service.built_by_subagent?(run, deck)
            flunk('BUG: writes_report? (service.rb:959) counts any cp/mv/tee/install in a command naming the report dir; ' \
                 'the main context copying deck.html out to $TMPDIR is taken as a write into it and agent_finish refuses')
          end
          assert_equal 'finished', host_tool('finish', { 'run_id' => run.id })['status']
        end

        # --- the kit's check.py under confinement ------------------------------------------------

        # Trigger (fable P2 / sonnet P2): check.py, which opens the actor-side
        # HTML in a browser, ran unconfined; finish now runs it confined.
        def test_finish_runs_the_kits_check_py_confined_on_a_real_deck
          skip_unless_kit
          skip 'playwright or its chromium is not installed' unless playwright_ready?
          run = closed_design_run
          deck = subagent_builds_deck(run)
          out = host_tool('finish', { 'run_id' => run.id }, svc: real_service)
          assert_equal 'finished', out['status'], out.inspect
          assert_equal 'issues=0', out['checker'], "the kit's check.py ran in confinement: #{out['checker']}"
          built = run.reload.report
          assert_equal false, built['checker_unavailable']
          ran = @cmds.find { |a| a.any? { |x| x.to_s.end_with?('check.py') } }
          refute_nil ran
          i = ran.index(Confinement::SANDBOX_EXEC)
          refute_nil i, 'check.py runs under sandbox-exec'
          assert_equal ['python3', File.join(KIT, 'check.py'), deck], ran[(i + 3)..]
          assert_nil host_stop('The report is built.')
        end
      end
    end
  end
end
