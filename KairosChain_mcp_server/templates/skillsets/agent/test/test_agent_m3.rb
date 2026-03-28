#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for M3: ACT + REFLECT + chain recording + M5 (progress.jsonl)
# Usage: ruby test_agent_m3.rb

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

TMPDIR = Dir.mktmpdir('agent_m3_test')

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

# Load Mandate for testing
require File.expand_path('../../../../.kairos/skillsets/autonomos/lib/autonomos/mandate',
  File.dirname(__dir__))

Session = KairosMcp::SkillSets::Agent::Session
CognitiveLoop = KairosMcp::SkillSets::Agent::CognitiveLoop
MandateAdapter = KairosMcp::SkillSets::Agent::MandateAdapter

# Mock Autoexec::TaskDsl for DECIDE validation
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

  def self.queue_response(response_hash)
    @@responses << response_hash
  end

  def self.clear!
    @@responses.clear
  end

  def name; 'llm_call'; end
  def description; 'mock llm_call'; end
  def input_schema; { type: 'object', properties: {} }; end

  def call(arguments)
    resp = @@responses.shift || { 'content' => 'default', 'tool_use' => nil, 'stop_reason' => 'end_turn' }
    payload = {
      'status' => 'ok',
      'provider' => 'mock',
      'model' => 'mock-1',
      'response' => resp,
      'usage' => { 'input_tokens' => 10, 'output_tokens' => 20 },
      'snapshot' => { 'model' => 'mock-1', 'timestamp' => Time.now.iso8601 }
    }
    text_content(JSON.generate(payload))
  end
end

class MockAutoexecPlan < KairosMcp::Tools::BaseTool
  def name; 'autoexec_plan'; end
  def description; 'mock autoexec_plan'; end
  def input_schema; { type: 'object', properties: {} }; end

  def call(arguments)
    task_json = JSON.parse(arguments['task_json'])
    text_content(JSON.generate({
      'status' => 'ok',
      'task_id' => task_json['task_id'] || 'mock_task_001',
      'plan_hash' => Digest::SHA256.hexdigest(arguments['task_json'])[0..15],
      'steps' => task_json['steps']&.length || 0
    }))
  end
end

class MockAutoexecRun < KairosMcp::Tools::BaseTool
  @@result = { 'status' => 'ok', 'executed_steps' => 1 }

  def self.set_result(result)
    @@result = result
  end

  def self.reset!
    @@result = { 'status' => 'ok', 'executed_steps' => 1 }
  end

  def name; 'autoexec_run'; end
  def description; 'mock autoexec_run'; end
  def input_schema; { type: 'object', properties: {} }; end

  def call(arguments)
    text_content(JSON.generate(@@result))
  end
end

class MockKnowledgeGet < KairosMcp::Tools::BaseTool
  def name; 'knowledge_get'; end
  def description; 'mock'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    text_content(JSON.generate({ 'name' => arguments['name'], 'content' => 'mock content' }))
  end
end

# Build test registry with autoexec mocks
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

# Helper: create session and advance to proposed state
def create_proposed_session(registry)
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => "m3_test_#{SecureRandom.hex(3)}" })
  session_id = JSON.parse(result[0][:text])['session_id']

  valid_decision = JSON.generate({
    'summary' => 'test plan',
    'task_json' => {
      'task_id' => 'test_001', 'meta' => { 'description' => 'test', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'do something', 'tool_name' => 'knowledge_get',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })

  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => 'orient analysis', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue_response({ 'content' => valid_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  session_id
end

registry = build_registry

# =========================================================================
# 1. ACT phase: autoexec integration
# =========================================================================

section "ACT phase (autoexec integration)"

assert("approve at proposed runs ACT+REFLECT and reaches checkpoint") do
  session_id = create_proposed_session(registry)

  # Queue REFLECT LLM response
  reflect_json = JSON.generate({
    'confidence' => 0.8,
    'achieved' => ['step completed'],
    'remaining' => [],
    'learnings' => ['mock works'],
    'open_questions' => []
  })
  MockLlmCall.clear!
  MockAutoexecRun.reset!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' && parsed['state'] == 'checkpoint'
end

assert("ACT uses derived context (autoexec tools unblocked)") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.7, 'achieved' => ['done'], 'remaining' => [],
    'learnings' => [], 'open_questions' => []
  })
  MockLlmCall.clear!
  MockAutoexecRun.reset!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  # If ACT failed because autoexec was blocked, status would be error
  parsed['status'] == 'ok'
end

assert("ACT handles autoexec failure gracefully") do
  session_id = create_proposed_session(registry)

  MockAutoexecRun.set_result({ 'status' => 'error', 'error' => 'step failed' })
  reflect_json = JSON.generate({
    'confidence' => 0.2, 'achieved' => [], 'remaining' => ['everything'],
    'learnings' => ['autoexec failed'], 'open_questions' => []
  })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  # Should still reach checkpoint (ACT failure is evaluated by REFLECT, not a hard error)
  parsed['state'] == 'checkpoint'
end

assert("risk_exceeds_budget terminates session") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'risk_test', 'risk_budget' => 'low' })
  session_id = JSON.parse(result[0][:text])['session_id']

  # Create a decision with high risk steps
  high_risk_decision = JSON.generate({
    'summary' => 'risky plan',
    'task_json' => {
      'task_id' => 'risk_001', 'meta' => { 'description' => 'risky', 'risk_default' => 'high' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'danger', 'tool_name' => 'knowledge_update',
                     'tool_arguments' => {}, 'risk' => 'high', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })

  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => 'orient: risky', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue_response({ 'content' => high_risk_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  # First advance to proposed
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  # Now approve at proposed — should check risk
  MockLlmCall.clear!
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'paused' && parsed['reason'] == 'risk_exceeded'
end

# =========================================================================
# 2. REFLECT evaluation
# =========================================================================

section "REFLECT evaluation"

assert("REFLECT returns parsed confidence and fields") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.85,
    'achieved' => ['A', 'B'],
    'remaining' => ['C'],
    'learnings' => ['lesson1'],
    'open_questions' => ['Q1']
  })
  MockLlmCall.clear!
  MockAutoexecRun.reset!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  reflect = parsed['reflect']
  reflect['confidence'] == 0.85 &&
    reflect['achieved'] == ['A', 'B'] &&
    reflect['remaining'] == ['C']
end

assert("REFLECT handles non-JSON LLM output with confidence=0") do
  session_id = create_proposed_session(registry)

  MockLlmCall.clear!
  MockAutoexecRun.reset!
  MockLlmCall.queue_response({ 'content' => 'I cannot evaluate this properly', 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  reflect = parsed['reflect']
  reflect['confidence'] == 0.0 && reflect.key?('raw')
end

# =========================================================================
# 3. Chain recording
# =========================================================================

section "Chain recording (record_agent_cycle)"

assert("cycle is recorded via Mandate.record_cycle") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.9, 'achieved' => ['all'], 'remaining' => [],
    'learnings' => [], 'open_questions' => []
  })
  MockLlmCall.clear!
  MockAutoexecRun.reset!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  # Verify mandate was updated
  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  mandate[:cycles_completed] >= 1
end

assert("MandateAdapter.reflect_to_evaluation maps high confidence to success") do
  MandateAdapter.reflect_to_evaluation({ 'confidence' => 0.9 }) == 'success'
end

assert("MandateAdapter.reflect_to_evaluation maps low confidence to failed") do
  MandateAdapter.reflect_to_evaluation({ 'confidence' => 0.1 }) == 'failed'
end

# =========================================================================
# 4. skip at proposed → REFLECT with skipped
# =========================================================================

section "skip at proposed"

assert("skip bypasses ACT and reaches checkpoint") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.5, 'achieved' => [], 'remaining' => ['skipped'],
    'learnings' => ['user skipped'], 'open_questions' => []
  })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'skip' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' && parsed['state'] == 'checkpoint'
end

assert("skip saves progress and increments cycle") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.4, 'achieved' => [], 'remaining' => ['all'],
    'learnings' => ['skipped'], 'open_questions' => []
  })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  step_tool.call({ 'session_id' => session_id, 'action' => 'skip' })

  session = Session.load(session_id)
  # cycle_number should be incremented
  session.cycle_number == 1 &&
    # progress should be saved
    session.load_progress.length == 1 &&
    session.load_progress[0]['act_summary'] == 'skipped' &&
    session.load_progress[0]['cycle'] == 1
end

assert("skip records cycle on mandate") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.3, 'achieved' => [], 'remaining' => ['x'],
    'learnings' => [], 'open_questions' => []
  })
  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  step_tool.call({ 'session_id' => session_id, 'action' => 'skip' })

  session = Session.load(session_id)
  mandate = Autonomos::Mandate.load(session.mandate_id)
  mandate[:cycles_completed] >= 1
end

# =========================================================================
# 5. Next cycle (checkpoint → observed)
# =========================================================================

section "Next cycle (checkpoint → observed)"

assert("approve at checkpoint starts next cycle") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.8, 'achieved' => ['step1'], 'remaining' => ['step2'],
    'learnings' => [], 'open_questions' => []
  })
  MockLlmCall.clear!
  MockAutoexecRun.reset!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  # Approve at proposed → checkpoint
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  # Approve at checkpoint → observed (next cycle)
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' && parsed['state'] == 'observed' && parsed['cycle'] == 2
end

assert("max_cycles terminates at checkpoint") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'max_cycle_test', 'max_cycles' => 1 })
  session_id = JSON.parse(result[0][:text])['session_id']

  valid_decision = JSON.generate({
    'summary' => 'plan', 'task_json' => {
      'task_id' => 't_max', 'meta' => { 'description' => 'x', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'a', 'tool_name' => 'echo',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })
  reflect_json = JSON.generate({
    'confidence' => 0.8, 'achieved' => ['done'], 'remaining' => [],
    'learnings' => [], 'open_questions' => []
  })

  MockLlmCall.clear!
  MockAutoexecRun.reset!
  # ORIENT + DECIDE
  MockLlmCall.queue_response({ 'content' => 'orient ok', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue_response({ 'content' => valid_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  # REFLECT
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  # observed → proposed
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  # proposed → checkpoint
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  # checkpoint → should terminate (max_cycles=1)
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'terminated'
end

# =========================================================================
# 6. M5: Progress file (Session methods)
# =========================================================================

section "M5: Progress file (Session)"

assert("save_progress appends JSONL lines") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'progress_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  r1 = { 'confidence' => 0.6, 'achieved' => ['A'], 'remaining' => ['B'], 'learnings' => ['L1'], 'open_questions' => [] }
  r2 = { 'confidence' => 0.8, 'achieved' => ['A', 'B'], 'remaining' => [], 'learnings' => ['L2'], 'open_questions' => [] }
  session.save_progress(r1, 0, 'completed', 'plan A')
  session.save_progress(r2, 1, 'completed', 'plan B')

  # Read raw file
  path = File.join(Autonomos.storage_path("agent_sessions/#{session_id}"), 'progress.jsonl')
  lines = File.readlines(path)
  lines.length == 2 &&
    JSON.parse(lines[0])['cycle'] == 0 &&
    JSON.parse(lines[1])['cycle'] == 1
end

assert("load_progress returns chronologically ordered entries") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'load_progress_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  3.times do |i|
    r = { 'confidence' => 0.5 + i * 0.1, 'achieved' => ["item_#{i}"], 'remaining' => [], 'learnings' => [], 'open_questions' => [] }
    session.save_progress(r, i, 'ok', "plan_#{i}")
  end

  entries = session.load_progress(max_entries: 10)
  entries.length == 3 &&
    entries[0]['cycle'] == 0 &&
    entries[2]['cycle'] == 2
end

assert("load_progress skips corrupted lines") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'corrupt_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  r = { 'confidence' => 0.7, 'achieved' => ['ok'], 'remaining' => [], 'learnings' => [], 'open_questions' => [] }
  session.save_progress(r, 0, 'ok', 'plan')

  # Inject corrupted line
  path = File.join(Autonomos.storage_path("agent_sessions/#{session_id}"), 'progress.jsonl')
  File.open(path, 'a') { |f| f.puts("NOT VALID JSON {{{") }

  r2 = { 'confidence' => 0.9, 'achieved' => ['all'], 'remaining' => [], 'learnings' => [], 'open_questions' => [] }
  session.save_progress(r2, 1, 'ok', 'plan2')

  entries = session.load_progress(max_entries: 10)
  entries.length == 2 &&
    entries[0]['cycle'] == 0 &&
    entries[1]['cycle'] == 1
end

assert("load_progress respects max_entries") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'max_entries_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  5.times do |i|
    r = { 'confidence' => 0.5, 'achieved' => [], 'remaining' => [], 'learnings' => [], 'open_questions' => [] }
    session.save_progress(r, i, 'ok', "plan_#{i}")
  end

  entries = session.load_progress(max_entries: 3)
  entries.length == 3 &&
    entries[0]['cycle'] == 2 &&  # last 3: cycles 2, 3, 4
    entries[2]['cycle'] == 4
end

assert("load_progress returns [] when no file exists") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'empty_progress_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)
  session.load_progress == []
end

# =========================================================================
# 7. M5: REFLECT saves progress (E2E)
# =========================================================================

section "M5: REFLECT saves progress (E2E)"

assert("ACT+REFLECT cycle saves progress.jsonl entry") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.75,
    'achieved' => ['implemented feature'],
    'remaining' => ['write tests'],
    'learnings' => ['mock is fast'],
    'open_questions' => ['coverage target?']
  })
  MockLlmCall.clear!
  MockAutoexecRun.reset!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  session = Session.load(session_id)
  entries = session.load_progress
  entries.length == 1 &&
    entries[0]['cycle'] == 1 &&  # 1-based cycle numbering
    entries[0]['confidence'] == 0.75 &&
    entries[0]['achieved'] == ['implemented feature'] &&
    entries[0]['decision_summary'] == 'test plan'
end

# =========================================================================
# 8. M5: ORIENT prompt includes progress
# =========================================================================

section "M5: ORIENT prompt includes progress"

assert("build_orient_prompt includes progress from previous cycles") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'orient_progress_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  # Manually save progress entries
  r = { 'confidence' => 0.7, 'achieved' => ['X'], 'remaining' => ['Y'], 'learnings' => ['Z'], 'open_questions' => [] }
  session.save_progress(r, 1, 'done', 'plan A')

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  prompt = step_tool.send(:build_orient_prompt, session, 'obs data')
  prompt.include?('Progress from previous cycles') &&
    prompt.include?('Cycle 1') &&
    prompt.include?('Achieved: X') &&
    prompt.include?('obs data')
end

assert("observation does not duplicate progress_history") do
  session_id = create_proposed_session(registry)

  reflect_json = JSON.generate({
    'confidence' => 0.8, 'achieved' => ['A'], 'remaining' => ['B'],
    'learnings' => ['L1'], 'open_questions' => []
  })
  MockLlmCall.clear!
  MockAutoexecRun.reset!
  MockLlmCall.queue_response({ 'content' => reflect_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  # proposed → checkpoint
  step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })

  # checkpoint → observed (next cycle)
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  obs = parsed['observation']
  # progress_history should NOT be in observation (injected via build_orient_prompt instead)
  !obs.key?('progress_history')
end

# =========================================================================
# 9. M5: format_progress_for_prompt
# =========================================================================

section "M5: format_progress_for_prompt"

assert("format_progress_for_prompt produces concise text") do
  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  entries = [
    { 'cycle' => 0, 'confidence' => 0.6, 'achieved' => ['A'], 'remaining' => ['B'], 'learnings' => ['L1'] },
    { 'cycle' => 1, 'confidence' => 0.9, 'achieved' => ['A', 'B'], 'remaining' => [], 'learnings' => ['L2'] }
  ]
  text = step_tool.send(:format_progress_for_prompt, entries)
  text.include?('Cycle 0') && text.include?('Cycle 1') &&
    text.include?('confidence: 0.6') && text.include?('confidence: 0.9') &&
    text.include?('Achieved: A.') && text.include?('Learnings: L2.')
end

assert("format_progress_for_prompt handles empty") do
  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  text = step_tool.send(:format_progress_for_prompt, [])
  text == "No previous cycles."
end

# =========================================================================
# Cleanup
# =========================================================================

FileUtils.rm_rf(TMPDIR)

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
