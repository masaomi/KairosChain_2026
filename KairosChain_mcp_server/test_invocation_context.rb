#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Phase 0: InvocationContext + BaseTool#invoke_tool
# Usage: ruby test_invocation_context.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'securerandom'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'

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

def assert_raises(description, error_class, &block)
  block.call
  $fail += 1
  puts "  FAIL: #{description} (no exception raised)"
rescue error_class => e
  $pass += 1
  puts "  PASS: #{description} (#{e.class})"
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (expected #{error_class}, got #{e.class}: #{e.message})"
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

# =========================================================================
# 1. InvocationContext unit tests
# =========================================================================

section "InvocationContext basics"

assert("creates with defaults") do
  ctx = KairosMcp::InvocationContext.new
  ctx.depth == 0 && ctx.caller_tool.nil? && ctx.whitelist.nil? && ctx.blacklist.nil?
end

assert("generates root_invocation_id") do
  ctx = KairosMcp::InvocationContext.new
  ctx.root_invocation_id.is_a?(String) && ctx.root_invocation_id.length == 16
end

assert("child increments depth") do
  ctx = KairosMcp::InvocationContext.new
  child = ctx.child(caller_tool: "test_tool")
  child.depth == 1 && child.caller_tool == "test_tool"
end

assert("child preserves root_invocation_id") do
  ctx = KairosMcp::InvocationContext.new
  child = ctx.child(caller_tool: "a")
  grandchild = child.child(caller_tool: "b")
  ctx.root_invocation_id == child.root_invocation_id &&
    child.root_invocation_id == grandchild.root_invocation_id
end

assert("child preserves policy") do
  ctx = KairosMcp::InvocationContext.new(
    whitelist: ["knowledge_*"],
    blacklist: ["agent_*"],
    mandate_id: "mnd_001"
  )
  child = ctx.child(caller_tool: "test")
  child.whitelist == ["knowledge_*"] &&
    child.blacklist == ["agent_*"] &&
    child.mandate_id == "mnd_001"
end

section "InvocationContext depth limit"

assert_raises("raises DepthExceededError at MAX_DEPTH", KairosMcp::InvocationContext::DepthExceededError) do
  ctx = KairosMcp::InvocationContext.new(depth: KairosMcp::InvocationContext::MAX_DEPTH)
  ctx.child(caller_tool: "should_fail")
end

assert("allows depth just under MAX_DEPTH") do
  ctx = KairosMcp::InvocationContext.new(depth: KairosMcp::InvocationContext::MAX_DEPTH - 1)
  child = ctx.child(caller_tool: "ok")
  child.depth == KairosMcp::InvocationContext::MAX_DEPTH
end

section "InvocationContext policy (whitelist/blacklist with fnmatch)"

assert("no policy allows everything") do
  ctx = KairosMcp::InvocationContext.new
  ctx.allowed?("any_tool") && ctx.allowed?("agent_start")
end

assert("blacklist blocks matching tools (exact)") do
  ctx = KairosMcp::InvocationContext.new(blacklist: ["agent_start"])
  !ctx.allowed?("agent_start") && ctx.allowed?("knowledge_list")
end

assert("blacklist supports fnmatch patterns") do
  ctx = KairosMcp::InvocationContext.new(blacklist: ["agent_*"])
  !ctx.allowed?("agent_start") &&
    !ctx.allowed?("agent_step") &&
    ctx.allowed?("knowledge_list")
end

assert("whitelist allows only matching tools") do
  ctx = KairosMcp::InvocationContext.new(whitelist: ["knowledge_*", "context_*"])
  ctx.allowed?("knowledge_list") &&
    ctx.allowed?("context_save") &&
    !ctx.allowed?("chain_status") &&
    !ctx.allowed?("agent_start")
end

assert("blacklist takes priority over whitelist") do
  ctx = KairosMcp::InvocationContext.new(
    whitelist: ["knowledge_*", "skills_evolve"],
    blacklist: ["skills_evolve"]
  )
  ctx.allowed?("knowledge_list") && !ctx.allowed?("skills_evolve")
end

assert("blacklist with wildcards blocks before whitelist check") do
  ctx = KairosMcp::InvocationContext.new(
    whitelist: ["*"],
    blacklist: ["agent_*"]
  )
  !ctx.allowed?("agent_start") && ctx.allowed?("knowledge_list")
end

# =========================================================================
# 2. BaseTool#invoke_tool tests
# =========================================================================

section "BaseTool#invoke_tool"

# Create a simple test tool that records calls
class TestEchoTool < KairosMcp::Tools::BaseTool
  def name; "echo"; end
  def description; "test echo"; end
  def input_schema; { type: "object", properties: {} }; end
  def call(arguments)
    text_content("echo: #{arguments.to_json}")
  end
end

class TestInvokerTool < KairosMcp::Tools::BaseTool
  def name; "invoker"; end
  def description; "invokes other tools"; end
  def input_schema; { type: "object", properties: {} }; end
  def call(arguments)
    target = arguments["target"] || "echo"
    invoke_tool(target, { "from" => "invoker" })
  end
end

# Build a minimal registry for testing
registry = KairosMcp::ToolRegistry.allocate
registry.instance_variable_set(:@safety, KairosMcp::Safety.new)
registry.instance_variable_set(:@tools, {})
KairosMcp::ToolRegistry.clear_gates!

echo = TestEchoTool.new(nil, registry: registry)
invoker = TestInvokerTool.new(nil, registry: registry)
registry.instance_variable_set(:@tools, { "echo" => echo, "invoker" => invoker })

assert("invoke_tool calls target tool through registry") do
  result = invoker.call({ "target" => "echo" })
  result.is_a?(Array) && result[0][:text].include?("echo:")
end

assert("invoke_tool raises without registry") do
  no_reg_tool = TestInvokerTool.new(nil)
  begin
    no_reg_tool.call({ "target" => "echo" })
    false
  rescue RuntimeError => e
    e.message.include?("no registry")
  end
end

assert("invoke_tool raises for non-existent tool") do
  begin
    invoker.invoke_tool("nonexistent", {})
    false
  rescue RuntimeError => e
    e.message.include?("Tool not found")
  end
end

section "BaseTool#invoke_tool with policy"

assert("invoke_tool respects blacklist") do
  ctx = KairosMcp::InvocationContext.new(blacklist: ["echo"])
  begin
    invoker.invoke_tool("echo", {}, context: ctx)
    false
  rescue KairosMcp::InvocationContext::PolicyDeniedError
    true
  end
end

assert("invoke_tool respects whitelist") do
  ctx = KairosMcp::InvocationContext.new(whitelist: ["echo"])
  result = invoker.invoke_tool("echo", { "msg" => "ok" }, context: ctx)
  result.is_a?(Array) && result[0][:text].include?("echo:")
end

assert("invoke_tool blocks tool not in whitelist") do
  ctx = KairosMcp::InvocationContext.new(whitelist: ["other_*"])
  begin
    invoker.invoke_tool("echo", {}, context: ctx)
    false
  rescue KairosMcp::InvocationContext::PolicyDeniedError
    true
  end
end

# =========================================================================
# 3. Depth limit integration test
# =========================================================================

section "Depth limit integration"

# Test depth limit by chaining invoke_tool calls with explicit context
assert("invoke_tool chain stops at MAX_DEPTH") do
  ctx = KairosMcp::InvocationContext.new
  current = ctx
  stopped = false
  (KairosMcp::InvocationContext::MAX_DEPTH + 2).times do |i|
    begin
      current = current.child(caller_tool: "tool_#{i}")
    rescue KairosMcp::InvocationContext::DepthExceededError
      stopped = true
      break
    end
  end
  stopped
end

assert("depth limit fires at exactly MAX_DEPTH") do
  ctx = KairosMcp::InvocationContext.new
  current = ctx
  max_reached = 0
  (KairosMcp::InvocationContext::MAX_DEPTH + 2).times do |i|
    begin
      current = current.child(caller_tool: "t#{i}")
      max_reached = current.depth
    rescue KairosMcp::InvocationContext::DepthExceededError
      break
    end
  end
  max_reached == KairosMcp::InvocationContext::MAX_DEPTH
end

# =========================================================================
# 4. Gate integration test
# =========================================================================

section "Gate integration with invoke_tool"

KairosMcp::ToolRegistry.clear_gates!

gate_log = []
KairosMcp::ToolRegistry.register_gate(:test_gate) do |tool_name, arguments, safety|
  gate_log << tool_name
end

assert("gates fire for invoke_tool calls") do
  gate_log.clear
  invoker.call({ "target" => "echo" })
  gate_log.include?("echo")
end

KairosMcp::ToolRegistry.register_gate(:blocking_gate) do |tool_name, arguments, safety|
  if tool_name == "echo"
    raise KairosMcp::ToolRegistry::GateDeniedError.new("echo", "test", "blocked by gate")
  end
end

assert("gate denial returns error for invoke_tool") do
  result = invoker.call({ "target" => "echo" })
  result.is_a?(Array) && result[0][:text].include?("forbidden")
end

KairosMcp::ToolRegistry.clear_gates!

# =========================================================================
# 5. Backward compatibility test
# =========================================================================

section "Backward compatibility"

assert("BaseTool with no registry: kwarg still works") do
  tool = TestEchoTool.new(nil)
  result = tool.call({ "msg" => "hello" })
  result.is_a?(Array) && result[0][:text].include?("echo:")
end

assert("BaseTool with positional safety only still works") do
  safety = KairosMcp::Safety.new
  tool = TestEchoTool.new(safety)
  tool.instance_variable_get(:@safety) == safety &&
    tool.instance_variable_get(:@registry).nil?
end

assert("ToolRegistry#call_tool still works without invocation_context") do
  result = registry.call_tool("echo", { "test" => true })
  result.is_a?(Array) && result[0][:text].include?("echo:")
end

# =========================================================================
# 6. Registry-side policy enforcement (defense-in-depth)
# =========================================================================

section "Registry-side policy enforcement"

assert("call_tool enforces blacklist when invocation_context provided") do
  ctx = KairosMcp::InvocationContext.new(blacklist: ["echo"])
  result = registry.call_tool("echo", {}, invocation_context: ctx)
  result.is_a?(Array) && result[0][:text].include?("invocation_denied")
end

assert("call_tool allows tool when invocation_context permits") do
  ctx = KairosMcp::InvocationContext.new(whitelist: ["echo"])
  result = registry.call_tool("echo", { "ok" => true }, invocation_context: ctx)
  result.is_a?(Array) && result[0][:text].include?("echo:")
end

assert("call_tool without invocation_context still works (no policy)") do
  result = registry.call_tool("echo", {})
  result.is_a?(Array) && result[0][:text].include?("echo:")
end

# =========================================================================
# 7. Registry mutation protection
# =========================================================================

section "Registry mutation protection"

assert("register is private — cannot be called externally") do
  begin
    registry.register(TestEchoTool.new(nil))
    false
  rescue NoMethodError => e
    e.message.include?("private method")
  end
end

assert("register_if_defined is private") do
  begin
    registry.register_if_defined('KairosMcp::Tools::HelloWorld')
    false
  rescue NoMethodError => e
    e.message.include?("private method")
  end
end

# =========================================================================
# 8. SecureRandom require (regression test)
# =========================================================================

section "SecureRandom require"

assert("InvocationContext can be loaded and constructed independently") do
  ctx = KairosMcp::InvocationContext.new
  ctx.root_invocation_id.is_a?(String) && ctx.root_invocation_id.length == 16
end

# =========================================================================
# 9. Serialization (to_h / from_h / to_json / from_json)
# =========================================================================

section "InvocationContext serialization"

assert("to_h includes policy fields") do
  ctx = KairosMcp::InvocationContext.new(
    whitelist: ["knowledge_*"], blacklist: ["agent_*"],
    mandate_id: "mnd_001", token_budget: 8192
  )
  h = ctx.to_h
  h['whitelist'] == ["knowledge_*"] &&
    h['blacklist'] == ["agent_*"] &&
    h['mandate_id'] == "mnd_001" &&
    h['token_budget'] == 8192
end

assert("to_h does NOT include depth, caller, or root_invocation_id") do
  ctx = KairosMcp::InvocationContext.new(depth: 3, caller_tool: "test")
  h = ctx.to_h
  !h.key?('depth') && !h.key?('caller_tool') && !h.key?('root_invocation_id')
end

assert("from_h reconstructs policy") do
  original = KairosMcp::InvocationContext.new(
    whitelist: ["knowledge_*"], blacklist: ["agent_*"],
    mandate_id: "mnd_001", token_budget: 4096
  )
  restored = KairosMcp::InvocationContext.from_h(original.to_h)
  restored.whitelist == ["knowledge_*"] &&
    restored.blacklist == ["agent_*"] &&
    restored.mandate_id == "mnd_001" &&
    restored.token_budget == 4096
end

assert("from_h starts at depth 0 (fresh context)") do
  restored = KairosMcp::InvocationContext.from_h({ 'whitelist' => ["*"] })
  restored.depth == 0 && restored.caller_tool.nil?
end

assert("from_h returns nil for nil input") do
  KairosMcp::InvocationContext.from_h(nil).nil?
end

assert("roundtrip to_json / from_json preserves policy") do
  ctx = KairosMcp::InvocationContext.new(
    whitelist: ["knowledge_*", "context_*"], blacklist: ["skills_evolve"],
    mandate_id: "mnd_002"
  )
  json = ctx.to_json
  restored = KairosMcp::InvocationContext.from_json(json)
  restored.allowed?("knowledge_list") &&
    !restored.allowed?("skills_evolve") &&
    restored.mandate_id == "mnd_002"
end

assert("restored context enforces same policy as original") do
  ctx = KairosMcp::InvocationContext.new(
    whitelist: ["knowledge_*"], blacklist: ["knowledge_update"]
  )
  restored = KairosMcp::InvocationContext.from_h(ctx.to_h)
  ctx.allowed?("knowledge_list") == restored.allowed?("knowledge_list") &&
    ctx.allowed?("knowledge_update") == restored.allowed?("knowledge_update") &&
    ctx.allowed?("agent_start") == restored.allowed?("agent_start")
end

# =========================================================================
# Summary
# =========================================================================

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
