# frozen_string_literal: true

# Design v0.7.2 INV-8: the policy report. Built over a temporary data
# directory: two policies and an adoption record, a chain file in the shape
# the core's file backend writes (a JSON array of blocks whose data holds
# JSON strings), run journals written through Journal (by Run), and operator
# acts stored the way Service#operator_act stores them. Every name and every
# word here is synthetic.
require 'minitest/autorun'
require 'tmpdir'
require 'find'
require 'open3'
require 'rbconfig'
require_relative '../lib/agent/policy_report'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1PolicyReport < Minitest::Test
        POLICY = <<~RUBY
          policy "sample_policy_a" do
            stand_in may: [:precedent, :instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            free_of_personal_data projects: []
            spend default: { review_rounds: 2, stand_in_calls: 10 }
          end
        RUBY

        # Precedent is not allowed here: a "decided" answer citing both a
        # precedent and the instruction mode stood on the instruction mode.
        OTHER = <<~RUBY
          policy "sample_policy_b" do
            stand_in may: [:instruction_mode, :novel_reversible]
            consent review: :configured_providers, of: :project_artifacts
            spend default: { review_rounds: 3, stand_in_calls: 20 }
          end
        RUBY

        PLAN = <<~RUBY
          run "r", template: :dev_cycle do
            goal "g"
            phase(:design)        { produce "log/x_design_v*.md" }
            phase(:design_review) { review :mlr, of: :design }
          end
        RUBY

        NOW = Time.utc(2026, 10, 21, 12, 0, 0)
        BIN = File.expand_path('../bin/agent_policy_report.rb', __dir__)

        def setup
          @dir = Dir.mktmpdir('agent1')
          @global = ENV['KAIROS_AGENT_GLOBAL']
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@dir, 'global_bound_sessions.txt')
          @data = File.join(@dir, '.kairos')
          @paths = Paths.new(@data)
          FileUtils.mkdir_p(@paths.policies_dir)
          File.write(File.join(@paths.policies_dir, 'sample_policy_a.rb'), POLICY)
          File.write(File.join(@paths.policies_dir, 'sample_policy_b.rb'), OTHER)
          @chain = []
          @act_seq = 0
        end

        def teardown
          ENV['KAIROS_AGENT_GLOBAL'] = @global
          FileUtils.rm_rf(@dir)
        end

        # --- fixtures -------------------------------------------------------------

        def adopt!(source = POLICY, name = 'sample_policy_a')
          @paths.ensure_ignored
          File.open(@paths.adoptions_path, 'a') do |f|
            f.puts(JSON.generate('name' => name, 'digest' => DSL.digest(source), 'at' => '2026-10-21T09:00:00Z',
                                 'words_sha256' => '0' * 64, 'transcript_path' => '/nonexistent/transcript.jsonl'))
          end
        end

        # Every run gets the start record Service#start writes (its journal
        # digest names a real line), as real chains hold; only end records count.
        def run!(project, policy = POLICY)
          run = Run.create(@paths, goal: 'g', target_repo: File.join(@dir, project), worktree: File.join(@dir, 'wt'),
                                   branch: 'agent-run/x', plan: DSL.parse_plan(PLAN), policy: DSL.parse_policy(policy))
          @chain << { 'type' => 'agent_run_start', 'run_id' => run.id, 'journal_digest' => run.journal.digest,
                      'policy_digest' => run.policy_digest, 'plan_digest' => run.plan_digest }
          write_chain
          run
        end

        def decide(run, point, klass, answer: 'yes', basis: [], given: [], reason: 'r', calls: 1, question: 'a question')
          a = StandIn::Answer.new(answer: answer, klass: klass, confidence: 0.9, basis: basis, reason: reason,
                                  calls: calls, inputs_digest: 'x', inputs: { 'precedent_ids' => given })
          run.record_decision(point, question, a)
        end

        # As Service#operator_act stores an act.
        def act(run, ref, kind, words)
          @act_seq += 1
          Precedents.new(@paths.precedents_dir).add(
            [{ 'source' => "run #{run.id} #{ref}", 'project' => File.basename(run.target_repo.to_s),
               'at' => format('2026-10-21T10:00:%02dZ', @act_seq), 'kind' => kind, 'kind_by' => 'actor reading',
               'question' => 'q', 'words' => words, 'ref' => ref }], file: 'operator_acts.jsonl'
          )
        end

        def resolve(run, item_id, decision, words)
          act(run, item_id, 'ruling', words)
          run.append(:item_resolved, id: item_id, resolution: 'resolve', words_sha256: Digest::SHA256.hexdigest(words),
                                     decision: decision)
        end

        def round(run, n, seats)
          run.append(:review_dispatched, phase: 'design_review', round: n, token: "t#{n}")
          run.append(:review_round, phase: 'design_review', round: n, counted: seats.size, quorum: 2,
                                    seats: seats.map { |s, v| { 'seat' => s, 'verdict' => v } })
        end

        # A chain end record as Service#record_chain writes it.
        def end!(run, digest = run.journal.digest)
          @chain << { 'type' => 'agent_run_end', 'run_id' => run.id, 'journal_digest' => digest,
                      'policy_digest' => run.policy_digest, 'plan_digest' => run.plan_digest }
          write_chain
        end

        # The core's file backend: JSON.pretty_generate of Block#to_h, a
        # genesis block first, each later block's data an array of strings.
        def write_chain
          prev = '0' * 64
          blocks = [{ 'index' => 0, 'timestamp' => '1970-01-01T00:00:00.000000Z', 'data' => ['Genesis Block'],
                      'previous_hash' => prev, 'merkle_root' => prev }]
          blocks[0]['hash'] = Digest::SHA256.hexdigest(blocks[0].values.join)
          @chain.each_with_index do |rec, i|
            data = [JSON.generate(rec)]
            b = { 'index' => i + 1, 'timestamp' => '2026-10-21T11:00:00.000000Z', 'data' => data,
                  'previous_hash' => blocks.last['hash'], 'merkle_root' => Digest::SHA256.hexdigest(data.first) }
            b['hash'] = Digest::SHA256.hexdigest([b['index'], b['timestamp'], b['previous_hash'], b['merkle_root'],
                                                  data.to_json].join)
            blocks << b
          end
          path = File.join(@data, 'storage', 'blockchain.json')
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate(blocks))
        end

        # Four runs: A counted (two end records, lines after the last one),
        # B with no end record, C whose recorded digest matches no line, D
        # counted and pinned to the other policy.
        def world!
          adopt!
          a = run!('proj_alpha')
          @d_prec = decide(a, 'question', 'decided', basis: ['P001'], given: ['P001'])
          @d_mode = decide(a, 'prose_question', 'decided', basis: ['instruction_mode'], question: 'which layout?')
          decide(a, 'plan_approval', 'decided_novel', answer: 'approve')
          decide(a, 'question', 'operator_item', answer: nil, reason: StandIn::SPENT, calls: 0)
          decide(a, 'review_labels', 'decided', answer: [])
          decide(a, 'data_check', 'decided', answer: 'clean')
          decide(a, 'data_check', 'decided', answer: 'carries_personal_or_third_party_data')
          decide(a, 'hazard', 'decided', answer: 'not_a_hazard')
          round(a, 1, [%w[seat_one REJECT], %w[seat_two APPROVE]])
          round(a, 2, [%w[seat_one REJECT], %w[seat_two REJECT]])
          cap = a.open_item('review_open', 'design_review is not closed and has had its 2 rounds; it waits for the ' \
                                           'operator (decision more_rounds, or freeze)', ref: 'design_review')
          @round_words = "#{cap['id']}: one more round, please"
          resolve(a, cap['id'], 'more_rounds', @round_words)
          a.append(:rounds_extended, phase: 'design_review', by: 1, item: cap['id'])
          a.open_item('blocking', 'design_review: bundle part 1 may carry personal or third-party data', ref: 'design_review')
          calls = a.open_item('blocking', "design_review round 2: the policy's stand-in call bound is reached; the " \
                                          "seats' findings cannot be labelled (decision more_calls)", ref: 'design_review')
          @calls_words = "#{calls['id']}: add 2 more calls"
          resolve(a, calls['id'], 'more_calls', @calls_words)
          a.append(:spend_extended, counter: 'stand_in_calls', by: 100, item: calls['id'])
          @correction_words = "#{@d_mode['id']} was wrong: keep the plain layout"
          act(a, @d_mode['id'], 'correction', @correction_words)
          @confirm_words = "#{@d_prec['id']} is right"
          act(a, @d_prec['id'], 'confirmation', @confirm_words)
          end!(a)
          # Between the two end records: counted.
          round(a, 3, [%w[seat_one REJECT], %w[seat_two APPROVE], %w[seat_three APPROVE]])
          cap2 = a.open_item('review_open', 'design_review is open (1 P0) and has had its 3 rounds; it waits for the ' \
                                            'operator (decision more_rounds, or freeze)', ref: 'design_review')
          @freeze_words = "#{cap2['id']}: freeze it here"
          resolve(a, cap2['id'], 'freeze', @freeze_words)
          a.append(:phase_ended, phase: 'design_review', by: 'operator', provisional: false, item: cap2['id'])
          waive = a.open_item('blocking', 'design_review: the check on the reviewed commit failed (decision freeze)',
                              ref: 'design_review')
          @waive_words = "#{waive['id']}: accept the check as it stands"
          resolve(a, waive['id'], 'freeze', @waive_words)
          a.append(:check_waived, phase: 'design_review', item: waive['id'], commit: 'c0ffee')
          decide(a, 'question', 'decided_novel', question: 'between the ends')
          end!(a)
          @a_counted = a.journal.lines.size
          # After the last end record: not counted.
          late = decide(a, 'question', 'decided_novel', question: 'AFTER_END_QUESTION')
          act(a, late['id'], 'correction', "#{late['id']} AFTER_END_WORDS")
          @a_total = a.journal.lines.size

          b = run!('proj_beta')
          decide(b, 'question', 'decided_novel')
          c = run!('proj_beta')
          decide(c, 'question', 'decided_novel')
          end!(c, 'f' * 64)
          d = run!('proj_gamma', OTHER)
          decide(d, 'question', 'decided', basis: %w[P009 instruction_mode], given: ['P009'])
          decide(d, 'data_check', 'decided', answer: 'clean')
          end!(d)
          @runs = { a: a, b: b, c: c, d: d }
        end

        def report
          PolicyReport.new(@paths, now: NOW).markdown
        end

        def listing
          out = {}
          Find.find(@dir) do |p|
            out[p.delete_prefix(@dir)] = File.directory?(p) ? :dir : Digest::SHA256.file(p).hexdigest
          end
          out
        end

        # --- runs counted -----------------------------------------------------------

        def test_counted_and_uncounted_runs
          world!
          r = report
          a, b, c, d = @runs.values_at(:a, :b, :c, :d)
          assert_includes r, 'Counted: 2 of 4'
          listed = r[r.index('## Runs')...r.index('## Rule: ')]
          assert_equal 1, listed.scan(/^\| #{a.id} \|/).size, 'a run with two end records is counted once'
          assert_includes r, "| #{a.id} | sample_policy_a #{a.policy_digest[0, 12]} | #{@a_counted} of #{@a_total} | yes |"
          assert_operator @a_counted, :<, @a_total
          assert_includes r, "Journals with no chain end record (1 of 4): #{b.id}"
          assert_includes r, "Journals whose recorded digest matches no line (1 of 4): #{c.id}"
          refute_includes r, "| #{b.id} |"
          refute_includes r, "| #{c.id} |"
          assert_match(/^\| #{d.id} \| sample_policy_b #{d.policy_digest[0, 12]} \|.*\| pinned to a policy other than the adopted one \|$/, r)
          refute_match(/^\| #{a.id} \|.*pinned to a policy other/, r)
          assert_includes r, '1 of 2 ran under a policy other than the adopted one'
          # Entries after the last recorded end are not counted.
          refute_includes r, 'AFTER_END_QUESTION'
          refute_includes r, 'AFTER_END_WORDS'
          assert_includes r, 'Adopted: `sample_policy_a`'
        end

        # --- the rules ----------------------------------------------------------------

        def test_stand_in_classes_are_derived_and_corrections_quoted
          world!
          r = report
          # A: precedent, instruction_mode, novel (plan_approval), operator_item,
          # novel (between the ends); D: a "decided" citing a precedent under a
          # policy that does not allow precedent stood on the instruction mode.
          assert_includes r, '| precedent | 1 of 6 | allows |'
          assert_includes r, '| instruction_mode | 2 of 6 | allows |'
          assert_includes r, '| novel_reversible | 2 of 6 | allows |'
          assert_includes r, "| operator_item | 1 of 6 | the operator's |"
          assert_includes r, 'Of the 1 operator_item: 1 had no answer because the stand-in call bound was reached'
          assert_includes r, 'review_labels 1, data_check 3, hazard 1'
          assert_includes r, '5 of 11 decisions in counted runs'
          assert_includes r, 'Corrections: 1 of 6 decisions corrected'
          assert_includes r, "- #{@runs[:a].id} #{@d_mode['id']} (prose_question, instruction_mode; question: \"which layout?\")"
          assert_includes r, "  > #{@correction_words}"
          assert_includes r, 'Other acts naming these decisions: confirmation 1.'
          assert_includes r, "  > #{@confirm_words}"
        end

        def test_review_rounds_cap_hits_grants_and_freezes
          world!
          r = report
          a = @runs[:a]
          assert_includes r, "| #{a.id} · design_review | 3 of 3 (2 + 1 granted) | 2 | the operator (freeze) |"
          assert_includes r, 'Reviews that reached their cap: 1 of 1 (cap hits in all: 2).'
          assert_includes r, 'Rounds granted (rounds_extended): 1 grant, 1 round, answering 2 cap hits'
          assert_match(/^- #{a.id} design_review: \+1 round, decision more_rounds on I\d+, the resolving act's words:$/, r)
          assert_includes r, "  > #{@round_words}"
          assert_includes r, 'Frozen by the operator: 1 of 1 reviews.'
          assert_match(/^- #{a.id} design_review: frozen, decision freeze on I\d+, the resolving act's words:$/, r)
          assert_includes r, "  > #{@freeze_words}"
          assert_includes r, 'Checks waived on a review: 1.'
          assert_match(/^- #{a.id} design_review: check waived, decision freeze on I\d+, the resolving act's words:$/, r)
          assert_includes r, "  > #{@waive_words}"
          assert_includes r, PolicyReport::CAP_SIGNAL
          refute_match(/頻繁|収束条件/, r)
        end

        def test_stand_in_calls_grants_carry_the_unit
          world!
          r = report
          a, d = @runs.values_at(:a, :d)
          assert_includes r, 'Unit: each grant is 50 calls per count'
          assert_includes r, "| #{a.id} | 8 of 110 (10 at start + 100 granted) | yes |"
          assert_includes r, "| #{d.id} | 2 of 20 (20 at start) | no |"
          assert_includes r, 'Runs that reached the bound: 1 of 2.'
          assert_match(/^- #{a.id}: \+100 calls \(2 counts × 50\), decision more_calls on I\d+, the resolving act's words:$/, r)
          assert_includes r, "  > #{@calls_words}"
        end

        def test_data_checks_and_consent
          world!
          r = report
          a = @runs[:a]
          assert_includes r, '| proj_alpha | no | 1 of 2 | 1 |'
          assert_includes r, '| proj_gamma | no | 1 of 1 | 0 |'
          assert_includes r, 'Of the 1 data check not clean: 1 answered that the part carries personal or third-party data'
          assert_includes r, 'Adopted: review :configured_providers of :project_artifacts.'
          assert_includes r, 'Rounds collected: 3 of 3 dispatched'
          assert_includes r, "- #{a.id} · design_review round 3: counted 3 of 3 seats with a reply, quorum 2: " \
                             'seat_one (REJECT), seat_two (APPROVE), seat_three (APPROVE)'
        end

        def test_every_section_states_what_it_cannot_show_and_how_a_policy_changes
          world!
          r = report
          sections = r.scan(/^## Rule: /).size
          assert_equal 5, sections
          assert_equal sections, r.scan(PolicyReport::CAVEAT).size
          assert_includes PolicyReport::CAVEAT, 'in both directions'
          assert_includes PolicyReport::CAVEAT, 'a refusal read as a grant'
          closing = r[r.index('## How a policy changes')..]
          assert_includes closing, File.join(@paths.policies_dir, 'sample_policy_a.rb')
          assert_includes closing, 'change the name in its `policy "…"` line'
          assert_includes closing, 'only the first file by name that parses is ever found'
          assert_includes closing, '`adopt policy <name> <first 8 hex digits'
          assert_includes closing, 'agent_items is called with action adopt_policy'
          assert_includes closing, "carries the actor's readings into the mandate"
          assert_includes closing, 'This report never changes a policy.'
        end

        def test_the_report_is_deterministic_but_for_its_generation_line
          world!
          one = PolicyReport.new(@paths, now: NOW).markdown
          two = PolicyReport.new(@paths, now: NOW + 3600).markdown
          refute_equal one, two
          strip = ->(t) { t.lines.reject { |l| l.start_with?('Generated: ') }.join }
          assert_equal strip.call(one), strip.call(two)
        end

        # --- no material ------------------------------------------------------------

        def test_no_chain_file_and_no_runs_say_there_is_no_material
          adopt!
          r = report
          assert_includes r, 'No chain file at'
          assert_includes r, 'There is no material yet: 0 journals found'
          refute_includes r, '## Rule: '
          assert_includes r, '## How a policy changes'

          # The run's start record is on the chain; a start is not an end.
          run!('proj_alpha')
          r = report
          assert_includes r, 'holds 0 agent_run_end records for 0 run ids'
          assert_includes r, 'There is no material yet: 1 journal found'
          assert_includes r, 'Journals with no chain end record (1 of 1)'
        end

        def test_without_an_adopted_policy_runs_are_still_reported
          world!
          File.delete(@paths.adoptions_path)
          r = report
          assert_includes r, 'No policy is adopted'
          assert_includes r, 'Counted: 2 of 4'
          assert_includes r, '| precedent | 1 of 6 | — |'
          refute_includes r, 'pinned to a policy other than the adopted one'

          # An adoption whose bytes no file has any more adopts nothing.
          adopt!(POLICY + "\n# edited\n")
          assert_includes report, 'No policy is adopted: the latest adoption names `sample_policy_a`'
        end

        # --- writing ------------------------------------------------------------------

        def test_writes_one_new_file_under_policy_reports_and_nothing_else
          world!
          before = listing
          first = PolicyReport.new(@paths, now: NOW).write
          second = PolicyReport.new(@paths, now: NOW).write
          dir = File.join(@data, 'storage', 'agent', 'policy_reports')
          assert_equal File.join(dir, '20261021-120000.md'), first
          assert_equal File.join(dir, '20261021-120000-2.md'), second, 'an existing report is never overwritten'
          assert_equal "*\n", File.read(File.join(@data, 'storage', 'agent', '.gitignore'))
          after = listing
          new_paths = [dir, first, second].map { |p| p.delete_prefix(@dir) }
          assert_equal before, after.reject { |k, _| new_paths.include?(k) }, 'nothing else changed'
          assert_equal new_paths.sort, (after.keys - before.keys).sort
        end

        # A file in a run directory is never evaluated: not the pinned policy's
        # copy, not the plan, not a plan an amendment names by a crafted digest.
        def test_no_file_from_a_run_directory_is_evaluated
          world!
          a = @runs[:a]
          marker = File.join(@dir, 'evaluated')
          payload = "::File.write(#{marker.inspect}, 'ran')\n"
          %w[policy.rb plan.rb].each do |f|
            path = File.join(a.dir, f)
            File.write(path, payload + File.read(path))
          end
          outside = File.join(@data, 'storage', 'outside_evil.rb')
          File.write(outside, payload)
          FileUtils.mkdir_p(File.join(a.dir, 'plans'))
          a.append(:plan_amended, digest: '../../../../outside_evil')
          end!(a)
          assert_equal outside, File.expand_path('../../../../outside_evil.rb', File.join(a.dir, 'plans'))
          r = report
          refute File.exist?(marker), 'a run-directory file was evaluated'
          assert_includes r, "| #{a.id} | sample_policy_a #{a.policy_digest[0, 12]} |"
          assert_includes r, 'a lower cap a plan set for one review is not read'
        end

        def test_a_gitignore_that_does_not_ignore_everything_stops_the_report
          FileUtils.mkdir_p(@paths.root)
          File.write(File.join(@paths.root, '.gitignore'), "runs/\n")
          error = assert_raises(IOError) { PolicyReport.new(@paths, now: NOW).write }
          assert_includes error.message, "is not a regular file holding exactly the line '*'"
          refute File.exist?(File.join(@paths.root, 'policy_reports')), 'no report written'
        end

        # Without the pinned policy in place the one policy-dependent answer is
        # not classed, and the runs table says why.
        def test_a_run_whose_pinned_policy_is_gone_is_not_classed_by_assumption
          world!
          File.delete(File.join(@paths.policies_dir, 'sample_policy_b.rb'))
          r = report
          d = @runs[:d]
          assert_match(/^\| #{d.id} \|.*pinned policy not in place; an answer citing both a precedent and the mode is unclassified/, r)
          assert_equal 'unclassified', PolicyReport.new(@paths).send(:derived_class,
                                                                      { 'class' => 'decided', 'basis' => %w[P009 instruction_mode],
                                                                        'inputs' => { 'precedent_ids' => ['P009'] } }, nil)
        end

        def test_a_gitignore_that_un_ignores_anything_stops_the_report
          FileUtils.mkdir_p(@paths.root)
          ["*\n!policy_reports/\n", " *\n", "* \n", "*\n*.md\n", '*'].each do |content|
            File.write(File.join(@paths.root, '.gitignore'), content)
            assert_raises(IOError, content.inspect) { PolicyReport.new(@paths, now: NOW).write }
            refute File.exist?(File.join(@paths.root, 'policy_reports')), "no report written for #{content.inspect}"
          end
        end

        # git does not read a .gitignore that is a symbolic link, so one is
        # refused even when the file it points to holds exactly '*'.
        def test_a_symlinked_gitignore_stops_the_report
          FileUtils.mkdir_p(@paths.root)
          target = File.join(@dir, 'elsewhere_ignore')
          File.write(target, "*\n")
          File.symlink(target, File.join(@paths.root, '.gitignore'))
          error = assert_raises(IOError) { PolicyReport.new(@paths, now: NOW).write }
          assert_includes error.message, 'is not a regular file'
          refute File.exist?(File.join(@paths.root, 'policy_reports')), 'no report written'
        end

        def test_a_fresh_data_dir_is_git_ignored_before_the_report_is_written
          FileUtils.mkdir_p(@data)
          path = PolicyReport.new(@paths, now: NOW).write
          assert File.exist?(path)
          assert_equal "*\n", File.read(File.join(@data, 'storage', 'agent', '.gitignore'))
        end

        def test_the_script_takes_data_dir_and_prints_the_path
          world!
          out, st = Open3.capture2e(RbConfig.ruby, BIN, '--data-dir', @data)
          assert st.success?, out
          path = out.strip
          assert_match(%r{\A#{Regexp.escape(File.join(@data, 'storage', 'agent', 'policy_reports'))}/\d{8}-\d{6}(-\d+)?\.md\z}, path)
          assert_includes File.read(path), 'Counted: 2 of 4'

          missing = File.join(@dir, 'nowhere', '.kairos')
          out, st = Open3.capture2e(RbConfig.ruby, BIN, '--data-dir', missing)
          refute st.success?
          assert_includes out, 'no data directory'
          refute File.exist?(File.join(@dir, 'nowhere'))
        end
      end
    end
  end
end
