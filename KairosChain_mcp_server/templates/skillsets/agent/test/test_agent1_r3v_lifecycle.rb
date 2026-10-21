# frozen_string_literal: true

# Verification of the fixes after implementation review R3 (the plan's last
# round), group "lifecycle": how a run's phases end, wait, reopen and are
# taken up, driven the way the host drives them. Every agent tool call goes
# PreToolUse (the hook names the session) → the service → PostToolUse; a Bash
# call goes PreToolUse (the guard confines it) → the rewritten command, run
# for real → PostToolUse; turns end with Stop. The triggers are the R3
# reviews' (log/agent_skillset_rebuild_impl_r3/persona_*_impl_r3.md and
# impl_r3_collect_result.json).
#
# Real git repositories, real confined checks and confined Bash
# (sandbox-exec), all under a tmpdir; KAIROS_AGENT_GLOBAL, CLAUDE_PROJECT_DIR
# and (for the hook script) HOME point into it. The stand-in and the review
# tools are scripted; no claude -p runs. Some scenarios run every hook event
# through hooks/agent_hook.rb as a subprocess with an empty gem path, so the
# project's ruby cannot load kairos_mcp and the stand-in cannot be built (the
# R3 operator-proxy trigger, a project pinned to an older ruby without the gem).
require 'rbconfig'
require 'shellwords'
require_relative 'test_agent1_r1_check'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R3VLifecycle < TestAgent1R1Check
        # Only this file's tests run here; the harness's own run in theirs.
        TestAgent1R1Check.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }
        Minitest::Runnable.runnables.delete(TestAgent1R1Check)

        HOOK_SCRIPT = File.expand_path('../hooks/agent_hook.rb', __dir__)
        TOOLS = { 'agent_start' => :start, 'agent_status' => :status, 'agent_advance' => :advance,
                  'agent_items' => :items, 'agent_finish' => :finish, 'agent_stop' => :stop }.freeze
        SUBAGENT = 'b7c1d2e3f4a5'
        P0 = 'the cache has no bound, so memory grows without limit'
        GIT_ID = '-c user.email=t@t -c user.name=t'
        QUESTION = { 'questions' => [{ 'question' => '査読は何席で回しますか', 'header' => '席', 'multiSelect' => false,
                                       'options' => [{ 'label' => '7 席' }, { 'label' => '8 席' }] }] }.freeze
        LEAK = 'Found it: the API key was leaked into the public log.'

        # Answers from a script keyed by decision point (default: the first
        # option, decided on the instruction mode); a reply may cite its own
        # basis, or raise.
        class LifecycleStandIn
          attr_reader :asked

          def initialize(script)
            @script = script
            @asked = []
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
            @asked << { point: point, question: question, evidence: evidence, options: options,
                        precedents: precedents.map { |p| p['id'] } }
            reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
            raise reply['raise'] if reply['raise']

            StandIn::Answer.new(answer: reply['answer'], klass: reply['class'], confidence: 0.9,
                                basis: reply['basis'] || ['instruction_mode'], reason: 'scripted', calls: 1,
                                inputs_digest: 'x' * 64)
          end

          def rule_hazard(text, **kw)
            a = ask(point: 'hazard', question: text, options: StandIn::HAZARD_RULINGS, **kw)
            [a.answer.to_s, a]
          end
        end

        def setup
          super
          @stand_in = LifecycleStandIn.new(@script)
          @saved_project_dir = [ENV.fetch('CLAUDE_PROJECT_DIR', nil)]
          ENV['CLAUDE_PROJECT_DIR'] = @root
          @home = File.join(@tmp, 'home')
          @no_gems = File.join(@tmp, 'no_gems')
          FileUtils.mkdir_p([@home, @no_gems])
          @transcripts = { 's1' => @transcript }
          %w[s2 s3].each do |s|
            t = File.join(@tmp, "transcript_#{s}.jsonl")
            File.write(t, '')
            @transcripts[s] = t
          end
          @tu = 0
          @use_script = false
          @hook_factory = nil
        end

        def teardown
          super
        ensure
          if @saved_project_dir
            v = @saved_project_dir.first
            v.nil? ? ENV.delete('CLAUDE_PROJECT_DIR') : ENV['CLAUDE_PROJECT_DIR'] = v
          end
        end

        # --- the host -------------------------------------------------------------

        def hooks
          Hooks.new(paths: @paths, project_root: @root, stand_in_factory: @hook_factory || ->(_r, _p) { @stand_in })
        end

        # One hook event: in process, or through hooks/agent_hook.rb as the host
        # runs it (input on stdin, every location in the tmpdir, no gems).
        def event(name, input)
          return hooks.handle(name, input) unless @use_script

          env = { 'HOME' => @home, 'KAIROS_DATA_DIR' => @paths.data_dir, 'CLAUDE_PROJECT_DIR' => @root,
                  'KAIROS_AGENT_GLOBAL' => ENV.fetch('KAIROS_AGENT_GLOBAL'), 'KAIROS_MCP_LIB' => nil,
                  'GEM_HOME' => @no_gems, 'GEM_PATH' => @no_gems, 'RUBYOPT' => nil, 'RUBYLIB' => nil,
                  'BUNDLE_GEMFILE' => nil, 'GIT_CONFIG_GLOBAL' => ENV.fetch('GIT_CONFIG_GLOBAL'),
                  'GIT_CONFIG_NOSYSTEM' => '1' }
          out, err, st = Open3.capture3(env, RbConfig.ruby, HOOK_SCRIPT,
                                        stdin_data: JSON.generate(input.merge('hook_event_name' => name)), chdir: @root)
          assert_equal 0, st.exitstatus, "#{name} hook failed: #{err}"
          out.strip.empty? ? nil : JSON.parse(out)
        end

        def tr(sid)
          @transcripts.fetch(sid)
        end

        def q(path)
          Shellwords.escape(path)
        end

        def verdict(out)
          out&.dig('hookSpecificOutput', 'permissionDecision')
        end

        def pre_hook(sid, tool, input, agent_id: nil)
          @last_tu = "toolu_r3v_#{@tu += 1}"
          ev = { 'session_id' => sid, 'transcript_path' => tr(sid), 'cwd' => @root, 'tool_name' => tool,
                 'tool_input' => input, 'tool_use_id' => @last_tu }
          ev['agent_id'] = agent_id if agent_id
          event('PreToolUse', ev)
        end

        def post_hook(sid, tool, input, response, agent_id: nil)
          ev = { 'session_id' => sid, 'transcript_path' => tr(sid), 'cwd' => @root, 'tool_name' => tool,
                 'tool_input' => input, 'tool_response' => response, 'tool_use_id' => @last_tu }
          ev['agent_id'] = agent_id if agent_id
          event('PostToolUse', ev)
        end

        # An agent tool as the host calls it.
        def host(tool, args, sid: 's1', agent_id: nil)
          name = "mcp__kairos-chain__#{tool}"
          v = pre_hook(sid, name, args, agent_id: agent_id)
          input = v&.dig('hookSpecificOutput', 'updatedInput')
          refute_nil input, "PreToolUse names the session for #{tool}: #{v.inspect}"
          assert_equal sid, input['_session_id']
          out = service.public_send(TOOLS.fetch(tool), input)
          post = post_hook(sid, name, input, [{ 'type' => 'text', 'text' => JSON.generate(out) }], agent_id: agent_id)
          assert_nil post, "PostToolUse of #{tool} answers nothing" unless tool == 'agent_start'
          out
        end

        # A Bash call as the host makes it: the guard's PreToolUse, the command
        # as the hook rewrote it (confined), PostToolUse with its output.
        def bash!(command, sid: 's1')
          input = { 'command' => command, 'description' => 'r3v' }
          v = pre_hook(sid, 'Bash', input)
          assert(v.nil? || verdict(v) == 'allow', "Bash refused: #{v.inspect}")
          ran = v&.dig('hookSpecificOutput', 'updatedInput') || input
          out, st = Open3.capture2e('/bin/bash', '-c', ran['command'], chdir: @root)
          post_hook(sid, 'Bash', ran, { 'stdout' => out, 'stderr' => '', 'interrupted' => false })
          assert st.success?, "#{command}: #{out}"
          [v, out]
        end

        # A file written by a shell command with an absolute path, as next_step
        # advises. (printf, not a heredoc: see the heredoc test at the end.)
        def bash_write!(path, body, sid: 's1')
          bash!("printf '%s' #{q(body)} > #{q(path)}", sid: sid)
        end

        def commit_via_bash!(run, msg, sid: 's1')
          wt = q(run.worktree)
          bash!("git -C #{wt} #{GIT_ID} add -A && git -C #{wt} #{GIT_ID} commit -q -m #{q(msg)}", sid: sid)
          git_out(run.worktree, 'rev-parse', 'HEAD')
        end

        def write!(path, content, sid: 's1', agent_id: nil)
          input = { 'file_path' => path, 'content' => content }
          v = pre_hook(sid, 'Write', input, agent_id: agent_id)
          assert_equal 'allow', verdict(v), v.inspect
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          post_hook(sid, 'Write', input, { 'type' => 'create', 'filePath' => path }, agent_id: agent_id)
          path
        end

        def write_design(version, stem: 'x', sid: 's1')
          write!(File.join(@root, 'log', "#{stem}_design_v#{version}.md"),
                 "# #{stem} design v#{version}\nINV-1: the cache is bounded (#{version})\n", sid: sid)
        end

        def stop!(msg = 'This turn is done.', sid: 's1')
          event('Stop', 'session_id' => sid, 'transcript_path' => tr(sid), 'cwd' => @root,
                        'last_assistant_message' => msg, 'stop_hook_active' => false)
        end

        def reason(out)
          out&.dig('reason').to_s
        end

        # The operator types a prompt: the host records it as typed, and
        # UserPromptSubmit fires.
        def type!(text, pid, sid: 's1')
          File.open(tr(sid), 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => pid, 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => text }))
          end
          event('UserPromptSubmit', 'session_id' => sid, 'prompt' => text, 'prompt_id' => pid,
                                    'transcript_path' => tr(sid), 'cwd' => @root)
        end

        def adv(run, sid: 's1')
          host('agent_advance', { 'run_id' => run.id }, sid: sid)
        end

        def act(action, run, ref, decision = nil, sid: 's1', rounds: nil)
          args = { 'action' => action, 'run_id' => run.id, 'ref' => ref }
          args['decision'] = decision if decision
          args['rounds'] = rounds if rounds
          host('agent_items', args, sid: sid)
        end

        def resolve(run, ref, decision = nil, sid: 's1', rounds: nil)
          act('resolve', run, ref, decision, sid: sid, rounds: rounds)
        end

        def material(run, sid: 's1')
          st = host('agent_status', { 'run_id' => run.id, 'report_material' => true }, sid: sid, agent_id: SUBAGENT)
          JSON.parse(File.read(st['report_material']['material_path']))
        end

        # --- runs ---------------------------------------------------------------------

        def start!(args, sid: 's1')
          adopt! unless Policies.new(@paths).adopted
          out = host('agent_start', args, sid: sid)
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          assert_equal sid, run.bound_session
          run
        end

        def impl_start(tests: 'test', test_command: nil, sid: 's1')
          args = { 'goal' => 'make x work', 'template' => 'impl_cycle', 'tests' => tests }
          args['test_command'] = test_command if test_command
          start!(args, sid: sid)
        end

        def design_start(stem: 'x', sid: 's1')
          start!({ 'goal' => "design #{stem}", 'template' => 'design_only', 'design_glob' => "log/#{stem}_design_v*.md" }, sid: sid)
        end

        def round_returns(p0: [], verdicts: %w[APPROVE APPROVE])
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = {
            'status' => 'ok',
            'reviews' => [{ 'role_label' => 'codex', 'verdict' => verdicts[0],
                            'raw_text' => (p0.map { |t| "P0: #{t}" } + ["Overall Verdict: #{verdicts[0]}"]).join("\n") },
                          { 'role_label' => 'sonnet', 'verdict' => verdicts[1], 'raw_text' => "Overall Verdict: #{verdicts[1]}" }],
            'aggregated_findings' => p0.map { |t| { 'severity' => 'P0', 'issue' => t } },
            'vote_tally' => { 'successful_count' => 2, 'min_quorum' => 2 }
          }
        end

        def new_labels(*texts)
          { 'answer' => texts.map { |t| { 'seat' => 'codex', 'text' => t, 'label' => 'new', 'covers' => [0] } },
            'class' => 'decided' }
        end

        # A design review at the policy's round cap (one round for each review) with
        # one open P0: a review_open item, the run running. The stand-in is
        # not asked anything at the bound.
        def design_at_bound(stem: 'x', sid: 's1')
          review_rounds!(1)
          run = design_start(stem: stem, sid: sid)
          write_design('0.1', stem: stem, sid: sid)
          assert_equal 'phase_ended', adv(run, sid: sid)['status']
          assert_equal 'dispatched', adv(run, sid: sid)['status']
          round_returns(p0: [P0], verdicts: %w[REVISE APPROVE])
          @script['review_labels'] = new_labels(P0)
          out = adv(run, sid: sid)
          assert_equal 'waiting', out['status'], out.inspect
          assert_empty asks('round_bound'), 'round_bound is not a decision point any more'
          item = run.reload.items[out['item']]
          assert_equal %w[review_open design_review], [item['item_kind'], item.dig('state_ref', 'ref')]
          [run, item]
        end

        # A design review closed provisionally at round 1.
        def closed_design_run
          run = design_start
          write_design('0.1')
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          round_returns
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          out = adv(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          item = run.reload.items[out['item']]
          assert_equal %w[closure design_review], [item['item_kind'], item.dig('state_ref', 'ref')]
          [run, item]
        end

        # Turns end as the host ends them (Stop, the actor's next advance)
        # until the run ends as waiting on the operator.
        def end_waiting!(run, sid: 's1')
          stops = []
          4.times do
            stops << stop!('Waiting on the operator.', sid: sid)
            break if run.reload.status == 'ended'

            adv(run, sid: sid)
          end
          assert_equal ['ended', 'waiting on operator items'], [run.reload.status, run.end_reason],
                       stops.map { |s| reason(s)[0, 60] }.inspect
          stops
        end

        # A subagent builds the deck from the report material through the
        # guarded Write tool; the acting context finishes.
        def finish!(run, sid: 's1')
          m = material(run, sid: sid)
          ids = m['decisions'].map { |d| d['id'] } + m['items'].map { |i| i['id'] } + m['phases'].map { |p| p['name'] }
          deck = File.join(@root, 'log', 'agent_runs', run.id, 'deck.html')
          write!(deck, "<html><body>#{ids.join(' ')}</body></html>", sid: sid, agent_id: SUBAGENT)
          event('SubagentStop', 'session_id' => sid, 'agent_id' => SUBAGENT, 'transcript_path' => tr(sid),
                                'last_assistant_message' => 'The deck is built; check.py reports issues=0.')
          fin = host('agent_finish', { 'run_id' => run.id }, sid: sid)
          assert_equal 'finished', fin['status'], fin.inspect
          stop!('The report is built.', sid: sid)
          deck
        end

        # An implementation review waiting on a review_open item (round 1 open
        # at the policy's cap of one round for each review), after the Stop
        # that follows the labelled round.
        def impl_waiting_on_its_review
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          review_rounds!(1)
          run = impl_start
          bash_write!(File.join(run.worktree, 'lib', 'x.rb'), "X_VALUE = 1 # v2\n")
          commit_via_bash!(run, 'v2')
          assert_equal 'phase_ended', adv(run)['status']
          assert_includes reason(stop!('Implemented; the check passed.')), 'continues'
          assert_equal 'dispatched', adv(run)['status']
          assert_includes reason(stop!('Dispatched the implementation review.')), 'review round is running'
          round_returns(p0: [P0], verdicts: %w[REVISE APPROVE])
          @script['review_labels'] = new_labels(P0)
          out = adv(run)
          assert_equal 'waiting', out['status'], out.inspect
          assert_includes reason(stop!('Round 1 is labelled; one P0 is open at the bound.')), 'continues'
          run.reload
        end

        # The operator freezes the check phase's item; the implementation review
        # then dispatches without running the check again, once the worktree is
        # clean.
        def freeze_and_dispatch!(run, ref)
          type!("#{ref} は凍結して先へ", "p-freeze-#{ref}")
          res = resolve(run, ref, 'freeze')
          refute res['item_open'], res.inspect
          assert_equal 'running', res['run_status'], res.inspect
          run.reload
          assert_equal %w[ended operator], [run.phases['implement']['status'], run.phases['implement']['by']]
          assert_equal 'implementation_review', run.current_phase
          checks = entries(run, 'check').size
          ran = checks_ran.size
          rulings = asks('pinned_test_change').size

          notes = File.join(run.worktree, 'notes.txt')
          bash_write!(notes, "scratch\n")
          out = adv(run)
          assert_equal 'refused', out['status'], "a clean worktree is still required: #{out.inspect}"
          assert_includes out['reason'], 'uncommitted'
          assert_empty dispatched
          bash!("rm #{q(notes)}")
          out = adv(run)
          assert_equal 'dispatched', out['status'], "the operator's freeze stands: #{out.inspect}"
          assert_equal 1, dispatched.size
          assert_equal checks, entries(run, 'check').size, 'the check is not run again'
          assert_equal ran, checks_ran.size, 'nothing ran confined'
          assert_equal rulings, asks('pinned_test_change').size, 'no pinned test is ruled again'
          run.reload
          assert_empty(run.open_items.select { |i| i['item_kind'] == 'blocking' }, 'no new item undoes the freeze')
          assert_equal %w[ended operator], [run.phases['implement']['status'], run.phases['implement']['by']]
          assert_includes reason(stop!('Dispatched the implementation review.')), 'review round is running'
        end

        # --- (1) the operator's freeze of the check phase stands ----------------------

        # R3 t11: impl_cycle, test/README and no test files; advance
        # refused with a blocking item; the run ends waiting; "I10 は凍結して先へ"
        # + freeze; every later advance re-ran the check and opened I20, I26 …
        def no_test_files_then_freeze
          repo!('test/README' => "tests go here\n", 'lib/x.rb' => "X = 1\n")
          run = impl_start
          bash_write!(File.join(run.worktree, 'lib', 'x.rb'), "X = 2\n")
          commit_via_bash!(run, 'x is two')
          first = adv(run)
          assert_equal 'refused', first['status'], first.inspect
          assert_includes first['reason'], 'no test files'
          ref = first['item']
          refute_nil ref
          assert_includes reason(stop!('The check found no test files.')), 'continues'
          assert_equal ref, adv(run)['item']
          assert_includes reason(stop!('Nothing more to do without the operator.')), 'can only wait on operator items'
          assert_equal 'waiting on operator items', run.reload.end_reason
          freeze_and_dispatch!(run, ref)
        end

        def test_a_frozen_no_test_files_check_is_not_rerun_by_the_implementation_review
          no_test_files_then_freeze
        end

        def test_a_frozen_no_test_files_check_through_the_hook_script_as_the_host_runs_it
          @use_script = true
          no_test_files_then_freeze
        end

        # R3 t1a: a pinned-test change the stand-in leaves to the operator, then
        # the operator's freeze of the check phase.
        def test_a_frozen_pinned_test_item_is_not_reopened_by_the_implementation_review
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          run = impl_start
          bash_write!(File.join(run.worktree, 'test', 'test_x.rb'), "require 'x'\nexit(X_VALUE >= 1 ? 0 : 1)\n")
          commit_via_bash!(run, 'loosen the check')
          @script['pinned_test_change'] = { 'answer' => nil, 'class' => 'operator_item' }
          first = adv(run)
          assert_equal 'check_refused', first['status'], first.inspect
          ref = first['item']
          assert_equal %w[blocking implement], [run.reload.items[ref]['item_kind'], run.items[ref].dig('state_ref', 'ref')]
          assert_includes reason(stop!('The changed pinned test went to the stand-in.')), 'continues'
          assert_equal ref, adv(run)['item']
          assert_includes reason(stop!('Waiting for the operator.')), 'can only wait on operator items'
          assert_empty checks_ran
          freeze_and_dispatch!(run, ref)
        end

        # R3 t1b: a test that fails on the base commit too, then a freeze.
        def test_a_frozen_base_failing_check_is_not_rerun_by_the_implementation_review
          repo!('test/test_broken.rb' => "exit 1\n", 'lib/x.rb' => "X = 1\n")
          run = impl_start
          bash_write!(File.join(run.worktree, 'lib', 'x.rb'), "X = 2\n")
          commit_via_bash!(run, 'x is two')
          first = adv(run)
          assert_equal 'tests_failed', first['status'], first.inspect
          ref = first['failing_on_the_base_too'].first&.dig('item')
          refute_nil ref, first.inspect
          assert_equal 'implement', run.reload.items[ref].dig('state_ref', 'ref')
          assert_includes reason(stop!('The test fails on the base commit too.')), 'continues'
          assert_equal 'tests_failed', adv(run)['status']
          assert_includes reason(stop!('Waiting for the operator.')), 'can only wait on operator items'
          freeze_and_dispatch!(run, ref)
        end

        # --- (2) the recheck's items block the review phase -----------------------------

        # R3 t6: the implementation review's recheck met a pinned-test change
        # left to the operator; its item opened on the ended implement phase,
        # so Stop only idled (5 advances, 5 idle).
        def test_a_recheck_item_blocks_the_review_phase_so_the_run_ends_waiting_and_ok_accepts_it
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          run = impl_start
          bash_write!(File.join(run.worktree, 'lib', 'x.rb'), "X_VALUE = 1 # v2\n")
          commit_via_bash!(run, 'v2')
          assert_equal 'phase_ended', adv(run)['status']
          assert_includes reason(stop!('Implemented; the check passed.')), 'continues'

          t = File.join(run.worktree, 'test', 'test_x.rb')
          bash_write!(t, "require 'x'\nexit(X_VALUE >= 1 ? 0 : 1) # loosened\n")
          commit_via_bash!(run, 'loosen the check after it passed')
          @script['pinned_test_change'] = { 'answer' => nil, 'class' => 'operator_item' }
          first = adv(run)
          assert_equal 'check_refused', first['status'], first.inspect
          item = run.reload.items[first['item'].to_s]
          refute_nil item, first.inspect
          assert_equal %w[blocking implementation_review], [item['item_kind'], item.dig('state_ref', 'ref')]
          assert_equal [t], item.dig('detail', 'paths')
          assert_empty dispatched

          stops = [stop!('The changed pinned test went to the stand-in.')]
          4.times do
            break if run.reload.status == 'ended'

            out = adv(run)
            assert_equal 'check_refused', out['status'], out.inspect
            assert_equal item['id'], out['item'], 'one item across advances'
            stops << stop!('Nothing to do until the operator rules.')
          end
          run.reload
          assert_equal ['ended', 'waiting on operator items'], [run.status, run.end_reason],
                       stops.map { |s| reason(s)[0, 60] }.inspect
          assert_empty entries(run, 'idle'), 'an ending, not idling'
          assert_equal 2, stops.size, 'the commit is progress once; the advance that changes nothing ends the run'
          assert_includes reason(stops.last), 'can only wait on operator items'

          # R3 operator_proxy: "I7 はOKです" was refused as an acceptance.
          type!("#{item['id']} はOKです", 'p-ok')
          res = resolve(run, item['id'], 'accept_test_change')
          refute res['item_open'], res.inspect
          assert_equal 'running', res['run_status'], res.inspect
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          last = entries(run, 'check').last
          assert_equal [true, true, git_out(run.worktree, 'rev-parse', 'HEAD')], [last['recheck'], last['ok'], last['commit']]
        end

        # --- (3) what is progress ---------------------------------------------------------

        # R3 t10: one `git log --oneline -1` per turn kept a waiting run alive
        # (10 of 10 Stops "continues").
        def test_a_turn_of_only_read_only_bash_after_a_block_does_not_keep_a_waiting_run_alive
          run = impl_waiting_on_its_review
          effects = entries(run, 'effect').size
          wt = q(run.worktree)
          bash!("git -C #{wt} log --oneline -1")
          bash!("ls #{wt}")
          bash!("git -C #{wt} status --short")
          confined = entries(run, 'effect').drop(effects)
          assert_equal %w[confined confined confined], confined.map { |e| e['verdict'] }, 'each call is confined and journaled'
          ended = stop!('Still waiting on the operator.')
          assert_includes reason(ended), 'can only wait on operator items'
          assert_equal ['ended', 'waiting on operator items'], [run.reload.status, run.end_reason]
        end

        # R3 t2: a failing check on an unchanged commit counted as progress, so a
        # run waiting on "fails on the base commit too" never ended.
        def test_edits_commits_and_a_check_of_a_new_commit_are_progress_a_failing_check_of_the_same_commit_is_not
          repo!('test/test_broken.rb' => "exit 1\n", 'lib/x.rb' => "X = 1\n")
          run = impl_start
          x = File.join(run.worktree, 'lib', 'x.rb')
          bash_write!(x, "X = 2\n")
          commit_via_bash!(run, 'two')
          assert_equal 'tests_failed', adv(run)['status']
          check1 = entries(run, 'check').last
          assert_equal check1['seq'], run.reload.last_progress_seq, 'the first check of a commit is progress'
          assert_includes reason(stop!('The test fails on the base commit too.')), 'continues'

          assert_equal 'tests_failed', adv(run)['status']
          check2 = entries(run, 'check').last
          assert_equal check1['commit'], check2['commit']
          assert_equal check1['seq'], run.reload.last_progress_seq, 'a failing check of the same commit is not progress'

          bash_write!(x, "X = 3\n")
          assert_includes reason(stop!('Edited lib/x.rb.')), 'continues', 'a confined edit in the worktree is progress'
          commit_via_bash!(run, 'three')
          assert_includes reason(stop!('Committed.')), 'continues', 'a confined commit is progress'
          assert_equal 'tests_failed', adv(run)['status']
          check3 = entries(run, 'check').last
          refute_equal check1['commit'], check3['commit']
          assert_equal check3['seq'], run.reload.last_progress_seq
          assert_includes reason(stop!('Checked the new commit.')), 'continues', 'a check of a new commit is progress'

          assert_equal 'tests_failed', adv(run)['status']
          assert_includes reason(stop!('It still fails as on the base commit.')), 'can only wait on operator items'
          assert_equal ['ended', 'waiting on operator items'], [run.reload.status, run.end_reason]
          assert_empty entries(run, 'idle')
        end

        # --- (4) restore_test_command re-pins ---------------------------------------------

        # R3 t7: the stand-in rules tests:spec + reject_test_command (the re-pin
        # drops bin/test); the operator restores the command; X_VALUE=2 (which
        # breaks spec/test_b.rb) committed with bin/test → exit 0 ended the phase.
        def test_restore_test_command_pins_the_restored_commands_tracked_script_again
          repo!('bin/test' => "#!/bin/sh\nexec ruby -Ilib \"$@\"\n", 'lib/x.rb' => "X_VALUE = 1\n",
                'test/test_ok.rb' => "exit 0\n", 'spec/test_b.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          File.chmod(0o755, File.join(@root, 'bin', 'test'))
          git!(@root, 'add', '-A')
          git!(@root, 'commit', '-q', '-m', 'bin/test is executable')
          run = impl_start(test_command: 'bin/test')
          bin = File.join(run.worktree, 'bin', 'test')
          spec = File.join(run.worktree, 'spec', 'test_b.rb')
          assert_includes run.pinned['implement']['tests'].keys, bin, 'the runner script is pinned at start'

          @script['plan_parameters'] = { 'answer' => ['tests:spec', 'reject_test_command'], 'class' => 'decided' }
          y = File.join(run.worktree, 'lib', 'y.rb')
          bash_write!(y, "Y = 1\n")
          first = adv(run)
          assert_equal 'refused', first['status'], "ratified, then the uncommitted work is refused: #{first.inspect}"
          run = Run.load(@paths, run.id)
          assert_equal ['spec', nil], [run.plan.phase(:implement).args[:tests], run.plan.phase(:implement).args[:command]]
          assert_equal [spec], run.pinned['implement']['tests'].keys, 'the re-pin for spec drops bin/test'
          item = run.open_items.find { |i| i['item_kind'] == 'plan_parameters' && i.dig('detail', 'test_command') }
          refute_nil item, run.open_items.inspect
          stop!('The stand-in rejected the test command.')

          type!("#{item['id']} はテストコマンドを元に戻して", 'p-restore')
          res = resolve(run, item['id'], 'restore_test_command')
          refute res['item_open'], res.inspect
          run = Run.load(@paths, run.id)
          assert_equal %w[bin/test spec], [run.plan.phase(:implement).args[:command], run.plan.phase(:implement).args[:tests]]
          pin = run.pinned['implement']
          assert_equal 'bin/test', pin['command']
          assert_includes pin['tests'].keys, bin, "the restored command's tracked script is pinned again"
          assert_equal git_out(@root, 'rev-parse', 'HEAD:bin/test'), pin['tests'][bin]
          assert_includes pin['tests'].keys, spec

          # The guard reads the new pin: an Edit of the script goes to the stand-in.
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          v = pre_hook('s1', 'Edit', { 'file_path' => bin, 'old_string' => 'exec ruby -Ilib "$@"', 'new_string' => 'exit 0' })
          assert_equal 'deny', verdict(v), v.inspect
          assert_equal [bin], asks('pinned_test_change').map { |a| a[:evidence]['path'] }

          # A shell route the guard does not read: X_VALUE=2 with bin/test → exit 0.
          bash!("rm #{q(y)}")
          bash_write!(File.join(run.worktree, 'lib', 'x.rb'), "X_VALUE = 2\n")
          bash_write!(bin, "#!/bin/sh\nexit 0\n")
          commit_via_bash!(run, 'x is two; the runner passes')
          out = adv(run)
          assert_equal 'check_refused', out['status'], "the changed runner is ruled before it judges: #{out.inspect}"
          assert_equal [bin], out['changed']
          assert_equal 'bin/test', asks('pinned_test_change').last[:evidence]['path']
          assert_empty checks_ran, 'nothing ran before the ruling'

          # With the runner restored, the restored command runs the pinned set.
          bash!("git -C #{q(run.worktree)} checkout #{run.base_commit} -- bin/test")
          commit_via_bash!(run, 'restore the runner')
          out = adv(run)
          assert_equal 'tests_failed', out['status'], out.inspect
          assert_equal [spec], out['failed'].map { |f| f['file'] }
          assert_equal ['bin/test', spec], checks_ran.first, 'the restored command judges the pinned set'
        end

        # --- (5) send_back of the design review --------------------------------------------

        # R3 t4: send_back of the design review reopened the implementation
        # review at its spent bound, and its old closure item stayed open.
        def test_send_back_of_the_design_review_reopens_the_later_phases_with_rounds_and_supersedes_their_closure
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          run = start!({ 'goal' => 'make x work', 'template' => 'dev_cycle', 'design_glob' => 'log/x_design_v*.md',
                        'tests' => 'test' })
          write_design('0.1')
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          round_returns
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          c1 = adv(run)
          assert_equal 'closed_provisionally', c1['status'], c1.inspect
          stop!('The design review closed provisionally.')
          bash_write!(File.join(run.worktree, 'lib', 'x.rb'), "X_VALUE = 1 # v2\n")
          commit_via_bash!(run, 'v2')
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          c2 = adv(run)
          assert_equal 'closed_provisionally', c2['status'], c2.inspect
          run.reload
          assert_nil run.current_phase
          assert_equal %w[design_review implementation_review], run.provisional_closures
          assert_includes reason(stop!('Both reviews closed provisionally.')), 'Build the report'

          type!("#{c1['item']} は差し戻して", 'p-back')
          res = resolve(run, c1['item'], 'send_back')
          refute res['item_open'], res.inspect
          run.reload
          assert_equal %w[ended pending pending pending],
                       %w[design design_review implement implementation_review].map { |p| run.phases[p]['status'] }
          assert_equal [1, 1], [run.round_extensions['design_review'], run.round_extensions['implementation_review']],
                       'the implementation review gets its rounds too'
          assert_equal [9, 9], [review_cap(run, 'design_review'), review_cap(run, 'implementation_review')],
                       'each review has the policy\'s 8 rounds and the one granted'
          assert_equal 8, run.spend['review_rounds'], 'the policy\'s rounds for each review are not changed'
          assert_empty entries(run, 'spend_extended')
          assert_equal 'resolved', run.items[c2['item']]['state'], 'its old closure item is superseded'
          assert_match(/superseded/, run.items[c2['item']]['resolution'])
          assert_empty run.provisional_closures
          assert_equal 'design_review', run.current_phase
          assert_includes reason(stop!('Sent back.')), 'continues'

          out = adv(run)
          assert_equal 'dispatched', out['status'], "the sent-back design may go out unchanged: #{out.inspect}"
          assert_equal 2, out['round']
          assert_equal 'closed_provisionally', adv(run)['status']
          assert_equal 'phase_ended', adv(run)['status']
          out = adv(run)
          assert_equal 'dispatched', out['status'], "the implementation review has its round: #{out.inspect}"
          assert_equal 2, out['round']
          assert_empty(run.reload.open_items.select { |i| i['item_kind'] == 'review_open' })
        end

        def test_a_sent_back_phase_sends_an_unchanged_artifact_once_and_then_asks_for_a_new_version
          run, item = closed_design_run
          stop!('Closed provisionally.')
          type!("#{item['id']} は差し戻して、あと 2 周", 'p-back')
          res = resolve(run, item['id'], 'send_back', rounds: 2)
          refute res['item_open'], res.inspect
          assert_equal 2, run.reload.round_extensions['design_review']
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 2, out['round']
          round_returns(p0: [P0], verdicts: %w[REVISE APPROVE])
          @script['review_labels'] = new_labels(P0)
          assert_equal 'open', adv(run)['status']
          out = adv(run)
          assert_equal 'refused', out['status'], "only once: #{out.inspect}"
          assert_includes out['reason'], 'nothing changed since round 2'
          write_design('0.2')
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 3, out['round']
        end

        # --- (6) a carried P0 sent back and labelled fixed -----------------------------------

        # R3 t5: settle_carried matched the label id (DR1.F1) against item ids
        # (I21), so the carried_p0 item stayed open after the P0 was fixed.
        # The carried item now comes from the operator's freeze of the
        # implementation review (a freeze is the only way a P0 is frozen
        # open); sending the design closure back reopens that review, and the
        # P0, still open in its last labelling, goes to the seats again.
        def test_a_frozen_p0_sent_back_with_its_review_and_labelled_fixed_by_its_finding_id_is_settled
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          review_rounds!(1)
          run = start!({ 'goal' => 'make x work', 'template' => 'dev_cycle', 'design_glob' => 'log/x_design_v*.md',
                         'tests' => 'test' })
          write_design('0.1')
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          round_returns
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          closure = adv(run)
          assert_equal 'closed_provisionally', closure['status'], closure.inspect
          stop!('The design review closed provisionally.')
          bash_write!(File.join(run.worktree, 'lib', 'x.rb'), "X_VALUE = 1 # v2\n")
          commit_via_bash!(run, 'v2')
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          round_returns(p0: [P0], verdicts: %w[REVISE APPROVE])
          @script['review_labels'] = new_labels(P0)
          waited = adv(run)
          assert_equal 'waiting', waited['status'], waited.inspect
          stop!('Round 1 of the implementation review is labelled; one P0 is open at the bound.')

          type!("#{waited['item']} は凍結して", 'p-freeze')
          res = resolve(run, waited['item'], 'freeze')
          refute res['item_open'], res.inspect
          carried = run.reload.open_items.find { |i| i['item_kind'] == 'carried_p0' }
          refute_nil carried
          finding = carried.dig('detail', 'finding')
          assert_equal 'IR1.F1', finding
          refute_equal carried['id'], finding
          assert_nil run.current_phase, 'every phase has ended'
          stop!('Frozen by the operator.')

          type!("#{closure['item']} は差し戻して", 'p-back')
          res = resolve(run, closure['item'], 'send_back')
          refute res['item_open'], res.inspect
          assert_equal 'open', run.reload.items[carried['id']]['state']
          assert_equal 'design_review', run.current_phase
          stop!('Sent back.')
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_empty dispatched.last.last['prior_findings'], 'the frozen P0 is not part of the design review'
          round_returns
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          assert_equal 'closed_provisionally', adv(run)['status']
          assert_equal 'phase_ended', adv(run)['status']
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_includes dispatched.last.last['artifact_content'], P0, 'the P0 still open in its last labelling goes to the seats'
          round_returns
          @script['review_labels'] = { 'answer' => [{ 'seat' => 'codex', 'text' => P0, 'label' => 'fixed',
                                                      'earlier_id' => finding, 'grounds' => 'the code bounds the cache' }],
                                       'class' => 'decided' }
          out = adv(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          settled = run.reload.items[carried['id']]
          assert_equal 'resolved', settled['state'], 'the carried P0 labelled fixed by its finding id is settled'
          assert_includes settled['resolution'], 'labelled fixed'
          assert_empty(run.open_items.select { |i| i['item_kind'] == 'carried_p0' })
        end

        # --- (7) reopen from another session -----------------------------------------------

        def resolve_from_s2(run, item, words: nil)
          type!(words || "run #{run.id[-6..]} の #{item['id']} はもう1周回して", 'p-s2', sid: 's2')
          res = resolve(run, item['id'], 'more_rounds', sid: 's2', rounds: 1)
          refute res['item_open'], res.inspect
          assert_equal 'running', res['run_status'], res.inspect
          res
        end

        def assert_s1_refuses_acting_tools(run)
          n = run.reload.journal.entries.size
          { 'Bash' => { 'command' => 'git push origin main' },
            'Write' => { 'file_path' => File.join(@root, 'log', 'x_design_v0.9.md'), 'content' => 'x' },
            'Edit' => { 'file_path' => File.join(@root, 'README.md'), 'old_string' => 'a', 'new_string' => 'b' } }.each do |tool, ti|
            v = pre_hook('s1', tool, ti)
            assert_equal 'deny', verdict(v), "#{tool}: #{v.inspect}"
            assert_includes v.dig('hookSpecificOutput', 'permissionDecisionReason'), 'taken over'
          end
          assert_nil pre_hook('s1', 'Read', { 'file_path' => @transcript }), 'reads pass'
          assert_nil stop!('Wrote the outline.', sid: 's1'), 'the old session is not pushed on'
          out = host('agent_start', { 'goal' => 'design z', 'template' => 'design_only', 'design_glob' => 'log/z_design_v*.md' }, sid: 's1')
          assert_equal 'refused', out['status'], "agent_start in a taken-over session: #{out.inspect}"
          assert_includes out['reason'], 'taken over'
          assert_equal n, run.reload.journal.entries.size, 'nothing from s1 lands in the journal'
        end

        def test_an_ended_run_reopened_from_a_session_holding_no_run_is_bound_there_and_the_old_session_is_marked
          run, item = design_at_bound
          end_waiting!(run)
          assert_equal run.id, Run.bound_to(@paths, 's1')&.id
          resolve_from_s2(run, item)
          run.reload
          assert_equal %w[running s2], [run.status, run.bound_session]
          assert_equal run.id, Run.bound_to(@paths, 's2')&.id
          assert Run.taken_over?(@paths, 's1')
          assert_nil Run.bound_to(@paths, 's1')
          assert_s1_refuses_acting_tools(run)

          assert_includes reason(stop!('Reopened here.', sid: 's2')), 'continues'
          write_design('0.2', sid: 's2')
          out = adv(run, sid: 's2')
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 2, out['round']

          type!('こちらは了解です', 'p-s1', sid: 's1')
          assert_nil pre_hook('s1', 'Bash', { 'command' => 'echo hi' }), 's1 is an ordinary session again'
          refute Run.taken_over?(@paths, 's1')
          assert_equal run.id, Run.bound_to(@paths, 's2')&.id
        end

        def test_a_finished_run_reopened_from_a_session_holding_no_run_is_bound_there_and_the_old_session_is_marked
          run, item = design_at_bound
          end_waiting!(run)
          deck = finish!(run)
          old = File.read(deck)
          assert_equal 'finished', run.reload.status
          assert_equal run.id, Run.bound_to(@paths, 's1')&.id, 'the guard stays until the operator speaks'
          resolve_from_s2(run, item)
          run.reload
          assert_equal ['running', 's2', nil], [run.status, run.bound_session, run.report]
          assert_equal run.id, Run.bound_to(@paths, 's2')&.id
          assert Run.taken_over?(@paths, 's1')
          assert_equal old, File.read(File.join(File.dirname(deck), 'deck_1.html')), 'the earlier deck is kept'
          assert_s1_refuses_acting_tools(run)
          assert_equal 'refused', host('agent_finish', { 'run_id' => run.id }, sid: 's1')['status']
          write_design('0.2', sid: 's2')
          assert_equal 'dispatched', adv(run, sid: 's2')['status']
        end

        def reopened_while_s2_holds_another
          a, item = design_at_bound
          end_waiting!(a)
          b = design_start(stem: 'y', sid: 's2')
          resolve_from_s2(a, item)
          a.reload
          assert_equal 'running', a.status
          assert_nil a.bound_session, 'neither session takes it'
          assert Run.taken_over?(@paths, 's1')
          assert_equal b.id, Run.bound_to(@paths, 's2')&.id
          assert_equal 's2', b.reload.bound_session
          [a, b]
        end

        def test_a_run_reopened_from_a_session_holding_another_run_marks_the_old_session_and_waits_for_resume
          a, b = reopened_while_s2_holds_another
          assert_s1_refuses_acting_tools(a)
          assert_equal 'refused', adv(a, sid: 's2')['status'], 'it does not run in the session holding B'
          assert_equal 'refused', adv(a, sid: 's1')['status']
          out = host('agent_start', { 'resume' => a.id }, sid: 's1')
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'taken over'
          write_design('0.1', stem: 'y', sid: 's2')
          assert_includes b.reload.created_paths, File.join(@root, 'log', 'y_design_v0.1.md'), "B's work is B's"
          refute(a.reload.created_paths.any? { |p| p.include?('y_design') })

          out = host('agent_start', { 'resume' => a.id }, sid: 's3')
          assert_equal 'resumed', out['status'], "the run waits for resume: #{out.inspect}"
          assert_nil out['taken_over_from']
          assert_equal 's3', a.reload.bound_session
          write_design('0.2', sid: 's3')
          assert_equal 'dispatched', adv(a, sid: 's3')['status']
        end

        # The marker holds "until the operator speaks there". The design's
        # pattern for an ending (hooks.rb pre_tool_use: release before the agent
        # tool runs, so agent_start right after the words is not refused) is
        # the same question here.
        def test_after_the_operator_speaks_in_the_taken_over_session_agent_start_there_is_not_refused
          a, = reopened_while_s2_holds_another
          type!("#{a.id} はこのセッションで続けて", 'p-s1', sid: 's1')
          out = host('agent_start', { 'resume' => a.id }, sid: 's1')
          if out['status'] == 'refused'
            # It works only after some other tool's PreToolUse cleared the marker.
            pre_hook('s1', 'Read', { 'file_path' => @transcript })
            later = host('agent_start', { 'resume' => a.id }, sid: 's1')
            flunk('BUG: hooks.rb:132-138 pre_tool_use returns with_session for agent tools before ' \
                 'clear_taken_over_if_typed, so agent_start(resume) right after the operator speaks in a taken-over ' \
                 "session is refused \"until the operator speaks\" (#{out['reason'][0, 60]}…); after a Read it gives " \
                 "#{later['status']}")
          end
          assert_equal 'resumed', out['status'], out.inspect
          assert_equal 's1', a.reload.bound_session
          refute Run.taken_over?(@paths, 's1')
        end

        # --- (8) confirming a closure ------------------------------------------------------

        def test_a_confirmed_closure_is_not_provisional_in_the_report_material_and_a_bare_correction_leaves_it_open
          run, item = closed_design_run
          assert_equal %w[design_review], material(run)['provisional_closures']
          stop!('Closed provisionally; the report is next.')

          type!("#{item['id']} は違う気がする", 'p-corr')
          res = act('correct', run, item['id'])
          assert res['item_open'], "a correction without send_back settles nothing: #{res.inspect}"
          assert_equal 'open', run.reload.items[item['id']]['state']
          assert_equal %w[design_review], run.provisional_closures
          assert_equal %w[design_review], material(run)['provisional_closures']

          type!("#{item['id']} は確定で", 'p-conf')
          res = act('confirm', run, item['id'])
          refute res['item_open'], res.inspect
          assert_equal 'resolved', run.reload.items[item['id']]['state']
          m = material(run)
          assert_empty m['provisional_closures'], 'the operator confirmed it'
          phase = m['phases'].find { |p| p['name'] == 'design_review' }
          assert_equal [false, true], [phase['provisional'], phase['confirmed']]
          assert_equal 'closure', m['phases'].find { |p| p['name'] == 'design_review' }['by']
        end

        def test_a_plain_resolve_of_a_closure_also_clears_its_provisional_flag
          run, item = closed_design_run
          type!("#{item['id']} はこれでいい", 'p-ok')
          res = resolve(run, item['id'])
          refute res['item_open'], res.inspect
          m = material(run)
          assert_empty m['provisional_closures']
          assert_equal false, m['phases'].find { |p| p['name'] == 'design_review' }['provisional']
        end

        # --- (9) counts and decision words from the operator's words ---------------------------

        def more_rounds_from(words, rounds)
          run, item = design_at_bound
          end_waiting!(run)
          type!(format(words, item['id']), 'p-more')
          res = resolve(run, item['id'], 'more_rounds', rounds: rounds)
          refute res['item_open'], res.inspect
          assert_equal 'running', res['run_status'], res.inspect
          run.reload
        end

        def test_the_operators_two_rounds_are_two_and_the_actors_nine_cannot_raise_them
          run = more_rounds_from('%s はあと 2 周回して', 9)
          assert_equal [2], entries(run, 'rounds_extended').map { |e| e['by'] }
          assert_equal [2, 3], [run.round_extensions['design_review'], review_cap(run, 'design_review')]
          stop!('Two more rounds.')
          write_design('0.2')
          assert_equal 2, adv(run)['round']
        end

        def test_one_more_round_is_one_whatever_the_actor_asks
          run = more_rounds_from('%s はもう一周', 9)
          assert_equal [1, 2], [run.round_extensions['design_review'], review_cap(run, 'design_review')]
        end

        def test_ordinary_japanese_for_two_more_rounds_counts_two
          run = more_rounds_from('%s はあと2回まわして', 5)
          assert_equal [2, 3], [run.round_extensions['design_review'], review_cap(run, 'design_review')]
        end

        def test_do_not_freeze_does_not_freeze
          run, item = design_at_bound
          end_waiting!(run)
          type!("#{item['id']} は凍結しないで", 'p-no')
          res = resolve(run, item['id'], 'freeze')
          assert res['item_open'], res.inspect
          assert_includes res['reason'], 'do not say freeze'
          run.reload
          assert_equal %w[open pending ended], [run.items[item['id']]['state'], run.phases['design_review']['status'], run.status]
          assert_empty(run.open_items.select { |i| i['item_kind'] == 'carried_p0' })
          type!("#{item['id']} は凍結して", 'p-yes')
          res = resolve(run, item['id'], 'freeze')
          refute res['item_open'], res.inspect
          assert_equal 'operator', run.reload.phases['design_review']['by']
        end

        def test_the_decision_name_the_item_prints_accepts_a_base_failing_test
          repo!('test/test_broken.rb' => "exit 1\n", 'test/test_ok.rb' => "exit 0\n", 'lib/x.rb' => "X = 1\n")
          run = impl_start
          bash_write!(File.join(run.worktree, 'lib', 'x.rb'), "X = 2\n")
          commit_via_bash!(run, 'two')
          out = adv(run)
          assert_equal 'tests_failed', out['status'], out.inspect
          ref = out['failing_on_the_base_too'].first['item']
          end_waiting!(run)
          type!("#{ref} accept_failing", 'p-acc')
          res = resolve(run, ref, 'accept_failing')
          refute res['item_open'], res.inspect
          assert_equal 'running', res['run_status'], res.inspect
          out = adv(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal [File.join(run.worktree, 'test', 'test_broken.rb')], out['failing_before_the_run']
        end

        # --- (10) a stand-in that cannot be built; a ruling that raises ---------------------

        def assert_queued_and_hazard_ends(run)
          v = pre_hook('s1', 'AskUserQuestion', QUESTION)
          assert_equal 'deny', verdict(v), v.inspect
          assert_includes v.dig('hookSpecificOutput', 'permissionDecisionReason'), 'Queued for the operator'
          run.reload
          item = run.open_items.find { |i| i['item_kind'] == 'question' }
          refute_nil item, 'the question is an operator item'
          assert_equal QUESTION['questions'].first['question'], item['text']
          d = run.decisions.last
          assert_equal %w[question operator_item], [d['point'], d['class']]
          assert_includes d['reason'], 'LoadError'

          out = stop!(LEAK)
          assert_equal 'block', out&.dig('decision'), out.inspect
          assert_includes reason(out), 'hazard'
          run.reload
          assert_equal ['ended', 'hazard (not_ruled)'], [run.status, run.end_reason]
          assert_equal 'not_ruled', run.hazard['ruling']
        end

        def test_a_stand_in_that_cannot_be_built_queues_questions_and_a_hazard_ends_the_run_not_ruled
          run = design_start
          @hook_factory = ->(_r, _p) { raise LoadError, 'cannot load such file -- kairos_mcp/tools/base_tool' }
          assert_queued_and_hazard_ends(run)
        end

        # R3 operator_proxy P0: the project's ruby cannot require kairos_mcp; the
        # hook script's own factory raises LoadError.
        def test_through_the_hook_script_a_ruby_without_kairos_mcp_queues_questions_and_ends_on_a_hazard
          run = design_start
          @use_script = true
          assert_queued_and_hazard_ends(run)
          assert_nil stop!('Building the report next.'), 'the ending is told once'
        end

        # R3 precedent_auditor P1: a hazard ruling that raises went unruled and
        # the run continued.
        def test_a_hazard_ruling_that_raises_ends_the_run
          run = design_start
          @script['hazard'] = { 'raise' => 'the stand-in process crashed' }
          out = stop!(LEAK)
          assert_equal 'block', out&.dig('decision'), out.inspect
          run.reload
          assert_equal ['ended', 'hazard (not_ruled)'], [run.status, run.end_reason]
          assert_includes run.hazard['error'].to_s, 'RuntimeError'
          assert_nil stop!('Building the report next.'), 'the ending is told once'
        end

        # --- found while driving (3): a heredoc in a confined Bash call ---------------------

        # next_step tells the actor each Bash call "starts afresh: use absolute
        # paths"; the host's Bash runs from the main checkout. A heredoc there
        # (the host's own file and commit forms) needs bash 3.2's temp file,
        # which it makes in /var/tmp, /tmp or the working directory — never
        # TMPDIR — and the profile lets none of them be written.
        def test_a_heredoc_edit_and_a_heredoc_commit_from_the_main_checkout_work_confined
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          run = impl_start
          x = File.join(run.worktree, 'lib', 'x.rb')
          head = git_out(run.worktree, 'rev-parse', 'HEAD')
          cmd = "cat > #{q(x)} <<'EOF'\nX_VALUE = 1 # v2\nEOF\n" \
                "git -C #{q(run.worktree)} #{GIT_ID} commit -q -a -F - <<'EOF'\nv2\n\nCo-Authored-By: t <t@t>\nEOF"
          v = pre_hook('s1', 'Bash', { 'command' => cmd })
          assert_equal 'allow', verdict(v), "the host's forms are confined, not refused: #{v.inspect}"
          out, st = Open3.capture2e('/bin/bash', '-c', v.dig('hookSpecificOutput', 'updatedInput', 'command'), chdir: @root)
          body = File.read(x)
          unless st.success? && body == "X_VALUE = 1 # v2\n"
            flunk('BUG: confinement.rb:112-115 wrap_command runs /bin/bash 3.2 with only TMPDIR writable; bash 3.2 ' \
                 'makes here-document temp files in /var/tmp, /tmp or the cwd, not TMPDIR, so from the main checkout ' \
                 "`cat > <worktree file> <<'EOF'` fails \"cannot create temp file for here document\" and leaves the " \
                 "file truncated (now #{body.bytesize} bytes, exit #{st.exitstatus}: #{out.lines.first.to_s.strip}); " \
                 "the commit's heredoc fails the same way (HEAD moved: #{git_out(run.worktree, 'rev-parse', 'HEAD') != head})")
          end
          refute_equal head, git_out(run.worktree, 'rev-parse', 'HEAD')
        end

        def test_a_precedent_store_that_cannot_be_read_at_a_hazard_ends_the_run
          run = design_start
          FileUtils.mkdir_p(File.join(@paths.precedents_dir, 'raw', 'torn.jsonl'))
          out = stop!(LEAK)
          assert_equal 'block', out&.dig('decision'), out.inspect
          run.reload
          assert_equal ['ended', 'hazard (not_ruled)'], [run.status, run.end_reason]
          assert_includes run.hazard['error'].to_s, 'EISDIR'
        end
      end
    end
  end
end
