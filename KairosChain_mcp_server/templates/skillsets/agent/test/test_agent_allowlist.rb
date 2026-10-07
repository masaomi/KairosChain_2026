#!/usr/bin/env ruby
# frozen_string_literal: true

# The act route's allow-list (design v0.3, INV-A1 / INV-A2 / INV-D8):
#   1. the table is in force only while the latest attested ruling names the
#      sha256 of its bytes; otherwise it is empty;
#   2. unclassified steps are set aside for the operator, classified ones run
#      at their resolved risk (the plan's label raises, never lowers);
#   3. the file route is never taken; the steps set aside reach the operator
#      as a list in manual mode too;
#   4. locations git and development tools execute are protected;
#   5. the terminal ruling refuses to run without a terminal.
#
# Drives the REAL agent_start / agent_step through the registry; stubs only
# llm_call, autoexec_plan/run, chain_record, knowledge_get and agent_execute.
# Rulings are made by the real ActClassification.interactive_rule; only their
# storage is in memory (section 4 uses the real chain in a subprocess).
# Usage: ruby test_agent_allowlist.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'yaml'
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

TMPDIR = Dir.mktmpdir('agent_allowlist')
PROJECT = File.join(TMPDIR, 'proj')
STORES = File.join(PROJECT, '.kairos')
FileUtils.mkdir_p(File.join(STORES, 'skillsets', 'agent', 'config'))
FileUtils.mkdir_p(File.join(PROJECT, 'docs'))
ORIG_PWD = Dir.pwd
ORIG_HOME = ENV['HOME']
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
Session = KairosMcp::SkillSets::Agent::Session

module Autoexec
  class TaskDsl
    def self.from_json(json_str)
      parsed = JSON.parse(json_str)
      raise ArgumentError, 'Missing task_id' unless parsed['task_id']

      parsed
    end
  end
end

# In-memory storage for rulings; the blocks are what the real
# interactive_rule appended, read back by the real rulings_from_blocks.
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

def rule!(action, path: AC::BASE_PATH, typed: nil)
  out = StringIO.new
  n = AC.nonce
  AC.interactive_rule(action: action, tty_in: StringIO.new("#{typed || n}\n"), tty_out: out,
                      path: path, chain: MEM, nonce_value: n)
end

class MockLlmCall < KairosMcp::Tools::BaseTool
  @@responses = []
  def self.queue(r) = @@responses << r
  def self.clear! = @@responses.clear
  def name = 'llm_call'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(_arguments)
    resp = @@responses.shift || { 'content' => 'default', 'tool_use' => nil, 'stop_reason' => 'end_turn' }
    text_content(JSON.generate({ 'status' => 'ok', 'provider' => 'mock', 'model' => 'mock-1',
                                 'response' => resp,
                                 'usage' => { 'input_tokens' => 1, 'output_tokens' => 1 },
                                 'snapshot' => { 'model' => 'mock-1', 'timestamp' => Time.now.iso8601 } }))
  end
end

class MockAutoexecPlan < KairosMcp::Tools::BaseTool
  @@last = nil
  @@calls = 0
  def self.last = @@last
  def self.calls = @@calls
  def name = 'autoexec_plan'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    @@calls += 1
    @@last = JSON.parse(arguments['task_json'])
    text_content(JSON.generate({ 'status' => 'ok', 'task_id' => @@last['task_id'],
                                 'plan_hash' => Digest::SHA256.hexdigest(arguments['task_json'])[0..15] }))
  end
end

# Defers exactly what the plan it was handed marks, as autoexec does.
class MockAutoexecRun < KairosMcp::Tools::BaseTool
  def name = 'autoexec_run'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  @@halt_first = false
  @@halt_at = nil
  def self.halt_first=(v)
    @@halt_first = v
  end

  def self.halt_at=(v)
    @@halt_at = v
  end

  def call(_arguments)
    if @@halt_first
      first = Array(MockAutoexecPlan.last['steps']).first
      return text_content(JSON.generate({ 'task_id' => 'mock_task', 'mode' => 'internal_execute',
                                          'outcome' => 'internal_execute_halted', 'halted_at' => first['step_id'],
                                          'halt_kind' => 'error', 'halt_reason' => 'tool failed', 'steps' => [] }))
    end
    steps = Array(MockAutoexecPlan.last && MockAutoexecPlan.last['steps'])
    if @@halt_at
      before = steps.take_while { |st| st['step_id'] != @@halt_at }
      deferred = before.select { |st| st['requires_human_cognition'] == true }
                       .map { |st| { 'step_id' => st['step_id'], 'status' => 'deferred' } }
      return text_content(JSON.generate({ 'task_id' => 'mock_task', 'mode' => 'internal_execute',
                                          'outcome' => 'internal_execute_halted', 'halted_at' => @@halt_at,
                                          'halt_kind' => 'error', 'deferred' => deferred, 'steps' => [] }))
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
  @@logs = []
  def self.logs = @@logs
  def name = 'chain_record'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    @@logs.concat(Array(arguments['logs']))
    text_content("Block ##{@@logs.size} recorded successfully.\nHash: #{'ab' * 32}")
  end
end

class MockKnowledgeGet < KairosMcp::Tools::BaseTool
  def name = 'knowledge_get'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }
  def call(args) = text_content(JSON.generate({ 'name' => args['name'], 'content' => 'mock' }))
end

class MockAgentExecute < KairosMcp::Tools::BaseTool
  @@calls = 0
  def self.calls = @@calls
  def name = 'agent_execute'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(_arguments)
    @@calls += 1
    text_content(JSON.generate({ 'status' => 'ok', 'files_modified' => [] }))
  end
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
    'agent_execute' => MockAgentExecute.new(nil, registry: registry),
    'agent_start' => KairosMcp::SkillSets::Agent::Tools::AgentStart.new(nil, registry: registry),
    'agent_step' => KairosMcp::SkillSets::Agent::Tools::AgentStep.new(registry.instance_variable_get(:@safety), registry: registry)
  })
  registry
end

REGISTRY = build_registry
START_TOOL = REGISTRY.instance_variable_get(:@tools)['agent_start']
STEP_TOOL = REGISTRY.instance_variable_get(:@tools)['agent_step']

def plan(steps)
  JSON.generate({
    'summary' => 'allow-list test plan',
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

# Manual mode: approve at observed (ORIENT+DECIDE), then at proposed (ACT).
def run_plan(plan_json, budget: 'medium')
  sid = JSON.parse(START_TOOL.call({ 'goal_name' => "allow_#{SecureRandom.hex(3)}",
                                     'risk_budget' => budget })[0][:text])['session_id']
  MockLlmCall.clear!
  MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue({ 'content' => plan_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })
  MockLlmCall.queue({ 'content' => '{"confidence":0.5}', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  JSON.parse(STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })[0][:text])
end

def marked_ids(task)
  Array(task['steps']).select { |s| s['requires_human_cognition'] == true }.map { |s| s['step_id'] }
end

# ------------------------------------------------------------------

section '1. The table is in force only by the latest attested ruling on its exact bytes'

assert('no ruling: the table is empty and says why') do
  e = AC.load_effective
  e['status'] == 'no_ruling' && e['tools'].empty? && e['sha256'] == AC.sha256_of(AC::BASE_PATH)
end

r_wrong = rule!('activate', typed: 'zzzzzz')
assert('a mistyped nonce records nothing') { r_wrong['recorded'] == false && MEM.blocks.empty? }
assert('...and the table stays empty') { AC.load_effective['status'] == 'no_ruling' }

r_ok = rule!('activate')
assert('the typed nonce records an attested ruling naming the file hash') do
  rec = r_ok['record']
  r_ok['recorded'] && rec['attested'] == true && rec['attestation'] == 'terminal_nonce' &&
    rec['sha256'] == AC.sha256_of(AC::BASE_PATH) && rec['table'] == AC::TABLE_ID
end
assert('the table is then in force, with the base tools') do
  e = AC.load_effective
  e['status'] == 'in_force' && e['tools'].key?('safe_file_write') && e['tools'].key?('knowledge_get')
end
assert('the nonce itself is never recorded') { !MEM.blocks.last.data.first.include?('nonce_value') }

EDITED = File.join(TMPDIR, 'edited_table.yml')
File.write(EDITED, File.read(AC::BASE_PATH) + "  safe_http_get: { effect: read_only }\n")
assert('a table whose bytes differ from the ruled hash is not in force (an act-authored widening)') do
  e = AC.load_effective(path: EDITED)
  e['status'] == 'hash_mismatch' && e['tools'].empty?
end

rule!('withdraw')
assert('a later withdrawal takes the table out of force') { AC.load_effective['status'] == 'withdrawn' }
assert('an earlier ruling naming these same bytes does not revive the withdrawn table') do
  AC.load_effective['tools'].empty?
end
rule!('activate')
assert('a later activation supersedes the withdrawal') { AC.load_effective['status'] == 'in_force' }

assert('an unattested ruling-shaped record is ignored') do
  rulings = [{ 'kind' => AC::RULING_KIND, 'table' => AC::TABLE_ID, 'action' => 'activate',
               'sha256' => AC.sha256_of(EDITED), 'attested' => false }]
  AC.load_effective(path: EDITED, rulings: rulings)['status'] == 'no_ruling'
end

invalid = {
  'a record-store writer' => "tools:\n  chain_record: { effect: read_only }\n",
  'a file-route tool' => "tools:\n  Edit: { effect: reversible_local }\n",
  'an L1 store writer' => "tools:\n  knowledge_update: { effect: session_record }\n",
  'a configuration writer (pattern)' => "tools:\n  hermes_ask: { effect: llm_sandboxed }\n",
  'an inadmissible effect' => "tools:\n  safe_git_push: { effect: outward }\n",
  'malformed locations' => "tools:\n  safe_file_read: { effect: read_only, locations: path }\n"
}
invalid.each do |what, yaml|
  path = File.join(TMPDIR, "invalid_#{SecureRandom.hex(3)}.yml")
  File.write(path, yaml)
  rulings = [{ 'kind' => AC::RULING_KIND, 'table' => AC::TABLE_ID, 'action' => 'activate',
               'sha256' => AC.sha256_of(path), 'attested' => true }]
  assert("a ruled table admitting #{what} is refused as invalid") do
    e = AC.load_effective(path: path, rulings: rulings)
    e['status'] == 'invalid' && e['tools'].empty?
  end
end
assert('the terminal ruling refuses to record an invalid table') do
  path = File.join(TMPDIR, 'invalid_rule.yml')
  File.write(path, invalid['a record-store writer'])
  before = MEM.blocks.size
  r = rule!('activate', path: path)
  r['recorded'] == false && MEM.blocks.size == before
end
assert('an unreadable chain empties the table') do
  e = AC.load_effective(rulings: nil, rulings_error: 'chain corrupt')
  e['status'] == 'chain_unreadable' && e['tools'].empty?
end

section '2. Unclassified steps are marked for the operator; risk is resolved, never lowered'

IN_FORCE = AC.load_effective
t, aside = AC.apply({ 'steps' => [step('s1', 'knowledge_get'), step('s2', 'knowledge_update'),
                                  step('s3', 'Bash'), step('s4', nil)] }, IN_FORCE)
assert('classified steps are not marked') { !marked_ids(t).include?('s1') }
assert('an unclassified tool, a file-route tool and a tool-less step are marked') do
  %w[s2 s3 s4].all? { |id| marked_ids(t).include?(id) } && aside.map { |a| a['step_id'] } == %w[s2 s3 s4]
end
ACCEPT_SCOPE = ->(_step) { true }
t2, = AC.apply({ 'steps' => [step('a', 'knowledge_get', risk: 'high'), step('b', 'safe_file_write', risk: 'low')] },
               IN_FORCE, write_scope: ACCEPT_SCOPE)
assert("the plan's label raises a classified step's risk") { t2['steps'][0]['risk'] == 'high' }
assert("...and never lowers it below the table's") { t2['steps'][1]['risk'] == 'medium' }
t3, aside3 = AC.apply({ 'steps' => [step('w', 'safe_file_write'), step('r', 'safe_file_read')] }, IN_FORCE,
                       guard: true, write_scope: ACCEPT_SCOPE)
assert('under the guard a work-tree write is set aside; a read is not') do
  marked_ids(t3) == ['w'] && aside3.size == 1
end
assert('the original plan is not modified') do
  orig = { 'steps' => [step('x', 'knowledge_update')] }
  AC.apply(orig, IN_FORCE)
  orig['steps'][0]['requires_human_cognition'] == false
end

section '3. Through agent_step: one route, the set-aside list, the risk gate'

execute_before = MockAgentExecute.calls
r_file = run_plan(plan([step('s1', 'knowledge_get', { 'name' => 'x' }),
                        step('s2', 'Edit', { 'file_path' => 'docs/a.md' })]))
assert('a plan naming a file-route tool never reaches agent_execute') { MockAgentExecute.calls == execute_before }
assert('...it runs in-process with that step marked for the operator') do
  marked_ids(MockAutoexecPlan.last) == ['s2']
end
assert('manual mode returns the set-aside steps as a list') do
  Array(r_file['awaiting_operator']).map { |d| d['step_id'] } == ['s2']
end
assert('the response says the table is in force and how many steps were set aside') do
  r_file.dig('classification', 'status') == 'in_force' && r_file.dig('classification', 'set_aside') == 1
end

rule!('withdraw')
r_none = run_plan(plan([step('s1', 'knowledge_get', { 'name' => 'x' })]))
assert('with no table in force every step is set aside') { marked_ids(MockAutoexecPlan.last) == ['s1'] }
assert('...and the response names the status and the remedy') do
  r_none.dig('classification', 'status') == 'withdrawn' &&
    r_none.dig('classification', 'remedy').to_s.include?('agent_rule.rb activate')
end
rule!('activate')

r_risk = run_plan(plan([step('s1', 'safe_file_write', { 'path' => 'docs/drafts/draft_n.md', 'content' => 'x' })]), budget: 'low')
assert('a classified work-tree write over a low budget pauses at the risk gate') { r_risk['state'] == 'paused_risk' }

r_unc = run_plan(plan([step('s1', 'knowledge_update', { 'name' => 'x', 'content' => 'y' }, risk: 'high')]),
                 budget: 'low')
assert('an unclassified high-risk step does not pause the plan: it is set aside instead') do
  r_unc['state'] != 'paused_risk' && marked_ids(MockAutoexecPlan.last) == ['s1']
end

r_raise = run_plan(plan([step('s1', 'knowledge_get', { 'name' => 'x' }, risk: 'medium')]), budget: 'low')
assert("a read labelled medium by the plan pauses under a low budget (the label raises)") do
  r_raise['state'] == 'paused_risk'
end

protected = {
  'a private key under keys/' => 'keys/mmp_keypair.pem',
  'a .pem anywhere' => 'docs/server.pem',
  'an ssh private key name' => 'docs/id_ed25519',
  'a leading ~' => '~/proj/docs/drafts/draft_x.md',
  'a git hook' => '.git/hooks/pre-commit',
  'git config' => '.git/config',
  'a CI workflow' => '.github/workflows/ci.yml',
  'editor tasks' => '.vscode/tasks.json',
  'cursor rules' => '.cursor/rules/x.mdc',
  'gemini settings' => '.gemini/settings.json',
  'direnv' => '.envrc',
  'a nested .envrc' => 'docs/.envrc',
  '.cursorrules' => '.cursorrules'
}
protected['any file under keys/'] = 'keys/notes.txt'
protected['a dotenv file'] = 'docker/.env'
protected['a nested .env.local'] = 'web/app/.env.local'
protected['a hidden directory'] = 'home/.aws/credentials'
protected.each do |what, path|
  before = MockAutoexecPlan.calls
  ENV['HOME'] = TMPDIR if path.start_with?('~')
  r = run_plan(plan([step('s1', 'safe_file_write', { 'path' => path, 'content' => '#!/bin/sh' })]))
  ENV['HOME'] = ORIG_HOME
  assert("a write to #{what} is refused before ACT") do
    MockAutoexecPlan.calls == before && r['act_error'].to_s.include?('protected location')
  end
end

assert('complexity signals read the location names the table gives (path, source, destination)') do
  c = STEP_TOOL.send(:assess_decision_complexity, JSON.parse(plan([
    step('s1', 'safe_file_write', { 'path' => 'KairosChain_mcp_server/lib/kairos_mcp/x.rb' }),
    step('s2', 'safe_file_copy', { 'source' => 'a.md', 'destination' => 'b.md' }),
    step('s3', 'safe_file_edit', { 'path' => 'c.md' })
  ])))
  c[:signals].include?('core_files') && c[:signals].include?('multi_file')
end

section '3b. Work-tree writes are allowed by place: write_roots and write_extensions'

assert('the base table names docs/drafts, .md/.txt and the draft_ prefix') do
  IN_FORCE['write_roots'] == ['docs/drafts'] && IN_FORCE['write_extensions'] == %w[.md .txt] &&
    IN_FORCE['write_name_prefix'] == 'draft_'
end
{
  'a draft in docs/drafts' => ['docs/drafts/draft_a.md', false],
  'a .txt in a subdirectory of drafts' => ['docs/drafts/sub/draft_b.txt', false],
  'a draft without the prefix' => ['docs/drafts/a.md', true],
  'CLAUDE.local.md inside drafts' => ['docs/drafts/CLAUDE.local.md', true],
  'GEMINI.md in a subdirectory of drafts' => ['docs/drafts/sub/GEMINI.md', true],
  'AGENTS.override.md inside drafts' => ['docs/drafts/AGENTS.override.md', true],
  'a draft under a hidden directory' => ['docs/drafts/.clinerules/draft_x.md', true],
  'a hidden draft' => ['docs/drafts/.draft_x.md', true],
  'a document outside drafts' => ['docs/a.md', true],
  'Ruby code inside drafts' => ['docs/drafts/draft_x.rb', true],
  'an editor add-on path inside drafts (Ruby LSP addon.rb)' => ['docs/drafts/ruby_lsp/kc/addon.rb', true],
  'CLAUDE.local.md at the root' => ['CLAUDE.local.md', true],
  'a pre-commit config' => ['.pre-commit-config.yaml', true],
  'the drafts directory itself' => ['docs/drafts', true]
}.each do |what, (path, set_aside)|
  run_plan(plan([step('s1', 'safe_file_write', { 'path' => path, 'content' => 'x' })]))
  assert("#{what}: #{set_aside ? 'set aside' : 'runs'}") do
    marked_ids(MockAutoexecPlan.last) == (set_aside ? ['s1'] : [])
  end
end
run_plan(plan([step('s1', 'safe_file_copy', { 'source' => 'docs/drafts/draft_a.md', 'destination' => 'docs/draft_b.md' })]))
assert('a copy whose destination is outside drafts is set aside') { marked_ids(MockAutoexecPlan.last) == ['s1'] }
run_plan(plan([step('s1', 'safe_file_write', { 'workspace_root' => File.join(PROJECT, 'docs', 'drafts'),
                                               'path' => 'draft_a.md', 'content' => 'x' })]))
assert('a relative path is judged from every root a tool may use, not only the plan\'s own') do
  marked_ids(MockAutoexecPlan.last) == ['s1']
end

ADM = KairosMcp::SkillSets::Agent::Admission
DRAFTS = File.join(PROJECT, 'docs', 'drafts')
FileUtils.mkdir_p(DRAFTS)
FileUtils.mkdir_p(File.join(PROJECT, 'secret'))
File.symlink(File.join(PROJECT, 'secret'), File.join(DRAFTS, 'link'))
scope = lambda do |args|
  ADM.within_write_scope?(args, ['docs/drafts'], %w[.md], [PROJECT], project_root: PROJECT, name_prefix: 'draft_')
end
assert('a symlink inside drafts that leads outside is not inside') do
  !scope.call({ 'path' => 'docs/drafts/link/draft_x.md' })
end
FileUtils.mkdir_p(File.join(DRAFTS, 'ruby_lsp', 'kc'))
File.write(File.join(DRAFTS, 'ruby_lsp', 'kc', 'addon.rb'), '# x')
File.symlink(File.join(DRAFTS, 'ruby_lsp', 'kc', 'addon.rb'), File.join(DRAFTS, 'draft_alias.md'))
assert('a draft_*.md link whose target is not a draft document is not inside') do
  !scope.call({ 'path' => 'docs/drafts/draft_alias.md' })
end
assert('a different spelling of the root is not inside: the path must be written as the root is') do
  !scope.call({ 'path' => 'DOCS/Drafts/draft_y.md' })
end
# With HOME at the test root, '~/proj/...' expands into the project: the case
# where the check and the tool would disagree about where the file lands.
ENV['HOME'] = TMPDIR
assert('a leading ~ is not inside, even when it expands into the drafts directory') do
  !scope.call({ 'path' => '~/proj/docs/drafts/draft_y.md' })
end
ENV['HOME'] = ORIG_HOME
assert('an absolute path is not inside, even one that names the drafts directory') do
  !scope.call({ 'path' => File.join(DRAFTS, 'draft_y.md') })
end
assert('a root argument beside the path makes the step not inside') do
  !scope.call({ 'path' => 'docs/drafts/draft_y.md', 'workspace_root' => PROJECT })
end
assert('a backslash, an empty segment or a ./ segment is not inside') do
  ['docs\\drafts\\draft_y.md', 'docs/drafts//draft_y.md', 'docs/drafts/./draft_y.md'].none? { |p| scope.call({ 'path' => p }) }
end
FileUtils.mkdir_p(File.join(DRAFTS, 'visible'))
File.symlink(File.join(DRAFTS, 'visible'), File.join(DRAFTS, '.clinerules'))
assert('a hidden name as written is not inside even when it resolves to a visible directory') do
  !scope.call({ 'path' => 'docs/drafts/.clinerules/draft_x.md' })
end
assert('a plain draft path is inside') { scope.call({ 'path' => 'docs/drafts/visible/draft_x.md' }) }
assert('a step that names no location is not inside') { !scope.call({ 'content' => 'x' }) }
assert('a NUL byte is not inside, and does not raise') { !scope.call({ 'path' => "docs/drafts/draft_\0.md" }) }

{
  'a reversible_local row with no write_roots' => "tools:\n  safe_file_write: { effect: reversible_local, locations: [path] }\nwrite_extensions: [.md]\n",
  'an absolute write root' => "write_roots: [/tmp]\nwrite_extensions: [.md]\ntools:\n  knowledge_get: { effect: read_only }\n",
  'a write root with ..' => "write_roots: [docs/../..]\nwrite_extensions: [.md]\ntools:\n  knowledge_get: { effect: read_only }\n",
  'a write root inside .git' => "write_roots: [.git/hooks]\nwrite_extensions: [.md]\ntools:\n  knowledge_get: { effect: read_only }\n",
  'an extension without a dot' => "write_roots: [docs/drafts]\nwrite_extensions: [md]\ntools:\n  knowledge_get: { effect: read_only }\n",
  'the project itself as a write root' => "write_roots: [.]\nwrite_extensions: [.md]\ntools:\n  knowledge_get: { effect: read_only }\n",
  'a control character in a write root' => "write_roots: [\"docs/\\0drafts\"]\nwrite_extensions: [.md]\ntools:\n  knowledge_get: { effect: read_only }\n",
  'a reversible_local row with no name prefix' => "write_roots: [docs/drafts]\nwrite_extensions: [.md]\ntools:\n  safe_file_write: { effect: reversible_local, locations: [path] }\n"
}.each do |what, yaml|
  _, error = AC.parse_table(yaml)
  assert("a table with #{what} is invalid") { !error.nil? }
end

section '3c. Risk: the plan default, unknown labels, and the gate key'

r_default = run_plan(JSON.generate(JSON.parse(plan([{ 'step_id' => 's1', 'action' => 'read', 'tool_name' => 'knowledge_get',
                                                      'tool_arguments' => { 'name' => 'x' }, 'depends_on' => [],
                                                      'requires_human_cognition' => false }]))
                                     .tap { |p| p['task_json']['meta']['risk_default'] = 'high' }),
                     budget: 'medium')
assert("a step with no risk takes the plan's risk_default (high pauses under medium)") do
  r_default['state'] == 'paused_risk'
end
t_label, = AC.apply({ 'steps' => [step('a', 'knowledge_get', risk: 'High'), step('b', 'knowledge_get', risk: 'critical')] },
                    IN_FORCE)
assert('a label in another case, or not a known level, counts as high') do
  t_label['steps'].map { |st| st['risk'] } == %w[high high]
end
MANDATE = ::Autonomos::Mandate
assert("the gate ignores a plan-supplied 'resolved_risk' string key") do
  raw = { autoexec_task: { enforce_human_marks: true,
                           steps: [{ risk: 'low', tool_name: 'knowledge_update', 'resolved_risk' => 'low',
                                     requires_human_cognition: false }] },
          selected_gap: { description: 'x' } }
  MANDATE.risk_exceeds_budget?(raw, 'low')
end

section '3d. Every path that runs an act hands over the set-aside list'

MIXED = plan([step('s1', 'knowledge_get', { 'name' => 'x' }, risk: 'medium'),
              step('s2', 'knowledge_update', { 'name' => 'x', 'content' => 'y' })])

def raise_budget(sid)
  m = MANDATE.load(Session.load(sid).mandate_id)
  m[:risk_budget] = 'medium'
  MANDATE.save(m[:mandate_id], m)
end

paused = run_plan(MIXED, budget: 'low')
sid_m = paused['session_id']
raise_budget(sid_m)
MockLlmCall.queue({ 'content' => '{"confidence":0.5}', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
r_resume = JSON.parse(STEP_TOOL.call({ 'session_id' => sid_m, 'action' => 'approve' })[0][:text])
assert('manual: the paused plan first stopped at the risk gate') { paused['state'] == 'paused_risk' }
assert('manual: resuming from the risk pause returns the set-aside list and the table state') do
  Array(r_resume['awaiting_operator']).map { |d| d['step_id'] } == ['s2'] &&
    r_resume.dig('classification', 'status') == 'in_force'
end

sid_a = JSON.parse(START_TOOL.call({ 'goal_name' => "allow_auto_#{SecureRandom.hex(3)}", 'risk_budget' => 'low',
                                     'autonomous' => true, 'max_cycles' => 2 })[0][:text])['session_id']
MockLlmCall.clear!
MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
MockLlmCall.queue({ 'content' => MIXED, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
a_paused = JSON.parse(STEP_TOOL.call({ 'session_id' => sid_a, 'action' => 'approve' })[0][:text])
raise_budget(sid_a)
MockLlmCall.queue({ 'content' => '{"confidence":0.5}', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
a_resume = JSON.parse(STEP_TOOL.call({ 'session_id' => sid_a, 'action' => 'approve' })[0][:text])
assert('autonomous: the plan first paused at the risk gate') { a_paused['state'] == 'paused_risk' }
assert('autonomous: the resumed cycle stops with the list instead of cycling on') do
  a_resume['status'] == 'checkpoint' && a_resume['cycles_completed'] == 1 &&
    Array(a_resume['awaiting_operator']).map { |d| d['step_id'] } == ['s2']
end

MockAutoexecRun.halt_first = true
r_halt = run_plan(plan([step('s1', 'knowledge_get', { 'name' => 'x' }), step('s2', 'knowledge_update', { 'name' => 'x' }),
                        step('s3', 'knowledge_get', { 'name' => 'y' }, depends_on: ['s2'])]))
MockAutoexecRun.halt_first = false
assert('a set-aside step the run never reached is still handed to the operator') do
  Array(r_halt['awaiting_operator']).any? { |d| d['step_id'] == 's2' && d['status'] == 'not_reached' }
end
assert('...and so is a step that depends on it') do
  Array(r_halt['awaiting_operator']).any? { |d| d['step_id'] == 's3' && d['status'] == 'blocked_by_not_reached' }
end
assert('the summary stays autoexec\'s own (halted), not the operator list') { r_halt['act_summary'] == 'halted' }

MockAutoexecRun.halt_at = 'f'
r_after = run_plan(plan([step('d', 'knowledge_update', { 'name' => 'x' }), step('f', 'knowledge_get', { 'name' => 'x' }),
                         step('e', 'knowledge_get', { 'name' => 'y' }, depends_on: ['d']),
                         step('g', 'knowledge_get', { 'name' => 'z' }, depends_on: ['e'])]))
MockAutoexecRun.halt_at = nil
assert('after a halt, dependents of a step autoexec already set aside are listed too (transitively)') do
  ids = Array(r_after['awaiting_operator']).map { |d| d['step_id'] }
  ids.include?('d') && ids.include?('e') && ids.include?('g') && !ids.include?('f')
end

{ 'a secret in a dotenv file' => 'Echoria/docker/.env', 'a private key' => 'keys/mmp_keypair.pem' }.each do |what, path|
  before = MockAutoexecPlan.calls
  r = run_plan(plan([step('s1', 'safe_file_read', { 'path' => path })]))
  assert("a read of #{what} is refused before ACT") do
    MockAutoexecPlan.calls == before && r['act_error'].to_s.include?('protected location')
  end
end

assert('DECIDE is told the write place and the hidden-name rule') do
  brief = STEP_TOOL.send(:act_route_brief)
  brief.include?('docs/drafts/draft_notes.md') && brief.include?('name starting draft_') &&
    brief.include?("starting with '.' is refused")
end
assert('an autonomous stop for set-aside steps carries the act error with the list') do
  r = JSON.parse(STEP_TOOL.send(:autonomous_act_stop, Session.load(sid_m),
                                { act: { 'deferred' => [{ 'step_id' => 's9' }] }, act_error: 'step s1 failed' }, [])[0][:text])
  r['state'] == 'checkpoint' && r['error'] == 'step s1 failed' && Array(r['awaiting_operator']).size == 1
end
assert('a guard-halt response carries the set-aside list and the table state') do
  resp = STEP_TOOL.send(:guard_halt_response, Session.load(sid_m),
                        { act: { 'deferred' => [{ 'step_id' => 's9' }], 'classification' => { 'status' => 'in_force' } },
                          guard_verdict: {} })
  Array(resp['awaiting_operator']).map { |d| d['step_id'] } == ['s9'] && resp.dig('classification', 'status') == 'in_force'
end

section '4. The real chain, and the terminal requirement (subprocesses)'

RUBY = RbConfig.ruby
SERVER_LIB = File.expand_path('../../../../lib', __dir__)
BIN = File.expand_path('../bin/agent_rule.rb', __dir__)
REAL = Dir.mktmpdir('agent_allowlist_real')

writer = <<~RB
  require 'kairos_mcp'; require 'kairos_mcp/kairos_chain/chain'; require 'stringio'
  KairosMcp.data_dir = #{REAL.inspect}
  lib = #{File.expand_path('../lib', __dir__).inspect}
  %w[admission mandate_adapter act_classification].each { |f| require File.join(lib, 'agent', f) }
  ac = KairosMcp::SkillSets::Agent::ActClassification
  r = ac.interactive_rule(action: 'activate', tty_in: StringIO.new("abc123\\n"), tty_out: StringIO.new,
                          nonce_value: 'abc123')
  puts r['recorded']
RB
w_out = IO.popen({ 'RUBYLIB' => SERVER_LIB }, [RUBY, '-e', writer], err: %i[child out], &:read)
assert('a ruling appended through the real chain is recorded') { w_out.strip.end_with?('true') }

s_out = IO.popen({ 'KAIROS_SERVER_LIB' => SERVER_LIB }, [RUBY, BIN, 'status', '--data-dir', REAL],
                 err: %i[child out], &:read)
assert('agent_rule.rb status reads it back from the real chain as in force') do
  s_out.include?('act_classification: in_force') && s_out.include?('safe_file_write')
end

# A process with no controlling terminal: /dev/tty cannot be opened.
rd, wr = IO.pipe
pid = fork do
  Process.setsid
  rd.close
  $stdout.reopen(wr)
  $stderr.reopen(wr)
  $stdin.reopen(File::NULL)
  ENV['KAIROS_SERVER_LIB'] = SERVER_LIB
  exec(RUBY, BIN, 'activate', '--data-dir', REAL)
end
wr.close
no_tty_out = rd.read
Process.wait(pid)
no_tty_status = $?.exitstatus
assert('agent_rule.rb activate refuses without a terminal and records nothing') do
  no_tty_status != 0 && no_tty_out.include?('needs a terminal')
end

Dir.chdir(ORIG_PWD)
FileUtils.rm_rf(TMPDIR)
FileUtils.rm_rf(REAL)

puts "\n#{'=' * 60}\nRESULTS: #{$pass} passed, #{$fail} failed\n#{'=' * 60}"
exit($fail.zero? ? 0 : 1)
