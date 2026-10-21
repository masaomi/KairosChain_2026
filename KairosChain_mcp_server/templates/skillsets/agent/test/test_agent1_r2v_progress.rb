# frozen_string_literal: true

# Verification of the fixes after implementation review R2, group "progress":
# how a run progresses, rests and ends under the host's real hook order.
# Every agent tool call goes PreToolUse (the hook names the session) → the
# service → PostToolUse, other tools go PreToolUse → PostToolUse, and every
# turn ends with Stop (SubagentStop for a subagent), as Claude Code fires
# them. R2 found that the suite called the service without PostToolUse, so
# the "waiting on operator items" ending was unreachable in the real order.
#
# Real git repositories and confined checks (sandbox-exec) under a tmpdir;
# the stand-in and the review tools are scripted. One scenario runs every
# hook event through hooks/agent_hook.rb as a subprocess, with HOME,
# KAIROS_DATA_DIR and CLAUDE_PROJECT_DIR in the tmpdir.
require 'rbconfig'
require_relative 'test_agent1_r1_check'

# The harness's own tests run in their own file.
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1R1Check)

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R2Progress < TestAgent1R1Check
        TestAgent1R1Check.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }

        SID = 's1'
        BUILDER = 'a7f3c2e9d1' # the report builder's agent id
        HOOK_SCRIPT = File.expand_path('../hooks/agent_hook.rb', __dir__)
        BOUND_PRECEDENT = 'Pbound0000001' # keeps the precedent store non-empty (no setup item)
        P0_TEXT = 'the cache has no bound, so memory grows without limit'
        AGENT_METHODS = { 'agent_start' => :start, 'agent_status' => :status, 'agent_advance' => :advance,
                          'agent_items' => :items, 'agent_finish' => :finish, 'agent_stop' => :stop }.freeze

        # Answers from a script keyed by decision point (default: the first
        # option, decided on the instruction mode); a reply may cite its own
        # basis. Records what each point was asked and which precedent it saw.
        class ProgressStandIn
          attr_reader :asked

          def initialize(script)
            @script = script
            @asked = []
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
            @asked << { point: point, question: question, evidence: evidence, options: options,
                        precedents: precedents.map { |p| p['id'] }, operator_words: operator_words }
            reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
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
          @project_dir_saved = [ENV.fetch('CLAUDE_PROJECT_DIR', nil)]
          ENV['CLAUDE_PROJECT_DIR'] = @root
          @home = File.join(@tmp, 'home')
          FileUtils.mkdir_p(@home)
          @stand_in = ProgressStandIn.new(@script)
          @tu = 0
          @stop_active = false
          # The operator's own ruling on a review that reaches its bound open.
          # (No stand-in point asks it any more: the review waits on its own.)
          Precedents.new(@paths.precedents_dir).add(
            [{ 'id' => BOUND_PRECEDENT, 'source' => 'seed', 'project' => 'proj', 'at' => '2026-10-02', 'kind' => 'ruling',
               'question' => 'review at its round cap with open P0: freeze provisionally or wait? (MLR 凍結)',
               'words' => '上限で収束しなければ凍結しないで待って。開いた P0 は私が決める' }]
          )
        end

        def teardown
          super
        ensure
          if @project_dir_saved
            v = @project_dir_saved.first
            v.nil? ? ENV.delete('CLAUDE_PROJECT_DIR') : ENV['CLAUDE_PROJECT_DIR'] = v
          end
        end

        # --- the host -------------------------------------------------------------

        # One hook event: in-process, or through hooks/agent_hook.rb as the
        # host runs it (input on stdin, environment in the tmpdir).
        def event(name, input)
          return hooks.handle(name, input) unless @use_script

          env = { 'HOME' => @home, 'KAIROS_DATA_DIR' => @paths.data_dir, 'CLAUDE_PROJECT_DIR' => @root,
                  'KAIROS_AGENT_GLOBAL' => ENV.fetch('KAIROS_AGENT_GLOBAL'), 'KAIROS_MCP_LIB' => nil }
          out, err, st = Open3.capture3(env, RbConfig.ruby, HOOK_SCRIPT,
                                        stdin_data: JSON.generate(input.merge('hook_event_name' => name)), chdir: @root)
          assert_equal 0, st.exitstatus, "#{name} hook failed: #{err}"
          out.strip.empty? ? nil : JSON.parse(out)
        end

        def pre_tool(tool, input, agent_id: nil)
          @last_tu = "toolu_r2p_#{@tu += 1}"
          ev = { 'session_id' => SID, 'transcript_path' => @transcript, 'cwd' => @root, 'tool_name' => tool,
                 'tool_input' => input, 'tool_use_id' => @last_tu }
          ev['agent_id'] = agent_id if agent_id
          event('PreToolUse', ev)
        end

        def post_tool(tool, input, response, agent_id: nil)
          ev = { 'session_id' => SID, 'transcript_path' => @transcript, 'cwd' => @root, 'tool_name' => tool,
                 'tool_input' => input, 'tool_response' => response, 'tool_use_id' => @last_tu }
          ev['agent_id'] = agent_id if agent_id
          event('PostToolUse', ev)
        end

        def journal_sizes
          Run.all(@paths).to_h { |r| [r.id, r.journal.entries.size] }
        end

        # An agent tool as the host calls it: PreToolUse gives it the session,
        # the tool runs, PostToolUse sees its reply. Only agent_start's
        # PostToolUse acts (it attaches the transcript); the others journal
        # nothing (R2: their outcomes counted as progress).
        def host_tool(tool, args, agent_id = nil)
          name = "mcp__kairos-chain__#{tool}"
          pre = pre_tool(name, args, agent_id: agent_id)
          input = pre&.dig('hookSpecificOutput', 'updatedInput')
          refute_nil input, "PreToolUse gives #{tool} its session: #{pre.inspect}"
          assert_equal SID, input['_session_id']
          out = service.public_send(AGENT_METHODS.fetch(tool), input)
          before = journal_sizes
          post = post_tool(name, input, [{ 'type' => 'text', 'text' => JSON.generate(out) }], agent_id: agent_id)
          unless tool == 'agent_start'
            assert_nil post, "PostToolUse of #{tool} answers nothing"
            assert_equal before, journal_sizes, "PostToolUse of #{tool} journals nothing"
          end
          out
        end

        def host_advance(run)
          host_tool('agent_advance', 'run_id' => run.id)
        end

        def host_start(args)
          adopt! unless Policies.new(@paths).adopted
          out = host_tool('agent_start', args)
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          assert_equal SID, run.bound_session
          assert_equal @transcript, run.transcript_path, 'PostToolUse of agent_start attached the transcript'
          run
        end

        def impl_run(tests: 'test')
          host_start('goal' => 'make x work', 'template' => 'impl_cycle', 'tests' => tests)
        end

        # A design-only run through its first dispatch.
        def host_design_run
          run = host_start('goal' => 'design x', 'template' => 'design_only', 'design_glob' => 'log/x_design_v*.md')
          host_write(File.join(@root, 'log', 'x_design_v0.1.md'), "# x v0.1\nINV-1 the cache is bounded\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          run.reload
        end

        def host_write(path, content, agent_id: nil)
          input = { 'file_path' => path, 'content' => content }
          v = pre_tool('Write', input, agent_id: agent_id)
          assert_equal 'allow', v&.dig('hookSpecificOutput', 'permissionDecision'), v.inspect
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          post_tool('Write', input, { 'type' => 'create', 'filePath' => path }, agent_id: agent_id)
        end

        # A session-local tool: the guard allows it without an effect, and
        # PostToolUse journals its outcome — which is not progress.
        def todo_write
          input = { 'todos' => [{ 'content' => 'wait for the operator', 'status' => 'in_progress',
                                  'activeForm' => 'Waiting for the operator' }] }
          v = pre_tool('TodoWrite', input)
          assert_equal 'allow', v&.dig('hookSpecificOutput', 'permissionDecision'), v.inspect
          post_tool('TodoWrite', input, { 'oldTodos' => [], 'newTodos' => input['todos'] })
        end

        def host_stop(msg, subagent: false, agent_id: nil)
          ev = { 'session_id' => SID, 'transcript_path' => @transcript, 'cwd' => @root,
                 'last_assistant_message' => msg, 'stop_hook_active' => @stop_active }
          ev['agent_id'] = agent_id if agent_id
          out = event(subagent ? 'SubagentStop' : 'Stop', ev)
          @stop_active = out&.dig('decision') == 'block' unless subagent
          out
        end

        def operator_types(text, prompt_id)
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => prompt_id, 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => text }))
          end
          event('UserPromptSubmit', 'session_id' => SID, 'prompt' => text, 'prompt_id' => prompt_id,
                                    'transcript_path' => @transcript, 'cwd' => @root)
        end

        # --- the review tool -----------------------------------------------------

        def round_returns(*seats, p0: [])
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = {
            'status' => 'ok',
            'reviews' => seats.map { |seat, verdict, text| { 'role_label' => seat, 'verdict' => verdict, 'raw_text' => text } },
            'aggregated_findings' => p0.map { |t| { 'severity' => 'P0', 'issue' => t } },
            'vote_tally' => { 'successful_count' => seats.size, 'min_quorum' => 2 }
          }
        end

        # Round 1 raises a P0 the stand-in labels open; at the round cap the
        # review waits for the operator on its own.
        def round_with_open_p0_at_the_round_cap
          round_returns(['codex', 'REVISE', "P0: #{P0_TEXT}"], ['sonnet', 'APPROVE', 'ok'], p0: [P0_TEXT])
          @script['review_labels'] = { 'answer' => [{ 'seat' => 'codex', 'text' => P0_TEXT, 'label' => 'new' }],
                                       'class' => 'decided' }
        end

        def assert_waited_on_the_operator(out, phase)
          assert_equal 'waiting', out['status'], out.inspect
          assert_empty asks('round_bound'), 'the stand-in is not asked about the bound'
          item = Run.load(@paths, Run.all(@paths).last.id).items[out['item']]
          assert_equal ['review_open', phase], [item['item_kind'], item.dig('state_ref', 'ref')]
        end

        # --- a run waiting on a review_open item ends -------------------------------

        # R2 trigger (lifecycle tester P0, sonnet/codex/fable): impl_cycle,
        # a policy of one review round, round 1 has an open P0 and the review
        # waits on its review_open item. Then, as the host does,
        # PreToolUse agent_advance → service.advance → PostToolUse → Stop, up
        # to 12 times: every Stop blocked and the run never ended.
        def test_a_run_waiting_on_a_review_open_item_ends_under_the_real_hook_order
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          review_rounds!(1) # the first round, with an open P0, reaches the round cap
          run = impl_run
          put(run.worktree, 'lib/x.rb', "X_VALUE = 1 # v2\n")
          commit_all!(run, 'v2')
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'block', host_stop('Implemented and committed; the check passed.')&.dig('decision')
          assert_equal 'dispatched', host_advance(run)['status']
          assert_includes host_stop('Dispatched the implementation review.')['reason'], 'review round is running'

          round_with_open_p0_at_the_round_cap
          assert_waited_on_the_operator(host_advance(run), 'implementation_review')

          stops = [host_stop('Round 1 is labelled; one P0 is open at the bound.')]
          11.times do
            break if run.reload.status == 'ended'

            host_tool('agent_status', 'run_id' => run.id)
            host_tool('agent_items', 'action' => 'list', 'run_id' => run.id)
            todo_write
            assert_equal 'waiting', host_advance(run)['status']
            stops << host_stop('Still waiting on the operator.')
          end
          run.reload
          assert_equal 'ended', run.status, "Stops: #{stops.map { |s| s&.dig('reason').to_s[0, 50] }.inspect}"
          assert_equal 'waiting on operator items', run.end_reason
          assert_equal 2, stops.size, 'the labelled round is progress once; the first poll that changes nothing ends the run'
          assert_includes stops[0]['reason'], 'continues'
          assert_includes stops[1]['reason'], 'can only wait on operator items'
          assert_empty asks('round_bound'), 'nothing is asked at the bound, on any poll'
          assert_equal 1, asks('review_labels').size, 'the round is labelled once, not on every poll'
          assert(run.open_items.any? { |i| i['item_kind'] == 'merge' }, 'the branch waits for the merge')
          assert(run.journal.entries.any? { |e| e['kind'] == 'effect_outcome' && e['tool'] == 'TodoWrite' },
                 "a session-local tool's outcome is journaled, and is not progress")
          assert_empty(run.journal.entries.select { |e| e['kind'] == 'effect_outcome' && e['tool'].to_s.include?('agent_') },
                       "agent tools' PostToolUse journals nothing")
          assert_equal run.id, Run.bound_to(@paths, SID)&.id, 'the guard stays until the operator speaks'
          assert_nil host_stop('I will build the report next.'), 'the ending is told once'
        end

        def test_the_waiting_ending_through_the_hook_script_as_the_host_runs_it
          @use_script = true
          review_rounds!(1) # the first round, with an open P0, reaches the round cap
          run = host_design_run
          assert_includes host_stop('Dispatched round 1.')['reason'], 'review round is running'
          round_with_open_p0_at_the_round_cap
          assert_waited_on_the_operator(host_advance(run), 'design_review')
          assert_includes host_stop('Round 1 is labelled.')['reason'], 'continues'

          todo_write
          host_tool('agent_status', 'run_id' => run.id)
          assert_equal 'waiting', host_advance(run)['status']
          ended = host_stop('Waiting on the operator.')
          assert_equal 'block', ended&.dig('decision')
          assert_includes ended['reason'], 'can only wait on operator items'
          run.reload
          assert_equal %w[ended], [run.status]
          assert_equal 'waiting on operator items', run.end_reason
          assert_equal run.id, Run.bound_to(@paths, SID)&.id
          assert_nil host_stop('Building the report next.')
        end

        # --- a round in flight ----------------------------------------------------------

        # R2 (fable P0): the once-per-progress rule for a round in flight was
        # defeated by the polls' own PostToolUse outcomes.
        def test_a_stop_while_a_round_is_in_flight_blocks_once_then_rests_without_progress
          run = host_design_run
          first = host_stop('Dispatched round 1.')
          assert_equal 'block', first&.dig('decision')
          assert_includes first['reason'], 'review round is running'

          @mlr['multi_llm_review_wait'] = { 'status' => 'still_pending' }
          3.times do |i|
            assert_equal 'pending', host_advance(run)['status']
            host_tool('agent_status', 'run_id' => run.id)
            todo_write
            assert_nil host_stop("The round is still running (#{i + 1})."), 'polling a round that has not returned is not progress'
          end
          run.reload
          assert_equal 'running', run.status
          refute_nil run.in_flight_review
          assert_equal run.id, Run.bound_to(@paths, SID)&.id, 'the session stays bound; the run rests'
          assert_equal 1, entries(run, 'stop_blocked').count { |e| e['for'] == 'review_in_flight' }
          assert_equal 3, entries(run, 'idle').size

          round_returns(%w[codex APPROVE ok], %w[sonnet APPROVE ok])
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          assert_equal 'closed_provisionally', host_advance(run)['status']
          back = host_stop('Round 1 collected.')
          assert_equal 'block', back&.dig('decision'), 'the round coming back is progress'
          assert_includes back['reason'], 'Build the report'
        end

        # --- after all phases end -----------------------------------------------------

        # R2 (lifecycle tester P1): the report builder's SubagentStop still ran
        # the question and hazard checks after every phase had ended; each new
        # D# made finish refuse a deck built before it.
        def test_after_all_phases_end_a_question_or_a_credential_in_the_last_words_records_no_decision
          run = host_design_run
          round_returns(['codex', 'APPROVE', 'Overall Verdict: APPROVE'], %w[sonnet APPROVE APPROVE])
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          assert_equal 'closed_provisionally', host_advance(run)['status']
          run.reload
          assert_nil run.current_phase
          assert_equal 'running', run.status
          assert_includes host_stop('Review closed provisionally.')['reason'], 'Build the report'

          # The report builder, a subagent of the run.
          out = host_tool('agent_status', { 'run_id' => run.id, 'report_material' => true }, BUILDER)
          material = JSON.parse(File.read(out['report_material']['material_path']))
          ids = material['decisions'].map { |d| d['id'] } + material['items'].map { |i| i['id'] } +
                material['phases'].map { |p| p['name'] }
          deck = File.join(@root, 'log', 'agent_runs', run.id, 'deck.html')
          host_write(deck, "<html><body>#{ids.join(' ')}</body></html>", agent_id: BUILDER)
          decisions = run.reload.decisions.size
          items = run.items.size
          asked = @stand_in.asked.size

          assert_nil host_stop('デッキを書きました。表紙の文言を直しますか？', subagent: true, agent_id: BUILDER)
          assert_nil host_stop('check.py: issues=0. Credential leak check: no API key, password or private key ' \
                               'appears in the deck.', subagent: true, agent_id: BUILDER)
          [host_stop('レポートができました。ブランチをマージしますか？'),
           host_stop('The credential and secret scan of the deck found no leak.')].each do |s|
            refute_match(/Stand-in answer|hazard/i, s&.dig('reason').to_s)
          end
          run.reload
          assert_equal decisions, run.decisions.size, "no decision after the phases ended: #{run.decisions.last.inspect}"
          assert_equal items, run.items.size, 'no item either'
          assert_equal asked, @stand_in.asked.size, 'the stand-in is not asked'
          assert_nil run.hazard
          assert_equal 'running', run.status

          fin = host_tool('agent_finish', 'run_id' => run.id)
          assert_equal 'finished', fin['status'], "the deck built before still covers the journal: #{fin.inspect}"
        end

        # --- a pinned test the stand-in hands to the operator ----------------------------

        # R2 (lifecycle tester P1, fable P1): the check opened no item, every
        # advance re-asked the stand-in, and Stop recorded idle instead of a
        # waiting ending.
        def test_a_pinned_test_change_handed_to_the_operator_opens_one_blocking_item_and_his_acceptance_passes_it
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          run = impl_run
          changed = put(run.worktree, 'test/test_x.rb', "require 'x'\nexit(X_VALUE >= 1 ? 0 : 1) # loosened\n")
          commit_all!(run, 'loosen the check')
          @script['pinned_test_change'] = { 'answer' => nil, 'class' => 'operator_item' }

          first = host_advance(run)
          assert_equal 'check_refused', first['status'], first.inspect
          assert_equal [changed], first['changed']
          refute_nil first['item'], 'the refusal names its item'
          assert_equal 'block', host_stop('The pinned test change went to the stand-in.')&.dig('decision')
          second = host_advance(run)
          assert_equal 'check_refused', second['status'], second.inspect
          assert_equal first['item'], second['item'], 'the same item, not one per advance'
          blocking = run.reload.open_items.select { |i| i['item_kind'] == 'blocking' }
          assert_equal 1, blocking.size, blocking.inspect
          item = blocking.first
          assert_equal first['item'], item['id']
          assert_equal 'implement', item.dig('state_ref', 'ref'), 'it blocks the check phase'
          assert_equal [changed], item.dig('detail', 'paths')
          assert_empty checks_ran, 'nothing ran before the ruling'

          ended = host_stop('Nothing more to do without the operator.')
          assert_includes ended&.dig('reason').to_s, 'can only wait on operator items', 'an ending, not idle'
          run.reload
          assert_equal ['ended', 'waiting on operator items'], [run.status, run.end_reason]
          assert_empty entries(run, 'idle')

          ref = item['id']
          operator_types("#{ref} は認める。テストをそう緩めたのは私の意図どおり", 'p-accept')
          plain = host_tool('agent_items', 'action' => 'resolve', 'run_id' => run.id, 'ref' => ref)
          assert plain['item_open'], "a resolve without the decision leaves it open: #{plain.inspect}"
          out = host_tool('agent_items', 'action' => 'resolve', 'run_id' => run.id, 'ref' => ref,
                                         'decision' => 'accept_test_change')
          assert_equal 'recorded', out['status'], out.inspect
          assert_equal 'running', out['run_status'], 'the run waited only on this item; it continues'
          assert_equal SID, run.reload.bound_session
          n = asks('pinned_test_change').size
          res = host_advance(run)
          assert_equal 'phase_ended', res['status'], res.inspect
          assert_equal 1, res['ran']
          assert_equal n, asks('pinned_test_change').size, 'the operator ruled; the stand-in is not asked again'
          accepted = entries(run, 'pinned_change').last
          assert_equal ['operator', ref], [accepted['by'], accepted['item']]
          assert_equal 'block', host_stop('The check passed.')&.dig('decision'), 'the run goes on'
        end

        def test_an_acceptance_in_words_that_do_not_say_so_leaves_the_pinned_test_item_open
          repo!('test/test_ok.rb' => "x = 1\nexit(x == 1 ? 0 : 1)\n")
          run = impl_run
          put(run.worktree, 'test/test_ok.rb', "x = 2\nexit(x >= 1 ? 0 : 1)\n")
          commit_all!(run, 'loosen')
          @script['pinned_test_change'] = { 'answer' => nil, 'class' => 'operator_item' }
          ref = host_advance(run)['item']
          refute_nil ref
          operator_types("#{ref} はあとで見ます", 'p-later')
          out = host_tool('agent_items', 'action' => 'resolve', 'run_id' => run.id, 'ref' => ref,
                                         'decision' => 'accept_test_change')
          assert out['item_open'], out.inspect
          assert_equal 'open', run.reload.items[ref]['state']
          assert_equal 'check_refused', host_advance(run)['status']
          assert_empty checks_ran
        end

        # --- refusals that only the operator can clear ------------------------------------

        # R2 (lifecycle tester P2): "no test files", "no runner" and a missing
        # tests path opened no item, and the run idled without one.
        def test_no_test_files_opens_one_blocking_item_and_the_run_can_end_waiting
          repo!('test/helper.rb' => "# helper\n", 'test/fixtures/a.txt' => "a\n", 'lib/x.rb' => "X = 1\n")
          run = impl_run
          first = host_advance(run)
          assert_equal 'refused', first['status'], first.inspect
          assert_includes first['reason'], 'no test files'
          refute_nil first['item']
          assert_equal 'block', host_stop('The check refused.')&.dig('decision')
          second = host_advance(run)
          assert_equal first['item'], second['item']
          items = run.reload.open_items.select { |i| i['item_kind'] == 'blocking' }
          assert_equal 1, items.size
          assert_equal 'implement', items.first.dig('state_ref', 'ref')
          assert_includes items.first['text'], 'no test files'
          ended = host_stop('Nothing more to do.')
          assert_includes ended&.dig('reason').to_s, 'can only wait on operator items'
          assert_equal 'waiting on operator items', run.reload.end_reason
          assert_empty checks_ran
        end

        def test_a_missing_tests_path_opens_a_blocking_item
          repo!('test/test_ok.rb' => "exit 0\n")
          run = impl_run(tests: 'spec')
          out = host_advance(run)
          assert_equal 'refused', out['status'], out.inspect
          item = run.reload.items[out['item'].to_s]
          refute_nil item, out.inspect
          assert_equal %w[blocking implement open], [item['item_kind'], item.dig('state_ref', 'ref'), item['state']]
          assert_includes item['text'], 'spec'
        end

        def test_no_runner_opens_a_blocking_item
          repo!('test/test_a.rb' => "exit 0\n", 'test/widget.test.js' => "process.exit(1)\n")
          run = impl_run
          out = host_advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'widget.test.js'
          item = run.reload.items[out['item'].to_s]
          refute_nil item, out.inspect
          assert_equal %w[blocking implement open], [item['item_kind'], item.dig('state_ref', 'ref'), item['state']]
          assert_includes item['text'], 'widget.test.js'
          assert_includes item['text'], 'test_command'
          host_advance(run)
          assert_equal 1, run.reload.open_items.count { |i| i['item_kind'] == 'blocking' }, 'one item across advances'
          assert_empty checks_ran, 'not even the ruby test runs'
        end

        # --- an ending after the operator's words reopened the run ---------------------

        # Design §8: after any ending the guard stays until the operator's
        # NEXT typed words. Words that reopened a waiting run came before its
        # next ending; they do not release that ending's guard.
        def test_a_second_ending_keeps_the_guard_until_the_operator_speaks_again
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "require 'x'\nexit(X_VALUE == 1 ? 0 : 1)\n")
          run = impl_run
          put(run.worktree, 'test/test_x.rb', "require 'x'\nexit(X_VALUE >= 1 ? 0 : 1)\n")
          commit_all!(run, 'loosen')
          @script['pinned_test_change'] = { 'answer' => nil, 'class' => 'operator_item' }
          ref = host_advance(run)['item']
          host_stop('Refused.')
          host_advance(run)
          assert_includes host_stop('Waiting.')&.dig('reason').to_s, 'can only wait on operator items'
          operator_types("#{ref} は認める", 'p-accept2')
          out = host_tool('agent_items', 'action' => 'resolve', 'run_id' => run.id, 'ref' => ref,
                                         'decision' => 'accept_test_change')
          assert_equal 'running', out['run_status'], out.inspect
          assert_equal 'phase_ended', host_advance(run)['status']

          stopped = host_tool('agent_stop', 'run_id' => run.id, 'reason' => 'enough for today')
          assert_equal 'stopped', stopped['status'], stopped.inspect
          host_stop('Stopped; the report comes next.')
          if Run.bound_to(@paths, SID).nil?
            # Observed: the journal shows release_pending(p-accept2) → run_reopened
            # → resumed → … → run_ended(stopped) → unbound("the operator spoke
            # after the ending"); the next Write to CLAUDE.md gets no hook output.
            flunk('BUG: hooks.rb:257 release_if_typed reuses a release_pending from before run_reopened, so the ' \
                 'first Stop after the next ending unbinds the session without the operator\'s new words')
          end
          assert_equal run.id, Run.bound_to(@paths, SID)&.id,
                       "the operator has not spoken since this ending; his words before the reopening do not release it"
          v = pre_tool('Write', { 'file_path' => File.join(@root, 'CLAUDE.md'), 'content' => 'x' })
          assert_equal 'deny', v&.dig('hookSpecificOutput', 'permissionDecision'), 'the guard still refuses governing writes'
        end
      end
    end
  end
end
