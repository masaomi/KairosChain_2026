#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for M2: agent_start + agent_step (observe + orient/decide, state machine)
# Usage: ruby test_agent_m2.rb

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
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

# ---- Test infrastructure ----

TMPDIR = Dir.mktmpdir('agent_m2_test')

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
MF = KairosMcp::SkillSets::Agent::MessageFormat

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

# ---- Mock LLM tool for testing ----

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

class MockKnowledgeGet < KairosMcp::Tools::BaseTool
  def name; 'knowledge_get'; end
  def description; 'mock'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    text_content(JSON.generate({ 'name' => arguments['name'], 'content' => 'mock content' }))
  end
end

# Build test registry
def build_registry
  registry = KairosMcp::ToolRegistry.allocate
  registry.instance_variable_set(:@safety, KairosMcp::Safety.new)
  registry.instance_variable_set(:@tools, {})
  KairosMcp::ToolRegistry.clear_gates!

  tools = {
    'llm_call' => MockLlmCall.new(nil, registry: registry),
    'knowledge_get' => MockKnowledgeGet.new(nil, registry: registry),
    'agent_start' => KairosMcp::SkillSets::Agent::Tools::AgentStart.new(nil, registry: registry),
    'agent_step' => KairosMcp::SkillSets::Agent::Tools::AgentStep.new(nil, registry: registry),
    'agent_status' => KairosMcp::SkillSets::Agent::Tools::AgentStatus.new(nil, registry: registry),
    'agent_stop' => KairosMcp::SkillSets::Agent::Tools::AgentStop.new(nil, registry: registry)
  }
  registry.instance_variable_set(:@tools, tools)
  registry
end

# =========================================================================
# 1. Tool schemas
# =========================================================================

section "Tool schemas"

registry = build_registry

assert("agent_start has correct schema") do
  tool = registry.instance_variable_get(:@tools)['agent_start']
  schema = tool.input_schema
  schema[:properties].key?(:goal_name) && schema[:required] == ['goal_name']
end

assert("agent_step has correct schema") do
  tool = registry.instance_variable_get(:@tools)['agent_step']
  schema = tool.input_schema
  schema[:properties].key?(:session_id) && schema[:properties].key?(:action)
end

assert("agent_status has optional session_id") do
  tool = registry.instance_variable_get(:@tools)['agent_status']
  schema = tool.input_schema
  schema[:properties].key?(:session_id) && !schema.key?(:required)
end

assert("agent_stop requires session_id") do
  tool = registry.instance_variable_get(:@tools)['agent_stop']
  schema = tool.input_schema
  schema[:required] == ['session_id']
end

# =========================================================================
# 2. agent_start
# =========================================================================

section "agent_start"

assert("creates session and returns observation") do
  tool = registry.instance_variable_get(:@tools)['agent_start']
  result = tool.call({ 'goal_name' => 'test_goal' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' &&
    parsed['state'] == 'observed' &&
    !parsed['session_id'].nil? &&
    !parsed['mandate_id'].nil?
end

assert("created session can be loaded") do
  tool = registry.instance_variable_get(:@tools)['agent_start']
  result = tool.call({ 'goal_name' => 'load_test_goal' })
  parsed = JSON.parse(result[0][:text])
  session = Session.load(parsed['session_id'])
  session && session.state == 'observed' && session.goal_name == 'load_test_goal'
end

assert("rejects invalid max_cycles") do
  tool = registry.instance_variable_get(:@tools)['agent_start']
  result = tool.call({ 'goal_name' => 'test', 'max_cycles' => 99 })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'error'
end

# =========================================================================
# 3. State machine: stop from any state
# =========================================================================

section "agent_stop"

assert("stop terminates session from observed state") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'stop_test' })
  session_id = JSON.parse(result[0][:text])['session_id']

  stop_tool = registry.instance_variable_get(:@tools)['agent_stop']
  stop_result = stop_tool.call({ 'session_id' => session_id })
  parsed = JSON.parse(stop_result[0][:text])
  parsed['status'] == 'ok' && parsed['state'] == 'terminated' && parsed['previous_state'] == 'observed'
end

assert("stop returns error for nonexistent session") do
  stop_tool = registry.instance_variable_get(:@tools)['agent_stop']
  result = stop_tool.call({ 'session_id' => 'nonexistent_xyz' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'error'
end

# =========================================================================
# 4. agent_status
# =========================================================================

section "agent_status"

assert("returns session info by ID") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'status_test' })
  session_id = JSON.parse(result[0][:text])['session_id']

  status_tool = registry.instance_variable_get(:@tools)['agent_status']
  status_result = status_tool.call({ 'session_id' => session_id })
  parsed = JSON.parse(status_result[0][:text])
  parsed['status'] == 'ok' && parsed['state'] == 'observed' && parsed['goal_name'] == 'status_test'
end

assert("lists active sessions when no session_id") do
  status_tool = registry.instance_variable_get(:@tools)['agent_status']
  result = status_tool.call({})
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' && parsed['active_sessions'].is_a?(Array)
end

# =========================================================================
# 5. CognitiveLoop with mock LLM
# =========================================================================

section "CognitiveLoop#run_phase (mock LLM)"

assert("run_phase returns content when no tool_use") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'loop_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  loop_inst = CognitiveLoop.new(step_tool, session)

  MockLlmCall.clear!
  MockLlmCall.queue_response({ 'content' => 'Analysis: all good', 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  result = loop_inst.run_phase('orient', 'system prompt', [{ 'role' => 'user', 'content' => 'test' }], [])
  result['content'] == 'Analysis: all good'
end

assert("run_phase handles tool_use loop") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'tool_loop_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  loop_inst = CognitiveLoop.new(step_tool, session)

  MockLlmCall.clear!
  # First call: LLM requests a tool
  MockLlmCall.queue_response({
    'content' => nil,
    'tool_use' => [{ 'id' => 'tu_1', 'name' => 'knowledge_get', 'input' => { 'name' => 'test' } }],
    'stop_reason' => 'tool_use'
  })
  # Second call: LLM returns final answer
  MockLlmCall.queue_response({ 'content' => 'Done after tool use', 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  result = loop_inst.run_phase('orient', 'system', [{ 'role' => 'user', 'content' => 'test' }], %w[knowledge_get])
  result['content'] == 'Done after tool use'
end

assert("run_phase enforces budget limit") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'budget_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  # Override config for tight budget
  session.config['phases'] ||= {}
  session.config['phases']['orient'] = { 'max_llm_calls' => 1 }

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  loop_inst = CognitiveLoop.new(step_tool, session)

  MockLlmCall.clear!
  # First call requests tool (uses up the 1 allowed LLM call)
  MockLlmCall.queue_response({
    'content' => nil,
    'tool_use' => [{ 'id' => 'tu_1', 'name' => 'knowledge_get', 'input' => {} }],
    'stop_reason' => 'tool_use'
  })

  result = loop_inst.run_phase('orient', 'system', [{ 'role' => 'user', 'content' => 'test' }], %w[knowledge_get])
  result['stop_reason'] == 'budget'
end

# =========================================================================
# 6. CognitiveLoop#run_decide (mock LLM)
# =========================================================================

section "CognitiveLoop#run_decide (mock LLM)"

assert("run_decide extracts valid JSON decision") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'decide_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  loop_inst = CognitiveLoop.new(step_tool, session)

  valid_decision = {
    'summary' => 'test plan',
    'task_json' => {
      'task_id' => 'test_001', 'meta' => { 'description' => 'test', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'test', 'tool_name' => 'knowledge_get',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  }

  MockLlmCall.clear!
  MockLlmCall.queue_response({
    'content' => JSON.generate(valid_decision), 'tool_use' => nil, 'stop_reason' => 'end_turn'
  })

  result = loop_inst.run_decide('system', [{ 'role' => 'user', 'content' => 'plan' }])
  result['decision_payload'] && result['decision_payload']['summary'] == 'test plan'
end

assert("run_decide handles code-fenced JSON") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'fence_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  loop_inst = CognitiveLoop.new(step_tool, session)

  valid_json = JSON.generate({
    'summary' => 'fenced',
    'task_json' => {
      'task_id' => 't_002', 'meta' => { 'description' => 'x', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'a', 'tool_name' => 'knowledge_get',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })

  MockLlmCall.clear!
  MockLlmCall.queue_response({
    'content' => "Here is the plan:\n```json\n#{valid_json}\n```", 'tool_use' => nil, 'stop_reason' => 'end_turn'
  })

  result = loop_inst.run_decide('system', [{ 'role' => 'user', 'content' => 'plan' }])
  result['decision_payload'] && result['decision_payload']['summary'] == 'fenced'
end

assert("run_decide repair loop on invalid JSON") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'repair_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  loop_inst = CognitiveLoop.new(step_tool, session)

  valid_decision = JSON.generate({
    'summary' => 'repaired',
    'task_json' => {
      'task_id' => 't_003', 'meta' => { 'description' => 'x', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'a', 'tool_name' => 'echo',
                     'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
                     'requires_human_cognition' => false }]
    }
  })

  MockLlmCall.clear!
  # First attempt: invalid
  MockLlmCall.queue_response({ 'content' => 'not json at all', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  # Second attempt: valid
  MockLlmCall.queue_response({ 'content' => valid_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })

  result = loop_inst.run_decide('system', [{ 'role' => 'user', 'content' => 'plan' }])
  result['decision_payload'] && result['decision_payload']['summary'] == 'repaired'
end

assert("run_decide fails after max repair attempts") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'max_repair_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  loop_inst = CognitiveLoop.new(step_tool, session)

  MockLlmCall.clear!
  5.times { MockLlmCall.queue_response({ 'content' => 'still not json', 'tool_use' => nil, 'stop_reason' => 'end_turn' }) }

  result = loop_inst.run_decide('system', [{ 'role' => 'user', 'content' => 'plan' }], max_repair: 3)
  result['error'] && result['error'].include?('no valid JSON')
end

# =========================================================================
# 7. State machine: approve at wrong state
# =========================================================================

section "State machine edge cases"

assert("approve at terminated returns error") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'wrong_state_test' })
  session_id = JSON.parse(result[0][:text])['session_id']

  # Terminate first
  stop_tool = registry.instance_variable_get(:@tools)['agent_stop']
  stop_tool.call({ 'session_id' => session_id })

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'approve' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'error' && parsed['error'].include?('terminated')
end

assert("revise at observed returns error") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'revise_wrong_state' })
  session_id = JSON.parse(result[0][:text])['session_id']

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'revise' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'error' && parsed['error'].include?('proposed')
end

assert("skip at observed returns error") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'skip_wrong_state' })
  session_id = JSON.parse(result[0][:text])['session_id']

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  result = step_tool.call({ 'session_id' => session_id, 'action' => 'skip' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'error' && parsed['error'].include?('proposed')
end

# =========================================================================
# 8. Batch budget pre-validation
# =========================================================================

section "Batch budget pre-validation"

assert("rejects tool batch exceeding budget") do
  start_tool = registry.instance_variable_get(:@tools)['agent_start']
  result = start_tool.call({ 'goal_name' => 'batch_budget_test' })
  session_id = JSON.parse(result[0][:text])['session_id']
  session = Session.load(session_id)
  session.config['phases'] ||= {}
  session.config['phases']['orient'] = { 'max_llm_calls' => 10, 'max_tool_calls' => 1 }

  step_tool = registry.instance_variable_get(:@tools)['agent_step']
  loop_inst = CognitiveLoop.new(step_tool, session)

  MockLlmCall.clear!
  MockLlmCall.queue_response({
    'content' => nil,
    'tool_use' => [
      { 'id' => 'tu_1', 'name' => 'knowledge_get', 'input' => {} },
      { 'id' => 'tu_2', 'name' => 'knowledge_get', 'input' => {} }
    ],
    'stop_reason' => 'tool_use'
  })

  result = loop_inst.run_phase('orient', 'sys', [{ 'role' => 'user', 'content' => 'test' }], %w[knowledge_get])
  result['stop_reason'] == 'budget'
end

# =========================================================================
# Cleanup
# =========================================================================

FileUtils.rm_rf(TMPDIR)

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
