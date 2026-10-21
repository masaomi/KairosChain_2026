# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/agent/run'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1JournalRun < Minitest::Test
        POLICY = <<~RUBY
          policy "p1" do
            stand_in may: [:precedent, :instruction_mode]
            spend default: { review_rounds: 4, stand_in_calls: 10 }
          end
        RUBY

        PLAN = <<~RUBY
          run "r", template: :dev_cycle do
            goal "g"
            phase(:design)        { produce "log/x_design_v*.md" }
            phase(:design_review) { review :mlr, of: :design, max_rounds: 2 }
          end
        RUBY

        def setup
          @dir = Dir.mktmpdir('agent1')
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@dir, 'global_bound_sessions.txt')
          @paths = Paths.new(File.join(@dir, '.kairos'))
          @run = Run.create(@paths, goal: 'g', target_repo: @dir, worktree: File.join(@dir, 'wt'),
                                    branch: 'agent-run/x', plan: DSL.parse_plan(PLAN),
                                    policy: DSL.parse_policy(POLICY))
        end

        def teardown
          FileUtils.rm_rf(@dir)
        end

        def test_journal_lines_chain_to_their_predecessor
          @run.append(:decision, id: 'D1', answer: 'yes', calls: 1)
          @run.append(:created, path: '/tmp/a')
          assert @run.journal.intact?
          lines = File.readlines(@run.journal.path)
          lines[1] = lines[1].sub('"yes"', '"no"')
          File.write(@run.journal.path, lines.join)
          refute @run.journal.intact?
        end

        def test_state_is_replayed_from_the_journal
          assert_equal 'running', @run.status
          assert_equal 'design', @run.current_phase
          @run.append(:phase_ended, phase: 'design', by: 'check')
          assert_equal 'design_review', @run.current_phase
          @run.append(:phase_ended, phase: 'design_review', by: 'closure', provisional: true)
          assert_nil @run.current_phase
          assert_equal %w[design_review], @run.provisional_closures
          again = Run.load(@paths, @run.id)
          assert_equal @run.state['phases'], again.state['phases']
        end

        def test_binding_requires_the_guard_to_have_been_seen
          assert_raises(ArgumentError) { @run.bind('s1', transcript_path: '/t') }
          FileUtils.mkdir_p(@paths.guard_seen_dir)
          FileUtils.touch(File.join(@paths.guard_seen_dir, 's1'))
          @run.bind('s1', transcript_path: '/t', prestart_words: ['do X'])
          assert_equal @run.id, Run.bound_to(@paths, 's1').id
          assert_nil Run.bound_to(@paths, 's2')
          @run.append(:interrupted, reason: 'session closed')
          assert_nil Run.bound_to(@paths, 's1'), 'an interrupted run is never re-entered silently'
        end

        def test_spend_counters_follow_decisions
          9.times { |i| @run.append(:decision, id: "D#{i}", calls: 1) }
          assert @run.within_spend?(:stand_in_calls)
          @run.append(:decision, id: 'D9', calls: 1)
          refute @run.within_spend?(:stand_in_calls)
        end

        def test_items_open_and_resolve
          item = @run.open_item('merge', 'merge the run branch', command: 'git merge agent-run/x')
          assert_match(/\AI\d+\z/, item['id'])
          other = Run.load(@paths, @run.id).open_item('blocking', 'from a second process')
          refute_equal item['id'], other['id'], 'ids are allocated under the journal lock'
          assert_equal 2, @run.reload.open_items.size
          @run.append(:item_resolved, id: item['id'], resolution: 'merged')
          assert_equal 1, @run.reload.open_items.size
          @run.append(:item_resolved, id: other['id'], resolution: 'done')
          assert_empty @run.open_items
        end
      end
    end
  end
end
