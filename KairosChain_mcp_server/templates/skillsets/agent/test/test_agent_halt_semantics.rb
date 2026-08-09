#!/usr/bin/env ruby
# frozen_string_literal: true

# D1: a human-cognition halt must be recorded as a halt, not as a failure.
#
# autoexec_run stops at a step carrying requires_human_cognition and returns
# outcome 'internal_execute_halted' plus halted_at / halt_reason / resume_hint.
# The agent driver used to collapse everything not ending in '_complete' to
# 'failed', which drove REFLECT to reason about a failure that never happened
# and let two halts terminate a session on 'error_threshold'.
#
# These probes drive the REAL run_act_via_autoexec and run_act_reflect_internal
# through the registry; only autoexec_run and llm_call are stubbed.
# Usage: ruby test_agent_halt_semantics.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'digest'
require 'time'
require 'securerandom'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'
require_relative '../lib/agent'
require_relative '../tools/agent_start'
require_relative '../tools/agent_step'

$pass = 0
$fail = 0

def assert(description)
  result = yield
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
  puts "\n#{'=' * 60}\nTEST: #{title}\n#{'=' * 60}"
end

TMPDIR = Dir.mktmpdir('agent_halt_test')

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
# The autonomous loop reaches Ooda for goal loading and COMPLEX_KEYWORDS.
require File.expand_path('../../../../.kairos/skillsets/autonomos/lib/autonomos/ooda',
                         File.dirname(__dir__))

Session = KairosMcp::SkillSets::Agent::Session

module Autoexec
  class TaskDsl
    def self.from_json(json_str)
      parsed = JSON.parse(json_str)
      raise ArgumentError, 'Missing task_id' unless parsed['task_id']
      raise ArgumentError, 'Missing steps' unless parsed['steps'].is_a?(Array)

      parsed
    end
  end
end

# ---- Mocks: only the external seams the driver calls ----

class MockLlmCall < KairosMcp::Tools::BaseTool
  @@responses = []
  def self.queue(r) = @@responses << r
  def self.clear! = @@responses.clear
  def name = 'llm_call'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(_arguments)
    resp = @@responses.shift ||
           { 'content' => 'default', 'tool_use' => nil, 'stop_reason' => 'end_turn' }
    text_content(JSON.generate({ 'status' => 'ok', 'provider' => 'mock', 'model' => 'mock-1',
                                 'response' => resp,
                                 'usage' => { 'input_tokens' => 1, 'output_tokens' => 1 },
                                 'snapshot' => { 'model' => 'mock-1',
                                                 'timestamp' => Time.now.iso8601 } }))
  end
end

class MockAutoexecPlan < KairosMcp::Tools::BaseTool
  def name = 'autoexec_plan'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    task_json = JSON.parse(arguments['task_json'])
    text_content(JSON.generate({ 'status' => 'ok',
                                 'task_id' => task_json['task_id'] || 'mock_task',
                                 'plan_hash' => Digest::SHA256.hexdigest(arguments['task_json'])[0..15],
                                 'steps' => task_json['steps']&.length || 0 }))
  end
end

# Returns the exact response shape autoexec_run builds (autoexec_run.rb:248-275).
class MockAutoexecRun < KairosMcp::Tools::BaseTool
  @@result = nil
  def self.set(r) = @@result = r
  def name = 'autoexec_run'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }
  def call(_arguments) = text_content(JSON.generate(@@result))

  # The real halt response for mode=internal_execute.
  def self.halt_response(halted_at: 's3')
    { 'task_id' => 'mock_task', 'mode' => 'internal_execute',
      'outcome' => 'internal_execute_halted',
      'steps_processed' => 2, 'steps_newly_completed' => 2,
      'steps_previously_completed' => 0, 'steps_remaining' => 10,
      'steps' => [], 'halted_at' => halted_at,
      'halt_reason' => 'Human cognitive participation required at this step',
      'resume_hint' => 'Review the step, then re-run with the same parameters to continue' }
  end

  def self.complete_response
    { 'task_id' => 'mock_task', 'mode' => 'internal_execute',
      'outcome' => 'internal_execute_complete', 'steps_processed' => 3, 'steps' => [] }
  end
end

class MockKnowledgeGet < KairosMcp::Tools::BaseTool
  def name = 'knowledge_get'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }
  def call(args) = text_content(JSON.generate({ 'name' => args['name'], 'content' => 'mock' }))
end

def build_registry
  registry = KairosMcp::ToolRegistry.allocate
  registry.instance_variable_set(:@safety, KairosMcp::Safety.new)
  registry.instance_variable_set(:@tools, {})
  KairosMcp::ToolRegistry.clear_gates!
  registry.instance_variable_set(:@tools, {
    'llm_call' => MockLlmCall.new(nil, registry: registry),
    'knowledge_get' => MockKnowledgeGet.new(nil, registry: registry),
    'autoexec_plan' => MockAutoexecPlan.new(nil, registry: registry),
    'autoexec_run' => MockAutoexecRun.new(nil, registry: registry),
    'agent_start' => KairosMcp::SkillSets::Agent::Tools::AgentStart.new(nil, registry: registry),
    'agent_step' => KairosMcp::SkillSets::Agent::Tools::AgentStep.new(nil, registry: registry)
  })
  registry
end

REGISTRY = build_registry
STEP_TOOL = REGISTRY.instance_variable_get(:@tools)['agent_step']

# A plan whose steps route to autoexec (no file tools) and whose third step
# declares it needs a person — the shape that produced the observed halt.
def gated_decision
  JSON.generate({
    'summary' => 'gated plan',
    'task_json' => {
      'task_id' => 'gated_001', 'meta' => { 'description' => 't', 'risk_default' => 'low' },
      'steps' => [
        { 'step_id' => 's1', 'action' => 'read', 'tool_name' => 'knowledge_get',
          'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
          'requires_human_cognition' => false },
        { 'step_id' => 's3', 'action' => 'judge', 'tool_name' => 'knowledge_get',
          'tool_arguments' => {}, 'risk' => 'low', 'depends_on' => [],
          'requires_human_cognition' => true }
      ]
    }
  })
end

def new_proposed_session
  start = REGISTRY.instance_variable_get(:@tools)['agent_start']
  sid = JSON.parse(start.call({ 'goal_name' => "halt_test_#{SecureRandom.hex(3)}" })[0][:text])['session_id']
  MockLlmCall.clear!
  MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue({ 'content' => gated_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })
  sid
end

# REFLECT after a halt realistically returns low confidence (0.15 observed).
def queue_low_confidence_reflect
  MockLlmCall.queue({ 'content' => JSON.generate({ 'confidence' => 0.15, 'achieved' => [],
                                                   'remaining' => ['step 3'] }),
                      'tool_use' => nil, 'stop_reason' => 'end_turn' })
end

section 'D1 unit: run_act_via_autoexec classifies the halt (real method)'

decision = JSON.parse(gated_decision)

# run_act_via_autoexec reads the session for the guard admission blacklist.
sess_u = Session.load(new_proposed_session)

MockAutoexecRun.set(MockAutoexecRun.halt_response)
halt_act = STEP_TOOL.send(:run_act_via_autoexec, sess_u, decision)

assert("a halt is summarised as 'halted', not 'failed'") { halt_act['summary'] == 'halted' }
assert('the halt is flagged for the driver (human_halt)') { halt_act['human_halt'] == true }
assert('halted_at is carried up out of the execution blob') { halt_act['halted_at'] == 's3' }
assert('halt_reason survives to the caller') do
  halt_act['halt_reason'].to_s.include?('Human cognitive participation')
end
assert('resume_hint survives to the caller') do
  halt_act['resume_hint'].to_s.include?('re-run with the same parameters')
end

MockAutoexecRun.set(MockAutoexecRun.complete_response)
ok_act = STEP_TOOL.send(:run_act_via_autoexec, sess_u, decision)
assert("regression: a completed run is still 'completed'") { ok_act['summary'] == 'completed' }
assert('regression: a completed run carries no halt flag') { ok_act['human_halt'].nil? }

MockAutoexecRun.set({ 'task_id' => 'mock_task', 'mode' => 'internal_execute',
                      'outcome' => 'internal_execute_error', 'steps' => [] })
bad_act = STEP_TOOL.send(:run_act_via_autoexec, sess_u, decision)
assert("regression: a genuine failure is still 'failed'") { bad_act['summary'] == 'failed' }

# compute_outcome returns a BARE 'halted' for dry_run / delegated modes
# (autoexec_run.rb:399,403). A fix keyed on the '_halted' suffix would read
# this as a failure; keying on halted_at is mode-independent.
MockAutoexecRun.set({ 'task_id' => 'mock_task', 'mode' => 'delegated', 'outcome' => 'halted',
                      'steps' => [], 'halted_at' => 's3',
                      'halt_reason' => 'Human cognitive participation required at this step' })
bare_act = STEP_TOOL.send(:run_act_via_autoexec, sess_u, decision)
assert("a bare 'halted' outcome (dry_run/delegated shape) is also a halt") do
  bare_act['summary'] == 'halted' && bare_act['human_halt'] == true
end

section 'D1 integration: the halt is recorded as a halt and does not terminate the session'

sid = new_proposed_session
MockAutoexecRun.set(MockAutoexecRun.halt_response)
queue_low_confidence_reflect
r1 = JSON.parse(STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })[0][:text])

assert("the response reports act_summary 'halted'") { r1['act_summary'] == 'halted' }

sess = Session.load(sid)
progress = sess.load_progress
assert("progress records the cycle as 'halted', not 'failed'") do
  progress.last && progress.last['act_summary'] == 'halted'
end

mandate = ::Autonomos::Mandate.load(sess.mandate_id)
assert("the mandate evaluates the halt as 'partial'") do
  mandate[:cycle_history].last[:evaluation] == 'partial'
end
assert('a halt does not increment consecutive_errors (REFLECT said 0.15)') do
  mandate[:consecutive_errors].zero?
end
assert('a halt still consumes a mandate cycle (so max_cycles remains reachable)') do
  mandate[:cycles_completed] == 1
end

# The 2026-08-05 observation: two halts ended the session on 'error_threshold'.
sess.update_state('proposed')
sess.save
MockAutoexecRun.set(MockAutoexecRun.halt_response)
queue_low_confidence_reflect
r2 = JSON.parse(STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })[0][:text])
assert("the second halt is also reported as 'halted'") { r2['act_summary'] == 'halted' }

mandate2 = ::Autonomos::Mandate.load(sess.mandate_id)
assert('two consecutive halts leave consecutive_errors at 0') do
  mandate2[:consecutive_errors].zero?
end
assert("two consecutive halts do NOT trigger 'error_threshold' termination") do
  ::Autonomos::Mandate.check_termination(mandate2) != 'error_threshold'
end

section 'D1 integration: a halt is not a success either'

sid2 = new_proposed_session
sess2 = Session.load(sid2)
MockAutoexecRun.set(MockAutoexecRun.halt_response)
# High confidence + empty remaining would satisfy the early-exit gate; only
# act_succeeded stops a halt from being read as a finished goal.
MockLlmCall.queue({ 'content' => JSON.generate({ 'confidence' => 0.95, 'achieved' => ['all'],
                                                 'remaining' => [] }),
                    'tool_use' => nil, 'stop_reason' => 'end_turn' })
ar = STEP_TOOL.send(:run_act_reflect_internal, sess2)
assert('act_succeeded is false for a halt even at confidence 0.95') do
  ar[:act_succeeded] == false
end
assert('a halt sets no act_error (it must not become a paused_error retry)') do
  ar[:act_error].nil?
end

section 'D1 autonomous: the loop stops for the person the step asked for'

start_tool = REGISTRY.instance_variable_get(:@tools)['agent_start']
auto_sid = JSON.parse(start_tool.call({ 'goal_name' => "halt_auto_#{SecureRandom.hex(3)}",
                                        'autonomous' => true })[0][:text])['session_id']
MockLlmCall.clear!
MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
MockLlmCall.queue({ 'content' => gated_decision, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
queue_low_confidence_reflect
MockAutoexecRun.set(MockAutoexecRun.halt_response)
auto_r = JSON.parse(STEP_TOOL.call({ 'session_id' => auto_sid, 'action' => 'approve' })[0][:text])

# NOTE: status == 'checkpoint' alone does NOT discriminate — Gate 8 (checkpoint
# pause, checkpoint_every=1) returns checkpoint even when the halt is ignored.
# The warning is what proves the loop stopped FOR the halt rather than past it.
assert('the loop checkpoints because of the halt, naming the step it stopped at') do
  auto_r['status'] == 'checkpoint' &&
    auto_r['warning'].to_s.include?('human_cognition_halt') &&
    auto_r['warning'].to_s.include?('s3')
end
assert('the checkpoint carries the resume hint the operator needs') do
  auto_r['warning'].to_s.include?('re-run with the same parameters')
end
assert("the cycle is reported as 'halted', not 'completed'") do
  auto_r.dig('cycle_results', 0, 'act_summary') == 'halted'
end

section 'Regression: a genuine failure still fails'

sid3 = new_proposed_session
sess3 = Session.load(sid3)
MockAutoexecRun.set({ 'task_id' => 'mock_task', 'mode' => 'internal_execute',
                      'outcome' => 'internal_execute_error', 'steps' => [] })
queue_low_confidence_reflect
ar3 = STEP_TOOL.send(:run_act_reflect_internal, sess3)
assert("a non-halt failure is still summarised 'failed'") do
  ar3.dig(:act, 'summary') == 'failed'
end
assert('a genuine failure is not act_succeeded') { ar3[:act_succeeded] == false }
mandate3 = ::Autonomos::Mandate.load(sess3.mandate_id)
assert('a genuine failure still increments consecutive_errors') do
  mandate3[:consecutive_errors] >= 1
end

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60
FileUtils.remove_entry(TMPDIR) if File.directory?(TMPDIR)
exit($fail.zero? ? 0 : 1)
