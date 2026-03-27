#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for M1: Session + MessageFormat + MandateAdapter + agent.yml
# Usage: ruby test_agent_m1.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'kairos_mcp/invocation_context'
require_relative '../lib/agent'

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

Session = KairosMcp::SkillSets::Agent::Session
MF = KairosMcp::SkillSets::Agent::MessageFormat
MA = KairosMcp::SkillSets::Agent::MandateAdapter

# Use a temp dir for storage
TMPDIR = Dir.mktmpdir('agent_test')

# Stub Autonomos.storage_path for testing
module Autonomos
  def self.storage_path(subpath)
    path = File.join(TMPDIR, subpath)
    FileUtils.mkdir_p(path)
    path
  end
end

# =========================================================================
# 1. MessageFormat
# =========================================================================

section "MessageFormat"

assert("assistant_tool_use creates canonical format") do
  tu = { 'id' => 'tu_1', 'name' => 'knowledge_get', 'input' => { 'name' => 'test' } }
  msg = MF.assistant_tool_use(tu)
  msg['role'] == 'assistant' &&
    msg['content'].nil? &&
    msg['tool_calls'].is_a?(Array) &&
    msg['tool_calls'][0]['id'] == 'tu_1' &&
    msg['tool_calls'][0]['name'] == 'knowledge_get'
end

assert("tool_result creates canonical format") do
  msg = MF.tool_result('tu_1', 'result text')
  msg['role'] == 'tool' &&
    msg['tool_use_id'] == 'tu_1' &&
    msg['content'] == 'result text'
end

assert("user_message creates user role") do
  msg = MF.user_message('fix the JSON')
  msg['role'] == 'user' && msg['content'] == 'fix the JSON'
end

# =========================================================================
# 2. Session basics
# =========================================================================

section "Session create"

def make_session(id: 'test_001', mandate: 'mnd_001', goal: 'test_goal')
  ctx = KairosMcp::InvocationContext.new(
    blacklist: %w[agent_* autonomos_*],
    mandate_id: mandate
  )
  config = YAML.safe_load(File.read(
    File.join(__dir__, '..', 'config', 'agent.yml')
  ))
  Session.new(
    session_id: id, mandate_id: mandate, goal_name: goal,
    invocation_context: ctx, config: config
  )
end

assert("creates with correct initial state") do
  s = make_session
  s.session_id == 'test_001' &&
    s.mandate_id == 'mnd_001' &&
    s.goal_name == 'test_goal' &&
    s.state == 'created' &&
    s.cycle_number == 0
end

assert("invocation_context has blacklist") do
  s = make_session
  !s.invocation_context.allowed?('agent_start')
end

# =========================================================================
# 3. Session#phase_config
# =========================================================================

section "Session#phase_config"

assert("returns orient config from YAML") do
  s = make_session
  pc = s.phase_config('orient')
  pc[:max_llm_calls] == 10 && pc[:max_tool_calls] == 20
end

assert("returns decide config with repair attempts") do
  s = make_session
  pc = s.phase_config('decide')
  pc[:max_llm_calls] == 5 && pc[:max_tool_calls] == 0 && pc[:max_repair_attempts] == 3
end

assert("returns decide_prep config") do
  s = make_session
  pc = s.phase_config('decide_prep')
  pc[:max_llm_calls] == 3 && pc[:max_tool_calls] == 5
end

assert("returns reflect config") do
  s = make_session
  pc = s.phase_config('reflect')
  pc[:max_llm_calls] == 3 && pc[:max_tool_calls] == 0
end

assert("returns defaults for unknown phase") do
  s = make_session
  pc = s.phase_config('nonexistent')
  pc[:max_llm_calls] == 10 && pc[:max_tool_calls] == 20 && pc[:max_repair_attempts] == 3
end

# =========================================================================
# 4. Session#record_snapshot
# =========================================================================

section "Session#record_snapshot"

assert("appends snapshot to JSONL file") do
  s = make_session(id: 'snap_test')
  s.record_snapshot({ 'model' => 'test', 'timestamp' => '2026-01-01' })
  s.record_snapshot({ 'model' => 'test', 'timestamp' => '2026-01-02' })
  path = File.join(Autonomos.storage_path("agent_sessions/snap_test"), 'llm_snapshots.jsonl')
  lines = File.readlines(path)
  lines.length == 2 &&
    JSON.parse(lines[0])['timestamp'] == '2026-01-01' &&
    JSON.parse(lines[1])['timestamp'] == '2026-01-02'
end

assert("ignores nil snapshot") do
  s = make_session(id: 'snap_nil')
  s.record_snapshot(nil)
  path = File.join(Autonomos.storage_path("agent_sessions/snap_nil"), 'llm_snapshots.jsonl')
  !File.exist?(path)
end

# =========================================================================
# 5. Session state management
# =========================================================================

section "Session state"

assert("update_state changes state") do
  s = make_session
  s.update_state('observed')
  s.state == 'observed'
end

assert("increment_cycle advances counter") do
  s = make_session
  s.increment_cycle
  s.increment_cycle
  s.cycle_number == 2
end

# =========================================================================
# 6. Session persistence (save/load)
# =========================================================================

section "Session save/load"

assert("roundtrip save and load preserves state") do
  s = make_session(id: 'persist_test')
  s.update_state('proposed')
  s.increment_cycle
  s.save

  loaded = Session.load('persist_test')
  loaded &&
    loaded.session_id == 'persist_test' &&
    loaded.mandate_id == 'mnd_001' &&
    loaded.goal_name == 'test_goal' &&
    loaded.state == 'proposed' &&
    loaded.cycle_number == 1
end

assert("loaded session has fresh invocation context (depth=0)") do
  s = make_session(id: 'ctx_test')
  s.save
  loaded = Session.load('ctx_test')
  loaded.invocation_context.depth == 0
end

assert("loaded session preserves policy") do
  s = make_session(id: 'policy_test')
  s.save
  loaded = Session.load('policy_test')
  !loaded.invocation_context.allowed?('agent_start') &&
    loaded.invocation_context.mandate_id == 'mnd_001'
end

assert("load returns nil for nonexistent session") do
  Session.load('nonexistent_xyz').nil?
end

# =========================================================================
# 7. MandateAdapter
# =========================================================================

section "MandateAdapter"

assert("to_mandate_proposal maps decision_payload correctly") do
  dp = {
    'summary' => 'merge duplicates',
    'task_json' => {
      'steps' => [
        { 'risk' => 'low', 'tool_name' => 'knowledge_get' },
        { 'risk' => 'medium', 'tool_name' => 'knowledge_update' }
      ]
    }
  }
  proposal = MA.to_mandate_proposal(dp)
  proposal[:autoexec_task][:steps].length == 2 &&
    proposal[:autoexec_task][:steps][0][:risk] == 'low' &&
    proposal[:autoexec_task][:steps][1][:risk] == 'medium' &&
    proposal[:selected_gap][:description] == 'merge duplicates'
end

assert("to_mandate_proposal defaults risk to 'low'") do
  dp = { 'summary' => 'test', 'task_json' => { 'steps' => [{ 'tool_name' => 'x' }] } }
  proposal = MA.to_mandate_proposal(dp)
  proposal[:autoexec_task][:steps][0][:risk] == 'low'
end

assert("extract_gap_description uses first gap") do
  orient = { 'gaps' => ['gap A', 'gap B'], 'recommended_action' => 'do C' }
  MA.extract_gap_description(orient) == 'gap A'
end

assert("extract_gap_description falls back to recommended_action") do
  orient = { 'gaps' => [], 'recommended_action' => 'do C' }
  MA.extract_gap_description(orient) == 'do C'
end

assert("extract_gap_description falls back to 'unknown'") do
  MA.extract_gap_description({}) == 'unknown'
end

assert("reflect_to_evaluation maps confidence correctly") do
  MA.reflect_to_evaluation({ 'confidence' => 0.9 }) == 'success' &&
    MA.reflect_to_evaluation({ 'confidence' => 0.7 }) == 'success' &&
    MA.reflect_to_evaluation({ 'confidence' => 0.5 }) == 'partial' &&
    MA.reflect_to_evaluation({ 'confidence' => 0.3 }) == 'partial' &&
    MA.reflect_to_evaluation({ 'confidence' => 0.1 }) == 'failed' &&
    MA.reflect_to_evaluation({ 'confidence' => 0.0 }) == 'unknown' &&
    MA.reflect_to_evaluation({}) == 'unknown'
end

# =========================================================================
# 8. agent.yml validation
# =========================================================================

section "agent.yml config"

assert("agent.yml is valid YAML with expected keys") do
  config = YAML.safe_load(File.read(File.join(__dir__, '..', 'config', 'agent.yml')))
  config.key?('phases') &&
    config.key?('tool_blacklist') &&
    config['phases'].key?('orient') &&
    config['phases'].key?('decide') &&
    config['phases'].key?('reflect') &&
    config['phases'].key?('decide_prep')
end

assert("blacklist includes all required patterns") do
  config = YAML.safe_load(File.read(File.join(__dir__, '..', 'config', 'agent.yml')))
  bl = config['tool_blacklist']
  %w[agent_* autonomos_* skills_evolve skills_rollback skills_promote
     instructions_update token_manage system_upgrade chain_import
     multiuser_* chain_migrate_* chain_export challenge_*
     autoexec_plan autoexec_run].all? { |pat| bl.include?(pat) }
end

# =========================================================================
# Cleanup
# =========================================================================

FileUtils.rm_rf(TMPDIR)

# =========================================================================
# Summary
# =========================================================================

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
