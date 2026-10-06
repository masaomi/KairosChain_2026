#!/usr/bin/env ruby
# frozen_string_literal: true

# The guard verdict reaches the record, and what is reported follows it.
#
# Field observation (guarded trial on another instance, gem 3.88.0, 2026-10-06):
# the guard FAILed an act that produced no file, but the chain held only
# autoexec's "internal_execute_complete", progress said "completed", and the
# FAIL survived only in the mutable advance_log.jsonl.
#
# These probes drive the REAL agent_start / agent_step and the REAL
# chain_record tool through the registry, with the REAL TaskDsl, Verdict and
# Confinement. Stubbed: llm_call, autoexec_plan/run, knowledge_get, the merge
# target directory, the storage underneath chain_record (never the real
# chain), and agent_execute.
#
# agent_execute is injected into the registry here. In a real server it is not
# registered (skillset.json tool_classes does not list it), so the confined
# route is not reachable yet; wiring it is separate work. The confined probes
# below test the driver's verdict/record/merge ordering, not that route.
# Usage: ruby test_agent_guard_verdict_record.rb

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
require 'kairos_mcp/tools/chain_record'
require 'kairos_mcp/tool_registry'
require_relative '../lib/agent'
require_relative '../tools/agent_start'
require_relative '../tools/agent_step'
require File.expand_path('../autoexec/lib/autoexec/task_dsl', File.dirname(__dir__))
# TaskDsl.validate reads Autoexec.config (normally provided by autoexec.rb).
module Autoexec
  def self.config = {} unless respond_to?(:config)
end

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

TMPDIR = Dir.mktmpdir('agent_guard_record_test')
PROJECT_ROOT = File.join(TMPDIR, 'project')
FileUtils.mkdir_p(File.join(PROJECT_ROOT, '.kairos'))

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

require File.expand_path('../autonomos/lib/autonomos/mandate', File.dirname(__dir__))
require File.expand_path('../autonomos/lib/autonomos/ooda', File.dirname(__dir__))

Session = KairosMcp::SkillSets::Agent::Session
Verdict = KairosMcp::SkillSets::Agent::Verdict
Confinement = KairosMcp::SkillSets::Agent::Confinement

# The storage under the real chain_record tool. Chain.new must never reach the
# real chain: the prepended initialize does not call super.
module FakeChainStore
  class << self
    attr_accessor :blocks, :raise_with, :on_add
  end
  self.blocks = []
end
KairosMcp::KairosChain::Chain.prepend(Module.new do
  def initialize(*); end

  def add_block(logs)
    raise FakeChainStore.raise_with if FakeChainStore.raise_with

    FakeChainStore.on_add&.call(logs)
    FakeChainStore.blocks << logs
    Struct.new(:index, :hash).new(200 + FakeChainStore.blocks.size, 'cd' * 32)
  end
end)

# The shipped agent.yml has the guard off; these probes need it on.
GUARD_ON = Module.new do
  def load_config
    super.merge('guard' => { 'enabled' => true, 'admission' => { 'extra_denied_tools' => [] } })
  end
end
KairosMcp::SkillSets::Agent::Tools::AgentStart.prepend(GUARD_ON)

# ---- Mocks: only the external seams the driver calls ----

class MockLlmCall < KairosMcp::Tools::BaseTool
  @@responses = []
  @@seen = []
  def self.queue(r) = @@responses << r
  def self.seen = @@seen

  def self.clear!
    @@responses.clear
    @@seen.clear
  end

  def name = 'llm_call'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    @@seen << JSON.generate(arguments)
    resp = @@responses.shift ||
           { 'content' => 'default', 'tool_use' => nil, 'stop_reason' => 'end_turn' }
    text_content(JSON.generate({ 'status' => 'ok', 'provider' => 'mock', 'model' => 'mock-1',
                                 'response' => resp,
                                 'usage' => { 'input_tokens' => 1, 'output_tokens' => 1 },
                                 'snapshot' => { 'model' => 'mock-1', 'timestamp' => Time.now.iso8601 } }))
  end
end

class MockAutoexecPlan < KairosMcp::Tools::BaseTool
  def name = 'autoexec_plan'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    task_json = JSON.parse(arguments['task_json'])
    text_content(JSON.generate({ 'status' => 'ok', 'task_id' => task_json['task_id'],
                                 'plan_hash' => Digest::SHA256.hexdigest(arguments['task_json'])[0..15],
                                 'steps' => task_json['steps']&.length || 0 }))
  end
end

# autoexec reports the run complete — exactly what it told the chain in the field.
class MockAutoexecRun < KairosMcp::Tools::BaseTool
  def name = 'autoexec_run'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(_arguments)
    text_content(JSON.generate({ 'task_id' => 'mock_task', 'mode' => 'internal_execute',
                                 'outcome' => 'internal_execute_complete',
                                 'steps_processed' => 1, 'steps' => [] }))
  end
end

# Stands in for the confined executor: writes into its own scratch area and
# returns the driver-visible evidence the real tool returns.
class MockAgentExecute < KairosMcp::Tools::BaseTool
  @@content = "implementation e9d9ef1\nanalysis fe66272\n"
  def name = 'agent_execute'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(_arguments)
    scratch = Dir.mktmpdir('agent_act_', TMPDIR)
    FileUtils.mkdir_p(File.join(scratch, 'out'))
    File.write(File.join(scratch, 'out', 'note.md'), @@content)
    text_content(JSON.generate({ 'status' => 'ok', 'result' => 'done',
                                 'scratch_dir' => scratch,
                                 'manifest' => Confinement.manifest(scratch),
                                 'files_modified' => [], 'tool_calls_count' => 1 }))
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
  KairosMcp::ToolRegistry.clear_gates!
  registry.instance_variable_set(:@tools, {
    'llm_call' => MockLlmCall.new(nil, registry: registry),
    'knowledge_get' => MockKnowledgeGet.new(nil, registry: registry),
    'autoexec_plan' => MockAutoexecPlan.new(nil, registry: registry),
    'autoexec_run' => MockAutoexecRun.new(nil, registry: registry),
    'agent_execute' => MockAgentExecute.new(nil, registry: registry),
    'chain_record' => KairosMcp::Tools::ChainRecord.new(nil, registry: registry),
    'agent_start' => KairosMcp::SkillSets::Agent::Tools::AgentStart.new(nil, registry: registry),
    'agent_step' => KairosMcp::SkillSets::Agent::Tools::AgentStep.new(nil, registry: registry)
  })
  registry
end

REGISTRY = build_registry
START_TOOL = REGISTRY.instance_variable_get(:@tools)['agent_start']
STEP_TOOL = REGISTRY.instance_variable_get(:@tools)['agent_step']
# A PASS merges into the live tree; point that at a scratch project, never the repo.
STEP_TOOL.define_singleton_method(:project_root_for_merge) { PROJECT_ROOT }
MERGED = File.join(PROJECT_ROOT, 'out', 'note.md')

ACCEPTANCE = {
  'acceptance' => [
    { 'type' => 'file_exists', 'path' => 'out/note.md' },
    { 'type' => 'file_contains', 'path' => 'out/note.md', 'substring' => 'e9d9ef1' },
    { 'type' => 'file_contains', 'path' => 'out/note.md', 'substring' => 'fe66272' },
    { 'type' => 'manifest_not_empty' },
    { 'type' => 'execution_completed' }
  ],
  'layer_surface' => []
}.freeze

def decision(tool_name, args)
  JSON.generate({
    'summary' => "plan via #{tool_name}",
    'task_json' => {
      'task_id' => "t_#{SecureRandom.hex(3)}", 'meta' => { 'description' => 't', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'produce the note', 'tool_name' => tool_name,
                    'tool_arguments' => args, 'risk' => 'low', 'depends_on' => [],
                    'requires_human_cognition' => false }]
    },
    'review_hint' => { 'needed' => false, 'reason' => nil, 'urgency' => nil },
    'complexity_hint' => { 'level' => 'low', 'signals' => [] }
  })
end

REPORT_PLAN = decision('operator_report', { 'title' => 'Guard trial', 'body' => 'e9d9ef1 fe66272' })
WRITE_PLAN = decision('file_write', { 'file_path' => 'out/note.md',
                                      'content' => "implementation e9d9ef1\nanalysis fe66272\n" })

def reset_chain!
  FakeChainStore.blocks = []
  FakeChainStore.raise_with = nil
  FakeChainStore.on_add = nil
end

def start_proposed(plan)
  sid = JSON.parse(START_TOOL.call({ 'goal_name' => "guard_record_#{SecureRandom.hex(3)}",
                                     'guard' => ACCEPTANCE })[0][:text])['session_id']
  MockLlmCall.clear!
  MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue({ 'content' => plan, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  r = JSON.parse(STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })[0][:text])
  [sid, r]
end

def act(sid)
  MockLlmCall.queue({ 'content' => JSON.generate({ 'confidence' => 0.9, 'achieved' => ['done'],
                                                   'remaining' => [] }),
                      'tool_use' => nil, 'stop_reason' => 'end_turn' })
  JSON.parse(STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })[0][:text])
end

def verdict_records
  FakeChainStore.blocks.flatten.map { |l| JSON.parse(l) }.select { |r| r['kind'] == 'agent_guard_verdict' }
end

# ------------------------------------------------------------------

section 'Field case reproduced: in-process act, no file, guard FAIL'

reset_chain!
sid5, proposed5 = start_proposed(REPORT_PLAN)
assert('DECIDE produced a proposal') { proposed5['state'] == 'proposed' }
r5 = act(sid5)
pinned_sha = File.read(File.join(Session.load(sid5).guard_dir, Verdict::SHA_FILE)).strip
rec5 = verdict_records.last

assert('the FAIL verdict is written to the chain through the real chain_record') do
  rec5 && rec5['verdict'] == Verdict::FAIL
end
assert('the chain record carries the pinned spec hash') { rec5 && rec5['spec_sha256'] == pinned_sha }
assert('the chain record names the failed checks') do
  rec5 && rec5['failed_checks'].map { |c| c['type'] }.sort ==
    %w[file_contains file_contains file_exists manifest_not_empty]
end
assert('the chain record names the planned route as in_process') { rec5 && rec5['planned_route'] == 'in_process' }
assert("the response reports 'failed', not 'completed'") { r5['act_summary'] == 'failed' }
assert('the response shows the verdict and its failed checks') do
  r5.dig('guard', 'verdict') == Verdict::FAIL && r5.dig('guard', 'failed_checks').include?('file_exists')
end
assert('REFLECT was shown the verdict, not only the executor\'s "completed"') do
  MockLlmCall.seen.last.include?('guard_verdict_summary') && MockLlmCall.seen.last.include?(Verdict::FAIL)
end

prog5 = Session.load(sid5).load_progress.last
assert("progress records 'failed', not 'completed'") { prog5['act_summary'] == 'failed' }
assert('the progress guard_record carries the verdict') { prog5.dig('guard_record', 'verdict') == Verdict::FAIL }
assert('the progress guard_record says the verdict was recorded, and where') do
  prog5.dig('guard_record', 'verdict_recorded') == true &&
    prog5.dig('guard_record', 'verdict_chain_block', 'index').is_a?(Integer)
end
assert('the next cycle is told the previous cycle failed') do
  STEP_TOOL.send(:build_agent_execute_context, Session.load(sid5)).include?('Cycle 1: failed')
end

section 'Confined PASS: the verdict is recorded first, then the file is merged'

reset_chain!
FileUtils.rm_rf(File.join(PROJECT_ROOT, 'out'))
merged_at_record_time = nil
FakeChainStore.on_add = ->(_logs) { merged_at_record_time = File.exist?(MERGED) }
sid6, = start_proposed(WRITE_PLAN)
r6 = act(sid6)
rec6 = verdict_records.last
assert('the PASS verdict is written to the chain') { rec6 && rec6['verdict'] == Verdict::PASS }
assert('the chain record names the planned route as confined') { rec6 && rec6['planned_route'] == 'confined' }
assert('nothing had been merged when the verdict was recorded') { merged_at_record_time == false }
assert('the file reached the project tree after the record') { File.read(MERGED).include?('fe66272') }
assert("the response reports 'completed' with a PASS verdict") do
  r6['act_summary'] == 'completed' && r6.dig('guard', 'verdict') == Verdict::PASS
end

section 'A PASS the chain does not take: halt for the operator, nothing merged'

reset_chain!
FileUtils.rm_rf(File.join(PROJECT_ROOT, 'out'))
sid7, = start_proposed(WRITE_PLAN)
FakeChainStore.raise_with = RuntimeError.new('storage unavailable')
r7 = act(sid7)
FakeChainStore.raise_with = nil
assert('nothing was merged into the project tree') { !File.exist?(MERGED) }
assert('the response is a guard halt, not success and not a plain failure') { r7['status'] == 'guard_halt' }
assert('the response says the verdict was not recorded') { r7['verdict_recorded'] == false }
assert('the halt reason names the lost verdict, the cause, and that results stay quarantined') do
  reason = r7['guard_reason'].to_s
  reason.include?("verdict #{Verdict::PASS} (") && reason.include?('RuntimeError: storage unavailable') &&
    reason.include?('quarantined')
end
prog7 = Session.load(sid7).load_progress.last
assert('progress records the halt, that the verdict was not recorded, and which verdict was lost') do
  prog7['act_summary'].start_with?('guard halt') && prog7.dig('guard_record', 'verdict_recorded') == false &&
    prog7.dig('guard_record', 'lost_verdict') == Verdict::PASS
end

section 'A FAIL the chain does not take also halts (it must not cycle on silently)'

reset_chain!
sid9, = start_proposed(REPORT_PLAN)
FakeChainStore.raise_with = RuntimeError.new('storage unavailable')
r9 = act(sid9)
FakeChainStore.raise_with = nil
assert('the response is a guard halt') { r9['status'] == 'guard_halt' && r9['verdict_recorded'] == false }
assert('the halt reason names the lost FAIL and that the in-process act already took effect') do
  r9['guard_reason'].to_s.include?("verdict #{Verdict::FAIL} (") && r9['guard_reason'].to_s.include?('already took effect')
end

section 'Guard HALT before ACT (tampered spec) is recorded and reported as a halt'

reset_chain!
sid8, = start_proposed(REPORT_PLAN)
File.write(File.join(Session.load(sid8).guard_dir, Verdict::SPEC_FILE), '{"acceptance":[],"layer_surface":[]}')
r8 = act(sid8)
rec8 = verdict_records.last
assert('the HALT verdict is written to the chain') { rec8 && rec8['verdict'] == Verdict::HALT }
assert('the response is a guard halt, not a completion') { r8['status'] == 'guard_halt' && r8['verdict_recorded'] == true }

section 'Pre-ACT HALT whose record fails: the diagnostic names both problems'

reset_chain!
sid10, = start_proposed(REPORT_PLAN)
File.write(File.join(Session.load(sid10).guard_dir, Verdict::SPEC_FILE), '{"acceptance":[],"layer_surface":[]}')
FakeChainStore.raise_with = RuntimeError.new('storage unavailable')
r10 = act(sid10)
FakeChainStore.raise_with = nil
assert('the response is a guard halt with the verdict not recorded') do
  r10['status'] == 'guard_halt' && r10['verdict_recorded'] == false
end
assert('the reason keeps the original tamper reason and adds the record failure') do
  r10['guard_reason'].to_s.include?('tamper') && r10['guard_reason'].to_s.include?('storage unavailable') &&
    r10['guard_reason'].to_s.include?('did not run')
end

section 'Manual risk-resume path: a guard halt is reported as a halt, not as ok'

reset_chain!
risky = decision('knowledge_update', { 'name' => 'x', 'content' => 'y' })
sid11, = start_proposed(risky)
paused = act(sid11)
assert('a medium-risk plan under a low budget pauses first') { paused['state'] == 'paused_risk' }
# The operator raises the budget, as the pause response asks, then resumes.
m11 = ::Autonomos::Mandate.load(Session.load(sid11).mandate_id)
m11[:risk_budget] = 'medium'
::Autonomos::Mandate.save(m11[:mandate_id], m11)
FakeChainStore.raise_with = RuntimeError.new('storage unavailable')
MockLlmCall.queue({ 'content' => '{"confidence":0.9}', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
r11 = JSON.parse(STEP_TOOL.call({ 'session_id' => sid11, 'action' => 'approve' })[0][:text])
FakeChainStore.raise_with = nil
assert('resuming from the risk pause reports guard_halt with the verdict not recorded') do
  r11['status'] == 'guard_halt' && r11['verdict_recorded'] == false
end

section 'Autonomous loop: a guard halt carries its reason and the record state'

reset_chain!
sid12 = JSON.parse(START_TOOL.call({ 'goal_name' => "guard_auto_#{SecureRandom.hex(3)}", 'guard' => ACCEPTANCE,
                                     'autonomous' => true })[0][:text])['session_id']
MockLlmCall.clear!
MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
MockLlmCall.queue({ 'content' => REPORT_PLAN, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
FakeChainStore.raise_with = RuntimeError.new('storage unavailable')
r12 = JSON.parse(STEP_TOOL.call({ 'session_id' => sid12, 'action' => 'approve' })[0][:text])
FakeChainStore.raise_with = nil
row12 = Array(r12['cycle_results']).last || {}
assert('the autonomous warning carries the halt reason and says the verdict was not recorded') do
  r12['warning'].to_s.include?('could not be recorded') && r12['warning'].to_s.include?('verdict not recorded')
end
assert('the autonomous cycle row says guard_halt, the reason, and verdict_recorded false') do
  row12['act_summary'] == 'guard_halt' && row12['guard_reason'].to_s.include?('storage unavailable') &&
    row12['verdict_recorded'] == false
end

section 'Summaries in autonomous cycle_results and error-only results'

halt_r = STEP_TOOL.send(:guard_halt_result, Session.load(sid8), { 'guard_halt' => true },
                        Verdict.halt_verdict('x'))
assert("a guard-halt cycle result summarises as 'guard_halt'") do
  STEP_TOOL.send(:response_act_summary, halt_r) == 'guard_halt'
end
assert("a result carrying only an error is not reported as 'completed'") do
  STEP_TOOL.send(:response_act_summary, { act_error: 'No decision payload found', llm_calls: 0 }) == 'failed'
end

FileUtils.rm_rf(TMPDIR)
puts "\n#{'=' * 60}\nRESULT: #{$pass} passed, #{$fail} failed\n#{'=' * 60}"
exit($fail.zero? ? 0 : 1)
