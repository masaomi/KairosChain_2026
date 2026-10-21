# frozen_string_literal: true

# Implementation review R1, group "report": the report material, agent_finish
# and the deck built with the kit (design v0.5.1 INV-7).
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'shellwords'
require 'cgi'
require_relative '../lib/agent/service'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R1Report < Minitest::Test
        KIT = Service::KIT_DIR
        SUBAGENT = 'a1b2c3d4e5f6'

        # A stand-in that answers from a script (a Hash point => reply, or a
        # lambda of the question).
        class Scripted
          def initialize(script)
            @script = script
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
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

        POLICY_SRC = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 8, stand_in_calls: 100 }
          end
        RUBY

        def setup
          @root = File.realpath(Dir.mktmpdir('a1r1rep'))
          @old_global = ENV['KAIROS_AGENT_GLOBAL']
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@root, 'global_bound_sessions.txt')
          @paths = Paths.new(File.join(@root, '.kairos'))
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'p1.rb'), POLICY_SRC)
          FileUtils.mkdir_p(File.join(@root, 'log'))
          @policy = DSL.parse_policy(POLICY_SRC)
          @script = {}
          @stand_in = Scripted.new(@script)
          @mlr = {}
          @transcript = File.join(@root, 'transcript.jsonl')
          File.write(@transcript, '')
          Precedents.new(@paths.precedents_dir).add([{ 'source' => 'seed', 'project' => 'x', 'at' => '2026-10-01',
                                                       'kind' => 'typed_answer', 'question' => '査読は何周?',
                                                       'words' => '収束するまで回して' }])
        end

        def teardown
          Run.all(@paths).each { |r| FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', r.id)) } if @paths
          FileUtils.rm_rf(@root) if @root
          ENV['KAIROS_AGENT_GLOBAL'] = @old_global
        end

        # --- harness --------------------------------------------------------------

        # The kit's checker is faked (it needs a browser); `checker` is what the
        # faked run of check.py returns: [output, success].
        def service(checker: ["slides=9 svg_texts_measured=0 issues=0\n", true])
          real = Service.allocate
          run_cmd = lambda do |argv, chdir, timeout|
            if argv.any? { |a| a.to_s.end_with?('check.py') }
              checker
            else
              real.send(:default_run_cmd, argv, chdir, timeout)
            end
          end
          Service.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in },
                      invoke: ->(name, _args) { @mlr.fetch(name) { {} } }, chain: ->(_logs) { 1 }, run_cmd: run_cmd)
        end

        def hooks
          Hooks.new(paths: @paths, project_root: @root, stand_in_factory: ->(_r, _p) { @stand_in })
        end

        def pre(tool, input, agent_id: nil)
          hooks.handle('PreToolUse', { 'session_id' => 's1', 'tool_name' => tool, 'cwd' => @root,
                                       'tool_input' => input, 'agent_id' => agent_id }.compact)
        end

        def via_hook(tool, args)
          pre("mcp__kairos-chain__#{tool}", args).dig('hookSpecificOutput', 'updatedInput')
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

        def start_run(args)
          adopt!
          typed('進めて。査読は収束するまで', 'pr2')
          out = service.start(via_hook('agent_start', args))
          assert_equal 'started', out['status'], out.inspect
          hooks.handle('PostToolUse', 'session_id' => 's1', 'tool_name' => 'mcp__kairos-chain__agent_start',
                                      'transcript_path' => @transcript,
                                      'tool_response' => [{ 'type' => 'text', 'text' => JSON.generate(out) }])
          Run.load(@paths, out['run_id'])
        end

        def start_design_run
          start_run('goal' => 'design the thing', 'template' => 'design_only', 'design_glob' => 'log/thing_design_v*.md')
        end

        def git!(dir, *args)
          system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', *args,
                 exception: true, out: File::NULL, err: File::NULL)
        end

        def git_out(dir, *args)
          out, st = Open3.capture2('git', '-C', dir, *args)
          assert st.success?, "git #{args.join(' ')} failed"
          out.strip
        end

        def start_impl_run
          skip 'sandbox-exec unavailable' unless Confinement.available?
          git!(@root, 'init', '-q', '-b', 'main')
          FileUtils.mkdir_p(File.join(@root, 'test'))
          File.write(File.join(@root, 'test', 'test_ok.rb'), "exit 0\n")
          FileUtils.mkdir_p(File.join(@root, 'tests'))
          File.write(File.join(@root, 'tests', 'test_ok.rb'), "exit 0\n")
          File.write(File.join(@root, '.gitignore'), ".kairos/\nlog/\ntranscript.jsonl\nglobal_bound_sessions.txt\n")
          git!(@root, 'add', '.')
          git!(@root, 'commit', '-q', '-m', 'init')
          start_run('goal' => 'implement the thing', 'template' => 'impl_cycle', 'tests' => 'test')
        end

        def commit_in_worktree(run)
          FileUtils.mkdir_p(File.join(run.worktree, 'lib'))
          File.write(File.join(run.worktree, 'lib', 'thing.rb'), "class Thing; end\n")
          git!(run.worktree, 'add', '.')
          git!(run.worktree, 'commit', '-q', '-m', 'add the thing')
        end

        def advance(run)
          service.advance('run_id' => run.id, '_session_id' => 's1')
        end

        REFUTED = [{ 'seat' => 'codex', 'text' => 'P0: the cache has no bound', 'label' => 'refuted',
                     'grounds' => 'The design caps the cache at 100 entries in section 3.' }].freeze

        # The design phase, then one review round closed by a refuted P0.
        def close_design(run, labels: REFUTED)
          path = File.join(@root, 'log', 'thing_design_v0.1.md')
          assert_equal 'allow', pre('Write', { 'file_path' => path, 'content' => 'x' }).dig('hookSpecificOutput', 'permissionDecision')
          File.write(path, "# Design v0.1\nINV-1 ...\n")
          assert_equal 'phase_ended', advance(run)['status']
          @mlr['multi_llm_review'] = { 'collect_token' => 'tok1' }
          assert_equal 'dispatched', advance(run)['status']
          @mlr['multi_llm_review_wait'] = { 'status' => 'ready' }
          @mlr['multi_llm_review_collect'] = {
            'reviews' => [{ 'role_label' => 'codex', 'verdict' => 'REVISE', 'raw_text' => 'P0: the cache has no bound' },
                          { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'APPROVE' }],
            'vote_tally' => { 'successful_count' => 2, 'min_quorum' => 2 }, 'status' => 'ok'
          }
          @script['review_labels'] = { 'answer' => labels, 'class' => 'decided' }
          out = advance(run)
          assert_equal 'closed_provisionally', out['status'], out.inspect
          run.reload
        end

        def material(run)
          JSON.parse(File.read(service.status('run_id' => run.id, 'report_material' => true)['report_material']['material_path']))
        end

        def report_dir(run)
          File.join(@root, 'log', 'agent_runs', run.id)
        end

        def ids_of(material)
          material['decisions'].map { |d| d['id'] } + material['items'].map { |i| i['id'] } +
            material['phases'].map { |p| p['name'] }
        end

        # A subagent writes into the report directory through the guarded Write.
        def subagent_write(run, name, content)
          path = File.join(report_dir(run), name)
          out = pre('Write', { 'file_path' => path, 'content' => content }, agent_id: SUBAGENT)
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          path
        end

        def main_write(path, content)
          out = pre('Write', { 'file_path' => path, 'content' => content })
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
        end

        # A Bash call through the guard; returns the confined command.
        def bash(command, agent_id: nil)
          out = pre('Bash', { 'command' => command }, agent_id: agent_id)
          assert_equal 'allow', out.dig('hookSpecificOutput', 'permissionDecision'), out.inspect
          out.dig('hookSpecificOutput', 'updatedInput', 'command')
        end

        def kit_usable?
          return false unless File.exist?(File.join(KIT, 'make_report_deck.py'))

          _, st = Open3.capture2e('python3', '-c', 'import json, html')
          st.success?
        rescue SystemCallError
          false
        end

        # The report subagent's steps as report_step names them: material.json
        # with Write, the kit's make_report_deck.py through confined Bash.
        def build_deck_with_kit(run)
          skip 'python3 or the report kit is unavailable' unless kit_usable?
          skip 'sandbox-exec unavailable' unless Confinement.available?
          m = material(run)
          dir = report_dir(run)
          subagent_write(run, 'material.json', JSON.pretty_generate(m))
          cmd = "python3 #{Shellwords.escape(File.join(KIT, 'make_report_deck.py'))} " \
                "#{Shellwords.escape(File.join(dir, 'material.json'))} #{Shellwords.escape(File.join(dir, 'deck.html'))}"
          wrapped = bash(cmd, agent_id: SUBAGENT)
          out, st = Open3.capture2e('/bin/bash', '-c', wrapped, chdir: @root)
          assert st.success?, "the confined kit run failed: #{out}"
          [m, File.read(File.join(dir, 'deck.html'))]
        end

        def complete_ids_deck(run)
          subagent_write(run, 'deck.html', "<html>#{ids_of(material(run)).join(' ')}</html>")
        end

        def finished_design_run
          run = start_design_run
          close_design(run)
          complete_ids_deck(run)
          fin = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', fin['status'], fin.inspect
          run.reload
        end

        # --- report material --------------------------------------------------------

        def test_report_material_carries_plan_parameters_and_the_applied_ratification
          run = start_impl_run
          # A rounds token is no ruling any more; the tests directory is.
          @script['plan_parameters'] = { 'answer' => ['approve', 'rounds:3/1', 'tests:tests'], 'class' => 'decided' }
          commit_in_worktree(run)
          adv = advance(run)
          assert_equal 'phase_ended', adv['status'], adv.inspect
          m = material(run)
          assert_equal 'impl_cycle', m.dig('plan_parameters', 'template')
          assert_equal 'implement the thing', m.dig('plan_parameters', 'args', 'goal')
          assert_equal 'test', m.dig('plan_parameters', 'args', 'tests'), 'the arguments as the actor started the run'
          ratified = m['plan_ratified']
          assert_equal ['approve', 'rounds:3/1', 'tests:tests'], ratified['answer']
          assert_equal({ 'tests' => 'tests' }, ratified['applied'])
          d = m['decisions'].find { |x| x['id'] == ratified['decision'] }
          refute_nil d, 'the ratification names its decision'
          assert_equal 'plan_parameters', d['point']
          assert_includes m['plan'], 'check tests: "tests"', 'the plan in the material is the amended one'
          refute_includes m['plan'], 'max_rounds', 'no round bound is written into a plan'
        end

        def test_a_plan_with_nothing_to_rule_is_not_put_to_the_stand_in_and_the_material_says_so
          run = start_design_run
          close_design(run)
          assert_equal 'design_only', material(run).dig('plan_parameters', 'template')
          assert_equal 0, run.decisions.count { |d| d['point'] == 'plan_parameters' }
          assert_equal({ 'answer' => nil, 'applied' => {} }, material(run)['plan_ratified'])
          assert_equal 'no test set or command to rule on',
                       run.journal.entries.find { |e| e['kind'] == 'plan_ratified' }['skipped']
        end

        def test_report_material_counts_the_precedent_records
          Precedents.new(@paths.precedents_dir).add([{ 'source' => 'seed2', 'project' => 'x', 'at' => '2026-10-02',
                                                       'kind' => 'correction', 'question' => '席は?', 'words' => '8 席で' }])
          run = start_design_run
          assert_equal 2, Precedents.new(@paths.precedents_dir).all.size
          assert_equal 2, material(run)['precedent_records']
        end

        def test_a_queued_question_keeps_its_options_in_the_item_detail
          run = start_design_run
          @script['question'] = { 'answer' => nil, 'class' => 'operator_item' }
          q = { 'questions' => [{ 'question' => '所長は休暇中?', 'header' => '所長', 'multiSelect' => false,
                                  'options' => [{ 'label' => 'yes', 'description' => '休暇中' },
                                                { 'label' => 'no', 'description' => '在席' }] }] }
          out = pre('AskUserQuestion', q)
          assert_equal 'deny', out.dig('hookSpecificOutput', 'permissionDecision')
          item = material(run)['items'].find { |i| i['item_kind'] == 'question' }
          refute_nil item, 'the queued question is an item in the material'
          assert_equal '所長は休暇中?', item['text']
          assert_equal %w[yes no], item.dig('detail', 'options')
          assert_equal '所長', item.dig('detail', 'header')
        end

        def test_report_material_carries_the_review_rounds_with_their_seats
          run = start_design_run
          close_design(run)
          rounds = material(run)['review_rounds']
          assert_equal 1, rounds.size
          r = rounds.first
          assert_equal 'design_review', r['phase']
          assert_equal 1, r['round']
          assert_equal 2, r['counted']
          assert_equal 2, r['quorum']
          assert_equal [{ 'seat' => 'codex', 'verdict' => 'REVISE' }, { 'seat' => 'sonnet', 'verdict' => 'APPROVE' }], r['seats']
          assert_equal %w[design_review], material(run)['provisional_closures']
        end

        def test_review_rounds_in_the_material_carry_the_stand_ins_labels
          run = start_design_run
          close_design(run)
          labels = material(run)['review_rounds'].first['labels']
          if labels.nil?
            flunk('BUG: report_material slices labels from review_round entries, but labels live in review_labelled ' \
                 '(service.rb:687); the deck shows no labelling for any round')
          end
          refuted = Array(labels).find { |l| l['label'] == 'refuted' }
          refute_nil refuted, labels.inspect
          assert_includes refuted['grounds'], 'section 3'
        end

        def test_report_material_carries_the_code_of_an_impl_cycle_run_with_commits
          run = start_impl_run
          base = git_out(@root, 'rev-parse', 'HEAD')
          commit_in_worktree(run)
          code = material(run.reload)['code']
          refute_nil code, 'an impl_cycle run with a worktree has a code summary'
          refute code.key?('error'), code.inspect
          assert_equal run.branch, code['branch']
          assert_equal run.worktree, code['worktree']
          assert_equal base, code['base']
          assert_equal git_out(run.worktree, 'rev-parse', 'HEAD'), code['head']
          refute_equal code['base'], code['head']
          assert_equal 1, code['commits'].size
          assert_match(/\A[0-9a-f]{7,} add the thing\z/, code['commits'].first)
          assert_includes code['diffstat'], 'lib/thing.rb'
          assert_includes code['diffstat'], '1 file changed'
        end

        # An ending recorded without the merge item (any route that opened
        # none): report_material opens it, so the deck built from it names it
        # and the first agent_finish is not refused for omitting it.
        def test_report_material_opens_the_merge_item_so_the_deck_built_from_it_names_it
          run = start_impl_run
          commit_in_worktree(run)
          run.append(:run_ended, reason: 'waiting on operator items')
          assert(run.items.values.none? { |i| i['item_kind'] == 'merge' })

          m, html = build_deck_with_kit(run)
          merge = m['items'].find { |i| i['item_kind'] == 'merge' }
          refute_nil merge, 'report_material opens the merge item before the deck is built'
          assert_equal "git merge #{run.branch}", merge['command']
          assert_match(/(?<![A-Za-z0-9_])#{merge['id']}(?![A-Za-z0-9_])/, html)
          assert_empty service.completeness(run.reload, html)
          items_before = run.items.size
          fin = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', fin['status'], fin.inspect
          assert_equal items_before, run.reload.items.size, 'finish opens nothing the deck could not name'
        end

        def test_a_hook_ended_run_gets_a_complete_deck_with_the_hazard_first
          run = start_impl_run
          commit_in_worktree(run)
          @script['hazard'] = { 'answer' => 'in_world', 'class' => 'decided' }
          out = hooks.handle('Stop', 'session_id' => 's1',
                                     'last_assistant_message' => 'The API key was printed to the public log and pushed.')
          assert_equal 'block', out['decision']
          assert_equal 'ended', run.reload.status
          m, html = build_deck_with_kit(run)
          assert_equal 'in_world', m.dig('hazard', 'ruling')
          refute_nil(m['items'].find { |i| i['item_kind'] == 'merge' })
          first = html[/<section[^>]*data-key="m1".*?<\/section>/m] || html[/data-key="m1".{0,4000}/m].to_s
          assert_includes first, '危険・最優先', 'the hazard leads the first main slide'
          assert_empty service.completeness(run.reload, html)
          assert_equal 'finished', service.finish('run_id' => run.id, '_session_id' => 's1')['status']
        end

        # --- who built the report -----------------------------------------------------

        def test_built_by_subagent_follows_the_last_write_into_the_report_dir
          skip 'sandbox-exec unavailable' unless Confinement.available?
          run = start_design_run
          svc = service
          deck = File.join(report_dir(run), 'deck.html')
          refute svc.built_by_subagent?(run, deck), 'nothing written yet'

          subagent_write(run, 'material.json', '{}')
          assert svc.built_by_subagent?(run, deck), 'a subagent Write is the last write'

          main_write(deck, '<html/>')
          refute svc.built_by_subagent?(run, deck), 'the main context wrote last'

          bash("python3 #{KIT}/make_report_deck.py #{report_dir(run)}/material.json #{deck}", agent_id: SUBAGENT)
          assert svc.built_by_subagent?(run, deck), "a subagent's Bash naming the report dir is the last write"

          bash("sed -i '' 's/a/b/' #{deck}")
          refute svc.built_by_subagent?(run, deck), "the main context's Bash naming the report dir is the last write"
        end

        def test_a_subagent_effect_elsewhere_does_not_vouch_for_the_main_contexts_deck
          skip 'sandbox-exec unavailable' unless Confinement.available?
          run = start_design_run
          deck = File.join(report_dir(run), 'deck.html')
          main_write(deck, '<html/>')
          path = File.join(@root, 'log', 'thing_design_v0.1.md')
          assert_equal 'allow', pre('Write', { 'file_path' => path, 'content' => 'x' }, agent_id: SUBAGENT)
                                  .dig('hookSpecificOutput', 'permissionDecision')
          bash('ls /tmp', agent_id: SUBAGENT)
          assert(run.journal.entries.any? { |e| e['kind'] == 'effect' && e['agent_id'] == SUBAGENT })
          refute service.built_by_subagent?(run, deck), 'subagent effects outside the report dir do not count'
        end

        def test_a_main_context_write_by_another_spelling_of_the_report_dir_still_counts
          run = start_design_run
          svc = service
          deck = File.join(report_dir(run), 'deck.html')
          subagent_write(run, 'deck.html', '<html/>')
          assert svc.built_by_subagent?(run, deck)
          spellings = []
          # macOS: /var is a link to /private/var, and the host may name either.
          alias_root = @root.sub(%r{\A/private(?=/)}, '')
          if alias_root != @root && File.directory?(alias_root) && File.realpath(alias_root) == @root
            spellings << File.join(alias_root, 'log', 'agent_runs', run.id, 'deck.html')
          end
          spellings << File.join(@root, 'log', '.', 'agent_runs', run.id, 'deck.html')
          missed = spellings.select do |p|
            subagent_write(run, 'deck.html', '<html/>')
            main_write(p, '<html>main</html>')
            svc.built_by_subagent?(run, deck)
          end
          unless missed.empty?
            flunk("BUG: built_by_subagent? compares the raw file_path with the report dir (service.rb:657); a main-context " \
                 "Write the guard placed in the report dir is not seen when spelled #{missed.join(' or ')}")
          end
        end

        # --- agent_finish ---------------------------------------------------------------

        def test_finish_refuses_when_the_kit_reports_issues
          run = start_design_run
          close_design(run)
          complete_ids_deck(run)
          out = service(checker: ["slides=9 svg_texts_measured=12 issues=3\n  m1: overflow\n", true])
                .finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'refused', out['status']
          assert_includes out['reason'], '3 issues'
          assert_includes out['checker'], 'issues=3'
          assert_nil run.reload.report
          assert(run.journal.entries.none? { |e| e['kind'] == 'report_built' })
          assert_equal 's1', run.bound_session, 'the run stays bound for the rebuild'
          assert_equal 'finished', service.finish('run_id' => run.id, '_session_id' => 's1')['status']
        end

        def test_finish_refuses_a_deck_missing_an_id
          run = start_design_run
          close_design(run)
          ids = ids_of(material(run))
          dropped = ids.find { |i| i.start_with?('D') }
          subagent_write(run, 'deck.html', "<html>#{(ids - [dropped]).join(' ')}</html>")
          out = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'refused', out['status']
          assert_equal [dropped], out['missing']
          assert_nil run.reload.report
        end

        def test_finish_accepts_an_unchecked_deck_and_records_checker_unavailable
          run = start_design_run
          close_design(run)
          complete_ids_deck(run)
          out = service(checker: ["ModuleNotFoundError: No module named 'playwright'\n", false])
                .finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', out['status'], out.inspect
          assert out['checker'].start_with?('unchecked'), out['checker']
          built = run.reload.journal.entries.reverse.find { |e| e['kind'] == 'report_built' }
          assert_equal true, built['checker_unavailable']
          assert_equal true, built['built_by_subagent']
          assert_equal 'finished', run.status
        end

        def test_a_real_deck_built_from_the_material_names_every_id
          run = start_design_run
          %w[knowledge_update skills_evolve chain_record state_commit context_create_subdir instructions_update
             system_upgrade skillset_deposit].each { |t| pre("mcp__kairos-chain__#{t}", { 'name' => 'x' }) }
          @script['question'] = lambda do |q|
            q.include?('所長') ? { 'answer' => nil, 'class' => 'operator_item' } : { 'answer' => 'A', 'class' => 'decided_novel', 'confidence' => 0.4 }
          end
          qs = { 'questions' => %w[どの名前? 何席? 所長は休暇中? 色は? 何時?].map do |t|
            { 'question' => t, 'header' => 'h', 'options' => [{ 'label' => 'A' }, { 'label' => 'B' }] }
          end }
          pre('AskUserQuestion', qs)
          close_design(run)
          assert_operator run.items.size, :>=, 9
          assert_operator run.decisions.size, :>=, 7

          m, html = build_deck_with_kit(run)
          assert_operator m['items'].size, :>, 7, 'the items span more than one appendix page'
          assert_empty service.completeness(run.reload, html)
          fin = service.finish('run_id' => run.id, '_session_id' => 's1')
          assert_equal 'finished', fin['status'], fin.inspect
          assert_equal true, run.reload.report['built_by_subagent']
        end

        def test_the_kits_deck_shows_what_the_material_adds
          run = start_impl_run
          @script['question'] = { 'answer' => nil, 'class' => 'operator_item' }
          pre('AskUserQuestion', { 'questions' => [{ 'question' => 'リリースはいつ?', 'header' => '時期',
                                                      'options' => [{ 'label' => '今週金曜' }, { 'label' => '来週月曜' }] }] })
          commit_in_worktree(run)
          @script['plan_parameters'] = { 'answer' => ['tests:tests'], 'class' => 'decided' }
          adv = advance(run)
          assert_equal 'phase_ended', adv['status'], adv.inspect
          assert_equal 'stopped', service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 'enough')['status']
          m, html = build_deck_with_kit(run)
          assert_equal({ 'tests' => 'tests' }, m.dig('plan_ratified', 'applied'))
          assert_equal %w[今週金曜 来週月曜], m['items'].find { |i| i['item_kind'] == 'question' }.dig('detail', 'options')
          assert_equal 1, m.dig('code', 'commits').size
          assert_empty service.completeness(run.reload, html)
          # INV-7: the main slides carry the operator items (a queued question
          # with its options), plan parameters the stand-in set, and what changed.
          main = html.scan(/<section class="slide" data-key="m[^"]*".*?<\/section>/m).join
          refute_empty main
          shown = { 'question options' => [%w[今週金曜 来週月曜]],
                    'plan parameters the stand-in set' => [['tests:tests']],
                    'commits on the run branch' => [['add the thing'], ['lib/thing.rb']] }
          missing = shown.reject { |_, alts| alts.any? { |words| words.all? { |w| main.include?(CGI.escapeHTML(w)) } } }.keys
          unless missing.empty?
            flunk("BUG: the kit's deck (make_report_deck.py main layer) shows none of: #{missing.join('; ')} — " \
                 'report_material carries them but no slide renders them')
          end
        end

        # --- guidance and stop ------------------------------------------------------------

        def test_report_step_names_the_kit_scripts_and_the_material
          run = start_design_run
          run.append(:run_ended, reason: 'stopped: test')
          step = Guidance.report_step(run.reload)
          dir = report_dir(run)
          assert_includes step, File.join(KIT, 'make_report_deck.py')
          assert_includes step, "#{dir}/material.json"
          assert_includes step, File.join(KIT, 'check.py')
          assert_includes step, "#{dir}/deck.html"
          assert_includes step, 'subagent'
          assert_includes step, "report_material: true"
          assert_equal step, Guidance.next_step(run)
        end

        def test_stop_on_a_finished_run_is_refused
          run = finished_design_run
          seq = run.journal.entries.last['seq']
          out = service.stop('run_id' => run.id, '_session_id' => 's1', 'reason' => 'late')
          assert_equal 'refused', out['status']
          assert_includes out['reason'], 'finished'
          assert_equal seq, run.reload.journal.entries.last['seq'], 'nothing is appended to a finished run'
          assert_equal 'finished', run.status
        end
      end
    end
  end
end
