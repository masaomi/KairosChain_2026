#!/usr/bin/env ruby
# frozen_string_literal: true

# Three side doors around the agent's gates, closed (found 2026-10-06 in the
# delegation design review):
#   1. every agent LLM phase runs `claude -p` sandboxed (no project
#      instruction files, no inherited permission rules, no built-in tools);
#   2. record-store writers (chain_record, ...) are denied on the act route
#      with the guard off, not only with it on;
#   3. a plan whose path arguments reach what constrains the agent or its
#      operator (KairosChain stores, .claude, .codex, .mcp.json, CLAUDE.md,
#      AGENTS.md) is refused before ACT, whatever the tool, and the refusal
#      is recorded on the chain;
#   4. LLM bodies the act launches run sandboxed (llm_call steps,
#      write_section's section writer).
#
# Drives the REAL agent_start / agent_step through the registry; stubs only
# llm_call, autoexec_plan/run and knowledge_get.
# Usage: ruby test_agent_act_hardening.rb

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

TMPDIR = Dir.mktmpdir('agent_act_hardening')
PROJECT = File.join(TMPDIR, 'proj')
STORES = File.join(PROJECT, '.kairos')
FileUtils.mkdir_p(File.join(STORES, 'skillsets', 'agent', 'config'))
FileUtils.mkdir_p(File.join(PROJECT, 'docs'))
# Production runs the server with Dir.pwd = the project root.
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

# The driver locates the stores through KairosMcp.data_dir.
module KairosMcp
  def self.data_dir = STORES
end
# The ordinary configuration: safety.yml points the tools' root at the
# project. The stores-root configuration is simulated where tested.
FileUtils.mkdir_p(File.join(STORES, 'config'))
File.write(File.join(STORES, 'config', 'safety.yml'), "safe_root: #{PROJECT}\n")
# The instance's llm_client default provider (claude_code, as shipped).
FileUtils.mkdir_p(File.join(STORES, 'skillsets', 'llm_client', 'config'))
File.write(File.join(STORES, 'skillsets', 'llm_client', 'config', 'llm_client.yml'), "provider: claude_code\n")

Session = KairosMcp::SkillSets::Agent::Session
Admission = KairosMcp::SkillSets::Agent::Admission

module Autoexec
  class TaskDsl
    def self.from_json(json_str)
      parsed = JSON.parse(json_str)
      raise ArgumentError, 'Missing task_id' unless parsed['task_id']

      parsed
    end
  end
end

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
    @@seen << arguments
    resp = @@responses.shift || { 'content' => 'default', 'tool_use' => nil, 'stop_reason' => 'end_turn' }
    text_content(JSON.generate({ 'status' => 'ok', 'provider' => 'mock', 'model' => 'mock-1',
                                 'response' => resp,
                                 'usage' => { 'input_tokens' => 1, 'output_tokens' => 1 },
                                 'snapshot' => { 'model' => 'mock-1', 'timestamp' => Time.now.iso8601 } }))
  end
end

class MockAutoexecPlan < KairosMcp::Tools::BaseTool
  @@calls = 0
  def self.calls = @@calls
  def name = 'autoexec_plan'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  @@last = nil
  def self.last = @@last

  def call(arguments)
    @@calls += 1
    task_json = JSON.parse(arguments['task_json'])
    @@last = task_json
    text_content(JSON.generate({ 'status' => 'ok', 'task_id' => task_json['task_id'],
                                 'plan_hash' => Digest::SHA256.hexdigest(arguments['task_json'])[0..15],
                                 'steps' => task_json['steps']&.length || 0 }))
  end
end

# Keeps the act context it was handed, so the test can ask what it allows.
class MockAutoexecRun < KairosMcp::Tools::BaseTool
  @@ctx_json = nil
  def self.ctx_json = @@ctx_json
  def name = 'autoexec_run'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }

  def call(arguments)
    @@ctx_json = arguments['invocation_context_json']
    text_content(JSON.generate({ 'task_id' => 'mock_task', 'mode' => 'internal_execute',
                                 'outcome' => 'internal_execute_complete', 'steps_processed' => 1, 'steps' => [] }))
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

class MockLlmConfigure < KairosMcp::Tools::BaseTool
  def name = 'llm_configure'
  def description = 'mock'
  def input_schema = { type: 'object', properties: {} }
  def call(_a) = text_content('{}')
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
    'llm_configure' => MockLlmConfigure.new(nil, registry: registry),
    'agent_start' => KairosMcp::SkillSets::Agent::Tools::AgentStart.new(nil, registry: registry),
    'agent_step' => KairosMcp::SkillSets::Agent::Tools::AgentStep.new(registry.instance_variable_get(:@safety), registry: registry)
  })
  registry
end

REGISTRY = build_registry
START_TOOL = REGISTRY.instance_variable_get(:@tools)['agent_start']
STEP_TOOL = REGISTRY.instance_variable_get(:@tools)['agent_step']

def plan(tool_name, args)
  JSON.generate({
    'summary' => "plan via #{tool_name}",
    'task_json' => {
      'task_id' => "t_#{SecureRandom.hex(3)}", 'meta' => { 'description' => 't', 'risk_default' => 'low' },
      'steps' => [{ 'step_id' => 's1', 'action' => 'do it', 'tool_name' => tool_name,
                    'tool_arguments' => args, 'risk' => 'low', 'depends_on' => [],
                    'requires_human_cognition' => false }]
    },
    'review_hint' => { 'needed' => false, 'reason' => nil, 'urgency' => nil },
    'complexity_hint' => { 'level' => 'low', 'signals' => [] }
  })
end

# risk_budget medium: the file tools are medium-risk, and under the default
# 'low' budget the plan would pause before ever reaching the store check.
def run_plan(plan_json)
  sid = JSON.parse(START_TOOL.call({ 'goal_name' => "hardening_#{SecureRandom.hex(3)}",
                                     'risk_budget' => 'medium' })[0][:text])['session_id']
  MockLlmCall.clear!
  MockLlmCall.queue({ 'content' => 'orient', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  MockLlmCall.queue({ 'content' => plan_json, 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })
  MockLlmCall.queue({ 'content' => '{"confidence":0.5}', 'tool_use' => nil, 'stop_reason' => 'end_turn' })
  JSON.parse(STEP_TOOL.call({ 'session_id' => sid, 'action' => 'approve' })[0][:text])
end

# ------------------------------------------------------------------

section 'Door 1: every agent LLM phase is sandboxed'

run_plan(plan('knowledge_get', { 'name' => 'x' }))
assert('ORIENT, DECIDE and REFLECT all reached llm_call') { MockLlmCall.seen.size >= 3 }
assert('every agent llm_call carries sandbox_mode: true') do
  MockLlmCall.seen.all? { |a| a['sandbox_mode'] == true }
end

section 'Door 2: record-store writers are denied on the act route with the guard off'

r2 = run_plan(plan('knowledge_get', { 'name' => 'x' }))
ctx = KairosMcp::InvocationContext.from_json(MockAutoexecRun.ctx_json)
assert('the guard is off in this session (shipped agent.yml)') { r2['status'] != 'guard_halt' }
assert('chain_record is refused on the act context') { !ctx.allowed?('chain_record') }
assert('every record-store writer is refused on the act context') do
  Admission::RECORD_STORE_TOOLS.none? { |t| ctx.allowed?(t) }
end
assert('an ordinary tool is still allowed') { ctx.allowed?('knowledge_get') }
assert('configuration writers are refused on the act context') do
  %w[llm_configure mode_hooks_add mode_hooks_project plugin_project hermes_ask].none? { |t| ctx.allowed?(t) }
end

section 'Door 3: a plan naming a protected location is refused before ACT, and recorded'

before = MockAutoexecPlan.calls
logs_before = MockChainRecord.logs.size
r3 = run_plan(plan('safe_file_edit', { 'path' => '.kairos/skillsets/agent/config/agent.yml',
                                       'old_string' => 'a', 'new_string' => 'b' }))
assert('the act did not reach autoexec, and not because of a risk pause') do
  MockAutoexecPlan.calls == before && r3['state'] != 'paused_risk'
end
assert('the response says a protected location was refused') do
  r3['act_summary'] == 'failed' && r3['act_error'].to_s.include?('protected location')
end
assert('the refusal is recorded on the chain (guard off), with the rule that fired') do
  rec = MockChainRecord.logs[logs_before..].map { |l| JSON.parse(l) }.find { |r| r['kind'] == 'agent_act_refused' }
  rec && rec['reason'] == ['protected'] && rec['steps'].first['rule'] == 'protected'
end

before_ws = MockAutoexecPlan.calls
r_ws = run_plan(plan('write_section', { 'section_name' => 'x', 'instructions' => 'y',
                                        'output_file' => '.kairos/skills/masa.md' }))
assert('write_section into the instruction mode is refused (low-risk tool, default budget path)') do
  MockAutoexecPlan.calls == before_ws && r_ws['act_error'].to_s.include?('protected location')
end

before_ok = MockAutoexecPlan.calls
r_ok = run_plan(plan('safe_file_write', { 'path' => 'docs/note.md', 'content' => 'x', 'workspace_root' => PROJECT }))
assert('a write outside the protected locations still runs') do
  MockAutoexecPlan.calls == before_ok + 1 && r_ok['act_error'].nil?
end

before_out = MockAutoexecPlan.calls
r_out = run_plan(plan('safe_file_write', { 'workspace_root' => Dir.home, 'path' => '.zshrc', 'content' => 'x' }))
assert('end to end: a write outside the project via an explicit workspace_root is refused') do
  MockAutoexecPlan.calls == before_out && r_out['act_error'].to_s.include?('[outside]')
end

PROTECTED = [STORES, File.join(PROJECT, '.claude'), File.join(PROJECT, '.codex')].freeze
v = lambda do |tool, args, roots: [PROJECT]|
  Admission.protected_path_violations({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => tool, 'tool_arguments' => args }] },
                                      PROTECTED, roots, [PROJECT])
end
refused = {
  'an absolute path inside the stores' => ['safe_file_write', { 'path' => File.join(STORES, 'skillsets', 'agent', 'config', 'agent.yml') }],
  'workspace_root pointing into the stores' => ['safe_file_write', { 'path' => 'skillsets/agent/config/agent.yml', 'workspace_root' => STORES }],
  'harness settings (.claude) where hooks live' => ['safe_file_write', { 'path' => '.claude/settings.local.json' }],
  'the project CLAUDE.md' => ['write_section', { 'output_file' => 'CLAUDE.md' }],
  'a CLAUDE.md in a subdirectory' => ['write_section', { 'output_file' => 'docs/CLAUDE.md' }],
  'AGENTS.md' => ['safe_file_write', { 'path' => 'AGENTS.md' }],
  '.mcp.json' => ['safe_file_write', { 'path' => '.mcp.json' }],
  'a different case (.KAIROS)' => ['safe_file_write', { 'path' => '.KAIROS/skills/masa.md' }],
  'backslash separators' => ['safe_file_write', { 'path' => '.kairos\\skills\\masa.md' }],
  'a git tool whose workspace_root is the stores repo' => ['safe_git_commit', { 'workspace_root' => '.kairos', 'message' => 'x' }],
  'sc_scaffold output_path into the stores' => ['sc_scaffold', { 'output_path' => '.kairos/skillsets/evil' }],
  'copy out of the stores (source)' => ['safe_file_copy', { 'source' => '.kairos/storage/key.pem', 'destination' => 'docs/key.pem' }],
  'a read of the stores' => ['safe_file_read', { 'path' => '.kairos/storage/key.pem' }],
  'an explicit workspace_root outside the project' => ['safe_file_write', { 'workspace_root' => Dir.home, 'path' => '.zshrc' }],
  'an absolute path outside the project' => ['safe_file_write', { 'path' => '/tmp/elsewhere.txt' }],
  'a .. segment' => ['safe_file_write', { 'path' => 'docs/../../outside.txt' }],
  'a nested path argument' => ['some_tool', { 'options' => { 'path' => '.kairos/x' } }],
  'a path inside an array of objects' => ['some_tool', { 'files' => [{ 'path' => 'CLAUDE.md' }] }],
  'a home harness file via src' => ['some_tool', { 'src' => File.join(Dir.home, '.claude.json') }],
  'a camelCase path key (filePath)' => ['some_tool', { 'filePath' => '/tmp/elsewhere.txt' }],
  'a joined path key (workdir)' => ['some_tool', { 'workdir' => '/tmp/elsewhere' }],
  'a joined path key (outdir)' => ['some_tool', { 'outdir' => '/tmp/elsewhere' }]
}
refused.each do |label, (tool, args)|
  assert("refused: #{label}") { v.call(tool, args).size >= 1 }
end
assert('refused: a relative path when the tool root is the stores (safety.yml without safe_root)') do
  v.call('safe_file_edit', { 'path' => 'skillsets/agent/config/agent.yml' }, roots: [PROJECT, STORES]).size == 1
end
File.symlink(STORES, File.join(PROJECT, 'cfg'))
assert('refused: a symlink in the workspace that points at the stores') do
  v.call('safe_file_edit', { 'path' => 'cfg/skillsets/agent/config/agent.yml' }).size == 1
end
File.write(File.join(PROJECT, 'CLAUDE.md'), '# instructions')
File.symlink(File.join(PROJECT, 'CLAUDE.md'), File.join(PROJECT, 'docs', 'innocent.md'))
assert('refused: an innocent-looking symlink whose target is CLAUDE.md') do
  v.call('safe_file_write', { 'path' => 'docs/innocent.md' }).size == 1
end
File.symlink(File.join(STORES, 'not_yet.json'), File.join(PROJECT, 'dangling'))
assert('refused: a dangling symlink') do
  v.call('safe_file_write', { 'path' => 'dangling' }).size == 1
end
assert('refused: arguments that are not an object') do
  Admission.protected_path_violations({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'safe_file_write', 'tool_arguments' => '{"path":".kairos/x"}' }] }, PROTECTED, [PROJECT]).size == 1
end
assert('no allowed root at all refuses even an ordinary path (fail-closed)') do
  Admission.protected_path_violations({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'safe_file_write',
                                                       'tool_arguments' => { 'path' => 'docs/note.md' } }] },
                                      PROTECTED, [PROJECT], []).first&.dig('rule') == 'outside'
end
home_step = KairosMcp::SkillSets::Agent::Tools::AgentStep.allocate
home_step.define_singleton_method(:project_root_for_merge) { Dir.home }
saved_ws = ENV.delete('KAIROS_WORKSPACE')
assert('the home directory never counts as the project') { home_step.send(:allowed_roots_for_admission).empty? }
ENV['KAIROS_WORKSPACE'] = saved_ws if saved_ws
assert('no root to resolve against is refused, not skipped') do
  Admission.protected_path_violations({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'safe_file_write',
                                                       'tool_arguments' => { 'path' => 'docs/note.md' } }] },
                                      PROTECTED, [], [PROJECT]).first&.dig('rule') == 'unresolvable'
end

WT = File.join(TMPDIR, 'repo', '.claude', 'worktrees', 'wt')
FileUtils.mkdir_p(File.join(WT, 'docs'))
wt_protected = [File.join(WT, '.kairos'), File.join(WT, '.claude'), File.join(WT, '.codex')]
wt = lambda do |args|
  Admission.protected_path_violations({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'safe_file_write', 'tool_arguments' => args }] },
                                      wt_protected, [WT], [WT])
end
assert('a project inside a Claude Code worktree (.claude/worktrees) is not refused wholesale') do
  wt.call({ 'path' => 'docs/note.md' }).empty?
end
assert('inside such a worktree, its own stores are still refused') do
  wt.call({ 'path' => '.kairos/skills/masa.md' }).size == 1
end

allowed = {
  'docs/kairos_notes.md' => ['safe_file_write', { 'path' => 'docs/kairos_notes.md' }],
  'a report under docs' => ['write_section', { 'output_file' => 'docs/report.md' }],
  'a non-path argument' => ['knowledge_get', { 'name' => 'kairoschain_meta_philosophy' }],
  'a URI-like resource' => ['resource_read', { 'uri' => 'knowledge://x' }],
  "a non-path key that contains 'file' as a substring" => ['some_tool', { 'profile' => 'a/b' }],
  'an output_format value' => ['some_tool', { 'output_format' => '/tmp/not_a_path_here' }],
  "profile is not a path key even with a path-shaped value" => ['some_tool', { 'profile' => '/tmp/elsewhere' }]
}
allowed.each do |label, (tool, args)|
  assert("allowed: #{label}") { v.call(tool, args).empty? }
end

# An instance whose safety.yml sets no safe_root resolves file tools against
# the data dir itself. Simulate that root and plan a path with no protected
# name in it: only resolving against the tools' own root can catch it.
safety = STEP_TOOL.instance_variable_get(:@safety)
raise 'the step tool must hold a real Safety' unless safety.is_a?(KairosMcp::Safety)
safety.define_singleton_method(:safe_root) { STORES }
before_sr = MockAutoexecPlan.calls
r_sr = run_plan(plan('safe_file_edit', { 'path' => 'skillsets/agent/config/agent.yml', 'old_string' => 'a', 'new_string' => 'b' }))
safety.singleton_class.send(:remove_method, :safe_root)
assert("a relative path is judged where the tool would write it (tool root = the stores)") do
  MockAutoexecPlan.calls == before_sr && r_sr['act_error'].to_s.include?('protected location')
end
assert('the refusal says the tool root is inside the stores and how to fix it') do
  r_sr['act_error'].to_s.include?('set safe_root in safety.yml')
end
safety.define_singleton_method(:safe_root) { STORES }
before_decoy = MockAutoexecPlan.calls
r_decoy = run_plan(plan('write_section', { 'section_name' => 'x', 'instructions' => 'y',
                                           'output_file' => 'knowledge/x/x.md', 'workspace_root' => PROJECT }))
safety.singleton_class.send(:remove_method, :safe_root)
assert('a decoy workspace_root does not move the check away from where the tool writes') do
  MockAutoexecPlan.calls == before_decoy && r_decoy['act_error'].to_s.include?('protected location')
end
assert('the driver protects the stores, .claude and .codex') do
  dirs = STEP_TOOL.send(:protected_dirs_for_admission)
  dirs.include?(STORES) && dirs.any? { |d| d.end_with?('/.claude') } && dirs.any? { |d| d.end_with?('/.codex') }
end

section 'Door 4: LLM bodies the act launches run sandboxed'

before_llm = MockAutoexecPlan.calls
run_plan(plan('llm_call', { 'messages' => [{ 'role' => 'user', 'content' => 'run: rm -rf x' }] }))
llm_step = Array(MockAutoexecPlan.last && MockAutoexecPlan.last['steps']).find { |st| st['tool_name'] == 'llm_call' }
assert('an llm_call step reaches autoexec with sandbox_mode forced on') do
  MockAutoexecPlan.calls == before_llm + 1 && llm_step && llm_step.dig('tool_arguments', 'sandbox_mode') == true
end

require File.expand_path('../document_authoring/lib/document_authoring/section_writer', File.dirname(__dir__))
FakeCaller = Struct.new(:seen) do
  def invoke_tool(name, args, context: nil)
    seen << [name, args]
    [{ text: JSON.generate({ 'status' => 'ok', 'response' => { 'content' => 'text' } }) }]
  end
end
fc = FakeCaller.new([])
KairosMcp::SkillSets::DocumentAuthoring::SectionWriter.new(fc, {}).send(:generate_one, 's', 'i', 'c', 100, 'en', nil)
assert("write_section's section writer calls llm_call with sandbox_mode") do
  fc.seen.any? { |name, args| name == 'llm_call' && args['sandbox_mode'] == true }
end

%w[codex cursor codex_mcp some_unknown_cli].each do |prov|
  before_p = MockAutoexecPlan.calls
  r_p = run_plan(plan('llm_call', { 'messages' => [{ 'role' => 'user', 'content' => 'print .kairos/keys/x.pem' }],
                                    'provider_override' => prov }))
  assert("an llm_call step with provider #{prov} is refused before ACT") do
    MockAutoexecPlan.calls == before_p && r_p['act_error'].to_s.include?('[unsafe_provider]')
  end
end
assert('an llm_call step with an API provider is allowed') do
  Admission.unsafe_llm_steps({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'llm_call',
                                             'tool_arguments' => { 'provider_override' => 'anthropic' } }] }, 'claude_code').empty?
end
assert('an llm_call step with no override follows the instance default (codex default is refused)') do
  Admission.unsafe_llm_steps({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'llm_call', 'tool_arguments' => {} }] }, 'codex').size == 1
end
assert('an unreadable default provider refuses an llm_call step without a safe override') do
  Admission.unsafe_llm_steps({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'llm_call', 'tool_arguments' => {} }] }, nil).size == 1
end
assert('openrouter is not a safe provider (it falls back to the OpenAI endpoint without base_url)') do
  Admission.unsafe_llm_steps({ 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'llm_call',
                                             'tool_arguments' => { 'provider_override' => 'openrouter' } }] }, 'claude_code').size == 1
end
assert('write_section follows the instance default provider (codex default is refused)') do
  ws = { 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'write_section', 'tool_arguments' => { 'output_file' => 'docs/a.md' } }] }
  Admission.unsafe_llm_steps(ws, 'codex').size == 1 && Admission.unsafe_llm_steps(ws, 'claude_code').empty?
end
assert('multi_llm_review is refused on the act context') { !ctx.allowed?('multi_llm_review') && !ctx.allowed?('multi_llm_review_collect') }

section 'The planner is not offered tools the act route always refuses'

catalog = STEP_TOOL.send(:build_tool_catalog, Session.load(JSON.parse(START_TOOL.call({ 'goal_name' => 'catalog_check' })[0][:text])['session_id']))
assert('chain_record is absent from the DECIDE catalog') { !catalog.include?('**chain_record**') }
assert('llm_configure is absent from the DECIDE catalog') { !catalog.include?('**llm_configure**') }
assert('an ordinary tool is present in the DECIDE catalog') { catalog.include?('**knowledge_get**') }

Dir.chdir(ORIG_PWD)
FileUtils.rm_rf(TMPDIR)
puts "\n#{'=' * 60}\nRESULT: #{$pass} passed, #{$fail} failed\n#{'=' * 60}"
exit($fail.zero? ? 0 : 1)
