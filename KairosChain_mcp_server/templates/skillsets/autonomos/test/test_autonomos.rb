# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'tmpdir'

# Minimal stubs for testing without full KairosChain
module Autoexec
  def self.loaded?; true; end
end

# Set up temp dir before loading Autonomos
$test_kairos_dir = Dir.mktmpdir('autonomos_test')

module KairosMcp
  def self.kairos_dir
    $test_kairos_dir
  end

  module Tools
    class BaseTool
      def text_content(text)
        text
      end
    end
  end
end

require_relative '../lib/autonomos'
require_relative '../tools/autonomos_cycle'
require_relative '../tools/autonomos_reflect'
require_relative '../tools/autonomos_status'

class TestAutonomosCycleStore < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir('autonomos_test')
    # Override storage path for tests
    Autonomos.instance_variable_set(:@config, { 'stale_lock_timeout' => 3600, 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_generate_cycle_id
    id = Autonomos::CycleStore.generate_cycle_id
    assert_match(/\Acyc_\d{8}_\d{6}_[0-9a-f]{6}\z/, id)
  end

  def test_save_and_load_cycle
    cycle_id = 'test_cycle_001'
    state = {
      cycle_id: cycle_id,
      state: 'decided',
      goal_name: 'test_goal',
      observation: { git: { git_available: false } },
      orientation: { gaps: [] },
      proposal: nil,
      created_at: Time.now.iso8601
    }

    Autonomos::CycleStore.save(cycle_id, state)
    loaded = Autonomos::CycleStore.load(cycle_id)

    assert_equal cycle_id, loaded[:cycle_id]
    assert_equal 'decided', loaded[:state]
    assert_equal 'test_goal', loaded[:goal_name]
  end

  def test_load_nonexistent_returns_nil
    assert_nil Autonomos::CycleStore.load('nonexistent_cycle')
  end

  def test_update_state
    cycle_id = 'test_cycle_002'
    Autonomos::CycleStore.save(cycle_id, {
      cycle_id: cycle_id,
      state: 'decided',
      state_history: []
    })

    Autonomos::CycleStore.update_state(cycle_id, 'reflected')
    loaded = Autonomos::CycleStore.load(cycle_id)

    assert_equal 'reflected', loaded[:state]
    assert_equal 1, loaded[:state_history].size
  end

  def test_update_state_invalid
    cycle_id = 'test_cycle_003'
    Autonomos::CycleStore.save(cycle_id, { cycle_id: cycle_id, state: 'decided', state_history: [] })

    assert_raises(ArgumentError) do
      Autonomos::CycleStore.update_state(cycle_id, 'invalid_state')
    end
  end

  def test_validate_cycle_id
    assert_raises(ArgumentError) do
      Autonomos::CycleStore.validate_cycle_id!('../../etc/passwd')
    end

    # Valid IDs should not raise
    Autonomos::CycleStore.validate_cycle_id!('cyc_20260316_001_abc123')
  end

  def test_list_cycles
    3.times do |i|
      Autonomos::CycleStore.save("test_list_#{i}", {
        cycle_id: "test_list_#{i}",
        state: 'decided',
        created_at: Time.now.iso8601
      })
      sleep 0.01 # Ensure different mtime
    end

    cycles = Autonomos::CycleStore.list(limit: 2)
    assert_equal 2, cycles.size
  end

  def test_lock_acquire_and_release
    Autonomos::CycleStore.acquire_lock('test_lock')
    assert Autonomos::CycleStore.locked?

    Autonomos::CycleStore.release_lock
    refute Autonomos::CycleStore.locked?
  end

  def test_lock_prevents_concurrent
    Autonomos::CycleStore.acquire_lock('test_lock_1')

    assert_raises(RuntimeError) do
      Autonomos::CycleStore.acquire_lock('test_lock_2')
    end

    Autonomos::CycleStore.release_lock
  end
end

class TestAutonomosReflector < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)

    @cycle_id = 'test_reflect_001'
    Autonomos::CycleStore.save(@cycle_id, {
      cycle_id: @cycle_id,
      state: 'decided',
      goal_name: 'test_goal',
      orientation: { gaps: [{ type: 'task_gap', description: 'test gap' }] },
      proposal: { task_id: 'test_task', design_intent: 'test intent' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })
  end

  def test_reflect_success
    reflector = Autonomos::Reflector.new(@cycle_id, execution_result: 'All tests passed, success')
    result = reflector.reflect

    assert_equal @cycle_id, result[:cycle_id]
    assert_equal 'success', result[:evaluation]
    assert result[:learnings].any? { |l| l.include?('success') }
  end

  def test_reflect_failure
    reflector = Autonomos::Reflector.new(@cycle_id, execution_result: 'Build failed with errors')
    result = reflector.reflect

    assert_equal 'failed', result[:evaluation]
  end

  def test_reflect_skipped
    reflector = Autonomos::Reflector.new(@cycle_id, skip_reason: 'Proposal rejected by user')
    result = reflector.reflect

    assert_equal 'skipped', result[:evaluation]
    assert_equal 'Proposal rejected by user', result[:skip_reason]
  end

  def test_reflect_with_feedback
    reflector = Autonomos::Reflector.new(
      @cycle_id,
      execution_result: 'Done',
      feedback: 'Also consider edge cases'
    )
    result = reflector.reflect

    assert result[:human_feedback_incorporated]
    assert result[:learnings].any? { |l| l.include?('edge cases') }
  end

  def test_reflect_wrong_state
    wrong_cycle = 'test_reflect_wrong'
    Autonomos::CycleStore.save(wrong_cycle, {
      cycle_id: wrong_cycle,
      state: 'reflected',
      state_history: []
    })

    reflector = Autonomos::Reflector.new(wrong_cycle, execution_result: 'test')
    result = reflector.reflect

    assert result[:error]
    assert result[:error].include?('reflected')
  end

  def test_reflect_nonexistent_cycle
    reflector = Autonomos::Reflector.new('nonexistent', execution_result: 'test')
    result = reflector.reflect

    assert result[:error]
    assert result[:error].include?('not found')
  end
end

class TestAutonomosReflectorEvaluation < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)

    @cycle_id = 'test_eval_001'
    Autonomos::CycleStore.save(@cycle_id, {
      cycle_id: @cycle_id,
      state: 'decided',
      goal_name: 'test_goal',
      orientation: { gaps: [{ type: 'task_gap', description: 'test gap' }] },
      proposal: { task_id: 'test_task', design_intent: 'test intent' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })
  end

  def test_failure_keywords_take_precedence_over_success
    # "done incorrectly" should be 'failed' not 'success'
    reflector = Autonomos::Reflector.new(@cycle_id, execution_result: 'I tried but it failed, done incorrectly')
    result = reflector.reflect
    assert_equal 'failed', result[:evaluation]
  end

  def test_partial_detected
    cycle_id = 'test_eval_002'
    Autonomos::CycleStore.save(cycle_id, {
      cycle_id: cycle_id, state: 'decided', goal_name: 'g',
      orientation: { gaps: [] }, proposal: { task_id: 't' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })
    reflector = Autonomos::Reflector.new(cycle_id, execution_result: 'Some tests passed but incomplete coverage')
    result = reflector.reflect
    assert_equal 'partial', result[:evaluation]
  end

  def test_unknown_when_no_result
    cycle_id = 'test_eval_003'
    Autonomos::CycleStore.save(cycle_id, {
      cycle_id: cycle_id, state: 'decided', goal_name: 'g',
      orientation: { gaps: [] }, proposal: { task_id: 't' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })
    reflector = Autonomos::Reflector.new(cycle_id)
    result = reflector.reflect
    assert_equal 'unknown', result[:evaluation]
  end

  def test_evaluation_persisted_to_cycle_json
    reflector = Autonomos::Reflector.new(@cycle_id, execution_result: 'All tests passed')
    reflector.reflect

    loaded = Autonomos::CycleStore.load(@cycle_id)
    assert_equal 'success', loaded[:evaluation]
    assert_equal 'reflected', loaded[:state]
    assert loaded[:learnings].is_a?(Array)
    refute_nil loaded[:suggested_next]
  end
end

class TestAutonomosIdentifyGaps < Minitest::Test
  # Test the gap identification logic by instantiating the tool class
  # and calling private methods via send (unit test for core logic)

  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_checklist_items_become_gaps
    goal = { content: "# Goal\n- [ ] Write tests\n- [ ] Fix bugs\n- [x] Done item", found: true }
    observation = { git: { git_available: false } }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    gaps = tool.send(:identify_gaps, goal, observation)

    assert_equal 2, gaps.size
    assert gaps.all? { |g| g[:type] == 'task_gap' }
    assert gaps.any? { |g| g[:description] == 'Write tests' }
    assert gaps.any? { |g| g[:description] == 'Fix bugs' }
  end

  def test_no_goal_produces_setup_gap
    goal = { content: nil, found: false }
    observation = { git: { git_available: false } }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    gaps = tool.send(:identify_gaps, goal, observation)

    assert_equal 1, gaps.size
    assert_equal 'setup', gaps.first[:type]
    assert_equal 'high', gaps.first[:priority]
  end

  def test_all_checked_produces_no_gaps
    goal = { content: "# Goal\n- [x] Done\n- [x] Also done", found: true }
    observation = { git: { git_available: false } }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    gaps = tool.send(:identify_gaps, goal, observation)

    assert_empty gaps
  end

  def test_prose_goal_without_checklist_produces_no_gaps
    goal = { content: "# Goal\nBuild a great product with excellent quality.", found: true }
    observation = { git: { git_available: false } }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    gaps = tool.send(:identify_gaps, goal, observation)

    assert_empty gaps
  end
end

class TestAutonomosDecide < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_decide_selects_highest_priority
    orientation = {
      gaps: [
        { type: 'task_gap', description: 'low item', priority: 'low', action_hint: 'do low' },
        { type: 'task_gap', description: 'high item', priority: 'high', action_hint: 'do high' },
        { type: 'task_gap', description: 'med item', priority: 'medium', action_hint: 'do med' }
      ]
    }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    proposal = tool.send(:decide, orientation)

    assert_equal 'high item', proposal[:selected_gap][:description]
    assert_equal 2, proposal[:remaining_gaps]
    assert_equal 'high', proposal[:autoexec_task][:meta][:risk_default]
  end

  def test_decide_setup_gap_requires_human_cognition
    orientation = {
      gaps: [{ type: 'setup', description: 'No goal', priority: 'high', action_hint: 'Set goal' }]
    }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    proposal = tool.send(:decide, orientation)

    implement_step = proposal[:autoexec_task][:steps].find { |s| s[:step_id] == 'implement' }
    assert implement_step[:requires_human_cognition], 'Setup gap implement step should require human cognition'
  end

  def test_decide_with_no_gaps
    orientation = { gaps: [] }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    proposal = tool.send(:decide, orientation)

    assert_nil proposal[:task_id]
    assert_nil proposal[:autoexec_task]
  end
end

class TestAutonomosStatus < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_current_with_no_cycles
    # Clear any existing cycles
    cycles_dir = Autonomos.storage_path('cycles')
    Dir.glob(File.join(cycles_dir, 'status_test_*.json')).each { |f| File.delete(f) }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosStatus.new
    # Can't call tool.call directly without BaseTool, so test handle_current via send
    result = tool.send(:handle_current)
    refute_nil result
    assert_includes [true, false], result[:locked]
  end

  def test_summary_requires_cycle_id
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosStatus.new
    result = tool.send(:handle_summary, nil)
    assert result[:error]
  end

  def test_summary_with_valid_cycle
    cycle_id = 'status_test_summary'
    Autonomos::CycleStore.save(cycle_id, {
      cycle_id: cycle_id,
      state: 'decided',
      goal_name: 'test_goal',
      created_at: Time.now.iso8601,
      observation: { git: { git_available: false, branch: 'main', status: [] } },
      orientation: { gaps: [] },
      proposal: nil,
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosStatus.new
    result = tool.send(:handle_summary, cycle_id)

    assert_equal cycle_id, result[:cycle_id]
    assert_equal 'decided', result[:state]
    refute_nil result[:observation_summary]
  end
end

class TestAutonomosGitObservation < Minitest::Test
  def test_git_disabled
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)

    result = Autonomos.git_observation
    assert_equal false, result[:git_available]
    assert_equal 'disabled', result[:reason]
  end
end
