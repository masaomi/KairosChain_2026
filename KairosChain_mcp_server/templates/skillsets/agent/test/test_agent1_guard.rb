# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative '../lib/agent/run'
require_relative '../lib/agent/guard'

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1Guard < Minitest::Test
        FakeRun = Struct.new(:id, :worktree, :target_repo, :branch, :created_paths, :pinned, keyword_init: true)

        def policy
          DSL.parse_policy("policy \"p\" do\n  stand_in may: [:precedent]\n  spend default: { stand_in_calls: 5 }\nend\n")
        end

        def setup
          @root = File.realpath(Dir.mktmpdir('guard'))
          FileUtils.mkdir_p(File.join(@root, '.kairos', 'knowledge'))
          FileUtils.mkdir_p(File.join(@root, 'log'))
          File.write(File.join(@root, 'log', 'old_design.md'), 'someone else')
          @wt = File.join(@root, '.claude', 'worktrees', 'run1')
          FileUtils.mkdir_p(File.join(@wt, 'test'))
          File.write(File.join(@wt, 'test', 'test_old.rb'), 'assert true')
          @paths = Paths.new(File.join(@root, '.kairos'))
          @run = FakeRun.new(id: 'run_x', worktree: @wt, target_repo: @root, branch: 'agent-run/x',
                             created_paths: [], pinned: { 'implement' => { 'tests' => { File.join(@wt, 'test', 'test_old.rb') => 'd' } } })
          @guard = Guard.new(run: @run, paths: @paths, policy: policy, project_root: @root,
                             deny_patterns: [/rm -rf \//])
        end

        def teardown
          FileUtils.rm_rf(@root)
          FileUtils.rm_rf('/tmp/kairos_agent_runs/run_x')
        end

        def test_unknown_tools_are_refused_by_default
          assert @guard.decide('SomeNewTool', {}).refuse?
        end

        def test_reads_are_inside
          assert @guard.decide('Read', { 'file_path' => '/etc/hosts' }).allow?
        end

        def test_file_writes_are_placed
          assert @guard.decide('Edit', { 'file_path' => File.join(@wt, 'lib', 'a.rb') }).allow?
          v = @guard.decide('Write', { 'file_path' => File.join(@root, 'log', 'new_design_v0.1.md') })
          assert v.allow?
          assert_equal File.join(@root, 'log', 'new_design_v0.1.md'), v.created
          assert @guard.decide('Edit', { 'file_path' => File.join(@root, 'log', 'old_design.md') }).refuse?
          assert @guard.decide('Write', { 'file_path' => File.join(@root, '.kairos', 'knowledge', 'x.md') }).refuse?
          assert @guard.decide('Write', { 'file_path' => File.join(@root, '.claude', 'settings.json') }).refuse?
          assert @guard.decide('Write', { 'file_path' => File.join(@wt, '.git') }).refuse?
          assert @guard.decide('Write', { 'file_path' => '/etc/passwd' }).refuse?
        end

        def test_a_pinned_test_change_is_a_decision_point
          v = @guard.decide('Edit', { 'file_path' => File.join(@wt, 'test', 'test_old.rb') })
          assert v.decision_point?
          assert_equal 'pinned_test_change', v.decision
          assert @guard.decide('Write', { 'file_path' => File.join(@wt, 'test', 'test_new.rb') }).allow?
        end

        def test_a_file_the_run_created_stays_inside
          created = File.join(@root, 'log', 'mine.md')
          File.write(created, 'v1')
          @run.created_paths << created
          assert @guard.decide('Edit', { 'file_path' => created }).allow?
        end

        def test_bash_outbound_and_denied_commands_are_refused
          assert @guard.decide('Bash', { 'command' => 'git push origin agent-run/x' }).refuse?
          assert @guard.decide('Bash', { 'command' => 'git tag v1' }).refuse?
          assert @guard.decide('Bash', { 'command' => 'gem push pkg/x.gem' }).refuse?
          assert @guard.decide('Bash', { 'command' => 'curl -X POST https://example.com' }).refuse?
          assert @guard.decide('Bash', { 'command' => 'sudo rm -rf /' }).refuse?
        end

        def test_bash_is_confined_and_confinement_holds
          skip 'sandbox-exec unavailable' unless Confinement.available?
          outside = File.join(@root, 'log', 'old_design.md')
          v = @guard.decide('Bash', { 'command' => "echo in > #{@wt}/made.txt; echo out > #{outside}; echo done" })
          assert v.rewrite?
          assert_includes v.updated_input['command'], 'sandbox-exec'
          _out, _err, st = Open3.capture3('/bin/bash', '-c', v.updated_input['command'])
          assert st.success? || true
          assert_equal "in\n", File.read(File.join(@wt, 'made.txt'))
          assert_equal 'someone else', File.read(outside), 'the confined command must not write shared files'
        end

        def test_mcp_tools
          assert @guard.decide('mcp__kairos-chain__knowledge_get', {}).allow?
          assert @guard.decide('mcp__kairos-chain__agent_status', {}).allow?
          assert @guard.decide('mcp__kairos-chain__knowledge_update', {}).refuse?
          assert @guard.decide('mcp__kairos-chain__chain_record', {}).refuse?
          assert @guard.decide('mcp__kairos-chain__multi_llm_review', {}).refuse?
          assert @guard.decide('mcp__kairos-chain__meeting_deposit', {}).refuse?
          assert @guard.decide('mcp__claude_ai_Gmail__create_draft', {}).refuse?
          v = @guard.decide('mcp__kairos-chain__context_save', { 'name' => 'handoff_new' })
          assert v.allow?
          assert_equal 'l2:handoff_new', v.created
          FileUtils.mkdir_p(File.join(@root, '.kairos', 'context', 's1', 'handoff_old'))
          assert @guard.decide('mcp__kairos-chain__context_save', { 'name' => 'handoff_old' }).refuse?
        end

        def test_lookups_are_refused_and_no_policy_can_consent_to_them
          %w[WebFetch WebSearch].each do |tool|
            v = @guard.decide(tool, { 'url' => 'https://x.org', 'query' => 'x' })
            assert v.refuse?, tool
            assert_includes v.reason, 'does not look things up on the web'
          end
          consenting = "policy \"p\" do\n  stand_in may: [:precedent]\n  consent lookup: :public_web\n  spend default: { stand_in_calls: 5 }\nend\n"
          assert_raises(DSL::Error) { DSL.parse_policy(consenting) }
        end

        def test_questions_are_decision_points_and_remote_agents_are_refused
          assert @guard.decide('AskUserQuestion', {}).decision_point?
          assert @guard.decide('ExitPlanMode', {}).decision_point?
          assert @guard.decide('Agent', { 'isolation' => 'remote' }).refuse?
          assert @guard.decide('Agent', { 'subagent_type' => 'general-purpose' }).allow?
        end
      end
    end
  end
end
