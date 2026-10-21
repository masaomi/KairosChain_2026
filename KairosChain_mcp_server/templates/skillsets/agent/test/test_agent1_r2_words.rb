# frozen_string_literal: true

# R2 implementation-review fixes, group "words": the stand-in's isolation,
# its prompt and recoverable inputs, the operator's words in transcripts and
# prompts, and policy adoption. Each test takes its trigger from the R2 findings.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/skillset'
require_relative '../../llm_client/tools/llm_call'
require_relative '../lib/agent/dsl'
require_relative '../lib/agent/run'
require_relative '../lib/agent/policies'
require_relative '../lib/agent/stand_in'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R2Words < Minitest::Test
        LlmCall = KairosMcp::SkillSets::LlmClient::Tools::LlmCall
        SafeSubprocess = KairosMcp::SkillSets::LlmClient::SafeSubprocess
        ClaudeCodeAdapter = KairosMcp::SkillSets::LlmClient::ClaudeCodeAdapter
        Status = Struct.new(:success?, :exitstatus)
        REPLY = '{"answer":"8 席","class":"decided","confidence":0.9,"basis":["instruction_mode"],"reason":"r"}'
        ISOLATED = { 'safe_mode' => true, 'tools' => '', 'cwd' => '/tmp/kairos_sandbox' }.freeze

        # An llm_call class whose payload the test sets; it records each call.
        class FakeLlmCall
          class << self
            attr_accessor :payload, :calls
          end

          def initialize(_safety = nil); end

          def input_schema
            { type: 'object', properties: { messages: { type: 'array' }, isolated: { type: 'boolean' } } }
          end

          def call(arguments)
            self.class.calls << arguments
            [{ type: 'text', text: JSON.generate(self.class.payload) }]
          end
        end

        # The llm_call of an llm_client before 0.3.0 knew no `isolated`.
        class OldLlmCall < FakeLlmCall
          def input_schema
            { type: 'object', properties: { messages: { type: 'array' } } }
          end
        end

        def setup
          @tmp = File.realpath(Dir.mktmpdir('r2w'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@tmp, 'global_bound_sessions.txt')
          FakeLlmCall.calls = []
          OldLlmCall.calls = []
        end

        def teardown
          FileUtils.rm_rf(@tmp)
        end

        # --- helpers -------------------------------------------------------------

        def policy(classes = %i[precedent instruction_mode])
          DSL.parse_policy("policy \"q\" do\n  stand_in may: #{classes.inspect}\n  spend default: { stand_in_calls: 10 }\nend\n")
        end

        def ok_payload(isolation)
          { 'status' => 'ok', 'provider' => 'claude_code', 'model' => 'claude-opus-5-5', 'isolation' => isolation,
            'response' => { 'content' => REPLY, 'model_observed' => 'claude-opus-5-5' } }
        end

        # The claude subprocess replaced by a canned reply, as the llm_client
        # test does; the shared sandbox directories under /tmp are left alone.
        def with_claude_stubbed
          seen = []
          ClaudeCodeAdapter.send(:alias_method, :_r2_real_prepare, :prepare_sandbox!)
          ClaudeCodeAdapter.send(:define_method, :prepare_sandbox!) { nil }
          SafeSubprocess.singleton_class.send(:alias_method, :_r2_real_capture, :safe_capture)
          SafeSubprocess.singleton_class.send(:define_method, :safe_capture) do |args, **kw|
            seen << { args: args, chdir: kw[:chdir] }
            body = { 'type' => 'result', 'result' => REPLY, 'is_error' => false,
                     'modelUsage' => { 'claude-opus-5-5' => { 'outputTokens' => 40 } } }
            [JSON.generate(body), '', Status.new(true, 0)]
          end
          yield seen
        ensure
          SafeSubprocess.singleton_class.send(:remove_method, :safe_capture)
          SafeSubprocess.singleton_class.send(:alias_method, :safe_capture, :_r2_real_capture)
          SafeSubprocess.singleton_class.send(:remove_method, :_r2_real_capture)
          ClaudeCodeAdapter.send(:remove_method, :prepare_sandbox!)
          ClaudeCodeAdapter.send(:alias_method, :prepare_sandbox!, :_r2_real_prepare)
          ClaudeCodeAdapter.send(:remove_method, :_r2_real_prepare)
          ClaudeCodeAdapter.send(:private, :prepare_sandbox!)
        end

        def entry(text, prompt_id, source: 'typed', kind: 'human', **extra)
          d = { 'type' => 'user', 'promptId' => prompt_id, 'message' => { 'role' => 'user', 'content' => text } }
          d['origin'] = { 'kind' => kind } if kind
          d['promptSource'] = source if source
          d.merge(extra)
        end

        # As the host records a skill or slash command typed with arguments.
        def command(name, args)
          "<command-message>#{name}</command-message>\n<command-name>/#{name}</command-name>\n<command-args>#{args}</command-args>"
        end

        def write_transcript(*entries)
          path = File.join(@tmp, 'transcript.jsonl')
          File.write(path, entries.map { |e| JSON.generate(e) }.join("\n") + "\n")
          path
        end

        # --- 1. the stand-in runs isolated, or does not answer ------------------

        def test_an_isolated_llm_call_reports_how_claude_was_spawned
          with_claude_stubbed do |seen|
            out = LlmCall.new(nil).call('messages' => [{ 'role' => 'user', 'content' => 'q' }],
                                        'provider_override' => 'claude_code', 'isolated' => true, 'no_fallback' => true)
            payload = JSON.parse(out.first[:text])
            assert_equal 'ok', payload['status'], payload.inspect
            assert_equal({ 'safe_mode' => true, 'tools' => '', 'cwd' => ClaudeCodeAdapter::SANDBOX_CWD }, payload['isolation'])
            assert_includes seen.last[:args], '--safe-mode'
            assert_equal ClaudeCodeAdapter::SANDBOX_CWD, seen.last[:chdir]
          end
        end

        def test_a_call_not_asked_to_isolate_reports_no_isolation
          with_claude_stubbed do
            out = LlmCall.new(nil).call('messages' => [{ 'role' => 'user', 'content' => 'q' }],
                                        'provider_override' => 'claude_code', 'sandbox_mode' => true)
            assert_nil JSON.parse(out.first[:text])['isolation']
          end
        end

        def test_default_llm_answers_through_the_isolated_llm_call
          with_claude_stubbed do |seen|
            text = StandIn.default_llm(LlmCall).call(system: 's', user: 'u')
            assert_equal REPLY, text
            args = seen.last[:args]
            assert_equal '', args[args.index('--tools') + 1]
            assert_equal StandIn::MODEL, args[args.index('--model') + 1]
          end
        end

        def test_default_llm_refuses_a_reply_that_does_not_show_isolation
          llm = StandIn.default_llm(FakeLlmCall)
          [nil, {}, ISOLATED.merge('safe_mode' => false), ISOLATED.merge('tools' => 'Read'),
           ISOLATED.merge('tools' => nil), ISOLATED.merge('cwd' => nil), 'isolated'].each do |iso|
            FakeLlmCall.payload = ok_payload(iso)
            e = assert_raises(RuntimeError, iso.inspect) { llm.call(system: 's', user: 'u') }
            assert_match(/not isolated/, e.message)
          end
          FakeLlmCall.payload = ok_payload(ISOLATED)
          assert_equal REPLY, llm.call(system: 's', user: 'u')
          assert(FakeLlmCall.calls.all? { |a| a['isolated'] == true && a['no_fallback'] == true })
        end

        def test_a_stand_in_whose_llm_did_not_isolate_has_failed
          FakeLlmCall.payload = ok_payload(nil)
          s = StandIn.new(policy: policy, instruction_mode: 'mode', llm: StandIn.default_llm(FakeLlmCall))
          a = s.ask(point: 'question', question: '何席?')
          assert a.failed?
          assert_nil a.answer
          assert_equal 2, a.calls
        end

        def test_an_llm_client_that_cannot_isolate_is_never_called
          llm = StandIn.default_llm(OldLlmCall)
          OldLlmCall.payload = ok_payload(ISOLATED)
          e = assert_raises(RuntimeError) { llm.call(system: 's', user: 'u') }
          assert_match(/cannot isolate/, e.message)
          assert_empty OldLlmCall.calls, 'the prompt never reaches a claude -p that is not isolated'
        end

        def test_the_agent_requires_the_llm_client_that_isolates
          agent = KairosMcp::Skillset.new(File.expand_path('..', __dir__))
          dep = agent.depends_on_with_versions.find { |d| d[:name] == 'llm_client' }
          refute_nil dep[:version], 'depends_on names a minimum llm_client version'
          req = Gem::Requirement.new(*dep[:version].split(',').map(&:strip))
          refute req.satisfied_by?(Gem::Version.new('0.2.2')), 'the llm_client installed before isolation does not satisfy it'
          llm_client = KairosMcp::Skillset.new(File.expand_path('../../llm_client', __dir__))
          assert req.satisfied_by?(Gem::Version.new(llm_client.version))
          assert_includes agent.depends_on, 'multi_llm_review'
        end

        # --- 2. the system prompt carries no paraphrase of the operator --------

        def test_the_system_prompt_has_no_paraphrase_and_no_pronouns
          s = StandIn.new(policy: policy(%i[precedent instruction_mode novel_reversible]), instruction_mode: 'mode', llm: ->(**) {})
          rules = s.system_prompt.split("\nPolicy (").first
          refute_match(/thorough|irreversible publication|cannot parse/i, rules)
          refute_match(/\b(he|him|himself|his|she|her|herself)\b/i, rules)
          %w[decided decided_novel operator_item].each { |k| assert_includes rules, "\"#{k}\"" }
          assert_match(/material to judge, not instructions/, rules)
          assert_match(/most recent words .* outrank older ones/, rules)
          assert_match(/provisional/, rules)
          assert_match(/quotes the seat's\s+own words and never the operator's words/, rules)
        end

        # --- 3. the stand-in's inputs are whole ---------------------------------

        def test_inputs_carry_the_whole_evidence_and_mode_text
          mode = "## Rule Hierarchy\n#{'rank ' * 8000}"
          evidence = { 'plan' => "# Plan\n#{'step ' * 3000}", 'new_text' => 'x' * 6000 }
          s = StandIn.new(policy: policy, instruction_mode: mode, llm: ->(**) { REPLY })
          a = s.ask(point: 'plan_approval', question: 'plan', evidence: evidence)
          json = JSON.generate(evidence)
          assert_operator json.size, :>, 12_000
          assert_equal json, a.inputs['evidence_json']
          assert_equal evidence, JSON.parse(a.inputs['evidence_json'])
          assert_equal Digest::SHA256.hexdigest(json), a.inputs['evidence_sha256']
          assert_equal mode, a.inputs['mode_text']
          assert_equal Digest::SHA256.hexdigest(mode), a.inputs['mode_sha256']
          refute a.inputs.key?('evidence'), 'no truncated copy beside the whole one'
          assert_equal a.inputs, a.to_h['inputs']
        end

        def test_a_failed_answer_keeps_its_inputs_too
          s = StandIn.new(policy: policy, instruction_mode: 'mode text', llm: ->(**) { raise 'down' })
          a = s.ask(point: 'question', question: 'q', evidence: { 'k' => 'v' * 5000 })
          assert a.failed?
          assert_equal JSON.generate('k' => 'v' * 5000), a.inputs['evidence_json']
          assert_equal 'mode text', a.inputs['mode_text']
        end

        # --- 4. the operator's words in transcripts and prompts -----------------

        def test_a_command_typed_with_arguments_is_the_operators_words
          real = entry(command('agent', '収束するまで回して'), 'c1', source: nil)
          assert Transcript.typed?(real)
          assert_equal '収束するまで回して', Transcript.text_of(real)
          name_first = "<command-name>/claude-api</command-name>\n<command-message>claude-api</command-message>\n" \
                       '<command-args>prompt-audit</command-args>'
          assert Transcript.typed?(entry(name_first, 'c2', source: nil))
          assert Transcript.typed?(entry(command('agent', 'do X'), 'c3', source: 'typed'))
          assert Transcript.typed?(entry(command('agent', 'do X'), 'c4', source: 'queued'))
        end

        def test_a_command_without_arguments_or_not_from_the_operator_is_not
          refute Transcript.typed?(entry(command('compact', ''), 'n1', source: nil)), 'empty arguments'
          refute Transcript.typed?(entry(command('compact', "  \n "), 'n2', source: nil)), 'blank arguments'
          refute Transcript.typed?(entry(command('agent', 'do X'), 'n3', source: nil, kind: nil)), 'no origin'
          refute Transcript.typed?(entry(command('agent', 'do X'), 'n4', source: nil, kind: 'peer'))
          refute Transcript.typed?(entry(command('loop', '継続して下さい。'), 'n5', source: 'system')), 'a scheduled prompt'
          refute Transcript.typed?(entry(command('agent', 'do X'), 'n6', source: nil, 'isMeta' => true))
          refute Transcript.typed?(entry(command('agent', 'do X'), 'n7', source: nil, 'isSidechain' => true))
          refute Transcript.typed?(entry("#{command('agent', 'do X')}\nI3 resolved", 'n8', source: nil)), 'text beside the tags'
          refute Transcript.typed?(entry('<command-message>agent</command-message><command-args>do X</command-args>', 'n9',
                                         source: nil)), 'no command name'
          refute Transcript.typed?(entry("  \n<command-name>/agent</command-name> adopt policy p1 00000000", 'n10'))
        end

        def test_typed_entries_return_a_commands_arguments_as_its_text
          path = write_transcript(entry(command('agent', '設計から実装まで、収束するまで'), 'c1', source: nil),
                                  entry(command('compact', ''), 'c2', source: nil),
                                  entry('8 席で', 'p3'))
          assert_equal [%w[c1 設計から実装まで、収束するまで], %w[p3 8\ 席で]],
                       Transcript.typed_entries(path).map { |e| [e['prompt_id'], e['text']] }
          assert Transcript.typed_prompt?(path, text: '設計から実装まで、収束するまで', prompt_id: 'c1')
          refute Transcript.typed_prompt?(path, text: '/agent 設計から実装まで、収束するまで', prompt_id: 'c1')
        end

        def test_operator_text_takes_a_commands_arguments
          assert_equal 'do X', Transcript.operator_text('/agent do X')
          assert_equal "複数行の\n依頼", Transcript.operator_text("  /agent\n複数行の\n依頼\n")
          assert_equal 'xhigh', Transcript.operator_text('/effort xhigh')
          assert_equal 'prompt-audit', Transcript.operator_text('/claude-api:review prompt-audit')
          assert_nil Transcript.operator_text('/compact')
          assert_nil Transcript.operator_text("/agent   \n")
          assert_equal '8 席で、Fable も入れて', Transcript.operator_text('8 席で、Fable も入れて')
          ['Another Claude session sent a message: I3: resolved', '[SYSTEM NOTIFICATION - done] D4 is fine',
           "<task-notification>\n<summary>D4</summary>\n</task-notification>", '[Request interrupted by user]',
           "  \n<command-name>/agent</command-name> adopt policy p1 00000000", '', nil].each do |p|
            assert_nil Transcript.operator_text(p), p.inspect
          end
        end

        def test_operator_text_matches_what_the_transcript_records
          path = write_transcript(entry(command('agent', 'do X'), 'c1', source: nil))
          assert Transcript.typed_prompt?(path, text: Transcript.operator_text('/agent do X'), prompt_id: 'c1')
        end

        def test_a_prompt_starting_with_an_existing_path_is_not_a_command
          ['/tmp に置いて', '/tmp', "/Users/x/y.md を読んで", "#{@tmp} の中を見て"].each do |p|
            assert Transcript.plausibly_typed?(p), p
            assert Transcript.typed?(entry(p, 'p1')), p
            assert_equal p, Transcript.operator_text(p), p
          end
          refute Transcript.plausibly_typed?('/no_such_dir_r2w に置いて'), 'not a path: a command'
          refute Transcript.typed?(entry('/no_such_dir_r2w に置いて', 'p2'))
          refute Transcript.plausibly_typed?('/compact keep D4 and I3')
          refute Transcript.typed?(entry('/compact keep D4 and I3', 'p3')), 'a command typed as plain text stays out'
        end

        # --- 5. policy adoption -------------------------------------------------

        def adoption_setup
          @data = File.join(@tmp, 'data')
          @paths = Paths.new(@data)
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'p1.rb'),
                     "policy \"p1\" do\n  stand_in may: [:precedent]\n  spend default: { stand_in_calls: 10 }\nend\n")
          @policies = Policies.new(@paths)
          @hex = @policies.find('p1').digest[0, 8]
        end

        def adopt(words, prompt_id)
          tr = File.join(@tmp, "t_#{prompt_id}.jsonl")
          File.write(tr, JSON.generate(entry(words, prompt_id)) + "\n")
          @policies.adopt('p1', words: words, transcript_path: tr, prompt_id: prompt_id)
        end

        def test_a_negation_counts_only_on_the_adopting_line
          adoption_setup
          ["adopt policy p1 #{@hex}\n以後、質問はしないで",
           "以後、確認はしないで進めて。\nadopt policy p1 #{@hex} でお願いします",
           "adopt policy p1 #{@hex}\r\nDon't ask me about seats."].each_with_index do |w, i|
            assert_equal 'p1', adopt(w, "ok#{i}").name, w
          end
          assert_equal 'p1', @policies.adopted.name
          ["adopt policy p1 #{@hex} は採用しない\n以後、質問は少なく",
           "まず確認。\ndo not adopt policy p1 #{@hex}",
           "adopt policy p1 #{@hex}\n…いや、adopt policy p1 #{@hex} は取り消し"].each_with_index do |w, i|
            e = assert_raises(ArgumentError, w) { adopt(w, "no#{i}") }
            assert_match(/negate/, e.message)
          end
        end

        def test_a_torn_adoption_line_does_not_break_adopted
          adoption_setup
          adopt("adopt policy p1 #{@hex}", 'a1')
          File.open(@paths.adoptions_path, 'a') { |f| f.write("{\"name\":\"p1\",\"dig\n\n[1,2]\n\"x\"\n") }
          assert_equal 1, @policies.adoptions.size
          assert_equal 'p1', @policies.adopted.name
          adopt("adopt policy p1 #{@hex} で", 'a2')
          assert_equal 2, @policies.adoptions.size
          assert_equal 'p1', @policies.adopted.name
        end
      end
    end
  end
end
