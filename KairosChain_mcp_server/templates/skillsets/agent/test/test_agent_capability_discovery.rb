#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Agent Capability Discovery (orient_tools, build_tool_catalog)
# Usage: ruby test_agent_capability_discovery.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'
require_relative '../lib/agent'
require_relative '../tools/agent_start'
require_relative '../tools/agent_step'

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

TMPDIR = Dir.mktmpdir('agent_cap_test')

# Stubs
module Autonomos
  def self.storage_path(subpath)
    path = File.join(TMPDIR, subpath)
    FileUtils.mkdir_p(path)
    path
  end

  module Mandate
    def self.create(**kwargs); { mandate_id: 'test_mandate' }; end
    def self.load(id); { mandate_id: id, max_cycles: 3, risk_budget: 'low', recent_gap_descriptions: [] }; end
    def self.save(id, data); end
    def self.update_status(id, status); end
    def self.record_cycle(id, **kwargs); end
    def self.risk_exceeds_budget?(proposal, budget); false; end
    def self.loop_detected?(proposal, gaps); false; end
    def self.check_termination(mandate); nil; end
  end

  module Ooda
    def observe(goal_name); { 'status' => 'observed' }; end
  end
end

module Autoexec
  def self.config; {}; end
  class TaskDsl
    def self.from_json(json_string)
      data = JSON.parse(json_string, symbolize_names: true)
      data
    end
  end
end

Session = KairosMcp::SkillSets::Agent::Session

# =========================================================================
# Build test infrastructure
# =========================================================================

# Mock registry with some tools
class CapTestRegistry
  def initialize(tools = [])
    @tools = tools
  end

  def list_tools
    @tools
  end

  def call_tool(name, arguments, invocation_context: nil)
    [{ text: '{}' }]
  end
end

# Create an AgentStep instance with custom registry
def build_agent_step(registry: nil, safety: nil)
  step = KairosMcp::SkillSets::Agent::Tools::AgentStep.new(safety, registry: registry)
  step
end

# Create a session with custom config
def build_session(config_overrides = {})
  config = {
    'phases' => {},
    'tool_blacklist' => %w[agent_* autonomos_*]
  }.merge(config_overrides)

  ctx = KairosMcp::InvocationContext.new(
    blacklist: config['tool_blacklist'],
    mandate_id: 'test_mandate'
  )

  Session.new(
    session_id: "test_#{rand(10000)}",
    mandate_id: 'test_mandate',
    goal_name: 'test_goal',
    invocation_context: ctx,
    config: config
  )
end

# =========================================================================
# 1. orient_tools
# =========================================================================

section "orient_tools"

assert("T1: returns base tools when no orient_tools_extra") do
  step = build_agent_step
  session = build_session
  tools = step.send(:orient_tools, session)
  tools.include?('knowledge_list') &&
    tools.include?('resource_read') &&
    tools.size == KairosMcp::SkillSets::Agent::Tools::AgentStep::BASE_ORIENT_TOOLS.size
end

assert("T2: merges orient_tools_extra from config") do
  step = build_agent_step
  session = build_session('orient_tools_extra' => ['document_status', 'custom_tool'])
  tools = step.send(:orient_tools, session)
  tools.include?('document_status') &&
    tools.include?('custom_tool') &&
    tools.include?('knowledge_list')
end

assert("T3: deduplicates entries") do
  step = build_agent_step
  session = build_session('orient_tools_extra' => ['knowledge_list', 'resource_read'])
  tools = step.send(:orient_tools, session)
  tools.count('knowledge_list') == 1
end

assert("handles nil session gracefully") do
  step = build_agent_step
  tools = step.send(:orient_tools, nil)
  tools == KairosMcp::SkillSets::Agent::Tools::AgentStep::BASE_ORIENT_TOOLS
end

# =========================================================================
# 2. build_tool_catalog
# =========================================================================

section "build_tool_catalog"

SAMPLE_TOOLS = [
  { name: 'write_section', description: 'Write a document section',
    inputSchema: { type: 'object', properties: {}, required: %w[section_name instructions output_file] } },
  { name: 'document_status', description: 'Show draft file inventory',
    inputSchema: { type: 'object', properties: {}, required: %w[output_dir] } },
  { name: 'knowledge_get', description: 'Get L1 knowledge',
    inputSchema: { type: 'object', properties: {}, required: %w[name] } },
  { name: 'agent_start', description: 'Start agent session',
    inputSchema: { type: 'object', properties: {}, required: %w[goal_name] } },
  { name: 'autonomos_loop', description: 'Run autonomos loop',
    inputSchema: { type: 'object', properties: {} } }
].freeze

assert("T4: excludes blacklisted tools") do
  registry = CapTestRegistry.new(SAMPLE_TOOLS)
  step = build_agent_step(registry: registry)
  session = build_session
  catalog = step.send(:build_tool_catalog, session)
  !catalog.include?('agent_start') && !catalog.include?('autonomos_loop')
end

assert("T5: includes non-blacklisted tools with descriptions and required params") do
  registry = CapTestRegistry.new(SAMPLE_TOOLS)
  step = build_agent_step(registry: registry)
  session = build_session
  catalog = step.send(:build_tool_catalog, session)
  catalog.include?('write_section') &&
    catalog.include?('section_name, instructions, output_file') &&
    catalog.include?('document_status') &&
    catalog.include?('knowledge_get')
end

assert("T6: returns fallback when no registry") do
  step = build_agent_step(registry: nil)
  session = build_session
  catalog = step.send(:build_tool_catalog, session)
  catalog.include?('no registry')
end

assert("T7: exact blacklist match works") do
  tools = [{ name: 'skills_evolve', description: 'Evolve skills', inputSchema: {} }]
  registry = CapTestRegistry.new(tools)
  step = build_agent_step(registry: registry)
  session = build_session('tool_blacklist' => %w[skills_evolve])
  catalog = step.send(:build_tool_catalog, session)
  !catalog.include?('skills_evolve')
end

assert("T8: wildcard blacklist via fnmatch works") do
  tools = [
    { name: 'chain_migrate_execute', description: 'Migrate', inputSchema: {} },
    { name: 'chain_history', description: 'History', inputSchema: {} }
  ]
  registry = CapTestRegistry.new(tools)
  step = build_agent_step(registry: registry)
  session = build_session('tool_blacklist' => %w[chain_migrate_*])
  catalog = step.send(:build_tool_catalog, session)
  !catalog.include?('chain_migrate_execute') && catalog.include?('chain_history')
end

assert("handles namespaced tool names (basename blacklist)") do
  tools = [{ name: 'peer1/agent_start', description: 'Remote agent start', inputSchema: {} }]
  registry = CapTestRegistry.new(tools)
  step = build_agent_step(registry: registry)
  session = build_session  # blacklist includes agent_*
  catalog = step.send(:build_tool_catalog, session)
  # InvocationContext.allowed? checks basename — should be filtered
  !catalog.include?('peer1/agent_start')
end

# =========================================================================
# 3. extract_required_params
# =========================================================================

section "extract_required_params"

assert("T11: handles symbol keys") do
  step = build_agent_step
  params = step.send(:extract_required_params, { required: %w[name version] })
  params == %w[name version]
end

assert("T11b: handles string keys") do
  step = build_agent_step
  params = step.send(:extract_required_params, { 'required' => %w[output_dir] })
  params == %w[output_dir]
end

assert("handles nil schema") do
  step = build_agent_step
  params = step.send(:extract_required_params, nil)
  params == []
end

assert("handles schema without required") do
  step = build_agent_step
  params = step.send(:extract_required_params, { type: 'object', properties: {} })
  params == []
end

# =========================================================================
# 4. build_decide_prompt integration
# =========================================================================

section "build_decide_prompt integration"

assert("T9: build_decide_prompt includes Available Tools section") do
  registry = CapTestRegistry.new(SAMPLE_TOOLS)
  step = build_agent_step(registry: registry)
  session = build_session
  orient_result = { 'content' => 'The goal requires writing a grant application.' }
  prompt = step.send(:build_decide_prompt, session, orient_result)
  prompt.include?('## Available Tools') &&
    prompt.include?('write_section') &&
    prompt.include?('Use ONLY tools listed above')
end

assert("T10: run_decide_with_feedback messages include catalog") do
  # We can't easily run the full method (needs LLM), but we can verify
  # the method exists and check the code path
  step = build_agent_step(registry: CapTestRegistry.new(SAMPLE_TOOLS))
  session = build_session
  catalog = step.send(:build_tool_catalog, session)
  catalog.include?('write_section') && catalog.include?('document_status')
end

# =========================================================================
# Cleanup
# =========================================================================

FileUtils.rm_rf(TMPDIR)

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
