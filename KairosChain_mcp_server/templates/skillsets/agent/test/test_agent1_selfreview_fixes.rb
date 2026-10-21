# frozen_string_literal: true

# Regression tests for the implementation self-review of 2026-10-20.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../lib/agent/service'
require_relative 'test_agent1_hooks_service'
require_relative 'test_agent1_guard'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1SelfReviewFixes < Minitest::Test
        def test_typed_requires_human_origin_and_typed_source
          human = { 'type' => 'user', 'origin' => { 'kind' => 'human' }, 'promptSource' => 'typed',
                    'message' => { 'content' => '8 席で' } }
          assert Transcript.typed?(human)
          refute Transcript.typed?(human.merge('isCompactSummary' => true))
          refute Transcript.typed?(human.merge('message' => { 'content' => '/compact' }))
          refute Transcript.typed?(human.merge('message' => { 'content' => '[Request interrupted by user for tool use]' }))
          refute Transcript.typed?({ 'type' => 'user', 'message' => { 'content' => 'This session is being continued…' } })
          refute Transcript.typed?(human.merge('origin' => { 'kind' => 'peer' }))
        end

        def test_instruction_files_govern_wherever_they_are
          root = File.realpath(Dir.mktmpdir('g'))
          paths = Paths.new(File.join(root, '.kairos'))
          wt = File.join(root, '.claude', 'worktrees', 'w')
          FileUtils.mkdir_p(wt)
          run = TestAgent1Guard::FakeRun.new(id: 'r', worktree: wt, target_repo: root, branch: 'b', created_paths: [], pinned: {})
          pol = DSL.parse_policy("policy \"p\" do\n stand_in may: [:precedent]\n spend default: { stand_in_calls: 1 }\nend\n")
          g = Guard.new(run: run, paths: paths, policy: pol, project_root: root)
          assert g.decide('Write', { 'file_path' => File.join(root, 'sub', 'CLAUDE.md') }).refuse?
          assert g.decide('Write', { 'file_path' => File.join(wt, 'CLAUDE.md') }).refuse?
          assert g.decide('Write', { 'file_path' => File.join(root, '.claude', 'rules', 'x.md') }).refuse?
          assert g.decide('Write', { 'file_path' => File.join(wt, 'lib', 'x.rb') }).allow?
        ensure
          FileUtils.rm_rf(root) if root
        end

        def test_completeness_matches_whole_ids
          svc = Service.allocate
          run = Struct.new(:decisions, :items, :phases).new([], { 'I1' => {}, 'I10' => {} }, { 'design' => {}, 'design_review' => {} })
          missing = svc.send(:completeness, run, 'I10 design_review')
          assert_equal %w[I1 design], missing
        end

        def test_a_timed_out_command_is_killed
          svc = Service.allocate
          t0 = Time.now
          out, ok = svc.send(:default_run_cmd, ['/bin/bash', '-c', 'sleep 30'], Dir.pwd, 1)
          refute ok
          assert_operator Time.now - t0, :<, 10
          assert_includes out, 'timed out'
        end

        def test_after_an_ending_the_stop_hook_asks_only_for_the_report
          t = TestAgent1HooksService.new('x')
          t.setup
          run = t.start_design_run
          run.append(:run_ended, reason: 'stopped: test')
          out = t.hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'ok.')
          assert_equal 'block', out['decision']
          assert_includes out['reason'], 'Build the report'
          refute_includes out['reason'], 'Phase design'
          assert_nil t.hooks.handle('Stop', 'session_id' => 's1', 'last_assistant_message' => 'ok.'),
                     'without progress the ended run rests'
        ensure
          t&.teardown
        end
      end
    end
  end
end
