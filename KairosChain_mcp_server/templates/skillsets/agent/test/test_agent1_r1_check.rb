# frozen_string_literal: true

# Implementation review R1, group "check": the implementation check (INV-2,
# INV-3) in lib/agent/service.rb. Real git repositories and real confined
# runs (sandbox-exec), all under a temporary directory; the stand-in and the
# review tools are scripted.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'open3'
require_relative '../lib/agent/service'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R1Check < Minitest::Test
        POLICY_SRC = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 8, stand_in_calls: 100 }
          end
        RUBY
        GITIGNORE = ".kairos/\nlog/\n.claude/\n__pycache__/\n.pytest_cache/\n"
        ENV_KEYS = %w[KAIROS_AGENT_GLOBAL GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].freeze

        # Answers from a script keyed by decision point (default: the first
        # option, decided), recording every question.
        class CheckStandIn
          attr_reader :asked

          def initialize(script)
            @script = script
            @asked = []
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
            @asked << { point: point, question: question, evidence: evidence, options: options }
            reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
            StandIn::Answer.new(answer: reply['answer'], klass: reply['class'], confidence: 0.9,
                                basis: ['instruction_mode'], reason: 'scripted', calls: 1, inputs_digest: 'x' * 64)
          end

          def rule_hazard(text, **kw)
            a = ask(point: 'hazard', question: text, options: StandIn::HAZARD_RULINGS, **kw)
            [a.answer.to_s, a]
          end
        end

        def setup
          skip 'sandbox-exec unavailable' unless Confinement.available?
          @saved_env = ENV_KEYS.to_h { |k| [k, ENV.fetch(k, nil)] }
          @tmp = File.realpath(Dir.mktmpdir('a1r1chk'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@tmp, 'global_bound_sessions.txt')
          File.write(File.join(@tmp, 'gitconfig'), '')
          ENV['GIT_CONFIG_GLOBAL'] = File.join(@tmp, 'gitconfig')
          ENV['GIT_CONFIG_NOSYSTEM'] = '1'
          @root = File.join(@tmp, 'proj')
          FileUtils.mkdir_p(File.join(@root, 'log'))
          @paths = Paths.new(File.join(@root, '.kairos'))
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'p1.rb'), POLICY_SRC)
          @policy = DSL.parse_policy(POLICY_SRC)
          @script = {}
          @stand_in = CheckStandIn.new(@script)
          @chain = []
          @invoked = []
          @mlr = { 'multi_llm_review' => { 'collect_token' => 'tok1' } }
          @cmds = []
          @transcript = File.join(@tmp, 'transcript.jsonl')
          File.write(@transcript, '')
          Precedents.new(@paths.precedents_dir).add([{ 'source' => 'seed', 'project' => 'proj', 'at' => '2026-10-01',
                                                       'kind' => 'typed_answer', 'question' => '査読は何周?',
                                                       'words' => '収束するまで回して' }])
        end

        def teardown
          return unless @tmp

          Run.all(@paths).each { |r| FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', r.id)) }
          FileUtils.rm_rf(@tmp)
          @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
        end

        # --- harness ------------------------------------------------------------

        # The kit's checker is faked; git and the confined checks run for real.
        # Every run_cmd call is recorded, so the checks' argv can be read back.
        def service
          real = Service.allocate
          run_cmd = lambda do |argv, chdir, timeout|
            @cmds << argv
            next ["issues=0\n", true] if argv.any? { |a| a.to_s.end_with?('check.py') }

            real.send(:default_run_cmd, argv, chdir, timeout)
          end
          Service.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in },
                      invoke: lambda { |name, args|
                        @invoked << [name, args]
                        @mlr.fetch(name) { {} }
                      },
                      chain: ->(logs) { @chain << logs; @chain.size }, run_cmd: run_cmd)
        end

        def hooks
          Hooks.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in })
        end

        # The argv of every confined check run (what follows sandbox-exec -p <profile>).
        def checks_ran
          @cmds.filter_map do |a|
            i = a.index(Confinement::SANDBOX_EXEC)
            i && a[(i + 3)..]
          end
        end

        def via_hook(sid, tool, args)
          out = hooks.handle('PreToolUse', 'session_id' => sid, 'tool_name' => "mcp__kairos-chain__#{tool}", 'tool_input' => args)
          out.dig('hookSpecificOutput', 'updatedInput')
        end

        def pre(run, tool, input)
          hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => tool, 'tool_input' => input, 'cwd' => run.worktree)
        end

        def adopt!
          words = "adopt policy p1 #{@policy.digest[0, 8]} でお願いします"
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => 'pr1', 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => words }))
          end
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => words, 'prompt_id' => 'pr1',
                                           'transcript_path' => @transcript)
          assert_equal 'adopted', service.items('action' => 'adopt_policy', 'policy' => 'p1')['status']
        end

        # The policy's review_rounds is the cap of each review, counted apart
        # (design v0.6.6). This writes a policy of the same shape with n rounds
        # for each review (call it before the first agent_start).
        def review_rounds!(n)
          src = POLICY_SRC.sub('review_rounds: 8', "review_rounds: #{n}")
          File.write(File.join(@paths.policies_dir, 'p1.rb'), src)
          @policy = DSL.parse_policy(src)
        end

        # The rounds a review may take now: the policy's cap plus the rounds
        # the operator granted that review.
        def review_cap(run, phase)
          run.reload.spend['review_rounds'].to_i + run.round_extensions[phase.to_s].to_i
        end

        def git!(dir, *args)
          system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', *args, exception: true)
        end

        def git_out(dir, *args)
          out, st = Open3.capture2('git', '-C', dir, *args)
          raise "git #{args.join(' ')} failed" unless st.success?

          out.strip
        end

        def repo!(files)
          system('git', 'init', '-q', '-b', 'main', @root, exception: true)
          { '.gitignore' => GITIGNORE }.merge(files).each { |rel, body| put(@root, rel, body) }
          git!(@root, 'add', '-A')
          git!(@root, 'commit', '-q', '-m', 'base')
        end

        def put(dir, rel, body)
          p = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(p))
          File.write(p, body)
          p
        end

        def commit_all!(run, msg)
          git!(run.worktree, 'add', '-A')
          git!(run.worktree, 'commit', '-q', '-m', msg)
          git_out(run.worktree, 'rev-parse', 'HEAD')
        end

        def start_run(template: 'impl_cycle', tests: 'test', test_command: nil)
          adopt! unless Policies.new(@paths).adopted
          args = { 'goal' => 'make x work', 'template' => template, 'tests' => tests }
          args['design_glob'] = 'log/x_design_v*.md' if %w[dev_cycle design_only].include?(template)
          args['test_command'] = test_command if test_command
          out = service.start(via_hook('s1', 'agent_start', args))
          [out, out['run_id'] && Run.load(@paths, out['run_id'])]
        end

        def started_run(**kw)
          out, run = start_run(**kw)
          assert_equal 'started', out['status'], out.inspect
          run
        end

        def advance(run)
          service.advance('run_id' => run.id, '_session_id' => 's1')
        end

        def asks(point)
          @stand_in.asked.select { |a| a[:point] == point }
        end

        def entries(run, kind)
          run.reload.journal.entries.select { |e| e['kind'] == kind }
        end

        def dispatched
          @invoked.select { |n, _| n == 'multi_llm_review' }
        end

        # --- pin at start ---------------------------------------------------------

        def test_every_file_under_the_tests_dir_is_pinned_from_the_base_and_a_weakening_before_the_first_advance_is_ruled
          repo!('test/test_ok.rb' => "exit 0\n", 'test/helper.rb' => "HELPER = 1\n",
                'test/fixtures/data.txt' => "42\n", 'lib/x.rb' => "X = 1\n")
          run = started_run
          pin = run.pinned['implement']
          expected = %w[test/fixtures/data.txt test/helper.rb test/test_ok.rb].to_h do |rel|
            [File.join(run.worktree, rel), git_out(@root, 'rev-parse', "HEAD:#{rel}")]
          end
          assert_equal expected, pin['tests'], 'helpers and fixtures are pinned by the base commit\'s blob ids'
          assert_equal git_out(@root, 'rev-parse', 'HEAD'), run.base_commit
          assert_equal run.base_commit, pin['base']
          assert_empty(run.journal.entries.select { |e| %w[plan_ratified check].include?(e['kind']) },
                       'the pin is taken at agent_start, before any advance')

          helper = put(run.worktree, 'test/helper.rb', "HELPER = 0 # weakened\n")
          commit_all!(run, 'weaken the helper before the first advance')
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          out = advance(run)
          assert_equal 'check_refused', out['status'], out.inspect
          assert_equal [helper], out['changed']
          ask = asks('pinned_test_change').last
          assert_equal 'test/helper.rb', ask[:evidence]['path']
          assert_equal "HELPER = 1\n", ask[:evidence]['old'], 'the old text is the base commit\'s'
          assert_empty checks_ran, 'nothing ran before the ruling'

          git!(run.worktree, 'checkout', run.base_commit, '--', 'test/helper.rb')
          fixture = File.join(run.worktree, 'test', 'fixtures', 'data.txt')
          FileUtils.rm(fixture)
          commit_all!(run, 'restore the helper, drop the fixture')
          out = advance(run)
          assert_equal 'check_refused', out['status'], out.inspect
          assert_equal [fixture], out['changed'], 'a removed fixture is a change to the pinned set'
          assert_equal '(removed)', asks('pinned_test_change').last[:evidence]['new']

          @script['pinned_test_change'] = { 'answer' => 'approve', 'class' => 'decided' }
          out = advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal [fixture], out['removed_tests'], 'the re-run reports the test that left the set'
        end

        # --- committed state only ---------------------------------------------------

        def test_uncommitted_work_is_refused_and_nothing_runs
          repo!('test/test_ok.rb' => "exit 0\n", 'README.md' => "r\n")
          run = started_run
          extra = put(run.worktree, 'lib/new.rb', "N = 1\n")
          out = advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'uncommitted'
          assert_includes out['uncommitted'], '?? lib/'

          FileUtils.rm_rf(File.dirname(extra))
          put(run.worktree, 'README.md', "changed\n")
          out = advance(run)
          assert_equal 'refused', out['status'], 'a modified tracked file is uncommitted work too'
          assert_includes out['uncommitted'], ' M README.md'
          assert_empty checks_ran
          assert_empty entries(run, 'check')

          head = commit_all!(run, 'readme')
          out = advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal head, out['commit']
        end

        # --- test_command -------------------------------------------------------------

        def test_test_commands_that_would_run_no_tests_are_refused_at_start
          repo!('test/test_ok.rb' => "exit 0\n")
          bad = ['true', 'true #', '/usr/bin/true', ':', 'false', 'bash -c "ruby test/test_ok.rb"', 'sh -c ruby',
                 'env true', 'nice true', 'ruby -e "exit 0"', 'ruby -Itest ; true', 'ruby -Itest | cat', 'ruby -Itest && true',
                 'ruby $(true)', 'ruby `true`', "ruby 'unterminated", '']
          bad.each do |cmd|
            out, run = start_run(test_command: cmd)
            assert_equal 'refused', out['status'], "#{cmd.inspect} => #{out.inspect}"
            assert_match(/test_command|shell/, out['reason'], cmd.inspect)
            assert_nil run
          end
          assert_empty Run.all(@paths), 'a refused command creates no run'
          refute Dir.exist?(File.join(@root, '.claude', 'worktrees')), 'nor a worktree'
          assert_equal 'main', git_out(@root, 'branch', '--format=%(refname:short)'), 'nor a branch'

          out, run = start_run(test_command: 'ruby -W0')
          assert_equal 'started', out['status'], out.inspect
          assert_equal 'ruby -W0', run.plan.phase(:implement).args[:command]
        end

        def test_a_wrapper_around_a_non_runner_is_refused_at_start
          repo!('test/test_fails.rb' => "exit 1\n")
          out, run = start_run(test_command: 'nice true')
          unless out['status'] == 'refused'
            res = advance(run)
            flunk("'nice true' started; with the plan approved, a test that exits 1 gave #{res['status']} " \
                  "(ran #{checks_ran.inspect})")
          end
          svc = Service.allocate
          ['/usr/bin/time true', 'command true', 'caffeinate -i true'].each { |c| refute_nil svc.test_command_problem(c), c }
        end

        # --- runners -------------------------------------------------------------------

        def test_default_runners_are_ruby_for_ruby_tests_and_pytest_for_python
          svc = Service.allocate
          phase = DSL::Phase.new(name: :implement, kind: :check, args: { tests: 'test', command: nil })
          { '/w/test/test_a.rb' => %w[ruby -Ilib -Itest], '/w/test/b_test.rb' => %w[ruby -Ilib -Itest],
            '/w/test/test_c.py' => %w[python3 -m pytest -q], '/w/test/c_test.py' => %w[python3 -m pytest -q] }.each do |f, pre|
            assert_equal pre + [f], svc.test_argv(phase, f)
          end
          %w[/w/test/x.test.js /w/test/x_spec.rb /w/test/x_test.go].each { |f| assert_nil svc.test_argv(phase, f), f }

          repo!('test/test_a.rb' => "exit 0\n", 'test/b_test.rb' => "exit 0\n",
                'test/test_c.py' => "def test_c():\n    assert 1 + 1 == 2\n")
          run = started_run
          out = advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal 3, out['ran']
          t = ->(n) { File.join(run.worktree, 'test', n) }
          assert_equal [['ruby', '-Ilib', '-Itest', t['b_test.rb']], ['ruby', '-Ilib', '-Itest', t['test_a.rb']],
                        ['python3', '-m', 'pytest', '-q', t['test_c.py']]], checks_ran.sort_by(&:last)
        end

        def test_a_test_file_with_no_runner_is_refused_naming_test_command
          repo!('test/test_a.rb' => "exit 0\n", 'test/widget.test.js' => "process.exit(1)\n")
          run = started_run
          out = advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'widget.test.js'
          assert_includes out['reason'], 'test_command'
          assert_empty checks_ran, 'not even the ruby test runs'
          assert_empty entries(run, 'check')
          assert_equal 'implement', run.current_phase
        end

        def test_a_check_that_would_run_zero_tests_is_refused
          repo!('test/helper.rb' => "# helper\n", 'test/fixtures/a.txt' => "a\n", 'lib/x.rb' => "X = 1\n")
          run = started_run(tests: 'test/**/test_*.rb')
          assert_empty run.pinned['implement']['tests'], 'a glob pins only the files it matches, never the source beside them'
          out = advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'runs nothing'
          assert_empty checks_ran
          assert_empty entries(run, 'check')
          assert_equal 'implement', run.current_phase
        end

        # --- the implementation review reviews the tested code ----------------------

        def test_the_review_reruns_the_check_when_head_moved_and_refuses_dispatch_if_it_fails
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          run = started_run
          put(run.worktree, 'lib/x.rb', "X_VALUE = 1 # v2\n")
          c1 = commit_all!(run, 'v2')
          assert_equal 'phase_ended', advance(run)['status']
          assert_equal c1, entries(run, 'check').last['commit']

          put(run.worktree, 'lib/x.rb', "X_VALUE = 2\n")
          c2 = commit_all!(run, 'break it after the check')
          out = advance(run)
          assert_equal 'tests_failed', out['status'], out.inspect
          last = entries(run, 'check').last
          assert_equal [c2, true, false], [last['commit'], last['recheck'], last['ok']]
          assert_empty dispatched, 'code that fails its check is not sent to review'

          put(run.worktree, 'lib/x.rb', "X_VALUE = 1 # v3\n")
          out = advance(run)
          assert_equal 'refused', out['status'], 'uncommitted work is not rechecked or reviewed'
          assert_empty dispatched

          c3 = commit_all!(run, 'v3')
          out = advance(run)
          assert_equal 'dispatched', out['status'], out.inspect
          last = entries(run, 'check').last
          assert_equal [c3, true, true], [last['commit'], last['recheck'], last['ok']]
          assert_equal 1, dispatched.size
          assert_includes dispatched.first.last['artifact_content'], 'X_VALUE = 1 # v3'
          assert_equal c3, entries(run, 'review_dispatched').last['commit']
        end

        def test_the_review_refuses_dispatch_when_the_branch_has_no_commits
          repo!('test/test_ok.rb' => "exit 0\n")
          run = started_run
          assert_equal 'phase_ended', advance(run)['status']
          out = advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'no commits'
          assert_empty dispatched
          assert_equal 'implementation_review', run.reload.current_phase
        end

        def test_a_diff_above_the_limit_opens_one_blocking_item_and_dispatches_nothing
          repo!('test/test_ok.rb' => "exit 0\n")
          run = started_run
          put(run.worktree, 'lib/big.txt', "#{'a' * 99}\n" * 2600)
          commit_all!(run, 'big')
          assert_equal 'phase_ended', advance(run)['status']
          2.times do
            out = advance(run)
            assert_equal 'refused', out['status'], out.inspect
            assert_includes out['reason'], Service::DIFF_LIMIT.to_s
          end
          items = run.reload.open_items.select { |i| i['item_kind'] == 'blocking' && i['text'].include?('diff exceeds') }
          assert_equal 1, items.size, 'one item, not one per advance'
          assert_equal 'implementation_review', items.first.dig('state_ref', 'ref')
          assert_empty dispatched
          assert_empty asks('data_check'), 'no part of the diff is even prepared for dispatch'
        end

        # --- a pinned change the hook approved --------------------------------------

        def test_a_pinned_change_the_hook_approved_is_not_ruled_again_at_advance
          repo!('test/test_ok.rb' => "x = 1\nexit(x == 1 ? 0 : 1)\n", 'test/helper.rb' => "# helper\n")
          run = started_run
          @script['pinned_test_change'] = { 'answer' => 'approve', 'class' => 'decided' }
          t = File.join(run.worktree, 'test', 'test_ok.rb')
          out = pre(run, 'Edit', 'file_path' => t, 'old_string' => 'x = 1', 'new_string' => 'x = 1 # same check, named')
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
          File.write(t, File.read(t).sub('x = 1', 'x = 1 # same check, named'))
          h = File.join(run.worktree, 'test', 'helper.rb')
          out = pre(run, 'Write', 'file_path' => h, 'content' => "# helper, documented\n")
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
          File.write(h, "# helper, documented\n")
          commit_all!(run, 'clarify the tests')
          assert_equal 2, asks('pinned_test_change').size

          ruled = entries(run, 'pinned_change').to_h { |e| [e['path'], e['digest']] }
          assert_equal git_out(run.worktree, 'rev-parse', 'HEAD:test/test_ok.rb'), ruled[t], 'the blob id the edit produces'
          assert_equal git_out(run.worktree, 'rev-parse', 'HEAD:test/helper.rb'), ruled[h]

          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          out = advance(run)
          assert_equal 'phase_ended', out['status'], 'a second ruling would have refused: ' + out.inspect
          assert_equal 2, asks('pinned_test_change').size, 'no second ruling at advance'
        end

        def test_a_pinned_change_the_hook_approved_through_multiedit_is_not_ruled_again
          repo!('test/test_ok.rb' => "x = 1\nexit(x == 1 ? 0 : 1)\n")
          run = started_run
          @script['pinned_test_change'] = { 'answer' => 'approve', 'class' => 'decided' }
          t = File.join(run.worktree, 'test', 'test_ok.rb')
          out = pre(run, 'MultiEdit', 'file_path' => t,
                                      'edits' => [{ 'old_string' => 'x = 1', 'new_string' => 'x = 1 # named' }])
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
          File.write(t, File.read(t).sub('x = 1', 'x = 1 # named'))
          assert_includes asks('pinned_test_change').first[:evidence]['new'].to_s, 'x = 1 # named',
                          'the stand-in sees the edits it approves'
          commit_all!(run, 'clarify')
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          out = advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal 1, asks('pinned_test_change').size
        end

        # --- plan ratification ------------------------------------------------------

        def test_a_ratified_tests_directory_amends_the_pinned_plan_and_the_ruling_offers_no_rounds
          repo!('test/test_ok.rb' => "exit 0\n", 'tests/test_ok.rb' => "exit 0\n")
          run = started_run(template: 'dev_cycle')
          before = run.plan_digest
          assert_equal 'test', run.plan.phase(:implement).args[:tests]
          assert_nil run.plan.phase(:design_review).args[:max_rounds], 'a review has no round bound of its own'
          # A rounds token is not a ruling any more: it changes nothing.
          @script['plan_parameters'] = { 'answer' => ['rounds:5/3', 'tests:tests'], 'class' => 'decided' }
          assert_equal 'not_yet', advance(run)['status']

          ask = asks('plan_parameters').first
          assert_equal ['approve', 'tests:<directory>', 'reject_test_command'], ask[:options]
          refute_match(/round/i, ask[:question], 'the ruling question offers no rounds option')

          run = Run.load(@paths, run.id)
          amended = entries(run, 'plan_amended')
          assert_equal 1, amended.size
          assert_equal before, amended.first['from']
          assert_equal({ 'tests' => 'tests' }, amended.first['changes'])
          assert_equal DSL.digest(File.read(File.join(run.dir, 'plans', "#{amended.first['digest']}.rb"))), amended.first['digest']
          assert_equal amended.first['digest'], run.plan_digest
          plan = run.plan
          assert_equal 'tests', plan.phase(:implement).args[:tests]
          %i[design_review implementation_review].each { |p| assert_nil plan.phase(p).args[:max_rounds] }
          ratified = entries(run, 'plan_ratified').first
          assert_equal({ 'tests' => 'tests' }, ratified['applied'])
          assert_equal 'plan_parameters', run.decisions.find { |d| d['id'] == ratified['decision'] }['point']
          assert_equal [File.join(run.worktree, 'tests', 'test_ok.rb')], run.pinned['implement']['tests'].keys,
                       'the amended tests directory is pinned again from the base commit'

          advance(run)
          assert_equal 1, asks('plan_parameters').size, 'ratified once'
          assert_equal 1, entries(run, 'plan_amended').size
        end

        def test_reject_test_command_drops_the_command_and_the_default_runner_runs
          repo!('test/test_ok.rb' => "exit 0\n")
          run = started_run(test_command: 'ruby -W0')
          @script['plan_parameters'] = { 'answer' => ['reject_test_command'], 'class' => 'decided' }
          out = advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          run = Run.load(@paths, run.id)
          assert_nil run.plan.phase(:implement).args[:command]
          assert_equal({ 'test_command' => nil }, entries(run, 'plan_amended').first['changes'])
          assert_equal [['ruby', '-Ilib', '-Itest', File.join(run.worktree, 'test', 'test_ok.rb')]], checks_ran
        end

        def test_an_unruled_plan_stays_as_started_keeps_a_runner_command_and_opens_an_item
          repo!('test/test_ok.rb' => "exit 0\n")
          run = started_run(template: 'dev_cycle', test_command: 'ruby -W0')
          before = run.plan_digest
          @script['plan_parameters'] = { 'answer' => nil, 'class' => 'operator_item' }
          advance(run)
          run = Run.load(@paths, run.id)
          plan = run.plan
          assert_equal before, run.plan_digest, 'the plan stands as started'
          assert_empty entries(run, 'plan_amended')
          assert_equal({}, entries(run, 'plan_ratified').first['applied'])
          %i[design_review implementation_review].each { |p| assert_nil plan.phase(p).args[:max_rounds], 'no round bound is applied' }
          assert_equal 'ruby -W0', plan.phase(:implement).args[:command], 'a command that names a runner stays'
          items = run.open_items.select { |i| i['item_kind'] == 'plan_parameters' }
          assert_equal 1, items.size
          assert_includes items.first['text'], 'ruby -W0'
          assert_includes items.first['text'], 'the plan stands as started'
          assert_equal 1, entries(run, 'plan_ratified').size
        end

        def test_a_tampered_plan_rb_makes_run_plan_raise_before_and_after_an_amendment
          repo!('test/test_ok.rb' => "exit 0\n", 'tests/test_ok.rb' => "exit 0\n")
          run = started_run
          path = File.join(run.dir, 'plan.rb')
          original = File.read(path)
          assert_includes original, 'check tests: "test"'
          File.write(path, original.sub('check tests: "test"', 'check tests: "elsewhere"'))
          err = assert_raises(RuntimeError) { Run.load(@paths, run.id).plan }
          assert_includes err.message, 'does not match its pinned digest'
          File.write(path, original)

          @script['plan_parameters'] = { 'answer' => 'tests:tests', 'class' => 'decided' }
          assert_equal 'phase_ended', advance(run)['status']
          path = File.join(run.dir, 'plans', "#{Run.load(@paths, run.id).plan_digest}.rb")
          amended = File.read(path)
          assert_equal 'tests', Run.load(@paths, run.id).plan.phase(:implement).args[:tests]

          File.write(path, amended.sub('check tests: "tests"', 'check tests: "elsewhere"'))
          assert_raises(RuntimeError) { Run.load(@paths, run.id).plan }
          out = begin
            advance(run)
          rescue RuntimeError => e
            { 'status' => 'raised', 'reason' => e.message }
          end
          assert_equal 'raised', out['status'], out.inspect
          assert_empty dispatched, 'nothing is dispatched under a tampered plan'

          File.write(path, original)
          assert_raises(RuntimeError, 'the pre-amendment plan no longer matches either') { Run.load(@paths, run.id).plan }
        end
      end
    end
  end
end
