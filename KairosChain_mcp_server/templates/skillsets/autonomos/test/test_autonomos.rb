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
  def self.data_dir
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
require_relative '../tools/autonomos_loop'

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

  def test_valid_states_only_reachable
    # Only states actually used in implementation should be valid
    assert_includes Autonomos::CycleStore::VALID_STATES, 'decided'
    assert_includes Autonomos::CycleStore::VALID_STATES, 'no_action'
    assert_includes Autonomos::CycleStore::VALID_STATES, 'reflected'
    # Unreachable states should have been removed
    refute_includes Autonomos::CycleStore::VALID_STATES, 'observing'
    refute_includes Autonomos::CycleStore::VALID_STATES, 'approved'
    refute_includes Autonomos::CycleStore::VALID_STATES, 'executed'
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

  def test_prose_goal_without_checklist_produces_clarification_gap
    goal = { content: "# Goal\nBuild a great product with excellent quality.", found: true }
    observation = { git: { git_available: false } }

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    gaps = tool.send(:identify_gaps, goal, observation)

    assert_equal 1, gaps.size
    assert_equal 'clarification', gaps.first[:type]
    assert gaps.first[:description].include?('checklist')
  end

  def test_prose_goal_with_checked_items_no_clarification
    goal = { content: "# Goal\n- [x] Already done item\nSome prose.", found: true }
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

class TestAutonomosMandate < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_create_mandate
    mandate = Autonomos::Mandate.create(
      goal_name: 'test_goal',
      goal_hash: 'abc123',
      max_cycles: 5,
      checkpoint_every: 2,
      risk_budget: 'low'
    )

    assert_match(/\Amnd_\d{8}_\d{6}_[0-9a-f]{6}\z/, mandate[:mandate_id])
    assert_equal 'created', mandate[:status]
    assert_equal 'test_goal', mandate[:goal_name]
    assert_equal 5, mandate[:max_cycles]
    assert_equal 2, mandate[:checkpoint_every]
    assert_equal 'low', mandate[:risk_budget]
    assert_equal 0, mandate[:cycles_completed]
  end

  def test_load_mandate
    mandate = Autonomos::Mandate.create(
      goal_name: 'load_test',
      goal_hash: 'def456',
      max_cycles: 3,
      checkpoint_every: 1,
      risk_budget: 'medium'
    )

    loaded = Autonomos::Mandate.load(mandate[:mandate_id])
    assert_equal mandate[:mandate_id], loaded[:mandate_id]
    assert_equal 'load_test', loaded[:goal_name]
    assert_equal 'medium', loaded[:risk_budget]
  end

  def test_load_nonexistent_returns_nil
    assert_nil Autonomos::Mandate.load('mnd_nonexistent_000000')
  end

  def test_update_status
    mandate = Autonomos::Mandate.create(
      goal_name: 'status_test',
      goal_hash: 'ghi789',
      max_cycles: 3,
      checkpoint_every: 1,
      risk_budget: 'low'
    )

    updated = Autonomos::Mandate.update_status(mandate[:mandate_id], 'active')
    assert_equal 'active', updated[:status]
  end

  def test_update_status_invalid
    mandate = Autonomos::Mandate.create(
      goal_name: 'invalid_test',
      goal_hash: 'jkl012',
      max_cycles: 3,
      checkpoint_every: 1,
      risk_budget: 'low'
    )

    assert_raises(ArgumentError) do
      Autonomos::Mandate.update_status(mandate[:mandate_id], 'bogus')
    end
  end

  def test_validate_params_max_cycles
    assert_raises(ArgumentError) do
      Autonomos::Mandate.create(
        goal_name: 'x', goal_hash: 'x',
        max_cycles: 0, checkpoint_every: 1, risk_budget: 'low'
      )
    end

    assert_raises(ArgumentError) do
      Autonomos::Mandate.create(
        goal_name: 'x', goal_hash: 'x',
        max_cycles: 11, checkpoint_every: 1, risk_budget: 'low'
      )
    end
  end

  def test_validate_params_checkpoint
    assert_raises(ArgumentError) do
      Autonomos::Mandate.create(
        goal_name: 'x', goal_hash: 'x',
        max_cycles: 3, checkpoint_every: 0, risk_budget: 'low'
      )
    end

    assert_raises(ArgumentError) do
      Autonomos::Mandate.create(
        goal_name: 'x', goal_hash: 'x',
        max_cycles: 3, checkpoint_every: 4, risk_budget: 'low'
      )
    end
  end

  def test_validate_params_risk_budget
    assert_raises(ArgumentError) do
      Autonomos::Mandate.create(
        goal_name: 'x', goal_hash: 'x',
        max_cycles: 3, checkpoint_every: 1, risk_budget: 'high'
      )
    end
  end

  def test_record_cycle
    mandate = Autonomos::Mandate.create(
      goal_name: 'cycle_test',
      goal_hash: 'mno345',
      max_cycles: 5,
      checkpoint_every: 2,
      risk_budget: 'low'
    )

    updated = Autonomos::Mandate.record_cycle(
      mandate[:mandate_id],
      cycle_id: 'cyc_test_001',
      evaluation: 'success'
    )

    assert_equal 1, updated[:cycles_completed]
    assert_equal 0, updated[:consecutive_errors]
    assert_equal 1, updated[:cycle_history].size
    assert_equal 'success', updated[:cycle_history].first[:evaluation]
  end

  def test_record_cycle_increments_errors
    mandate = Autonomos::Mandate.create(
      goal_name: 'error_test',
      goal_hash: 'pqr678',
      max_cycles: 5,
      checkpoint_every: 2,
      risk_budget: 'low'
    )

    Autonomos::Mandate.record_cycle(mandate[:mandate_id], cycle_id: 'c1', evaluation: 'failed')
    updated = Autonomos::Mandate.record_cycle(mandate[:mandate_id], cycle_id: 'c2', evaluation: 'failed')

    assert_equal 2, updated[:consecutive_errors]
  end

  def test_record_cycle_resets_errors_on_success
    mandate = Autonomos::Mandate.create(
      goal_name: 'reset_test',
      goal_hash: 'stu901',
      max_cycles: 5,
      checkpoint_every: 2,
      risk_budget: 'low'
    )

    Autonomos::Mandate.record_cycle(mandate[:mandate_id], cycle_id: 'c1', evaluation: 'failed')
    updated = Autonomos::Mandate.record_cycle(mandate[:mandate_id], cycle_id: 'c2', evaluation: 'success')

    assert_equal 0, updated[:consecutive_errors]
  end

  def test_check_termination_max_cycles
    mandate = { cycles_completed: 5, max_cycles: 5, consecutive_errors: 0 }
    assert_equal 'max_cycles_reached', Autonomos::Mandate.check_termination(mandate)
  end

  def test_check_termination_error_threshold
    mandate = { cycles_completed: 2, max_cycles: 5, consecutive_errors: 2 }
    assert_equal 'error_threshold', Autonomos::Mandate.check_termination(mandate)
  end

  def test_check_termination_nil_when_ok
    mandate = { cycles_completed: 2, max_cycles: 5, consecutive_errors: 0 }
    assert_nil Autonomos::Mandate.check_termination(mandate)
  end

  def test_checkpoint_due
    mandate = { cycles_completed: 2, checkpoint_every: 2 }
    assert Autonomos::Mandate.checkpoint_due?(mandate)

    mandate = { cycles_completed: 3, checkpoint_every: 2 }
    refute Autonomos::Mandate.checkpoint_due?(mandate)

    mandate = { cycles_completed: 0, checkpoint_every: 1 }
    refute Autonomos::Mandate.checkpoint_due?(mandate)
  end

  def test_loop_detected_consecutive
    proposal = { selected_gap: { description: 'Fix bug X' } }

    # Consecutive same gap
    assert Autonomos::Mandate.loop_detected?(proposal, ['Fix bug X'])
    # Different gap
    refute Autonomos::Mandate.loop_detected?(proposal, ['Add feature Y'])
    # Empty history
    refute Autonomos::Mandate.loop_detected?(proposal, [])
    # Nil history
    refute Autonomos::Mandate.loop_detected?(proposal, nil)
  end

  def test_loop_detected_oscillation
    proposal_a = { selected_gap: { description: 'Fix bug X' } }

    # A→B→A pattern detected
    assert Autonomos::Mandate.loop_detected?(proposal_a, ['Fix bug X', 'Add feature Y'])
    # A→B→C no pattern
    proposal_c = { selected_gap: { description: 'Deploy' } }
    refute Autonomos::Mandate.loop_detected?(proposal_c, ['Fix bug X', 'Add feature Y'])
  end

  def test_validate_params_checkpoint_exceeds_max
    assert_raises(ArgumentError) do
      Autonomos::Mandate.create(
        goal_name: 'x', goal_hash: 'x',
        max_cycles: 2, checkpoint_every: 3, risk_budget: 'low'
      )
    end
  end

  def test_risk_exceeds_budget_low
    proposal = {
      autoexec_task: {
        steps: [
          { step_id: 'analyze', risk: 'low' },
          { step_id: 'implement', risk: 'medium' }
        ]
      }
    }

    assert Autonomos::Mandate.risk_exceeds_budget?(proposal, 'low')
    refute Autonomos::Mandate.risk_exceeds_budget?(proposal, 'medium')
  end

  def test_risk_exceeds_budget_medium
    proposal = {
      autoexec_task: {
        steps: [
          { step_id: 'deploy', risk: 'high' }
        ]
      }
    }

    assert Autonomos::Mandate.risk_exceeds_budget?(proposal, 'medium')
    assert Autonomos::Mandate.risk_exceeds_budget?(proposal, 'low')
  end

  def test_risk_within_budget
    proposal = {
      autoexec_task: {
        steps: [
          { step_id: 'read', risk: 'low' },
          { step_id: 'analyze', risk: 'low' }
        ]
      }
    }

    refute Autonomos::Mandate.risk_exceeds_budget?(proposal, 'low')
    refute Autonomos::Mandate.risk_exceeds_budget?(proposal, 'medium')
  end

  def test_list_active
    # Create mandates in different states
    m1 = Autonomos::Mandate.create(
      goal_name: 'active_list', goal_hash: 'a',
      max_cycles: 3, checkpoint_every: 1, risk_budget: 'low'
    )
    m2 = Autonomos::Mandate.create(
      goal_name: 'active_list2', goal_hash: 'b',
      max_cycles: 3, checkpoint_every: 1, risk_budget: 'low'
    )
    Autonomos::Mandate.update_status(m2[:mandate_id], 'active')

    m3 = Autonomos::Mandate.create(
      goal_name: 'terminated_list', goal_hash: 'c',
      max_cycles: 3, checkpoint_every: 1, risk_budget: 'low'
    )
    Autonomos::Mandate.update_status(m3[:mandate_id], 'terminated')

    active = Autonomos::Mandate.list_active
    active_ids = active.map { |m| m[:mandate_id] }

    assert_includes active_ids, m1[:mandate_id]
    assert_includes active_ids, m2[:mandate_id]
    refute_includes active_ids, m3[:mandate_id]
  end
end

class TestAutonomosLoopTool < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_create_mandate_no_goal
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({ 'command' => 'create_mandate', 'goal_name' => 'nonexistent_goal_xyz' }))
    assert result['error']
    assert result['error'].include?('not found')
  end

  def test_start_missing_mandate_id
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({ 'command' => 'start' }))
    assert result['error']
    assert result['error'].include?('mandate_id required')
  end

  def test_start_nonexistent_mandate
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({ 'command' => 'start', 'mandate_id' => 'mnd_nonexistent' }))
    assert result['error']
    assert result['error'].include?('not found')
  end

  def test_start_wrong_state
    mandate = Autonomos::Mandate.create(
      goal_name: 'test', goal_hash: 'x',
      max_cycles: 3, checkpoint_every: 1, risk_budget: 'low'
    )
    Autonomos::Mandate.update_status(mandate[:mandate_id], 'active')

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({ 'command' => 'start', 'mandate_id' => mandate[:mandate_id] }))
    assert result['error']
    assert result['error'].include?('active')
  end

  def test_interrupt
    mandate = Autonomos::Mandate.create(
      goal_name: 'int_test', goal_hash: 'x',
      max_cycles: 3, checkpoint_every: 1, risk_budget: 'low'
    )
    Autonomos::Mandate.update_status(mandate[:mandate_id], 'active')

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({ 'command' => 'interrupt', 'mandate_id' => mandate[:mandate_id] }))

    assert_equal 'interrupted', result['termination_reason']
    assert_equal 'interrupted', result['status']
  end

  def test_interrupt_already_terminated
    mandate = Autonomos::Mandate.create(
      goal_name: 'term_test', goal_hash: 'x',
      max_cycles: 3, checkpoint_every: 1, risk_budget: 'low'
    )
    Autonomos::Mandate.update_status(mandate[:mandate_id], 'terminated')

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({ 'command' => 'interrupt', 'mandate_id' => mandate[:mandate_id] }))
    assert result['error']
    assert result['error'].include?('already terminated')
  end

  def test_cycle_complete_missing_mandate
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({ 'command' => 'cycle_complete' }))
    assert result['error']
  end

  def test_cycle_complete_wrong_state
    mandate = Autonomos::Mandate.create(
      goal_name: 'wrong_state', goal_hash: 'x',
      max_cycles: 3, checkpoint_every: 1, risk_budget: 'low'
    )
    # status is 'created', not 'active'
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({
      'command' => 'cycle_complete',
      'mandate_id' => mandate[:mandate_id],
      'execution_result' => 'done'
    }))
    assert result['error']
    assert result['error'].include?('created')
  end
end

class TestAutonomosStatusMandate < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_mandate_command_no_id
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosStatus.new
    result = tool.send(:handle_mandate, nil)
    assert result.key?(:active_mandates)
    assert result[:active_mandates].is_a?(Array)
  end

  def test_mandate_command_with_id
    mandate = Autonomos::Mandate.create(
      goal_name: 'status_mnd', goal_hash: 'x',
      max_cycles: 3, checkpoint_every: 1, risk_budget: 'low'
    )

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosStatus.new
    result = tool.send(:handle_mandate, mandate[:mandate_id])

    assert_equal mandate[:mandate_id], result[:mandate_id]
    assert_equal 'created', result[:status]
    assert_equal 'status_mnd', result[:goal_name]
  end

  def test_mandate_command_not_found
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosStatus.new
    result = tool.send(:handle_mandate, 'mnd_nonexistent')
    assert result[:error]
  end
end

class TestAutonomosOodaModule < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_cycle_tool_uses_ooda_module
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    assert tool.is_a?(Autonomos::Ooda), 'AutonomosCycle should include Ooda module'
  end

  def test_loop_tool_uses_ooda_module
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    assert tool.is_a?(Autonomos::Ooda), 'AutonomosLoop should include Ooda module'
  end

  def test_ooda_observe_returns_structure
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    obs = tool.observe('test_goal')
    assert obs.key?(:timestamp)
    assert obs.key?(:git)
    assert_equal false, obs[:git][:git_available]
  end

  def test_ooda_orient_with_no_goal
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    obs = tool.observe('nonexistent')
    orientation = tool.orient(obs, 'nonexistent', nil)

    assert orientation[:gaps].any? { |g| g[:type] == 'setup' }
  end

  def test_load_goal_no_providers
    # Without ContextManager or KnowledgeProvider, should return not found
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    result = tool.load_goal('nonexistent_goal')
    refute result[:found]
    assert_nil result[:content]
  end

  def test_load_goal_l2_first
    # Stub ContextManager with real API shape: list_sessions + get_context
    entry_class = Struct.new(:content)
    klass = Class.new do
      define_method(:initialize) { |*| }
      define_method(:list_sessions) { [{ session_id: 'sess_1' }] }
      define_method(:get_context) do |session_id, name|
        name == 'my_l2_goal' ? entry_class.new("- [ ] Do the thing") : nil
      end
    end
    KairosMcp.const_set(:ContextManager, klass)

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    result = tool.load_goal('my_l2_goal')

    assert result[:found]
    assert_equal :l2, result[:source]
    assert_includes result[:content], 'Do the thing'
  ensure
    KairosMcp.send(:remove_const, :ContextManager) if KairosMcp.const_defined?(:ContextManager)
  end

  def test_load_goal_l1_fallback
    # Define ContextManager that returns nil (no L2 goal)
    klass = Class.new do
      define_method(:initialize) { |*| }
      define_method(:list_sessions) { [{ session_id: 'sess_empty' }] }
      define_method(:get_context) { |_sid, _name| nil }
    end
    KairosMcp.const_set(:ContextManager, klass)

    # Define KnowledgeProvider that returns L1 goal
    kp_mod = Module.new do
      define_method(:initialize) { |_| }
      define_method(:get) do |name|
        if name == 'template_goal'
          { content: "- [ ] Template task" }
        else
          nil
        end
      end
    end
    KairosMcp.const_set(:KnowledgeProvider, Class.new { include kp_mod })

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    result = tool.load_goal('template_goal')

    assert result[:found]
    assert_equal :l1, result[:source]
    assert_includes result[:content], 'Template task'
  ensure
    KairosMcp.send(:remove_const, :ContextManager) if KairosMcp.const_defined?(:ContextManager)
    KairosMcp.send(:remove_const, :KnowledgeProvider) if KairosMcp.const_defined?(:KnowledgeProvider)
  end

  def test_orient_includes_goal_source
    # Define ContextManager with real API shape
    entry_class = Struct.new(:content)
    klass = Class.new do
      define_method(:initialize) { |*| }
      define_method(:list_sessions) { [{ session_id: 'sess_src' }] }
      define_method(:get_context) do |_sid, name|
        name == 'src_test' ? entry_class.new("- [ ] Source test task") : nil
      end
    end
    KairosMcp.const_set(:ContextManager, klass)

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    obs = tool.observe('src_test')
    orientation = tool.orient(obs, 'src_test', nil)

    assert_equal :l2, orientation[:goal_source]
  ensure
    KairosMcp.send(:remove_const, :ContextManager) if KairosMcp.const_defined?(:ContextManager)
  end

  def test_ooda_decide_with_gaps
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    orientation = {
      gaps: [
        { type: 'task_gap', description: 'test task', priority: 'medium', action_hint: 'do it' }
      ]
    }
    proposal = tool.decide(orientation)
    assert proposal[:task_id]
    assert proposal[:autoexec_task]
    assert_equal 'medium', proposal[:autoexec_task][:meta][:risk_default]
  end
end

class TestAutonomosLoopIntegration < Minitest::Test
  # Integration test: exercises create_mandate → start → cycle_complete → termination
  # Uses the real Ooda module but without KnowledgeProvider (so goal not found → setup gap → risk pause)

  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_start_with_no_goal_detects_drift
    # Create mandate with a fake goal_hash (simulating that goal existed at create time)
    mandate = Autonomos::Mandate.create(
      goal_name: 'test_integration_goal',
      goal_hash: 'abc',
      max_cycles: 3,
      checkpoint_every: 3,
      risk_budget: 'low'
    )

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({
      'command' => 'start',
      'mandate_id' => mandate[:mandate_id]
    }))

    # Without providers, goal resolves to nil. Hash of nil.to_s differs from 'abc'.
    # goal_hash verification triggers before risk budget gate.
    assert_equal 'paused_goal_drift', result['status']
    assert_equal mandate[:mandate_id], result['mandate_id']
  end

  def test_start_with_matching_hash_reaches_risk_gate
    # Compute the hash that orient will produce when goal is not found
    # (nil content → hash of empty string)
    expected_hash = Digest::SHA256.hexdigest('')

    mandate = Autonomos::Mandate.create(
      goal_name: 'hash_match_test',
      goal_hash: expected_hash,
      max_cycles: 3,
      checkpoint_every: 3,
      risk_budget: 'low'
    )

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({
      'command' => 'start',
      'mandate_id' => mandate[:mandate_id]
    }))

    # Hash matches, so we proceed past goal_hash check.
    # No goal → setup gap (high priority/risk) → paused_risk_exceeded
    assert_equal 'paused_risk_exceeded', result['status']
  end

  def test_cycle_complete_with_max_cycles
    mandate = Autonomos::Mandate.create(
      goal_name: 'max_test',
      goal_hash: 'def',
      max_cycles: 1,
      checkpoint_every: 1,
      risk_budget: 'low'
    )
    mandate_id = mandate[:mandate_id]

    # Simulate a decided cycle for reflect
    cycle_id = Autonomos::CycleStore.generate_cycle_id
    Autonomos::CycleStore.save(cycle_id, {
      cycle_id: cycle_id,
      state: 'decided',
      goal_name: 'max_test',
      mandate_id: mandate_id,
      orientation: { gaps: [] },
      proposal: { task_id: 't', design_intent: 'test' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })

    # Set status to active and track cycle (reload after update to avoid stale overwrite)
    Autonomos::Mandate.update_status(mandate_id, 'active')
    mandate = Autonomos::Mandate.load(mandate_id)
    mandate[:last_cycle_id] = cycle_id
    Autonomos::Mandate.save(mandate_id, mandate)

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({
      'command' => 'cycle_complete',
      'mandate_id' => mandate_id,
      'execution_result' => 'All tests passed'
    }))

    assert_equal 'terminated', result['status']
    assert_equal 'max_cycles_reached', result['termination_reason']
    assert_equal 1, result['cycles_completed']
  end

  def test_cycle_complete_skipped_with_no_prior_cycle
    mandate = Autonomos::Mandate.create(
      goal_name: 'skip_test',
      goal_hash: 'ghi',
      max_cycles: 2,
      checkpoint_every: 2,
      risk_budget: 'low'
    )
    mandate_id = mandate[:mandate_id]
    Autonomos::Mandate.update_status(mandate_id, 'active')

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    # cycle_complete without execution_result and no prior cycle (last_cycle_id nil)
    tool.call({
      'command' => 'cycle_complete',
      'mandate_id' => mandate_id
    })

    # No prior cycle to record — cycles_completed stays 0, but loop proceeds to run_cycle
    updated = Autonomos::Mandate.load(mandate_id)
    assert_equal 0, updated[:cycles_completed],
                 "Expected no cycle recorded when last_cycle_id is nil"
  end

  def test_interrupt_from_active
    mandate = Autonomos::Mandate.create(
      goal_name: 'int_integration',
      goal_hash: 'jkl',
      max_cycles: 5,
      checkpoint_every: 2,
      risk_budget: 'medium'
    )
    Autonomos::Mandate.update_status(mandate[:mandate_id], 'active')

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({
      'command' => 'interrupt',
      'mandate_id' => mandate[:mandate_id]
    }))

    assert_equal 'interrupted', result['status']
    assert_equal 'interrupted', result['termination_reason']

    # Verify persisted state
    loaded = Autonomos::Mandate.load(mandate[:mandate_id])
    assert_equal 'interrupted', loaded[:status]
    assert_equal 'interrupted', loaded[:termination_reason]
  end
end

class TestAutonomosGoalHashVerification < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_goal_drift_pauses_mandate
    # Create mandate with a specific goal_hash
    mandate = Autonomos::Mandate.create(
      goal_name: 'drift_test',
      goal_hash: 'original_hash_abc',
      max_cycles: 3,
      checkpoint_every: 3,
      risk_budget: 'low'
    )

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    # Start will observe→orient and compute a new goal_hash (different from 'original_hash_abc')
    # Since no KnowledgeProvider is defined, the goal won't be found — but
    # when goal is not found, orient still computes goal_hash from nil content.
    # The hash of nil.to_s will differ from 'original_hash_abc'
    result = JSON.parse(tool.call({
      'command' => 'start',
      'mandate_id' => mandate[:mandate_id]
    }))

    assert_equal 'paused_goal_drift', result['status']
    assert result['message'].include?('changed')
  end

  def test_paused_goal_drift_is_valid_status
    assert_includes Autonomos::Mandate::VALID_STATUSES, 'paused_goal_drift'
  end
end

class TestAutonomosSkipReflector < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_skip_via_reflector_closes_cycle
    # Create a decided cycle
    cycle_id = 'skip_reflector_test'
    Autonomos::CycleStore.save(cycle_id, {
      cycle_id: cycle_id,
      state: 'decided',
      goal_name: 'test',
      orientation: { gaps: [{ type: 'task_gap', description: 'test' }] },
      proposal: { task_id: 't', design_intent: 'test' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })

    # Reflect with skip_reason (same path as loop skip)
    reflector = Autonomos::Reflector.new(
      cycle_id,
      skip_reason: 'Skipped by user'
    )
    result = reflector.reflect

    assert_equal 'skipped', result[:evaluation]
    assert_equal 'Skipped by user', result[:skip_reason]

    # Verify cycle state is closed
    loaded = Autonomos::CycleStore.load(cycle_id)
    assert_equal 'reflected', loaded[:state]
    assert_equal 'skipped', loaded[:evaluation]
  end
end

class TestAutonomosPausedGoalDriftRejection < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_cycle_complete_rejects_paused_goal_drift
    mandate = Autonomos::Mandate.create(
      goal_name: 'drift_reject_test',
      goal_hash: 'stale_hash',
      max_cycles: 3,
      checkpoint_every: 3,
      risk_budget: 'low'
    )
    mandate_id = mandate[:mandate_id]
    Autonomos::Mandate.update_status(mandate_id, 'paused_goal_drift')

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result = JSON.parse(tool.call({
      'command' => 'cycle_complete',
      'mandate_id' => mandate_id,
      'execution_result' => 'should be rejected'
    }))

    # paused_goal_drift cannot be resumed via cycle_complete
    assert result['error'] || result['status'] == 'paused_goal_drift',
           "Expected rejection of cycle_complete from paused_goal_drift state"
  end
end

class TestAutonomosHappyPathIntegration < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)

    # Provide a goal via KnowledgeProvider mock
    mod = Module.new do
      define_method(:get) do |name|
        if name == 'happy_goal'
          { content: "# Goal\n- [ ] Write hello world\n- [ ] Add tests" }
        end
      end
    end
    klass = Class.new do
      include mod
      def initialize(*); end
    end
    KairosMcp.const_set(:KnowledgeProvider, klass)
  end

  def teardown
    KairosMcp.send(:remove_const, :KnowledgeProvider) if KairosMcp.const_defined?(:KnowledgeProvider)
  end

  def test_single_cycle_returns_proposal_with_task_gaps
    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    result = JSON.parse(tool.call({ 'goal_name' => 'happy_goal' }))

    assert_equal 'decided', result['state']
    assert result['proposal'], "Expected a proposal"
    assert result['proposal']['autoexec_task'], "Expected autoexec_task in proposal"
    assert result['proposal']['selected_gap'], "Expected selected_gap"
    assert_equal 'task_gap', result['proposal']['selected_gap']['type']

    # Orientation should show gaps from checklist
    gaps = result['orientation']['gaps']
    assert_operator gaps.size, :>=, 2, "Expected at least 2 task gaps from checklist"
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

class TestAutonomosSaveContextFailure < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def teardown
    KairosMcp.send(:remove_const, :ContextManager) if KairosMcp.const_defined?(:ContextManager)
  end

  def test_save_to_l2_returns_nil_on_save_failure
    # Mock ContextManager where save_context returns { success: false }
    klass = Class.new do
      define_method(:initialize) { |*| }
      define_method(:generate_session_id) { |**| 'sess_fail' }
      define_method(:save_context) { |_sid, _name, _content| { success: false, error: 'disk full' } }
    end
    KairosMcp.const_set(:ContextManager, klass)

    cycle_id = 'save_fail_test'
    Autonomos::CycleStore.save(cycle_id, {
      cycle_id: cycle_id,
      state: 'decided',
      goal_name: 'test',
      orientation: { gaps: [{ type: 'task_gap', description: 'test' }] },
      proposal: { task_id: 't', design_intent: 'test' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })

    reflector = Autonomos::Reflector.new(cycle_id, execution_result: 'success')
    result = reflector.reflect

    # l2_saved should be nil when save_context fails
    assert_nil result[:l2_saved], "Expected l2_saved to be nil when save_context fails"
    assert_equal 'success', result[:evaluation]
    assert_equal 'reflected', Autonomos::CycleStore.load(cycle_id)[:state]
  end
end

class TestAutonomosLoadL2ContextShape < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def teardown
    KairosMcp.send(:remove_const, :ContextManager) if KairosMcp.const_defined?(:ContextManager)
  end

  def test_load_l2_context_returns_newest_session_id
    klass = Class.new do
      define_method(:initialize) { |*| }
      define_method(:list_sessions) do
        [
          { session_id: 'sess_new', context_count: 3, modified_at: Time.now },
          { session_id: 'sess_old', context_count: 1, modified_at: Time.now - 3600 }
        ]
      end
    end
    KairosMcp.const_set(:ContextManager, klass)

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosCycle.new
    result = tool.send(:load_l2_context)

    assert result, "Expected non-nil L2 context"
    assert_equal 'sess_new', result[:session_id], "Expected newest session (first in list)"
    assert_equal 3, result[:context_count]
    assert_equal true, result[:exists]
  end
end

class TestAutonomosLoopDetectionNormalization < Minitest::Test
  def test_loop_detected_with_different_counts
    proposal = { selected_gap: { description: '7 uncommitted modified files detected' } }
    recent = ['6 uncommitted modified files detected']

    assert Autonomos::Mandate.loop_detected?(proposal, recent),
           "Expected loop detection when only numbers differ"
  end

  def test_loop_not_detected_with_different_descriptions
    proposal = { selected_gap: { description: 'Missing tests for module A' } }
    recent = ['Missing docs for module B']

    refute Autonomos::Mandate.loop_detected?(proposal, recent),
           "Expected no loop for genuinely different descriptions"
  end
end

class TestAutonomosRegexEvaluation < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_errors_plural_detected_as_failed
    cycle_id = 'regex_errors_test'
    Autonomos::CycleStore.save(cycle_id, {
      cycle_id: cycle_id,
      state: 'decided',
      goal_name: 'test',
      orientation: { gaps: [] },
      proposal: { task_id: 't', design_intent: 'test' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })

    reflector = Autonomos::Reflector.new(cycle_id, execution_result: 'completed with errors')
    result = reflector.reflect

    assert_equal 'failed', result[:evaluation],
                 "Expected 'completed with errors' to evaluate as failed"
  end
end

class TestAutonomosCheckpointResume < Minitest::Test
  def setup
    Autonomos.instance_variable_set(:@config, { 'git_observation' => false })
    Autonomos.instance_variable_set(:@loaded, true)
  end

  def test_checkpoint_resume_does_not_re_pause
    # Create mandate with checkpoint_every=1 (checkpoint after every cycle)
    # Use the hash that orient computes when no goal provider exists (empty string)
    mandate = Autonomos::Mandate.create(
      goal_name: 'ckpt_test',
      goal_hash: Digest::SHA256.hexdigest(''),
      max_cycles: 3,
      checkpoint_every: 1,
      risk_budget: 'low'
    )
    mandate_id = mandate[:mandate_id]

    # Simulate: 1 cycle completed, then paused at checkpoint
    Autonomos::Mandate.record_cycle(mandate_id, cycle_id: 'cyc_ckpt_1', evaluation: 'success')
    Autonomos::Mandate.update_status(mandate_id, 'paused_at_checkpoint')

    # Create a decided cycle so reflection can proceed
    Autonomos::CycleStore.save('cyc_ckpt_1', {
      cycle_id: 'cyc_ckpt_1',
      state: 'decided',
      goal_name: 'ckpt_test',
      orientation: { gaps: [{ type: 'task_gap', description: 'test' }] },
      proposal: { task_id: 't', design_intent: 'test' },
      state_history: [{ state: 'decided', at: Time.now.iso8601 }]
    })

    # Set last_cycle_id
    m = Autonomos::Mandate.load(mandate_id)
    m[:last_cycle_id] = 'cyc_ckpt_1'
    Autonomos::Mandate.save(mandate_id, m)

    tool = KairosMcp::SkillSets::Autonomos::Tools::AutonomosLoop.new
    result_json = tool.call({
      'command' => 'cycle_complete',
      'mandate_id' => mandate_id,
      'feedback' => 'Looks good, continue'
    })
    result = JSON.parse(result_json)

    # Should NOT be paused_at_checkpoint again — should proceed to next cycle or terminate
    refute_equal 'paused_at_checkpoint', result['status'],
                 "Expected checkpoint resume to proceed, not re-pause"
  end
end
