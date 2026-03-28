#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for M4: Multi-cycle, mandate progression, loop detection, revise
# Usage: ruby test_agent_m4.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'digest'
require 'time'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'
require_relative '../lib/agent'
require_relative '../tools/agent_start'
require_relative '../tools/agent_step'
require_relative '../tools/agent_status'
require_relative '../tools/agent_stop'

$pass = 0
$fail = 0

def assert(description, &block)
  result = block.call
  if result
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "        #{e.backtrace.first(3).join("\n        ")}"
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

# ---- Test infrastructure ----

TMPDIR = Dir.mktmpdir('agent_m4_test')

module Autonomos
  @storage_base = TMPDIR

  def self.storage_path(subpath)
    path = File.join(@storage_base, subpath)
    FileUtils.mkdir_p(path)
    path
  end

  def self.config
    {}
  end
end

require File.expand_path('../../../../.kairos/skillsets/autonomos/lib/autonomos/mandate',
  File.dirname(__dir__))

Session = KairosMcp::SkillSets::Agent::Session
MandateAdapter = KairosMcp::SkillSets::Agent::MandateAdapter

module Autoexec
  class TaskDsl
    def self.from_json(json_str)
      parsed = JSON.parse(json_str)
      raise ArgumentError, "Missing task_id" unless parsed['task_id']
      raise ArgumentError, "Missing steps" unless parsed['steps'].is_a?(Array)
      parsed
    end
  end
end

# ---- Mock tools ----

class MockLlmCall < KairosMcp::Tools::BaseTool
  @@responses = []
  def self.queue_response(r); @@responses << r; end
  def self.clear!; @@responses.clear; end
  def name; 'llm_call'; end
  def description; 'mock'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    resp = @@responses.shift || { 'content' => 'default', 'tool_use' => nil, 'stop_reason' => 'end_turn' }
    text_content(JSON.generate({
      'status' => 'ok', 'provider' => 'mock', 'model' => 'mock-1',
      'response' => resp, 'usage' => { 'input_tokens' => 10, 'output_tokens' => 20 },
      'snapshot' => { 'model' => 'mock-1', 'timestamp' => Time.now.iso8601 }
    }))
  end
end

class MockAutoexecPlan < KairosMcp::Tools::BaseTool
  def name; 'autoexec_plan'; end
  def description; 'mock'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    task_json = JSON.parse(arguments['task_json'])
    text_content(JSON.generate({
      'status' => 'ok', 'task_id' => task_json['task_id'] || 'mock_001',
      'plan_hash' => Digest::SHA256.hexdigest(arguments['task_json'])[0..15],
      'steps' => task_json['steps']&.length || 0
    }))
  end
end

class MockAutoexecRun < KairosMcp::Tools::BaseTool
  def name; 'autoexec_run'; end
  def description; 'mock'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    text_content(JSON.generate({ 'status' => 'ok', 'executed_steps' => 1 }))
  end
end

class MockKnowledgeGet < KairosMcp::Tools::BaseTool
  def name; 'knowledge_get'; end
  def description; 'mock'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    text_content(JSON.generate({ 'name' => arguments['name'], 'content' => 'mock' }))
  end
end

def build_registry
  registry = KairosMcp::ToolRegistry.allocate
  registry.instance_variable_set(:@safety, KairosMcp::Safety.new)
  registry.instance_variable_set(:@tools, {})
  KairosMcp::ToolRegistry.clear_gates!
  tools = {
    'llm_call' => MockLlmCall.new(nil, registry: registry),
    'knowledge_get' => MockKnowledgeGet.new(nil, registry: registry),
    'autoexec_plan' => MockAutoexecPlan.new(nil, registry: registry),
    'autoexec_run' => MockAutoexecRun.new(nil, registry: registry),
    'agent_start' => KairosMcp::SkillSets::Agent::Tools::AgentStart.new(nil, registry: registry),
    'agent_step' => KairosMcp::SkillSets::Agent::Tools::AgentStep.new(nil, registry: registry),
    'agent_status' => KairosMcp::SkillSets::Agent::Tools::AgentStatus.new(nil, registry: registry),
    'agent_stop' => KairosMcp::SkillSets::Agent::Tools::AgentStop.new(nil, registry: registry)
  }
  registry.instance_variable_set(:@tools, tools)
  registry
end

VALID_DECISION = JSON.generate({
  'summary' => 'test plan',
  'task_json' => {
    'task_id' => 'test_001', 'meta' => { 'description' => 'test', 'risk_default' => 'low' },
    'steps' => [{ 'step_id' => 's1', 'action' => 'do', 'tool_name' => 'knowledge_get',
                   'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                   'requires_human_cognition' => false }]
  }
})

REFLECT_OK = JSON.generate({
  'confidence' => 0.8, 'achieved' => ['done'], 'remaining' => [],
  'learnings' => [], 'open_questions' => []
})

def make_decision(summary)
  JSON.generate({
    'summary' => summary,
    'task_json' => {
      'task_id' => "t_#{SecureRandom.hex(3)}", 'meta' => { 'description' => summary, 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'do', 'tool_name' => 'knowledge_get',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })
end

def queue_orient_decide_reflect(summary: nil)
  summary ||= "plan_#{SecureRandom.hex(3)}"
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => 'orient analysis', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue_response({ 'content' => make_decision(summary), 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue_response({ 'content' => REFLECT_OK, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
end

def queue_orient_decide(summary: nil)
  summary ||= "plan_#{SecureRandom.hex(3)}"
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => 'orient analysis', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue_response({ 'content' => make_decision(summary), 'tool_use' => nil, 'stop_reason' => 'end_turn' })
end

registry = build_registry

# =========================================================================
# 1. Full 2-cycle E2E
# =========================================================================

section "Multi-cycle E2E"

assert("2 full cycles: observed→proposed→checkpoint→observed→proposed→checkpoint") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'multi_cycle_test', 'max_cycles' => 3 })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  # Cycle 1: observed → proposed → checkpoint
  queue_orient_decide_reflect
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })  # orient+decide
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })  # act+reflect

  # checkpoint → observed (cycle 2)
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  next_cycle = parsed['state'] == 'observed'

  # Cycle 2: observed → proposed → checkpoint
  queue_orient_decide_reflect
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  result2 = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed2 = JSON.parse(result2[0][:text])

  next_cycle && parsed2['state'] == 'checkpoint'
end

assert("progress accumulates across cycles") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'progress_accum_test', 'max_cycles' => 3 })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  2.times do
    queue_orient_decide_reflect
    step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
    step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
    step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })  # next cycle
  end

  session = Session.load(session_id)
  entries = session.load_progress(max_entries: 10)
  entries.length == 2 &&
    entries[0]['cycle'] == 1 &&
    entries[1]['cycle'] == 2
end

# =========================================================================
# 2. Revise with feedback E2E
# =========================================================================

section "Revise with feedback"

assert("revise at proposed re-runs DECIDE and stays at proposed") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'revise_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  # observed → proposed
  queue_orient_decide
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  # revise at proposed
  revised_decision = JSON.generate({
    'summary' => 'revised plan',
    'task_json' => {
      'task_id' => 'rev_001', 'meta' => { 'description' => 'revised', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'revised', 'tool_name' => 'knowledge_get',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => revised_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  result = step_tool.call({ 'session_id' => session_id, 'action' => 'revise', 'feedback' => 'Use knowledge_get instead' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' &&
    parsed['state'] == 'proposed' &&
    parsed['decision_payload']['summary'] == 'revised plan'
end

assert("revised decision is persisted") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'revise_persist_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  queue_orient_decide
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  revised_decision = JSON.generate({
    'summary' => 'new plan',
    'task_json' => {
      'task_id' => 'rev_002', 'meta' => { 'description' => 'x', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'a', 'tool_name' => 'echo',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => revised_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  step_tool.call({ 'session_id' => session_id, 'action' => 'revise', 'feedback' => 'change it' })

  session = Session.load(session_id)
  dp = session.load_decision
  dp['summary'] == 'new plan'
end

# =========================================================================
# 3. Loop detection
# =========================================================================

section "Loop detection"

assert("loop_detected terminates when same gap repeats") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'loop_test', 'max_cycles' => 5 })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  # Pre-populate recent_gap_descriptions to trigger loop detection
  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  mandate[:recent_gap_descriptions] = ['same gap', 'same gap']
  Autonomos::Mandate.save(session.mandate_id, mandate)

  # ORIENT returns analysis with same gap
  orient_with_gap = 'Analysis complete. Gaps identified. Recommended action: fix same gap'
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => orient_with_gap, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  # DECIDE returns plan with "same gap" in summary
  decision_same_gap = JSON.generate({
    'summary' => 'same gap',
    'task_json' => {
      'task_id' => 'loop_001', 'meta' => { 'description' => 'x', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'a', 'tool_name' => 'echo',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })
  MockLlmCall.queue_response({ 'content' => decision_same_gap, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'terminated' && parsed['reason'] == 'loop_detected'
end

assert("loop termination sets mandate status to terminated") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'loop_mandate_test', 'max_cycles' => 5 })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  mandate[:recent_gap_descriptions] = ['dup', 'dup']
  Autonomos::Mandate.save(session.mandate_id, mandate)

  decision_dup = JSON.generate({
    'summary' => 'dup',
    'task_json' => {
      'task_id' => 'ld_001', 'meta' => { 'description' => 'x', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'a', 'tool_name' => 'echo',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue_response({ 'content' => decision_dup, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  # Both session AND mandate must be terminated
  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  session.state == 'terminated' && mandate[:status] == 'terminated'
end

assert("gap history uses decision_payload summary (not orient content)") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'gap_source_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  # ORIENT returns plain text, DECIDE returns a specific summary
  specific_decision = JSON.generate({
    'summary' => 'fix auth middleware',
    'task_json' => {
      'task_id' => 'gs_001', 'meta' => { 'description' => 'x', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'a', 'tool_name' => 'echo',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => 'Analysis of current state...', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue_response({ 'content' => specific_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  gaps = Array(mandate[:recent_gap_descriptions])
  # Gap should be decision summary, NOT 'unknown'
  gaps.last == 'fix auth middleware'
end

assert("no loop when gaps are different") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'no_loop_test', 'max_cycles' => 5 })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  # Pre-populate with different gaps
  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  mandate[:recent_gap_descriptions] = ['gap A', 'gap B']
  Autonomos::Mandate.save(session.mandate_id, mandate)

  # ORIENT + DECIDE with different gap
  queue_orient_decide
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' && parsed['state'] == 'proposed'
end

assert("gap history is updated with decision summary after orient+decide") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'gap_history_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  queue_orient_decide(summary: 'specific gap description')
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  gaps = Array(mandate[:recent_gap_descriptions])
  gaps.length == 1 && gaps.last == 'specific gap description'
end

# =========================================================================
# 4. Mandate progression
# =========================================================================

section "Mandate progression"

assert("consecutive_errors increments on low confidence") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'error_test', 'max_cycles' => 5 })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  # Cycle with low confidence → failed evaluation
  low_confidence = JSON.generate({
    'confidence' => 0.1, 'achieved' => [], 'remaining' => ['all'],
    'learnings' => [], 'open_questions' => []
  })
  queue_orient_decide
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => low_confidence, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  mandate[:consecutive_errors] >= 1
end

assert("consecutive_errors resets on success") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'reset_error_test', 'max_cycles' => 5 })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  # Cycle 1: fail
  low_conf = JSON.generate({ 'confidence' => 0.1, 'achieved' => [], 'remaining' => ['x'],
    'learnings' => [], 'open_questions' => [] })
  queue_orient_decide
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => low_conf, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  # Next cycle
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  # Cycle 2: success
  queue_orient_decide_reflect
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  mandate[:consecutive_errors] == 0
end

# =========================================================================
# 5. Stop from various states
# =========================================================================

section "Stop from various states"

assert("stop at proposed terminates") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'stop_proposed_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  queue_orient_decide
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  result = step_tool.call({ 'session_id' => session_id, 'action' => 'stop' })
  parsed = JSON.parse(result[0][:text])
  parsed['state'] == 'terminated'
end

assert("stop at checkpoint terminates") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'stop_checkpoint_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  step_tool = registry.instance_variable_get(:@tools)['agent_step']

  queue_orient_decide_reflect
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  result = step_tool.call({ 'session_id' => session_id, 'action' => 'stop' })
  parsed = JSON.parse(result[0][:text])
  parsed['state'] == 'terminated'
end

# =========================================================================
# Cleanup
# =========================================================================

FileUtils.rm_rf(TMPDIR)

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
