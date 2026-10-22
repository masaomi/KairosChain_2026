# frozen_string_literal: true

# Persona seats in run reviews (log/agent_persona_seats_design_v0.3_20261022.md):
# dispatch composes three seats, the actor launches them by marker, the hooks
# rewrite the launch, hold the seat to its prompt and settle its reply from
# the host's inputs, and agent_advance submits the settled replies. Driven
# through the real Service and Hooks with the review tools stubbed and the
# host's meta and transcript files written as Claude Code writes them.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'time'
require 'fileutils'
require_relative '../lib/agent/service'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1PersonaSeats < Minitest::Test
        class Scripted
          attr_reader :asked

          def initialize(script)
            @script = script
            @asked = []
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
            @asked << { point: point, question: question, evidence: evidence }
            reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
            reply = reply.call(question) if reply.respond_to?(:call)
            StandIn::Answer.new(answer: reply['answer'], klass: reply['class'], confidence: 0.9, basis: [],
                                reason: 'scripted', calls: 1, inputs_digest: 'x' * 64)
          end

          def rule_hazard(text, **kw)
            a = ask(point: 'hazard', question: text, options: StandIn::HAZARD_RULINGS, **kw)
            [a.answer.to_s, a]
          end
        end

        POLICY = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 8, stand_in_calls: 100 }
          end
        RUBY
        TOKEN = 'abcd1234-0000-4000-8000-000000000001'
        TEAM = 'claude_team_claude-opus-5-5'

        def setup
          @root = File.realpath(Dir.mktmpdir('seats'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@root, 'global_bound_sessions.txt')
          @paths = Paths.new(File.join(@root, '.kairos'))
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'p1.rb'), POLICY)
          FileUtils.mkdir_p(File.join(@root, 'log'))
          @policy = DSL.parse_policy(POLICY)
          @script = {}
          @stand_in = Scripted.new(@script)
          @invoked = []
          @mlr = {}
          @transcript = File.join(@root, 'projects', 's1.jsonl')
          FileUtils.mkdir_p(File.dirname(@transcript))
          File.write(@transcript, '')
        end

        def teardown
          FileUtils.rm_rf(@root)
        end

        def service
          Service.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in },
                      invoke: lambda { |name, args|
                        @invoked << [name, args]
                        v = @mlr.fetch(name) { {} }
                        v.respond_to?(:call) ? v.call(args) : v
                      },
                      chain: ->(_logs) { 1 }, run_cmd: ->(_a, _c, _t) { ["issues=0\n", true] })
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

        def pre(tool, input = {}, sid = 's1')
          hooks.handle('PreToolUse', { 'session_id' => sid, 'tool_name' => tool, 'transcript_path' => @transcript,
                                       'cwd' => @root }.merge(input))
        end

        def decision(out)
          out&.dig('hookSpecificOutput', 'permissionDecision')
        end

        # A design-only run whose design_review is the current phase, the
        # review tool answering delegation_pending.
        def start_review(must_collect_by: Time.now + 3600)
          words = "adopt policy p1 #{@policy.digest[0, 8]} でお願いします"
          typed(words, 'pr1')
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => words, 'prompt_id' => 'pr1',
                                           'transcript_path' => @transcript)
          service.items('action' => 'adopt_policy', 'policy' => 'p1')
          args = pre('mcp__kairos-chain__agent_start', 'tool_input' => { 'goal' => 'design the thing', 'template' => 'design_only',
                                                                          'design_glob' => 'log/thing_design_v*.md' })
                 .dig('hookSpecificOutput', 'updatedInput')
          out = service.start(args)
          assert_equal 'started', out['status'], out.inspect
          hooks.handle('PostToolUse', 'session_id' => 's1', 'tool_name' => 'mcp__kairos-chain__agent_start',
                                      'transcript_path' => @transcript,
                                      'tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }])
          run = Run.load(@paths, out['run_id'])
          path = File.join(@root, 'log', 'thing_design_v0.1.md')
          assert_equal 'allow', decision(pre('Write', 'tool_input' => { 'file_path' => path, 'content' => 'x' }))
          File.write(path, "# Design v0.1\nINV-1 the thing holds.\n")
          assert_equal 'phase_ended', service.advance('run_id' => run.id, '_session_id' => 's1')['status']
          @mlr['multi_llm_review'] = { 'status' => 'delegation_pending', 'collect_token' => TOKEN,
                                       'must_collect_by' => must_collect_by.iso8601 }
          @dispatch_reply = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'dispatched', @dispatch_reply['status'], @dispatch_reply.inspect
          run.reload
        end

        def dispatch_entry(run)
          run.reload.journal.entries.reverse.find { |e| e['kind'] == 'review_dispatched' }
        end

        def marker(run, persona)
          Seats.marker(run.id, TOKEN, persona)
        end

        # The actor's Agent call by marker; returns the hook's answer.
        def launch(run, persona, tool_use_id, extra = {})
          pre('Agent', { 'tool_use_id' => tool_use_id, 'effort' => { 'level' => 'xhigh' },
                         'tool_input' => { 'prompt' => marker(run, persona), 'description' => 'mine', 'model' => 'haiku' } }
                         .merge(extra))
        end

        # What Claude Code writes for a subagent: its meta file naming the
        # launch, and its transcript whose first user record is its prompt.
        def host_subagent(agent_id, tool_use_id, prompt, finished: false)
          dir = File.join(File.dirname(@transcript), 's1', 'subagents')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "agent-#{agent_id}.meta.json"),
                     JSON.generate('agentType' => 'general-purpose', 'toolUseId' => tool_use_id,
                                   'requestShape' => 'background', 'finished' => finished))
          File.write(File.join(dir, "agent-#{agent_id}.jsonl"),
                     JSON.generate('type' => 'user', 'isSidechain' => true, 'agentId' => agent_id,
                                   'message' => { 'role' => 'user', 'content' => prompt }) + "\n")
          File.join(dir, "agent-#{agent_id}.jsonl")
        end

        def seat_call(agent_id, tool, tool_input = {})
          pre(tool, 'agent_id' => agent_id, 'tool_input' => tool_input)
        end

        def seat_stop(agent_id, transcript, last = 'Done.')
          hooks.handle('SubagentStop', 'session_id' => 's1', 'transcript_path' => @transcript, 'agent_id' => agent_id,
                                       'agent_transcript_path' => transcript, 'last_assistant_message' => last)
        end

        # Launches a seat and runs it to its hand-back and stop.
        def answer_seat(run, persona, n, reply)
          out = launch(run, persona, "toolu_#{n}")
          assert_equal 'allow', decision(out), out.inspect
          prompt = out.dig('hookSpecificOutput', 'updatedInput', 'prompt')
          t = host_subagent("a#{n}", "toolu_#{n}", prompt)
          assert_equal 'allow', decision(seat_call("a#{n}", 'SubagentHandback', 'message' => reply))
          seat_stop("a#{n}", t)
          t
        end

        REVISE = "**Overall Verdict**: REVISE\n\nP0: the cache is never invalidated [consequence: readers see stale data] [location: §2]\n" \
                 "P1: name the lock\n"
        APPROVE = "**Overall Verdict**: APPROVE\n\nNo findings.\n"

        def collect_reply
          { 'status' => 'ok',
            'reviews' => [{ 'role_label' => 'codex', 'verdict' => 'APPROVE', 'raw_text' => APPROVE },
                          { 'role_label' => TEAM, 'verdict' => 'REVISE', 'synthetic' => true,
                            'persona_rows' => [], 'raw_text' => 'assembled summary' }],
            'aggregated_findings' => [], 'vote_tally' => { 'successful_count' => 2, 'min_quorum' => 2 } }
        end

        # --- dispatch -------------------------------------------------------------

        def test_dispatch_declares_three_seats_and_journals_them_with_the_token
          run = start_review
          req = @invoked.find { |n, _| n == 'multi_llm_review' }.last
          assert_equal 3, req['persona_count_declared']
          assert_equal Seats::DEADLINE_SECONDS, req['collect_deadline_seconds_override']
          d = dispatch_entry(run)
          assert_equal TOKEN, d['token']
          assert_equal %w[architect security operability], d['seats'].map { |s| s['persona'] }
          refute_nil d['must_collect_by']
          d['seats'].each do |s|
            text = File.read(Seats.prompt_path(run, s['sha256']))
            assert_equal s['sha256'], Digest::SHA256.hexdigest(text)
            assert_includes text, "Persona seat: #{s['persona']}"
            assert_includes text, 'INV-1 the thing holds', 'the seat reads the bundle the external seats read'
            assert_includes text, '**Overall Verdict**'
          end
          d['seats'].each { |s| assert_includes @dispatch_reply['next'], marker(run, s['persona']) }
        end

        # --- launch ----------------------------------------------------------------

        def test_a_marker_launch_is_rewritten_and_every_caller_key_dropped
          run = start_review
          out = launch(run, 'architect', 'toolu_1')
          assert_equal 'allow', decision(out)
          up = out.dig('hookSpecificOutput', 'updatedInput')
          assert_equal %w[description effort prompt subagent_type], up.keys.sort
          assert_equal 'general-purpose', up['subagent_type']
          assert_equal 'review seat architect', up['description']
          assert_equal 'xhigh', up['effort']
          sha = dispatch_entry(run)['seats'].first['sha256']
          assert_includes up['prompt'], Seats.prompt_path(run, sha)
          l = run.reload.journal.entries.find { |e| e['kind'] == 'seat_launched' }
          assert_equal %w[toolu_1 architect], [l['tool_use_id'], l['persona']]
          assert_equal Digest::SHA256.hexdigest(up['prompt']), l['prompt_sha256']
        end

        def test_near_miss_duplicate_and_unknown_markers_are_denied_without_an_item
          run = start_review
          items = run.open_items.size
          near = pre('Agent', 'tool_use_id' => 't9', 'tool_input' => { 'prompt' => "#{marker(run, 'architect')}.", 'description' => 'x' })
          assert_equal 'deny', decision(near)
          assert_includes near.dig('hookSpecificOutput', 'permissionDecisionReason'), marker(run, 'security')
          assert_equal 'allow', decision(launch(run, 'architect', 'toolu_1'))
          again = launch(run, 'architect', 'toolu_2')
          assert_equal 'deny', decision(again)
          assert_includes again.dig('hookSpecificOutput', 'permissionDecisionReason'), 'still running'
          assert_equal items, run.reload.open_items.size, 'a mistaken launch is not an operator item'
          plain = pre('Agent', 'tool_use_id' => 't8', 'tool_input' => { 'prompt' => 'explore the repo', 'description' => 'x' })
          refute_equal 'deny', decision(plain), 'an Agent call that is not a marker is left to the guard'
        end

        # --- a seat reads only its prompt --------------------------------------------

        def test_a_seat_may_read_its_prompt_and_hand_back_and_nothing_else
          run = start_review
          items = run.open_items.size
          prompt = launch(run, 'architect', 'toolu_1').dig('hookSpecificOutput', 'updatedInput', 'prompt')
          host_subagent('a1', 'toolu_1', prompt)
          own = Seats.prompt_path(run, dispatch_entry(run)['seats'].first['sha256'])
          assert_equal 'allow', decision(seat_call('a1', 'Read', 'file_path' => own))
          assert_equal 'deny', decision(seat_call('a1', 'Read', 'file_path' => File.join(@root, 'log', 'thing_design_v0.1.md')))
          assert_equal 'deny', decision(seat_call('a1', 'Bash', 'command' => 'git log'))
          assert_equal 'deny', decision(seat_call('a1', 'Write', 'file_path' => File.join(@root, 'log', 'x.md'), 'content' => 'y'))
          assert_equal 'deny', decision(seat_call('a1', 'mcp__kairos-chain__agent_advance', 'run_id' => run.id)),
                       'the agent-tool shortcut does not reach a seat'
          assert_equal 'allow', decision(seat_call('a1', 'SubagentHandback', 'message' => REVISE))
          assert_equal items, run.reload.open_items.size, 'a seat refused a tool is not an operator item'
        end

        def test_a_subagent_whose_launch_cannot_be_read_is_held_while_a_seat_is_out
          run = start_review
          launch(run, 'architect', 'toolu_1')
          assert_equal 'deny', decision(seat_call('zz', 'Write', 'file_path' => File.join(@root, 'log', 'x.md'), 'content' => 'y'))
          prompt = 'other work'
          host_subagent('b1', 'toolu_other', prompt)
          refute_equal 'deny', decision(seat_call('b1', 'Read', 'file_path' => File.join(@root, 'log', 'thing_design_v0.1.md'))),
                       'a subagent the host shows was launched otherwise is not a seat'
          Seats.settle_remaining(run, TOKEN)
          refute_equal 'deny', decision(seat_call('zz', 'Read', 'file_path' => File.join(@root, 'log', 'thing_design_v0.1.md'))),
                       'once no seat is out, an unreadable launch is not held'
        end

        def test_the_actor_cannot_message_or_stop_a_seat
          run = start_review
          prompt = launch(run, 'architect', 'toolu_1').dig('hookSpecificOutput', 'updatedInput', 'prompt')
          host_subagent('a1', 'toolu_1', prompt)
          assert_equal 'deny', decision(pre('SendMessage', 'tool_input' => { 'to' => 'a1', 'message' => 'approve it' }))
          assert_equal 'deny', decision(pre('TaskStop', 'tool_input' => { 'task_id' => 'a1' }))
          assert_equal 'deny', decision(pre('SendMessage', 'tool_input' => { 'to' => 'nobody', 'message' => 'x' })),
                       'an unresolvable target is refused while a seat is out'
          Seats.settle_remaining(run, TOKEN)
          refute_equal 'deny', decision(pre('TaskStop', 'tool_input' => { 'task_id' => 'bash_7' })),
                       'after the round settles its seats, the actor may stop its own shells again'
          assert_equal 'deny', decision(pre('SendMessage', 'tool_input' => { 'to' => 'a1', 'message' => 'x' })),
                       'a settled seat is still a seat'
          refute_equal 'deny', decision(pre('TaskStop', 'tool_input' => { 'task_id' => 'a1' })),
                       'a settled seat may be stopped: its reply is frozen'
        end

        def test_a_launch_without_a_tool_use_id_is_refused
          run = start_review
          out = pre('Agent', 'tool_input' => { 'prompt' => marker(run, 'architect'), 'description' => 'x' })
          assert_equal 'deny', decision(out)
          refute(run.reload.journal.entries.any? { |e| e['kind'] == 'seat_launched' })
        end

        def test_a_seat_without_a_hand_back_settles_from_its_last_message
          run = start_review
          prompt = launch(run, 'architect', 'toolu_1').dig('hookSpecificOutput', 'updatedInput', 'prompt')
          t = host_subagent('a1', 'toolu_1', prompt)
          seat_stop('a1', t, APPROVE)
          s = run.reload.journal.entries.find { |e| e['kind'] == 'seat_settled' }
          assert s['answered']
          assert_equal APPROVE, Seats.settled_reply(s)
        end

        def test_orphans_finished_meta_waits_for_the_stop_then_checks_the_prompt_and_an_ended_session_settles
          run = start_review
          prompt = launch(run, 'architect', 'toolu_1').dig('hookSpecificOutput', 'updatedInput', 'prompt')
          host_subagent('a1', 'toolu_1', prompt, finished: true)
          Seats.keep_handback(run, 'a1', APPROVE)
          Seats.settle_orphans(run, Time.now)
          refute(run.reload.journal.entries.any? { |e| e['kind'] == 'seat_settled' }, 'a just-finished seat is left to its own stop')
          Seats.settle_orphans(run, Time.now + Seats::STOP_GRACE_SECONDS + 1)
          s = run.reload.journal.entries.find { |e| e['kind'] == 'seat_settled' }
          assert s['answered'], s.inspect
          launch(run, 'security', 'toolu_2')
          host_subagent('a2', 'toolu_2', 'a prompt the actor wrote', finished: true)
          Seats.keep_handback(run, 'a2', APPROVE)
          Seats.settle_orphans(run, Time.now + Seats::STOP_GRACE_SECONDS + 1)
          assert_equal 'prompt_mismatch', run.reload.journal.entries.find { |e| e['kind'] == 'seat_settled' && e['persona'] == 'security' }['cause']
          launch(run, 'operability', 'toolu_3')
          run.append(:bound, session_id: 's2')
          Seats.settle_orphans(Run.load(@paths, run.id), Time.now)
          assert_equal 'session_ended', run.reload.journal.entries.find { |e| e['kind'] == 'seat_settled' && e['persona'] == 'operability' }['cause']
        end

        # --- settlement ----------------------------------------------------------------

        def test_a_seat_settles_once_from_its_hand_back_and_never_reaches_the_hazard_reader
          run = start_review
          reply = "**Overall Verdict**: REVISE\n\nP0: the private key could leak into the log; data loss on retry " \
                  "[consequence: credentials exposed] [location: §3]\nIs this intended?"
          t = answer_seat(run, 'security', 2, reply)
          s = run.reload.journal.entries.select { |e| e['kind'] == 'seat_settled' }
          assert_equal 1, s.size
          assert s.first['answered']
          assert_equal reply, File.read(s.first['reply_file'])
          refute(@stand_in.asked.any? { |a| %w[hazard prose_question].include?(a[:point]) },
                 'a review finding is not a hazard report or a question')
          Seats.keep_handback(run, 'a2', 'a later reply')
          seat_stop('a2', t)
          assert_equal 1, run.reload.journal.entries.count { |e| e['kind'] == 'seat_settled' }, 'later stops change nothing'
          assert_equal reply, Seats.settled_reply(s.first)
        end

        def test_a_seat_whose_transcript_shows_another_prompt_is_settled_unanswered
          run = start_review
          launch(run, 'architect', 'toolu_1')
          t = host_subagent('a1', 'toolu_1', 'a prompt the actor wrote')
          seat_call('a1', 'SubagentHandback', 'message' => APPROVE)
          seat_stop('a1', t)
          s = run.reload.journal.entries.find { |e| e['kind'] == 'seat_settled' }
          refute s['answered']
          assert_equal 'prompt_mismatch', s['cause']
        end

        def test_a_launch_the_host_never_started_settles_as_not_started_and_may_be_launched_again
          run = start_review
          launch(run, 'architect', 'toolu_1')
          l = run.reload.journal.entries.find { |e| e['kind'] == 'seat_launched' }
          Seats.settle_orphans(run, Time.parse(l['at']) + Seats::START_GRACE_SECONDS + 1)
          s = run.reload.journal.entries.find { |e| e['kind'] == 'seat_settled' }
          assert_equal 'not_started', s['cause']
          assert_equal 'allow', decision(launch(run, 'architect', 'toolu_2')), 'one relaunch after a launch that ended unanswered'
          Seats.settle_orphans(run, Time.parse(l['at']) + 10_000)
          assert_equal 'deny', decision(launch(run, 'architect', 'toolu_3')), 'not a third'
        end

        # --- collect -------------------------------------------------------------------------

        def test_collect_submits_settled_replies_and_the_stand_in_reads_each_persona
          run = start_review
          answer_seat(run, 'architect', 1, REVISE)
          answer_seat(run, 'security', 2, APPROVE)
          answer_seat(run, 'operability', 3, "I think it is fine.\n**Overall Verdict**: APPROVE")
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = collect_reply
          @script['review_labels'] = { 'answer' => [{ 'seat' => "#{TEAM}/architect", 'text' => 'the cache is never invalidated',
                                                      'label' => 'new', 'covers' => [] }], 'class' => 'decided' }
          out = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'open', out['status'], out.inspect
          sub = @invoked.find { |n, _| n == 'multi_llm_review_collect' }.last['orchestrator_reviews']
          assert_equal %w[architect security], sub.map { |r| r['persona'] }
          assert_equal %w[REVISE APPROVE], sub.map { |r| r['verdict'] }
          assert_equal %w[a1 a2], sub.map { |r| r['agent_id'] }
          assert_equal 'P0', sub.first['findings'].first['severity']
          assert_includes sub.first['findings'].first['issue'], '[consequence: readers see stale data]'
          seats = @stand_in.asked.find { |a| a[:point] == 'review_labels' }[:evidence]['seat_replies'].map { |s| s['seat'] }
          assert_equal ['codex', "#{TEAM}/architect", "#{TEAM}/security", "#{TEAM}/operability"], seats,
                       "each persona's own reply replaces the assembled row"
          r = run.reload.journal.entries.find { |e| e['kind'] == 'review_round' }
          assert_equal TOKEN, r['token']
          assert_equal({ 'operability' => 'no_verdict' }, r['personas'].reject { |o| o['submitted'] }.to_h { |o| [o['persona'], o['cause']] })
          assert_equal [TEAM, 'codex'].sort, r['seats'].map { |s| s['seat'] }.sort, 'the record keeps the review tool\'s seats'
        end

        def review_for(run, clock:, sleep:)
          Review.new(run: run, policy: @policy, stand_in: @stand_in, project_root: @root, type: 'design',
                     invoke: lambda { |name, args|
                       @invoked << [name, args]
                       v = @mlr.fetch(name) { {} }
                       v.respond_to?(:call) ? v.call(args) : v
                     },
                     clock: clock, sleep: sleep)
        end

        def test_a_running_seat_holds_one_call_for_its_budget_then_the_cutoff_collects
          run = start_review
          answer_seat(run, 'architect', 1, REVISE)
          answer_seat(run, 'security', 2, APPROVE)
          prompt = launch(run, 'operability', 'toolu_3').dig('hookSpecificOutput', 'updatedInput', 'prompt')
          host_subagent('a3', 'toolu_3', prompt)
          t = Time.now
          slept = []
          rv = review_for(run, clock: -> { t }, sleep: ->(s) { slept << s; t += s })
          phase = run.plan.phase(:design_review)
          out = rv.collect(phase, rv.pending_round('design_review'))
          assert_equal 'pending', out['status'], out.inspect
          assert_in_delta Seats::WAIT_SECONDS, slept.sum, Seats::POLL_SECONDS
          refute(@invoked.any? { |n, _| n == 'multi_llm_review_collect' }, 'nothing is collected while a seat reviews')
          t = Seats.cutoff_of(dispatch_entry(run)) + 1
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = collect_reply
          @script['review_labels'] = { 'answer' => [{ 'seat' => "#{TEAM}/architect", 'text' => 'x', 'label' => 'new', 'covers' => [] }],
                                       'class' => 'decided' }
          rv.collect(phase, rv.pending_round('design_review'))
          r = run.reload.journal.entries.find { |e| e['kind'] == 'review_round' }
          assert_equal 'not_settled', r['personas'].find { |o| o['persona'] == 'operability' }['cause']
          assert_empty Seats.unsettled_launches(run.reload.journal.entries), 'collect settles the launches it went without'
          refute_equal 'deny', decision(pre('TaskStop', 'tool_input' => { 'task_id' => 'bash_7' })),
                       'so the seat refusals end with the round'
          assert_equal 'deny', decision(seat_call('a3', 'Bash', 'command' => 'ls')), 'the hung seat itself stays a seat'
        end

        def test_unlaunched_seats_get_the_instruction_once_then_the_round_collects_and_the_closure_names_them
          run = start_review
          answer_seat(run, 'architect', 1, APPROVE)
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = collect_reply.merge('reviews' => [{ 'role_label' => 'codex', 'verdict' => 'APPROVE', 'raw_text' => APPROVE },
                                                                               { 'role_label' => TEAM, 'verdict' => 'APPROVE', 'synthetic' => true,
                                                                                 'persona_rows' => [], 'raw_text' => 's' }])
          first = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'pending', first['status']
          assert_includes first['next'], marker(run, 'security')
          refute(@invoked.any? { |n, _| n == 'multi_llm_review_collect' })
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          second = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'closed_provisionally', second['status'], second.inspect
          item = run.reload.items[second['item']]
          assert_includes item['text'], 'security (never launched)'
          assert_includes item['text'], 'operability (never launched)'
        end

        def test_a_refused_persona_submission_keeps_the_external_round
          run = start_review
          answer_seat(run, 'architect', 1, APPROVE)
          answer_seat(run, 'security', 2, APPROVE)
          answer_seat(run, 'operability', 3, APPROVE)
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = lambda do |args|
            args['orchestrator_reviews'].empty? ? collect_reply : { 'status' => 'error', 'error' => 'invalid orchestrator_reviews: x' }
          end
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          service.advance('run_id' => run.id, '_session_id' => 's1')
          e = run.reload.journal.entries
          assert(e.any? { |x| x['kind'] == 'seat_submission_refused' })
          r = e.find { |x| x['kind'] == 'review_round' }
          assert(r['personas'].all? { |o| o['cause'] == 'refused_by_review_tool' })
          assert_equal 2, @invoked.count { |n, _| n == 'multi_llm_review_collect' }
        end

        # --- the Stop hook and the report ---------------------------------------------------

        def test_the_stop_hook_keeps_the_actor_on_agent_advance_while_seats_are_out
          run = start_review
          out = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Launched.',
                                     'background_tasks' => [{ 'id' => 'a1' }])
          assert_equal 'block', out&.dig('decision'), 'background seats do not let the actor rest'
          assert_includes out['reason'], marker(run, 'architect')
          2.times do
            again = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Still waiting.',
                                         'background_tasks' => [{ 'id' => 'a1' }])
            assert_equal 'block', again&.dig('decision'), 'blocked again until the round collects'
          end
          assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Still waiting.',
                                          'background_tasks' => [{ 'id' => 'a1' }]),
                     'three blocks with no agent_advance between them, then the run rests rather than spin'
          run.append(:seats_waited, phase: 'design_review', round: 1, token: TOKEN, running: 3)
          assert_equal 'block', hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x')&.dig('decision'),
                       'an agent_advance that waited earns blocks again, also past the cutoff until the round collects'
        end

        def test_a_late_seat_is_named_on_the_closure_even_when_it_answered
          run = start_review
          answer_seat(run, 'architect', 1, APPROVE)
          answer_seat(run, 'security', 2, APPROVE)
          answer_seat(run, 'operability', 3, APPROVE)
          e = run.reload.journal.entries
          first = e.find { |x| x['kind'] == 'seat_settled' && x['persona'] == 'architect' }
          assert first['seq'] < e.find { |x| x['kind'] == 'seat_launched' && x['persona'] == 'security' }['seq']
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = collect_reply.merge('reviews' => [{ 'role_label' => 'codex', 'verdict' => 'APPROVE', 'raw_text' => APPROVE },
                                                                               { 'role_label' => TEAM, 'verdict' => 'APPROVE', 'synthetic' => true,
                                                                                 'persona_rows' => [], 'raw_text' => 's' }])
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          out = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'closed_provisionally', out['status'], out.inspect
          text = run.reload.items[out['item']]['text']
          assert_includes text, 'security (first launched after another seat had answered, then submitted)'
        end

        def test_a_transient_collect_error_is_not_blamed_on_the_personas
          run = start_review
          answer_seat(run, 'architect', 1, APPROVE)
          answer_seat(run, 'security', 2, APPROVE)
          answer_seat(run, 'operability', 3, APPROVE)
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = { 'status' => 'error', 'error' => 'worker_timeout' }
          out = service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'dispatch_failed', out['status']
          assert_equal 1, @invoked.count { |n, _| n == 'multi_llm_review_collect' }
          refute(run.reload.journal.entries.any? { |x| x['kind'] == 'seat_submission_refused' })
          again = launch(run, 'architect', 'toolu_9')
          assert_equal 'deny', decision(again)
          assert_includes again.dig('hookSpecificOutput', 'permissionDecisionReason'), "dispatch failed; agent_advance(run_id: '#{run.id}')"
        end

        def test_the_report_names_each_missing_seat_and_drops_the_old_line
          run = start_review
          answer_seat(run, 'architect', 1, APPROVE)
          answer_seat(run, 'security', 2, APPROVE)
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = collect_reply.merge('reviews' => [{ 'role_label' => 'codex', 'verdict' => 'APPROVE', 'raw_text' => APPROVE },
                                                                               { 'role_label' => TEAM, 'verdict' => 'APPROVE', 'synthetic' => true,
                                                                                 'persona_rows' => [], 'raw_text' => 's' }])
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          service.advance('run_id' => run.id, '_session_id' => 's1')
          service.advance('run_id' => run.id, '_session_id' => 's1')
          notes = service.send(:report_material, run.reload)['not_checked']
          assert(notes.any? { |n| n.include?('2 of 3 persona seats submitted') && n.include?('operability not_launched') }, notes.inspect)
          refute(notes.any? { |n| n.include?('external seats only') })
        end

        # --- after impl review round 2 ----------------------------------------------------

        def test_a_long_persona_finding_keeps_its_consequence_through_the_review_tools_cut
          limit = Seats.mlr::PersonaAssembly::MAX_ISSUE_LENGTH
          long = "**Overall Verdict**: REVISE\n\nP0: the lock is taken twice #{'and the reason runs on ' * 60}" \
                 "[consequence: two writers corrupt the journal] [location: hooks.rb]\nP1: name the lock\n"
          found = Seats.findings(long, 'REVISE')
          p0 = found.find { |f| f['severity'] == 'P0' }
          assert_operator p0['issue'].each_char.count, :<=, limit
          assert p0['issue'].end_with?('[consequence: two writers corrupt the journal] [location: hooks.rb]'), p0['issue'][-120..]
          assert p0['issue'].start_with?('the lock is taken twice'), 'the front of the issue is kept for the dedup key'
          raw = Seats.mlr::PersonaAssembly.build_raw_text([{ 'persona' => 'correctness', 'verdict' => 'REVISE',
                                                              'findings' => found, 'reasoning' => 'r' }], 'REVISE')
          reread = Seats.mlr::Consensus.aggregate_findings([{ verdict: 'REVISE', raw_text: raw, role_label: 'team' }])
          assert_equal 'P0', reread.find { |f| f[:issue].start_with?('the lock is taken twice') }[:severity],
                       'the review tool reads the P0 with its consequence, not as a P2 without one'
          short = Seats.findings(REVISE, 'REVISE').find { |f| f['severity'] == 'P0' }
          assert_equal 'the cache is never invalidated [consequence: readers see stale data] [location: §2]', short['issue'],
                       'a finding that fits is kept as written'
          first = "the lock is taken twice [consequence: two writers corrupt the journal] #{'and so on ' * 150}"
          assert_equal first, Seats.keep_consequence(first, 'two writers corrupt the journal', limit),
                       'a clause the cut keeps needs no rebuilding'
          clamped = Seats.keep_consequence('the lock is taken twice and the text was cut before its clause', 'harm', limit)
          assert_equal 'the lock is taken twice and the text was cut before its clause [consequence: harm]', clamped,
                       'a consequence the issue text lost is put back even when it fits, and nothing is marked cut'
          long = Seats.keep_consequence("x #{'y' * 2000}", 'z' * 2000, limit)
          assert_operator long.length, :<=, limit
          assert_includes long, "#{'z' * 50}...]", 'a consequence cut to fit says it was cut'
          assert_includes long, 'y ... [consequence:', 'a body cut to fit says it was cut'
          located = "the lock is taken twice [consequence: two writers corrupt the journal] #{'and so on ' * 150}[location: hooks.rb:9]"
          rebuilt = Seats.keep_consequence(located, 'two writers corrupt the journal', limit)
          assert rebuilt.end_with?('[consequence: two writers corrupt the journal] [location: hooks.rb:9]'),
                 'a location the cut would drop is carried too'
          straddle = "#{'w' * (limit - 10)} [consequence: the clause straddles the cut] tail"
          over = Seats.keep_consequence(straddle, 'the clause straddles the cut', limit)
          assert_operator over.length, :<=, limit
          assert over.end_with?('[consequence: the clause straddles the cut]'), 'a clause the cut would split is rebuilt'
          assert_equal '[consequence: harm]', Seats.keep_consequence('[consequence: ] ', 'harm', limit)
          fronted = "[location: hooks.rb:10] the seat lock is taken #{'and so on ' * 150}[consequence: x]"
          kept_front = Seats.keep_consequence(fronted, 'x', limit)
          assert kept_front.start_with?('[location: hooks.rb:10] the seat lock is taken'), 'a location the front keeps stays in place'
          assert kept_front.end_with?(' ... [consequence: x]')
          two = "[location: a.rb:1] the lock #{'more ' * 300}[location: ] [location: b.rb:2] [consequence: harm]"
          carried = Seats.keep_consequence(two, 'harm', limit)
          assert carried.start_with?('[location: a.rb:1] the lock')
          assert carried.end_with?('[consequence: harm] [location: b.rb:2]'), 'the stated location the cut would lose is the one carried'
          tiny = Seats.keep_consequence('x y z', 'w' * 100, 30)
          assert_equal "... [consequence: #{'w' * 12}...]", tiny, 'a cut too small for any body leaves none, without raising'
        end

        def test_a_finding_keeps_the_severity_and_the_consequence_of_its_own_line
          prefix = 'the seat lock is taken in the hook and again in the server when the round closes, both on'
          reply = "**Overall Verdict**: REVISE\n\nP0: #{prefix} the same file twice\n" \
                  "P2: #{prefix} the same file again [consequence: a little time is lost] [location: seats.rb]\n"
          found = Seats.findings(reply)
          assert_equal %w[P0 P2], found.map { |f| f['severity'] }, 'one finding per line, each with its own severity'
          refute_includes found.first['issue'], 'consequence', 'the P0 does not borrow the P2 line\'s consequence'
          mlr = Seats.mlr
          raw = mlr::PersonaAssembly.build_raw_text([{ 'persona' => 'correctness', 'verdict' => 'REVISE',
                                                       'findings' => found, 'reasoning' => 'r' }], 'REVISE')
          via_seat = mlr::Consensus.aggregate_findings([{ verdict: 'REVISE', raw_text: raw, role_label: 'team' }])
          direct = mlr::Consensus.aggregate_findings([{ verdict: 'REVISE', raw_text: reply, role_label: 'team' }])
          assert_equal direct.map { |f| [f[:severity], f[:severity_stated]] }, via_seat.map { |f| [f[:severity], f[:severity_stated]] },
                       'the review tool records the seat\'s findings as it records the same reply read directly'
        end

        def test_the_finding_scan_is_the_review_tools_own
          source = File.read(File.join(Seats::MLR_LIB, 'consensus.rb'))
          assert_includes source, "text.scan(/#{Seats::FINDING_LINE.source}/mi)",
                          'Seats::FINDING_LINE must match the scan in Consensus.aggregate_findings'
          assert_equal Regexp::MULTILINE | Regexp::IGNORECASE, Seats::FINDING_LINE.options & (Regexp::MULTILINE | Regexp::IGNORECASE | Regexp::EXTENDED)
        end

        def test_a_blocker_written_after_many_findings_survives_the_review_tools_per_persona_cap
          cap = Seats.mlr::PersonaAssembly::MAX_FINDINGS_PER_PERSONA
          reply = "**Overall Verdict**: REVISE\n\n" + (1..cap + 5).map { |i| "P3: note number #{i} on wording\n" }.join +
                  "P0: the journal is written twice [consequence: the run's record forks] [location: run.rb]\n"
          found = Seats.findings(reply)
          assert_equal 'P0', found.first['severity'], 'most severe first'
          assert_equal (1..cap + 5).map { |i| "note number #{i} on wording" }, found.drop(1).map { |f| f['issue'] },
                       'the seat\'s order is kept within a severity'
          raw = Seats.mlr::PersonaAssembly.build_raw_text([{ 'persona' => 'correctness', 'verdict' => 'REVISE',
                                                              'findings' => found, 'reasoning' => 'r' }], 'REVISE')
          rows = Seats.mlr::Consensus.aggregate_findings([{ verdict: 'REVISE', raw_text: raw, role_label: 'team' }])
          assert(rows.any? { |r| r[:severity] == 'P0' }, 'the blocker reaches the review tool\'s record')
        end

        # Two processes, the order forced by pipes: one holds the seat lock and
        # admits a launch only after the other has signalled that it is about
        # to close the round and has had time to block on the lock.
        def test_closing_waits_for_a_launch_admitted_under_the_lock_so_none_outlives_the_round
          run = start_review
          held_r, held_w = IO.pipe
          go_r, go_w = IO.pipe
          ready_r, ready_w = IO.pipe
          pids = []
          pids << fork do
            held_r.close
            go_w.close
            ready_r.close
            ready_w.close
            Seats.locked(run) do
              held_w.write('h')
              held_w.close
              go_r.read(1)
              run.append(:seat_launched, token: TOKEN, persona: 'architect', phase: 'design_review', round: 1,
                                         tool_use_id: 'toolu_race', full_sha256: 'x', prompt_sha256: 'y')
            end
            exit!(0)
          rescue StandardError
            exit!(1)
          end
          held_w.close
          go_r.close
          assert_equal 'h', held_r.read(1), 'the launcher holds the lock'
          pids << fork do
            go_w.close
            ready_r.close
            ready_w.write('c')
            ready_w.close
            Seats.settle_remaining(Run.load(@paths, run.id), TOKEN)
            exit!(0)
          rescue StandardError
            exit!(1)
          end
          ready_w.close
          assert_equal 'c', ready_r.read(1), 'the closer is about to close'
          sleep 0.3
          assert_nil Process.waitpid(pids.last, Process::WNOHANG), 'the closer is still waiting for the lock'
          refute(run.reload.journal.entries.any? { |e| e['kind'] == 'seats_closed' }, 'the close waits for the lock')
          go_w.write('g')
          go_w.close
          statuses = pids.map { |pid| Process.wait2(pid).last }
          pids.clear
          assert statuses.all?(&:success?), statuses.inspect
          e = run.reload.journal.entries
          launched = e.find { |x| x['kind'] == 'seat_launched' && x['tool_use_id'] == 'toolu_race' }
          closed = e.find { |x| x['kind'] == 'seats_closed' }
          assert_operator launched['seq'], :<, closed['seq']
          assert_empty Seats.unsettled_launches(e), 'the launch admitted before the close is settled by it'
        ensure
          go_w.close if go_w && !go_w.closed?
          Array(pids).each do |pid|
            Process.kill('KILL', pid)
            Process.wait(pid)
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          end
        end

        def test_a_close_that_fails_is_journaled_and_the_settled_replies_are_still_submitted
          run = start_review
          answer_seat(run, 'architect', 1, REVISE)
          host_subagent('a2', 'toolu_2', launch(run, 'security', 'toolu_2').dig('hookSpecificOutput', 'updatedInput', 'prompt'))
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = collect_reply
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          original = Seats.method(:settle_remaining)
          Seats.define_singleton_method(:settle_remaining) { |*_a| raise Errno::ENOSPC, 'seats.lock' }
          begin
            t = Seats.cutoff_of(dispatch_entry(run)) + 1
            rv = review_for(run, clock: -> { t }, sleep: ->(_s) {})
            rv.collect(run.plan.phase(:design_review), rv.pending_round('design_review'))
            e = run.reload.journal.entries
            assert(e.any? { |x| x['kind'] == 'seats_close_failed' && x['token'] == TOKEN })
            refute(e.any? { |x| x['kind'] == 'seat_submission_failed' }, 'a failed close is not a parse failure')
            sub = @invoked.find { |n, _| n == 'multi_llm_review_collect' }.last['orchestrator_reviews']
            assert_equal %w[architect], sub.map { |r| r['persona'] }
            r = e.find { |x| x['kind'] == 'review_round' }
            assert_equal 'not_settled', r['personas'].find { |o| o['persona'] == 'security' }['cause']
          ensure
            Seats.define_singleton_method(:settle_remaining, original)
          end
        end

        def test_a_close_that_fails_at_agent_stop_is_journaled_and_the_stop_stands
          run = start_review
          launch(run, 'architect', 'toolu_1')
          original = Seats.method(:settle_remaining)
          Seats.define_singleton_method(:settle_remaining) { |*_a| raise Errno::ENOSPC, 'seats.lock' }
          begin
            out = service.stop('run_id' => run.id, 'reason' => 'enough', '_session_id' => 's1')
          ensure
            Seats.define_singleton_method(:settle_remaining, original)
          end
          assert_equal 'stopped', out['status']
          e = run.reload.journal.entries
          assert(e.any? { |x| x['kind'] == 'seats_close_failed' && x['token'] == TOKEN })
          assert(e.index { |x| x['kind'] == 'run_ended' } < e.index { |x| x['kind'] == 'seats_close_failed' })
        end

        def test_a_launch_inside_the_collect_window_is_refused_so_none_outlives_the_round
          run = start_review
          answer_seat(run, 'architect', 1, APPROVE)
          launch(run, 'security', 'toolu_2')
          Seats.settle_remaining(run, TOKEN)
          e = run.reload.journal.entries
          assert(e.any? { |x| x['kind'] == 'seats_closed' && x['token'] == TOKEN && x['phase'] == 'design_review' })
          assert_empty Seats.unsettled_launches(e)
          late = launch(run, 'operability', 'toolu_3')
          assert_equal 'deny', decision(late), 'no launch is admitted once the collect closed the seats'
          assert_includes late.dig('hookSpecificOutput', 'permissionDecisionReason'), 'closed its seats'
          assert_empty Seats.unsettled_launches(run.reload.journal.entries), 'so no launch outlives the round'
          assert_nil Seats.instruction(run, 'design_review'), 'and the guidance no longer asks for launches'
          Seats.settle_remaining(run, TOKEN)
          assert_equal 1, run.reload.journal.entries.count { |x| x['kind'] == 'seats_closed' }, 'closing twice journals once'
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = collect_reply
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          out = service.advance('run_id' => run.id, '_session_id' => 's1')
          refute_equal 'pending', out['status'], 'a closed round collects at once, without asking for its missing seats'
          after = launch(run, 'operability', 'toolu_4')
          assert_includes after.dig('hookSpecificOutput', 'permissionDecisionReason'), 'its round has already collected'
          r = run.reload.journal.entries.find { |x| x['kind'] == 'review_round' }
          assert_equal({ 'security' => 'not_settled', 'operability' => 'not_launched' },
                       r['personas'].reject { |o| o['submitted'] }.to_h { |o| [o['persona'], o['cause']] })
        end

        def test_past_the_cutoff_no_seat_is_instructed_or_launched_and_the_stop_hook_still_holds
          run = start_review(must_collect_by: Time.now + Seats::CUTOFF_SECONDS - 60)
          assert_empty Seats.live_markers(run.id, run.journal.entries)
          assert_nil Seats.instruction(run, 'design_review')
          late = launch(run, 'architect', 'toolu_1')
          assert_equal 'deny', decision(late)
          assert_includes late.dig('hookSpecificOutput', 'permissionDecisionReason'), 'past its cutoff'
          refute(run.reload.journal.entries.any? { |x| x['kind'] == 'seat_launched' })
          out = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x', 'background_tasks' => [{ 'id' => 'b' }])
          assert_equal 'block', out&.dig('decision'), 'between the cutoff and expiry the actor is held on agent_advance'
          assert_includes out['reason'], 'to collect it'
          refute_includes out['reason'], marker(run, 'architect')
        end

        def test_after_token_expiry_the_hold_ends_and_the_round_blocks_once_per_progress
          run = start_review(must_collect_by: Time.now - 1)
          assert_nil Seats.holding_dispatch(run.journal.entries)
          assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x', 'background_tasks' => [{ 'id' => 'b' }]),
                     'an expired dispatch no longer keeps background tasks from letting the actor rest'
          first = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x')
          assert_equal 'block', first&.dig('decision')
          assert_equal 'review_in_flight', run.reload.journal.entries.reverse.find { |x| x['kind'] == 'stop_blocked' }['for']
          assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x'), 'and not again without progress'
        end

        def test_a_seat_launching_or_settling_does_not_restart_the_three_block_hold
          run = start_review
          3.times { assert_equal 'block', hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x')&.dig('decision') }
          answer_seat(run, 'architect', 1, APPROVE)
          once = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x')
          assert_equal 'block', once&.dig('decision'), 'a seat answering is progress: one block, as for any progress'
          assert_equal 'review_in_flight', run.reload.journal.entries.reverse.find { |x| x['kind'] == 'stop_blocked' }['for']
          assert_nil hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x'),
                     'not three more: a seat answering is not the actor calling agent_advance'
          run.append(:seats_waited, phase: 'design_review', round: 1, token: TOKEN, running: 2)
          assert_equal 'block', hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'x')&.dig('decision')
        end

        def test_agent_stop_closes_the_seats_of_a_round_that_never_collects
          run = start_review
          prompt = launch(run, 'architect', 'toolu_1').dig('hookSpecificOutput', 'updatedInput', 'prompt')
          host_subagent('a1', 'toolu_1', prompt)
          assert_equal 'deny', decision(pre('TaskStop', 'tool_input' => { 'task_id' => 'bash_7' }))
          assert_equal 'stopped', service.stop('run_id' => run.id, 'reason' => 'enough', '_session_id' => 's1')['status']
          e = run.reload.journal.entries
          assert(e.any? { |x| x['kind'] == 'seats_closed' && x['token'] == TOKEN })
          assert_equal 'not_settled', e.find { |x| x['kind'] == 'seat_settled' && x['persona'] == 'architect' }['cause']
          refute_equal 'deny', decision(pre('TaskStop', 'tool_input' => { 'task_id' => 'bash_7' })),
                       'the actor may stop its own shells again'
          assert_equal 'deny', decision(seat_call('a1', 'Bash', 'command' => 'ls')), 'the seat itself stays a seat'
        end

        def test_a_seat_launched_through_the_task_tool_is_rewritten_too
          run = start_review
          out = pre('Task', 'tool_use_id' => 'toolu_t', 'tool_input' => { 'prompt' => marker(run, 'security'), 'description' => 'x' })
          assert_equal 'allow', decision(out), out.inspect
          assert_includes out.dig('hookSpecificOutput', 'updatedInput', 'prompt'), 'Persona seat: security'
          assert_equal 'security', run.reload.journal.entries.find { |x| x['kind'] == 'seat_launched' }['persona']
        end

        def test_seats_that_cannot_be_composed_leave_the_round_as_1_0_1_ran_it_and_the_report_says_why
          original = Seats.method(:compose)
          Seats.define_singleton_method(:compose) { |**_kw| raise IOError, 'bundle unreadable' }
          begin
            run = start_review
          ensure
            Seats.define_singleton_method(:compose, original)
          end
          req = @invoked.find { |n, _| n == 'multi_llm_review' }.last
          assert_equal 0, req['persona_count_declared']
          refute req.key?('collect_deadline_seconds_override')
          refute dispatch_entry(run).key?('seats')
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = collect_reply
          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          service.advance('run_id' => run.id, '_session_id' => 's1')
          assert_equal [], @invoked.find { |n, _| n == 'multi_llm_review_collect' }.last['orchestrator_reviews']
          notes = service.send(:report_material, run.reload)['not_checked']
          assert(notes.any? { |n| n.include?('no persona seats were convened') && n.include?('bundle unreadable') }, notes.inspect)
        end
      end
    end
  end
end
