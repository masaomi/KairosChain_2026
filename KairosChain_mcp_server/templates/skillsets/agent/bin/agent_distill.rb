#!/usr/bin/env ruby
# frozen_string_literal: true
#
# The distiller's process (distillation design v0.2, INV-K1 / INV-K4).
# Started detached by the driver after an attested, reasoned answer at a
# delegable point commits, or in the foreground by `agent_rule.rb distill`.
# Counting, the one-draft lock, the table's status and the inputs are all
# decided here, off the response path; DistillRun does the run.
#
# It loads no agent tool and never opens a session's advance lock. What it
# reads is what the operator authored and what the driver observed: the
# attested answers on the chain, the terminal-sourced reasons they name, the
# point facts they name, and the operator's changes recorded at adoption.
#
# The model is reached through llm_call as the shadow judge reaches it:
# provider claude_code with sandbox_mode, no fallback.
#
# argv: [--manual]   run whatever the count (the operator asked for it)
# env:  KAIROS_SERVER_LIB   lib dir to load kairos_mcp from
#       KAIROS_DATA_DIR     the server's data dir (the chain read and written)
#       KAIROS_PROJECT_ROOT the server's working directory (its .kairos/storage)

require 'json'

manual = ARGV.include?('--manual')

begin
  Process.setsid unless manual
rescue StandardError
  # Already a group leader (spawned with pgroup): acceptable.
end

begin
  Dir.chdir(ENV['KAIROS_PROJECT_ROOT']) if ENV['KAIROS_PROJECT_ROOT'] && Dir.exist?(ENV['KAIROS_PROJECT_ROOT'])
  $LOAD_PATH.unshift(ENV['KAIROS_SERVER_LIB']) if ENV['KAIROS_SERVER_LIB'] && !ENV['KAIROS_SERVER_LIB'].empty?
  require 'kairos_mcp'
  KairosMcp.data_dir = ENV['KAIROS_DATA_DIR'] if ENV['KAIROS_DATA_DIR'] && !ENV['KAIROS_DATA_DIR'].empty?
  require 'kairos_mcp/kairos_chain/chain'

  lib = File.expand_path('../lib', __dir__)
  %w[session admission mandate_adapter act_classification answer_ruling delegation point_facts distiller
     distill_run distiller_prompt].each { |f| require File.join(lib, 'agent', f) }
  require 'kairos_mcp/tools/base_tool'
  # agent depends on llm_client; both are installed side by side.
  require File.expand_path('../../llm_client/tools/llm_call', __dir__)
rescue ScriptError, StandardError => e
  warn JSON.generate({ 'status' => 'failed', 'reason' => "bootstrap: #{e.class}: #{e.message[0, 200]}" })
  exit 1
end

agent = KairosMcp::SkillSets::Agent
ar = agent::AnswerRuling
pf = agent::PointFacts
sessions = agent::Session.storage_path('agent_sessions')
dir = agent::Session.storage_path('agent_distill')

session_dir = lambda do |sid|
  next nil unless sid.to_s.match?(/\A[\w-]+\z/)

  d = File.join(sessions, sid.to_s)
  File.directory?(d) ? d : nil
end

# The reason the operator typed at the terminal, matched by the digest the
# ruling names. A caller's text is never the operator's reason.
reason = lambda do |sid, anchor, sha|
  d = session_dir.call(sid)
  next nil unless d

  ar.texts_at(d, anchor, source: 'terminal').map { |t| t['rationale'] }.find { |r| r && ar.sha256(r) == sha }
end

# The plans the answer covered, as the driver filed them when the answer
# committed; nil unless the filed line is the one the ruling names. An answer
# at a point always covers a plan, so an empty window is facts not recorded.
# Only what the driver observed passes: the cycle, and per step the tool and
# effect the table gave it, the unclassified count and the step count. The
# plan's own marks for a person are the agent's declaration and stay behind.
facts = lambda do |sid, anchor, sha|
  d = session_dir.call(sid)
  next nil unless d

  entry, line_sha = pf.answer_facts(d, anchor)
  plans = entry && line_sha == sha ? entry['plans'] : nil
  next nil unless plans.is_a?(Array) && !plans.empty?
  next nil unless plans.all? { |p| p.is_a?(Hash) && p['facts'].is_a?(Hash) }

  plans.map do |p|
    f = p['facts']
    { 'cycle' => p['cycle'], 'facts' => f.slice('steps', 'unclassified', 'step_count') }
  end
end

edits = Dir.glob(File.join(dir, 'adoptions', '*.json')).sort.filter_map do |f|
  e = JSON.parse(File.read(f))
  e.is_a?(Hash) ? e.slice('adopted_block', 'changes') : nil
rescue StandardError
  nil
end.sort_by { |e| e['adopted_block'].to_i }

llm = lambda do |system:, user:, model:, effort:, provider:|
  out = KairosMcp::SkillSets::LlmClient::Tools::LlmCall.new(nil).call(
    'messages' => [{ 'role' => 'user', 'content' => user }], 'system' => system, 'model' => model,
    'effort' => effort, 'sandbox_mode' => true, 'provider_override' => provider
  )
  payload = JSON.parse(Array(out).first[:text])
  raise "llm_call #{payload.dig('error', 'type')}: #{payload.dig('error', 'message')}" unless payload['status'] == 'ok'

  payload['response'].merge('provider' => payload['provider'])
end

records, records_error = ar.chain_records
if records_error
  warn JSON.generate({ 'status' => 'failed', 'reason' => "chain unreadable: #{records_error}" })
  exit 1
end

result = agent::DistillRun.run(
  dir: dir, delegation_status: agent::Delegation.load_effective['status'], records: records,
  facts: facts, reason: reason, edits: edits, llm: llm, chain: KairosMcp::KairosChain::Chain.new,
  judge: agent::Delegation::JUDGE, prompts: agent::DistillerPrompt, manual: manual
)
(manual ? $stdout : $stderr).puts JSON.generate(result)
exit(%w[failed].include?(result['status']) ? 1 : 0)
