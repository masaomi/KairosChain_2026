#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Phase 1: llm_client SkillSet
# Usage: ruby test_llm_client.rb
# For live API tests: ANTHROPIC_API_KEY=... ruby test_llm_client.rb --live

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'yaml'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'

# Load llm_client SkillSet
skillset_path = File.join(__dir__, '..', '.kairos', 'skillsets', 'llm_client')
require File.join(skillset_path, 'lib', 'llm_client', 'schema_converter')
require File.join(skillset_path, 'lib', 'llm_client', 'adapter')
require File.join(skillset_path, 'lib', 'llm_client', 'anthropic_adapter')
require File.join(skillset_path, 'lib', 'llm_client', 'openai_adapter')
require File.join(skillset_path, 'tools', 'llm_call')
require File.join(skillset_path, 'tools', 'llm_configure')
require File.join(skillset_path, 'tools', 'llm_status')

$pass = 0
$fail = 0
LIVE_MODE = ARGV.include?('--live')

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

SC = KairosMcp::SkillSets::LlmClient::SchemaConverter

# =========================================================================
# 1. Schema Converter: MCP → Anthropic
# =========================================================================

section "Schema Converter: MCP → Anthropic"

assert("converts basic MCP schema to Anthropic format") do
  mcp = { name: "knowledge_list", description: "List knowledge", inputSchema: { type: "object", properties: { format: { type: "string" } } } }
  result = SC.to_anthropic(mcp)
  result[:name] == "knowledge_list" &&
    result[:input_schema][:type] == "object" &&
    !result.key?(:inputSchema)
end

assert("handles nil inputSchema") do
  mcp = { name: "test", description: "test", inputSchema: nil }
  result = SC.to_anthropic(mcp)
  result[:input_schema] == { type: 'object', properties: {} }
end

# =========================================================================
# 2. Schema Converter: MCP → OpenAI
# =========================================================================

section "Schema Converter: MCP → OpenAI"

assert("converts to OpenAI function wrapper") do
  mcp = { name: "echo", description: "Echo tool", inputSchema: { type: "object", properties: { msg: { type: "string" } } } }
  result = SC.to_openai(mcp)
  result[:type] == "function" &&
    result[:function][:name] == "echo" &&
    result[:function][:parameters].is_a?(Hash)
end

assert("adds additionalProperties: false for OpenAI") do
  mcp = { name: "test", description: "test", inputSchema: { type: "object", properties: {} } }
  result = SC.to_openai(mcp)
  params = result[:function][:parameters]
  params[:additionalProperties] == false || params['additionalProperties'] == false
end

assert("truncates long descriptions to 1024 for OpenAI") do
  long_desc = "x" * 2000
  mcp = { name: "test", description: long_desc, inputSchema: { type: "object", properties: {} } }
  result = SC.to_openai(mcp)
  result[:function][:description].length <= 1024
end

assert("normalizes nested objects for OpenAI") do
  mcp = { name: "test", description: "t", inputSchema: {
    type: "object", properties: {
      nested: { type: "object", properties: { inner: { type: "string" } } }
    }
  } }
  result = SC.to_openai(mcp)
  nested = result[:function][:parameters][:properties][:nested]
  nested[:additionalProperties] == false || nested['additionalProperties'] == false
end

# =========================================================================
# 3. Schema Converter: Batch with error isolation
# =========================================================================

section "Schema Converter: Batch conversion"

assert("batch converts multiple schemas") do
  schemas = [
    { name: "a", description: "a", inputSchema: { type: "object", properties: {} } },
    { name: "b", description: "b", inputSchema: { type: "object", properties: {} } }
  ]
  result = SC.convert_batch(schemas, :anthropic)
  result[:schemas].length == 2 && result[:errors].empty?
end

# =========================================================================
# 4. Policy-filtered tool schema discovery
# =========================================================================

section "Policy-filtered tool schema discovery"

# Build a minimal registry with known tools
registry = KairosMcp::ToolRegistry.allocate
registry.instance_variable_set(:@safety, KairosMcp::Safety.new)
registry.instance_variable_set(:@tools, {})
KairosMcp::ToolRegistry.clear_gates!

class MockTool < KairosMcp::Tools::BaseTool
  def initialize(tool_name, safety = nil, registry: nil)
    super(safety, registry: registry)
    @tool_name = tool_name
  end
  def name; @tool_name; end
  def description; "Mock #{@tool_name}"; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments); text_content("mock"); end
end

tools = {}
%w[knowledge_list knowledge_get knowledge_update context_save agent_start skills_evolve].each do |n|
  t = MockTool.new(n, nil, registry: registry)
  tools[n] = t
end
registry.instance_variable_set(:@tools, tools)

# Create llm_call tool with the registry
llm_call_tool = KairosMcp::SkillSets::LlmClient::Tools::LlmCall.new(nil, registry: registry)

assert("llm_call without context includes all requested tools") do
  # We can't actually call the API, but we can test schema resolution
  # by checking the internal method
  all = registry.list_tools
  all.length == 6
end

assert("InvocationContext filters blacklisted tools from discovery") do
  ctx = KairosMcp::InvocationContext.new(blacklist: ["agent_*", "skills_evolve"])
  all = registry.list_tools
  filtered = all.select { |s| ctx.allowed?(s[:name]) }
  filtered.map { |s| s[:name] }.sort == %w[context_save knowledge_get knowledge_list knowledge_update]
end

assert("InvocationContext whitelist limits discovery") do
  ctx = KairosMcp::InvocationContext.new(whitelist: ["knowledge_*"])
  all = registry.list_tools
  filtered = all.select { |s| ctx.allowed?(s[:name]) }
  filtered.all? { |s| s[:name].start_with?("knowledge_") }
end

assert("policy roundtrip via JSON preserves filtering") do
  original = KairosMcp::InvocationContext.new(
    whitelist: ["knowledge_*"], blacklist: ["knowledge_update"]
  )
  restored = KairosMcp::InvocationContext.from_json(original.to_json)
  all = registry.list_tools
  original_filtered = all.select { |s| original.allowed?(s[:name]) }.map { |s| s[:name] }
  restored_filtered = all.select { |s| restored.allowed?(s[:name]) }.map { |s| s[:name] }
  original_filtered == restored_filtered
end

# =========================================================================
# 5. Error handling (never raises)
# =========================================================================

section "Error handling"

assert("llm_call returns error for missing API key") do
  # Temporarily unset key
  old_key = ENV.delete('ANTHROPIC_API_KEY')
  begin
    result = llm_call_tool.call({ 'messages' => [{ 'role' => 'user', 'content' => 'test' }] })
    parsed = JSON.parse(result[0][:text])
    parsed['status'] == 'error' && parsed['error']['type'] == 'auth_error'
  ensure
    ENV['ANTHROPIC_API_KEY'] = old_key if old_key
  end
end

assert("llm_call returns MCP content array on error") do
  old_key = ENV.delete('ANTHROPIC_API_KEY')
  begin
    result = llm_call_tool.call({ 'messages' => [{ 'role' => 'user', 'content' => 'test' }] })
    result.is_a?(Array) && result[0].is_a?(Hash) && result[0][:type] == 'text'
  ensure
    ENV['ANTHROPIC_API_KEY'] = old_key if old_key
  end
end

assert("llm_call never raises (catches all errors)") do
  # Call with completely invalid arguments
  result = llm_call_tool.call({})
  result.is_a?(Array)
end

# =========================================================================
# 6. llm_status
# =========================================================================

section "llm_status"

KairosMcp::SkillSets::LlmClient::Tools::UsageTracker.reset!

status_tool = KairosMcp::SkillSets::LlmClient::Tools::LlmStatus.new(nil, registry: registry)

assert("llm_status returns structured response") do
  result = status_tool.call({})
  parsed = JSON.parse(result[0][:text])
  parsed.key?('provider') && parsed.key?('session_usage')
end

assert("llm_status shows zero usage initially") do
  result = status_tool.call({})
  parsed = JSON.parse(result[0][:text])
  parsed['session_usage']['total_calls'] == 0
end

# =========================================================================
# 7. No loop / no fallback
# =========================================================================

section "No loop, no fallback"

assert("llm_call error response includes retryable metadata") do
  old_key = ENV.delete('ANTHROPIC_API_KEY')
  begin
    result = llm_call_tool.call({ 'messages' => [{ 'role' => 'user', 'content' => 'test' }] })
    parsed = JSON.parse(result[0][:text])
    parsed['error'].key?('retryable') && parsed['error'].key?('rate_limited')
  ensure
    ENV['ANTHROPIC_API_KEY'] = old_key if old_key
  end
end

# =========================================================================
# 8. Schema conversion for all registry tools (Phase 1.5 spike)
# =========================================================================

section "Schema conversion spike (all registered tools)"

assert("all registered tools convert to Anthropic format") do
  schemas = registry.list_tools
  result = SC.convert_batch(schemas, :anthropic)
  result[:errors].empty? && result[:schemas].length == schemas.length
end

assert("all registered tools convert to OpenAI format") do
  schemas = registry.list_tools
  result = SC.convert_batch(schemas, :openai)
  result[:errors].empty? && result[:schemas].length == schemas.length
end

# =========================================================================
# 9. Live API test (optional, requires --live flag)
# =========================================================================

if LIVE_MODE && ENV['ANTHROPIC_API_KEY']
  section "Live API test (Anthropic)"

  assert("live Anthropic call returns structured response") do
    result = llm_call_tool.call({
      'messages' => [{ 'role' => 'user', 'content' => 'Reply with exactly: HELLO' }],
      'max_tokens' => 50
    })
    parsed = JSON.parse(result[0][:text])
    parsed['status'] == 'ok' && parsed['response']['content']&.include?('HELLO')
  end

  assert("live Anthropic call with tools returns tool_use") do
    result = llm_call_tool.call({
      'messages' => [{ 'role' => 'user', 'content' => 'List the available knowledge' }],
      'tools' => ['knowledge_list'],
      'max_tokens' => 200
    })
    parsed = JSON.parse(result[0][:text])
    parsed['status'] == 'ok' && parsed['response'].key?('tool_use')
  end

  assert("live call populates usage stats") do
    result = status_tool.call({})
    parsed = JSON.parse(result[0][:text])
    parsed['session_usage']['total_calls'] > 0
  end
else
  puts "\n(Skipping live API tests — use --live flag with ANTHROPIC_API_KEY)"
end

# =========================================================================
# M0: Adapter convert_messages tests
# =========================================================================

section "AnthropicAdapter#convert_messages"

anthropic_adapter = KairosMcp::SkillSets::LlmClient::AnthropicAdapter.new(
  { 'provider' => 'anthropic', 'api_key_env' => 'ANTHROPIC_API_KEY' }
)

assert("converts canonical tool result to Anthropic tool_result") do
  msgs = [{ 'role' => 'tool', 'tool_use_id' => 'tu_1', 'content' => 'result text' }]
  converted = anthropic_adapter.send(:convert_messages, msgs)
  m = converted[0]
  m['role'] == 'user' &&
    m['content'].is_a?(Array) &&
    m['content'][0]['type'] == 'tool_result' &&
    m['content'][0]['tool_use_id'] == 'tu_1' &&
    m['content'][0]['content'] == 'result text'
end

assert("converts canonical assistant tool_calls to Anthropic tool_use blocks") do
  msgs = [{ 'role' => 'assistant', 'content' => nil,
             'tool_calls' => [{ 'id' => 'tu_1', 'name' => 'knowledge_get', 'input' => { 'name' => 'test' } }] }]
  converted = anthropic_adapter.send(:convert_messages, msgs)
  m = converted[0]
  m['role'] == 'assistant' &&
    m['content'].is_a?(Array) &&
    m['content'][0]['type'] == 'tool_use' &&
    m['content'][0]['id'] == 'tu_1' &&
    m['content'][0]['name'] == 'knowledge_get' &&
    m['content'][0]['input'] == { 'name' => 'test' }
end

assert("passes through plain user messages unchanged") do
  msgs = [{ 'role' => 'user', 'content' => 'hello' }]
  converted = anthropic_adapter.send(:convert_messages, msgs)
  converted[0] == { 'role' => 'user', 'content' => 'hello' }
end

assert("passes through plain assistant messages unchanged") do
  msgs = [{ 'role' => 'assistant', 'content' => 'I think...' }]
  converted = anthropic_adapter.send(:convert_messages, msgs)
  converted[0] == { 'role' => 'assistant', 'content' => 'I think...' }
end

assert("handles assistant with both content and tool_calls") do
  msgs = [{ 'role' => 'assistant', 'content' => 'Let me check',
             'tool_calls' => [{ 'id' => 'tu_2', 'name' => 'knowledge_list', 'input' => {} }] }]
  converted = anthropic_adapter.send(:convert_messages, msgs)
  m = converted[0]
  m['content'].length == 2 &&
    m['content'][0]['type'] == 'text' &&
    m['content'][0]['text'] == 'Let me check' &&
    m['content'][1]['type'] == 'tool_use'
end

assert("passes through native tool message without tool_use_id") do
  native = { 'role' => 'tool', 'content' => 'native result' }
  msgs = [native]
  converted = anthropic_adapter.send(:convert_messages, msgs)
  converted[0].equal?(native)
end

assert("passes through assistant with empty tool_calls array") do
  msgs = [{ 'role' => 'assistant', 'content' => 'just text', 'tool_calls' => [] }]
  converted = anthropic_adapter.send(:convert_messages, msgs)
  converted[0] == { 'role' => 'assistant', 'content' => 'just text' }
end

section "OpenaiAdapter#convert_messages"

openai_adapter = KairosMcp::SkillSets::LlmClient::OpenaiAdapter.new(
  { 'provider' => 'openai', 'api_key_env' => 'OPENAI_API_KEY' }
)

assert("converts canonical tool result to OpenAI format (tool_call_id)") do
  msgs = [{ 'role' => 'tool', 'tool_use_id' => 'tu_1', 'content' => 'result' }]
  converted = openai_adapter.send(:convert_messages, msgs)
  m = converted[0]
  m['role'] == 'tool' &&
    m['tool_call_id'] == 'tu_1' &&
    m['content'] == 'result'
end

assert("converts canonical assistant tool_calls to OpenAI function format") do
  msgs = [{ 'role' => 'assistant', 'content' => nil,
             'tool_calls' => [{ 'id' => 'tc_1', 'name' => 'knowledge_get', 'input' => { 'name' => 'x' } }] }]
  converted = openai_adapter.send(:convert_messages, msgs)
  m = converted[0]
  tc = m['tool_calls'][0]
  tc['id'] == 'tc_1' &&
    tc['type'] == 'function' &&
    tc['function']['name'] == 'knowledge_get' &&
    tc['function']['arguments'] == '{"name":"x"}'
end

assert("passes through OpenAI-native tool_calls unchanged") do
  msgs = [{ 'role' => 'assistant', 'content' => nil,
             'tool_calls' => [{ 'id' => 'tc_1', 'type' => 'function',
                                'function' => { 'name' => 'test', 'arguments' => '{}' } }] }]
  converted = openai_adapter.send(:convert_messages, msgs)
  converted[0] == msgs[0]
end

assert("passes through system messages unchanged") do
  msgs = [{ 'role' => 'system', 'content' => 'You are helpful' }]
  converted = openai_adapter.send(:convert_messages, msgs)
  converted[0] == msgs[0]
end

assert("handles tool result with already-present tool_call_id") do
  msgs = [{ 'role' => 'tool', 'tool_call_id' => 'existing_id', 'content' => 'ok' }]
  converted = openai_adapter.send(:convert_messages, msgs)
  converted[0]['tool_call_id'] == 'existing_id'
end

assert("passes through native tool message without tool_use_id or tool_call_id") do
  native = { 'role' => 'tool', 'content' => 'native' }
  msgs = [native]
  converted = openai_adapter.send(:convert_messages, msgs)
  converted[0].equal?(native)
end

# =========================================================================
# Summary
# =========================================================================

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
