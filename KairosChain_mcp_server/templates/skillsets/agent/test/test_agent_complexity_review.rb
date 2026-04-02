#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Complexity-Driven Review Integration
# Tests: M1 (complexity assessment), M2 (persona review), M3 (autonomous loop), M4 (config)
# Usage: ruby test_agent_complexity_review.rb

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

TMPDIR = Dir.mktmpdir('agent_complexity_test')

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

  module Ooda
    COMPLEX_KEYWORDS = /\b(architect|design|refactor|migrat|restructur|integrat|security|auth)/i
  end
end

require File.expand_path('../../../../.kairos/skillsets/autonomos/lib/autonomos/mandate',
  File.dirname(__dir__))

Session = KairosMcp::SkillSets::Agent::Session
AgentStep = KairosMcp::SkillSets::Agent::Tools::AgentStep
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

class MockKnowledgeGet < KairosMcp::Tools::BaseTool
  def name; 'knowledge_get'; end
  def description; 'mock'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    text_content(JSON.generate({ 'name' => arguments['name'], 'content' => 'mock persona content' }))
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
      'plan_hash' => Digest::SHA256.hexdigest(arguments['task_json'])[0..15]
    }))
  end
end

class MockAutoexecRun < KairosMcp::Tools::BaseTool
  def name; 'autoexec_run'; end
  def description; 'mock'; end
  def input_schema; { type: 'object', properties: {} }; end
  def call(arguments)
    text_content(JSON.generate({ 'status' => 'ok', 'outcome' => 'step_complete' }))
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
    'agent_step' => AgentStep.new(nil, registry: registry),
    'agent_status' => KairosMcp::SkillSets::Agent::Tools::AgentStatus.new(nil, registry: registry),
    'agent_stop' => KairosMcp::SkillSets::Agent::Tools::AgentStop.new(nil, registry: registry)
  }
  registry.instance_variable_set(:@tools, tools)
  registry
end

# Helper to get AgentStep instance for testing private methods
def build_step_tool
  registry = build_registry
  registry.instance_variable_get(:@tools)['agent_step']
end

# ---- Decision payload factories ----

def low_complexity_payload
  {
    'summary' => 'Update readme file',
    'task_json' => {
      'task_id' => 'test_001', 'meta' => { 'description' => 'test', 'risk_default' => 'low' },
      'steps' => [
        { 'step_id' => 's1', 'action' => 'edit file', 'tool_name' => 'Edit',
          'tool_arguments' => { 'file_path' => '/tmp/readme.md' }, 'risk' => 'low',
          'depends_on' => [], 'requires_human_cognition' => false }
      ]
    }
  }
end

def medium_complexity_payload
  {
    'summary' => 'Add logging to API handler',
    'task_json' => {
      'task_id' => 'test_002', 'meta' => { 'description' => 'test', 'risk_default' => 'high' },
      'steps' => [
        { 'step_id' => 's1', 'action' => 'modify handler', 'tool_name' => 'Edit',
          'tool_arguments' => { 'file_path' => '/tmp/handler.rb' }, 'risk' => 'high',
          'depends_on' => [], 'requires_human_cognition' => false }
      ]
    }
  }
end

def high_complexity_payload
  {
    'summary' => 'Refactor authentication architecture',
    'task_json' => {
      'task_id' => 'test_003', 'meta' => { 'description' => 'test', 'risk_default' => 'high' },
      'steps' => [
        { 'step_id' => 's1', 'action' => 'modify auth', 'tool_name' => 'Edit',
          'tool_arguments' => { 'file_path' => '/tmp/auth.rb' }, 'risk' => 'high',
          'depends_on' => [], 'requires_human_cognition' => false },
        { 'step_id' => 's2', 'action' => 'update config', 'tool_name' => 'Write',
          'tool_arguments' => { 'file_path' => '/tmp/config.yml' }, 'risk' => 'medium',
          'depends_on' => ['s1'], 'requires_human_cognition' => false }
      ]
    }
  }
end

def l0_change_payload
  {
    'summary' => 'Update skill definitions',
    'task_json' => {
      'task_id' => 'test_004', 'meta' => { 'description' => 'test', 'risk_default' => 'low' },
      'steps' => [
        { 'step_id' => 's1', 'action' => 'evolve skill', 'tool_name' => 'skills_evolve',
          'tool_arguments' => { 'name' => 'test_skill' }, 'risk' => 'low',
          'depends_on' => [], 'requires_human_cognition' => false }
      ]
    }
  }
end

def multi_file_payload
  {
    'summary' => 'Update multiple modules',
    'task_json' => {
      'task_id' => 'test_005', 'meta' => { 'description' => 'test', 'risk_default' => 'low' },
      'steps' => (1..5).map { |i|
        { 'step_id' => "s#{i}", 'action' => 'edit', 'tool_name' => 'Edit',
          'tool_arguments' => { 'file_path' => "/tmp/file#{i}.rb" }, 'risk' => 'low',
          'depends_on' => [], 'requires_human_cognition' => false }
      }
    }
  }
end

def state_mutation_payload
  {
    'summary' => 'Record knowledge update',
    'task_json' => {
      'task_id' => 'test_006', 'meta' => { 'description' => 'test', 'risk_default' => 'low' },
      'steps' => [
        { 'step_id' => 's1', 'action' => 'update knowledge', 'tool_name' => 'knowledge_update',
          'tool_arguments' => { 'name' => 'test' }, 'risk' => 'low',
          'depends_on' => [], 'requires_human_cognition' => false }
      ]
    }
  }
end

# ============================================================
# M1: Complexity Assessment
# ============================================================

section "M1: Complexity Assessment"

step = build_step_tool

assert "test_low_complexity: single low-risk step → level 'low'" do
  result = step.send(:assess_decision_complexity, low_complexity_payload)
  result[:level] == 'low' && result[:signals].empty?
end

assert "test_medium_complexity_risk: one high-risk step → level 'medium'" do
  result = step.send(:assess_decision_complexity, medium_complexity_payload)
  result[:level] == 'medium' && result[:signals] == ['high_risk']
end

assert "test_high_complexity: high_risk + design_scope → level 'high'" do
  result = step.send(:assess_decision_complexity, high_complexity_payload)
  result[:level] == 'high' &&
    result[:signals].include?('high_risk') &&
    result[:signals].include?('design_scope')
end

assert "test_l0_forces_high: single l0_change → level 'high' (not medium)" do
  result = step.send(:assess_decision_complexity, l0_change_payload)
  result[:level] == 'high' && result[:signals] == ['l0_change']
end

assert "test_multi_file_signal: 4+ distinct file paths → 'multi_file' signal" do
  result = step.send(:assess_decision_complexity, multi_file_payload)
  result[:signals].include?('multi_file')
end

assert "test_state_mutation_signal: knowledge_update tool → 'state_mutation' signal" do
  result = step.send(:assess_decision_complexity, state_mutation_payload)
  result[:signals].include?('state_mutation')
end

assert "test_many_steps_signal: >5 steps → 'many_steps' signal" do
  payload = {
    'summary' => 'Big task',
    'task_json' => {
      'task_id' => 'test_007', 'meta' => {},
      'steps' => (1..7).map { |i|
        { 'step_id' => "s#{i}", 'action' => 'do', 'tool_name' => 'Read',
          'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
          'requires_human_cognition' => false }
      }
    }
  }
  result = step.send(:assess_decision_complexity, payload)
  result[:signals].include?('many_steps')
end

assert "test_core_files_signal: kairos lib path → 'core_files' signal" do
  payload = {
    'summary' => 'Fix bug',
    'task_json' => {
      'task_id' => 'test_008', 'meta' => {},
      'steps' => [
        { 'step_id' => 's1', 'action' => 'fix', 'tool_name' => 'Edit',
          'tool_arguments' => { 'file_path' => '/project/kairos_mcp/lib/kairos_mcp/chain.rb' },
          'risk' => 'low', 'depends_on' => [], 'requires_human_cognition' => false }
      ]
    }
  }
  result = step.send(:assess_decision_complexity, payload)
  result[:signals].include?('core_files')
end

assert "test_nil_task_json: missing task_json → low complexity, no crash" do
  payload = { 'summary' => 'nothing' }
  result = step.send(:assess_decision_complexity, payload)
  result[:level] == 'low' && result[:signals].empty?
end

# ---- Merge complexity ----

assert "test_merge_llm_structural: LLM high + structural low → final medium (capped +1)" do
  structural = { level: 'low', signals: [] }
  llm_hint = { 'level' => 'high', 'signals' => ['semantic_complexity'] }
  result = step.send(:merge_complexity, structural, llm_hint)
  result[:level] == 'medium'
end

assert "test_merge_llm_cannot_lower: LLM low + structural high → final high" do
  structural = { level: 'high', signals: ['high_risk', 'design_scope'] }
  llm_hint = { 'level' => 'low', 'signals' => [] }
  result = step.send(:merge_complexity, structural, llm_hint)
  result[:level] == 'high'
end

assert "test_merge_llm_same_level: LLM medium + structural medium → final medium" do
  structural = { level: 'medium', signals: ['high_risk'] }
  llm_hint = { 'level' => 'medium', 'signals' => ['moderate_scope'] }
  result = step.send(:merge_complexity, structural, llm_hint)
  result[:level] == 'medium' && result[:signals].include?('moderate_scope')
end

assert "test_merge_nil_hint: nil LLM hint → structural unchanged" do
  structural = { level: 'medium', signals: ['high_risk'] }
  result = step.send(:merge_complexity, structural, nil)
  result[:level] == 'medium'
end

assert "test_merge_symbol_keys: symbol-key llm_hint works" do
  structural = { level: 'low', signals: [] }
  llm_hint = { level: 'high', signals: ['deep'] }
  result = step.send(:merge_complexity, structural, llm_hint)
  result[:level] == 'medium' && result[:signals].include?('deep')
end

# ============================================================
# M2: Persona Review Parsing
# ============================================================

section "M2: Persona Review Parsing"

assert "test_parse_approve: valid JSON with APPROVE → overall_verdict APPROVE" do
  content = JSON.generate({
    'personas' => { 'pragmatic' => { 'verdict' => 'APPROVE' } },
    'overall_verdict' => 'APPROVE',
    'key_findings' => []
  })
  result = step.send(:parse_persona_review, content)
  result[:overall_verdict] == 'APPROVE'
end

assert "test_parse_revise: REVISE verdict → correctly parsed" do
  content = JSON.generate({
    'personas' => { 'skeptic' => { 'verdict' => 'REVISE', 'concerns' => ['No rollback'] } },
    'overall_verdict' => 'revise',
    'key_findings' => ['No rollback plan']
  })
  result = step.send(:parse_persona_review, content)
  result[:overall_verdict] == 'REVISE' && result[:key_findings] == ['No rollback plan']
end

assert "test_parse_reject: REJECT verdict → correctly parsed" do
  content = JSON.generate({
    'personas' => {},
    'overall_verdict' => 'REJECT',
    'key_findings' => ['Violates layer boundaries']
  })
  result = step.send(:parse_persona_review, content)
  result[:overall_verdict] == 'REJECT'
end

assert "test_parse_json_error: malformed content → fallback REVISE with parse_error" do
  result = step.send(:parse_persona_review, 'not json at all')
  result[:overall_verdict] == 'REVISE' && result[:parse_error] == true
end

assert "test_parse_nil_content: nil → fallback REVISE" do
  result = step.send(:parse_persona_review, nil)
  result[:overall_verdict] == 'REVISE' && result[:parse_error] == true
end

assert "test_parse_missing_verdict: valid JSON but no overall_verdict → fallback REVISE" do
  content = JSON.generate({ 'personas' => {}, 'key_findings' => [] })
  result = step.send(:parse_persona_review, content)
  result[:overall_verdict] == 'REVISE' && result[:parse_error] == true
end

assert "test_parse_non_string_verdict: numeric verdict → fallback REVISE" do
  content = JSON.generate({ 'overall_verdict' => 42, 'key_findings' => [], 'personas' => {} })
  result = step.send(:parse_persona_review, content)
  result[:overall_verdict] == 'REVISE' && result[:parse_error] == true
end

assert "test_parse_code_fenced_json: JSON in code fences → parsed correctly" do
  content = "Here is my review:\n```json\n{\"overall_verdict\": \"APPROVE\", \"key_findings\": [], \"personas\": {}}\n```"
  result = step.send(:parse_persona_review, content)
  result[:overall_verdict] == 'APPROVE'
end

assert "test_parse_bare_json_after_prose: JSON after text (no fences) → parsed" do
  content = "Here is my analysis:\n{\"overall_verdict\": \"REVISE\", \"key_findings\": [\"issue found\"], \"personas\": {}}"
  result = step.send(:parse_persona_review, content)
  result[:overall_verdict] == 'REVISE' && result[:key_findings] == ['issue found']
end

# ---- Lightweight review parsing ----

assert "test_parse_lightweight_concerns: valid JSON → concerns extracted" do
  content = JSON.generate({ 'concerns' => ['edge case missed'], 'suggestions' => ['add test'] })
  result = step.send(:parse_lightweight_review, content)
  result[:concerns] == ['edge case missed']
end

assert "test_parse_lightweight_nil: nil content → empty concerns" do
  result = step.send(:parse_lightweight_review, nil)
  result[:concerns] == []
end

assert "test_parse_lightweight_malformed: bad JSON → empty concerns" do
  result = step.send(:parse_lightweight_review, 'garbage')
  result[:concerns] == []
end

# ============================================================
# M3: review_enabled? and configuration
# ============================================================

section "M3: Configuration"

assert "test_review_enabled_default: no config → true" do
  session = Session.new(
    session_id: 'test_cfg_1', mandate_id: 'test_m', goal_name: 'test',
    invocation_context: KairosMcp::InvocationContext.new, config: {}
  )
  step.send(:review_enabled?, session) == true
end

assert "test_review_disabled: enabled=false → false" do
  session = Session.new(
    session_id: 'test_cfg_2', mandate_id: 'test_m', goal_name: 'test',
    invocation_context: KairosMcp::InvocationContext.new,
    config: { 'complexity_review' => { 'enabled' => false } }
  )
  step.send(:review_enabled?, session) == false
end

assert "test_review_enabled_explicit: enabled=true → true" do
  session = Session.new(
    session_id: 'test_cfg_3', mandate_id: 'test_m', goal_name: 'test',
    invocation_context: KairosMcp::InvocationContext.new,
    config: { 'complexity_review' => { 'enabled' => true } }
  )
  step.send(:review_enabled?, session) == true
end

# ============================================================
# M4: Session review methods
# ============================================================

section "M4: Session review persistence"

assert "test_save_load_review_result: round-trip review result (symbol keys)" do
  session = Session.new(
    session_id: 'test_review_1', mandate_id: 'test_m', goal_name: 'test',
    invocation_context: KairosMcp::InvocationContext.new, config: {}
  )
  review = { overall_verdict: 'APPROVE', key_findings: [], personas: {} }
  session.save_review_result(review)

  loaded = session.load_review_result
  loaded && loaded[:overall_verdict] == 'APPROVE'
end

assert "test_load_review_result_missing: no file → nil" do
  session = Session.new(
    session_id: 'test_review_nonexist', mandate_id: 'test_m', goal_name: 'test',
    invocation_context: KairosMcp::InvocationContext.new, config: {}
  )
  session.load_review_result.nil?
end

assert "test_load_review_result_symbol_keys: round-trip preserves symbol keys" do
  session = Session.new(
    session_id: 'test_review_sym', mandate_id: 'test_m', goal_name: 'test',
    invocation_context: KairosMcp::InvocationContext.new, config: {}
  )
  review = { overall_verdict: 'APPROVE', key_findings: [], personas: {} }
  session.save_review_result(review)
  loaded = session.load_review_result
  loaded && loaded[:overall_verdict] == 'APPROVE'
end

assert "test_save_progress_amendment: appends review concerns to progress" do
  session = Session.new(
    session_id: 'test_amend_1', mandate_id: 'test_m', goal_name: 'test',
    invocation_context: KairosMcp::InvocationContext.new, config: {}
  )
  session.save_progress_amendment(['concern 1', 'concern 2'])
  progress = session.load_progress
  progress.any? { |e| e['type'] == 'review_amendment' && e['concerns'].include?('concern 1') }
end

assert "test_save_progress_amendment_cycle_number: uses current cycle_number" do
  session = Session.new(
    session_id: 'test_amend_cycle', mandate_id: 'test_m', goal_name: 'test',
    invocation_context: KairosMcp::InvocationContext.new, config: {}
  )
  session.increment_cycle  # simulate post-ACT increment → cycle_number = 1
  session.save_progress_amendment(['test concern'])
  progress = session.load_progress
  progress.any? { |e| e['type'] == 'review_amendment' && e['cycle'] == 1 }
end

# ============================================================
# M5: Persona review prompt building
# ============================================================

section "M5: Prompt building"

assert "test_persona_review_prompt_contains_summary: summary in prompt" do
  payload = high_complexity_payload
  complexity = { level: 'high', signals: ['high_risk', 'design_scope'] }
  persona_defs = { 'skeptic' => 'Be critical.' }
  prompt = step.send(:build_persona_review_prompt, payload, complexity, persona_defs)
  prompt.include?('Refactor authentication architecture') && prompt.include?('skeptic')
end

assert "test_lightweight_review_prompt: contains plan summary" do
  payload = medium_complexity_payload
  ar_result = { act: { 'summary' => 'completed' }, reflect: { 'confidence' => 0.8, 'achieved' => ['done'] } }
  prompt = step.send(:build_lightweight_review_prompt, payload, ar_result)
  prompt.include?('Add logging to API handler') && prompt.include?('skeptical')
end

assert "test_multi_llm_review_prompt: L0 review prompt generated" do
  session = Session.new(
    session_id: 'test_mlp_1', mandate_id: 'test_m', goal_name: 'test_goal',
    invocation_context: KairosMcp::InvocationContext.new, config: {}
  )
  prompt = step.send(:generate_multi_llm_review_prompt, session, l0_change_payload)
  prompt.include?('L0 Change Review') && prompt.include?('evolve skill') && prompt.include?('test_goal')
end

# ============================================================
# Summary
# ============================================================

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (total: #{$pass + $fail})"
puts '=' * 60

FileUtils.rm_rf(TMPDIR)
exit($fail > 0 ? 1 : 0)
