# frozen_string_literal: true

# Regression tests for the second fix batch after implementation review R1
# (the verifiers' and the critic's findings). Reuses the "check" harness: real
# git repositories and confined runs under a temporary directory, a scripted
# stand-in and scripted review tools.
require_relative 'test_agent1_r1_check'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R1bFixes < TestAgent1R1Check
        # Only this file's tests run here; the harness's own run in theirs.
        TestAgent1R1Check.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }

        def collect_round(reviews:, p0_lines: [], counted: 2)
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = {
            'status' => 'ok', 'reviews' => reviews,
            'aggregated_findings' => p0_lines.map { |t| { 'severity' => 'P0', 'issue' => t } },
            'vote_tally' => { 'successful_count' => counted, 'min_quorum' => 2 }
          }
        end

        def last_ask_evidence(point)
          asks(point).last[:evidence]
        end

        def design_run
          adopt! unless Policies.new(@paths).adopted
          out = service.start(via_hook('s1', 'agent_start', 'goal' => 'design x', 'template' => 'design_only',
                                                              'design_glob' => 'log/x_design_v*.md'))
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          path = File.join(@root, 'log', 'x_design_v0.1.md')
          pre(run, 'Write', 'file_path' => path, 'content' => 'x')
          File.write(path, "# x v0.1\n")
          assert_equal 'phase_ended', advance(run)['status']
          run
        end

        # --- review labelling ----------------------------------------------------

        def test_a_labelling_that_lists_nothing_while_the_tool_extracted_p0s_is_not_a_closure
          run = design_run
          assert_equal 'dispatched', advance(run)['status']
          collect_round(reviews: [{ 'role_label' => 'codex', 'verdict' => 'REVISE', 'raw_text' => 'P0: no bound' },
                                  { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'ok' }],
                        p0_lines: ['the cache has no bound'])
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          out = advance(run)
          assert_equal 'labelling_failed', out['status'], out.inspect
          assert_nil run.reload.phases['design_review']['by']
          @script['review_labels'] = { 'answer' => [{ 'seat' => 'codex', 'text' => 'the cache has no bound', 'label' => 'new' }],
                                       'class' => 'decided' }
          out = advance(run)
          assert_equal 'open', out['status'], 'an open P0 keeps the review open; the policy\'s spend (8) is not reached'
          assert_equal ['the cache has no bound'], out['open_p0'].map { |l| l['text'] }
          assert_empty run.reload.open_items.select { |i| i['item_kind'] == 'review_open' }
          assert_nil run.phases['design_review']['by']
          assert_equal 1, dispatched.size, 'labelled again, not dispatched again'
        end

        def test_a_deferred_p0_labelled_fixed_is_settled_and_not_sent_again
          run = design_run
          item = run.open_item('carried_p0', 'design: codex: no bound', ref: 'earlier_review',
                               detail: { 'finding' => 'R1.F1', 'seat' => 'codex', 'text' => 'the cache has no bound',
                                         'deferred' => true })
          assert_equal 'dispatched', advance(run)['status']
          bundle = dispatched.last.last['artifact_content']
          assert_includes bundle, "[#{item['id']}]", 'a P0 deferred at an earlier review is carried into this one'
          collect_round(reviews: [{ 'role_label' => 'codex', 'verdict' => 'APPROVE', 'raw_text' => 'bounded now' },
                                  { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'ok' }])
          @script['review_labels'] = { 'answer' => [{ 'seat' => 'codex', 'text' => 'the cache has no bound', 'label' => 'fixed',
                                                      'earlier_id' => item['id'] }], 'class' => 'decided' }
          out = advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          settled = run.reload.items[item['id']]
          assert_equal 'resolved', settled['state']
          assert_match(/labelled fixed in design_review round 1 \(provisional\)/, settled['resolution'])
        end

        def test_a_frozen_p0_item_is_not_carried_into_the_next_review_and_stays_open
          run = design_run
          item = run.open_item('carried_p0', 'earlier_review: codex: no bound', ref: 'earlier_review',
                               detail: { 'finding' => 'R1.F1', 'seat' => 'codex', 'text' => 'the cache has no bound' })
          assert_equal 'dispatched', advance(run)['status']
          sent = dispatched.last.last
          refute_includes sent['artifact_content'], 'the cache has no bound', 'a P0 frozen open is not sent to the seats'
          assert_empty sent['prior_findings']
          collect_round(reviews: [{ 'role_label' => 'codex', 'verdict' => 'APPROVE', 'raw_text' => 'ok' },
                                  { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'ok' }])
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          out = advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_empty last_ask_evidence('review_labels')['earlier_open_p0']
          assert_equal 'open', run.reload.items[item['id']]['state'], 'it stays an operator item on the report'
        end

        # --- plan ratification -----------------------------------------------------

        def test_the_stand_in_can_move_the_tests_the_run_is_judged_by
          repo!('test/test_a.rb' => "exit 0\n", 'spec/test_b.rb' => "exit 0\n")
          run = started_run(tests: 'test')
          @script['plan_parameters'] = { 'answer' => ['tests:spec'], 'class' => 'decided' }
          advance(run)
          run = Run.load(@paths, run.id)
          assert_equal 'spec', run.plan.phase(:implement).args[:tests]
          assert_equal [File.join(run.worktree, 'spec', 'test_b.rb')], run.pinned['implement']['tests'].keys
          cands = asks('plan_parameters').first[:evidence]['test_directory_candidates']
          assert_equal %w[spec test], cands.sort
        end

        def test_a_rejected_test_command_can_be_restored_by_the_operator
          repo!('test/test_ok.rb' => "exit 0\n")
          run = started_run(test_command: 'ruby -W0')
          @script['plan_parameters'] = { 'answer' => ['reject_test_command'], 'class' => 'decided' }
          advance(run)
          run = Run.load(@paths, run.id)
          assert_nil run.plan.phase(:implement).args[:command]
          item = run.open_items.find { |i| i['item_kind'] == 'plan_parameters' }
          refute_nil item
          words = "#{item['id']} はテストコマンドを戻して"
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => 'pr9', 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => words }))
          end
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => words, 'prompt_id' => 'pr9',
                                           'transcript_path' => @transcript)
          out = service.items(via_hook('s1', 'agent_items', 'action' => 'resolve', 'run_id' => run.id, 'ref' => item['id'],
                                                            'decision' => 'restore_test_command'))
          assert_equal 'recorded', out['status'], out.inspect
          assert_equal 'ruby -W0', Run.load(@paths, run.id).plan.phase(:implement).args[:command]
        end

        # --- pins ----------------------------------------------------------------

        def test_a_glob_with_no_directory_pins_only_what_it_matches
          repo!('lib/a.rb' => "x\n", 'lib/a_test.rb' => "exit 0\n", 'b_test.rb' => "exit 0\n", 'README.md' => "r\n")
          run = started_run(tests: '**/*_test.rb')
          pinned = run.pinned['implement']['tests'].keys.map { |k| k.delete_prefix("#{run.worktree}/") }.sort
          assert_equal %w[b_test.rb lib/a_test.rb], pinned
          v = pre(run, 'Edit', 'file_path' => File.join(run.worktree, 'lib', 'a.rb'), 'old_string' => 'x', 'new_string' => 'y')
          assert_equal 'allow', v.dig('hookSpecificOutput', 'permissionDecision'), 'a source file is not a pinned test'
        end

        # --- a repository reached through a link ------------------------------------

        def test_a_design_phase_ends_when_the_repository_is_reached_through_a_link
          adopt!
          link = File.join(@tmp, 'via_link')
          File.symlink(@root, link)
          out = service.start(via_hook('s1', 'agent_start', 'goal' => 'design x', 'template' => 'design_only',
                                                              'design_glob' => 'log/x_design_v*.md', 'target_repo' => link))
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          assert_equal @root, run.target_repo, 'the repository is recorded by its resolved path'
          path = File.join(link, 'log', 'x_design_v0.1.md')
          hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Write', 'cwd' => link,
                                     'tool_input' => { 'file_path' => path, 'content' => 'x' })
          File.write(path, "# x\n")
          assert_equal 'phase_ended', advance(run)['status']
        end

        # --- the diff limit ----------------------------------------------------------

        def test_the_operator_can_have_a_large_diff_reviewed_whole
          repo!('test/test_ok.rb' => "exit 0\n")
          run = started_run
          @script['plan_parameters'] = { 'answer' => 'approve', 'class' => 'decided' }
          put(run.worktree, 'lib/big.rb', "# #{'x' * 100}\n" * 2100)
          commit_all!(run, 'big')
          assert_equal 'phase_ended', advance(run)['status']
          out = advance(run)
          assert_equal 'refused', out['status'], out.inspect
          item = run.reload.open_items.find { |i| i['text'].include?('diff exceeds') }
          refute_nil item
          words = "#{item['id']} はそのまま全部査読して"
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => 'pr8', 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => words }))
          end
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => words, 'prompt_id' => 'pr8',
                                           'transcript_path' => @transcript)
          plain = service.items(via_hook('s1', 'agent_items', 'action' => 'resolve', 'run_id' => run.id, 'ref' => item['id']))
          assert plain['item_open'], 'without a decision the item stays open'
          service.items(via_hook('s1', 'agent_items', 'action' => 'resolve', 'run_id' => run.id, 'ref' => item['id'],
                                                      'decision' => 'review_whole'))
          assert_equal 'dispatched', advance(run)['status']
        end

        # --- Stop while a round is in flight -------------------------------------------

        def test_a_round_that_never_returns_does_not_push_the_turn_forever
          run = design_run
          assert_equal 'dispatched', advance(run)['status']
          first = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Waiting for the round.')
          assert_equal 'block', first['decision']
          assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Still waiting.'),
                     'without progress the second turn end rests'
          assert_equal 'running', run.reload.status
        end

        # --- the journal ----------------------------------------------------------------

        def test_a_torn_last_line_does_not_brick_the_run
          run = design_run
          File.open(run.journal.path, 'a') { |f| f.write('{"seq": 99, "kind": "trunc') }
          refute run.journal.intact?
          e = run.append(:idle, reason: 'after a torn line')
          assert_equal run.journal.entries[-1]['seq'], e['seq']
          assert_equal 'running', Run.load(@paths, run.id).status
        end

        # --- the operator's own settings rules --------------------------------------------

        def test_ask_and_path_rules_are_refused_and_queued
          repo!('test/test_ok.rb' => "exit 0\n")
          run = started_run
          rules = [{ 'kind' => 'ask', 'tool' => 'WebFetch', 'spec' => 'domain:example.com' },
                   { 'kind' => 'deny', 'tool' => 'Read', 'spec' => './secrets/**' }]
          g = Guard.new(run: run, paths: @paths, policy: @policy, project_root: @root, settings_rules: rules)
          assert g.decide('WebFetch', { 'url' => 'https://api.example.com/x' }).refuse?
          other = g.decide('WebFetch', { 'url' => 'https://other.org/x' })
          assert other.refuse?, 'no lookup is allowed, whatever the operator\'s ask rules say'
          assert_includes other.reason, 'does not look things up on the web'
          assert g.decide('Read', { 'file_path' => File.join(@root, 'secrets', 'k') }, cwd: @root).refuse?
          assert g.decide('Read', { 'file_path' => File.join(@root, 'lib', 'k') }, cwd: @root).allow?
          assert g.decide('Grep', { 'path' => File.join(@root, 'secrets') + '/**' }, cwd: @root).refuse?
        end

        # --- hazards ---------------------------------------------------------------------

        def test_an_alert_the_stand_in_cannot_rule_ends_the_run
          run = design_run
          failing = Object.new
          def failing.ask(**) = StandIn::Answer.new(answer: nil, klass: 'operator_item', confidence: 0.0, basis: [],
                                                    reason: StandIn::FAILED, calls: 2, inputs_digest: '')

          def failing.rule_hazard(_text, **) = ['not_ruled', ask]
          @stand_in = failing
          out = service.items(via_hook('s1', 'agent_items', 'action' => 'alert', 'run_id' => run.id,
                                                            'text' => 'the key in config/x.yml was pushed'))
          assert_equal 'run_ended', out['status'], out.inspect
          assert_equal 'hazard (not_ruled)', run.reload.end_reason
        end

        def test_after_an_ending_a_question_is_left_for_the_returning_operator
          run = design_run
          service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 'enough')
          n = asks('prose_question').size
          hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'I5 はマージしますか？')
          assert_equal n, asks('prose_question').size
        end
      end
    end
  end
end
