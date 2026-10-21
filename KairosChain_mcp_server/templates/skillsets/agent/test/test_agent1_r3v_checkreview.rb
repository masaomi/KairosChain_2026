# frozen_string_literal: true

# Verification of the fixes after implementation review R3, group
# "checkreview": the review rounds (a design version written while a round is
# in flight, the one automatic extension when the work changed after
# dispatch, the labelling's coverage of the extracted P0 lines, what the
# implementation bundle carries), the implementation check (test_command
# behind a wrapper, the files a runner reads, the helpers a glob pins, a glob
# without a command, script-style tests failing on the base commit), the
# report deck (pinned-test changes on the main slides, the run-id form for an
# answer from another session) and the core's upgrade warnings for a
# SkillSet's user-level leftovers.
#
# Every agent tool is called as the host calls it: PreToolUse (which hands
# the tool its session) -> the service -> PostToolUse, with the turn's Stop
# where the host fires it; one scenario runs every hook event through
# hooks/agent_hook.rb as a subprocess. Real git and sandbox-exec under a
# temporary directory; HOME, KAIROS_DATA_DIR, CLAUDE_PROJECT_DIR and
# KAIROS_AGENT_GLOBAL point into it. The stand-in and the review tools are
# scripted; no claude -p runs. The core upgrade runs in a subprocess with a
# temporary HOME, data directory and template.
require 'rbconfig'
require 'securerandom'
require_relative 'test_agent1_r2v_checkreview'

# The harnesses' own tests run in their own files.
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1R1Check)
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1R2Checkreview)

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R3Checkreview < TestAgent1R2Checkreview
        TestAgent1R2Checkreview.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }

        HOOK_SCRIPT = File.expand_path('../hooks/agent_hook.rb', __dir__)
        CORE_LIB = File.expand_path('../../../../lib', __dir__)
        AGENT_JSON = File.expand_path('../skillset.json', __dir__)
        GROUNDS = 'the artifact as sent bounds the cache at 100 entries with LRU eviction (section INV-1).'

        # Scripted answers keyed by decision point; a script entry may be a
        # callable that answers from the evidence. inputs_digest is a sha256
        # like the real stand-in's.
        class R3StandIn
          attr_reader :asked

          def initialize(script)
            @script = script
            @asked = []
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
            @asked << { point: point, question: question, evidence: evidence, options: options }
            reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
            reply = reply.call(evidence) if reply.respond_to?(:call)
            StandIn::Answer.new(answer: reply['answer'], klass: reply['class'], confidence: 0.9,
                                basis: ['instruction_mode'], reason: 'scripted', calls: 1,
                                inputs_digest: Digest::SHA256.hexdigest(JSON.generate([point, question, @asked.size])))
          end

          def rule_hazard(text, **kw)
            a = ask(point: 'hazard', question: text, options: StandIn::HAZARD_RULINGS, **kw)
            [a.answer.to_s, a]
          end
        end

        # The hook script as the host runs it: input on stdin, the event name
        # in it, the environment in the tmpdir.
        class ScriptHooks
          def initialize(test)
            @test = test
          end

          def handle(name, input)
            @test.script_event(name, input)
          end
        end

        def setup
          @py_saved = [ENV.fetch('PYTHONUSERBASE', nil)]
          real_home = ENV.fetch('HOME')
          super
          # The confined pytest finds the user's site packages where they are
          # installed (read only), as the harness does for rbenv.
          local = File.join(real_home, '.local')
          ENV['PYTHONUSERBASE'] ||= local if File.directory?(local)
          @stand_in = R3StandIn.new(@script)
          @script_events = []
        end

        def teardown
          super
        ensure
          v = @py_saved&.first
          v.nil? ? ENV.delete('PYTHONUSERBASE') : ENV['PYTHONUSERBASE'] = v
        end

        def hooks
          @use_script ? ScriptHooks.new(self) : super
        end

        def script_event(name, input)
          env = { 'HOME' => ENV.fetch('HOME'), 'KAIROS_DATA_DIR' => @paths.data_dir, 'CLAUDE_PROJECT_DIR' => @root,
                  'KAIROS_AGENT_GLOBAL' => ENV.fetch('KAIROS_AGENT_GLOBAL'), 'KAIROS_MCP_LIB' => nil }
          out, err, st = Open3.capture3(env, RbConfig.ruby, HOOK_SCRIPT,
                                        stdin_data: JSON.generate(input.merge('hook_event_name' => name)), chdir: @root)
          assert_equal 0, st.exitstatus, "#{name} hook failed: #{err}"
          @script_events << name
          out.strip.empty? ? nil : JSON.parse(out)
        end

        # --- the host, for any session -------------------------------------------

        def host_tool_as(sid, name, args, transcript: @transcript, agent_id: nil)
          input = { 'session_id' => sid, 'tool_name' => "mcp__kairos-chain__agent_#{name}", 'tool_input' => args,
                    'cwd' => @root, 'transcript_path' => transcript, 'tool_use_id' => next_id }
          input['agent_id'] = agent_id if agent_id
          pre = hooks.handle('PreToolUse', input)
          assert_equal 'allow', pre.dig('hookSpecificOutput', 'permissionDecision'), pre.inspect
          out = service.public_send(TOOLS.fetch(name), pre.dig('hookSpecificOutput', 'updatedInput'))
          hooks.handle('PostToolUse', input.merge('tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }]))
          out
        end

        def host_edit_as(sid, path, old, new, cwd:)
          data = { 'session_id' => sid, 'tool_name' => 'Edit',
                   'tool_input' => { 'file_path' => path, 'old_string' => old, 'new_string' => new },
                   'cwd' => cwd, 'tool_use_id' => next_id }
          out = hooks.handle('PreToolUse', data)
          decision = out&.dig('hookSpecificOutput', 'permissionDecision')
          if decision == 'allow'
            File.write(path, File.read(path).sub(old) { new })
            hooks.handle('PostToolUse', data.merge('tool_response' => { 'filePath' => path, 'success' => true }))
          end
          decision
        end

        # The operator types a prompt: the transcript records it as typed and
        # UserPromptSubmit fires.
        def type!(text, pid, sid: 's1', transcript: @transcript)
          File.open(transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => pid, 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => text }))
          end
          hooks.handle('UserPromptSubmit', 'session_id' => sid, 'prompt' => text, 'prompt_id' => pid,
                                           'transcript_path' => transcript)
        end

        def resolve(run, ref, decision = nil, **extra)
          args = { 'action' => 'resolve', 'run_id' => run.id, 'ref' => ref }
          args['decision'] = decision if decision
          host_tool('items', args.merge(extra.transform_keys(&:to_s)))
        end

        def p0_rounds(lines, verdict: 'REVISE')
          [{ 'role_label' => 'codex', 'verdict' => verdict, 'raw_text' => lines.map { |l| "P0: #{l}" }.join("\n") },
           { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'APPROVE' }]
        end

        def main_slides(html)
          html.scan(%r{<section class="slide" data-key="(m\d+)">(.*?)</section>}m).map(&:last).join("\n")
        end

        # =========================================================================
        # (1) A design version written while a design round is in flight
        # =========================================================================

        # Trigger (lifecycle_tester P1, t8): the HEAD-moved guard applied only
        # to implementation reviews; a design version written while a round
        # ran was never reviewed and design_latest named the old file. Every
        # hook event goes through hooks/agent_hook.rb as a subprocess.
        def test_a_design_version_written_during_a_round_keeps_it_from_closing_and_is_reviewed_next
          @use_script = true
          run = design_run
          v1 = File.join(@root, 'log', 'x_design_v0.1.md')
          assert_equal 'dispatched', host_advance(run)['status']
          assert_equal Digest::SHA256.file(v1).hexdigest, entries(run, 'review_dispatched').last['commit']
          assert_equal 'block', host_stop('Round 1 is running.')&.dig('decision'), 'a round in flight: collect it'

          # The actor writes the next version while round 1 runs.
          v2 = write_design('0.2', "# x design v0.2\nINV-1: an LRU of 100 entries, evicted on insert.\n")
          collect_round(reviews: APPROVE)
          labels([])
          out = host_advance(run)
          assert_equal 'open', out['status'], out.inspect
          run.reload
          assert_equal 'design_review', run.current_phase, 'round 1 saw v0.1 only: it does not close the review'
          assert_empty run.provisional_closures
          assert(run.open_items.none? { |i| i['item_kind'] == 'closure' })
          assert_equal 0, run.round_extensions['design_review'].to_i, 'a review has no bound of its own to extend'
          assert_empty entries(run, 'rounds_extended')
          assert_equal 'block', host_stop('Round 1 came back; v0.2 is newer.')&.dig('decision')

          out = host_advance(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 2, out['round']
          d2 = entries(run, 'review_dispatched').last
          assert_equal [v2, Digest::SHA256.file(v2).hexdigest], [d2['artifact'], d2['commit']]
          assert_equal 'x_design_v0.2.md', dispatched.last.last['artifact_name']
          assert_includes dispatched.last.last['artifact_content'], 'evicted on insert', 'round 2 carries v0.2'

          out = host_advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal 2, dispatched.size
          assert_equal v2, service.report_material(run.reload).dig('design_latest', 'path'), 'design_latest names v0.2'
          assert_includes @script_events, 'Stop'
          assert_operator @script_events.count('PreToolUse'), :>=, 6, 'the hook script ran every event'
        end

        # =========================================================================
        # (2) The automatic extension, at most once per review, only at its cap
        # =========================================================================

        # Trigger (lifecycle_tester P1, t12; sonnet P2): commits during each
        # round extended the review's rounds by one each time, without the
        # operator. The policy's review_rounds is the cap of each review (design
        # v0.6.6; here 2): below the cap a round that did not see the latest
        # commits is followed by another; at the cap the review waits for the
        # operator, who grants the round. Nothing is extended automatically.
        def test_work_changed_after_dispatch_gets_a_round_within_the_cap_and_at_the_cap_only_by_the_operator
          repo!('test/test_x.rb' => "require 'x'\nexit(X_VALUE >= 1 ? 0 : 1)\n", 'lib/x.rb' => "X_VALUE = 1\n")
          review_rounds!(2)
          run = started('template' => 'impl_cycle', 'tests' => 'test')
          wt = run.worktree
          x = File.join(wt, 'lib', 'x.rb')
          assert_equal 2, run.spend['review_rounds']
          assert_equal 'allow', host_edit(x, 'X_VALUE = 1', 'X_VALUE = 2', cwd: wt)
          host_commit(run, 'v2')
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          assert_equal 'block', host_stop('Round 1 is running.')&.dig('decision')

          # A commit during round 1, below the cap (2): another round sees it; nothing is extended.
          assert_equal 'allow', host_edit(x, 'X_VALUE = 2', 'X_VALUE = 3', cwd: wt)
          c2 = host_commit(run, 'v3 during round 1')
          collect_round(reviews: APPROVE)
          labels([])
          out = host_advance(run)
          assert_equal 'open', out['status'], out.inspect
          assert_empty entries(run, 'rounds_extended'), 'below the cap nothing is extended'
          assert_equal 2, review_cap(run, 'implementation_review')
          assert_equal 'block', host_stop('Round 1 came back before the last commit.')&.dig('decision')
          out = host_advance(run)
          assert_equal ['dispatched', 2], out.values_at('status', 'round'), out.inspect
          assert_equal c2, entries(run, 'review_dispatched').last['commit']

          # A commit during round 2, which is the cap: no round without the operator.
          assert_equal 'allow', host_edit(x, 'X_VALUE = 3', 'X_VALUE = 4', cwd: wt)
          c3 = host_commit(run, 'v4 during round 2')
          out = host_advance(run)
          assert_equal 'open', out['status'], out.inspect
          assert_empty entries(run, 'rounds_extended'), 'the cap is not extended without the operator'
          assert_equal 2, review_cap(run, 'implementation_review')
          host_stop('Round 2 came back before the last commit.')

          out = host_advance(run)
          assert_equal 'waiting', out['status'], out.inspect
          assert_equal 'implementation_review is at its round cap; it waits for the operator', out['reason']
          item = run.reload.items[out['item']]
          assert_equal 'review_open', item['item_kind']
          assert_includes item['text'], 'has had its 2 rounds'
          assert_equal 2, dispatched.size, 'the cap holds: no third round without the operator'
          host_stop('Round 3 needs the operator.')
          assert_equal 'waiting', host_advance(run)['status']
          assert_equal 2, dispatched.size
          assert_equal 'block', host_stop('Waiting on the operator.')&.dig('decision')
          run.reload
          assert_equal ['ended', 'waiting on operator items'], [run.status, run.end_reason]

          # The operator's words grant the round.
          type!("#{item['id']} はあと1周まわして", 'p-more')
          out = resolve(run, item['id'], 'more_rounds', rounds: 1)
          assert_equal 'running', out['run_status'], out.inspect
          assert_equal 1, entries(run, 'rounds_extended').size
          assert_equal item['id'], entries(run, 'rounds_extended').last['item']
          assert_equal 3, review_cap(run, 'implementation_review')
          assert_empty entries(run, 'spend_extended')
          assert_equal 2, run.reload.spend['review_rounds']
          out = host_advance(run)
          assert_equal ['dispatched', 3], out.values_at('status', 'round'), out.inspect
          assert_equal c3, entries(run, 'review_dispatched').last['commit']
          out = host_advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
        end

        # =========================================================================
        # (3) A labelling that covers only one of two extracted P0 lines
        # =========================================================================

        # Trigger (lifecycle_tester P1, t9): completeness checked only that the
        # labelling was not empty; one label closed a round with two P0 lines.
        def test_a_labelling_that_covers_one_of_two_p0_lines_fails_by_covers_or_by_count
          run = design_run
          lines = ['the cache has no eviction', 'the index is rebuilt on every read']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: p0_rounds(lines), p0_lines: lines)

          # One refuted label, covering line 0 only.
          labels([{ 'seat' => 'codex', 'text' => lines[0], 'label' => 'refuted', 'grounds' => GROUNDS, 'covers' => [0] }])
          out = host_advance(run)
          assert_equal 'labelling_failed', out['status'], out.inspect
          assert_equal 'labelling incomplete', out['reason']
          item = out['item']
          assert_equal 'design_review', run.reload.current_phase
          assert_empty run.provisional_closures
          assert(entries(run, 'review_labelled').empty?, 'an incomplete labelling is not recorded as the round\'s labels')
          assert_equal 'block', host_stop('The labelling failed; labelling again.')&.dig('decision')

          # One label and no coverage: the count must reach the lines.
          labels([{ 'seat' => 'codex', 'text' => lines.join('; '), 'label' => 'refuted', 'grounds' => GROUNDS }])
          out = host_advance(run)
          assert_equal ['labelling_failed', item], out.values_at('status', 'item'), out.inspect

          # Coverage of both lines: the round is labelled and closes.
          labels([{ 'seat' => 'codex', 'text' => lines.join('; '), 'label' => 'refuted', 'grounds' => GROUNDS, 'covers' => [0, 1] }])
          out = host_advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal 1, dispatched.size, 'every labelling read the same round; none dispatched again'
          assert_equal 3, asks('review_labels').size
          assert_equal 'resolved', run.reload.items[item]['state'], 'the labelling item clears'
          ev = asks('review_labels').last[:evidence]['p0_lines_the_review_tool_extracted']
          assert_equal [0, 1], ev.map { |l| l['index'] }, 'the labeller is shown each line with its index'
        end

        def test_without_coverage_as_many_labels_as_p0_lines_pass_and_the_open_one_stays_open
          run = design_run
          lines = ['the cache has no eviction', 'the index is rebuilt on every read']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: p0_rounds(lines), p0_lines: lines)
          labels([{ 'seat' => 'codex', 'text' => lines[0], 'label' => 'new' },
                  { 'seat' => 'codex', 'text' => lines[1], 'label' => 'refuted', 'grounds' => GROUNDS }])
          out = host_advance(run)
          assert_equal 'open', out['status'], out.inspect
          assert_equal [lines[0]], out['open_p0'].map { |o| o['text'] }
          assert_empty run.reload.provisional_closures
        end

        # =========================================================================
        # (4) What the implementation review bundle carries
        # =========================================================================

        # Trigger (operator_proxy P1): the implementation bundle was the diff
        # and diffstat only; the L1 workflow says implementation seats see the
        # design and the full source.
        def test_the_implementation_bundle_carries_the_runs_design_and_the_changed_files_in_full
          far = '# header line, far from the change'
          x_old = ([far] + (1..40).map { |i| "C#{i} = #{i}" } + ['X_VALUE = 1']).join("\n") + "\n"
          repo!('test/test_ok.rb' => "exit 0\n", 'lib/x.rb' => x_old)
          run = started('template' => 'dev_cycle', 'design_glob' => 'log/x_design_v*.md', 'tests' => 'test')
          design_body = "# x design v0.1\nINV-1: the cache holds at most 100 entries.\n"
          write_design('0.1', design_body)
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: APPROVE)
          labels([])
          assert_equal 'closed_provisionally', host_advance(run)['status']
          assert_equal 'block', host_stop('The design review closed provisionally.')&.dig('decision')

          wt = run.worktree
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 2', cwd: wt)
          new_rb = "# a new file\ndef parse(s) = s.lines\n"
          assert_equal 'allow', host_write(File.join(wt, 'lib', 'new.rb'), new_rb, cwd: wt)
          big = "#{'a' * 159_999}\n"
          assert_equal 'allow', host_write(File.join(wt, 'data', 'big.txt'), big, cwd: wt)
          assert_equal 'allow', host_write(File.join(wt, 'assets', 'blob.bin'), "PK\0\0\x01binary", cwd: wt)
          head = host_commit(run, 'x 2, parser, data')
          assert_equal 'phase_ended', host_advance(run)['status']
          out = host_advance(run)
          assert_equal 'dispatched', out['status'], out.inspect

          sent = dispatched.last.last['artifact_content']
          assert_includes sent, '## Implementation under review', 'an implementation review says so'
          refute_includes sent, '## Work under review'
          diff_part = sent[sent.index('### Diff')...sent.index('## The design this work follows')]
          assert_includes diff_part, '+X_VALUE = 2', 'the diff is there'
          refute_includes diff_part, far, 'the diff alone does not show the far line'
          assert_includes sent, "## The design this work follows (x_design_v0.1.md)\n\n#{design_body}"
          assert_includes sent, '## Changed files in full'
          assert_includes sent, "### lib/x.rb\n\n```\n#{File.read(File.join(wt, 'lib', 'x.rb'))}\n```", 'lib/x.rb in full'
          assert_includes sent, "### lib/new.rb\n\n```\n#{new_rb}\n```"
          refute_includes sent, '### data/big.txt', 'a file beyond the bound is not included'
          refute_includes sent, '### assets/blob.bin', 'nor a binary one'
          assert_match(/Not included \(size or binary\): .*assets\/blob\.bin/, sent)
          assert_match(/Not included \(size or binary\): .*data\/big\.txt/, sent)
          assert_equal head, entries(run, 'review_dispatched').last['commit']
          stored = File.read(entries(run, 'review_dispatched').last['bundle_file'])
          assert_equal sent, stored, 'the stored bundle is the one sent'
        end

        # =========================================================================
        # (5) test_command
        # =========================================================================

        # Trigger (fable P1): bundle exec ruby -e0, uv run python -c pass,
        # npx node -e 0 and bundle exec ./untracked.sh passed the runner check;
        # (sonnet P2) python3 -m this passed too.
        def test_inline_code_behind_a_wrapper_and_a_non_test_module_are_refused_and_runners_pass
          repo_files!({ 'test/test_x.py' => "import os, sys\nsys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))\n" \
                                             "from x import VALUE\n\ndef test_value():\n    assert VALUE == 1\n",
                        'lib/x.py' => "VALUE = 1\n", 'conftest.py' => "# root conftest\n" })
          File.write(File.join(@root, 'untracked.sh'), "#!/bin/sh\nexit 0\n")
          File.chmod(0o755, File.join(@root, 'untracked.sh'))
          ['bundle exec ruby -e0', 'uv run python -c pass', 'npx node -e 0', 'python3 -m this',
           'bundle exec ./untracked.sh'].each do |cmd|
            out = host_start('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => cmd)
            assert_equal 'refused', out['status'], "#{cmd.inspect} => #{out.inspect}"
            assert_match(/test_command/, out['reason'], cmd)
          end
          assert_empty Run.all(@paths), 'a refused command creates no run'
          assert_equal 'main', git_out(@root, 'branch', '--format=%(refname:short)'), 'nor a branch'

          svc = Service.allocate
          ['bundle exec rake test', 'uv run pytest', 'python3 -m pytest -q'].each do |cmd|
            assert_nil svc.test_command_problem(cmd, @root), cmd
          end
          # Two of them start in their own sessions (a start a second later:
          # the run's branch is named by the second).
          { 's_rake' => 'bundle exec rake test', 's_uv' => 'uv run pytest' }.each do |sid, cmd|
            adopt! unless Policies.new(@paths).adopted
            out = host_tool_as(sid, 'start', { 'goal' => 'make x work', 'template' => 'impl_cycle', 'tests' => 'test', 'test_command' => cmd })
            assert_equal 'started', out['status'], "#{cmd}: #{out.inspect}"
            assert_equal cmd, Run.load(@paths, out['run_id']).plan.phase(:implement).args[:command]
            sleep 1.1
          end

          # The third runs its tests: a broken lib fails the check, a fixed one passes.
          run = started('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => 'python3 -m pytest -q')
          wt = run.worktree
          assert_includes run.pinned['implement']['tests'].keys, File.join(wt, 'conftest.py'), 'pytest reads conftest.py'
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.py'), 'VALUE = 1', 'VALUE = 2', cwd: wt)
          host_commit(run, 'break x')
          out = host_advance(run)
          assert_equal 'tests_failed', out['status'], out.inspect
          assert_equal [File.join(wt, 'test', 'test_x.py')], out['failed'].map { |f| f['file'] }
          assert_equal ['python3', '-m', 'pytest', '-q', File.join(wt, 'test', 'test_x.py')], checks_ran.first
          assert_equal 'block', host_stop('The test fails; fixing it.')&.dig('decision')
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.py'), 'VALUE = 2', 'VALUE = 1 # restored', cwd: wt)
          host_commit(run, 'fix x')
          out = host_advance(run)
          assert_equal ['phase_ended', 1], out.values_at('status', 'ran'), out.inspect
        end

        # Trigger (sonnet P2): the build files that define what make, rake or
        # npm run were not pinned, so the actor could edit the test target.
        def test_make_rake_and_npm_commands_pin_the_file_that_defines_what_they_run
          repo_files!({ 'Makefile' => "test:\n\truby -Ilib test/test_x.rb\n", 'Rakefile' => "task(:test) { ruby 'test/test_x.rb' }\n",
                        'package.json' => %({"scripts":{"test":"node test/x.test.js"}}\n),
                        'test/test_x.rb' => "exit 0\n", 'lib/x.rb' => "X = 1\n" })
          adopt!
          runs = {}
          { 's_make' => ['make test', 'Makefile'], 's_rake' => ['rake test', 'Rakefile'],
            's_npm' => ['npm test', 'package.json'] }.each do |sid, (cmd, file)|
            out = host_tool_as(sid, 'start', { 'goal' => 'make x work', 'template' => 'impl_cycle', 'tests' => 'test', 'test_command' => cmd })
            assert_equal 'started', out['status'], "#{cmd}: #{out.inspect}"
            run = Run.load(@paths, out['run_id'])
            runs[sid] = run
            # package.json is deliberately not pinned (every dependency edit
            # would become a test change); its test script is a stated residual.
            pinned = run.pinned['implement']['tests'].keys.include?(File.join(run.worktree, file))
            file == 'package.json' ? refute(pinned, 'npm test does not pin package.json') : assert(pinned, "#{cmd} pins #{file}")
            sleep 1.1
          end
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          mk = runs['s_make']
          assert_equal 'deny', host_edit_as('s_make', File.join(mk.worktree, 'Makefile'), "\truby -Ilib test/test_x.rb", "\ttrue",
                                            cwd: mk.worktree), 'an edit of the pinned Makefile goes to the stand-in'
          assert_equal 1, asks('pinned_test_change').size
          assert_includes File.read(File.join(mk.worktree, 'Makefile')), "\truby -Ilib test/test_x.rb", 'the refused edit is not applied'
        end

        # The same rake command behind bundle exec: the Rakefile decides what
        # it runs just the same.
        def test_a_rake_command_behind_bundle_exec_pins_the_rakefile_too
          repo_files!({ 'Rakefile' => "task(:test) { ruby 'test/test_x.rb' }\n", 'test/test_x.rb' => "exit 0\n",
                        'lib/x.rb' => "X = 1\n" })
          run = started('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => 'bundle exec rake test')
          rakefile = File.join(run.worktree, 'Rakefile')
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          verdict = host_edit(rakefile, "ruby 'test/test_x.rb'", 'true', cwd: run.worktree)
          unless run.pinned['implement']['tests'].key?(rakefile)
            flunk('BUG: runner_files (service.rb:733-742) reads the program after unwrap only, not after RUN_WRAPPERS, so ' \
                 '"bundle exec rake test" pins no Rakefile (nor "uv run pytest" pytest.ini/conftest.py); an Edit of the ' \
                 "Rakefile to `true` was #{verdict} with #{asks('pinned_test_change').size} stand-in calls")
          end
          assert_equal 'deny', verdict
          assert_equal 1, asks('pinned_test_change').size
        end

        # The fix refuses inline code behind ruby, python, node...; rake (the
        # runner of "bundle exec rake test") takes inline code too: rake -e
        # CODE executes it and exits.
        def test_inline_code_given_to_rake_is_refused_too
          repo!('test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n", 'lib/x.rb' => "X_VALUE = 1\n")
          out = host_start('template' => 'impl_cycle', 'tests' => 'test', 'test_command' => 'rake -e0')
          if out['status'] == 'started'
            run = Run.load(@paths, out['run_id'])
            assert_equal 'allow', host_edit(File.join(run.worktree, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 2', cwd: run.worktree)
            host_commit(run, 'break x')
            res = host_advance(run)
            if res['status'] == 'phase_ended'
              statics = ['bundle exec rake -e0', 'Rscript -e 0'].select { |c| Service.allocate.test_command_problem(c, @root).nil? }
              flunk('BUG: test_command_problem (service.rb:646-680; INTERPRETER_FLAGS, service.rb:51) has no entry for rake (nor Rscript, julia, ' \
                   "elixir), so \"rake -e0\" passed the runner check and a broken test/test_x.rb ended the implement phase " \
                   "(ran #{checks_ran.last.inspect}); also let through: #{statics.join(', ')}")
            end
          end
          assert_equal 'refused', out['status'], out.inspect
        end

        # =========================================================================
        # (6) The helpers a glob pins beside the matched tests
        # =========================================================================

        # Trigger (codex P2, fable P3): with a root-level glob (*.test.js) every
        # repository directory was admitted and any path naming "helper" was
        # pinned (src/helper.js, lib/url_helper.rb).
        def test_a_root_level_glob_pins_only_the_conventional_helpers_beside_its_tests
          repo!('app.test.js' => "require('./src/app')\n", 'src/app.js' => "module.exports = 1\n",
                'src/helper.js' => "module.exports = 2\n", 'helper.js' => "module.exports = 3\n",
                'lib/x_helper.rb' => "X = 1\n", 'lib/url_helper.rb' => "U = 1\n", 'test_helper.rb' => "T = 1\n",
                'conftest.py' => "# conftest\n", 'fixtures/a.json' => "{}\n", 'support/s.js' => "1\n")
          run = started('template' => 'impl_cycle', 'tests' => '*.test.js', 'test_command' => 'node')
          wt = run.worktree
          pinned = run.pinned['implement']['tests'].keys.map { |k| k.delete_prefix("#{wt}/") }.sort
          assert_equal %w[app.test.js conftest.py fixtures/a.json support/s.js test_helper.rb], pinned

          %w[src/helper.js lib/x_helper.rb lib/url_helper.rb helper.js].each do |rel|
            assert_equal 'allow', host_write(File.join(wt, rel), "// edited #{rel}\n", cwd: wt), rel
          end
          assert_empty asks('pinned_test_change'), 'source named like a helper is edited without a stand-in call'
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          assert_equal 'deny', host_edit(File.join(wt, 'conftest.py'), '# conftest', 'import sys', cwd: wt)
          assert_equal 1, asks('pinned_test_change').size, 'the conventional helper is pinned'
        end

        # Trigger (operator_proxy P2, sonnet P1): tests
        # "KairosChain_mcp_server/test_*.rb" pinned lib/kairos_mcp/admin/helpers.rb
        # and tool_helpers.rb.
        def test_a_glob_under_a_directory_pins_helpers_only_inside_the_matched_tests_directories
          repo!('srv/test_a.rb' => "require_relative 'lib/kairos_mcp/admin/helpers'\nexit(HELPERS_OK ? 0 : 1)\n",
                'srv/lib/kairos_mcp/admin/helpers.rb' => "HELPERS_OK = true\n",
                'srv/lib/kairos_mcp/tool_helpers.rb' => "TH = 1\n", 'srv/lib/support/y.rb' => "Y = 1\n",
                'srv/lib/x_helper.rb' => "XH = 1\n", 'srv/test_helper.rb' => "require 'minitest'\n",
                'srv/support/x.rb' => "SX = 1\n", 'srv/fixtures/a.yml' => "a: 1\n", 'srv/unit/fixtures/b.yml' => "b: 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'srv/test_*.rb')
          wt = run.worktree
          pinned = run.pinned['implement']['tests'].keys.map { |k| k.delete_prefix("#{wt}/") }.sort
          assert_equal %w[srv/fixtures/a.yml srv/support/x.rb srv/test_a.rb srv/test_helper.rb], pinned

          assert_equal 'allow', host_edit(File.join(wt, 'srv/lib/kairos_mcp/admin/helpers.rb'), 'HELPERS_OK = true',
                                          'HELPERS_OK = true # documented', cwd: wt)
          assert_equal 'allow', host_write(File.join(wt, 'srv/lib/kairos_mcp/tool_helpers.rb'), "TH = 2\n", cwd: wt)
          assert_equal 'allow', host_write(File.join(wt, 'srv/lib/x_helper.rb'), "XH = 2\n", cwd: wt)
          assert_equal 'allow', host_write(File.join(wt, 'srv/lib/support/y.rb'), "Y = 2\n", cwd: wt)
          assert_empty asks('pinned_test_change')
          host_commit(run, 'edit the source helpers')
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_empty asks('pinned_test_change'), 'nor ruled at the check'
          assert_includes checks_ran.map(&:last), File.join(wt, 'srv', 'test_a.rb')
        end

        # =========================================================================
        # (7) A tests glob without a command
        # =========================================================================

        # Trigger (sonnet P2): test/**/*.rb selected a helper; with no command
        # test_argv had no runner for it and the check opened "no runner for
        # helper.rb".
        def test_a_glob_without_a_command_runs_only_files_named_like_tests
          repo!('test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n", 'test/helper.rb' => "HELPER = 1\n",
                'test/support/util.rb' => "raise 'not a test'\n", 'lib/x.rb' => "X_VALUE = 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'test/**/*.rb')
          wt = run.worktree
          assert_includes run.pinned['implement']['tests'].keys, File.join(wt, 'test', 'helper.rb'), 'the glob matches it: pinned'
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 1 # documented', cwd: wt)
          host_commit(run, 'document x')
          out = host_advance(run)
          assert_equal ['phase_ended', 1], out.values_at('status', 'ran'), out.inspect
          assert_equal [['ruby', '-Ilib', '-Itest', File.join(wt, 'test', 'test_x.rb')]], checks_ran
          assert(run.reload.items.values.none? { |i| i['text'].to_s.include?('no runner') }, 'no "no runner" item')
          assert_equal 'block', host_stop('The check passed.')&.dig('decision')
        end

        # =========================================================================
        # (8) Script-style tests failing on the base commit
        # =========================================================================

        LEGACY = <<~RUBY
          require_relative '../lib/x'
          puts '✅ basic check'
          puts '❌ legacy check'
          puts '❌ new check' if X_VALUE != 1
          exit 1
        RUBY

        def legacy_repo!(legacy = LEGACY)
          repo!('test/test_legacy.rb' => legacy, 'test/test_x.rb' => "require 'x'\nexit(X_VALUE >= 1 ? 0 : 1)\n",
                'lib/x.rb' => "X_VALUE = 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'test')
          [run, File.join(run.worktree, 'test', 'test_legacy.rb')]
        end

        # A script-style test (✅/❌ lines, no minitest or pytest names) failing
        # on the base is not excused by its lines (R5): the operator decides.
        def test_a_script_style_test_failing_on_the_base_waits_on_the_operator
          run, legacy = legacy_repo!
          wt = run.worktree
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 1 # documented', cwd: wt)
          host_commit(run, 'document x')
          out = host_advance(run)
          assert_equal 'tests_failed', out['status'], out.inspect
          assert_equal [legacy], out['failed'].map { |f| f['file'] }
          base = entries(run, 'baseline').find { |e| e['file'] == 'test/test_legacy.rb' }
          assert_equal [false, nil], base.values_at('ok', 'failing_tests')
          items = run.reload.open_items_for('implement', %w[blocking])
          assert_equal 1, items.size
          assert_includes items.first['text'], 'fails on the base commit too'
        end

        def test_a_script_style_test_with_a_new_failure_line_is_not_excused_and_tests_failed_names_its_item
          run, legacy = legacy_repo!
          wt = run.worktree
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 2', cwd: wt)
          host_commit(run, 'x 2')
          out = host_advance(run)
          assert_equal 'tests_failed', out['status'], out.inspect
          assert_equal [legacy], out['failed'].map { |f| f['file'] }
          base_items = run.reload.open_items_for('implement', %w[blocking])
          assert_equal 1, base_items.size
          item = base_items.first
          assert_includes item['text'], 'fails on the base commit too'
          assert_equal [{ 'item' => item['id'], 'file' => 'test/test_legacy.rb' }], out['failing_on_the_base_too']
          assert_equal 'block', host_stop('One test fails with a new line; the operator decides.')&.dig('decision')

          type!("#{item['id']} はそのままで進めて", 'p-accept')
          res = resolve(run, item['id'], 'accept_failing')
          refute res['item_open'], res.inspect
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal [legacy], out['failing_before_the_run']
        end

        # The same rule on lines that differ only by a number: "❌ INV-2 holds"
        # is a new failure beside "❌ INV-1 holds".
        def test_a_new_failure_line_that_differs_from_a_base_line_only_by_a_number_is_not_excused
          numbered = <<~RUBY
            require_relative '../lib/x'
            puts '❌ INV-1 holds'
            puts '❌ INV-2 holds' if X_VALUE != 1
            exit 1
          RUBY
          run, legacy = legacy_repo!(numbered)
          wt = run.worktree
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 2', cwd: wt)
          host_commit(run, 'x 2 breaks INV-2')
          out = host_advance(run)
          if out['status'] == 'phase_ended'
            flunk('BUG: failing_tests (service.rb:579-589) replaces every digit with N before comparing script-style lines, ' \
                 'so "❌ INV-2 holds" (new) reads as "❌ INV-1 holds" (failing on main) and the new failure of ' \
                 "#{File.basename(legacy)} is excused: the implement phase ended with failing_before_the_run " \
                 "#{out['failing_before_the_run'].map { |f| File.basename(f) }.inspect}")
          end
          assert_equal 'tests_failed', out['status'], out.inspect
        end

        # =========================================================================
        # (9) The deck: pinned-test changes on a main slide; the run-id form
        # =========================================================================

        # Trigger (operator_proxy P0): pinned-test changes sat in the details
        # layer, and an approval showed no decision id. Three routes: an Edit
        # the guard sent to the stand-in, a shell change ruled at the check,
        # and a change the operator accepted.
        def test_the_deck_puts_every_pinned_test_change_with_its_decision_id_on_a_main_slide
          skip_unless_kit
          repo!('test/test_a.rb' => "exit 0\n", 'test/test_b.rb' => "exit 0\n", 'test/test_c.rb' => "exit 0\n",
                'lib/x.rb' => "X = 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'test')
          wt = run.worktree
          ta, tb, tc = %w[a b c].map { |n| File.join(wt, 'test', "test_#{n}.rb") }
          @script['pinned_test_change'] = lambda do |ev|
            if File.basename(ev['path'].to_s) == 'test_c.rb' then { 'answer' => nil, 'class' => 'operator_item' }
            else { 'answer' => 'approve', 'class' => 'decided' }
            end
          end
          assert_equal 'allow', host_edit(ta, 'exit 0', 'exit 0 # the design asks for a note', cwd: wt)
          out, ok = host_bash("printf 'exit 0 # b\\n' > test/test_b.rb && printf 'exit 0 # c\\n' > test/test_c.rb", cwd: wt)
          assert ok, out
          host_commit(run, 'notes in the tests')
          out = host_advance(run)
          assert_equal 'check_refused', out['status'], out.inspect
          assert_equal [tc], out['changed']
          item = out['item']
          assert_equal 'block', host_stop('One pinned test change needs the operator.')&.dig('decision')
          type!("#{item} の変更は承認します", 'p-acc')
          res = resolve(run, item, 'accept_test_change')
          refute res['item_open'], res.inspect
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: APPROVE)
          labels([])
          assert_equal 'closed_provisionally', host_advance(run)['status']
          assert_equal 'block', host_stop('The implementation review closed.')&.dig('decision')

          deck = subagent_builds_deck(run)
          main = main_slides(File.read(deck))
          decisions = run.reload.decisions.select { |d| d['point'] == 'pinned_test_change' }
          d_a = decisions.find { |d| d['question'] == ta }
          d_b = decisions.find { |d| d['question'] == 'test/test_b.rb' }
          refute_nil d_a
          refute_nil d_b
          changes = run.journal.entries.select { |e| e['kind'] == 'pinned_change' }
          assert_equal [ta, tb, tc].sort, changes.map { |c| c['path'] }.sort
          lines = main.scan(%r{<li>([^<]*固定したテストの変更[^<]*)</li>}).flatten
          assert_equal 3, lines.size, 'every pinned-test change is on a main slide'
          line = ->(path) { lines.find { |l| l.include?(path) } }
          assert_includes line.(tb), d_b['id'], 'the check-time approval names its decision'
          assert_includes line.(tc), 'あなた', "the operator's acceptance is shown as the operator's"
          unless line.(ta).include?(d_a['id'])
            flunk("BUG: the guard's approval of a pinned-test Edit records the stand-in's inputs digest as its decision " \
                 "(hooks.rb:597 `decision: a.inputs_digest`), not the D# record_decision returned, so the deck's main slide " \
                 "shows #{line.(ta)[/（[^）]*）/]} for test_a.rb instead of #{d_a['id']}; the operator cannot name it to correct it")
          end
        end

        # Trigger (operator_proxy P2): from a new session the operator's words
        # must carry the run id, but the deck never showed that form.
        def test_the_deck_shows_the_run_id_form_and_an_answer_in_that_form_from_another_session_counts
          skip_unless_kit
          run = closed_design_run
          deck = subagent_builds_deck(run)
          rid6 = run.id[-6..]
          main = main_slides(File.read(deck))
          assert_includes main, "run id の末尾 6 文字（#{rid6}）"
          assert_includes main, "「#{rid6} I3 は凍結」"
          out = host_tool('finish', { 'run_id' => run.id })
          assert_equal 'finished', out['status'], out.inspect
          assert_nil host_stop('The report is built.')
          closure = run.reload.open_items.find { |i| i['item_kind'] == 'closure' }
          refute_nil closure
          assert_includes main, "#{closure['id']} closure:", 'the closure item is on the main slide'

          t2 = File.join(@tmp, 'transcript_s2.jsonl')
          File.write(t2, '')
          # In another session, without the run id: not the run's words.
          type!("#{closure['id']} は確定で", 'p2-a', sid: 's2', transcript: t2)
          out = host_tool_as('s2', 'items', { 'action' => 'confirm', 'run_id' => run.id, 'ref' => closure['id'] }, transcript: t2)
          assert_equal 'refused', out['status'], out.inspect
          # In the form the deck shows: counted.
          type!("#{rid6} #{closure['id']} は確定で", 'p2-b', sid: 's2', transcript: t2)
          out = host_tool_as('s2', 'items', { 'action' => 'confirm', 'run_id' => run.id, 'ref' => closure['id'] }, transcript: t2)
          assert_equal 'recorded', out['status'], out.inspect
          run.reload
          assert_equal 'resolved', run.items[closure['id']]['state']
          assert(run.journal.entries.any? { |e| e['kind'] == 'phase_confirmed' && e['item'] == closure['id'] })
        end

        # =========================================================================
        # (10) Core: upgrade warnings for a SkillSet's user-level leftovers
        # =========================================================================

        CORE_SCRIPT = <<~'RUBY'
          require 'json'
          require 'kairos_mcp/skillset_manager'
          require 'kairos_mcp/tools/system_upgrade'
          KairosMcp.define_singleton_method(:gem_root) { ENV.fetch('R3_GEM_ROOT') }
          out = if ARGV[0] == 'tool'
                  KairosMcp::Tools::SystemUpgrade.new.send(:handle_skillset_only_install, ['agent'])
                else
                  KairosMcp::SkillSetManager.new.upgrade_apply(names: ['agent'])
                end
          puts JSON.generate(out)
        RUBY

        OLD_SKILL = "---\nname: agent\ndescription: Governed autonomous OODA loop for cognitive agents (agent_step).\n---\n"
        NEW_SKILL = "---\nname: agent\ndescription: Long autonomous runs in the operator's own host session (agent_start).\n---\n"
        MONITOR = "---\nname: agent-monitor\ndescription: watches agent sessions\n---\n"

        # The agent template's declared conflicts, in a temporary template
        # (layer L2: no chain record), installed into a temporary data dir
        # under a temporary HOME, by a subprocess.
        def core_upgrade(mode: 'manager', home_files: {}, installed: nil)
          base = File.join(@tmp, "core_#{SecureRandom.hex(3)}")
          home = File.join(base, 'home')
          data = File.join(base, 'data')
          gem = File.join(base, 'gem')
          tpl = File.join(gem, 'templates', 'skillsets', 'agent')
          FileUtils.mkdir_p([home, File.join(data, 'skillsets'), tpl])
          declared = JSON.parse(File.read(AGENT_JSON))['user_level_conflicts']
          File.write(File.join(tpl, 'skillset.json'),
                     JSON.generate('name' => 'agent', 'version' => '1.0.0', 'layer' => 'L2', 'user_level_conflicts' => declared))
          File.write(File.join(tpl, 'README.md'), "agent 1.0\n")
          if installed
            put(File.join(data, 'skillsets', 'agent'), 'skillset.json',
                JSON.generate('name' => 'agent', 'version' => installed, 'layer' => 'L2'))
          end
          home_files.each { |rel, body| put(home, rel, body) }
          env = { 'HOME' => home, 'KAIROS_DATA_DIR' => data, 'R3_GEM_ROOT' => gem, 'KAIROS_MCP_LIB' => nil }
          out, err, st = Open3.capture3(env, RbConfig.ruby, '-I', CORE_LIB, '-e', CORE_SCRIPT, mode, chdir: base)
          assert st.success?, err
          [JSON.parse(out.lines.last), home]
        end

        def test_core_upgrade_apply_warns_of_the_declared_user_level_leftovers_present_at_home
          declared = JSON.parse(File.read(AGENT_JSON))['user_level_conflicts'].map { |c| c['path'] }
          assert_equal %w[~/.claude/skills/agent/SKILL.md ~/.claude/agents/agent-monitor.md], declared

          # A new install, the 0.x personal skill present.
          res, home = core_upgrade(home_files: { '.claude/skills/agent/SKILL.md' => OLD_SKILL })
          assert_equal 1, res.size
          r = res.first
          assert_equal %w[agent installed], r.values_at('name', 'action')
          assert_equal 1, r['warnings'].size, r.inspect
          w = r['warnings'].first
          assert w.start_with?("#{home}/.claude/skills/agent/SKILL.md: "), w
          assert_includes w, "mv #{home}/.claude/skills/agent/SKILL.md #{home}/.claude/agent_previous_version_backup/"

          # An upgrade of an installed 0.x, both leftovers present.
          res, home = core_upgrade(installed: '0.9.0', home_files: { '.claude/skills/agent/SKILL.md' => OLD_SKILL,
                                                                     '.claude/agents/agent-monitor.md' => MONITOR })
          r = res.first
          assert_equal %w[agent upgraded 0.9.0 1.0.0], r.values_at('name', 'action', 'from', 'to')
          assert_equal ["#{home}/.claude/skills/agent/SKILL.md", "#{home}/.claude/agents/agent-monitor.md"],
                       r['warnings'].map { |x| x.split(': ').first }
        end

        def test_core_upgrade_apply_reports_no_warnings_when_the_leftovers_are_absent
          res, = core_upgrade
          assert_equal 'installed', res.first['action']
          refute res.first.key?('warnings'), res.inspect
          res, = core_upgrade(installed: '0.9.0')
          assert_equal 'upgraded', res.first['action']
          refute res.first.key?('warnings'), res.inspect
          # A personal skill named agent that is not the 0.x one is not a leftover.
          res, = core_upgrade(installed: '0.9.0', home_files: { '.claude/skills/agent/SKILL.md' => NEW_SKILL })
          refute res.first.key?('warnings'), res.inspect
        end

        # What the operator sees: system_upgrade's reply for the same install.
        def test_core_system_upgrade_shows_the_operator_the_warning
          res, home = core_upgrade(mode: 'tool', home_files: { '.claude/skills/agent/SKILL.md' => OLD_SKILL })
          text = res.map { |c| c['text'] }.join
          assert_includes text, '[INSTALLED] agent v1.0.0'
          unless text.include?("#{home}/.claude/skills/agent/SKILL.md")
            flunk('BUG: system_upgrade prints only [INSTALLED]/[UPGRADED] per SkillSet (system_upgrade.rb:484-489 in ' \
                 'handle_skillset_only_install, 356-363 in handle_apply) and drops the warnings upgrade_apply returns, so ' \
                 "the operator is never told the 0.x personal skill shadows 1.0; reply was: #{text.strip.inspect}")
          end
        end
      end
    end
  end
end
