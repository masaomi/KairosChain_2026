# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../lib/agent/dsl'
require_relative '../lib/agent/precedents'
require_relative '../lib/agent/stand_in'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1Precedents < Minitest::Test
        def setup
          @dir = Dir.mktmpdir('prec')
          @store = Precedents.new(@dir)
        end

        def teardown
          FileUtils.rm_rf(@dir)
        end

        def rec(words, kind: 'typed_answer', project: 'KairosChain_2026', question: 'q')
          { 'source' => 't.jsonl', 'project' => project, 'at' => '2026-10-20T00:00:00Z',
            'kind' => kind, 'question' => question, 'words' => words }
        end

        def test_pasted_host_output_is_not_the_operators_words
          text = "Fable も入れて 8 席で出して下さい。\n⏺ R2 summary: 7 seats ...\n  more model text\n\nありがとう"
          stripped = Precedents.strip_pasted(text)
          assert_includes stripped, 'Fable も入れて'
          assert_includes stripped, 'ありがとう'
          refute_includes stripped, 'R2 summary'
        end

        def test_add_is_idempotent_and_skips_empty_words
          assert_equal 2, @store.add([rec('全部直す'), rec('⏺ only pasted'), rec('8 席で')])
          assert_equal 0, @store.add([rec('全部直す'), rec('8 席で')])
          assert_equal 2, @store.all.size
        end

        def test_unknown_kinds_are_refused
          assert_raises(ArgumentError) { @store.add([rec('x', kind: 'stand_in_answer')]) }
        end

        def test_retrieval_prefers_related_words_and_the_same_project
          @store.add([rec('Fable も入れて 8 席で出す', question: '2 周目の査読をどう出しますか'),
                      rec('メールで良いと思います', question: 'Ralph さんにはどう連絡しますか', project: 'Desktop'),
                      rec('Fable 込み 8 席', question: '査読の席', project: 'GenomicsChain_SkillSets')])
          top = @store.retrieve('査読の席を何席にしますか Fable', project: 'KairosChain_2026', k: 2)
          assert_equal 2, top.size
          assert_equal 'KairosChain_2026', top.first['project']
          refute(top.any? { |r| r['words'].include?('メール') })
        end
      end

      class TestAgent1StandIn < Minitest::Test
        POLICY = DSL.parse_policy(<<~RUBY)
          policy "p" do
            stand_in may: [:precedent, :instruction_mode]
            spend default: { stand_in_calls: 10 }
          end
        RUBY

        def stand_in(replies)
          seen = []
          llm = lambda do |system:, user:|
            seen << [system, user]
            r = replies.shift
            raise r if r.is_a?(Exception)

            r
          end
          [StandIn.new(policy: POLICY, instruction_mode: 'Reversible: move quickly.', llm: llm), seen]
        end

        def test_a_parsed_reply_becomes_an_answer_with_its_inputs_digest
          s, seen = stand_in(['ok {"answer":"8 seats","class":"decided","confidence":0.8,"basis":["P1"],"reason":"thorough"}'])
          a = s.ask(point: 'question', question: 'How many seats?', options: %w[7 8],
                    precedents: [{ 'id' => 'P1', 'project' => 'K', 'kind' => 'typed_answer', 'question' => 'q', 'words' => '8 席' }],
                    operator_words: ['use Fable'])
          assert_equal '8 seats', a.answer
          assert_equal 'decided', a.klass
          assert_equal 1, a.calls
          assert_match(/\A[0-9a-f]{64}\z/, a.inputs_digest)
          assert_includes seen.first[1], '[P1]'
          assert_includes seen.first[1], 'use Fable'
          assert_includes seen.first[0], 'Reversible: move quickly.'
        end

        def test_one_retry_then_an_operator_item
          s, = stand_in([RuntimeError.new('timeout'), 'not json'])
          a = s.ask(point: 'question', question: 'q')
          assert a.operator_item?
          assert_equal 2, a.calls
        end

        def test_novel_answers_need_the_policy_class
          s, = stand_in(['{"answer":"x","class":"decided_novel","confidence":0.4,"basis":[],"reason":"r"}'])
          assert s.ask(point: 'question', question: 'q').operator_item?
        end

        def test_hazard_ruling_fails_closed
          s, = stand_in(['{"answer":"maybe","class":"decided","confidence":0.3,"basis":[],"reason":"r"}'])
          ruling, = s.rule_hazard('API key printed in a test log')
          assert_equal 'uncertain', ruling
          s2, = stand_in(['{"answer":"in_draft","class":"decided","confidence":0.9,"basis":[],"reason":"r"}'])
          assert_equal 'in_draft', s2.rule_hazard('design could lose 0.x storage').first
        end
      end
    end
  end
end
