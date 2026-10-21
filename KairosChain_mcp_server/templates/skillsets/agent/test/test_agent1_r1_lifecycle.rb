# frozen_string_literal: true

# Regression tests for the implementation review R1 (2026-10-20), lifecycle
# and binding (INV-6, INV-7): who may start, resume, advance, alert, finish
# and stop a run, what a session's end and an idle turn do to it, and the
# merge item's place before the report material is read.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../lib/agent/service'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R1Lifecycle < Minitest::Test
        HOOK = File.expand_path('../hooks/agent_hook.rb', __dir__)

        # A stand-in that answers from a script, recording what it was asked.
        class LifecycleStandIn
          attr_reader :asked

          def initialize(script)
            @script = script
            @asked = []
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
            @asked << { point: point, question: question }
            reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
            StandIn::Answer.new(answer: reply['answer'], klass: reply['class'], confidence: 0.9, basis: [],
                                reason: 'scripted', calls: 1, inputs_digest: 'x' * 64)
          end

          def rule_hazard(text, **kw)
            a = ask(point: 'hazard', question: text, options: StandIn::HAZARD_RULINGS, **kw)
            return ['not_ruled', a] if a.failed?

            [a.answer.to_s, a]
          end
        end

        POLICY_SRC = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 8, stand_in_calls: 100 }
          end
        RUBY

        def setup
          @root = File.realpath(Dir.mktmpdir('a1r1l'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@root, 'global_bound_sessions.txt')
          @data = File.join(@root, '.kairos')
          @paths = Paths.new(@data)
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'p1.rb'), POLICY_SRC)
          FileUtils.mkdir_p(File.join(@root, 'log'))
          @policy = DSL.parse_policy(POLICY_SRC)
          @script = {}
          @stand_in = LifecycleStandIn.new(@script)
          @chain = []
          @transcript = File.join(@root, 'transcript.jsonl')
          File.write(@transcript, '')
          Precedents.new(@paths.precedents_dir).add([{ 'source' => 'seed', 'project' => 'x', 'at' => '2026-10-01',
                                                       'kind' => 'typed_answer', 'question' => '査読は何周?',
                                                       'words' => '収束するまで回して' }])
        end

        def teardown
          FileUtils.rm_rf(@root)
        end

        # --- harness ------------------------------------------------------------

        def service
          real = Service.allocate
          run_cmd = lambda do |argv, chdir, timeout|
            if argv.any? { |a| a.to_s.end_with?('check.py') }
              ["issues=0\n", true]
            else
              real.send(:default_run_cmd, argv, chdir, timeout)
            end
          end
          Service.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in },
                      invoke: ->(_name, _args) { {} },
                      chain: ->(logs) { @chain << logs; @chain.size }, run_cmd: run_cmd)
        end

        def hooks
          Hooks.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in })
        end

        # The host's PreToolUse on an agent tool: marks the guard as seen and
        # tells the tool its session.
        def via_hook(sid, tool, args)
          out = hooks.handle('PreToolUse', 'session_id' => sid, 'tool_name' => "mcp__kairos-chain__#{tool}", 'tool_input' => args)
          out.dig('hookSpecificOutput', 'updatedInput')
        end

        def typed(text, prompt_id)
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => prompt_id, 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => text }))
          end
        end

        def adopt!
          words = "adopt policy p1 #{@policy.digest[0, 8]} でお願いします"
          typed(words, 'pr1')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => words, 'prompt_id' => 'pr1',
                                           'transcript_path' => @transcript)
          assert_equal 'adopted', service.items('action' => 'adopt_policy', 'policy' => 'p1')['status']
        end

        def design_args(goal = 'design the thing')
          { 'goal' => goal, 'template' => 'design_only', 'design_glob' => 'log/thing_design_v*.md' }
        end

        # agent_start through the host: PreToolUse (marker, session id), the
        # tool, then PostToolUse (binding with the transcript).
        def start_in(sid, args)
          out = service.start(via_hook(sid, 'agent_start', args))
          if out['bind']
            hooks.handle('PostToolUse', 'session_id' => sid, 'tool_name' => 'mcp__kairos-chain__agent_start',
                                        'transcript_path' => @transcript,
                                        'tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }])
          end
          out
        end

        def start_design_run(sid = 's1')
          adopt! unless Policies.new(@paths).adopted
          out = start_in(sid, design_args)
          assert_equal 'started', out['status'], out.inspect
          Run.load(@paths, out['run_id'])
        end

        def git!(dir, *args)
          system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', *args, exception: true)
        end

        def init_repo!
          system('git', '-C', @root, 'init', '-q', '-b', 'main', exception: true)
          FileUtils.mkdir_p(File.join(@root, 'test'))
          File.write(File.join(@root, 'test', 'test_ok.rb'), "exit 0\n")
          File.write(File.join(@root, '.gitignore'), ".kairos/\nlog/\ntranscript.jsonl\nhome/\nglobal_bound_sessions.txt\n")
          git!(@root, 'add', '.')
          git!(@root, 'commit', '-q', '-m', 'init')
        end

        def dev_args
          { 'goal' => 'g', 'template' => 'dev_cycle', 'design_glob' => 'log/g_design_v*.md', 'tests' => 'test' }
        end

        def binding_file(sid)
          File.join(@paths.bindings_dir, Run.safe(sid))
        end

        def kinds(run)
          run.journal.entries.map { |e| e['kind'] }
        end

        # A subagent writes the deck from the report material alone, through
        # the guarded Write tool of the session the run is bound to.
        def write_deck_from_material(run)
          material = JSON.parse(File.read(service.status('run_id' => run.id, 'report_material' => true)['report_material']['material_path']))
          html = (material['decisions'].map { |d| d['id'] } + material['items'].map { |i| i['id'] } +
                  material['phases'].map { |p| p['name'] }).join(' ')
          deck = File.join(@root, 'log', 'agent_runs', run.id, 'deck.html')
          out = hooks.handle('PreToolUse', 'session_id' => run.reload.bound_session, 'tool_name' => 'Write',
                                           'agent_id' => 'a1b2c3d4e5', 'cwd' => @root,
                                           'tool_input' => { 'file_path' => deck, 'content' => html })
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
          File.write(deck, html)
          material
        end

        # hooks/agent_hook.rb as the host runs it, with every location in tmp.
        def run_hook(input)
          home = File.join(@root, 'home')
          FileUtils.mkdir_p(home)
          env = { 'HOME' => home, 'KAIROS_DATA_DIR' => @data, 'CLAUDE_PROJECT_DIR' => @root,
                  'KAIROS_AGENT_GLOBAL' => ENV['KAIROS_AGENT_GLOBAL'], 'KAIROS_MCP_LIB' => nil }
          out, err, st = Open3.capture3(env, RbConfig.ruby, HOOK, stdin_data: JSON.generate(input), chdir: @root)
          [out.strip.empty? ? nil : JSON.parse(out), err, st]
        end

        # --- start: hooks must be live; nothing is created otherwise -------------

        def test_start_without_a_session_or_with_a_missing_or_stale_marker_is_refused_and_creates_nothing
          skip 'sandbox-exec unavailable' unless Confinement.available?
          init_repo!
          adopt!
          chain_before = @chain.size

          no_sid = service.start(dev_args)
          missing = service.start(dev_args.merge('_session_id' => 's_missing'))
          FileUtils.mkdir_p(@paths.guard_seen_dir)
          stale = File.join(@paths.guard_seen_dir, 's_stale')
          FileUtils.touch(stale)
          old = Time.now - 3600
          File.utime(old, old, stale)
          stale_out = service.start(dev_args.merge('_session_id' => 's_stale'))
          resume_stale = service.start('resume' => 'run_x', '_session_id' => 's_stale')

          [no_sid, missing, stale_out, resume_stale].each do |out|
            assert_equal 'refused', out['status'], out.inspect
            assert_includes out['reason'], 'hooks are not active'
          end
          assert_empty Run.all(@paths), 'no run journal'
          assert_empty Dir.glob(File.join(@paths.bindings_dir, '*')), 'no binding'
          assert_equal chain_before, @chain.size, 'no chain record'
          refute File.exist?(File.join(@root, '.claude', 'worktrees')), 'no worktree'
          assert_empty `git -C #{@root} branch --list 'agent-run/*'`.strip, 'no run branch'
          refute File.exist?(File.join(@root, 'log', 'agent_runs')), 'no report directory'
          refute File.exist?(ENV['KAIROS_AGENT_GLOBAL']), 'no session registered as bound'

          # The same arguments start a run once the guard has been seen there.
          out = start_in('s_stale', dev_args)
          assert_equal 'started', out['status'], out.inspect
          refute_empty `git -C #{@root} branch --list 'agent-run/*'`.strip
        end

        # --- start: one unfinished run per session ------------------------------

        def test_start_is_refused_in_a_session_bound_to_an_unfinished_run
          run = start_design_run('s1')
          other = start_design_run('s2')
          chain_before = @chain.size

          again = service.start(via_hook('s1', 'agent_start', design_args('another')))
          assert_equal 'refused', again['status']
          assert_includes again['reason'], run.id
          takeover = service.start(via_hook('s1', 'agent_start', 'resume' => other.id))
          assert_equal 'refused', takeover['status'], 'a bound session does not take over a second run'

          assert_equal 'stopped', service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 't')['status']
          assert_equal 'ended', run.reload.status
          ended = service.start(via_hook('s1', 'agent_start', design_args('another')))
          assert_equal 'refused', ended['status'], 'an ended run without its report still holds the session'

          assert_equal 2, Run.all(@paths).size
          assert_equal run.id, File.read(binding_file('s1')).strip
          assert_equal 's2', other.reload.bound_session
          assert_equal other.id, File.read(binding_file('s2')).strip
          assert_equal chain_before, @chain.size
        end

        # Following the refusal's advice leads somewhere: stop ends the run, the
        # next refusal names what is left (the report and agent_finish), and
        # the operator's next typed words release the session (design §8).
        def test_following_the_refusals_advice_leads_to_a_free_session
          run = start_design_run('s1')
          refused = service.start(via_hook('s1', 'agent_start', design_args('another')))
          assert_equal 'refused', refused['status']
          assert_includes refused['reason'], 'agent_stop', 'a running run is stopped first'
          assert_equal 'stopped', service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 'as advised')['status']
          again = service.start(via_hook('s1', 'agent_start', design_args('another')))
          assert_equal 'refused', again['status']
          refute_includes again['reason'], 'agent_stop', 'an ended run is not sent back to agent_stop'
          assert_includes again['reason'], 'agent_finish'
          typed('じゃあ次の件に進めて', 'p-next')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => 'じゃあ次の件に進めて', 'prompt_id' => 'p-next',
                                           'transcript_path' => @transcript)
          hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Read', 'tool_input' => { 'file_path' => @transcript })
          assert_nil Run.bound_to(@paths, 's1'), "the operator's next words release the ended run"
          third = service.start(via_hook('s1', 'agent_start', design_args('another')))
          assert_equal 'started', third['status'], third.inspect
        end

        # --- resume: running elsewhere, interrupted, ended without a report -----

        # A run whose binding never happened (the server died between creating
        # and binding) is running with no session; a resume takes it up.
        def test_resume_takes_up_a_running_run_no_session_holds
          adopt!
          plan = DSL.parse_plan(Templates.build('design_only', name: 'x', goal: 'g', design_glob: 'log/thing_design_v*.md'))
                    .check_against(@policy)
          run = Run.create(@paths, goal: 'g', target_repo: @root, worktree: nil, branch: nil, plan: plan, policy: @policy)
          assert_equal 'running', run.status
          assert_nil run.bound_session

          out = start_in('s2', 'resume' => run.id)
          assert_equal 'resumed', out['status'], out.inspect
          assert_nil out['taken_over_from']
          assert_equal 's2', run.reload.bound_session
          assert_equal 'not_yet', service.advance('run_id' => run.id, '_session_id' => 's2')['status']
          assert_equal 'stopped', service.stop('run_id' => run.id, '_session_id' => 's2', 'reason' => 'x')['status']
        end

        def test_resume_takes_over_a_run_whose_session_went_quiet_and_the_old_session_refuses
          run = start_design_run('s1')
          assert File.exist?(binding_file('s1'))

          refused = service.start('resume' => run.id, '_session_id' => 's_nohooks')
          assert_equal 'refused', refused['status'], 'a session whose guard is not seen cannot take a run'
          assert_equal 's1', run.reload.bound_session

          live = start_in('s2', 'resume' => run.id)
          assert_equal 'refused', live['status'], 'a run whose session is live is not taken from it (INV-6)'
          old = Time.now - 3600
          File.utime(old, old, File.join(@paths.guard_seen_dir, 's1'))

          out = start_in('s2', 'resume' => run.id)
          assert_equal 'resumed', out['status'], out.inspect
          assert_equal 's1', out['taken_over_from']
          assert_equal 'running', out['run_status']
          run.reload
          assert_equal 's2', run.bound_session
          assert_includes File.read(binding_file('s1')), 'taken_over:', "the old session keeps a taken-over marker"
          assert_equal run.id, File.read(binding_file('s2')).strip
          assert_nil Run.bound_to(@paths, 's1')
          assert_equal run.id, Run.bound_to(@paths, 's2')&.id

          # s1 refuses what would act until the operator speaks there again.
          n = run.journal.entries.size
          d = hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Bash',
                                         'tool_input' => { 'command' => 'git push origin main' }, 'cwd' => @root)
          assert_equal 'deny', d.dig('hookSpecificOutput', 'permissionDecision')
          assert_includes d.dig('hookSpecificOutput', 'permissionDecisionReason'), 'taken over'
          assert_nil hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Read', 'tool_input' => { 'file_path' => @transcript })
          assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Wrote the outline.')
          typed('続けて', 'p_s1')
          assert_nil hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '続けて', 'prompt_id' => 'p_s1',
                                                      'transcript_path' => @transcript)
          hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Read', 'tool_input' => { 'file_path' => @transcript })
          refute File.exist?(binding_file('s1')), "the operator's words in s1 clear the marker (at the next hook event)"
          assert_nil hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Bash',
                                                'tool_input' => { 'command' => 'git push origin main' }, 'cwd' => @root)
          assert_nil hooks.handle('SessionEnd', 'session_id' => 's1', 'reason' => 'exit')
          hook_out, _err, st = run_hook('hook_event_name' => 'PreToolUse', 'session_id' => 's1', 'tool_name' => 'Bash',
                                        'tool_input' => { 'command' => 'git push origin main' }, 'cwd' => @root)
          assert st.success?
          assert_nil hook_out, 'the host hook script treats s1 as unbound'
          run.reload
          assert_equal n, run.journal.entries.size, "nothing from s1 lands in the run's journal"
          assert_equal 'running', run.status, "s1's session end does not interrupt a run s2 holds"
          assert_equal 's2', run.bound_session

          assert_equal 'refused', service.advance('run_id' => run.id, '_session_id' => 's1')['status']
          adv = service.advance('run_id' => run.id, '_session_id' => 's2')
          assert_equal 'not_yet', adv['status'], adv.inspect
        end

        def test_resume_takes_up_an_interrupted_run
          run = start_design_run('s1')
          hooks.handle('SessionEnd', 'session_id' => 's1', 'reason' => 'exit')
          assert_equal 'interrupted', run.reload.status

          out = start_in('s2', 'resume' => run.id)
          assert_equal 'resumed', out['status'], out.inspect
          assert_equal 'running', out['run_status']
          run.reload
          assert_equal 'running', run.status
          assert_equal 's2', run.bound_session
          assert_equal run.id, File.read(binding_file('s2')).strip
          assert_equal 'not_yet', service.advance('run_id' => run.id, '_session_id' => 's2')['status']
        end

        def test_resume_takes_up_an_ended_unreported_run_which_finishes_but_does_not_advance
          run = start_design_run('s1')
          assert_equal 'stopped', service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 'operator')['status']
          hooks.handle('SessionEnd', 'session_id' => 's1', 'reason' => 'exit')
          run.reload
          assert_equal 'ended', run.status, 'a session end does not turn an ended run into an interrupted one'
          refute File.exist?(binding_file('s1'))
          assert_equal 'refused', service.finish('run_id' => run.id, '_session_id' => 's1')['status']
          listed = hooks.handle('SessionStart', 'session_id' => 's2', 'source' => 'startup')
          assert_includes listed.dig('hookSpecificOutput', 'additionalContext').to_s, "agent_start(resume: '#{run.id}')",
                          'the next session start offers the unreported run'

          out = start_in('s2', 'resume' => run.id)
          assert_equal 'resumed', out['status'], out.inspect
          assert_equal 'ended', out['run_status']
          assert_equal 's2', run.reload.bound_session
          assert_equal run.id, Run.bound_to(@paths, 's2')&.id

          adv = service.advance('run_id' => run.id, '_session_id' => 's2')
          assert_equal 'refused', adv['status']
          assert_includes adv['reason'], 'ended'

          write_deck_from_material(run)
          fin = service.finish('run_id' => run.id, '_session_id' => 's2')
          assert_equal 'finished', fin['status'], fin.inspect
          assert_equal 'finished', run.reload.status
        end

        # --- session end and idle turns -----------------------------------------

        def test_session_end_through_the_hook_script_interrupts_and_removes_the_binding_file
          run = start_design_run('s1')
          out, err, st = run_hook('hook_event_name' => 'SessionEnd', 'session_id' => 's1', 'reason' => 'exit')
          assert st.success?, err
          assert_nil out
          run.reload
          assert_equal 'interrupted', run.status
          assert_nil run.bound_session
          refute File.exist?(binding_file('s1')), 'the binding file goes with the session'
          unbound = run.journal.entries.reverse.find { |e| e['kind'] == 'unbound' }
          assert_equal 's1', unbound['session_id'], 'the unbinding names the session that ended'

          # With no stale binding file the agent tools still learn the session.
          out, _err, st = run_hook('hook_event_name' => 'PreToolUse', 'session_id' => 's1',
                                   'tool_name' => 'mcp__kairos-chain__agent_status', 'tool_input' => { 'run_id' => run.id })
          assert st.success?
          assert_equal 's1', out.dig('hookSpecificOutput', 'updatedInput', '_session_id')
        end

        def test_a_stop_without_progress_rests_the_run_running_and_bound_never_interrupted
          run = start_design_run('s1')
          assert_equal 'block', hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Outline next.')['decision']
          # A refused effect is an open item, but neither progress nor blocking.
          denied = hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'mcp__kairos-chain__knowledge_update',
                                              'tool_input' => {}, 'cwd' => @root)
          assert_equal 'deny', denied.dig('hookSpecificOutput', 'permissionDecision')
          3.times do
            assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Done for now.')
          end
          run.reload
          assert_equal 'running', run.status
          assert_equal 's1', run.bound_session
          assert File.exist?(binding_file('s1'))
          assert_equal run.id, Run.bound_to(@paths, 's1')&.id
          refute_includes kinds(run), 'interrupted'
          refute_includes kinds(run), 'run_ended'
          assert_operator kinds(run).count('idle'), :>=, 3

          # The guard keeps working while it rests; progress wakes the next stop.
          path = File.join(@root, 'log', 'thing_design_v0.1.md')
          w = hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Write',
                                         'tool_input' => { 'file_path' => path, 'content' => 'x' }, 'cwd' => @root)
          assert_equal 'allow', w.dig('hookSpecificOutput', 'permissionDecision')
          assert_equal 'block', hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Wrote v0.1.')['decision']
        end

        # --- finish -------------------------------------------------------------

        def test_finish_is_idempotent_and_the_operators_next_words_unbind
          run = start_design_run('s1')
          service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 'enough')
          write_deck_from_material(run)
          fin = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', fin['status'], fin.inspect
          assert_equal run.id, Run.bound_to(@paths, 's1')&.id, "the guard stays until the operator's next typed words"
          typed('ok, thanks', 'p-thanks')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => 'ok, thanks', 'prompt_id' => 'p-thanks',
                                           'transcript_path' => @transcript)
          hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'ok')
          run.reload
          assert_nil run.bound_session
          assert_nil Run.bound_to(@paths, 's1')
          refute File.exist?(binding_file('s1')), 'the binding file is gone'
          assert_equal 's1', run.journal.entries.reverse.find { |e| e['kind'] == 'unbound' }['session_id']
          chain = @chain.size
          n = run.journal.entries.size

          again = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', again['status']
          assert again['already']
          run.reload
          assert_equal n, run.journal.entries.size, 'a second finish writes nothing'
          assert_equal 1, kinds(run).count('report_built')
          assert_equal chain, @chain.size, 'no second chain record'

          resumed = service.start(via_hook('s2', 'agent_start', 'resume' => run.id))
          assert_equal 'refused', resumed['status'], 'a finished run is not resumable'
          assert_equal 'started', start_in('s1', design_args('next'))['status'], 'the session is free again'
        end

        # --- alert --------------------------------------------------------------

        def test_alert_is_refused_when_the_run_is_not_running
          run = start_design_run('s1')
          service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 'enough')
          assert_equal 'ended', run.reload.status
          decisions = run.decisions.size

          out = service.items('action' => 'alert', 'run_id' => run.id, '_session_id' => 's1',
                              'text' => 'The API key was pushed to the public repo.')
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'ended'
          run.reload
          assert_empty(@stand_in.asked.select { |a| a[:point] == 'hazard' }, 'the stand-in is not asked')
          assert_equal decisions, run.decisions.size
          assert_nil run.hazard
          assert_equal 'stopped: enough', run.end_reason, 'the ending is not rewritten as a hazard'
        end

        # --- advance lock -------------------------------------------------------

        def test_advance_is_busy_while_another_advance_holds_the_runs_lock
          run = start_design_run('s1')
          n = run.journal.entries.size
          lock = File.join(run.dir, 'advance.lock')
          holder = 'f = File.open(ARGV[0], File::RDWR | File::CREAT, 0o600); f.flock(File::LOCK_EX); ' \
                   '$stdout.puts "held"; $stdout.flush; $stdin.read'
          IO.popen([RbConfig.ruby, '-e', holder, lock], 'r+') do |io|
            assert_equal "held\n", io.gets
            out = service.advance('run_id' => run.id, '_session_id' => 's1')
            assert_equal 'busy', out['status'], out.inspect
            io.close_write
          end
          assert_equal n, run.reload.journal.entries.size, 'a busy advance writes nothing'
          assert_empty @stand_in.asked, 'a busy advance asks the stand-in nothing'
          assert_equal 'not_yet', service.advance('run_id' => run.id, '_session_id' => 's1')['status'],
                       'once the lock is released the advance runs'
        end

        # --- merge item before the report material ------------------------------

        def test_after_a_stop_the_merge_item_is_in_the_report_material_and_the_first_finish_passes
          skip 'sandbox-exec unavailable' unless Confinement.available?
          init_repo!
          adopt!
          out = start_in('s1', dev_args)
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          refute_nil run.branch

          assert_equal 'stopped', service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 'enough')['status']
          material = write_deck_from_material(run)
          merge = material['items'].select { |i| i['item_kind'] == 'merge' }
          assert_equal 1, merge.size, 'the merge item is in the material the report is built from'
          assert_includes merge.first['command'], run.branch
          fin = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', fin['status'], "the first finish passes: #{fin.inspect}"
          assert_equal 1, run.reload.items.values.count { |i| i['item_kind'] == 'merge' }
        end

        def test_after_all_phases_end_the_merge_item_is_in_the_report_material_and_the_first_finish_passes
          skip 'sandbox-exec unavailable' unless Confinement.available?
          init_repo!
          adopt!
          out = start_in('s1', dev_args)
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          run.append(:plan_ratified, answer: 'approve')
          run.plan.phase_names.each { |p| run.append(:phase_ended, phase: p.to_s, by: 'check') }
          assert_nil run.reload.current_phase
          assert_equal 'running', run.status

          # Read the material first, before any advance has had the chance to open it.
          material = write_deck_from_material(run)
          assert_equal 1, material['items'].count { |i| i['item_kind'] == 'merge' }
          adv = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'all_phases_ended', adv['status'], adv.inspect
          assert_equal 1, run.reload.items.values.count { |i| i['item_kind'] == 'merge' }, 'one merge item, not two'
          fin = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', fin['status'], "the first finish passes: #{fin.inspect}"
        end
      end
    end
  end
end
