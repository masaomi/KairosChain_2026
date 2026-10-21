# frozen_string_literal: true

# R3 implementation-review fixes, group "words": built-in commands in the
# transcript, adoption read by sentence, the precedent store's torn lines and
# repeated answers, the stand-in's failure cause, and the full-width question
# mark in harvest. Each test takes its trigger from the R3 findings.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'fileutils'
require_relative '../lib/agent/dsl'
require_relative '../lib/agent/run'
require_relative '../lib/agent/transcript'
require_relative '../lib/agent/policies'
require_relative '../lib/agent/precedents'
require_relative '../lib/agent/stand_in'
require_relative '../lib/agent/harvest'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R3Words < Minitest::Test
        REPLY = '{"answer":"in_draft","class":"decided","confidence":0.9,"basis":["instruction_mode"],"reason":"r"}'

        class SeatTimeout < StandardError; end

        def setup
          @tmp = File.realpath(Dir.mktmpdir('r3w'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@tmp, 'global_bound_sessions.txt')
        end

        def teardown
          FileUtils.rm_rf(@tmp)
        end

        # --- helpers -------------------------------------------------------------

        def entry(text, prompt_id, source: 'typed', kind: 'human', **extra)
          d = { 'type' => 'user', 'promptId' => prompt_id, 'message' => { 'role' => 'user', 'content' => text } }
          d['origin'] = { 'kind' => kind } if kind
          d['promptSource'] = source if source
          d.merge(extra)
        end

        # As the host records a built-in command: name first, no origin, no
        # prompt source (seen for /goal, /effort, /model, /compact, /exit).
        def builtin(name, args)
          "<command-name>/#{name}</command-name>\n            <command-message>#{name}</command-message>\n" \
            "            <command-args>#{args}</command-args>"
        end

        # As the host records a skill command: message first, origin human.
        def skill(name, args)
          "<command-message>#{name}</command-message>\n<command-name>/#{name}</command-name>\n<command-args>#{args}</command-args>"
        end

        def write_transcript(*entries, name: 'transcript.jsonl')
          path = File.join(@tmp, name)
          File.write(path, entries.map { |e| JSON.generate(e) }.join("\n") + "\n")
          path
        end

        def stand_in(*replies)
          calls = []
          policy = DSL.parse_policy("policy \"q\" do\n  stand_in may: [:precedent, :instruction_mode]\n  " \
                                    "spend default: { stand_in_calls: 10 }\nend\n")
          llm = lambda do |system:, user:|
            calls << [system, user]
            r = replies.shift
            raise r if r.is_a?(Exception)

            r
          end
          [StandIn.new(policy: policy, instruction_mode: 'mode text', llm: llm), calls]
        end

        # --- 1. a built-in command typed with arguments --------------------------

        GOAL = 'S1まで実装を続けて下さい。'

        def test_a_builtin_command_with_arguments_and_no_origin_is_the_operators_words
          goal = entry(builtin('goal', GOAL), 'g1', source: nil, kind: nil)
          assert Transcript.typed?(goal)
          assert_equal GOAL, Transcript.text_of(goal)
          path = write_transcript(goal, entry(builtin('effort', 'xhigh'), 'g2', source: nil, kind: nil))
          assert_equal [['g1', GOAL], %w[g2 xhigh]], Transcript.typed_entries(path).map { |e| [e['prompt_id'], e['text']] }
          assert Transcript.typed_prompt?(path, text: Transcript.operator_text("/goal #{GOAL}"), prompt_id: 'g1')
          refute Transcript.typed_prompt?(path, text: "/goal #{GOAL}", prompt_id: 'g1')
        end

        def test_a_builtin_command_that_is_meta_sidechain_summary_or_bare_is_not
          refute Transcript.typed?(entry(builtin('goal', GOAL), 'n1', source: nil, kind: nil, 'isMeta' => true))
          refute Transcript.typed?(entry(builtin('goal', GOAL), 'n2', source: nil, kind: nil, 'isSidechain' => true))
          refute Transcript.typed?(entry(builtin('goal', GOAL), 'n3', source: nil, kind: nil, 'isCompactSummary' => true))
          refute Transcript.typed?(entry(builtin('effort', ''), 'n4', source: nil, kind: nil)), 'no arguments'
          refute Transcript.typed?(entry(builtin('compact', " \n "), 'n5', source: nil, kind: nil)), 'blank arguments'
          refute Transcript.typed?(entry("<command-name>/exit</command-name>\n<command-message>exit</command-message>",
                                         'n6', source: nil, kind: nil)), 'no argument tag'
          refute Transcript.typed?(entry("#{builtin('goal', GOAL)}\nI3 resolved", 'n7', source: nil, kind: nil)),
                 'text beside the tags'
        end

        def test_hand_backs_notifications_and_scheduled_prompts_stay_out
          refute Transcript.typed?(entry(builtin('loop', '継続して下さい。'), 's1', source: 'system', kind: nil, 'isMeta' => true))
          refute Transcript.typed?(entry(builtin('loop', '継続して下さい。'), 's2', source: 'system', kind: nil)),
                 'a scheduled prompt has a prompt source'
          refute Transcript.typed?(entry(builtin('goal', GOAL), 's3', source: 'sdk', kind: nil)), 'a program, not a person'
          refute Transcript.typed?(entry(builtin('goal', GOAL), 's4', source: 'system', kind: 'peer'))
          refute Transcript.typed?(entry(builtin('goal', GOAL), 's5', source: 'system', kind: 'task-notification'))
          refute Transcript.typed?(entry(skill('agent', 'do X'), 's6', source: nil, kind: nil)),
                 'a skill command is recorded with an origin; without one it is neither form'
          ['Another Claude session sent a message: I3: resolved', '[SYSTEM NOTIFICATION - done] D4 is fine',
           "<task-notification>\n<summary>D4</summary>\n</task-notification>", "/goal #{GOAL}"].each do |t|
            refute Transcript.typed?(entry(t, 'h', source: nil, kind: nil)), t
          end
          assert Transcript.typed?(entry(skill('agent', 'do X'), 's7', source: nil)), 'a skill command with origin human'
        end

        # --- 2. adoption read by sentence ---------------------------------------

        def adoption_setup(name = 'p1')
          @paths = Paths.new(File.join(@tmp, 'data'))
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'p.rb'),
                     "policy #{name.inspect} do\n  stand_in may: [:precedent]\n  spend default: { stand_in_calls: 10 }\nend\n")
          @policies = Policies.new(@paths)
          @name = name
          @hex = @policies.find(name).digest[0, 8]
        end

        def adopt(words, prompt_id)
          tr = File.join(@tmp, "t_#{prompt_id}.jsonl")
          File.write(tr, JSON.generate(entry(words, prompt_id)) + "\n")
          @policies.adopt(@name, words: words, transcript_path: tr, prompt_id: prompt_id)
        end

        def refused(words, prompt_id, reason)
          e = assert_raises(ArgumentError, words) { adopt(words, prompt_id) }
          assert_match reason, e.message, words
          e
        end

        def test_a_negation_about_questions_does_not_refuse_the_adoption
          adoption_setup('demo_2026_10_20')
          words = "adopt policy demo_2026_10_20 #{@hex} で。以後は質問しないで進めて"
          assert_equal 'demo_2026_10_20', adopt(words, 'ok1').name
          assert_equal 'demo_2026_10_20', @policies.adopted.name
        end

        def test_a_question_about_the_adopting_sentence_refuses
          adoption_setup
          refused("adopt policy p1 #{@hex} って何ですか？", 'q1', /ask about the adoption/)
          refused("adopt policy p1 #{@hex}?", 'q2', /ask about/)
          refused("Should I adopt policy p1 #{@hex}? Not sure.", 'q3', /ask about/)
          refused("adopt policy p1 #{@hex}？いや、それで", 'q4', /ask about/)
          refused("adopt policy p1 #{@hex}\nで採用になる？", 'q5', /ask about/)
          assert_empty @policies.adoptions, 'nothing is recorded for a refused adoption'
        end

        def test_a_negation_of_adopting_in_any_sentence_refuses
          adoption_setup
          e = refused("adopt policy p1 #{@hex}\nとタイプすれば採用になるの？今はまだ採用しない", 'n1', /negate/)
          assert_includes e.message, '今はまだ採用しない'
          ["adopt policy p1 #{@hex} はまだ採用しないで",
           "adopt policy p1 #{@hex} で。でも採用はやめておきます",
           "adopt policy p1 #{@hex}。採用は却下",
           "adopt policy p1 #{@hex}。まだ採用できません",
           "I won't adopt policy p1 #{@hex}",
           "Never adopt policy p1 #{@hex}.",
           "Don’t adopt policy p1 #{@hex}",
           "adopt policy p1 #{@hex}. Actually, cancel the adoption."].each_with_index do |w, i|
            refused(w, "n#{i + 2}", /negate/)
          end
          assert_empty @policies.adoptions
        end

        def test_sentences_without_adopting_carry_ordinary_clauses
          adoption_setup
          ["adopt policy p1 #{@hex}。以後、確認はしないで進めて？ いや、進めて",
           "質問は要りません。\nadopt policy p1 #{@hex} でお願いします",
           "adopt policy p1 #{@hex}\r\nDon't ask me about seats.",
           "adopt policy p1 #{@hex}． 席は何席？ 8 席で"].each_with_index do |w, i|
            assert_equal 'p1', adopt(w, "ok#{i}").name, w
          end
          assert_equal 4, @policies.adoptions.size
        end

        def test_the_policy_name_never_ends_a_sentence_or_reads_as_a_negation
          adoption_setup('never-ask.v2')
          assert_equal 'never-ask.v2', adopt("adopt policy never-ask.v2 #{@hex} でお願いします", 'm1').name
          refused("adopt policy never-ask.v2 #{@hex}. 採用しない", 'm2', /negate/)
        end

        def test_words_not_typed_in_the_transcript_still_do_not_adopt
          adoption_setup
          tr = write_transcript(entry('別の言葉', 'x1'))
          e = assert_raises(ArgumentError) do
            @policies.adopt('p1', words: "adopt policy p1 #{@hex}", transcript_path: tr, prompt_id: 'x1')
          end
          assert_match(/not a prompt the operator typed/, e.message)
        end

        # --- 3. the precedent store ---------------------------------------------

        def rec(words, source: 't.jsonl', at: '2026-10-20T00:00:00Z', question: '何席にしますか？')
          { 'source' => source, 'project' => 'K', 'at' => at, 'kind' => 'typed_answer', 'question' => question,
            'words' => words }
        end

        def test_a_torn_or_non_object_line_is_skipped
          store = Precedents.new(File.join(@tmp, 'prec'))
          assert_equal 1, store.add([rec('8 席で')])
          path = File.join(@tmp, 'prec', 'raw', 'harvest.jsonl')
          torn = "{\"id\":\"Px\",\"words\":\"\xE5\xB8".b
          File.open(path, 'ab') { |f| f.write("#{torn}\n[1,2]\n\"x\"\nnull\n{\"id\":\"Pt\",\"wo\n") }
          File.write(File.join(@tmp, 'prec', 'raw', 'other.jsonl'), "{broken\n")
          assert_equal ['8 席で'], store.all.map { |r| r['words'] }
          assert_equal ['8 席で'], store.retrieve('何席 8 席').map { |r| r['words'] }
          assert_equal 1, store.add([rec('Fable も入れて')]), 'adding still works past a torn line'
          assert_equal 2, store.all.size
        end

        def test_the_same_answer_from_another_source_is_stored_once
          store = Precedents.new(File.join(@tmp, 'prec'))
          long = "#{'査読の席の数について。' * 30}何席にしますか？"
          assert_equal 2, store.add([rec('8 席で', source: 'snapshot:K', question: long), rec('7 席', question: 'x')])
          before = store.all.map { |r| r['id'] }
          again = [rec('8 席で', source: '/p/K/s.jsonl', at: '2026-10-21T00:00:00Z', question: "  #{long[0, 200]} 以下略"),
                   rec("8 席で\n\n⏺ pasted host output\n  more", source: '/p/K/s2.jsonl', question: long)]
          assert_equal 0, store.add(again), 'the first 200 characters of the question and the words decide'
          assert_equal before, store.all.map { |r| r['id'] }, 'stored ids are kept as they are'
          assert_equal 1, store.add([rec('8 席で', source: '/p/K/s3.jsonl', question: "別の質問。#{long}")])
          assert_equal 1, store.add([rec('9 席で', source: '/p/K/s4.jsonl', question: long)])
          both = [rec('A で', source: '/p/K/a.jsonl', question: 'A か B か？'), rec('A で', source: '/p/K/b.jsonl', question: 'A か B か？')]
          assert_equal 2, store.add(both), 'records of one call are distinct entries'
        end

        def test_importing_the_snapshot_then_harvesting_stores_each_answer_once
          q = '古い設定をどうしますか。'
          projects = File.join(@tmp, 'projects')
          dir = File.join(projects, '-Users-operator-x')
          FileUtils.mkdir_p(dir)
          lines = [
            { 'type' => 'assistant', 'sessionId' => 'sx', 'timestamp' => '2026-09-21T10:00:00.000Z',
              'message' => { 'content' => [{ 'type' => 'tool_use', 'id' => 'tu1', 'name' => 'AskUserQuestion',
                                             'input' => { 'questions' => [{ 'question' => q, 'options' => [{ 'label' => 'a' }] }] } }] } },
            { 'type' => 'user', 'sessionId' => 'sx', 'timestamp' => '2026-09-21T10:01:00.000Z',
              'toolUseResult' => { 'answers' => { q => '使わないが、記録としては残す' } },
              'message' => { 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => 'tu1', 'content' => 'answered' }] } }
          ]
          File.write(File.join(dir, 'sx.jsonl'), lines.map { |l| JSON.generate(l) }.join("\n") + "\n")
          snap = File.join(@tmp, 'snap')
          FileUtils.mkdir_p(snap)
          pairs = [{ 'proj' => '-Users-operator-x', 'ts' => '2026-09-21T10:00:00.000Z',
                     'input' => { 'questions' => [{ 'question' => q, 'options' => [{ 'label' => 'a' }] }] },
                     'result' => "Your questions have been answered: \"#{q}\"=\"使わないが、記録としては残す\". You can now continue." }]
          File.write(File.join(snap, 'askuserquestion_pairs_20261020.json'), JSON.generate(pairs))
          paths = Paths.new(File.join(@tmp, '.kairos'))
          h = Harvest.new(paths, projects_root: projects)
          assert_equal 1, h.import_snapshot(snap)
          assert_equal 0, h.run, 'the live transcript gives the same answer another source and time'
          assert_equal ['snapshot:-Users-operator-x'], Precedents.new(paths.precedents_dir).all.map { |r| r['source'] }
        end

        # --- 4. a stand-in failure keeps its cause ------------------------------

        def test_a_failure_keeps_the_last_errors_class_and_message
          s, calls = stand_in(RuntimeError.new('first'), SeatTimeout.new("timed out after 120s\n#{'x' * 400}"))
          a = s.ask(point: 'question', question: 'q')
          assert_equal 2, calls.size
          assert_equal "stand-in failed twice: #{SeatTimeout.name}: #{"timed out after 120s\n#{'x' * 400}"[0, 200]}", a.reason
          assert a.failed?
          assert a.operator_item?
          refute_nil a.inputs, 'the inputs stay with a failed answer'
        end

        def test_a_reply_that_does_not_parse_is_a_named_cause
          s, = stand_in(RuntimeError.new('down'), 'no json here')
          a = s.ask(point: 'question', question: 'q')
          assert_equal "#{StandIn::FAILED}: #{StandIn::UNPARSED}", a.reason
          assert a.failed?
          s2, = stand_in('no json here', RuntimeError.new('down'))
          assert_equal 'stand-in failed twice: RuntimeError: down', s2.ask(point: 'question', question: 'q').reason
        end

        def test_failed_reads_the_prefix_and_needs_no_answer
          answer = ->(**kw) { StandIn::Answer.new(answer: nil, klass: 'operator_item', confidence: 0.0, basis: [], **kw) }
          assert answer.call(reason: StandIn::FAILED).failed?
          assert answer.call(reason: "#{StandIn::FAILED}: stand-in unavailable: LoadError: x").failed?
          assert answer.call(reason: StandIn::SPENT).failed?
          refute answer.call(reason: 'the operator holds the facts').failed?
          refute StandIn::Answer.new(answer: 'x', klass: 'decided', reason: "#{StandIn::FAILED}: odd").failed?
        end

        # A run whose stand-in call bound is reached.
        FakeRun = Struct.new(:spent) do
          def reload = self

          def within_spend?(_counter) = !spent
        end

        def test_the_spent_answer_is_unchanged
          s, calls = stand_in(REPLY)
          g = StandIn.guard(FakeRun.new(true), s)
          a = g.ask(point: 'question', question: 'q')
          assert_equal StandIn::SPENT, a.reason
          assert a.failed?
          ruling, h = g.rule_hazard('API key printed')
          assert_equal 'not_ruled', ruling
          assert_equal StandIn::SPENT, h.reason
          assert_empty calls
        end

        def test_rule_hazard_passes_the_evidence_through_unchanged
          alert = "The API key was printed to the public log and pushed. #{'context ' * 400}"
          s, calls = stand_in(REPLY)
          ruling, a = s.rule_hazard(alert[0, 80], evidence: { 'alert' => alert })
          assert_equal 'in_draft', ruling
          assert_equal JSON.generate('alert' => alert), a.inputs['evidence_json']
          assert_equal({ 'alert' => alert }, JSON.parse(a.inputs['evidence_json']))
          assert_includes calls.first[1], JSON.pretty_generate('alert' => alert)
          s2, = stand_in(RuntimeError.new('down'), RuntimeError.new('down'))
          ruling2, a2 = s2.rule_hazard('API key printed', evidence: { 'alert' => alert })
          assert_equal 'not_ruled', ruling2
          assert_equal 'stand-in failed twice: RuntimeError: down', a2.reason
          assert_equal JSON.generate('alert' => alert), a2.inputs['evidence_json']
        end

        # --- 5. the full-width question mark survives normalising the source -----

        def test_harvest_question_end_spells_the_full_width_mark_as_an_escape
          src = Harvest::QUESTION_END.source
          assert_includes src, '\\uFF1F'
          refute_includes src, "？"
          assert_equal src, src.unicode_normalize(:nfkc), 'normalising the source changes nothing'
          ["A と B、どちらにしますか？", "進めますか？  \n", 'OK?', '進めますか。', 'どうでしょうか'].each do |t|
            assert_match Harvest::QUESTION_END, t.strip, t
          end
          refute_match Harvest::QUESTION_END, '了解しました。'
          refute_match Harvest::QUESTION_END, "？ の意味は後で"
        end

        def test_adoption_patterns_survive_normalising_the_source
          [Policies::SENTENCE_BREAK, Policies::QUESTION, Policies::NEGATION, Policies::ADOPTING].each do |re|
            assert_equal re.source, re.source.unicode_normalize(:nfkc), re.inspect
          end
        end

        def test_harvest_admits_a_goal_answer_to_a_full_width_question
          projects = File.join(@tmp, 'projects')
          dir = File.join(projects, '-Users-operator-x')
          FileUtils.mkdir_p(dir)
          lines = [
            { 'type' => 'assistant', 'sessionId' => 'sg', 'message' => { 'content' => [{ 'type' => 'text', 'text' => "どこまで進めますか？" }] } },
            entry(builtin('goal', GOAL), 'g1', source: nil, kind: nil).merge('sessionId' => 'sg', 'timestamp' => '2026-09-29T16:27:18.024Z')
          ]
          File.write(File.join(dir, 'sg.jsonl'), lines.map { |l| JSON.generate(l) }.join("\n") + "\n")
          paths = Paths.new(File.join(@tmp, '.kairos'))
          assert_equal 1, Harvest.new(paths, projects_root: projects).run
          r = Precedents.new(paths.precedents_dir).all.first
          assert_equal GOAL, r['words']
          assert_equal "どこまで進めますか？", r['question']
        end
      end
    end
  end
end
