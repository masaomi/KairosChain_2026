# frozen_string_literal: true

# Design v0.6.1 - v0.6.4: reviews with no round bound of their own, the
# policy's rounds for each review as the only cap, the revision discipline in the
# round's reply, deferred design findings, the three new templates, a check
# with no test set, and no public lookup.
#
# The first two classes need no host: the templates and the plan language, and
# the guard. The third drives runs the way the host does (PreToolUse -> the
# service -> PostToolUse, Stop where the host fires it) on real git
# repositories with confined checks (sandbox-exec) under a temporary
# directory; the stand-in and the review tools are scripted (@script, @mlr).
require 'shellwords'
require 'securerandom'
require 'open3'
require_relative 'test_agent1_r2v_checkreview'

# The harnesses' own tests run in their own files.
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1R1Check)
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1R2Checkreview)

module KairosMcp
  module SkillSets
    module Agent
      # --- templates and the plan language ----------------------------------------

      class TestAgent1V06Templates < Minitest::Test
        def plan_of(template, **params)
          DSL.parse_plan(Templates.build(template, **params))
        end

        def test_no_round_bound_remains_in_the_templates
          refute Templates.const_defined?(:TIERS), 'the tiers are gone'
          assert_equal %w[dev_cycle design_only impl_cycle doc_cycle survey general], Templates::NAMES
          err = assert_raises(ArgumentError) do
            Templates.design_only(name: 'x', goal: 'g', design_glob: 'log/x_design_v*.md', tier: 1)
          end
          assert_includes err.message, 'tier'
          # Through build (what agent_start calls) the old parameters are dropped.
          plan = plan_of('dev_cycle', name: 'x', goal: 'g', design_glob: 'log/x_design_v*.md', tests: 'test',
                                      tier: 1, design_rounds: 5, implementation_rounds: 3)
          plan.phases.select { |p| p.kind == :review }.each { |p| assert_nil p.args[:max_rounds] }
          refute_match(/tier|max_rounds|rounds/, plan.source)
        end

        def test_doc_cycle_builds_and_parses_with_or_without_a_build_command
          plan = plan_of('doc_cycle', name: 'paper', goal: 'revise the paper')
          assert_equal :doc_cycle, plan.template
          assert_equal %i[write write_review], plan.phase_names
          assert_equal [:check, { tests: nil, command: nil }], [plan.phase(:write).kind, plan.phase(:write).args]
          rv = plan.phase(:write_review)
          assert_equal [:review, :write, :document, nil], [rv.kind, rv.args[:of], rv.args[:as], rv.args[:max_rounds]]
          assert_equal :layered_deck, plan.report

          built = plan_of('doc_cycle', name: 'paper', goal: 'revise the paper', test_command: 'make paper.pdf')
          assert_equal({ tests: nil, command: 'make paper.pdf' }, built.phase(:write).args)
          assert_equal built.source, Templates.doc_cycle(name: 'paper', goal: 'revise the paper', test_command: 'make paper.pdf')
          assert_raises(DSL::Error) { Templates.doc_cycle(name: 'paper', goal: ' ') }
        end

        def test_survey_builds_and_parses_and_needs_an_output_glob_with_a_star
          plan = plan_of('survey', name: 's', goal: 'survey caching', output_glob: 'log/caching_survey_v*.md')
          assert_equal :survey, plan.template
          assert_equal %i[survey survey_review], plan.phase_names
          assert_equal [:produce, 'log/caching_survey_v*.md'], [plan.phase(:survey).kind, plan.phase(:survey).args[:glob]]
          rv = plan.phase(:survey_review)
          assert_equal [:review, :survey, :document], [rv.kind, rv.args[:of], rv.args[:as]]

          err = assert_raises(DSL::Error) { Templates.survey(name: 's', goal: 'g', output_glob: nil) }
          assert_includes err.message, 'output_glob'
          err = assert_raises(DSL::Error) { Templates.survey(name: 's', goal: 'g', output_glob: 'log/caching_survey.md') }
          assert_includes err.message, 'must contain *'
          assert_raises(DSL::Error) { Templates.survey(name: 's', goal: 'g', output_glob: '   ') }
        end

        def test_general_is_a_produce_phase_with_an_output_glob_and_a_check_phase_without
          produce = plan_of('general', name: 'g', goal: 'g', output_glob: 'log/g_v*.md')
          assert_equal %i[work work_review], produce.phase_names
          assert_equal :produce, produce.phase(:work).kind
          assert_equal 'log/g_v*.md', produce.phase(:work).args[:glob]
          assert_equal [:document, :work], [produce.phase(:work_review).args[:as], produce.phase(:work_review).args[:of]]

          check = plan_of('general', name: 'g', goal: 'g')
          assert_equal [:check, { tests: nil, command: nil }], [check.phase(:work).kind, check.phase(:work).args]
          assert_equal :document, check.phase(:work_review).args[:as], 'committed work without tests is reviewed as a document'

          with_tests = plan_of('general', name: 'g', goal: 'g', tests: 'test', test_command: 'rake test')
          assert_equal({ tests: 'test', command: 'rake test' }, with_tests.phase(:work).args)
          assert_equal :implementation, with_tests.phase(:work_review).args[:as], 'with tests the review is an implementation review'

          err = assert_raises(DSL::Error) { Templates.general(name: 'g', goal: 'g', output_glob: 'log/g_v*.md', tests: 'test') }
          assert_includes err.message, 'not both'
          assert_raises(DSL::Error) { Templates.general(name: 'g', goal: 'g', output_glob: 'log/g.md') }
        end

        def test_general_validates_review_as
          %w[design implementation document].each do |as|
            plan = plan_of('general', name: 'g', goal: 'g', output_glob: 'log/g_v*.md', review_as: as)
            assert_equal as.to_sym, plan.phase(:work_review).args[:as]
          end
          err = assert_raises(DSL::Error) { Templates.general(name: 'g', goal: 'g', review_as: 'summary') }
          assert_includes err.message, 'review_as must be one of design, implementation, document'
          # The plan language refuses the same type spelled in a plan.
          assert_raises(DSL::Error) do
            DSL.parse_plan('run "r", template: :general do; goal "g"; phase(:w) { produce "a_v*.md" }; ' \
                           'phase(:r) { review :mlr, of: :w, as: :summary }; end')
          end
        end

        def test_a_review_may_not_name_a_review_phase_or_a_later_phase
          plan = lambda do |body|
            "run \"r\", template: :general do\n  goal \"g\"\n#{body}\nend\n"
          end
          ok = plan.call(%(  phase(:w) { produce "a_v*.md" }\n  phase(:r1) { review :mlr, of: :w }\n  phase(:c) { check }\n  phase(:r2) { review :mlr, of: :c }))
          assert_equal %i[w r1 c r2], DSL.parse_plan(ok).phase_names

          of_a_review = plan.call(%(  phase(:w) { produce "a_v*.md" }\n  phase(:r1) { review :mlr, of: :w }\n  phase(:r2) { review :mlr, of: :r1 }))
          err = assert_raises(DSL::Error) { DSL.parse_plan(of_a_review) }
          assert_includes err.message, 'must name an earlier produce or check phase'

          of_a_later = plan.call(%(  phase(:r) { review :mlr, of: :w }\n  phase(:w) { produce "a_v*.md" }))
          assert_raises(DSL::Error) { DSL.parse_plan(of_a_later) }
          of_itself = plan.call(%(  phase(:w) { produce "a_v*.md" }\n  phase(:r) { review :mlr, of: :r }))
          assert_raises(DSL::Error) { DSL.parse_plan(of_itself) }
          of_nothing = plan.call(%(  phase(:r) { review :mlr, of: :nowhere }))
          assert_raises(DSL::Error) { DSL.parse_plan(of_nothing) }
        end

        def test_max_rounds_is_still_an_optional_cap_the_plan_language_accepts
          src = "run \"r\", template: :general do\n  goal \"g\"\n  phase(:w) { produce \"a_v*.md\" }\n" \
                "  phase(:r) { review :mlr, of: :w, max_rounds: 2 }\nend\n"
          assert_equal 2, DSL.parse_plan(src).phase(:r).args[:max_rounds]
        end

        def test_the_shipped_policy_has_no_lookup_consent_ten_rounds_for_each_review_and_a_known_digest
          path = File.expand_path('../config/policies/masa_2026_10_20.rb', __dir__)
          policy = DSL.parse_policy(File.read(path))
          assert_equal 'masa_2026_10_20', policy.name
          assert policy.consents?(:review)
          refute policy.consents?(:lookup)
          assert_equal 10, policy.spend[:review_rounds], 'the cap of each review, counted apart'
          assert_equal '8846b67e', policy.digest[0, 8],
                       'the operator adopts this digest in their own words; an edit needs a new adoption'
        end
      end

      # --- the guard: no lookup ---------------------------------------------------------

      class TestAgent1V06Guard < Minitest::Test
        FakeRun = Struct.new(:id, :worktree, :target_repo, :branch, :created_paths, :pinned, keyword_init: true)
        KEY = "AKIA#{'ABCDEFGHIJKLMNOP'}"

        def setup
          @root = File.realpath(Dir.mktmpdir('v06guard'))
          @wt = File.join(@root, '.claude', 'worktrees', 'run1')
          FileUtils.mkdir_p(@wt)
          @paths = Paths.new(File.join(@root, '.kairos'))
          @run = FakeRun.new(id: 'run_v06', worktree: @wt, target_repo: @root, branch: 'agent-run/v06', created_paths: [], pinned: {})
        end

        def teardown
          FileUtils.rm_rf(@root)
          FileUtils.rm_rf('/tmp/kairos_agent_runs/run_v06')
        end

        def guard(source = nil)
          src = source || "policy \"p\" do\n  stand_in may: [:precedent]\n  consent review: :configured_providers, of: :project_artifacts\n" \
                          "  spend default: { stand_in_calls: 5 }\nend\n"
          Guard.new(run: @run, paths: @paths, policy: DSL.parse_policy(src), project_root: @root)
        end

        def test_websearch_and_webfetch_are_refused_in_every_run
          g = guard
          [['WebSearch', { 'query' => 'agent skillset design' }],
           ['WebFetch', { 'url' => 'https://example.org/page', 'prompt' => 'summarise' }]].each do |tool, input|
            v = g.decide(tool, input)
            assert v.refuse?, "#{tool}: #{v.inspect}"
            assert_includes v.reason, 'does not look things up on the web'
          end
          assert g.decide('WebSearch', {}).refuse?
        end

        def test_websearch_and_webfetch_stay_refused_when_the_policy_source_tries_to_consent_because_it_does_not_parse
          source = "policy \"p\" do\n  stand_in may: [:precedent]\n  consent review: :configured_providers, of: :project_artifacts\n" \
                   "  consent lookup: :public_web\n  spend default: { stand_in_calls: 5 }\nend\n"
          err = assert_raises(DSL::Error) { guard(source) }
          assert_includes err.message, 'unknown consent'
          refute_includes DSL::CONSENT_KINDS, :lookup
          # With the consenting line left out, nothing else lets a lookup through.
          g = guard
          assert g.decide('WebSearch', { 'query' => 'x' }).refuse?
          assert g.decide('WebFetch', { 'url' => 'https://example.org' }).refuse?
        end

        # --- the here-document allowance of the confinement profile (R4) ----------------

        HEREDOC_RULE = '(regex #"^/private/var/tmp/sh-thd[^/]*$")'

        def test_the_here_document_allowance_is_anchored_to_files_named_sh_thd_and_nothing_below_them
          skip 'sandbox-exec unavailable' unless Confinement.available?
          prof = Confinement.profile(writable: [@wt], worktree: @wt)
          assert_includes prof, HEREDOC_RULE
          assert_includes prof, '(literal "/private/var/tmp")'

          tag = "v06#{SecureRandom.hex(4)}"
          dir = "/private/var/tmp/sh-thd#{tag}"
          file = "/private/var/tmp/sh-thdf#{tag}"
          scratch = File.join('/tmp', 'kairos_agent_runs', 'run_v06', 'scratch')
          confined = lambda do |cmd|
            argv = Confinement.argv(['/bin/sh', '-c', cmd], writable: [@wt], scratch: scratch, worktree: @wt)
            Open3.capture2e(*argv)
          end
          begin
            FileUtils.mkdir_p(dir) # made outside confinement: only the write below is the question
            out, st = confined.call("printf x > #{dir}/inner")
            refute st.success?, 'a file below a directory named sh-thd* is not a here-document body'
            assert_match(/not permitted/i, out)
            refute File.exist?("#{dir}/inner")

            out, st = confined.call("printf x > #{file}")
            assert st.success?, "a here-document body (a file named sh-thd*) stays writable: #{out}"
            assert_equal 'x', File.read(file)

            out, st = confined.call("printf x > /private/var/tmp/other-#{tag}")
            refute st.success?, 'nothing else in /var/tmp is writable'
            assert_match(/not permitted/i, out)
          ensure
            FileUtils.rm_rf([dir, file, "/private/var/tmp/other-#{tag}"])
          end
        end

        def test_a_url_carrying_a_credential_is_refused_like_any_other_lookup_and_the_reason_is_the_lookup
          v = guard.decide('WebFetch', { 'url' => "https://example.org/?k=#{KEY}", 'prompt' => 'x' })
          assert v.refuse?
          assert_includes v.reason, 'does not look things up on the web'
          refute_includes v.reason, 'credential', 'there is no credential check on lookups any more'
        end
      end

      # --- runs driven the way the host drives them ----------------------------------------

      class TestAgent1V06 < TestAgent1R2Checkreview
        TestAgent1R2Checkreview.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }

        LEVEL_HEADING = '## Review level (fixed by the SkillSet)'
        GROUNDS_40 = 'It concerns only how the cache is evicted, not what the design requires of it.'
        P0_A = 'the cache has no eviction'
        P0_B = 'the index is rebuilt on every read'

        # Answers from a script keyed by decision point; an entry may be a
        # callable of the evidence. Records every question.
        class V06StandIn
          attr_reader :asked

          def initialize(script)
            @script = script
            @asked = []
          end

          def ask(point:, question:, options: nil, evidence: {}, precedents: [], operator_words: [])
            @asked << { point: point, question: question, evidence: evidence, options: options }
            reply = @script.fetch(point) { { 'answer' => Array(options).first, 'class' => 'decided' } }
            reply = reply.call(evidence) if reply.respond_to?(:call)
            StandIn::Answer.new(answer: reply['answer'], klass: reply['class'], confidence: 0.9,
                                basis: ['instruction_mode'], reason: 'scripted', calls: 1,
                                inputs_digest: Digest::SHA256.hexdigest(JSON.generate([point, question, @asked.size])))
          end

          def rule_hazard(text, **kw)
            a = ask(point: 'hazard', question: text, options: StandIn::HAZARD_RULINGS, **kw)
            [a.answer.to_s, a]
          end
        end

        def setup
          super
          @stand_in = V06StandIn.new(@script)
        end

        # --- helpers -------------------------------------------------------------------

        def revise(*lines)
          [{ 'role_label' => 'codex', 'verdict' => 'REVISE', 'raw_text' => lines.map { |l| "P0: #{l}" }.join("\n") },
           { 'role_label' => 'sonnet', 'verdict' => 'APPROVE', 'raw_text' => 'APPROVE' }]
        end

        def lab(text, label, earlier: nil, grounds: nil, from_revision: nil, seat: 'codex', covers: nil)
          { 'seat' => seat, 'text' => text, 'label' => label, 'earlier_id' => earlier, 'grounds' => grounds,
            'from_revision' => from_revision, 'covers' => covers }.compact
        end

        # One more version of the design, written through the guard.
        def next_version(version, extra = '')
          write_design(version, "# x design v#{version}\nINV-1: the cache holds at most 100 entries.\n#{extra}")
        end

        # A round collected and labelled through the review step itself, whose
        # reply (status, labels, tally, next) is returned as the review gives it.
        # (agent_advance replaces the review's own `next` with Guidance.next_step
        # - service.rb:277 - so the revision discipline's text is read here.)
        def review_reply(run, phase = 'design_review')
          service.review_step(run.reload, @policy, @stand_in, run.plan.phase(phase))
        end

        # Dispatches the next round of the design review and collects it
        # labelled; returns the review's reply.
        def design_round(run, reviews:, labelled:, p0_lines: [])
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: reviews, p0_lines: p0_lines)
          labels(labelled)
          review_reply(run)
        end

        # The operator types a prompt: the transcript records it as typed and
        # UserPromptSubmit fires.
        def type!(text, pid, sid: 's1')
          File.open(@transcript, 'a') do |f|
            f.puts(JSON.generate('type' => 'user', 'promptId' => pid, 'origin' => { 'kind' => 'human' },
                                 'promptSource' => 'typed', 'message' => { 'role' => 'user', 'content' => text }))
          end
          hooks.handle('UserPromptSubmit', 'session_id' => sid, 'prompt' => text, 'prompt_id' => pid,
                                           'transcript_path' => @transcript)
        end

        def resolve(run, ref, decision = nil, **extra)
          args = { 'action' => 'resolve', 'run_id' => run.id, 'ref' => ref }
          args['decision'] = decision if decision
          host_tool('items', args.merge(extra.transform_keys(&:to_s)))
        end

        def doc_repo!(extra = {})
          repo_files!({ 'paper.md' => "# Paper\n\nA first draft.\n" }.merge(extra), executable: extra.keys.grep(%r{\Abin/}))
        end

        def commit_paper(run, text)
          wt = run.worktree
          assert_equal 'allow', host_write(File.join(wt, 'paper.md'), text, cwd: wt)
          host_commit(run, 'edit the paper')
        end

        # --- agent_start ignores the old round parameters -------------------------------------

        def test_agent_start_ignores_tier_and_the_round_parameters
          run = started('template' => 'design_only', 'design_glob' => 'log/x_design_v*.md', 'tier' => 1,
                        'design_rounds' => 1, 'implementation_rounds' => 1)
          refute_match(/tier|max_rounds/, run.plan.source)
          assert_nil run.plan.phase(:design_review).args[:max_rounds]
          assert_nil run.plan.tier
          args = entries(run, 'plan_parameters').first['args']
          refute_includes args.keys, 'tier'
          refute_includes args.keys, 'design_rounds'
        end

        # --- a check phase with no test set ------------------------------------------------------

        def test_a_check_phase_without_tests_refuses_while_head_is_the_base
          doc_repo!
          run = started('template' => 'doc_cycle')
          assert_equal [:check, nil, nil], [run.plan.phase(:write).kind, run.plan.phase(:write).args[:tests], run.plan.phase(:write).args[:command]]
          assert_equal run.base_commit, git_out(run.worktree, 'rev-parse', 'HEAD')
          out = host_advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'no commits yet'
          assert_equal 'write', run.reload.current_phase
          assert_empty entries(run, 'check')
          assert_empty dispatched
        end

        def test_a_check_phase_without_tests_or_command_ends_when_the_work_is_committed
          doc_repo!
          run = started('template' => 'doc_cycle')
          wt = run.worktree
          assert_equal 'allow', host_write(File.join(wt, 'paper.md'), "# Paper\n\nA second draft.\n", cwd: wt)
          out = host_advance(run)
          assert_equal 'refused', out['status'], 'uncommitted work is not the committed state: ' + out.inspect
          assert_includes out['reason'], 'uncommitted'
          head = host_commit(run, 'second draft')
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal [0, head], out.values_at('ran', 'commit')
          check = entries(run, 'check').last
          assert_equal [true, 0, head], check.values_at('ok', 'ran', 'commit')
          assert_empty checks_ran, 'with no command nothing runs confined'
          assert_equal 'write_review', run.reload.current_phase
        end

        def test_a_check_phase_with_a_build_command_runs_it_and_returns_build_failed_on_failure
          doc_repo!('bin/build' => "#!/bin/sh\ntest -f built.flag && echo built || { echo 'no flag'; exit 1; }\n")
          run = started('template' => 'doc_cycle', 'test_command' => 'bin/build')
          assert_equal 'bin/build', run.plan.phase(:write).args[:command]
          wt = run.worktree
          out = host_advance(run)
          assert_equal 'refused', out['status'], 'nothing committed yet: ' + out.inspect
          assert_equal 1, asks('plan_parameters').size, 'a plan with a command is ruled on'

          commit_paper(run, "# Paper\n\nA draft that does not build.\n")
          out = host_advance(run)
          assert_equal 'build_failed', out['status'], out.inspect
          assert_includes out['out'], 'no flag'
          assert_equal [['bin/build']], checks_ran
          assert_equal false, entries(run, 'check').last['ok']
          assert_equal 'write', run.reload.current_phase

          assert_equal 'allow', host_write(File.join(wt, 'built.flag'), "x\n", cwd: wt)
          host_commit(run, 'now it builds')
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal 1, out['ran']
          assert_equal 2, checks_ran.size
          assert_equal true, entries(run, 'check').last['ok']
        end

        # --- the plan ruling ----------------------------------------------------------------------

        def test_a_plan_with_neither_tests_nor_command_skips_the_plan_ruling
          doc_repo!
          run = started('template' => 'doc_cycle')
          @script['plan_parameters'] = { 'answer' => ['reject_test_command'], 'class' => 'decided' }
          host_advance(run)
          assert_empty asks('plan_parameters'), 'the stand-in is not asked'
          ratified = entries(run, 'plan_ratified')
          assert_equal 1, ratified.size
          assert_equal 'no test set or command to rule on', ratified.first['skipped']
          assert_equal({}, ratified.first['applied'])
          assert_empty entries(run, 'plan_amended')
          assert_empty run.decisions.select { |d| d['point'] == 'plan_parameters' }
          assert(run.open_items.none? { |i| i['item_kind'] == 'plan_parameters' })
          host_advance(run)
          assert_equal 1, entries(run, 'plan_ratified').size, 'recorded once'
        end

        def test_a_design_only_plan_has_nothing_to_rule_either
          run = started('template' => 'design_only', 'design_glob' => 'log/x_design_v*.md')
          write_design('0.1', "# x design v0.1\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_empty asks('plan_parameters')
          assert_equal 'no test set or command to rule on', entries(run, 'plan_ratified').first['skipped']
        end

        # --- fixes after implementation review R4 --------------------------------------------------------

        # A build file named by the command's own option is read to decide what
        # runs, so it is pinned like a test (R4). Every spelling of the option.
        def test_a_config_file_named_by_a_runner_option_is_one_of_the_commands_files_in_every_spelling
          svc = Service.allocate
          {
            'make -f build.mk' => 'build.mk', 'make -fbuild.mk' => 'build.mk', 'make --file build.mk' => 'build.mk',
            'make --file=build.mk' => 'build.mk', 'make --makefile build.mk' => 'build.mk', 'make --makefile=build.mk' => 'build.mk',
            'nice make -f build.mk all' => 'build.mk', 'make -j4 -f ci/build.mk all' => 'ci/build.mk',
            'rake -f tasks/Rakefile2' => 'tasks/Rakefile2', 'rake -fRakefile2' => 'Rakefile2', 'rake --rakefile r.rb' => 'r.rb',
            'rake --rakefile=r.rb' => 'r.rb', 'pytest -c ci/pytest.ini' => 'ci/pytest.ini', 'pytest -cci/pytest.ini' => 'ci/pytest.ini',
            'python3 -m pytest -c ci/pytest.ini' => 'ci/pytest.ini', 'tox -c ci/tox.ini' => 'ci/tox.ini',
            'latexmk -r ci/latexmkrc' => 'ci/latexmkrc', 'latexmk -rci/latexmkrc' => 'ci/latexmkrc'
          }.each do |cmd, file|
            assert_includes svc.runner_files(cmd), file, cmd
          end
          assert_equal %w[Makefile GNUmakefile], svc.runner_files('make -j4 all'), 'options that name no file add none'
          assert_equal %w[build.mk Makefile GNUmakefile], svc.runner_files('make -f build.mk'), 'the runner\'s own defaults stay'
          assert_equal %w[Rakefile], svc.runner_files('rake test')
          assert_empty svc.runner_files('ruby -W0')
          assert_empty svc.runner_files(nil)
        end

        def test_a_build_file_named_by_make_f_is_pinned_and_its_change_goes_to_the_ruling_and_then_the_operator
          doc_repo!('build.mk' => "all:\n\t@echo built\n")
          run = started('template' => 'doc_cycle', 'test_command' => 'make -f build.mk')
          build = File.join(run.worktree, 'build.mk')
          assert_equal({ build => git_out(@root, 'rev-parse', 'HEAD:build.mk') }, run.pinned['write']['tests'],
                       'build.mk is in the pinned set, at the base commit\'s blob')
          assert_equal 'refused', host_advance(run)['status'], 'nothing is committed yet'
          assert_empty asks('pinned_test_change')

          # The build file is changed and committed by a route the guard did not rule on.
          @script['pinned_test_change'] = { 'answer' => 'refuse', 'class' => 'decided' }
          put(run.worktree, 'build.mk', "all:\n\t@echo built without checking anything\n")
          commit_all!(run, 'rewrite the build file')
          out = host_advance(run)
          assert_equal 'check_refused', out['status'], out.inspect
          assert_equal [build], out['changed']
          ask = asks('pinned_test_change').last
          assert_equal 'build.mk', ask[:evidence]['path']
          assert_equal "all:\n\t@echo built\n", ask[:evidence]['old'], 'the old text is the base commit\'s'
          item = run.reload.items[out['item']]
          assert_equal 'blocking', item['item_kind']
          assert_equal 'a change to pinned test (build file) build.mk needs the operator ' \
                       '(decision accept_test_change, or revert it)', item['text']
          assert_includes Service.allocate.decisions_for(item), 'accept_test_change'
          assert_empty checks_ran, 'nothing ran before the ruling'

          # A plain resolve does not settle it; the operator's decision does.
          type!("#{item['id']} は認める", 'p-accept-build')
          plain = resolve(run, item['id'])
          assert plain['item_open'], plain.inspect
          res = resolve(run, item['id'], 'accept_test_change')
          assert_equal 'recorded', res['status'], res.inspect
          refute res['item_open'], res.inspect
          assert_equal 'resolved', run.reload.items[item['id']]['state']
          change = entries(run, 'pinned_change').last
          assert_equal [build, 'operator'], change.values_at('path', 'by')
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal [['make', '-f', 'build.mk']], checks_ran
        end

        def test_a_build_file_change_the_stand_in_approves_ends_the_phase_without_an_item
          doc_repo!('build.mk' => "all:\n\t@echo built\n")
          run = started('template' => 'doc_cycle', 'test_command' => 'make -f build.mk')
          @script['pinned_test_change'] = { 'answer' => 'approve', 'class' => 'decided' }
          put(run.worktree, 'build.mk', "all:\n\t@echo built, documented\n")
          commit_all!(run, 'document the build file')
          out = host_advance(run)
          assert_equal 'phase_ended', out['status'], out.inspect
          assert_equal 1, asks('pinned_test_change').size
          assert_equal 'stand-in', entries(run, 'pinned_change').last['by']
          assert_empty run.reload.open_items_for('write', %w[blocking])
        end

        # Only named tests (minitest, pytest) count as failing test names (R5:
        # guessing names from other output lines is removed).
        def test_only_named_tests_are_failing_test_names
          svc = Service.allocate
          assert_nil svc.failing_tests("FAIL tests/a.test.js\nFAILED tests/b.test.js\nERROR tests/c.test.js\n")
          assert_nil svc.failing_tests("FAIL tests/a.test.js (5.3 s)\n  ● adds two numbers\n")
          assert_nil svc.failing_tests("FAIL tests/a.test.js\n❌ legacy check\nError: boom\n")
          assert_equal ['tests/test_a.py::test_one'], svc.failing_tests("FAILED tests/test_a.py::test_one - assert 1 == 2\n")
          assert_nil svc.failing_tests('')
        end

        def test_a_file_failing_on_the_base_and_now_with_only_a_file_header_is_not_excused
          repo!('test/test_legacy.rb' => "puts 'FAIL tests/legacy.test.js'\nexit 1\n",
                'test/test_x.rb' => "require 'x'\nexit(X_VALUE >= 1 ? 0 : 1)\n", 'lib/x.rb' => "X_VALUE = 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'test')
          wt = run.worktree
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X_VALUE = 1', 'X_VALUE = 1 # documented', cwd: wt)
          host_commit(run, 'document x')
          out = host_advance(run)
          assert_equal 'tests_failed', out['status'], 'the same header is no evidence of the same failures: ' + out.inspect
          assert_equal [File.join(wt, 'test', 'test_legacy.rb')], out['failed'].map { |f| f['file'] }
          base = entries(run, 'baseline').find { |e| e['file'] == 'test/test_legacy.rb' }
          assert_equal [false, nil], base.values_at('ok', 'failing_tests'), 'the base failure names no test'
          items = run.reload.open_items_for('implement', %w[blocking])
          assert_equal 1, items.size
          assert_includes items.first['text'], 'fails on the base commit too'
          assert_equal [{ 'item' => items.first['id'], 'file' => 'test/test_legacy.rb' }], out['failing_on_the_base_too']
          assert_empty out.fetch('failing_before_the_run', []), 'it is not reported as failing before the run'
        end

        # A build's output is the actor's to ignore (R5: the clean after the
        # build is removed): untracked output refuses the next check or the
        # review, naming .gitignore; a committed .gitignore lets both through.
        def test_build_output_refuses_until_a_gitignore_is_committed
          doc_repo!('bin/build' => "#!/bin/sh\nprintf pdf > out.pdf\nprintf aux > x.aux\nexit 0\n")
          run = started('template' => 'doc_cycle', 'test_command' => 'bin/build')
          wt = run.worktree
          commit_paper(run, "# Paper\n\nA second draft.\n")
          out = host_advance(run)
          assert_equal ['phase_ended', 1], out.values_at('status', 'ran'), out.inspect
          assert File.exist?(File.join(wt, 'out.pdf')), 'nothing removes the build output'

          out = host_advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['uncommitted'], '?? out.pdf'
          assert_includes out['reason'], '.gitignore'

          # The guard lets the run write the worktree's .gitignore.
          assert_equal 'allow', host_write(File.join(wt, '.gitignore'), "out.pdf\n*.aux\n", cwd: wt)
          git_out(wt, 'add', '.gitignore')
          git_out(wt, 'commit', '-q', '-m', 'ignore build output')
          out = host_advance(run)
          assert_equal 'dispatched', out['status'], out.inspect
        end

        # Output the review's own re-run of the build leaves is seen before the
        # dispatch (R6): the cleanliness check follows the re-check.
        def test_output_of_the_reviews_recheck_refuses_the_dispatch
          doc_repo!('bin/build' => "#!/bin/sh\n[ -f second ] && printf x > late.aux\nexit 0\n")
          run = started('template' => 'doc_cycle', 'test_command' => 'bin/build')
          wt = run.worktree
          commit_paper(run, "# Paper\n\nA second draft.\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          File.write(File.join(wt, 'second'), "x\n")
          git_out(wt, 'add', 'second')
          git_out(wt, 'commit', '-q', '-m', 'second')
          out = host_advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['uncommitted'], '?? late.aux'
          assert_equal true, entries(run, 'check').last['recheck'], 'the review re-ran the build first'
        end

        # The review reads the committed state, so anything uncommitted refuses
        # its dispatch whatever the check says (R4).
        def test_the_review_refuses_a_dirty_worktree_even_when_the_last_ok_check_is_at_head
          doc_repo!
          run = started('template' => 'doc_cycle')
          wt = run.worktree
          head = commit_paper(run, "# Paper\n\nA second draft.\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal [true, head], entries(run, 'check').last.values_at('ok', 'commit'), 'the last ok check is at HEAD'
          assert_equal 'write_review', run.reload.current_phase

          assert_equal 'allow', host_write(File.join(wt, 'paper.md'), "# Paper\n\nA third draft, not committed.\n", cwd: wt)
          out = host_advance(run)
          assert_equal 'refused', out['status'], out.inspect
          assert_includes out['reason'], 'uncommitted'
          assert_includes out['uncommitted'], ' M paper.md'
          assert_empty dispatched

          git!(wt, 'checkout', '--', 'paper.md')
          assert_equal 'allow', host_write(File.join(wt, 'notes.txt'), "scratch\n", cwd: wt)
          out = host_advance(run)
          assert_equal 'refused', out['status'], 'an untracked file is uncommitted work too: ' + out.inspect
          assert_includes out['uncommitted'], '?? notes.txt'
          assert_empty dispatched

          FileUtils.rm(File.join(wt, 'notes.txt'))
          assert_equal 'dispatched', host_advance(run)['status']
          assert_equal 1, dispatched.size
        end

        # The labeller is shown every P0 line the review tool extracted, not the
        # first 40 (R4): a labelling that covers what it was shown is complete.
        def test_a_round_with_forty_five_p0_lines_is_shown_whole_and_labelled
          lines = (0...45).map { |i| "P0 number #{i}: the cache has no bound at site #{i}" }
          # The scripted labeller covers exactly the lines it is shown.
          @script['review_labels'] = lambda do |evidence|
            shown = evidence['p0_lines_the_review_tool_extracted']
            { 'answer' => shown.map { |l| { 'seat' => 'codex', 'text' => l['text'], 'label' => 'new', 'covers' => [l['index']] } },
              'class' => 'decided' }
          end
          run = design_run(rounds: 6)
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: revise(*lines), p0_lines: lines)
          out = review_reply(run)
          refute_equal 'labelling_failed', out['status'], out.inspect
          assert_equal 'open', out['status'], out.inspect
          shown = asks('review_labels').last[:evidence]['p0_lines_the_review_tool_extracted']
          assert_equal 45, shown.size
          assert_equal (0...45).to_a, shown.map { |l| l['index'] }
          assert_equal lines, shown.map { |l| l['text'] }
          assert_equal 45, out['open_p0'].size
          assert_empty run.reload.open_items_for('design_review', %w[blocking])

          # The same labelling given as one label that covers 0..44 is complete too.
          next_version('0.2')
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: revise(*lines), p0_lines: lines)
          labels((0...45).map { |i| lab(lines[i], 'carried_over', earlier: out['open_p0'][i]['id'], covers: [i]) })
          again = review_reply(run)
          assert_equal 'open', again['status'], again.inspect
          assert_equal 45, again['open_p0'].size
        end

        # --- deferred findings, the tally and the revision discipline -------------------------------

        def test_a_deferred_design_label_opens_a_carried_item_and_the_design_review_closes_with_it
          run = design_run
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A],
                                  labelled: [lab(P0_A, 'deferred', grounds: GROUNDS_40, covers: [0])])
          assert_equal 'closed_provisionally', out['status'], out.inspect
          label = out['labels'].first
          assert_equal ['deferred', false], label.values_at('label', 'open')
          items = run.reload.open_items.select { |i| i['item_kind'] == 'carried_p0' }
          assert_equal 1, items.size
          detail = items.first['detail']
          assert_equal true, detail['deferred']
          assert_equal [label['id'], 'codex', P0_A, GROUNDS_40], detail.values_at('finding', 'seat', 'text', 'grounds')
          assert_equal 'design_review', items.first.dig('state_ref', 'ref')
          assert_includes items.first['text'], 'deferred to the implementation'
          assert_equal 1, run.open_items.count { |i| i['item_kind'] == 'closure' }, 'the review closed provisionally'
          tally = entries(run, 'review_labelled').last['tally']
          assert_equal({ 'carried_open' => 0, 'fixed' => 0, 'refuted' => 0, 'deferred' => 1, 'new_from_revision' => 0,
                         'new_elsewhere' => 0 }, tally)
          assert_equal 0, entries(run, 'review_labelled').last['open']
          # The question to the labeller offers the deferral for a design review.
          assert_includes asks('review_labels').last[:question], '"deferred"'
        end

        def test_a_deferred_label_needs_grounds_of_forty_characters_or_it_is_new
          run = design_run
          out = design_round(run, reviews: revise(P0_A, P0_B), p0_lines: [P0_A, P0_B],
                                  labelled: [lab(P0_A, 'deferred', grounds: 'too short', covers: [0]),
                                             lab(P0_B, 'deferred', grounds: '', covers: [1])])
          assert_equal 'open', out['status'], out.inspect
          assert_equal %w[new new], out['open_p0'].map { |l| l['label'] }
          assert_equal %w[deferred deferred], out['open_p0'].map { |l| l['label_given'] }
          assert_empty run.reload.open_items.select { |i| i['item_kind'] == 'carried_p0' }
        end

        def test_a_deferred_label_in_a_document_review_is_a_new_finding
          doc_repo!
          run = started('template' => 'doc_cycle')
          commit_paper(run, "# Paper\n\nA second draft.\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: revise(P0_A), p0_lines: [P0_A])
          labels([lab(P0_A, 'deferred', grounds: GROUNDS_40, covers: [0])])
          out = review_reply(run, 'write_review')
          assert_equal 'open', out['status'], out.inspect
          assert_equal %w[new], out['open_p0'].map { |l| l['label'] }, 'only a design review defers'
          assert_empty run.reload.open_items.select { |i| i['item_kind'] == 'carried_p0' }
          refute_includes asks('review_labels').last[:question], '"deferred"', 'and the labeller is not offered it'
        end

        def test_the_round_tally_counts_each_kind_of_label_and_the_drawn_by_revision_flag_is_for_new_labels_only
          run = design_run(rounds: 6)
          lock = 'the lock order is unspecified'
          design_round(run, reviews: revise(P0_A, P0_B, lock), p0_lines: [P0_A, P0_B, lock],
                            labelled: [lab(P0_A, 'new', covers: [0]), lab(P0_B, 'new', covers: [1]), lab(lock, 'new', covers: [2])])
          first = entries(run, 'review_labelled').last
          assert_equal({ 'carried_open' => 0, 'fixed' => 0, 'refuted' => 0, 'deferred' => 0, 'new_from_revision' => 0,
                         'new_elsewhere' => 3 }, first['tally'])
          assert(first['labels'].all? { |l| l['from_revision'] == false }, 'nothing was drawn by a revision in round 1')

          next_version('0.2', "Entries are evicted on insert (LRU).\n")
          out = design_round(run, reviews: revise(lock, 'a new queue', 'the retry count', 'the sweep interval'),
                                  p0_lines: [lock, 'a new queue', 'the retry count', 'the sweep interval'],
                                  labelled: [lab(P0_A, 'fixed', earlier: 'DR1.F1'),
                                             lab(P0_B, 'refuted', earlier: 'DR1.F2', grounds: GROUNDS_40),
                                             lab(lock, 'carried_over', earlier: 'DR1.F3', from_revision: true, covers: [0]),
                                             lab('a new queue', 'new', from_revision: true, covers: [1]),
                                             lab('the retry count', 'new', covers: [2]),
                                             lab('the sweep interval', 'deferred', grounds: GROUNDS_40, covers: [3])])
          assert_equal 'open', out['status'], out.inspect
          assert_equal({ 'carried_open' => 1, 'fixed' => 1, 'refuted' => 1, 'deferred' => 1, 'new_from_revision' => 1,
                         'new_elsewhere' => 1 }, out['tally'])
          journal = entries(run, 'review_labelled').last
          assert_equal out['tally'], journal['tally'], 'the journal carries the same tally'
          assert_equal 3, journal['open'], 'carried, new, new'
          by_text = journal['labels'].to_h { |l| [l['text'], l] }
          assert_equal true, by_text['a new queue']['from_revision']
          assert_equal false, by_text['the retry count']['from_revision']
          assert_equal false, by_text[lock]['from_revision'], 'a carried-over label is not a new P0 the revision drew'
          assert_equal ['the sweep interval'], run.reload.open_items.select { |i| i['item_kind'] == 'carried_p0' }.map { |i| i.dig('detail', 'text') }
        end

        # agent_advance itself (the host's path) keeps the review's revision
        # step in `next`, ahead of the phase's standing guidance.
        def test_agent_advance_keeps_the_revision_step_in_next
          run = design_run(rounds: 6)
          design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          next_version('0.2', "A background sweeper thread evicts entries every second.\n")
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: revise(P0_A, 'the sweeper races the writers'), p0_lines: [P0_A, 'the sweeper races the writers'])
          labels([lab(P0_A, 'carried_over', earlier: 'DR1.F1', covers: [0]),
                  lab('the sweeper races the writers', 'new', from_revision: true, covers: [1])])
          out = host_advance(run)
          assert_equal 'open', out['status'], out.inspect
          assert_includes out['next'], 'undo that addition'
          assert_includes out['next'], "agent_advance(run_id: '#{run.id}'"
        end

        # An earlier P0 deferred in a later round stays an open item, to be
        # carried into the implementation review; deferring is not settling.
        def test_an_earlier_p0_deferred_later_stays_an_open_carried_item
          run = design_run(rounds: 6)
          design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          next_version('0.2', "The bound is stated as a requirement.\n")
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A],
                                  labelled: [lab(P0_A, 'deferred', earlier: 'DR1.F1', grounds: GROUNDS_40, covers: [0])])
          item = run.reload.open_items.find { |i| i['item_kind'] == 'carried_p0' && i.dig('detail', 'deferred') }
          refute_nil item, "the deferral is an open item: #{out.inspect}"
        end

        # A cap a plan names tightens the policy's rounds for a review and never
        # raises them (design v0.6.6, R8).
        def test_a_plan_cap_is_bounded_by_the_policys_rounds_for_each_review
          run = design_run(rounds: 4)
          rv = ->(max) {
            Review.new(run: run.reload, policy: @policy, stand_in: @stand_in, invoke: ->(*) { {} }, project_root: @root)
                  .send(:round_bound_of, DSL::Phase.new(name: :design_review, kind: :review, args: { of: :design, max_rounds: max }))
          }
          assert_equal 4, rv.call(nil), 'no plan cap: the policy\'s rounds'
          assert_equal 2, rv.call(2), 'a lower plan cap tightens'
          assert_equal 4, rv.call(9), 'a higher plan cap does not raise the policy\'s rounds'
        end

        def test_a_new_p0_drawn_by_the_revision_puts_undo_that_addition_in_next
          run = design_run(rounds: 6)
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          assert_equal 'open', out['status'], out.inspect
          refute_includes out['next'], 'undo that addition', 'nothing was added in round 1'

          # The actor answers the P0 by adding a mechanism; the next round raises a P0 against it.
          next_version('0.2', "A background sweeper thread evicts entries every second.\n")
          out = design_round(run, reviews: revise(P0_A, 'the sweeper races the writers'),
                                  p0_lines: [P0_A, 'the sweeper races the writers'],
                                  labelled: [lab(P0_A, 'carried_over', earlier: 'DR1.F1', covers: [0]),
                                             lab('the sweeper races the writers', 'new', from_revision: true, covers: [1])])
          assert_equal 'open', out['status'], out.inspect
          drawn = out['open_p0'].select { |l| l['from_revision'] }.map { |l| l['id'] }
          assert_equal %w[DR2.F2], drawn
          assert_includes out['next'], 'undo that addition'
          assert_includes out['next'], 'DR2.F2'
          assert_includes out['next'], 'by deletion, correction or naming instead'
          # The labeller was shown what the actor changed between the rounds.
          diff = asks('review_labels').last[:evidence]['revision_diff']
          assert_includes diff, '+A background sweeper thread evicts entries every second.'
          # A new P0 that no addition drew does not ask for an undo.
          next_version('0.3', "Entries are evicted on insert.\n")
          out = design_round(run, reviews: revise('the retry count is unbounded'), p0_lines: ['the retry count is unbounded'],
                                  labelled: [lab('the retry count is unbounded', 'new', covers: [0])])
          refute_includes out['next'], 'undo that addition'
        end

        def test_an_open_count_that_has_not_fallen_for_two_rounds_calls_for_another_approach
          run = design_run(rounds: 6) # enough spend for the rounds below
          counts = []
          carried = ->(id) { lab(P0_A, 'carried_over', earlier: id, covers: [0]) }
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          counts << out['open_p0'].size
          refute_includes out['next'], 'has not fallen'
          next_version('0.2')
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [carried.call('DR1.F1')])
          counts << out['open_p0'].size
          refute_includes out['next'], 'has not fallen', 'two labelled rounds are not yet a trend'
          next_version('0.3')
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [carried.call('DR1.F1')])
          counts << out['open_p0'].size
          assert_equal [1, 1, 1], counts
          assert_equal 'open', out['status'], 'the run does not stop for it: ' + out.inspect
          assert_includes out['next'], 'has not fallen for two rounds'
          assert_includes out['next'], '1 → 1 → 1'
          assert_includes out['next'], 'prove or refute each open P0 by a test or a reproduction, undo additions, or split the artifact'
          assert_equal 3, entries(run, 'review_labelled').size
        end

        def test_a_falling_open_count_does_not_call_for_another_approach
          run = design_run(rounds: 6)
          design_round(run, reviews: revise(P0_A, P0_B), p0_lines: [P0_A, P0_B],
                            labelled: [lab(P0_A, 'new', covers: [0]), lab(P0_B, 'new', covers: [1])])
          next_version('0.2')
          out = design_round(run, reviews: revise(P0_B), p0_lines: [P0_B],
                                  labelled: [lab(P0_A, 'fixed', earlier: 'DR1.F1'), lab(P0_B, 'carried_over', earlier: 'DR1.F2', covers: [0])])
          next_version('0.3')
          out = design_round(run, reviews: revise(P0_B), p0_lines: [P0_B], labelled: [lab(P0_B, 'carried_over', earlier: 'DR1.F2', covers: [0])])
          assert_equal [2, 1, 1], entries(run, 'review_labelled').map { |e| e['open'] }
          refute_includes out['next'], 'has not fallen', '2 -> 1 -> 1 fell in the first step'
        end

        # --- what the seats are sent -----------------------------------------------------------------

        def test_a_design_bundle_starts_with_the_fixed_review_level_section
          run = design_run
          assert_equal 'dispatched', host_advance(run)['status']
          sent = dispatched.last.last
          assert_equal 'design', sent['review_type']
          assert sent['artifact_content'].start_with?(LEVEL_HEADING), sent['artifact_content'][0, 80]
          assert_includes sent['artifact_content'], 'A finding about how to implement it is not a P0 of this review; ' \
                                                    'name it as P1 (implementation).'
          assert_includes sent['artifact_content'], '# x design v0.1'
          stored = File.read(entries(run, 'review_dispatched').last['bundle_file'])
          assert_equal sent['artifact_content'], stored
        end

        def test_a_document_bundle_has_the_level_section_and_says_work_under_review_not_implementation
          doc_repo!
          doc = started('template' => 'doc_cycle')
          commit_paper(doc, "# Paper\n\nA second draft.\n")
          assert_equal 'phase_ended', host_advance(doc)['status']
          assert_equal 'dispatched', host_advance(doc)['status']
          sent = dispatched.last.last
          assert_equal 'document', sent['review_type']
          assert sent['artifact_content'].start_with?(LEVEL_HEADING)
          assert_includes sent['artifact_content'], '## Work under review', 'not an implementation: the heading says work'
          refute_includes sent['artifact_content'], '## Implementation under review'
          refute_match(/^## The .* this work follows/, sent['artifact_content'], 'a document run has no earlier produce phase')
          assert_includes sent['artifact_content'], '+A second draft.'
        end

        def test_an_implementation_bundle_has_no_level_section_and_says_implementation_under_review
          repo!('test/test_ok.rb' => "exit 0\n", 'lib/x.rb' => "X = 1\n")
          run = started('template' => 'impl_cycle', 'tests' => 'test')
          wt = run.worktree
          assert_equal 'allow', host_edit(File.join(wt, 'lib', 'x.rb'), 'X = 1', 'X = 2', cwd: wt)
          host_commit(run, 'x is two')
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          sent = dispatched.last.last
          assert_equal 'implementation', sent['review_type']
          refute_includes sent['artifact_content'], LEVEL_HEADING
          assert sent['artifact_content'].start_with?('## Implementation under review')
          refute_includes sent['artifact_content'], '## Work under review'
        end

        def test_a_survey_run_writes_versioned_files_and_its_review_is_a_document_review
          run = started('template' => 'survey', 'output_glob' => 'log/caching_survey_v*.md', 'goal' => 'survey caching')
          assert_nil run.worktree, 'a survey has no check phase and so no branch'
          assert_equal %i[survey survey_review], run.plan.phase_names
          path = File.join(@root, 'log', 'caching_survey_v0.1.md')
          assert_equal 'allow', host_write(path, "# Caching survey v0.1\nSources: [1] ...\n", cwd: @root)
          out = host_advance(run)
          assert_equal ['phase_ended', path], out.values_at('status', 'artifact'), out.inspect
          assert_equal 'dispatched', host_advance(run)['status']
          sent = dispatched.last.last
          assert_equal ['document', 'caching_survey_v0.1.md'], sent.values_at('review_type', 'artifact_name')
          assert sent['artifact_content'].start_with?(LEVEL_HEADING)
        end

        # --- the cap is the policy's spend; a plan's own cap also waits -----------------------------------

        def test_the_policys_rounds_for_each_review_are_the_only_cap_and_the_review_then_waits_with_one_review_open_item
          review_rounds!(2)
          run = design_run
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          assert_equal 'open', out['status'], 'round 1 of 2: ' + out.inspect
          next_version('0.2')
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A],
                                  labelled: [lab(P0_A, 'carried_over', earlier: 'DR1.F1', covers: [0])])
          assert_equal 'waiting', out['status'], 'round 2 is the last this review may take: ' + out.inspect
          item = run.reload.items[out['item']]
          assert_equal 'review_open', item['item_kind']
          assert_equal 'design_review is open (1 P0) and has had its 2 rounds; ' \
                       'it waits for the operator (decision more_rounds, or freeze)', item['text']
          assert_equal [P0_A], out['labels'].select { |l| l['open'] }.map { |l| l['text'] }
          assert_empty asks('round_bound'), 'nothing asks the stand-in at the cap'

          next_version('0.3')
          again = host_advance(run)
          assert_equal ['waiting', out['item']], again.values_at('status', 'item'), 'a dispatch past the cap waits on the same item'
          assert_equal 'design_review is at its round cap; it waits for the operator', again['reason']
          assert_equal 2, dispatched.size
          assert_equal 1, run.reload.open_items.count { |i| i['item_kind'] == 'review_open' }
          assert_empty run.open_items.select { |i| i['item_kind'] == 'blocking' }, 'it used to be a blocking item with status refused'
        end

        def test_a_cap_a_plan_names_also_waits_with_a_review_open_item_and_takes_the_place_of_the_policys
          adopt! unless Policies.new(@paths).adopted
          src = "run \"capped\", template: :design_only do\n  goal \"design x\"\n  phase(:design)        { produce \"log/x_design_v*.md\" }\n" \
                "  phase(:design_review) { review :mlr, of: :design, max_rounds: 1 }\n  report :layered_deck\nend\n"
          plan = DSL.parse_plan(src).check_against(@policy)
          run = Run.create(@paths, goal: 'design x', target_repo: @root, worktree: nil, branch: nil, plan: plan, policy: @policy)
          FileUtils.mkdir_p(@paths.guard_seen_dir)
          FileUtils.touch(File.join(@paths.guard_seen_dir, 's1'))
          run.bind('s1', transcript_path: @transcript)
          run.append(:plan_parameters, template: 'design_only', args: { 'goal' => 'design x' }, source: 'test')
          write_design('0.1', "# x design v0.1\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          assert_equal 'waiting', out['status'], 'round 1 is the plan\'s cap: ' + out.inspect
          assert_equal 'review_open', run.reload.items[out['item']]['item_kind']
          assert_operator @policy.spend[:review_rounds], :>, 1, 'the policy would have allowed more rounds'
          next_version('0.2')
          again = host_advance(run)
          assert_equal ['waiting', out['item']], again.values_at('status', 'item'), again.inspect
          assert_equal 'design_review is at its round cap; it waits for the operator', again['reason']
          assert_equal 1, dispatched.size
        end

        # --- rounds are counted for each review apart (design v0.6.6) -----------------------------

        def dev_cycle_repo!
          repo!('test/test_ok.rb' => "exit 0\n", 'lib/x.rb' => "X_VALUE = 1\n")
        end

        def start_dev_cycle
          started('template' => 'dev_cycle', 'design_glob' => 'log/x_design_v*.md', 'tests' => 'test')
        end

        # The design review closes at round 1 and the code is committed and checked.
        def dev_cycle_at_implementation_review(run)
          write_design('0.1', "# x design v0.1\nINV-1: the cache holds at most 100 entries.\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: APPROVE)
          labels([])
          assert_equal 'closed_provisionally', review_reply(run)['status']
          commit_x(run, 2)
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'implementation_review', run.reload.current_phase
        end

        def commit_x(run, n)
          wt = run.worktree
          x = File.join(wt, 'lib', 'x.rb')
          assert_equal 'allow', host_edit(x, /X_VALUE = \d+/.match(File.read(x))[0], "X_VALUE = #{n}", cwd: wt)
          host_commit(run, "x is #{n}")
        end

        # One round of the implementation review on a new commit; returns the review's reply.
        def implementation_round(run, n, reviews:, labelled:, p0_lines: [])
          commit_x(run, n)
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: reviews, p0_lines: p0_lines)
          labels(labelled)
          review_reply(run, 'implementation_review')
        end

        # (a) The design review's rounds are not the implementation review's.
        def test_a_design_review_using_both_its_rounds_leaves_the_implementation_review_its_own_two
          dev_cycle_repo!
          review_rounds!(2)
          run = start_dev_cycle
          write_design('0.1', "# x design v0.1\nINV-1: the cache holds at most 100 entries.\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          assert_equal 'open', out['status'], out.inspect
          next_version('0.2', "Entries are evicted on insert (LRU).\n")
          out = design_round(run, reviews: APPROVE, labelled: [lab(P0_A, 'fixed', earlier: 'DR1.F1')])
          assert_equal 'closed_provisionally', out['status'], out.inspect
          assert_equal 2, run.reload.phases['design_review']['rounds'], 'the design review used both its rounds'
          assert_equal 2, run.counters['review_rounds'], 'the run-wide count of dispatches still counts them'

          commit_x(run, 2)
          assert_equal 'phase_ended', host_advance(run)['status']
          out = implementation_round(run, 3, reviews: revise(P0_B), p0_lines: [P0_B], labelled: [lab(P0_B, 'new', covers: [0])])
          assert_equal 'open', out['status'], 'round 1 of its own 2 rounds: ' + out.inspect
          assert_equal 1, run.reload.phases['implementation_review']['rounds']
          out = implementation_round(run, 4, reviews: revise(P0_B), p0_lines: [P0_B],
                                             labelled: [lab(P0_B, 'carried_over', earlier: 'IR1.F1', covers: [0])])
          assert_equal 'waiting', out['status'], 'round 2 is its own cap: ' + out.inspect
          assert_equal 2, run.reload.phases['implementation_review']['rounds']
          assert_equal 4, run.counters['review_rounds']
          item = run.items[out['item']]
          assert_equal ['review_open', 'implementation_review'], [item['item_kind'], item.dig('state_ref', 'ref')]
          assert_equal 'implementation_review is open (1 P0) and has had its 2 rounds; it waits for the operator ' \
                       '(decision more_rounds, or freeze)', item['text']
          assert_equal 4, dispatched.size

          commit_x(run, 5)
          again = host_advance(run)
          assert_equal ['waiting', out['item']], again.values_at('status', 'item'), again.inspect
          assert_equal 'implementation_review is at its round cap; it waits for the operator', again['reason']
          assert_equal 4, dispatched.size, 'a third implementation round needs the operator'
          assert_empty entries(run, 'spend_extended')
        end

        # (b) More rounds are granted to one review.
        def test_more_rounds_on_one_reviews_item_extends_only_that_reviews_cap
          dev_cycle_repo!
          review_rounds!(1)
          run = start_dev_cycle
          dev_cycle_at_implementation_review(run)
          out = implementation_round(run, 3, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          assert_equal 'waiting', out['status'], out.inspect
          item = out['item']
          assert_equal [1, 1], [review_cap(run, 'design_review'), review_cap(run, 'implementation_review')]

          type!("#{item} はあと 2 周回して", 'p-two-more')
          res = resolve(run, item, 'more_rounds', rounds: 2)
          assert_equal 'recorded', res['status'], res.inspect
          refute res['item_open'], res.inspect
          extended = entries(run, 'rounds_extended')
          assert_equal [['implementation_review', 2, item]], extended.map { |e| e.values_at('phase', 'by', 'item') }
          assert_equal 1, review_cap(run, 'design_review'), 'the design review\'s cap is not touched'
          assert_equal 3, review_cap(run, 'implementation_review')
          assert_equal 0, run.round_extensions['design_review'].to_i
          assert_equal 1, run.spend['review_rounds'], 'the policy\'s rounds are not changed'
          assert_empty entries(run, 'spend_extended')

          out = implementation_round(run, 4, reviews: revise(P0_A), p0_lines: [P0_A],
                                             labelled: [lab(P0_A, 'carried_over', earlier: 'IR1.F1', covers: [0])])
          assert_equal 'open', out['status'], 'round 2 of 3: ' + out.inspect
          out = implementation_round(run, 5, reviews: APPROVE, labelled: [lab(P0_A, 'fixed', earlier: 'IR1.F1')])
          assert_equal ['closed_provisionally', 3], out.values_at('status', 'round')
        end

        def test_a_send_back_gives_rounds_to_each_reopened_review_only
          dev_cycle_repo!
          review_rounds!(1)
          run = start_dev_cycle
          write_design('0.1', "# x design v0.1\n")
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          collect_round(reviews: APPROVE)
          labels([])
          closed = review_reply(run)
          assert_equal 'closed_provisionally', closed['status']
          commit_x(run, 2)
          assert_equal 'phase_ended', host_advance(run)['status']
          assert_equal 'dispatched', host_advance(run)['status']
          assert_equal 'closed_provisionally', review_reply(run, 'implementation_review')['status']

          type!("#{closed['item']} は差し戻して", 'p-back')
          res = resolve(run, closed['item'], 'send_back')
          refute res['item_open'], res.inspect
          assert_equal [['design_review', 1], ['implementation_review', 1]],
                       entries(run, 'rounds_extended').map { |e| e.values_at('phase', 'by') }
          assert_equal [2, 2], [review_cap(run, 'design_review'), review_cap(run, 'implementation_review')]
          assert_empty entries(run, 'spend_extended')
          assert_equal 1, run.spend['review_rounds']
        end

        # (c) There is no more_spend decision any more.
        def test_a_more_spend_decision_on_a_review_open_item_is_refused_like_an_unknown_decision
          review_rounds!(1)
          run = design_run
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          assert_equal 'waiting', out['status'], out.inspect
          item = run.reload.items[out['item']]
          assert_equal %w[freeze more_rounds], Service.allocate.decisions_for(item)

          type!("#{item['id']} は 1 周分追加して", 'p-spend')
          spend = resolve(run, item['id'], 'more_spend')
          assert_equal 'recorded', spend['status'], spend.inspect
          assert spend['item_open'], spend.inspect
          assert_includes spend['reason'], 'stays open: resolving it needs a decision (freeze | more_rounds)'
          bogus = resolve(run, item['id'], 'bogus')
          assert bogus['item_open'], bogus.inspect
          assert_equal bogus['reason'], spend['reason'], 'more_spend is refused exactly as an unknown decision is'
          assert_equal 'open', run.reload.items[item['id']]['state']
          assert_empty entries(run, 'rounds_extended')
          assert_empty entries(run, 'spend_extended')
          assert_equal 1, review_cap(run, 'design_review')
          assert_equal 'waiting', host_advance(run)['status'], 'the review still waits'

          # The decision is gone from the lists and from the words that read decisions.
          refute_includes Service::DECISION_WORDS.keys, 'more_spend'
          spend_bound = { 'item_kind' => 'blocking', 'text' => 'design_review: the policy\'s review spend bound is reached' }
          refute_includes Service.allocate.decisions_for(spend_bound).to_a, 'more_spend'
        end

        def test_an_operator_freeze_carries_the_open_p0s_as_items_but_not_into_a_later_review
          review_rounds!(1)
          run = design_run
          out = design_round(run, reviews: revise(P0_A), p0_lines: [P0_A], labelled: [lab(P0_A, 'new', covers: [0])])
          assert_equal 'waiting', out['status'], out.inspect
          type!("#{out['item']} は凍結して", 'p-freeze')
          res = resolve(run, out['item'], 'freeze')
          refute res['item_open'], res.inspect
          items = run.reload.open_items.select { |i| i['item_kind'] == 'carried_p0' }
          assert_equal [P0_A], items.map { |i| i.dig('detail', 'text') }
          assert_nil items.first.dig('detail', 'deferred'), 'a freeze is not a deferral'
          assert_equal 'operator', run.phases['design_review']['by']
          assert_nil run.current_phase
        end
      end
    end
  end
end
