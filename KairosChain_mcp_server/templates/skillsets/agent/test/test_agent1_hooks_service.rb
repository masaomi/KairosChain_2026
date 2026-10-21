# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require_relative '../lib/agent/service'

module KairosMcp
  module SkillSets
    module Agent
      # A stand-in that answers from a script, recording what it was asked.
      class ScriptedStandIn
        attr_reader :asked

        def initialize(script)
          @script = script
          @asked = []
        end

        def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
          @asked << { point: point, question: question, operator_words: operator_words, precedents: precedents,
                      evidence: evidence }
          reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
          reply = reply.call(question) if reply.respond_to?(:call)
          StandIn::Answer.new(answer: reply['answer'], klass: reply['class'], confidence: reply['confidence'] || 0.9,
                              basis: reply['basis'] || [], reason: reply['reason'] || 'scripted', calls: 1,
                              inputs_digest: 'x' * 64)
        end

        def rule_hazard(text, **kw)
          a = ask(point: 'hazard', question: text, options: StandIn::HAZARD_RULINGS, **kw)
          return ['not_ruled', a] if a.failed?

          [a.answer.to_s, a]
        end
      end

      class TestAgent1HooksService < Minitest::Test
        POLICY_SRC = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 8, stand_in_calls: 100 }
          end
        RUBY

        def setup
          @root = File.realpath(Dir.mktmpdir('a1'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@root, 'global_bound_sessions.txt')
          @data = File.join(@root, '.kairos')
          @paths = Paths.new(@data)
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'p1.rb'), POLICY_SRC)
          FileUtils.mkdir_p(File.join(@root, 'log'))
          @policy = DSL.parse_policy(POLICY_SRC)
          @script = {}
          @stand_in = ScriptedStandIn.new(@script)
          @chain = []
          @invoked = []
          @mlr = {}
          @transcript = File.join(@root, 'transcript.jsonl')
          File.write(@transcript, '')
          Precedents.new(@paths.precedents_dir).add([{ 'source' => 'seed', 'project' => 'x', 'at' => '2026-10-01',
                                                       'kind' => 'typed_answer', 'question' => '査読は何周?',
                                                       'words' => '収束するまで回して' }])
        end

        def teardown
          FileUtils.rm_rf(@root)
        end

        # The kit's checker is faked (it needs a browser); everything else runs.
        def service
          real = Service.allocate
          run_cmd = lambda do |argv, chdir, timeout|
            if argv.any? { |a| a.to_s.end_with?('check.py') }
              [@checker_out || "issues=0\n", true]
            else
              real.send(:default_run_cmd, argv, chdir, timeout)
            end
          end
          Service.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in },
                      invoke: lambda { |name, args|
                        @invoked << [name, args]
                        @mlr.fetch(name) { {} }
                      },
                      chain: ->(logs) { @chain << logs; @chain.size }, run_cmd: run_cmd)
        end

        # The host's PreToolUse on an agent tool: marks the guard as seen and
        # tells the tool its session.
        def via_hook(sid, tool, args)
          out = hooks.handle('PreToolUse', 'session_id' => sid, 'tool_name' => "mcp__kairos-chain__#{tool}", 'tool_input' => args)
          out.dig('hookSpecificOutput', 'updatedInput')
        end

        # A subagent writes the report through the guarded Write tool.
        def write_deck(run, html)
          deck = File.join(@root, 'log', 'agent_runs', run.id, 'deck.html')
          out = hooks.handle('PreToolUse', 'session_id' => run.bound_session || 's1', 'tool_name' => 'Write',
                                           'agent_id' => 'a1b2c3d4e5', 'cwd' => @root,
                                           'tool_input' => { 'file_path' => deck, 'content' => html })
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
          File.write(deck, html)
          deck
        end

        def hooks
          Hooks.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in })
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
          service.items('action' => 'adopt_policy', 'policy' => 'p1')
        end

        def start_design_run
          adopt!
          typed('設計だけ進めて。席は Fable も入れて', 'pr2')
          args = via_hook('s1', 'agent_start', 'goal' => 'design the thing', 'template' => 'design_only',
                                               'design_glob' => 'log/thing_design_v*.md')
          out = service.start(args)
          assert_equal 'started', out['status'], out.inspect
          hooks.handle('PostToolUse', 'session_id' => 's1', 'tool_name' => 'mcp__kairos-chain__agent_start',
                                      'transcript_path' => @transcript,
                                      'tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }])
          Run.load(@paths, out['run_id'])
        end

        # --- policy and start ---------------------------------------------------

        def test_start_refuses_without_an_adopted_policy_and_shows_the_sentence
          args = via_hook('s1', 'agent_start', 'goal' => 'g', 'template' => 'design_only', 'design_glob' => 'log/x_v*.md')
          out = service.start(args)
          assert_equal 'refused', out['status']
          assert_includes out['policies'].first['type_to_adopt'], "adopt policy p1 #{@policy.digest[0, 8]}"
        end

        def test_start_refuses_where_the_hooks_are_not_live
          adopt!
          out = service.start('goal' => 'g', 'template' => 'design_only', 'design_glob' => 'log/x_v*.md')
          assert_equal 'refused', out['status']
          assert_includes out['reason'], 'hooks are not active'
          assert_empty Run.all(@paths), 'nothing is created for a session no guard watches'
        end

        def test_adoption_needs_the_operators_own_typed_words
          words = "adopt policy p1 #{@policy.digest[0, 8]}"
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => words, 'prompt_id' => 'zz',
                                           'transcript_path' => @transcript)
          assert_equal 'refused', service.items('action' => 'adopt_policy', 'policy' => 'p1')['status'],
                       'words not in the transcript as typed input do not adopt'
          assert_equal 'adopted', adopt!['status']
          assert_equal 1, @chain.size
          assert_equal 'p1', Policies.new(@paths).adopted.name
        end

        def test_binding_copies_the_words_typed_before_it
          run = start_design_run
          assert_equal 's1', run.bound_session
          assert_includes run.operator_words.join, 'Fable も入れて'
        end

        # --- guard and decision points ------------------------------------------

        def test_an_unbound_session_is_left_alone
          assert_nil hooks.handle('PreToolUse', 'session_id' => 'other', 'tool_name' => 'Bash',
                                                'tool_input' => { 'command' => 'git push' })
          assert File.exist?(File.join(@paths.guard_seen_dir, 'other'))
        end

        def test_a_refused_effect_becomes_an_operator_item_and_a_deny
          run = start_design_run
          out = hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'mcp__kairos-chain__knowledge_update',
                                           'tool_input' => {}, 'cwd' => @root)
          assert_equal 'deny', out.dig('hookSpecificOutput', 'permissionDecision')
          assert_match(/operator item I\d+/, out.dig('hookSpecificOutput', 'permissionDecisionReason'))
          assert_equal 1, run.reload.open_items.size
        end

        def test_ask_user_question_is_answered_by_the_stand_in
          start_design_run
          @script['question'] = { 'answer' => '8 席', 'class' => 'decided' }
          q = { 'questions' => [{ 'question' => '何席?', 'header' => '席', 'multiSelect' => false,
                                  'options' => [{ 'label' => '7 席' }, { 'label' => '8 席' }] }] }
          out = hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'AskUserQuestion', 'tool_input' => q)
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision')
          assert_equal({ '何席?' => '8 席' }, out.dig('hookSpecificOutput', 'updatedInput', 'answers'))
          assert_equal q['questions'], out.dig('hookSpecificOutput', 'updatedInput', 'questions')
          assert_includes @stand_in.asked.last[:operator_words].join, 'Fable'
        end

        def test_a_question_only_the_operator_can_answer_is_queued_not_shown
          run = start_design_run
          @script['question'] = { 'answer' => nil, 'class' => 'operator_item' }
          q = { 'questions' => [{ 'question' => '所長は休暇中?', 'options' => [{ 'label' => 'yes' }, { 'label' => 'no' }] }] }
          out = hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'AskUserQuestion', 'tool_input' => q)
          assert_equal 'deny', out.dig('hookSpecificOutput', 'permissionDecision')
          assert_equal 1, run.reload.open_items.size
        end

        def test_stop_continues_while_there_is_progress_and_rests_bound_otherwise
          run = start_design_run
          out = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Wrote the outline.')
          assert_equal 'block', out['decision']
          assert_includes out['reason'], 'Phase design'
          assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Done for now.')
          assert_equal 'running', run.reload.status
          assert_equal run.id, Run.bound_to(@paths, 's1')&.id, 'the guard stays on while the session lives'
          hooks.handle('SessionEnd', 'session_id' => 's1', 'reason' => 'exit')
          assert_equal 'interrupted', run.reload.status
          assert_nil Run.bound_to(@paths, 's1')
          refute File.exist?(File.join(@paths.bindings_dir, 's1')), 'the binding file goes with the session'
        end

        def test_a_prose_question_at_the_end_of_a_turn_goes_to_the_stand_in
          start_design_run
          @script['prose_question'] = { 'answer' => 'A でお願いします', 'class' => 'decided' }
          out = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'A と B、どちらにしますか？')
          assert_equal 'block', out['decision']
          assert_includes out['reason'], 'A でお願いします'
        end

        def test_a_fatal_hazard_in_the_world_ends_the_run
          run = start_design_run
          @script['hazard'] = { 'answer' => 'in_world', 'class' => 'decided' }
          out = hooks.handle('Stop', 'session_id' => 's1',
                                     'last_assistant_message' => 'The API key was printed to the public log and pushed.')
          assert_equal 'block', out['decision']
          assert_includes out['reason'], 'has ended'
          assert_equal 'ended', run.reload.status
          refute_nil Run.bound_to(@paths, 's1'), 'the guard stays on after an ending'
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '継続して下さい。', 'prompt_id' => 'p-sched',
                                           'transcript_path' => @transcript)
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => 'p-sched', 'isMeta' => true, 'promptSource' => 'system',
                                 'message' => { 'role' => 'user', 'content' => '継続して下さい。' }))
          end
          hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Read', 'tool_input' => { 'file_path' => @transcript })
          refute_nil Run.bound_to(@paths, 's1'), 'a scheduled prompt is not the operator speaking'
          typed('了解', 'p-ok')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => '了解', 'prompt_id' => 'p-ok',
                                           'transcript_path' => @transcript)
          hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Read', 'tool_input' => { 'file_path' => @transcript })
          assert_nil Run.bound_to(@paths, 's1'), "until the operator's next typed words (design §8)"
          assert_equal 'resumed', service.start(via_hook('s1', 'agent_start', 'resume' => run.id))['status'],
                       'the report is still built: the run is taken up again'
        end

        def test_a_defect_in_the_draft_is_a_finding_not_an_ending
          run = start_design_run
          @script['hazard'] = { 'answer' => 'in_draft', 'class' => 'decided' }
          hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'This removal path could cause data loss of 0.x storage.')
          assert_equal 'running', run.reload.status
          assert(run.open_items.any? { |i| i['item_kind'] == 'finding' })
        end

        # --- the whole design-only cycle ---------------------------------------

        def test_design_review_report_cycle
          run = start_design_run
          path = File.join(@root, 'log', 'thing_design_v0.1.md')
          out = hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Write',
                                           'tool_input' => { 'file_path' => path, 'content' => 'x' }, 'cwd' => @root)
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision')
          File.write(path, "# Design v0.1\nINV-1 ...\n")
          assert_equal 'refused', service.advance('run_id' => run.id, '_session_id' => 'intruder')['status'],
                       'only the bound session advances a run'
          assert_equal 'phase_ended', service.advance('run_id' => run.id, '_session_id' => 's1')['status']

          @mlr['multi_llm_review'] = { 'collect_token' => 'tok1' }
          assert_equal 'dispatched', service.advance('run_id' => run.id, '_session_id' => 's1')['status']
          dispatched = @invoked.find { |n, _| n == 'multi_llm_review' }.last
          assert_includes dispatched['artifact_content'], 'INV-1'
          assert_equal 0, dispatched['persona_count_declared']

          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = {
            'reviews' => [{ 'role_label' => 'codex', 'verdict' => 'APPROVE', 'raw_text' => 'Overall Verdict: APPROVE' },
                          { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'APPROVE' }],
            'vote_tally' => { 'successful_count' => 2, 'min_quorum' => 2 }, 'status' => 'ok'
          }
          @script['review_labels'] = { 'answer' => nil, 'class' => 'operator_item' }
          failed = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'labelling_failed', failed['status'], 'a failed labelling never closes a review'
          assert(run.reload.open_items.any? { |i| i['item_kind'] == 'blocking' })
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          out = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'closed_provisionally', out['status'], 'the round is labelled again, not dispatched again'
          assert_equal 1, @invoked.count { |n, _| n == 'multi_llm_review' }
          run.reload
          assert_equal %w[closure], run.open_items.map { |i| i['item_kind'] },
                       'the labelling item clears; the provisional closure waits for the operator as an item'
          assert_nil run.current_phase
          assert_equal %w[design_review], run.provisional_closures

          assert_equal 'refused', service.finish('run_id' => run.id, '_session_id' => 's1')['status'], 'no report yet'
          material = JSON.parse(File.read(service.status('run_id' => run.id, 'report_material' => true)['report_material']['material_path']))
          ids = (material['decisions'].map { |d| d['id'] } + run.reload.items.keys + run.phases.keys).join(' ')
          deck = File.join(@root, 'log', 'agent_runs', run.id, 'deck.html')
          File.write(deck, ids)
          refused = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'refused', refused['status'], 'a deck the acting context wrote is not the report'
          write_deck(run, ids)
          @checker_out = "issues=2\n"
          assert_equal 'refused', service.finish('run_id' => run.id, '_session_id' => 's1')['status'], 'the kit must pass'
          @checker_out = nil
          fin = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', fin['status'], fin.inspect
          assert_equal 'finished', run.reload.status
          refute_nil Run.bound_to(@paths, 's1'), "the guard stays until the operator's next typed words"
          typed('ありがとう', 'p-after')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => 'ありがとう', 'prompt_id' => 'p-after',
                                           'transcript_path' => @transcript)
          hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'ok')
          assert_nil Run.bound_to(@paths, 's1'), 'then the session is let go'
          refute File.exist?(File.join(@paths.bindings_dir, 's1'))
          assert_equal 'finished', service.finish('run_id' => run.id, '_session_id' => 's1')['status'], 'finish is idempotent'
          assert_equal 3, @chain.size, 'adoption, run start and run end are on the chain'
        end

        def test_operator_confirmation_needs_their_words_naming_the_item
          run = start_design_run
          @stand_in.ask(point: 'question', question: 'q')
          run.append(:decision, 'id' => 'D9', 'point' => 'question', 'question' => '何席?', 'answer' => '8')
          assert_equal 'refused', service.items('action' => 'confirm', 'run_id' => run.id, 'ref' => 'D9')['status']
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => 'D9 はそれでいい', 'prompt_id' => 'p9',
                                           'transcript_path' => @transcript)
          assert_equal 'refused', service.items('action' => 'confirm', 'run_id' => run.id, 'ref' => 'D9')['status'],
                       'words the transcript does not show as typed do not count'
          typed('D9 はそれでいい', 'p9')
          out = service.items('action' => 'confirm', 'run_id' => run.id, 'ref' => 'D9')
          assert_equal 'recorded', out['status']
          stored = Precedents.new(@paths.precedents_dir).all.last
          assert_equal 'confirmation', stored['kind']
          assert_equal 'D9 はそれでいい', stored['words']
        end

        # --- dev_cycle with a worktree and a pinned, confined test run ----------

        def git!(dir, *args)
          system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', *args, exception: true)
        end

        def test_dev_cycle_pins_at_start_and_reruns_committed_tests_confined
          skip 'sandbox-exec unavailable' unless Confinement.available?
          system('git', '-C', @root, 'init', '-q', '-b', 'main', exception: true)
          FileUtils.mkdir_p(File.join(@root, 'test'))
          File.write(File.join(@root, 'test', 'test_ok.rb'), "require 'tmpdir'; Dir.mktmpdir { |d| File.write(d + '/x', 1) }; exit 0\n")
          File.write(File.join(@root, 'test', 'helper.rb'), "# helper\n")
          File.write(File.join(@root, '.gitignore'), ".kairos/\nlog/\ntranscript.jsonl\n")
          git!(@root, 'add', '.')
          git!(@root, 'commit', '-q', '-m', 'init')
          adopt!
          args = via_hook('s1', 'agent_start', 'goal' => 'g', 'template' => 'dev_cycle', 'design_glob' => 'log/g_design_v*.md',
                                               'tests' => 'test')
          out = service.start(args)
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          assert_equal 's1', run.bound_session
          pinned = run.pinned['implement']['tests'].keys.map { |k| File.basename(k) }.sort
          assert_equal %w[helper.rb test_ok.rb], pinned, 'every file under the tests directory is pinned from the base'
          run.append(:phase_ended, phase: 'design', by: 'check')
          run.append(:phase_ended, phase: 'design_review', by: 'closure', provisional: true)
          run.append(:plan_ratified, answer: 'approve')

          pinned_file = File.join(run.worktree, 'test', 'test_ok.rb')
          original = File.read(pinned_file)
          File.write(pinned_file, "exit 0 # weakened\n")
          dirty = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'refused', dirty['status'], 'the check runs only committed work'
          assert_includes dirty['reason'], 'uncommitted'
          git!(run.worktree, 'commit', '-q', '-am', 'weaken')
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          refused = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'check_refused', refused['status'], 'a pinned test changed through any route goes to the stand-in'
          assert_equal [pinned_file], refused['changed']
          refute_nil(@stand_in.asked.find { |a| a[:point] == 'pinned_test_change' })
          File.write(pinned_file, original)
          git!(run.worktree, 'commit', '-q', '-am', 'restore')
          res = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'phase_ended', res['status'], res.inspect
          assert_equal 1, res['ran']
          check = run.reload.journal.entries.reverse.find { |e| e['kind'] == 'check' }
          assert_equal res['commit'], check['commit']
        end
      end
    end
  end
end
