#!/usr/bin/env ruby
# frozen_string_literal: true

# Acceptance criteria for the "norms first" slice of
# docs/drafts/agent_judgment_norms_loop_v0.9.md §5.
#
#   1  a marked step is exempt from the risk count only under the declaration
#   2  a plan bound for the subcontractor route gets no exemption
#   3  the autonomos setup plan is still stopped at both budgets
#   7  knowledge_update is denied by config, not by the risk gate
#   8  run metrics carry attempted cycles as the denominator
#   9  norms (c) and (d) are counted by machine; (a) and (b) are not
#
# Reads the SHIPPED template copies, not the instance copies under .kairos.
# Usage: ruby test_agent_human_mark_gate.rb

require 'minitest/autorun'
require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'

$test_kairos_dir = Dir.mktmpdir('agent_mark_gate_test')

module Autoexec
  def self.loaded?
    true
  end
end

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

# The parent, not just mandate.rb: Mandate.save resolves its path through
# Autonomos.storage_path, which lives there.
require File.expand_path('../autonomos/lib/autonomos', File.dirname(__dir__))
require_relative '../lib/agent/mandate_adapter'

$LOAD_PATH.unshift File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../autoexec/lib', __dir__)
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'
require_relative '../lib/agent'
require_relative '../tools/agent_step'
require File.expand_path('../autoexec/lib/autoexec', File.dirname(__dir__))
require File.expand_path('../autoexec/tools/autoexec_run', File.dirname(__dir__))

Mandate = Autonomos::Mandate
Adapter = KairosMcp::SkillSets::Agent::MandateAdapter
StepTool = KairosMcp::SkillSets::Agent::Tools::AgentStep
RunTool = KairosMcp::SkillSets::Autoexec::Tools::AutoexecRun
require_relative '../tools/operator_report'
ReportTool = KairosMcp::SkillSets::Agent::Tools::OperatorReport

def payload(steps, task_id: 'tsk_1', summary: 'gap')
  { 'summary' => summary,
    'task_json' => { 'task_id' => task_id, 'steps' => steps } }
end

def step(tool, risk: 'low', marked: false, id: 's1')
  { 'step_id' => id, 'tool_name' => tool, 'risk' => risk,
    'requires_human_cognition' => marked }
end

# --- 1: the exemption, and its limit ----------------------------------------
class TestMarkedStepExemption < Minitest::Test
  # A plan of nothing but marked high steps must clear budget low. This is the
  # 2026-08-22 case: the model marked the step honestly and lost the plan.
  def test_marked_only_plan_clears_low_budget
    p = Adapter.to_mandate_proposal(
      payload([{ 'step_id' => 's1', 'tool_name' => '', 'risk' => 'high',
                 'requires_human_cognition' => true }])
    )
    assert_equal true, p[:autoexec_task][:enforce_human_marks]
    refute Mandate.risk_exceeds_budget?(p, 'low')
  end

  # ...and one unmarked over-budget step in the same plan brings it back.
  # An implementation that exempts the whole plan when any step is marked
  # passes the first assertion and fails here.
  def test_one_unmarked_over_budget_step_still_exceeds
    p = Adapter.to_mandate_proposal(
      payload([{ 'step_id' => 's1', 'tool_name' => '', 'risk' => 'high',
                 'requires_human_cognition' => true },
               step('safe_file_write', id: 's2')])
    )
    assert Mandate.risk_exceeds_budget?(p, 'low')
  end

  # The flag is read strictly, matching TaskDsl (task_dsl.rb:117). A truthy
  # string must not buy the exemption.
  def test_string_false_does_not_mark
    p = Adapter.to_mandate_proposal(
      payload([{ 'step_id' => 's1', 'tool_name' => '', 'risk' => 'high',
                 'requires_human_cognition' => 'false' }])
    )
    assert Mandate.risk_exceeds_budget?(p, 'low')
  end

  # The adapter normalises the flag, so the case above never reaches the gate
  # through that path. The gate must not lean on the adapter having done it:
  # any other caller can hand it a truthy non-true value.
  def test_gate_reads_the_mark_strictly_on_a_raw_proposal
    raw = { autoexec_task: { enforce_human_marks: true,
                             steps: [{ risk: 'high', tool_name: '',
                                       requires_human_cognition: 'false' }] },
            selected_gap: { description: 'x' } }
    assert Mandate.risk_exceeds_budget?(raw, 'low')
  end

  # Without the declaration the mark buys nothing, whoever built the hash.
  def test_no_declaration_means_no_exemption
    raw = { autoexec_task: { steps: [{ risk: 'high', tool_name: '',
                                       requires_human_cognition: true }] },
            selected_gap: { description: 'x' } }
    assert Mandate.risk_exceeds_budget?(raw, 'low')
  end
end

# --- 2: the subcontractor route gets no exemption ----------------------------
class TestSubcontractorRouteHasNoExemption < Minitest::Test
  # format_steps_as_instructions never reads the mark, so a marked delete
  # would be handed to the subcontractor as prose. The plan must stay refused.
  def test_marked_delete_beside_unmarked_file_write_is_refused
    p = Adapter.to_mandate_proposal(
      payload([step('safe_file_delete', risk: 'high', marked: true, id: 's1'),
               step('file_write', id: 's2')])
    )
    assert_equal false, p[:autoexec_task][:enforce_human_marks]
    assert Mandate.risk_exceeds_budget?(p, 'low')
    assert Mandate.risk_exceeds_budget?(p, 'medium')
  end

  def test_route_predicate_matches_every_file_tool_name
    %w[Edit Write Read Bash file_edit file_write file_read].each do |tool|
      assert Adapter.routes_to_subcontractor?({ 'steps' => [step(tool)] }),
             "#{tool} should route to the subcontractor"
    end
    refute Adapter.routes_to_subcontractor?({ 'steps' => [step('safe_file_read')] })
  end

  def test_missing_task_json_is_not_a_subcontractor_route
    refute Adapter.routes_to_subcontractor?(nil)
    assert_equal true, Adapter.to_mandate_proposal({ 'summary' => 's' })[:autoexec_task][:enforce_human_marks]
  end
end

# --- 3: the autonomos setup plan is still stopped ----------------------------
class TestAutonomosSetupPlanStillStops < Minitest::Test
  # The shape ooda.rb builds for a high-priority gap (ooda.rb:85-107): no
  # tool_name at all, the implement step at the gap's risk, and marked when the
  # gap is setup. Autonomos builds its own proposal and never goes through the
  # adapter, so no declaration is present and the mark buys nothing.
  def ooda_shaped_setup_proposal
    { autoexec_task: {
        steps: [
          { step_id: 'analyze', risk: 'low', requires_human_cognition: false },
          { step_id: 'implement', risk: 'high', requires_human_cognition: true },
          { step_id: 'verify', risk: 'low', requires_human_cognition: false }
        ]
      },
      selected_gap: { description: 'setup' } }
  end

  def test_setup_plan_stops_at_both_budgets
    assert Mandate.risk_exceeds_budget?(ooda_shaped_setup_proposal, 'low')
    assert Mandate.risk_exceeds_budget?(ooda_shaped_setup_proposal, 'medium')
  end

  # The policy at ooda.rb:58-61 — a high-priority gap always needs human
  # confirmation — survives only because autonomos does not build its proposal
  # through the adapter. Wiring it up would grant the implement step the
  # exemption and retract that policy silently, so guard the wiring itself.
  def test_autonomos_loop_does_not_build_proposals_through_the_adapter
    src = File.read(
      File.expand_path('../autonomos/tools/autonomos_loop.rb', File.dirname(__dir__))
    )
    refute_match(/MandateAdapter/, src)
  end
end

# --- 7: knowledge_update is denied by config --------------------------------
class TestNormEditingToolIsDenied < Minitest::Test
  def agent_yml
    YAML.load_file(File.expand_path('../config/agent.yml', __dir__))
  end

  # The gate cannot carry this one: knowledge_update is medium, so a run at
  # budget medium passes it. The blacklist is the only thing standing between
  # the agent and the norms that bind it.
  def test_gate_alone_would_let_the_norm_editor_through
    p = Adapter.to_mandate_proposal(payload([step('knowledge_update', risk: 'medium')]))
    refute Mandate.risk_exceeds_budget?(p, 'medium')
  end

  def test_blacklist_denies_it
    assert_includes agent_yml['tool_blacklist'], 'knowledge_update'
  end

  # Already present before this slice; asserted so a later edit cannot drop
  # them while adding the new entry.
  def test_blacklist_still_denies_the_other_two_norm_editors
    assert_includes agent_yml['tool_blacklist'], 'instructions_update'
    assert_includes agent_yml['tool_blacklist'], 'skills_promote'
  end
end

# --- 8: the exit tally must be able to add up --------------------------------
class TestExitReasonKey < Minitest::Test
  def key(reason)
    StepTool.new(nil, registry: nil).send(:exit_reason_key, reason)
  end

  # The defect the first run exposed (2026-08-26): the halt reason carries the
  # step id in its prose, so a whole-string key gives every halt its own bucket.
  def test_halts_at_different_steps_share_one_key
    a = key('human_cognition_halt at step s2: Review the step, then re-run')
    b = key('human_cognition_halt at step s7: Review the step, then re-run')
    assert_equal 'human_cognition_halt', a
    assert_equal a, b
  end

  # The same shape with a colon rather than a space — the other prose reason in
  # the loop. Naming only the case that was observed leaves this one open.
  def test_colon_form_is_folded_too
    assert_equal 'guard_halt', key('guard_halt: human review required')
  end

  # Bare identifiers must survive untouched, or the fold silently renames the
  # exits that were already countable.
  def test_bare_reasons_are_unchanged
    %w[max_cycles_reached goal_achieved loop_detected risk_exceeded timeout
       llm_budget_exceeded act_failed review_rejected review_max_retries
       goal_content_changed l0_requires_external_review checkpoint error].each do |r|
      assert_equal r, key(r)
    end
  end

  # A reason that does not begin with an identifier must land in one bounded
  # bucket rather than becoming a key of its own.
  def test_unrecognised_reasons_land_in_one_bucket
    assert_equal 'unclassified', key('Review the step')
    assert_equal 'unclassified', key('')
    assert_equal 'unclassified', key(nil)
  end

  # Folding on write is not enough. A mandate written by the code that shipped
  # before this fix carries whole-sentence keys, and a run that resumes it must
  # not leave the old key sitting beside the folded one, counting the same exit
  # twice. Drives the real accumulator against a real mandate.
  FakeSession = Struct.new(:mandate_id, :cycle_number)

  def test_a_sentence_key_left_by_an_earlier_run_is_folded_on_read
    m = Mandate.create(goal_name: 'g', goal_hash: 'h', max_cycles: 3,
                       checkpoint_every: 3, risk_budget: 'low')
    m[:exits] = { 'human_cognition_halt at step s2: Review the step' => 1 }
    Mandate.save(m[:mandate_id], m)

    metrics = StepTool.new(nil, registry: nil).send(
      :accumulate_run_metrics,
      FakeSession.new(m[:mandate_id], 1),
      'human_cognition_halt at step s7: Review the step', []
    )
    refute_nil metrics, 'the accumulator swallowed an error'
    assert_equal({ 'human_cognition_halt' => 2 }, metrics['exits'])
  end
end

# --- the halt kind, the goal in the prompt, the run-wide cycle count ---------
class TestHaltKind < Minitest::Test
  def kind(results, at)
    RunTool.new(nil, registry: nil).send(:halt_kind, results, at)
  end

  # Six paths reach the stop and the reason used to name only the first. The
  # live run on 2026-08-26 stopped on a tool error and was filed as waiting for
  # a person.
  def test_a_tool_error_is_not_a_person
    assert_equal 'step_failed',
                 kind([{ step_id: :s4, status: 'failed', error: 'pm_item rejected the update' }], :s4)
  end

  def test_the_human_path_leaves_no_row_and_is_read_from_that
    assert_equal 'human_cognition', kind([], :s2)
  end

  def test_the_other_kinds_keep_their_own_names
    assert_equal 'tool_missing',
                 kind([{ step_id: :s1, status: 'failed', error: "Tool 'x' not found in registry" }], :s1)
    assert_equal 'policy_denied', kind([{ step_id: :s1, status: 'policy_denied' }], :s1)
    assert_equal 'blocked_on_delegated', kind([{ step_id: :s1, status: 'blocked' }], :s1)
  end
end

class TestGoalReachesDecide < Minitest::Test
  FakeSession = Struct.new(:mandate_id, :cycle_number, :goal_name)

  def tool_with_goal(text)
    t = StepTool.new(nil, registry: nil)
    t.define_singleton_method(:load_goal_content) { |_| text }
    t
  end

  # The goal text reached OBSERVE and stopped there, so a goal saying "read
  # only" produced a plan that wrote. Nothing disobeyed; DECIDE never saw it.
  def test_the_prohibition_is_in_the_prompt
    t = tool_with_goal("# GOAL\n禁止事項: ファイルを作成しない")
    t.define_singleton_method(:build_tool_catalog) { |_| 'resource_read' }
    prompt = t.send(:build_decide_prompt, FakeSession.new('m', 0, 'g'), { 'content' => 'analysis' })
    assert_includes prompt, '禁止事項: ファイルを作成しない'
    assert_includes prompt, 'analysis'
  end

  def test_a_long_goal_is_cut_and_says_so
    excerpt = tool_with_goal('あ' * 9000).send(:goal_excerpt, FakeSession.new('m', 0, 'g'))
    assert_includes excerpt, 'truncated'
    assert_operator excerpt.length, :<, 9000
  end

  def test_no_goal_means_no_section
    t = tool_with_goal(nil)
    t.define_singleton_method(:build_tool_catalog) { |_| 'resource_read' }
    prompt = t.send(:build_decide_prompt, FakeSession.new('m', 0, 'g'), { 'content' => 'analysis' })
    refute_includes prompt, 'The goal, verbatim'
  end
end

class TestUnlimitedCycles < Minitest::Test
  # Withdrawn 2026-08-26. A cycle count fixed in advance is a guess about how
  # long the work takes; the operator already gets the decision back at every
  # checkpoint.
  def test_a_mandate_can_be_created_without_a_cycle_cap
    m = Mandate.create(goal_name: 'g', goal_hash: 'h', max_cycles: nil,
                       checkpoint_every: 3, risk_budget: 'low')
    assert_nil m[:max_cycles]
  end

  def test_an_uncapped_mandate_never_terminates_on_cycle_count
    m = { max_cycles: nil, cycles_completed: 500, consecutive_errors: 0 }
    assert_nil Mandate.check_termination(m)
  end

  # The other stoppers stay. Removing the cap must not remove the error floor.
  def test_the_error_floor_still_stops_an_uncapped_run
    m = { max_cycles: nil, cycles_completed: 500, consecutive_errors: 2 }
    assert_equal 'error_threshold', Mandate.check_termination(m)
  end

  def test_a_cap_still_works_when_one_is_given
    m = { max_cycles: 3, cycles_completed: 3, consecutive_errors: 0 }
    assert_equal 'max_cycles_reached', Mandate.check_termination(m)
    assert_raises(ArgumentError) do
      Mandate.create(goal_name: 'g', goal_hash: 'h', max_cycles: 99,
                     checkpoint_every: 3, risk_budget: 'low')
    end
  end

  # checkpoint_every is what hands the decision back, so it stays bounded even
  # when the cycle count is not.
  def test_checkpoint_every_is_still_bounded_without_a_cap
    assert_raises(ArgumentError) do
      Mandate.create(goal_name: 'g', goal_hash: 'h', max_cycles: nil,
                     checkpoint_every: 9, risk_budget: 'low')
    end
  end
end

class TestOperatorReportBody < Minitest::Test
  def body(title, content)
    ReportTool.new(nil, registry: nil).send(:body, title, content)
  end

  # The first report written, 2026-08-26, opened with two headings: the model
  # wrote one and the tool prepended another.
  def test_no_second_heading_when_the_text_already_has_one
    assert_equal "# 今週の順位\n\n本文", body('今週の優先順位', "# 今週の順位\n\n本文")
  end

  def test_the_title_becomes_the_heading_when_there_is_none
    assert_equal "# 今週の順位\n\n本文", body('今週の順位', '本文')
  end

  def test_no_title_means_the_text_is_left_alone
    assert_equal '本文', body('', '本文')
  end
end

class TestUnlistedToolCount < Minitest::Test
  FakeSession = Struct.new(:mandate_id, :cycle_number)

  def count_for(steps)
    m = Mandate.create(goal_name: 'g', goal_hash: 'h', max_cycles: 3,
                       checkpoint_every: 3, risk_budget: 'low')
    tool = StepTool.new(nil, registry: nil)
    tool.send(:observe_norms, FakeSession.new(m[:mandate_id], 1),
              { 'task_id' => 't1', 'steps' => steps })
    Mandate.load(m[:mandate_id])[:norm_breaks][:unlisted_writing_tool_unmarked].to_i
  end

  # The 2026-08-26 run counted four read-only queries as breaches. Reading is
  # not changing, and marking those would have stopped the plan for nothing.
  def test_read_only_unlisted_tools_are_not_counted
    steps = %w[pm_digest pm_query safe_git_status].map.with_index { |t, i|
      { 'step_id' => "s#{i}", 'tool_name' => t, 'risk' => 'low' }
    }
    assert_equal 0, count_for(steps)
  end

  def test_an_unlisted_tool_the_model_called_medium_is_counted
    assert_equal 1, count_for([{ 'step_id' => 's1', 'tool_name' => 'pm_item', 'risk' => 'medium' }])
  end

  def test_marking_it_settles_the_norm
    assert_equal 0, count_for([{ 'step_id' => 's1', 'tool_name' => 'pm_item',
                                 'risk' => 'medium', 'requires_human_cognition' => true }])
  end

  # A tool in the table is the machine's judgement, not the model's, so it is
  # outside this norm whatever risk the model assigned.
  def test_a_listed_tool_is_not_counted
    assert_equal 0, count_for([{ 'step_id' => 's1', 'tool_name' => 'chain_record', 'risk' => 'high' }])
  end
end

class TestCompletedCyclesSpanTheRun < Minitest::Test
  FakeSession = Struct.new(:mandate_id, :cycle_number)

  # Reported 1 completed against 2 attempted on the second call, because one
  # side counted the run and the other counted the call.
  def test_the_count_accumulates_across_calls
    m = Mandate.create(goal_name: 'g', goal_hash: 'h', max_cycles: 3,
                       checkpoint_every: 3, risk_budget: 'low')
    tool = StepTool.new(nil, registry: nil)
    tool.send(:accumulate_run_metrics, FakeSession.new(m[:mandate_id], 1), 'checkpoint', [{ cycle: 1 }])
    second = tool.send(:accumulate_run_metrics, FakeSession.new(m[:mandate_id], 2), 'checkpoint', [{ cycle: 2 }])
    assert_equal 2, second['attempted_cycles']
    assert_equal 2, second['completed_cycles']
  end
end

# --- 9 (partial): what the risk table does and does not cover ----------------
class TestRiskTableCoverage < Minitest::Test
  # Norm (d) exists because the table is thin. If the table ever grows to cover
  # the registry, the norm loses its reason and this test should be revisited.
  # 28 since operator_report was added on 2026-08-26: a tool the plan must be
  # able to call without marking it has to be in the table, because the norms
  # tell the model to mark anything that is not.
  def test_table_is_thinner_than_the_registry
    assert_equal 28, Mandate::TOOL_RISK.size
    assert_equal 'low', Mandate::TOOL_RISK['operator_report']
    assert_equal 3, Mandate::TOOL_RISK.count { |_, r| r == 'high' }
    %w[safe_file_delete safe_git_push].each do |tool|
      assert_equal 'high', Mandate::TOOL_RISK[tool]
    end
  end

  # high exceeds every budget there is, so the two tools above are the only
  # ones the mechanism refuses outright.
  def test_high_exceeds_every_budget
    Mandate::RISK_BUDGETS.each do |budget|
      p = Adapter.to_mandate_proposal(payload([step('safe_file_delete', risk: 'high')]))
      assert Mandate.risk_exceeds_budget?(p, budget), "high should exceed #{budget}"
    end
  end
end
