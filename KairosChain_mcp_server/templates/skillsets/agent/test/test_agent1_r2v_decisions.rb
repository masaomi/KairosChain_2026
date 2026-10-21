# frozen_string_literal: true

# Verification of the R2 fixes, group "decisions": the operator's decisions
# on a run's items (Service#operator_act, decisions_for, reopen_if_unblocked,
# freeze_by_operator, restore_test_command, typed_words_naming) and the
# release of an ended run's guard by the operator's next typed words. Every
# agent tool is called as the host calls it — PreToolUse (which tells the
# tool its session), the tool, PostToolUse with its reply — and turns end
# through the Stop hook, because R2 found defects only that order shows. The
# triggers are the R2 findings'. Real git and sandbox-exec under a temporary
# directory; HOME, KAIROS_DATA_DIR and CLAUDE_PROJECT_DIR point into it; the
# stand-in and the review tools are scripted.
require_relative 'test_agent1_r1_check'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R2Decisions < TestAgent1R1Check
        # Only this file's tests run here; the harness's own run in theirs.
        TestAgent1R1Check.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }
        Minitest::Runnable.runnables.delete(TestAgent1R1Check)

        SMALL_POLICY = <<~RUBY
          policy "p_small" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 1, stand_in_calls: 100 }
          end
        RUBY
        HOST_ENV = %w[HOME KAIROS_DATA_DIR CLAUDE_PROJECT_DIR].freeze
        P0 = 'the cache has no bound'
        SUBAGENT = 'a1b2c3d4e5'
        TOOLS = { 'agent_start' => :start, 'agent_advance' => :advance, 'agent_items' => :items,
                  'agent_status' => :status, 'agent_finish' => :finish, 'agent_stop' => :stop }.freeze

        def setup
          super
          @saved_host_env = HOST_ENV.to_h { |k| [k, ENV.fetch(k, nil)] }
          home = File.join(@tmp, 'home')
          FileUtils.mkdir_p(home)
          ENV['HOME'] = home
          ENV['KAIROS_DATA_DIR'] = @paths.data_dir
          ENV['CLAUDE_PROJECT_DIR'] = @root
          File.write(File.join(@paths.policies_dir, 'p_small.rb'), SMALL_POLICY)
          @sid = 's1'
        end

        def teardown
          super
          @saved_host_env&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
        end

        # --- the host's order ------------------------------------------------------

        # The operator types a prompt: the host records it as typed, and
        # UserPromptSubmit fires.
        def type!(text, pid, sid: @sid)
          entry = { 'type' => 'user', 'promptId' => pid, 'origin' => { 'kind' => 'human' }, 'promptSource' => 'typed',
                    'message' => { 'role' => 'user', 'content' => text } }
          File.open(@transcript, 'a') { |f| f.puts(JSON.generate(entry)) }
          hooks.handle('UserPromptSubmit', 'session_id' => sid, 'prompt' => text, 'prompt_id' => pid,
                                           'transcript_path' => @transcript)
        end

        # A prompt the host schedules (ScheduleWakeup): UserPromptSubmit fires
        # with it, and the transcript records it as not typed.
        def scheduled!(text, pid, fields)
          hooks.handle('UserPromptSubmit', 'session_id' => @sid, 'prompt' => text, 'prompt_id' => pid,
                                           'transcript_path' => @transcript)
          entry = { 'type' => 'user', 'promptId' => pid, 'message' => { 'role' => 'user', 'content' => text } }.merge(fields)
          File.open(@transcript, 'a') { |f| f.puts(JSON.generate(entry)) }
        end

        # One agent tool call: PreToolUse, the tool with the input the hook
        # returned, PostToolUse with the tool's reply.
        def host(tool, args = nil, sid: @sid, agent_id: nil, **fields)
          args ||= fields
          pre = { 'session_id' => sid, 'tool_name' => "mcp__kairos-chain__#{tool}", 'tool_input' => args, 'cwd' => @root }
          pre['agent_id'] = agent_id if agent_id
          input = hooks.handle('PreToolUse', pre).dig('hookSpecificOutput', 'updatedInput')
          out = service.public_send(TOOLS.fetch(tool), input)
          hooks.handle('PostToolUse', pre.merge('tool_input' => input, 'transcript_path' => @transcript,
                                                'tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }]))
          out
        end

        # Any other tool call: the guard's PreToolUse verdict (nil = no output).
        def tool!(name, input = nil, agent_id: nil, sid: @sid, **fields)
          input ||= fields
          h = { 'session_id' => sid, 'tool_name' => name, 'tool_input' => input, 'cwd' => @root }
          h['agent_id'] = agent_id if agent_id
          hooks.handle('PreToolUse', h)
        end

        def stop!(msg = 'This turn is done.', sid: @sid)
          hooks.handle('Stop', 'session_id' => sid, 'last_assistant_message' => msg, 'transcript_path' => @transcript)
        end

        def adv(run, sid: @sid)
          host('agent_advance', { 'run_id' => run.id }, sid: sid)
        end

        def resolve(run, ref, decision = nil, sid: @sid, **extra)
          args = { 'action' => 'resolve', 'run_id' => run.id, 'ref' => ref }
          args['decision'] = decision if decision
          host('agent_items', args.merge(extra.transform_keys(&:to_s)), sid: sid)
        end

        def bound_id(sid = @sid)
          Run.bound_to(@paths, sid)&.id
        end

        def binding_file(sid = @sid)
          File.join(@paths.bindings_dir, sid)
        end

        def allowed?(verdict)
          verdict&.dig('hookSpecificOutput', 'permissionDecision') == 'allow'
        end

        # --- runs --------------------------------------------------------------------

        # A review has no round bound of its own: the policy's review spend is
        # what stops it. One round is p_small; n rounds is a policy of the same
        # shape with review_rounds: n.
        def rounds_policy(n)
          return ['p_small', SMALL_POLICY] if n == 1

          name = "p_rounds#{n}"
          [name, SMALL_POLICY.sub('p_small', name).sub('review_rounds: 1', "review_rounds: #{n}")]
        end

        def adopt_rounds!(n)
          name, src = rounds_policy(n)
          File.write(File.join(@paths.policies_dir, "#{name}.rb"), src)
          words = "adopt policy #{name} #{DSL.parse_policy(src).digest[0, 8]} でお願いします"
          type!(words, "p-adopt-#{name}")
          assert_equal 'adopted', service.items('action' => 'adopt_policy', 'policy' => name)['status']
        end

        def adopt_small!
          adopt_rounds!(1)
        end

        def start_design(rounds: 1, stem: 'x')
          adopt_rounds!(rounds) unless Policies.new(@paths).adopted&.name == rounds_policy(rounds).first
          out = host('agent_start', 'goal' => "design #{stem}", 'template' => 'design_only',
                                    'design_glob' => "log/#{stem}_design_v*.md")
          assert_equal 'started', out['status'], out.inspect
          Run.load(@paths, out['run_id'])
        end

        # Each design version is a new file the run writes through the guard.
        def write_design(version, stem: 'x')
          path = File.join(@root, 'log', "#{stem}_design_v#{version}.md")
          out = tool!('Write', 'file_path' => path, 'content' => 'x')
          assert allowed?(out), out.inspect
          File.write(path, "# #{stem} design v#{version}\nINV-1: the cache is bounded (#{version})\n")
          path
        end

        def collect_round(p0_lines: [], verdicts: %w[APPROVE APPROVE])
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = {
            'status' => 'ok',
            'reviews' => [{ 'role_label' => 'codex', 'verdict' => verdicts[0],
                            'raw_text' => (p0_lines.map { |t| "P0: #{t}" } + ["Overall Verdict: #{verdicts[0]}"]).join("\n") },
                          { 'role_label' => 'sonnet', 'verdict' => verdicts[1], 'raw_text' => "Overall Verdict: #{verdicts[1]}" }],
            'aggregated_findings' => p0_lines.map { |t| { 'severity' => 'P0', 'issue' => t } },
            'vote_tally' => { 'successful_count' => 2, 'min_quorum' => 2 }
          }
        end

        def new_labels(*texts)
          { 'answer' => texts.map { |t| { 'seat' => 'codex', 'text' => t, 'label' => 'new' } }, 'class' => 'decided' }
        end

        # A design review that has had the policy's one round for each review,
        # with one open P0: a review_open item, run running. Nothing is asked of
        # the stand-in at the cap.
        def design_at_bound(stem: 'x')
          run = start_design(stem: stem)
          write_design('0.1', stem: stem)
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          collect_round(p0_lines: [P0], verdicts: %w[REVISE APPROVE])
          @script['review_labels'] = new_labels(P0)
          out = adv(run)
          assert_equal 'waiting', out['status'], out.inspect
          item = run.reload.items[out['item']]
          assert_equal 'review_open', item['item_kind']
          assert_nil asks('round_bound').first, 'round_bound is not a decision point any more'
          [run, item]
        end

        # A design review closed provisionally at round 1: a closure item, every
        # phase ended, the run still running.
        def closed_run
          run = start_design
          write_design('0.1')
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          collect_round
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          out = adv(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          item = run.reload.items[out['item']]
          assert_equal 'closure', item['item_kind']
          [run, item]
        end

        # Turns end as the host ends them (the Stop hook, the actor's next
        # advance) until the run ends as waiting on the operator.
        def end_waiting!(run)
          4.times do
            stop!
            break if run.reload.status == 'ended'

            adv(run)
          end
          assert_equal 'ended', run.reload.status, run.journal.entries.last(4).map { |e| e['kind'] }.inspect
          assert_equal 'waiting on operator items', run.end_reason
        end

        # A subagent builds the deck from the report material through the
        # guarded Write tool. Returns the deck path, the guard's verdict and
        # the html (the host writes it whatever the verdict, as it does
        # when the hook gives no output).
        def subagent_writes_deck(run)
          st = host('agent_status', { 'run_id' => run.id, 'report_material' => true }, agent_id: SUBAGENT)
          material = JSON.parse(File.read(st['report_material']['material_path']))
          html = (material['decisions'].map { |d| d['id'] } + material['items'].map { |i| i['id'] } +
                  material['phases'].map { |p| p['name'] }).join(' ')
          deck = File.join(@root, 'log', 'agent_runs', run.id, 'deck.html')
          verdict = tool!('Write', { 'file_path' => deck, 'content' => html }, agent_id: SUBAGENT)
          File.write(deck, html) if verdict.nil? || allowed?(verdict)
          hooks.handle('SubagentStop', 'session_id' => @sid, 'agent_id' => SUBAGENT,
                                       'last_assistant_message' => 'The deck is built; check.py reports issues=0.')
          [deck, verdict]
        end

        def finish!(run)
          deck, verdict = subagent_writes_deck(run)
          assert allowed?(verdict), "the subagent's Write is guarded and journaled: #{verdict.inspect}"
          fin = host('agent_finish', 'run_id' => run.id)
          assert_equal 'finished', fin['status'], fin.inspect
          stop!('The report is built.')
          deck
        end

        # The operator's words after an ending, then any other tool call: the
        # guard lets the session go.
        def release!(text, pid)
          type!(text, pid)
          tool!('Read', 'file_path' => @transcript)
          assert_nil bound_id, "the operator's next typed words release the ended run"
        end

        def carried_texts(run)
          run.reload.open_items.select { |i| i['item_kind'] == 'carried_p0' }.map { |i| i.dig('detail', 'text') }
        end

        # --- restore_test_command -------------------------------------------------

        # R2 lifecycle P0: test_command "ruby", tests "test"; the stand-in
        # answers tests:spec, reject_test_command; the operator restores the
        # command. (A rounds token in the answer rules on nothing.)
        def test_restore_test_command_keeps_the_ratified_tests_directory_and_pin
          repo!('test/test_ok.rb' => "exit 0\n", 'spec/test_b.rb' => "exit 0\n")
          adopt!
          out = host('agent_start', 'goal' => 'make x work', 'template' => 'impl_cycle', 'tests' => 'test',
                                    'test_command' => 'ruby')
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          @script['plan_parameters'] = { 'answer' => ['rounds:5/3', 'tests:spec', 'reject_test_command'], 'class' => 'decided' }
          put(run.worktree, 'lib/x.rb', "X = 1\n")
          first = adv(run)
          assert_equal 'refused', first['status'], "ratified, then the uncommitted work is refused: #{first.inspect}"
          run = Run.load(@paths, run.id)
          assert_equal ['spec', nil], [run.plan.phase(:implement).args[:tests], run.plan.phase(:implement).args[:command]]
          assert_nil run.plan.phase(:implementation_review).args[:max_rounds], 'the rounds token ruled on nothing'
          pin = run.pinned['implement']
          pins = entries(run, 'pinned').size
          assert_equal [File.join(run.worktree, 'spec', 'test_b.rb')], pin['tests'].keys
          item = run.open_items.find { |i| i['item_kind'] == 'plan_parameters' && i.dig('detail', 'test_command') }
          refute_nil item, run.open_items.inspect
          stop!('The stand-in rejected the test command; I continue with the default runner.')

          type!("#{item['id']} はテストコマンドを元に戻して", 'p-restore')
          res = resolve(run, item['id'], 'restore_test_command')
          assert_equal 'recorded', res['status'], res.inspect
          refute res['item_open'], res.inspect
          run = Run.load(@paths, run.id)
          assert_equal 'resolved', run.items[item['id']]['state']
          plan = run.plan
          assert_equal 'ruby', plan.phase(:implement).args[:command], 'the operator restored the command'
          assert_equal 'spec', plan.phase(:implement).args[:tests], 'the ratified tests directory stays'
          assert_nil plan.phase(:implementation_review).args[:max_rounds], 'no round bound appears with the restored command'
          assert_equal({ 'test_command' => 'ruby' }, entries(run, 'plan_amended').last['changes'])
          assert_equal pin['tests'], run.pinned['implement']['tests'], 'the pinned tests are the same files at the same blobs'
          assert_equal 'ruby', run.pinned['implement']['command'], "the pin is retaken with the restored command (R3: its scripts are pinned too)"
          stop!('Restored.')

          commit_all!(run, 'x')
          res = adv(run)
          assert_equal 'phase_ended', res['status'], res.inspect
          assert_equal [['ruby', File.join(run.worktree, 'spec', 'test_b.rb')]], checks_ran,
                       'the restored command runs the pinned set'
          put(run.worktree, 'spec/test_b.rb', "exit 0 # weakened\n")
          commit_all!(run, 'weaken the pinned test')
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          res = adv(run)
          assert_equal 'check_refused', res['status'], "the pinned set still judges: #{res.inspect}"
          assert_equal ['spec/test_b.rb'], asks('pinned_test_change').map { |a| a[:evidence]['path'] }
        end

        # --- reopening -------------------------------------------------------------

        # R2 lifecycle P0: run A ends waiting on I23; the operator types "ok";
        # B starts in s1; the operator names I23 and A's item is resolved
        # from s1 with more_rounds.
        def test_a_reopen_never_binds_a_session_that_holds_another_unfinished_run
          a, item = design_at_bound
          end_waiting!(a)
          release!('ok', 'p-ok')
          b = start_design(stem: 'y')
          assert_equal b.id, bound_id

          type!("#{item['id']} はあと 2 周回して", 'p-more')
          res = resolve(a, item['id'], 'more_rounds', rounds: 2)
          assert_equal 'recorded', res['status'], res.inspect
          refute res['item_open'], res.inspect
          a.reload
          assert_equal 'running', a.status, 'what it waited on is cleared: the run continues'
          assert_nil a.bound_session, 'but not in a session that holds another run'
          assert_equal b.id, bound_id
          assert_equal b.id, File.read(binding_file).strip
          assert_equal 's1', b.reload.bound_session
          stop!

          path = write_design('0.1', stem: 'y')
          assert_includes b.reload.created_paths, path, "B's work is B's"
          refute(a.reload.journal.entries.any? { |e| e['path'] == path }, "nothing of B's lands in A's journal")
          assert_equal 'refused', adv(a)['status'], 'A does not advance from a session it is not bound to'
          assert_equal 'phase_ended', adv(b)['status']
        end

        # R2 operator_proxy P0: review spend 1, open P0 at the bound, waiting,
        # report, finished; then "I16 はあと 2 周回して" with more_rounds 2.
        def test_a_decision_after_the_report_reopens_keeps_the_deck_binds_the_session_and_advance_works
          run, item = design_at_bound
          end_waiting!(run)
          deck = finish!(run)
          old = File.read(deck)
          assert_equal 'finished', run.reload.status

          type!("#{item['id']} はあと 2 周回して", 'p-more')
          tool!('Read', 'file_path' => deck)
          assert_equal run.id, bound_id, "words that name the run's own item continue its business: the guard stays"
          res = resolve(run, item['id'], 'more_rounds', rounds: 2)
          assert_equal 'recorded', res['status'], res.inspect
          assert_equal 'running', res['run_status'], res.inspect
          assert_includes res['next'], 'agent_advance'
          run.reload
          assert_equal ['running', nil, nil], [run.status, run.report, run.end_reason]
          assert_equal 's1', run.bound_session, 'the resolving live session takes the run up'
          assert_equal run.id, bound_id
          refute File.exist?(deck)
          assert_equal old, File.read(File.join(File.dirname(deck), 'deck_1.html')), 'the earlier deck is kept'
          assert_equal 2, run.round_extensions['design_review']
          assert_equal 1, run.spend['review_rounds'], 'the policy\'s rounds for each review are not changed'
          assert_equal 3, review_cap(run, 'design_review'), 'the policy\'s 1 round and the 2 the operator granted'
          assert_equal 'block', stop!&.dig('decision'), 'the reopened run continues'

          write_design('0.2')
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 2, out['round']
          earlier = entries(run, 'review_labelled').last['labels'].first['id']
          collect_round
          @script['review_labels'] = { 'answer' => [{ 'seat' => 'codex', 'text' => P0, 'label' => 'fixed',
                                                      'earlier_id' => earlier }], 'class' => 'decided' }
          out = adv(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          stop!
          finish!(run)
          assert File.exist?(deck), 'a new report'
          assert_equal old, File.read(File.join(File.dirname(deck), 'deck_1.html'))
          assert_equal 'finished', run.reload.status
        end

        # The operator answers in a new session, naming the run: that session
        # is the one that continues it.
        def test_a_decision_after_the_report_from_a_new_session_binds_that_session
          run, item = design_at_bound
          end_waiting!(run)
          finish!(run)
          type!("run #{run.id[-6..]} の #{item['id']} はもう1周回して", 'p-s2', sid: 's2')
          res = resolve(run, item['id'], 'more_rounds', sid: 's2')
          assert_equal 'running', res['run_status'], res.inspect
          assert_equal 's2', run.reload.bound_session
          assert_equal run.id, bound_id('s2')
          @sid = 's2'
          write_design('0.2')
          assert_equal 'dispatched', adv(run)['status']
        end

        # After a reopen the guard stays until words typed after the next
        # ending (design §8). Here the operator's decision was the next hook
        # event's prompt: the agent tool came first, so its release was still
        # pending when the decision reopened the run.
        def test_after_a_reopen_the_guard_waits_for_words_typed_after_the_next_ending
          run, item = design_at_bound
          end_waiting!(run)
          finish!(run)
          type!("#{item['id']} はあと 2 周回して", 'p-more')
          res = resolve(run, item['id'], 'more_rounds', rounds: 2)
          assert_equal 'running', res['run_status'], res.inspect
          assert_equal run.id, bound_id
          write_design('0.2')
          assert_equal 'dispatched', adv(run)['status']
          assert_equal 'stopped', host('agent_stop', 'run_id' => run.id, 'reason' => 'enough for today')['status']
          stop!('Stopped as asked.')
          assert_equal run.id, bound_id, 'no word was typed after this ending; the guard stays'
          deck, verdict = subagent_writes_deck(run)
          assert allowed?(verdict), "the report's writes are guarded and journaled: #{verdict.inspect}"
          fin = host('agent_finish', 'run_id' => run.id)
          assert_equal 'finished', fin['status'], fin.inspect
          assert File.exist?(deck)
        end

        # --- more rounds, more spend -------------------------------------------------

        # R2 lifecycle P1: policy review_rounds 1, the review_open item,
        # "I17 more_rounds" (the operator's words reach the run while it waits).
        def test_more_rounds_extends_that_reviews_cap_and_counts_the_rounds_granted
          adopt_small!
          run, item = design_at_bound
          assert_equal 1, review_cap(run, 'design_review')
          type!("#{item['id']} はもう1周回して", 'p-more')
          res = resolve(run, item['id'], 'more_rounds')
          assert_equal 'running', res['run_status'], res.inspect
          run.reload
          assert_equal [1, 1], [run.spend['review_rounds'], run.round_extensions['design_review']]
          assert_equal 2, review_cap(run, 'design_review')
          assert_empty entries(run, 'spend_extended'), 'no run-wide spend grows with the rounds granted'
          stop!
          write_design('0.2')
          out = adv(run)
          assert_equal 'dispatched', out['status'], "the extended cap lets the round go: #{out.inspect}"
          assert_equal 2, out['round']
          refute(run.reload.open_items.any? { |i| i['text'].include?('round cap') && i['state'] == 'open' })
        end

        # The same decision in the host's order: the Stop hook blocks once, the
        # actor advances again as told (that advance meets the round cap and
        # waits on the same review_open item), the next Stop ends the run as
        # waiting; then the operator says "もう1周".
        def test_more_rounds_after_the_run_ended_waiting_continues_it
          adopt_small!
          run, item = design_at_bound
          end_waiting!(run)
          type!("#{item['id']} はもう1周回して", 'p-more')
          res = resolve(run, item['id'], 'more_rounds')
          assert_equal [1, 1], [run.reload.spend['review_rounds'], run.round_extensions['design_review']]
          assert_equal 2, review_cap(run, 'design_review')
          assert_equal 'running', res['run_status'],
                       "open items: #{run.open_items.map { |i| [i['id'], i['item_kind'], i['text']] }.inspect}"
          assert_equal 's1', run.reload.bound_session
          stop!
          write_design('0.2')
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 2, out['round']
        end

        # A dispatch at the round cap waits on the one review_open item (it
        # was a blocking item that the review refused with): the operator's
        # more_rounds lifts the cap of that review, a plain resolve does not.
        def test_a_dispatch_at_the_round_cap_waits_on_the_review_open_item_and_more_rounds_lifts_it
          run = start_design(rounds: 2)
          write_design('0.1')
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          collect_round(p0_lines: [P0], verdicts: %w[REVISE APPROVE])
          @script['review_labels'] = new_labels(P0)
          assert_equal 'open', adv(run)['status'], 'one round of two: the review is open, not waiting'
          write_design('0.2')
          assert_equal 'dispatched', adv(run)['status']
          collect_round(p0_lines: [P0], verdicts: %w[REVISE APPROVE])
          @script['review_labels'] = { 'answer' => [{ 'seat' => 'codex', 'text' => P0, 'label' => 'carried_over',
                                                      'earlier_id' => 'DR1.F1' }], 'class' => 'decided' }
          waited = adv(run)
          assert_equal 'waiting', waited['status'], waited.inspect
          write_design('0.3')
          out = adv(run)
          assert_equal 'waiting', out['status'], 'a dispatch at the cap waits; it is no longer refused: ' + out.inspect
          assert_equal 'design_review is at its round cap; it waits for the operator', out['reason']
          assert_equal 'design_review is open (1 P0) and has had its 2 rounds; it waits for the operator ' \
                       '(decision more_rounds, or freeze)', run.reload.items[out['item']]['text'],
                       'the item opened when the round was labelled is the one the dispatch waits on'
          assert_equal waited['item'], out['item'], 'the same item'
          item = run.reload.items[out['item']]
          assert_equal 'review_open', item['item_kind']
          assert_empty run.open_items.select { |i| i['item_kind'] == 'blocking' }
          end_waiting!(run)

          type!("#{item['id']} は 1 周分追加して", 'p-spend')
          plain = resolve(run, item['id'])
          assert plain['item_open'], "a plain resolve does not lift the cap: #{plain.inspect}"
          assert_equal 'ended', run.reload.status
          res = resolve(run, item['id'], 'more_rounds')
          assert_equal 'running', res['run_status'], res.inspect
          assert_equal [2, 3], [run.reload.spend['review_rounds'], review_cap(run, 'design_review')]
          assert_equal 's1', run.bound_session
          stop!
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 3, out['round']
        end

        # --- freeze ------------------------------------------------------------------

        # R2 lifecycle P1: round 1 labelled with "first P0"; round 2 raises a
        # second P0 and its labelling fails; "I21 freeze".
        def labelling_failed_run
          run = start_design(rounds: 2)
          write_design('0.1')
          assert_equal 'phase_ended', adv(run)['status']
          assert_equal 'dispatched', adv(run)['status']
          collect_round(p0_lines: ['first P0: the cache has no bound'], verdicts: %w[REVISE APPROVE])
          @script['review_labels'] = new_labels('first P0: the cache has no bound')
          assert_equal 'open', adv(run)['status']
          write_design('0.2')
          assert_equal 'dispatched', adv(run)['status']
          collect_round(p0_lines: ['SECOND new P0: eviction races the writer'], verdicts: %w[REVISE REVISE])
          @script['review_labels'] = { 'answer' => nil, 'class' => 'operator_item' }
          out = adv(run)
          assert_equal 'labelling_failed', out['status'], out.inspect
          item = run.reload.items[out['item']]
          assert_equal 'blocking', item['item_kind']
          end_waiting!(run)
          [run, item]
        end

        def test_freeze_on_a_labelling_failed_item_carries_the_unlabelled_rounds_p0_lines
          run, item = labelling_failed_run
          type!("#{item['id']} は凍結して", 'p-freeze')
          res = resolve(run, item['id'], 'freeze')
          assert_equal 'recorded', res['status'], res.inspect
          refute res['item_open'], res.inspect
          carried = carried_texts(run)
          assert_includes carried, 'SECOND new P0: eviction races the writer', "the unlabelled round's P0 is carried"
          assert_includes carried, 'first P0: the cache has no bound'
          phase = run.phases['design_review']
          assert_equal ['ended', 'operator', false], [phase['status'], phase['by'], phase['provisional']]
          assert_equal 'resolved', run.items[item['id']]['state']
          assert_nil run.current_phase
          assert_includes res['next'], 'Build the report'
        end

        # The freeze leaves an ended run whose report is next (the reply says
        # so); the operator's decision words must not take the guard the
        # report is built under.
        def test_a_freeze_after_an_ending_leaves_the_guard_for_the_report_it_calls_for
          run, item = labelling_failed_run
          type!("#{item['id']} は凍結して", 'p-freeze')
          res = resolve(run, item['id'], 'freeze')
          assert_includes res['next'], 'Build the report'
          stop!('Frozen as the operator said; building the report.')
          assert_equal run.id, bound_id, 'the run the decision was about still needs its report'
          deck, verdict = subagent_writes_deck(run)
          assert allowed?(verdict), "the report's writes are guarded and journaled: #{verdict.inspect}"
          fin = host('agent_finish', 'run_id' => run.id)
          assert_equal 'finished', fin['status'], fin.inspect
          assert File.exist?(deck)
        end

        # --- closure and send_back -----------------------------------------------------

        def test_a_provisional_closure_sent_back_reopens_the_review_with_rounds_for_that_review
          run, item = closed_run
          assert_equal %w[design_review], run.provisional_closures
          assert_includes stop!&.dig('reason').to_s, 'Build the report'
          type!("#{item['id']} は差し戻して、もう1周", 'p-back')
          res = resolve(run, item['id'], 'send_back')
          assert_equal 'recorded', res['status'], res.inspect
          refute res['item_open'], res.inspect
          run.reload
          assert_equal ['running', 'design_review', 'pending'], [run.status, run.current_phase, run.phases['design_review']['status']]
          assert_equal [1, 2], [run.round_extensions['design_review'], review_cap(run, 'design_review')]
          assert_empty run.provisional_closures
          stop!
          write_design('0.2')
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 2, out['round']
        end

        def test_a_closure_sent_back_after_the_report_reopens_the_run_and_the_review
          run, item = closed_run
          deck = finish!(run)
          old = File.read(deck)
          type!("#{item['id']} は差し戻し", 'p-back')
          res = resolve(run, item['id'], 'send_back')
          assert_equal 'running', res['run_status'], res.inspect
          run.reload
          assert_equal ['running', 'design_review', nil], [run.status, run.current_phase, run.report]
          assert_equal 's1', run.bound_session
          assert_equal [1, 2], [run.round_extensions['design_review'], review_cap(run, 'design_review')]
          refute File.exist?(deck)
          assert_equal old, File.read(File.join(File.dirname(deck), 'deck_1.html'))
          stop!
          write_design('0.2')
          out = adv(run)
          assert_equal 'dispatched', out['status'], out.inspect
          assert_equal 2, out['round']
        end

        # --- the words must say the decision --------------------------------------------

        # R2 sonnet P2: "I5 は何?" would authorize freeze.
        def test_a_decision_the_operators_words_do_not_say_leaves_the_item_open
          run, item = design_at_bound
          end_waiting!(run)
          type!("#{item['id']} は何?", 'p-what')
          %w[freeze more_rounds].each do |d|
            res = resolve(run, item['id'], d)
            assert_equal 'recorded', res['status'], res.inspect
            assert res['item_open'], "#{d}: #{res.inspect}"
            assert_includes res['reason'], "do not say #{d}"
          end
          run.reload
          assert_equal 'open', run.items[item['id']]['state']
          assert_equal 'pending', run.phases['design_review']['status']
          assert_equal 'ended', run.status
          assert_empty carried_texts(run)
          assert_empty entries(run, 'rounds_extended')

          type!("#{item['id']} は凍結で", 'p-freeze')
          res = resolve(run, item['id'], 'freeze')
          refute res['item_open'], res.inspect
          assert_equal [P0], carried_texts(run), "the round's open P0 is carried"
          assert_equal 'operator', run.phases['design_review']['by']
        end

        # --- whose words name the item -----------------------------------------------------

        def pasted(ref, run_id = nil)
          "⏺ #{run_id ? "Run #{run_id}: " : ''}#{ref}: design_review is open (1 P0) and has had its 1 rounds; " \
            "it waits for the operator (decision more_rounds, or freeze)\n  Options: freeze | more_rounds\n\nあとで見ます"
        end

        # R2 precedent_auditor P1: "⏺ I7: … Freeze it or run more rounds?…"
        # followed by the operator's own "あとで見ます".
        def test_a_ref_only_inside_pasted_host_output_names_nothing
          run, item = design_at_bound
          type!(pasted(item['id']), 'p-paste1')
          res = resolve(run, item['id'], 'freeze')
          assert_equal 'refused', res['status'], "bound, words during the run: #{res.inspect}"
          end_waiting!(run)
          release!('ok', 'p-ok')
          type!(pasted(item['id']), 'p-paste2')
          res = resolve(run, item['id'], 'freeze')
          assert_equal 'refused', res['status'], "the session the run was bound to, afterwards: #{res.inspect}"
          type!(pasted(item['id'], run.id), 'p-paste3', sid: 's2')
          res = resolve(run, item['id'], 'freeze', sid: 's2')
          assert_equal 'refused', res['status'], "another session, the run's id also only in the paste: #{res.inspect}"
          run.reload
          assert_equal 'open', run.items[item['id']]['state']
          assert_equal 'pending', run.phases['design_review']['status']
          assert_empty carried_texts(run)

          type!("#{item['id']} は凍結して", 'p-own')
          res = resolve(run, item['id'], 'freeze')
          refute res['item_open'], "the operator's own words do name it: #{res.inspect}"
          assert_equal 'operator', run.reload.phases['design_review']['by']
        end

        # R2 precedent_auditor carry-over: words typed in s1 before the run
        # existed (about an earlier run) named an id this run later gave.
        def test_words_typed_before_the_run_started_name_nothing_in_it
          @sid = 's9'
          earlier, earlier_item = design_at_bound(stem: 'z')
          earlier_decision = earlier.reload.decisions.find { |d| d['point'] == 'review_labels' }['id']
          @sid = 's1'
          type!("#{earlier_item['id']} は凍結して。#{earlier_decision} は違う、まだ待って", 'p-before')
          sleep 1.1
          run, item = design_at_bound
          decision = run.reload.decisions.find { |d| d['point'] == 'review_labels' }['id']
          assert_equal [earlier_item['id'], earlier_decision], [item['id'], decision], 'the same flow gives the same ids'
          assert(run.verified_operator_words.any? { |w| w.include?(item['id']) }, 'the words were before the binding')

          res = resolve(run, item['id'], 'freeze')
          assert_equal 'refused', res['status'], res.inspect
          res = host('agent_items', 'action' => 'correct', 'run_id' => run.id, 'ref' => decision)
          assert_equal 'refused', res['status'], res.inspect
          refute(Precedents.new(@paths.precedents_dir).all.any? { |p| p['kind'] == 'correction' })
          assert_equal 'open', run.reload.items[item['id']]['state']

          type!("#{item['id']} は凍結して", 'p-during')
          res = resolve(run, item['id'], 'freeze')
          refute res['item_open'], "words typed during the run do name it: #{res.inspect}"
        end

        # --- the release after an ending ----------------------------------------------------

        # R2 precedent_auditor P1: a ScheduleWakeup prompt ("継続して下さい。",
        # promptSource system, isMeta) unbound an ended run.
        def test_a_scheduled_prompt_after_an_ending_keeps_the_guard_and_a_typed_one_releases_it
          run, = design_at_bound
          end_waiting!(run)
          scheduled!('継続して下さい。', 'p-sched1', 'isMeta' => true, 'promptSource' => 'system')
          assert_nil stop!
          assert_equal run.id, bound_id, 'a scheduled prompt is not the operator speaking'
          scheduled!('継続して下さい。', 'p-sched2', 'origin' => { 'kind' => 'human' }, 'promptSource' => 'system')
          out = tool!('Write', 'file_path' => File.join(@paths.policies_dir, 'p9.rb'), 'content' => 'x')
          assert_equal 'deny', out&.dig('hookSpecificOutput', 'permissionDecision'), "the guard still works: #{out.inspect}"
          assert_equal %w[p-sched1 p-sched2], entries(run, 'release_cancelled').map { |e| e['prompt_id'] }

          type!('了解', 'p-typed')
          assert_equal run.id, bound_id, 'released at the next hook event, not at the prompt'
          stop!
          assert_nil bound_id
          refute File.exist?(binding_file)
          assert_equal 'ended', run.reload.status
        end

        def test_a_scheduled_prompt_after_a_finish_keeps_the_guard_too
          run, = closed_run
          finish!(run)
          scheduled!('継続して下さい。', 'p-sched', 'isMeta' => true, 'promptSource' => 'system')
          tool!('Read', 'file_path' => @transcript)
          stop!
          assert_equal run.id, bound_id
          type!('ありがとう', 'p-thanks')
          tool!('Read', 'file_path' => @transcript)
          assert_nil bound_id
        end

        # The next hook event after the operator's words is often the agent
        # tool itself: "この件はここまで。次の設計を始めて" → agent_start.
        def test_typed_words_after_an_ending_release_the_guard_before_an_immediate_agent_start
          run, = design_at_bound
          end_waiting!(run)
          type!('この件はここまで。次の設計を始めて', 'p-next')
          out = host('agent_start', 'goal' => 'design y', 'template' => 'design_only',
                                    'design_glob' => 'log/y_design_v*.md')
          assert_equal 'started', out['status'], "the operator's next words were typed: #{out.inspect}"
          assert_equal out['run_id'], bound_id
          assert_equal 'ended', run.reload.status
        end
      end
    end
  end
end
