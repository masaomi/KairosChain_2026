#!/usr/bin/env ruby
# frozen_string_literal: true

# Answer rulings (design v0.3, INV-D4 / INV-D8, §4 stop record):
#   1. every stop names itself, with the state change that makes it, and a
#      later state change replaces it;
#   2. every committed advance writes one ruling; a replay writes none; a
#      failed record never blocks the answer;
#   3. an answer typed at the terminal binds the anchor it was given at: the
#      MCP answer there must be the same one, except that a stop always
#      proceeds;
#   4. the terminal command refuses without a terminal and finds the session
#      where the server keeps it.
#
# Drives the REAL agent_start / agent_step / agent_stop through the registry;
# stubs only llm_call, autoexec_plan/run, chain_record and knowledge_get.
# Records land in one in-memory chain read back by the real readers.
# Usage: ruby test_agent_answer_rulings.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'fileutils'
require 'tmpdir'
require 'digest'
require 'time'
require 'stringio'
require 'securerandom'
require 'rbconfig'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'
require_relative '../lib/agent'
require_relative '../tools/agent_start'
require_relative '../tools/agent_step'
require_relative '../tools/agent_stop'
require_relative '../tools/agent_status'

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

TMPDIR = Dir.mktmpdir('agent_answer_rulings')
PROJECT = File.join(TMPDIR, 'proj')
STORES = File.join(PROJECT, '.kairos')
FileUtils.mkdir_p(File.join(STORES, 'skillsets', 'agent', 'config'))
ORIG_PWD = Dir.pwd
Dir.chdir(PROJECT)

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

module KairosMcp
  def self.data_dir = STORES
end
FileUtils.mkdir_p(File.join(STORES, 'config'))
File.write(File.join(STORES, 'config', 'safety.yml'), "safe_root: #{PROJECT}\n")
FileUtils.mkdir_p(File.join(STORES, 'skillsets', 'llm_client', 'config'))
File.write(File.join(STORES, 'skillsets', 'llm_client', 'config', 'llm_client.yml'), "provider: claude_code\n")

AC = KairosMcp::SkillSets::Agent::ActClassification
AR = KairosMcp::SkillSets::Agent::AnswerRuling
Session = KairosMcp::SkillSets::Agent::Session
Gate = KairosMcp::SkillSets::Agent::AdvanceGate
MANDATE = Autonomos::Mandate

module Autoexec
  class TaskDsl
    def self.from_json(json_str)
      parsed = JSON.parse(json_str)
      raise ArgumentError, 'Missing task_id' unless parsed['task_id']

      parsed
    end
  end
end

# One in-memory chain: the table ruling and the terminal attestations are
# appended by the real interactive_* methods, the commit-time rulings by the
# driver through chain_record. Both are read back by the real readers.
class MemChain
  Block = Struct.new(:index, :data)
  attr_reader :blocks

  def initialize = @blocks = []

  def add_block(data)
    b = Block.new(@blocks.size + 1, data)
    @blocks << b
    b
  end
end

MEM = MemChain.new
AC.rulings_source = -> { [AC.rulings_from_blocks(MEM.blocks), nil] }
CHAIN_ERROR = { value: nil }
AR.records_source = lambda do
  CHAIN_ERROR[:value] ? [[], CHAIN_ERROR[:value]] : [AR.records_from_blocks(MEM.blocks), nil]
end

def answers(kind = AR::KIND)
  AR.records_from_blocks(MEM.blocks).select { |r| r['kind'] == kind }
end

class MockLlmCall < KairosMcp::Tools::BaseTool
  @@responses = []
  @@seen = []
  def self.queue(r) = @@responses << r
  def self.clear! = @@responses.clear
  def self.seen = @@seen
  def name = 'llm_call'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    @@seen << JSON.generate(arguments['messages'] || [])
    resp = @@responses.shift || { 'content' => 'default', 'tool_use' => nil, 'stop_reason' => 'end_turn' }
    text_content(JSON.generate({ 'status' => 'ok', 'provider' => 'mock', 'model' => 'mock-1',
                                 'response' => resp,
                                 'usage' => { 'input_tokens' => 1, 'output_tokens' => 1 },
                                 'snapshot' => { 'model' => 'mock-1', 'timestamp' => Time.now.iso8601 } }))
  end
end

class MockAutoexecPlan < KairosMcp::Tools::BaseTool
  @@last = nil
  def self.last = @@last
  def name = 'autoexec_plan'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    @@last = JSON.parse(arguments['task_json'])
    text_content(JSON.generate({ 'status' => 'ok', 'task_id' => @@last['task_id'],
                                 'plan_hash' => Digest::SHA256.hexdigest(arguments['task_json'])[0..15] }))
  end
end

class MockAutoexecRun < KairosMcp::Tools::BaseTool
  def name = 'autoexec_run'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  @@halt = false
  def self.halt=(v)
    @@halt = v
  end

  def call(_arguments)
    steps = Array(MockAutoexecPlan.last && MockAutoexecPlan.last['steps'])
    if @@halt
      return text_content(JSON.generate({ 'task_id' => 'mock_task', 'mode' => 'internal_execute',
                                          'outcome' => 'internal_execute_halted', 'halted_at' => steps.first['step_id'],
                                          'halt_kind' => 'step_failed', 'halt_reason' => 'tool failed', 'steps' => [] }))
    end
    deferred = steps.select { |s| s['requires_human_cognition'] == true }
                    .map { |s| { 'step_id' => s['step_id'], 'status' => 'deferred', 'tool_name' => s['tool_name'] } }
    body = { 'task_id' => 'mock_task', 'mode' => 'internal_execute',
             'outcome' => 'internal_execute_complete', 'steps' => [] }
    body['deferred'] = deferred unless deferred.empty?
    text_content(JSON.generate(body))
  end
end

class MockChainRecord < KairosMcp::Tools::BaseTool
  @@fail = false
  def self.fail=(v)
    @@fail = v
  end

  def name = 'chain_record'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    return text_content('Error: chain is locked') if @@fail

    b = MEM.add_block(Array(arguments['logs']))
    text_content("Block ##{b.index} recorded successfully.\nHash: #{'ab' * 32}")
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
    'chain_record' => MockChainRecord.new(nil, registry: registry),
    'agent_start' => KairosMcp::SkillSets::Agent::Tools::AgentStart.new(nil, registry: registry),
    'agent_stop' => KairosMcp::SkillSets::Agent::Tools::AgentStop.new(nil, registry: registry),
    'agent_status' => KairosMcp::SkillSets::Agent::Tools::AgentStatus.new(nil, registry: registry),
    'agent_step' => KairosMcp::SkillSets::Agent::Tools::AgentStep.new(registry.instance_variable_get(:@safety),
                                                                      registry: registry)
  })
  registry
end

REGISTRY = build_registry
TOOLS = REGISTRY.instance_variable_get(:@tools)
START_TOOL = TOOLS['agent_start']
STEP_TOOL = TOOLS['agent_step']
STOP_TOOL = TOOLS['agent_stop']
STATUS_TOOL = TOOLS['agent_status']

def plan(steps, summary: 'answer-ruling test plan')
  JSON.generate({
    'summary' => summary,
    'task_json' => { 'task_id' => "t_#{SecureRandom.hex(3)}",
                     'meta' => { 'description' => 't', 'risk_default' => 'low' },
                     'steps' => steps },
    'review_hint' => { 'needed' => false, 'reason' => nil, 'urgency' => nil },
    'complexity_hint' => { 'level' => 'low', 'signals' => [] }
  })
end

def step(id, tool, args = {}, risk: 'low', depends_on: [])
  { 'step_id' => id, 'action' => "do #{id}", 'tool_name' => tool, 'tool_arguments' => args,
    'risk' => risk, 'depends_on' => depends_on, 'requires_human_cognition' => false }
end

CLEAN = plan([step('s1', 'knowledge_get', { 'name' => 'x' })])
MIXED = plan([step('s1', 'knowledge_get', { 'name' => 'x' }),
              step('s2', 'knowledge_update', { 'name' => 'x', 'content' => 'y' })])

def step!(sid, action, **extra)
  JSON.parse(STEP_TOOL.call({ 'session_id' => sid, 'action' => action }.merge(extra.transform_keys(&:to_s)))[0][:text])
end

def start!(autonomous: false, max_cycles: 3, budget: 'medium')
  args = { 'goal_name' => "answers_#{SecureRandom.hex(3)}", 'risk_budget' => budget }
  args.merge!('autonomous' => true, 'max_cycles' => max_cycles) if autonomous
  JSON.parse(START_TOOL.call(args)[0][:text])['session_id']
end

# Manual mode, stopped at proposed with plan_json.
def proposed!(plan_json = CLEAN)
  sid = start!
  MockLlmCall.clear!
  MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue({ 'content' => plan_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  step!(sid, 'approve')
  sid
end

def reflect!
  MockLlmCall.queue({ 'content' => '{"confidence":0.5}', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
end

def anchor_of(sid)
  s = Session.load(sid)
  Gate.new(s.guard_dir).current_anchor(s)
end

# The operator at the terminal: lines are what they type, in order.
def terminal_answer!(sid, lines, nonce: 'k7k7k7', typed_nonce: nil, tty_in: nil)
  s = Session.load(sid)
  out = StringIO.new
  input = tty_in || StringIO.new((lines + [typed_nonce || nonce]).map { |l| "#{l}\n" }.join)
  r = AR.interactive_answer(session: s, gate: Gate.new(s.guard_dir), tty_in: input, tty_out: out,
                            reload: -> { Session.load(sid) }, chain: MEM, nonce_value: nonce)
  r.merge('shown' => out.string)
end

# The act route needs a table in force.
AC.interactive_rule(action: 'activate', tty_in: StringIO.new("abc123\n"), tty_out: StringIO.new,
                    chain: MEM, nonce_value: 'abc123')
TABLE_SHA = AC.sha256_of(AC::BASE_PATH)

# ------------------------------------------------------------------

section '1. Every stop names itself, and a later state change replaces it'

sid1 = start!
assert('a started session waits at observed because it was started') do
  Session.load(sid1).stop_kind == 'session_started'
end
MockLlmCall.clear!
MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
MockLlmCall.queue({ 'content' => CLEAN, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
r_prop = step!(sid1, 'approve')
assert('a proposed plan waits as plan_proposed, and the response says so') do
  r_prop['state'] == 'proposed' && r_prop.dig('stop', 'kind') == 'plan_proposed' &&
    Session.load(sid1).stop_kind == 'plan_proposed'
end
reflect!
r_clean = step!(sid1, 'approve')
assert('an act that left nothing over stops at the scheduled checkpoint') do
  r_clean['state'] == 'checkpoint' && r_clean.dig('stop', 'kind') == 'cycle_checkpoint'
end
r_next = step!(sid1, 'approve')
assert('the next state change replaces the stop (no stale checkpoint survives)') do
  r_next['state'] == 'observed' && Session.load(sid1).stop_kind == 'cycle_observed'
end
assert('agent_status shows the stop') do
  st = JSON.parse(STATUS_TOOL.call({ 'session_id' => sid1 })[0][:text])
  st.dig('stop', 'kind') == 'cycle_observed'
end

sid_mx = proposed!(MIXED)
reflect!
r_mx = step!(sid_mx, 'approve')
assert('an act that set a step aside stops as awaiting_operator, not as the checkpoint') do
  r_mx['state'] == 'checkpoint' && r_mx.dig('stop', 'kind') == 'awaiting_operator' &&
    Array(r_mx['awaiting_operator']).map { |d| d['step_id'] } == ['s2']
end

assert('the approve that ran it was ruled with the driver\'s count of steps set aside') do
  r = answers.reverse.find { |x| x['session_id'] == sid_mx && x['state'] == 'proposed' }
  r && r['set_aside'] == 1 && r['plan_sha256']
end

assert('a stop reached without a reason reads as unspecified') do
  s = Session.load(sid_mx)
  s.update_state('checkpoint')
  s.stop.nil? && s.stop_kind == 'unspecified'
end

sid_a = start!(autonomous: true, max_cycles: 3)
MockLlmCall.clear!
MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
MockLlmCall.queue({ 'content' => CLEAN, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
reflect!
r_a = step!(sid_a, 'approve')
assert('autonomous: the scheduled end-of-cycle stop (Gate 8) is cycle_checkpoint') do
  r_a['status'] == 'checkpoint' && r_a.dig('stop', 'kind') == 'cycle_checkpoint' &&
    Session.load(sid_a).stop_kind == 'cycle_checkpoint'
end
assert('autonomous: the mandate still reads paused_at_checkpoint, but nothing reads it for the stop') do
  MANDATE.load(Session.load(sid_a).mandate_id)[:status] == 'paused_at_checkpoint'
end
MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
MockLlmCall.queue({ 'content' => plan([step('s1', 'knowledge_get', { 'name' => 'x' }),
                                        step('s2', 'knowledge_update', { 'name' => 'x', 'content' => 'y' })],
                                       summary: 'second cycle plan'),
                    'tool_use' => nil, 'stop_reason' => 'end_turn' })
reflect!
r_a2 = step!(sid_a, 'approve')
assert('autonomous: a later stop of another kind is not read as Gate 8') do
  r_a2['status'] == 'checkpoint' && r_a2.dig('stop', 'kind') == 'awaiting_operator' &&
    MANDATE.load(Session.load(sid_a).mandate_id)[:status] == 'paused_at_checkpoint'
end

r_fin = JSON.parse(STEP_TOOL.send(:finalize_autonomous, Session.load(sid_a), [], terminated: 'goal_achieved')[0][:text])
assert('a termination names itself with its reason') do
  s = Session.load(sid_a)
  r_fin['terminated_reason'] == 'goal_achieved' && s.stop_kind == 'terminated' && s.stop['detail'] == 'goal_achieved'
end
STEP_TOOL.send(:finalize_autonomous, Session.load(sid_a), [], checkpoint: true, paused: 'llm_budget_exceeded')
assert('a pause code names itself') { Session.load(sid_a).stop_kind == 'llm_budget_exceeded' }
STEP_TOOL.send(:finalize_autonomous, Session.load(sid_a), [], checkpoint: true, warning: 'something')
assert('a checkpoint that does not say which it is stays unspecified (never Gate 8)') do
  Session.load(sid_a).stop_kind == 'unspecified'
end

section '2. Every committed advance writes one ruling; a replay writes none'

before = answers.size
sid2 = proposed!
r2_obs = answers.last
assert('the approve at observed wrote a ruling for that point') do
  answers.size == before + 1 && r2_obs['state'] == 'observed' && r2_obs['stop'] == 'session_started' &&
    r2_obs['decision'] == 'approve' && r2_obs['session_id'] == sid2 && !r2_obs.key?('plan_sha256')
end
anchor2 = anchor_of(sid2)
reflect!
r2 = step!(sid2, 'approve', anchor: anchor2, rationale: 'looks fine')
rec2 = answers.last
plan2 = Session.load(sid2).load_decision
assert('the approve at proposed wrote one ruling with the point, the plan and the tables') do
  rec2['anchor'] == anchor2 && rec2['state'] == 'proposed' && rec2['stop'] == 'plan_proposed' &&
    rec2['plan_sha256'] == AR.plan_sha256(plan2) && rec2['signals'].is_a?(Array) && rec2['set_aside'] == 0 &&
    rec2['tables'] == { 'act_classification' => TABLE_SHA, 'delegation' => nil }
end
assert('an MCP answer is the caller\'s, unattested') do
  rec2['approver'] == 'caller' && rec2['attestation'] == 'caller_unattested' && !rec2.key?('attestation_block')
end
assert('the response carries the ruling\'s block') do
  r2.dig('ruling', 'recorded') == true && r2.dig('ruling', 'block') == MEM.blocks.size
end
assert('the rationale stays off the chain; the ruling carries its sha256') do
  texts = AR.texts_at(Session.load(sid2).guard_dir, anchor2, source: 'caller')
  rec2['rationale_sha256'] == Digest::SHA256.hexdigest('looks fine') &&
    texts.last['rationale'] == 'looks fine' && MEM.blocks.none? { |b| b.data.join.include?('looks fine') }
end
count2 = answers.size
r2_again = step!(sid2, 'approve', anchor: anchor2, rationale: 'looks fine')
assert('re-sending the same answer at the same anchor replays it and writes no second ruling') do
  r2_again['replayed'] == true && answers.size == count2 && r2_again.dig('ruling', 'block') == r2.dig('ruling', 'block')
end

sid_rev = proposed!
MockLlmCall.queue({ 'content' => CLEAN, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
step!(sid_rev, 'revise', feedback: 'smaller steps please')
assert('a revise ruling carries the feedback\'s sha256, not the text') do
  r = answers.last
  r['decision'] == 'revise' && r['feedback_sha256'] == Digest::SHA256.hexdigest('smaller steps please') &&
    MEM.blocks.none? { |b| b.data.join.include?('smaller steps please') }
end

sid_bad = start!
count_bad = answers.size
r_bad = step!(sid_bad, 'revise', feedback: 'x')
assert('an answer that advanced nothing writes no ruling') do
  r_bad['status'] == 'error' && answers.size == count_bad
end

sid_f = proposed!
MockChainRecord.fail = true
reflect!
r_f = step!(sid_f, 'approve')
MockChainRecord.fail = false
assert('a ruling that failed to record does not block the answer, and the response says so') do
  r_f['state'] == 'checkpoint' && r_f.dig('ruling', 'recorded') == false &&
    r_f.dig('ruling', 'error').to_s.include?('chain is locked') && r_f.dig('ruling', 'note').to_s.include?('does not count')
end

section '3. A terminal answer binds its anchor'

sid3 = proposed!
a3 = anchor_of(sid3)
r_wrong = terminal_answer!(sid3, ['approve', ''], typed_nonce: 'nope')
assert('a mistyped nonce records nothing') { r_wrong['recorded'] == false && answers(AR::ATTESTATION_KIND).empty? }
r_off = terminal_answer!(sid3, ['adjudicate'])
assert('an answer not offered at this state records nothing') { r_off['recorded'] == false && r_off['reason'] == 'not_offered' }
assert('the terminal shows why the session stopped and the plan it would answer') do
  r_off['shown'].include?('because plan_proposed') && r_off['shown'].include?('knowledge_get') &&
    r_off['shown'].include?(AR.plan_sha256(Session.load(sid3).load_decision))
end
r_t = terminal_answer!(sid3, ['skip', 'not today'])
att3 = answers(AR::ATTESTATION_KIND).last
assert('the typed nonce records an attestation bound to the anchor and the plan shown') do
  r_t['recorded'] && att3['anchor'] == a3 && att3['decision'] == 'skip' && att3['attested'] == true &&
    att3['attestation'] == 'terminal_nonce' && att3['plan_sha256'] == AR.plan_sha256(Session.load(sid3).load_decision) &&
    att3['stop'] == 'plan_proposed'
end
assert('the nonce is never recorded') { MEM.blocks.none? { |b| b.data.join.include?('k7k7k7') } }
count3 = answers.size
r_mis = step!(sid3, 'approve')
assert('a different MCP answer at that anchor is refused and advances nothing') do
  r_mis['status'] == 'answer_refused' && r_mis.dig('attested', 'decision') == 'skip' &&
    Session.load(sid3).state == 'proposed' && anchor_of(sid3) == a3 && answers.size == count3
end
MockLlmCall.queue({ 'content' => '{"confidence":0.4}', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
r_match = step!(sid3, 'skip')
rec3 = answers.last
assert('the same answer proceeds and its ruling is the operator\'s, attested, naming the attestation') do
  r_match['state'] == 'checkpoint' && rec3['decision'] == 'skip' && rec3['approver'] == 'operator' &&
    rec3['attestation'] == 'terminal_nonce' && rec3['attestation_block'] == att3['block']
end
assert('...and the operator\'s reason was not written again as the caller\'s') do
  AR.texts_at(Session.load(sid3).guard_dir, a3, source: 'caller').empty? &&
    AR.texts_at(Session.load(sid3).guard_dir, a3).last['rationale'] == 'not today'
end
assert('the attestation does not reach the next anchor') do
  AR.attestation_at(AR.records_from_blocks(MEM.blocks), sid3, anchor_of(sid3)).nil?
end

sid_s = proposed!
terminal_answer!(sid_s, ['approve', ''])
att_s = answers(AR::ATTESTATION_KIND).last
r_stop = step!(sid_s, 'stop')
assert('a stop proceeds over a different terminal answer, and the ruling names what it overrode') do
  r = answers.last
  r_stop['state'] == 'terminated' && r['decision'] == 'stop' && r['attestation'] == 'caller_unattested' &&
    r['overrode_attestation_block'] == att_s['block']
end

sid_s2 = proposed!
terminal_answer!(sid_s2, ['approve', ''])
att_s2 = answers(AR::ATTESTATION_KIND).last
r_ts = JSON.parse(STOP_TOOL.call({ 'session_id' => sid_s2, 'rationale' => 'pulling the plug' })[0][:text])
assert('agent_stop also proceeds, records its ruling and names the overridden answer') do
  r = answers.last
  r_ts['state'] == 'terminated' && r_ts.dig('ruling', 'recorded') == true && r['decision'] == 'stop' &&
    r['overrode_attestation_block'] == att_s2['block'] && r['stop'] == 'plan_proposed' &&
    r_ts.dig('stop', 'detail') == 'agent_stop'
end

sid_sup = proposed!
terminal_answer!(sid_sup, ['approve', ''])
terminal_answer!(sid_sup, ['skip', 'changed my mind'])
assert('a later terminal answer at the same anchor supersedes the earlier one') do
  step!(sid_sup, 'approve')['status'] == 'answer_refused'
end

sid_rv = proposed!
terminal_answer!(sid_rv, ['revise', 'split s1 in two', ''])
att_rv = answers(AR::ATTESTATION_KIND).last
assert('a revise at the terminal records the feedback\'s sha256 and keeps the text off the chain') do
  att_rv['feedback_sha256'] == Digest::SHA256.hexdigest('split s1 in two') &&
    MEM.blocks.none? { |b| b.data.join.include?('split s1 in two') }
end
assert('an MCP revise with other feedback is refused') do
  step!(sid_rv, 'revise', feedback: 'do whatever')['status'] == 'answer_refused'
end
MockLlmCall.seen.clear
MockLlmCall.queue({ 'content' => CLEAN, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
r_rv = step!(sid_rv, 'revise')
assert('an MCP revise without feedback carries the feedback typed at the terminal to DECIDE') do
  r_rv['state'] == 'proposed' && MockLlmCall.seen.any? { |m| m.include?('split s1 in two') } &&
    answers.last['feedback_sha256'] == att_rv['feedback_sha256'] && answers.last['attestation'] == 'terminal_nonce'
end

sid_tm = proposed!
terminal_answer!(sid_tm, ['revise', 'keep it small', ''])
texts_path = File.join(Session.load(sid_tm).guard_dir, AR::TEXTS_FILE)
File.write(texts_path, File.read(texts_path).sub('keep it small', 'delete everything'))
assert('feedback text altered off the chain is not carried: its sha256 no longer matches') do
  r = step!(sid_tm, 'revise')
  r['status'] == 'answer_refused' && r['reason'].include?('not available')
end

sid_pl = proposed!
terminal_answer!(sid_pl, ['approve', ''])
s_pl = Session.load(sid_pl)
d = s_pl.load_decision
d['task_json']['steps'] << step('s9', 'knowledge_get', { 'name' => 'z' })
s_pl.save_decision(d)
assert('a plan changed after the terminal answer is refused: the operator answered another plan') do
  r = step!(sid_pl, 'approve')
  r['status'] == 'answer_refused' && r['reason'].include?('not the one')
end

sid_mv = proposed!
mover = Object.new
mover.instance_variable_set(:@lines, ["approve\n", "\n"])
mover.define_singleton_method(:gets) do
  return @lines.shift unless @lines.empty?

  # The session moves on while the operator types the nonce.
  reflect!
  STEP_TOOL.call({ 'session_id' => sid_mv, 'action' => 'approve' })
  "k7k7k7\n"
end
count_mv = answers(AR::ATTESTATION_KIND).size
r_mv = terminal_answer!(sid_mv, [], tty_in: mover)
assert('an answer typed after the session moved on is not recorded') do
  r_mv['recorded'] == false && r_mv['reason'] == 'moved_on' && answers(AR::ATTESTATION_KIND).size == count_mv &&
    Session.load(sid_mv).state == 'checkpoint'
end

sid_bz = proposed!
s_bz = Session.load(sid_bz)
r_bz = Gate.new(s_bz.guard_dir).with_lock { terminal_answer!(sid_bz, ['approve', '']) }
assert('an answer typed while an advance holds the lock is not recorded') do
  r_bz['recorded'] == false && r_bz['reason'] == 'busy'
end

sid_un = proposed!
terminal_answer!(sid_un, ['skip', ''])
CHAIN_ERROR[:value] = 'chain corrupt'
count_un = answers.size
r_un = step!(sid_un, 'approve')
assert('a chain that cannot be read refuses every answer but a stop: whether the operator answered is unknown') do
  r_un['status'] == 'answer_refused' && r_un['reason'].include?('could not be read') &&
    Session.load(sid_un).state == 'proposed' && answers.size == count_un
end
r_un_stop = step!(sid_un, 'stop')
CHAIN_ERROR[:value] = nil
assert('...and a stop still proceeds, its ruling saying why it is unattested') do
  r = answers.last
  r_un_stop['state'] == 'terminated' && r['decision'] == 'stop' && r['attestation_check'].include?('chain corrupt')
end

sid_cr = proposed!
refusing = Object.new
refusing.define_singleton_method(:add_block) { |_| raise 'cannot append: ledger is unreadable' }
s_cr = Session.load(sid_cr)
out_cr = StringIO.new
r_cr = AR.interactive_answer(session: s_cr, gate: Gate.new(s_cr.guard_dir), tty_in: StringIO.new("approve\n\nk7k7k7\n"),
                             tty_out: out_cr, reload: -> { Session.load(sid_cr) }, chain: refusing, nonce_value: 'k7k7k7')
assert('a chain that will not take the answer ends in a message, not a traceback') do
  r_cr['recorded'] == false && r_cr['reason'] == 'chain_refused' && out_cr.string.include?('did not take the answer')
end

sid_tr = proposed!
step!(sid_tr, 'stop')
assert('a terminated session offers nothing to answer') do
  terminal_answer!(sid_tr, ['stop', ''])['reason'] == 'nothing_to_answer'
end

section '3b. Review round 1 fixes'

sid_h = proposed!(plan([step('s1', 'knowledge_get', { 'name' => 'x' }),
                        step('s2', 'knowledge_get', { 'name' => 'y' }, depends_on: ['s1'])]))
MockAutoexecRun.halt = true
reflect!
r_h = step!(sid_h, 'approve')
MockAutoexecRun.halt = false
assert('an act that halted on a failed step stops as act_failed, never as the scheduled checkpoint') do
  r_h['act_summary'] == 'halted' && r_h.dig('stop', 'kind') == 'act_failed'
end

sid_ra = proposed!
s_ra = Session.load(sid_ra)
Gate.new(s_ra.guard_dir).open_intent(anchor_of(sid_ra), {})
reflect!
r_ra = step!(sid_ra, 'adjudicate', resolution: 'reattempt')
assert('a clean reattempt after an interrupted act stops as adjudicated, never as the scheduled checkpoint') do
  r_ra['state'] == 'checkpoint' && r_ra.dig('stop', 'kind') == 'adjudicated' && r_ra.dig('stop', 'detail') == 'reattempt'
end
assert('in an autonomous session the manual wrapper never names the scheduled checkpoint') do
  STEP_TOOL.send(:manual_act_stop, Session.load(sid_a), { act: {}, act_succeeded: true }) == 'adjudicated'
end

sid_pe = proposed!
MockLlmCall.queue({ 'content' => 'not json at all', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
r_pe = step!(sid_pe, 'revise', feedback: 'first try')
MockLlmCall.queue({ 'content' => CLEAN, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
r_pe2 = step!(sid_pe, 'revise', feedback: 'second try')
assert('a successful revise after a failed one waits as plan_proposed again, not as the old error') do
  r_pe['status'] == 'error' && r_pe2['state'] == 'proposed' && Session.load(sid_pe).stop_kind == 'plan_proposed'
end

sid_x = proposed!(plan([step("s1\e[1A\e[2K\r", 'knowledge_get', { 'name' => "x\e]0;t\a" })],
                       summary: "ok\nPlan:    forged\u202e"))
r_x = terminal_answer!(sid_x, ['stop', ''], typed_nonce: 'no')
assert('agent-authored text reaches the terminal with its control and format characters escaped') do
  shown = r_x['shown']
  !shown.include?("\e") && !shown.include?("\r") && !shown.include?("\u202e") &&
    shown.include?('\\u{1b}') && !shown.include?("\nPlan:    forged")
end
assert('the terminal shows each step\'s arguments') { r_x['shown'].include?('name: "x') }

LONG = 'harmless words ' * 30
sid_lg = proposed!(plan([step('s1', 'safe_file_write', { 'content' => LONG, 'path' => 'docs/drafts/draft_x.md' })]))
r_lg = terminal_answer!(sid_lg, ['stop', ''], typed_nonce: 'no')
assert('every argument is shown whole, the location first, whatever order the plan put them in') do
  shown = r_lg['shown']
  shown.include?(LONG.strip) && shown.index('path: ') < shown.index('content: ') &&
    shown.include?(File.join(Session.load(sid_lg).guard_dir, 'decision_payload.json'))
end
# The three ways the review pushed a location out of view (round-2 carryover).
def last_lines_before_prompt(shown, n)
  shown.split("\n").take_while { |l| !l.start_with?('Your answer') }.last(n).join("\n")
end
FLOOD = 'x' * 14_500
sid_fl = proposed!(plan([step('s1', 'safe_file_write', { 'path' => 'docs/drafts/draft_target.md', 'content' => 'c' }),
                         step('s2', 'knowledge_get', { 'query' => FLOOD })]))
near_fl = last_lines_before_prompt(terminal_answer!(sid_fl, ['stop', ''], typed_nonce: 'no')['shown'], 6)
assert('a later step that floods the screen cannot push the location away from the prompt') do
  near_fl.include?('step 1: safe_file_write path="docs/drafts/draft_target.md"') &&
    near_fl.include?('2 step(s)') && near_fl.match?(/took \d+ lines \(\d+ characters\)/) &&
    near_fl.include?(File.join(Session.load(sid_fl).guard_dir, 'decision_payload.json')) &&
    !near_fl.include?(FLOOD)
end
sid_zw = proposed!(plan([step('s1', 'safe_file_write', { 'path' => 'docs/drafts/draft_z.md', 'content' => 'c' }),
                         step('s2', 'knowledge_get', { 'query' => "\u200b" * 14_000 })]))
near_zw = last_lines_before_prompt(terminal_answer!(sid_zw, ['stop', ''], typed_nonce: 'no')['shown'], 6)
assert('invisible characters cannot push it away either') do
  near_zw.include?('path="docs/drafts/draft_z.md"')
end
sid_sp2 = proposed!(plan([step('s1', 'safe_file_write',
                               { 'path' => "docs/drafts/ok.md#{' ' * 3000}/../../important_doc.md", 'content' => 'c' })]))
near_sp = last_lines_before_prompt(terminal_answer!(sid_sp2, ['stop', ''], typed_nonce: 'no')['shown'], 6)
assert('spaces packed into a location are shown as a count, and what follows them stays in view') do
  near_sp.include?('docs/drafts/ok.md[3000 spaces]/../../important_doc.md')
end
assert('the plan file is named by its absolute path, whatever directory the server runs in') do
  out = StringIO.new
  AR.show_plan(out, JSON.parse(CLEAN), 'proposed', 'abc', File.join('rel', 'decision_payload.json'))
  out.string.include?("read it whole in #{File.expand_path(File.join('rel', 'decision_payload.json'))}")
end
assert('a long location is cut with a marker that says so') do
  AR.visible('a' * 500).end_with?('(cut; read the file)')
end
assert('spacing characters other than the plain space are escaped') do
  AR.printable("a\u3000b\u00a0c") == 'a\\u{3000}b\\u{a0}c'
end

assert('the summary is shown as the plan\'s own claim') do
  r_lg['shown'].include?('summary, as the plan states it:')
end

assert('bytes that are not UTF-8 cannot make the terminal display raise') do
  bad = "bad \xff\xfe bytes".b
  AR.printable(bad).include?('bad ?? bytes') && AR.json_text({ 'k' => bad }).is_a?(String)
end

def typing_then(lines, before_nonce)
  io = Object.new
  io.instance_variable_set(:@lines, lines.map { |l| "#{l}\n" })
  io.define_singleton_method(:gets) do
    return @lines.shift unless @lines.empty?

    before_nonce.call
    "k7k7k7\n"
  end
  io
end

sid_in = proposed!
r_in = terminal_answer!(sid_in, [], tty_in: typing_then(['approve', ''], lambda {
  s = Session.load(sid_in)
  Gate.new(s.guard_dir).open_intent(anchor_of(sid_in), {})
}))
assert('an answer whose state changed under it (an act opened its intent) is not recorded') do
  r_in['recorded'] == false && r_in['detail'].to_s.include?('no longer an answer')
end

sid_pc = proposed!
r_pc = terminal_answer!(sid_pc, [], tty_in: typing_then(['approve', ''], lambda {
  s = Session.load(sid_pc)
  d = s.load_decision
  d['task_json']['steps'] << step('s9', 'knowledge_get', { 'name' => 'z' })
  s.save_decision(d)
}))
assert('an answer to a plan that changed after it was shown is not recorded') do
  r_pc['recorded'] == false && r_pc['detail'].to_s.include?('plan changed')
end

sid_rx = proposed!
orig_att = AR.method(:attestation_at)
AR.define_singleton_method(:attestation_at) { |*| raise 'cannot check' }
r_rx = step!(sid_rx, 'approve')
r_rx_stop = step!(sid_rx, 'stop')
AR.define_singleton_method(:attestation_at, orig_att)
assert('an answer that cannot be checked is refused, and a stop still proceeds') do
  r_rx['status'] == 'answer_refused' && r_rx['reason'].include?('could not be checked') &&
    r_rx_stop['state'] == 'terminated'
end

sid_sx = proposed!
STEP_CLASS = KairosMcp::SkillSets::Agent::Tools::AgentStep
STEP_CLASS.class_eval do
  alias_method :__answer_point, :answer_point
  define_method(:answer_point) { |*| raise 'point broke' }
end
r_sx = JSON.parse(STOP_TOOL.call({ 'session_id' => sid_sx })[0][:text])
STEP_CLASS.class_eval { alias_method :answer_point, :__answer_point }
assert('agent_stop stops even when its ruling cannot be prepared, and says so in the ruling') do
  r = answers.last
  r_sx['state'] == 'terminated' && r['decision'] == 'stop' && r['attestation_check'].to_s.include?('point broke')
end

sid_st = proposed!
r_st = JSON.parse(STOP_TOOL.call({ 'session_id' => sid_st })[0][:text])
assert('agent_stop at a plan point rules with the plan hash, the signals and the set-aside count') do
  r = answers.last
  r_st.dig('ruling', 'recorded') && r['plan_sha256'] && r['signals'].is_a?(Array) && r['set_aside'] == 0 &&
    r['tables'] == { 'act_classification' => TABLE_SHA, 'delegation' => nil }
end

sid_rr = proposed!
terminal_answer!(sid_rr, ['skip', 'the operator says why'])
att_rr = answers(AR::ATTESTATION_KIND).last
MockLlmCall.queue({ 'content' => '{"confidence":0.4}', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
step!(sid_rr, 'skip', rationale: 'the caller says something else')
assert('an attested ruling carries the operator\'s reason, not the caller\'s') do
  answers.last['rationale_sha256'] == att_rr['rationale_sha256'] &&
    att_rr['rationale_sha256'] == Digest::SHA256.hexdigest('the operator says why')
end

sid_df = proposed!
MockLlmCall.queue({ 'content' => CLEAN, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
step!(sid_df, 'revise')
assert('a revise with no feedback records the digest of the feedback DECIDE was given') do
  answers.last['feedback_sha256'] == Digest::SHA256.hexdigest('Please revise the plan.')
end

sid_rp = proposed!
a_rp = anchor_of(sid_rp)
terminal_answer!(sid_rp, ['revise', 'tighten the scope', ''])
MockLlmCall.queue({ 'content' => plan([step('s1', 'knowledge_get', { 'name' => 'q' })], summary: 'tightened'),
                    'tool_use' => nil, 'stop_reason' => 'end_turn' })
first = step!(sid_rp, 'revise', anchor: a_rp)
count_rp = answers.size
again = step!(sid_rp, 'revise', anchor: a_rp)
assert('re-sending an attested revise without feedback after it committed replays it') do
  first['state'] == 'proposed' && again['replayed'] == true && answers.size == count_rp
end

sid_sp = proposed!
a_sp = anchor_of(sid_sp)
MEM.add_block([JSON.generate({ 'kind' => AR::KIND, 'session_id' => sid_sp, 'anchor' => a_sp, 'decision' => 'approve' })])
orphan = MEM.blocks.size
reflect!
step!(sid_sp, 'approve')
assert('a second ruling at an anchor (left by a crash before the commit) names the one it supersedes') do
  answers.last['supersedes_block'] == orphan
end

sid_bd = proposed!
orig_ruling = AR.method(:ruling)
AR.define_singleton_method(:ruling) { |**| raise 'ruling could not be built' }
reflect!
r_bd = step!(sid_bd, 'approve')
AR.define_singleton_method(:ruling, orig_ruling)
assert('a ruling that cannot even be built never blocks the answer: it commits and says so') do
  r_bd['state'] == 'checkpoint' && r_bd.dig('ruling', 'recorded') == false &&
    r_bd.dig('ruling', 'error').to_s.include?('could not be built')
end

SD = KairosMcp::SkillSets::Agent::StepDelegation
SD.class_eval do
  alias_method :__spawn_worker, :spawn_worker
  define_method(:spawn_worker) { |_sid| nil }
end
sid_dl = proposed!
terminal_answer!(sid_dl, ['revise', 'from the terminal', ''])
STEP_TOOL.call({ 'session_id' => sid_dl, 'action' => 'revise', 'execution' => 'delegated', 'rationale' => 'why' })
args_dl = SD.new(Session.load(sid_dl).guard_dir).pending['arguments']
SD.class_eval { alias_method :spawn_worker, :__spawn_worker }
assert('a delegated answer carries its rationale and the feedback typed at the terminal to the worker') do
  args_dl['rationale'] == 'why' && args_dl['feedback'] == 'from the terminal'
end

section '4. The terminal command (subprocesses)'

RUBY = RbConfig.ruby
SERVER_LIB = File.expand_path('../../../../lib', __dir__)
BIN = File.expand_path('../bin/agent_rule.rb', __dir__)

SERVER_SESSIONS = File.join(STORES, 'storage', 'agent_sessions', 'agent_cli_probe')
FileUtils.mkdir_p(SERVER_SESSIONS)
File.write(File.join(SERVER_SESSIONS, 'session.json'), JSON.generate({
  'session_id' => 'agent_cli_probe', 'mandate_id' => 'm', 'goal_name' => 'g', 'state' => 'observed',
  'cycle_number' => 0, 'config' => {}, 'autonomous' => false, 'invocation_context' => {}
}))
miss_out = IO.popen({ 'KAIROS_SERVER_LIB' => SERVER_LIB }, [RUBY, BIN, 'answer', 'agent_nope', '--data-dir', STORES],
                    err: %i[child out], &:read)
assert('agent_rule.rb answer names where it looked when the session is not there') do
  miss_out.include?('no agent session agent_nope') && miss_out.include?(File.join('.kairos', 'storage', 'agent_sessions'))
end
rd2, wr2 = IO.pipe
pid2 = fork do
  Process.setsid
  rd2.close
  $stdout.reopen(wr2)
  $stderr.reopen(wr2)
  $stdin.reopen(File::NULL)
  ENV['KAIROS_SERVER_LIB'] = SERVER_LIB
  exec(RUBY, BIN, 'answer', 'agent_cli_probe', '--data-dir', STORES)
end
wr2.close
found_out = rd2.read
Process.wait(pid2)
found_status = $?.exitstatus
assert('agent_rule.rb answer finds a session where the server keeps it, then refuses without a terminal') do
  found_status != 0 && found_out.include?('needs a terminal') && !found_out.include?('no agent session')
end
ELSEWHERE = File.join(TMPDIR, 'server_cwd')
FileUtils.mkdir_p(File.join(ELSEWHERE, '.kairos', 'storage', 'agent_sessions', 'agent_cli_elsewhere'))
File.write(File.join(ELSEWHERE, '.kairos', 'storage', 'agent_sessions', 'agent_cli_elsewhere', 'session.json'),
           File.read(File.join(SERVER_SESSIONS, 'session.json')).sub('agent_cli_probe', 'agent_cli_elsewhere'))
rd3, wr3 = IO.pipe
pid3 = fork do
  Process.setsid
  rd3.close
  $stdout.reopen(wr3)
  $stderr.reopen(wr3)
  $stdin.reopen(File::NULL)
  ENV['KAIROS_SERVER_LIB'] = SERVER_LIB
  exec(RUBY, BIN, 'answer', 'agent_cli_elsewhere', '--data-dir', STORES, '--project-dir', ELSEWHERE)
end
wr3.close
elsewhere_out = rd3.read
Process.wait(pid3)
assert('with --project-dir the session is found where that server runs, while the chain stays the data dir\'s') do
  elsewhere_out.include?("Sessions from: #{ELSEWHERE}") && elsewhere_out.include?("Data dir: #{STORES}") &&
    elsewhere_out.include?('needs a terminal')
end
assert('--project-dir without a directory prints usage instead of guessing') do
  out = IO.popen({ 'KAIROS_SERVER_LIB' => SERVER_LIB }, [RUBY, BIN, 'answer', 'agent_cli_probe', '--data-dir', STORES,
                                                          '--project-dir'], err: %i[child out], &:read)
  out.include?('usage: agent_rule.rb answer SESSION_ID --project-dir DIR')
end
assert('agent_rule.rb without a session id prints usage') do
  out = IO.popen({ 'KAIROS_SERVER_LIB' => SERVER_LIB }, [RUBY, BIN, 'answer', '--data-dir', STORES],
                 err: %i[child out], &:read)
  out.include?('usage: agent_rule.rb answer SESSION_ID')
end

REAL = File.join(TMPDIR, 'real_chain')
FileUtils.mkdir_p(REAL)
reader = <<~RB
  require 'kairos_mcp'; require 'kairos_mcp/kairos_chain/chain'; require 'json'
  KairosMcp.data_dir = #{REAL.inspect}
  lib = #{File.expand_path('../lib', __dir__).inspect}
  %w[admission mandate_adapter act_classification answer_ruling].each { |f| require File.join(lib, 'agent', f) }
  ar = KairosMcp::SkillSets::Agent::AnswerRuling
  KairosMcp::KairosChain::Chain.new.add_block([JSON.generate({ 'kind' => ar::ATTESTATION_KIND, 'session_id' => 's',
    'anchor' => '1:proposed:0', 'decision' => 'skip', 'attested' => true })])
  calls = 0
  KairosMcp::KairosChain::Chain.prepend(Module.new do
    define_method(:initialize) do |*a, **k|
      calls += 1
      raise IOError, 'torn' if calls == 1

      super(*a, **k)
    end
  end)
  records, error = ar.chain_records
  att = ar.attestation_at(records, 's', '1:proposed:0')
  puts [error.inspect, att && att['decision'], att && att['block'], calls].join(' ')
RB
real_out = IO.popen({ 'RUBYLIB' => SERVER_LIB }, [RUBY, '-e', reader], err: %i[child out], &:read)
assert('the real chain reader returns an attestation appended through the real chain, with its block') do
  real_out.strip.match?(/\Anil skip \d+ 2\z/)
end

Dir.chdir(ORIG_PWD)
FileUtils.rm_rf(TMPDIR)

puts "\n#{'=' * 60}\nRESULTS: #{$pass} passed, #{$fail} failed\n#{'=' * 60}"
exit($fail.zero? ? 0 : 1)
