# frozen_string_literal: true

# Regression tests for the implementation review R1 (2026-10-20), review
# group: review closure (INV-3) in lib/agent/review.rb, driven through
# Service#advance with the review tools and the stand-in scripted.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'fileutils'
require_relative '../lib/agent/service'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R1Review < Minitest::Test
        # A stand-in that answers from a script and records what it was asked.
        class Scripted
          attr_reader :asked

          def initialize(script)
            @script = script
            @asked = []
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
            @asked << { point: point, question: question, options: options, evidence: evidence,
                        precedents: precedents, operator_words: operator_words }
            reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
            reply = reply.call(question) if reply.is_a?(Proc)
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

        POLICY = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 8, stand_in_calls: 100 }
          end
        RUBY

        NO_CONSENT = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            spend default: { review_rounds: 8, stand_in_calls: 100 }
          end
        RUBY

        ONE_ROUND_SPEND = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 1, stand_in_calls: 100 }
          end
        RUBY

        def setup
          @root = File.realpath(Dir.mktmpdir('a1r1'))
          @saved_global = ENV['KAIROS_AGENT_GLOBAL']
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@root, 'global_bound_sessions.txt')
          @data = File.join(@root, '.kairos')
          @paths = Paths.new(@data)
          FileUtils.mkdir_p(@paths.policies_dir)
          FileUtils.mkdir_p(File.join(@root, 'log'))
          use_policy(POLICY)
          @script = {}
          @stand_in = Scripted.new(@script)
          @chain = []
          @invoked = []
          @mlr = {}
          @tok = 0
          @transcript = File.join(@root, 'transcript.jsonl')
          File.write(@transcript, '')
          Precedents.new(@paths.precedents_dir).add([{ 'source' => 'seed', 'project' => 'x', 'at' => '2026-10-01',
                                                       'kind' => 'typed_answer', 'question' => '査読は何周?',
                                                       'words' => '収束するまで回して' }])
          @seed_id = Precedents.new(@paths.precedents_dir).all.first['id']
        end

        def teardown
          Run.all(@paths).each { |r| FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', r.id)) } if @paths
          FileUtils.rm_rf(@root)
          ENV['KAIROS_AGENT_GLOBAL'] = @saved_global
        end

        # --- harness -------------------------------------------------------------

        def use_policy(src)
          File.write(File.join(@paths.policies_dir, 'p1.rb'), src)
          @policy = DSL.parse_policy(src)
        end

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
                      invoke: lambda { |name, args|
                        @invoked << [name, args]
                        @mlr.fetch(name) { {} }
                      },
                      chain: ->(logs) { @chain << logs; @chain.size }, run_cmd: run_cmd)
        end

        def hooks
          Hooks.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in })
        end

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
          out = service.items('action' => 'adopt_policy', 'policy' => 'p1')
          assert_equal 'adopted', out['status'], out.inspect
        end

        def start!(extra = {})
          adopt!
          typed('設計だけ進めて。席は Fable も入れて', 'pr2')
          args = via_hook('s1', 'agent_start', { 'goal' => 'design the thing', 'template' => 'design_only',
                                                 'design_glob' => 'log/thing_design_v*.md' }.merge(extra))
          out = service.start(args)
          assert_equal 'started', out['status'], out.inspect
          hooks.handle('PostToolUse', 'session_id' => 's1', 'tool_name' => 'mcp__kairos-chain__agent_start',
                                      'transcript_path' => @transcript,
                                      'tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }])
          Run.load(@paths, out['run_id'])
        end

        def advance(run)
          service.advance('run_id' => run.id, '_session_id' => 's1')
        end

        # The design phase ends on its own check: a design file the run wrote.
        def finish_design!(run, topic = 'thing')
          path = File.join(@root, 'log', "#{topic}_design_v0.1.md")
          out = hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Write',
                                           'tool_input' => { 'file_path' => path, 'content' => 'x' }, 'cwd' => @root)
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
          File.write(path, "# Design v0.1\nINV-1 the thing holds.\n")
          res = advance(run)
          assert_equal 'phase_ended', res['status'], res.inspect
        end

        def seats(*specs)
          specs.map { |l, v| { 'role_label' => l, 'verdict' => v, 'raw_text' => "#{l} reply.\nOverall Verdict: #{v}" } }
        end

        def two_approve
          seats(%w[codex APPROVE], %w[sonnet APPROVE])
        end

        def p0(seat, text, label: 'new', earlier: nil, grounds: nil)
          { 'seat' => seat, 'text' => text, 'label' => label, 'earlier_id' => earlier, 'grounds' => grounds }.compact
        end

        # One review round: dispatch, then collect (which labels it at once).
        # A later round reviews a new version (an unchanged artifact is not
        # sent again after a quorate round).
        def new_version!(run)
          n = run.reload.journal.entries.count { |e| e['kind'] == 'review_round' }
          return if n.zero?

          path = File.join(@root, 'log', "thing_design_v0.#{n + 1}.md")
          hooks.handle('PreToolUse', 'session_id' => 's1', 'tool_name' => 'Write', 'cwd' => @root,
                                     'tool_input' => { 'file_path' => path, 'content' => 'x' })
          File.write(path, "# thing v0.#{n + 1}\n")
        end

        def round!(run, labels:, reviews: two_approve, counted: 2, quorum: 2, wait: 'ready')
          new_version!(run)
          @mlr['multi_llm_review'] = { 'collect_token' => "tok#{@tok += 1}" }
          d = advance(run)
          assert_equal 'dispatched', d['status'], d.inspect
          collect!(run, labels: labels, reviews: reviews, counted: counted, quorum: quorum, wait: wait)
        end

        def collect!(run, labels:, reviews: two_approve, counted: 2, quorum: 2, wait: 'ready')
          @mlr['multi_llm_review_wait'] = { 'status' => wait }
          tally = { 'successful_count' => counted }
          tally['min_quorum'] = quorum if quorum
          @mlr['multi_llm_review_collect'] = { 'status' => 'ok', 'reviews' => reviews, 'vote_tally' => tally }
          @script['review_labels'] = labels.is_a?(Hash) ? labels : { 'answer' => labels, 'class' => 'decided' }
          advance(run)
        end

        def dispatches
          @invoked.count { |n, _| n == 'multi_llm_review' }
        end

        def last_asked(point)
          @stand_in.asked.reverse.find { |a| a[:point] == point }
        end

        def open_of(run, kind)
          run.reload.open_items.select { |i| i['item_kind'] == kind }
        end

        # The rounds this review may take: the policy's cap for each review plus
        # the rounds the operator granted it.
        def review_cap(run, phase)
          run.reload.spend['review_rounds'].to_i + run.round_extensions[phase.to_s].to_i
        end

        def entries(run, kind)
          run.reload.journal.entries.select { |e| e['kind'] == kind }
        end

        def by_id(out)
          Array(out['labels'] || out['open_p0']).to_h { |l| [l['id'], l] }
        end

        # A run whose design review has had the policy's one round for each
        # review, with one open P0. The stand-in is not asked anything at the
        # cap; `stand_in_says` is what it would have answered, scripted to show
        # it is never consulted.
        def at_bound!(stand_in_says = nil)
          use_policy(ONE_ROUND_SPEND)
          run = start!
          finish_design!(run)
          @script['round_bound'] = stand_in_says if stand_in_says
          out = round!(run, labels: [p0('codex', 'The removal path loses 0.x storage on upgrade')])
          [run, out]
        end

        def operator_resolves!(run, ref, words, decision:, rounds: nil)
          pid = "op_#{ref}_#{decision}"
          typed(words, pid)
          hooks.handle('UserPromptSubmit', 'session_id' => 's1', 'prompt' => words, 'prompt_id' => pid,
                                           'transcript_path' => @transcript)
          service.items(via_hook('s1', 'agent_items', { 'action' => 'resolve', 'run_id' => run.id, 'ref' => ref,
                                                        'decision' => decision, 'rounds' => rounds }.compact))
        end

        def git!(dir, *args)
          system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', *args, exception: true)
        end

        # --- labelling ---------------------------------------------------------

        def test_label_variants_are_normalised_and_unknown_labels_stay_open
          run = start!
          finish_design!(run)
          out = round!(run, labels: [p0('codex', 'a', label: 'New'), p0('codex', 'b', label: 'Carried over'),
                                     p0('sonnet', 'c', label: 'open'), p0('sonnet', 'd', label: 'looks resolved'),
                                     { 'seat' => 'sonnet', 'text' => 'e' }, 'not a hash'])
          assert_equal 'open', out['status'], out.inspect
          labels = by_id(out)
          assert_equal({ 'DR1.F1' => 'new', 'DR1.F2' => 'carried_over', 'DR1.F3' => 'carried_over',
                         'DR1.F4' => 'new', 'DR1.F5' => 'new', 'DR1.F6' => 'new' },
                       labels.transform_values { |l| l['label'] })
          assert(labels.values.all? { |l| l['open'] }, 'every variant and every unknown label stays open')
          assert_equal 'Carried over', labels['DR1.F2']['label_given']
          refute run.reload.phases.dig('design_review', 'status') == 'ended'

          grounds = 'The design states in section 2 that this path is never taken.'
          out = round!(run, labels: [p0('codex', 'a', label: 'FIXED', earlier: 'DR1.F1'),
                                     p0('codex', 'b', label: ' Fixed ', earlier: 'DR1.F2'),
                                     p0('sonnet', 'c', label: 'fixed', earlier: 'DR1.F3'),
                                     p0('sonnet', 'd', label: 'REFUTED', earlier: 'DR1.F4', grounds: grounds),
                                     p0('sonnet', 'e', label: 'Refuted', earlier: 'DR1.F5', grounds: grounds),
                                     p0('', '', label: 'fixed', earlier: 'DR1.F6')])
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal %w[fixed fixed fixed refuted refuted fixed], out['labels'].map { |l| l['label'] }
        end

        def test_refuted_without_grounds_stays_open
          run = start!
          finish_design!(run)
          out = round!(run, labels: [p0('codex', 'x', label: 'refuted'),
                                     p0('sonnet', 'y', label: 'refuted', grounds: 'it is wrong.')])
          assert_equal 'open', out['status'], out.inspect
          assert_equal %w[new new], out['open_p0'].map { |l| l['label'] }

          out = round!(run, labels: [p0('codex', 'x', label: 'refuted', earlier: 'DR1.F1', grounds: '  '),
                                     p0('sonnet', 'y', label: 'refuted', earlier: 'DR1.F2',
                                                       grounds: 'The seat misread the lock order; section 3 serialises it.')])
          assert_equal 'open', out['status'], out.inspect
          assert_equal [%w[DR1.F1 carried_over]], out['open_p0'].map { |l| [l['id'], l['label']] },
                       'only the refutation with grounds closes its P0'
        end

        def test_fixed_without_an_earlier_id_stays_open
          run = start!
          finish_design!(run)
          out = round!(run, labels: [p0('codex', 'x', label: 'fixed'),
                                     p0('sonnet', 'y', label: 'fixed', earlier: 'DR0.F9')])
          assert_equal 'open', out['status'], out.inspect
          assert_equal [['new', nil], ['new', nil]], out['open_p0'].map { |l| [l['label'], l['earlier_id']] },
                       'a fix of nothing, or of an id that was never open, is a new finding'
        end

        def test_an_earlier_open_p0_the_labelling_did_not_address_is_carried_over
          run = start!
          finish_design!(run)
          round!(run, labels: [p0('codex', 'lock order', label: 'new'), p0('sonnet', 'quota leak', label: 'new')])
          out = round!(run, labels: [p0('codex', 'lock order', label: 'fixed', earlier: 'DR1.F1')])
          assert_equal 'open', out['status'], out.inspect
          left = out['open_p0']
          assert_equal %w[DR1.F2], left.map { |l| l['id'] }
          assert_equal 'carried_over', left.first['label']
          assert_equal '(not addressed by the labelling)', left.first['label_given']
          ev = last_asked('review_labels')[:evidence]
          assert_equal [%w[DR1.F1 codex], %w[DR1.F2 sonnet]], ev['earlier_open_p0'].map { |p| [p['id'], p['seat']] },
                       'the labelling sees each earlier P0 with its seat'

          out = round!(run, labels: [])
          assert_equal %w[DR1.F2], out['open_p0'].map { |l| l['id'] }, 'an empty labelling carries every open P0 over'
        end

        def test_a_reject_seat_with_no_p0_listed_is_an_open_finding
          run = start!
          finish_design!(run)
          out = round!(run, labels: [], reviews: seats(%w[codex REJECT], %w[sonnet APPROVE]))
          assert_equal 'open', out['status'], out.inspect
          assert_equal 1, out['open_p0'].size
          f = out['open_p0'].first
          assert_equal 'codex', f['seat']
          assert_includes f['text'], 'rejected with no P0 listed'
          refute_equal 'ended', run.reload.phases.dig('design_review', 'status')
        end

        def test_a_reject_seat_is_not_answered_by_a_finding_another_seat_raised
          run = start!
          finish_design!(run)
          grounds = 'The design already serialises the writers in section 4, so the race cannot occur.'
          out = round!(run, labels: [p0('claude', 'a race between writers', label: 'refuted', grounds: grounds)],
                            reviews: seats(%w[claude_cli_sonnet5.5 APPROVE], %w[claude_team_claude-opus-5-5 REJECT],
                                           %w[codex_gpt6-astra APPROVE]),
                            counted: 3)
          flunk('BUG: review.rb:289 same_seat? matches by substring, so a finding labelled seat "claude" silences ' \
               'the REJECT of claude_team_claude-opus-5-5 and the review closes') if out['status'] == 'closed_provisionally'
          assert_equal 'open', out['status'], out.inspect
          assert(out['open_p0'].any? { |l| l['seat'] == 'claude_team_claude-opus-5-5' })
        end

        # --- quorum and collection ---------------------------------------------

        def test_closure_needs_counted_at_least_quorum
          run = start!
          finish_design!(run)
          out = round!(run, labels: [], counted: 1, quorum: nil)
          assert_equal 'no_quorum', out['status'], 'one seat of a default quorum of two does not close'
          out = round!(run, labels: [], counted: 2, quorum: 3)
          assert_equal 'no_quorum', out['status'], out.inspect
          refute_equal 'ended', run.reload.phases.dig('design_review', 'status')
          out = round!(run, labels: [], counted: 3, quorum: 3)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal 3, out['round']
        end

        def test_a_crashed_or_heartbeat_stale_wait_still_collects_when_collect_is_ok
          run = start!
          finish_design!(run)
          @mlr['multi_llm_review'] = { 'collect_token' => 'tokA' }
          assert_equal 'dispatched', advance(run)['status']
          @mlr['multi_llm_review_wait'] = { 'status' => 'still_pending' }
          assert_equal 'pending', advance(run)['status']
          assert_equal 0, @invoked.count { |n, _| n == 'multi_llm_review_collect' }, 'a running round is not collected'

          out = collect!(run, labels: [p0('codex', 'x')], wait: 'crashed')
          assert_equal 'open', out['status'], out.inspect
          assert_equal 1, dispatches
          round1 = run.reload.journal.entries.find { |e| e['kind'] == 'review_round' }
          assert_equal 'crashed', round1['wait_status']

          new_version!(run)
          @mlr['multi_llm_review'] = { 'collect_token' => 'tokB' }
          assert_equal 'dispatched', advance(run)['status']
          out = collect!(run, labels: [p0('codex', 'x', label: 'fixed', earlier: 'DR1.F1')], wait: 'heartbeat_stale')
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal 2, dispatches, 'neither wait status redispatched its round'
          refute(run.reload.journal.entries.any? { |e| e['kind'] == 'review_dispatch_failed' })
        end

        def test_a_labelling_failure_keeps_the_round_and_relabels_without_a_new_dispatch
          run = start!
          finish_design!(run)
          @mlr['multi_llm_review'] = { 'collect_token' => 'tokL' }
          assert_equal 'dispatched', advance(run)['status']
          failed = collect!(run, labels: { 'answer' => nil, 'class' => 'operator_item' },
                                 reviews: seats(%w[codex APPROVE], %w[sonnet APPROVE]))
          assert_equal 'labelling_failed', failed['status'], failed.inspect
          round = run.reload.journal.entries.find { |e| e['kind'] == 'review_round' }
          refute_nil round, 'the collected round is journaled before labelling'
          assert File.exist?(round['replies_file'])
          assert_equal 1, open_of(run, 'blocking').size

          @script['review_labels'] = { 'answer' => 'all fine', 'class' => 'decided' }
          again = advance(run)
          assert_equal 'labelling_failed', again['status'], 'a labelling that is not a list is a failure too'
          assert_equal failed['item'], again['item'], 'the same blocking item, not a second one'
          assert_equal 1, open_of(run, 'blocking').size

          @script['review_labels'] = { 'answer' => [], 'class' => 'decided' }
          out = advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal 1, dispatches, 'the round is labelled again, not dispatched again'
          assert_equal 1, @invoked.count { |n, _| n == 'multi_llm_review_collect' }, 'nor collected again'
          ev = last_asked('review_labels')[:evidence]
          assert_equal %w[codex sonnet], ev['seat_replies'].map { |s| s['seat'] }
          assert_includes ev['seat_replies'].first['reply'], 'Overall Verdict: APPROVE'
          assert_empty open_of(run, 'blocking'), 'the labelling item clears once the round is labelled'
        end

        # --- consent and spend ---------------------------------------------------

        def test_missing_review_consent_opens_one_blocking_item_and_dispatches_nothing
          use_policy(NO_CONSENT)
          run = start!
          finish_design!(run)
          first = advance(run)
          assert_equal 'refused', first['status'], first.inspect
          assert_equal 'the policy gives no review consent', first['reason']
          second = advance(run)
          assert_equal first['item'], second['item']
          assert_equal 1, open_of(run, 'blocking').size
          assert_equal 0, dispatches
          assert_nil last_asked('data_check'), 'no bundle is even composed for checking'
        end

        def test_the_review_round_cap_makes_the_review_wait_with_one_review_open_item_and_dispatches_nothing
          use_policy(ONE_ROUND_SPEND)
          run = start!
          finish_design!(run)
          waited = round!(run, labels: [p0('codex', 'x')])
          assert_equal 'waiting', waited['status'], waited.inspect
          assert_equal [waited['item']], open_of(run, 'review_open').map { |i| i['id'] }
          assert_equal "design_review is open (1 P0) and has had its 1 rounds; it waits for the operator " \
                       '(decision more_rounds, or freeze)', run.items[waited['item']]['text']
          assert_equal ['codex'], waited['labels'].map { |l| l['seat'] }, 'the reply carries the labelled round'
          first = advance(run)
          assert_equal 'waiting', first['status'], 'a dispatch at the cap waits too; it is no longer a refusal: ' + first.inspect
          assert_equal 'design_review is at its round cap; it waits for the operator', first['reason']
          assert_equal waited['item'], first['item'], 'the same review_open item, not a second one'
          second = advance(run)
          assert_equal waited['item'], second['item']
          assert_equal 1, open_of(run, 'review_open').size
          assert_empty open_of(run, 'blocking'), 'no blocking item is opened for the bound any more'
          assert_equal 1, dispatches
        end

        # --- the policy's rounds for each review are the cap -------------------------

        def test_at_the_round_cap_the_review_waits_with_a_review_open_item_and_round_bound_is_never_asked
          run, out = at_bound!('answer' => 'freeze_provisionally', 'class' => 'decided_novel', 'basis' => [@seed_id])
          assert_equal 'waiting', out['status'], out.inspect
          assert_equal [out['item']], open_of(run, 'review_open').map { |i| i['id'] }
          assert_empty open_of(run, 'carried_p0')
          refute_equal 'ended', run.phases.dig('design_review', 'status')
          assert_empty run.provisional_closures
          assert_nil last_asked('round_bound'), 'nothing asks the stand-in whether to freeze at the bound'
          refute(@stand_in.asked.any? { |a| a[:point] == 'round_bound' })
          again = advance(run)
          assert_equal 'waiting', again['status']
          assert_equal out['item'], again['item']
          assert_equal 1, dispatches, 'nothing is dispatched past the bound'
          assert_nil last_asked('round_bound')
        end

        def test_no_stand_in_answer_can_end_a_review_at_the_round_cap_and_none_is_recorded
          run, out = at_bound!('answer' => 'freeze_provisionally', 'class' => 'decided',
                               'basis' => ['instruction_mode', 'P000000000000'])
          assert_equal 'waiting', out['status'], out.inspect
          assert_equal 1, open_of(run, 'review_open').size
          assert_empty open_of(run, 'carried_p0')
          refute_equal 'ended', run.phases.dig('design_review', 'status')
          refute(run.reload.decisions.any? { |d| d['point'] == 'round_bound' }, 'no round_bound decision is in the journal')
          assert_equal %w[data_check review_labels], run.decisions.map { |d| d['point'] }.uniq.sort
        end

        def test_an_operator_freeze_at_the_round_cap_ends_the_phase_and_carries_its_p0s
          run, out = at_bound!
          assert_equal 'waiting', out['status'], out.inspect
          item = out['item']
          res = operator_resolves!(run, item, "#{item} はこのまま凍結でいい", decision: 'freeze')
          assert_equal 'recorded', res['status'], res.inspect
          run.reload
          assert_equal 'ended', run.phases.dig('design_review', 'status')
          assert_equal 'operator', run.phases.dig('design_review', 'by')
          assert_empty run.provisional_closures, 'an operator freeze is not provisional'
          carried = open_of(run, 'carried_p0')
          assert_equal 1, carried.size
          assert_equal 'The removal path loses 0.x storage on upgrade', carried.first.dig('detail', 'text')
          assert_equal 'codex', carried.first.dig('detail', 'seat')
          assert_equal 'design_review', carried.first.dig('state_ref', 'ref')
          assert_empty open_of(run, 'review_open')
          assert_nil last_asked('round_bound')
        end

        def test_no_quorum_at_the_round_cap_is_no_quorum_and_the_next_dispatch_waits
          use_policy(ONE_ROUND_SPEND)
          run = start!
          finish_design!(run)
          out = round!(run, labels: [], counted: 1, quorum: 2)
          assert_equal 'no_quorum', out['status'], 'a round without quorum is not a round that waits: ' + out.inspect
          assert_empty open_of(run, 'review_open')
          refute_equal 'ended', run.phases.dig('design_review', 'status')
          next_try = advance(run)
          assert_equal 'waiting', next_try['status'], next_try.inspect
          assert_equal 'design_review is at its round cap; it waits for the operator', next_try['reason']
          assert_equal 1, open_of(run, 'review_open').size
          assert_equal 1, dispatches
          assert_nil last_asked('round_bound'), 'the bound is not the stand-in\'s to freeze'
        end

        # A real git repository for a dev_cycle run (design, then implementation).
        def dev_cycle_repo!
          saved = ENV.to_h.slice('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM')
          ENV['GIT_CONFIG_GLOBAL'] = File::NULL
          ENV['GIT_CONFIG_NOSYSTEM'] = '1'
          system('git', '-C', @root, 'init', '-q', '-b', 'main', exception: true)
          FileUtils.mkdir_p(File.join(@root, 'test'))
          File.write(File.join(@root, 'test', 'test_ok.rb'), "exit 0\n")
          File.write(File.join(@root, '.gitignore'), ".kairos/\nlog/\n.claude/\ntranscript.jsonl\nglobal_bound_sessions.txt\n")
          git!(@root, 'add', '.')
          git!(@root, 'commit', '-q', '-m', 'init')
          saved
        end

        def restore_git_env(saved)
          saved&.then { |s| %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].each { |k| ENV[k] = s[k] } }
        end

        def commit_implementation!(run)
          File.write(File.join(run.worktree, 'impl.rb'), "X = 1\n")
          git!(run.worktree, 'add', '.')
          git!(run.worktree, 'commit', '-q', '-m', 'implement')
          checked = advance(run)
          assert_equal 'phase_ended', checked['status'], checked.inspect
          assert_equal 'implementation_review', run.reload.current_phase
        end

        def test_a_deferred_design_finding_reaches_the_next_review_phase_bundle_and_labelling
          skip 'sandbox-exec unavailable' unless Confinement.available?
          saved = dev_cycle_repo!
          run = start!('template' => 'dev_cycle', 'design_glob' => 'log/g_design_v*.md', 'tests' => 'test')
          finish_design!(run, 'g')
          grounds = 'It concerns only how the removal is implemented, not what the design requires of it.'
          closed = round!(run, labels: [p0('codex', 'The removal path loses 0.x storage on upgrade', label: 'deferred', grounds: grounds)])
          assert_equal 'closed_provisionally', closed['status'], 'a deferred P0 is not open: ' + closed.inspect
          carried = open_of(run, 'carried_p0')
          assert_equal 1, carried.size
          assert_equal true, carried.first.dig('detail', 'deferred')
          cid = carried.first['id']

          commit_implementation!(run)
          out = round!(run, labels: [])
          sent = @invoked.select { |n, _| n == 'multi_llm_review' }.last.last
          assert_equal 'implementation', sent['review_type']
          assert_includes sent['artifact_content'], "[#{cid}] [codex] The removal path loses 0.x storage on upgrade"
          assert_equal [cid], sent['prior_findings'].map { |f| f['id'] }
          ev = last_asked('review_labels')[:evidence]
          assert_equal [cid], ev['earlier_open_p0'].map { |p| p['id'] }
          assert_equal 'open', out['status'], out.inspect
          assert_equal [[cid, 'carried_over']], out['open_p0'].map { |l| [l['id'], l['label']] },
                       'the implementation review cannot close past a deferred P0 it did not answer'
        ensure
          restore_git_env(saved)
        end

        def test_operator_frozen_open_p0s_stay_open_items_and_do_not_reach_the_next_review_phase
          skip 'sandbox-exec unavailable' unless Confinement.available?
          saved = dev_cycle_repo!
          use_policy(ONE_ROUND_SPEND)
          run = start!('template' => 'dev_cycle', 'design_glob' => 'log/g_design_v*.md', 'tests' => 'test')
          finish_design!(run, 'g')
          waited = round!(run, labels: [p0('codex', 'The removal path loses 0.x storage on upgrade')])
          assert_equal 'waiting', waited['status'], waited.inspect
          res = operator_resolves!(run, waited['item'], "#{waited['item']} はこのまま凍結でいい", decision: 'freeze')
          assert_equal 'recorded', res['status'], res.inspect
          carried = open_of(run, 'carried_p0')
          assert_equal 1, carried.size
          cid = carried.first['id']
          assert_nil carried.first.dig('detail', 'deferred'), 'a freeze is not a deferral'

          commit_implementation!(run)
          # The design review used its one round; the implementation review has
          # its own, so it dispatches without the operator.
          out = round!(run, labels: [])
          assert_equal 2, dispatches
          sent = @invoked.select { |n, _| n == 'multi_llm_review' }.last.last
          assert_equal 'implementation', sent['review_type']
          refute_includes sent['artifact_content'], 'The removal path loses 0.x storage on upgrade'
          assert_empty sent['prior_findings'], 'a frozen P0 is not sent to the seats again'
          assert_empty last_asked('review_labels')[:evidence]['earlier_open_p0'], 'nor shown to the labelling'
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal [cid], open_of(run, 'carried_p0').map { |i| i['id'] }, 'it stays an open operator item on the report'
        ensure
          restore_git_env(saved)
        end

        # --- the operator's resolution -------------------------------------------

        def test_the_operator_resolving_review_open_with_freeze_ends_the_phase
          run, out = at_bound!
          assert_equal 'waiting', out['status'], out.inspect
          item = out['item']
          res = operator_resolves!(run, item, "#{item} はこのまま凍結でいい", decision: 'freeze')
          assert_equal 'recorded', res['status'], res.inspect
          run.reload
          assert_equal 'resolved', run.items.dig(item, 'state')
          assert_equal 'ended', run.phases.dig('design_review', 'status')
          assert_equal 'operator', run.phases.dig('design_review', 'by')
          assert_nil run.current_phase
        end

        def test_the_operator_resolving_review_open_with_more_rounds_extends_that_reviews_cap
          run, out = at_bound!
          item = out['item']
          assert_equal 1, review_cap(run, 'design_review')
          res = operator_resolves!(run, item, "#{item} はもう 1 周回して", decision: 'more_rounds', rounds: 1)
          assert_equal 'recorded', res['status'], res.inspect
          run.reload
          assert_equal 1, run.spend['review_rounds'], 'the policy\'s rounds are not changed by it'
          assert_equal 1, run.round_extensions['design_review']
          assert_equal 2, review_cap(run, 'design_review'), 'more_rounds extends the cap of this review'
          assert_empty entries(run, 'spend_extended'), 'no run-wide spend grows'
          refute_equal 'ended', run.phases.dig('design_review', 'status')
          out = round!(run, labels: [p0('codex', 'The removal path loses 0.x storage on upgrade',
                                        label: 'fixed', earlier: 'DR1.F1')])
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal 2, out['round']
        end

        def test_a_resolution_naming_no_freeze_does_not_end_the_review
          run, out = at_bound!
          item = out['item']
          res = operator_resolves!(run, item, "#{item} は見た。どうするかは後で決める", decision: nil)
          assert_equal 'recorded', res['status'], res.inspect
          ended = run.reload.phases.dig('design_review', 'status') == 'ended'
          flunk('BUG: service.rb:550-555 any review_open resolution whose decision is not "more_rounds" (omitted, ' \
               'a typo, or action "confirm") ends the review phase by the operator, non-provisionally') if ended
          refute ended
          again = advance(run)
          assert_equal 'waiting', again['status'], 'the review stays open at its bound'
        end

        def test_a_run_ended_waiting_on_operator_items_is_reopened_by_the_resolution
          run, out = at_bound!
          item = out['item']
          first = hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Waiting.')
          assert_equal 'block', first['decision']
          hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'Waiting.')
          run.reload
          assert_equal 'ended', run.status
          assert_equal 'waiting on operator items', run.end_reason
          assert_equal 'refused', advance(run)['status']

          res = operator_resolves!(run, item, "#{item} はもう 1 周回して", decision: 'more_rounds', rounds: 1)
          assert_equal 'running', res['run_status'], res.inspect
          assert_nil run.reload.end_reason
          new_version!(run)
          @mlr['multi_llm_review'] = { 'collect_token' => 'tokR' }
          again = advance(run)
          assert_equal 'dispatched', again['status'], again.inspect
          assert_equal 2, again['round']
        end
      end
    end
  end
end
