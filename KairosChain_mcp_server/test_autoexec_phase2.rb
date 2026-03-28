#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Phase 2: autoexec internal_execute
# Usage: ruby test_autoexec_phase2.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'fileutils'
require 'digest'
require 'time'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'

# Load autoexec SkillSet
skillset_base = File.join(__dir__, '..', '.kairos', 'skillsets', 'autoexec')
require File.join(skillset_base, 'lib', 'autoexec')
require File.join(skillset_base, 'tools', 'autoexec_run')
require File.join(skillset_base, 'tools', 'autoexec_plan')

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

# Setup temp storage
TEST_DIR = File.join(__dir__, 'tmp_autoexec_phase2_test')
FileUtils.rm_rf(TEST_DIR)
FileUtils.mkdir_p(File.join(TEST_DIR, 'plans'))
FileUtils.mkdir_p(File.join(TEST_DIR, 'state'))

# Override storage path
module Autoexec
  def self.storage_path(sub)
    File.join(TEST_DIR, sub)
  end
  def self.config
    { 'max_steps' => 20 }
  end
end

# =========================================================================
# 1. TaskStep extension
# =========================================================================

section "TaskStep with tool_name/tool_arguments"

assert("TaskStep accepts tool_name and tool_arguments") do
  step = Autoexec::TaskStep.new(
    step_id: :s1, action: "test", risk: :low, depends_on: [],
    requires_human_cognition: false,
    tool_name: "knowledge_get", tool_arguments: { "name" => "readme" }
  )
  step.tool_name == "knowledge_get" && step.tool_arguments == { "name" => "readme" }
end

assert("TaskStep.to_h includes tool_name when present") do
  step = Autoexec::TaskStep.new(
    step_id: :s1, action: "test", risk: :low, depends_on: [],
    tool_name: "knowledge_get", tool_arguments: { "name" => "readme" }
  )
  h = step.to_h
  h[:tool_name] == "knowledge_get" && h[:tool_arguments] == { "name" => "readme" }
end

assert("TaskStep.to_h omits tool_name when nil") do
  step = Autoexec::TaskStep.new(step_id: :s1, action: "test", risk: :low, depends_on: [])
  h = step.to_h
  !h.key?(:tool_name) && !h.key?(:tool_arguments)
end

# =========================================================================
# 2. from_json with tool_name
# =========================================================================

section "TaskDsl.from_json with executable steps"

EXEC_PLAN_JSON = {
  task_id: "test_exec",
  meta: { description: "Test executable plan", risk_default: "low" },
  steps: [
    { step_id: "s1", action: "Get knowledge", tool_name: "knowledge_get",
      tool_arguments: { name: "readme" }, risk: "low" },
    { step_id: "s2", action: "Save context", tool_name: "context_save",
      tool_arguments: { name: "test", content: "hello" }, risk: "medium",
      depends_on: ["s1"] }
  ]
}.freeze

assert("from_json parses tool_name and tool_arguments") do
  plan = Autoexec::TaskDsl.from_json(JSON.generate(EXEC_PLAN_JSON))
  plan.steps[0].tool_name == "knowledge_get" &&
    plan.steps[0].tool_arguments == { "name" => "readme" } &&
    plan.steps[1].tool_name == "context_save"
end

assert("tool_arguments keys are stringified") do
  plan = Autoexec::TaskDsl.from_json(JSON.generate(EXEC_PLAN_JSON))
  plan.steps[0].tool_arguments.keys.all? { |k| k.is_a?(String) }
end

assert("from_json without tool_name still works (backward compat)") do
  legacy = { task_id: "legacy", steps: [{ step_id: "s1", action: "do something", risk: "low" }] }
  plan = Autoexec::TaskDsl.from_json(JSON.generate(legacy))
  plan.steps[0].tool_name.nil? && plan.steps[0].tool_arguments.nil?
end

# =========================================================================
# 3. Validation
# =========================================================================

section "Validation with tool_name"

assert("rejects invalid tool_name characters") do
  bad = { task_id: "t", steps: [{ step_id: "s1", action: "x", tool_name: "DROP TABLE", risk: "low" }] }
  begin
    Autoexec::TaskDsl.from_json(JSON.generate(bad))
    false
  rescue Autoexec::TaskDsl::ParseError => e
    e.message.include?("Invalid tool_name")
  end
end

assert("rejects empty tool_name") do
  bad = { task_id: "t", steps: [{ step_id: "s1", action: "x", tool_name: "", risk: "low" }] }
  begin
    Autoexec::TaskDsl.from_json(JSON.generate(bad))
    false
  rescue Autoexec::TaskDsl::ParseError => e
    e.message.include?("Empty tool_name")
  end
end

assert("rejects non-Hash tool_arguments") do
  bad = { task_id: "t", steps: [{ step_id: "s1", action: "x", tool_name: "echo", tool_arguments: "string", risk: "low" }] }
  begin
    Autoexec::TaskDsl.from_json(JSON.generate(bad))
    false
  rescue Autoexec::TaskDsl::ParseError => e
    e.message.include?("tool_arguments must be a Hash")
  end
end

# =========================================================================
# 4. Canonical hashing
# =========================================================================

section "Canonical plan hashing"

assert("same plan different key order → same hash") do
  plan_a = { task_id: "t", steps: [{ step_id: "s1", action: "x", tool_name: "echo",
    tool_arguments: { "b" => 2, "a" => 1 }, risk: "low" }] }
  plan_b = { task_id: "t", steps: [{ step_id: "s1", action: "x", tool_name: "echo",
    tool_arguments: { "a" => 1, "b" => 2 }, risk: "low" }] }
  p_a = Autoexec::TaskDsl.from_json(JSON.generate(plan_a))
  p_b = Autoexec::TaskDsl.from_json(JSON.generate(plan_b))
  p_a.source_hash == p_b.source_hash
end

assert("modified tool_arguments → different hash") do
  plan_a = { task_id: "t", steps: [{ step_id: "s1", action: "x", tool_name: "echo",
    tool_arguments: { "a" => 1 }, risk: "low" }] }
  plan_b = { task_id: "t", steps: [{ step_id: "s1", action: "x", tool_name: "echo",
    tool_arguments: { "a" => 2 }, risk: "low" }] }
  p_a = Autoexec::TaskDsl.from_json(JSON.generate(plan_a))
  p_b = Autoexec::TaskDsl.from_json(JSON.generate(plan_b))
  p_a.source_hash != p_b.source_hash
end

# =========================================================================
# 5. PlanStore: save_executable + load
# =========================================================================

section "PlanStore executable save/load"

assert("save_executable creates .plan.json and metadata") do
  plan = Autoexec::TaskDsl.from_json(JSON.generate(EXEC_PLAN_JSON))
  hash = Autoexec::PlanStore.save_executable("test_exec", plan)
  plan_file = File.join(TEST_DIR, 'plans', 'test_exec.plan.json')
  meta_file = File.join(TEST_DIR, 'plans', 'test_exec.json')
  File.exist?(plan_file) && File.exist?(meta_file) && hash.is_a?(String)
end

assert("load detects executable plan format") do
  stored = Autoexec::PlanStore.load("test_exec")
  stored && stored[:plan].steps[0].tool_name == "knowledge_get" &&
    stored[:metadata][:executable] == true
end

assert("hash verification works for executable plans") do
  plan = Autoexec::TaskDsl.from_json(JSON.generate(EXEC_PLAN_JSON))
  hash = Autoexec::PlanStore.save_executable("test_verify", plan)
  Autoexec::PlanStore.verify_hash("test_verify", hash)
end

assert("list excludes .plan.json from metadata results") do
  list = Autoexec::PlanStore.list
  list.all? { |m| m.is_a?(Hash) && m[:task_id] }
end

# =========================================================================
# 6. RiskClassifier with tool_name
# =========================================================================

section "RiskClassifier tool_name tiers"

assert("skills_evolve classified as high risk by tool_name") do
  step = Autoexec::TaskStep.new(
    step_id: :s1, action: "update some docs", risk: :low, depends_on: [],
    tool_name: "skills_evolve"
  )
  Autoexec::RiskClassifier.classify_step(step) == :high
end

assert("knowledge_update classified as medium risk by tool_name") do
  step = Autoexec::TaskStep.new(
    step_id: :s1, action: "read stuff", risk: :low, depends_on: [],
    tool_name: "knowledge_update"
  )
  Autoexec::RiskClassifier.classify_step(step) == :medium
end

assert("unknown tool falls through to text classification") do
  step = Autoexec::TaskStep.new(
    step_id: :s1, action: "analyze the code", risk: :low, depends_on: [],
    tool_name: "some_custom_tool"
  )
  # "analyze" matches :low in text rules
  Autoexec::RiskClassifier.classify_step(step) == :low
end

assert("step without tool_name uses text classification (backward compat)") do
  step = Autoexec::TaskStep.new(
    step_id: :s1, action: "delete everything", risk: :low, depends_on: []
  )
  Autoexec::RiskClassifier.classify_step(step) == :high
end

# =========================================================================
# 7. E2E: from_json → save → load → verify
# =========================================================================

section "E2E persistence roundtrip"

assert("from_json → save_executable → load → hash matches") do
  plan = Autoexec::TaskDsl.from_json(JSON.generate(EXEC_PLAN_JSON))
  saved_hash = Autoexec::PlanStore.save_executable("e2e_test", plan)
  loaded = Autoexec::PlanStore.load("e2e_test")
  loaded[:hash] == saved_hash &&
    loaded[:plan].steps.length == 2 &&
    loaded[:plan].steps[0].tool_name == "knowledge_get"
end

# =========================================================================
# 8. internal_execute integration tests (mock registry)
# =========================================================================

section "internal_execute integration (mock tools)"

# Build a mock registry with known tools
mock_registry = KairosMcp::ToolRegistry.allocate
mock_registry.instance_variable_set(:@safety, KairosMcp::Safety.new)
mock_registry.instance_variable_set(:@tools, {})
KairosMcp::ToolRegistry.clear_gates!

class MockEchoTool < KairosMcp::Tools::BaseTool
  def name; "echo_tool"; end
  def description; "echo"; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    text_content("echo: #{arguments.to_json}")
  end
end

class MockFailTool < KairosMcp::Tools::BaseTool
  def name; "fail_tool"; end
  def description; "always fails"; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    raise "Intentional failure for testing"
  end
end

class MockErrorPayloadTool < KairosMcp::Tools::BaseTool
  def name; "error_payload_tool"; end
  def description; "returns MCP error payload"; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    text_content(JSON.generate({ 'error' => 'forbidden', 'message' => 'Access denied by gate' }))
  end
end

echo = MockEchoTool.new(nil, registry: mock_registry)
fail_t = MockFailTool.new(nil, registry: mock_registry)
error_t = MockErrorPayloadTool.new(nil, registry: mock_registry)
mock_registry.instance_variable_set(:@tools, {
  "echo_tool" => echo, "fail_tool" => fail_t, "error_payload_tool" => error_t
})

# Create autoexec_run tool with mock registry
autoexec_run = KairosMcp::SkillSets::Autoexec::Tools::AutoexecRun.new(nil, registry: mock_registry)

# Helper: create and save an executable plan, return task_id and hash
def create_exec_plan(steps, task_id: "int_test_#{SecureRandom.hex(4)}")
  plan_json = {
    task_id: task_id,
    meta: { description: "Integration test", risk_default: "low" },
    steps: steps
  }
  plan = Autoexec::TaskDsl.from_json(JSON.generate(plan_json))
  hash = Autoexec::PlanStore.save_executable(task_id, plan)
  [task_id, hash]
end

# -- Success --
assert("internal_execute: successful tool execution") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Echo test", tool_name: "echo_tool",
      tool_arguments: { "msg" => "hello" }, risk: "low" }
  ])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash
  })
  parsed = JSON.parse(result[0][:text])
  parsed['outcome'] == 'internal_execute_complete' &&
    parsed['steps'][0]['status'] == 'executed' &&
    parsed['steps'][0]['tool_result'].include?('echo:')
end

# -- Tool not found --
assert("internal_execute: tool not found → failed + halted") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Call nonexistent", tool_name: "nonexistent_tool",
      tool_arguments: {}, risk: "low" }
  ])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash
  })
  parsed = JSON.parse(result[0][:text])
  parsed['outcome'] == 'internal_execute_halted' &&
    parsed['steps'][0]['status'] == 'failed' &&
    parsed['steps'][0]['error'].include?('not found')
end

# -- Tool raises exception --
assert("internal_execute: tool exception → failed + halted") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Fail", tool_name: "fail_tool",
      tool_arguments: {}, risk: "low" }
  ])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash
  })
  parsed = JSON.parse(result[0][:text])
  parsed['outcome'] == 'internal_execute_halted' &&
    parsed['steps'][0]['status'] == 'failed' &&
    parsed['steps'][0]['error'].include?('Intentional failure')
end

# -- MCP error payload detection --
assert("internal_execute: MCP error payload detected as failure") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Error payload", tool_name: "error_payload_tool",
      tool_arguments: {}, risk: "low" }
  ])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash
  })
  parsed = JSON.parse(result[0][:text])
  parsed['outcome'] == 'internal_execute_halted' &&
    parsed['steps'][0]['status'] == 'forbidden'
end

# -- No tool_name → delegated fallback --
assert("internal_execute: no tool_name → delegated") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Manual step", risk: "low" }
  ])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash
  })
  parsed = JSON.parse(result[0][:text])
  parsed['steps'][0]['status'] == 'delegated'
end

# -- Multi-step: halts on first failure --
assert("internal_execute: multi-step halts on first failure") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Echo", tool_name: "echo_tool",
      tool_arguments: { "x" => 1 }, risk: "low" },
    { step_id: "s2", action: "Fail", tool_name: "fail_tool",
      tool_arguments: {}, risk: "low", depends_on: ["s1"] },
    { step_id: "s3", action: "Should not run", tool_name: "echo_tool",
      tool_arguments: {}, risk: "low", depends_on: ["s2"] }
  ])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash
  })
  parsed = JSON.parse(result[0][:text])
  parsed['outcome'] == 'internal_execute_halted' &&
    parsed['steps_processed'] == 2 &&
    parsed['steps'][0]['status'] == 'executed' &&
    parsed['steps'][1]['status'] == 'failed'
end

# =========================================================================
# 9. InvocationContext in internal_execute
# =========================================================================

section "InvocationContext in internal_execute"

assert("internal_execute: with policy context → blacklisted tool denied") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Echo", tool_name: "echo_tool",
      tool_arguments: { "x" => 1 }, risk: "low" }
  ])
  ctx = KairosMcp::InvocationContext.new(blacklist: ["echo_tool"])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash,
    'invocation_context_json' => ctx.to_json
  })
  parsed = JSON.parse(result[0][:text])
  parsed['outcome'] == 'internal_execute_halted' &&
    parsed['steps'][0]['status'] == 'policy_denied'
end

assert("internal_execute: malformed context_json → fail-closed (deny-all)") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Echo", tool_name: "echo_tool",
      tool_arguments: {}, risk: "low" }
  ])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash,
    'invocation_context_json' => '{invalid json!!!'
  })
  parsed = JSON.parse(result[0][:text])
  # Fail-closed: deny-all context means echo_tool is blocked
  parsed['outcome'] == 'internal_execute_halted' &&
    parsed['steps'][0]['status'] == 'policy_denied'
end

assert("internal_execute: without context_json → no policy (allows all)") do
  tid, hash = create_exec_plan([
    { step_id: "s1", action: "Echo", tool_name: "echo_tool",
      tool_arguments: { "ok" => true }, risk: "low" }
  ])
  result = autoexec_run.call({
    'task_id' => tid, 'mode' => 'internal_execute', 'approved_hash' => hash
  })
  parsed = JSON.parse(result[0][:text])
  parsed['outcome'] == 'internal_execute_complete' &&
    parsed['steps'][0]['status'] == 'executed'
end

# =========================================================================
# 10. decode_tool_result unit tests
# =========================================================================

section "decode_tool_result"

assert("decode_tool_result: normal text → success") do
  result = autoexec_run.send(:decode_tool_result, [{ text: "hello world" }])
  !result[:error] && result[:summary] == "hello world"
end

assert("decode_tool_result: nil → error") do
  result = autoexec_run.send(:decode_tool_result, nil)
  result[:error] && result[:error_type] == 'no_result'
end

assert("decode_tool_result: MCP forbidden payload → error") do
  payload = [{ text: JSON.generate({ 'error' => 'forbidden', 'message' => 'blocked' }) }]
  result = autoexec_run.send(:decode_tool_result, payload)
  result[:error] && result[:error_type] == 'forbidden'
end

assert("decode_tool_result: MCP invocation_denied payload → error") do
  payload = [{ text: JSON.generate({ 'error' => 'invocation_denied', 'message' => 'depth exceeded' }) }]
  result = autoexec_run.send(:decode_tool_result, payload)
  result[:error] && result[:error_type] == 'invocation_denied'
end

assert("decode_tool_result: normal JSON without error key → success") do
  payload = [{ text: JSON.generate({ 'status' => 'ok', 'data' => [1, 2, 3] }) }]
  result = autoexec_run.send(:decode_tool_result, payload)
  !result[:error]
end

assert("decode_tool_result: long result truncated") do
  long_text = "x" * 600
  result = autoexec_run.send(:decode_tool_result, [{ text: long_text }])
  !result[:error] && result[:summary].length <= 501 && result[:summary].end_with?("...")
end

# =========================================================================
# 11. build_invocation_context unit tests
# =========================================================================

section "build_invocation_context"

assert("build_invocation_context: valid JSON → context with policy") do
  ctx = KairosMcp::InvocationContext.new(whitelist: ["echo_*"], blacklist: ["fail_*"])
  result = autoexec_run.send(:build_invocation_context, { 'invocation_context_json' => ctx.to_json })
  result.is_a?(KairosMcp::InvocationContext) &&
    result.allowed?("echo_tool") &&
    !result.allowed?("fail_tool")
end

assert("build_invocation_context: nil → nil (no policy)") do
  result = autoexec_run.send(:build_invocation_context, {})
  result.nil?
end

assert("build_invocation_context: empty string → nil") do
  result = autoexec_run.send(:build_invocation_context, { 'invocation_context_json' => '' })
  result.nil?
end

assert("build_invocation_context: malformed JSON → deny-all") do
  result = autoexec_run.send(:build_invocation_context, { 'invocation_context_json' => 'broken{' })
  result.is_a?(KairosMcp::InvocationContext) &&
    !result.allowed?("anything")
end

# =========================================================================
# Cleanup
# =========================================================================

FileUtils.rm_rf(TEST_DIR)

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
