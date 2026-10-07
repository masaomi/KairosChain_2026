#!/usr/bin/env ruby
# frozen_string_literal: true
#
# The shadow judge's process (design v0.3, INV-D6 / INV-D7). Started detached
# by the driver after an advance commits, once per anchor, with the packet the
# driver wrote. It reads the files the packet pins, asks a fresh model the
# operator's question, writes the verdict beside the packet and appends a
# salted commitment to it on the chain.
#
# It loads no agent tool and never opens the session's advance lock: nothing
# waits for it, and nothing it does can reach the operator's answer.
#
# The model is reached through llm_call (design v0.3 §4), loaded here as a
# tool object rather than through a registry: provider claude_code (claude -p)
# with sandbox_mode, the requested model and effort. llm_call falls back to
# another provider only from a provider other than claude_code, so the judge
# has none. Its timeout is llm_client's configured one (600 s as shipped).
#
# argv: <packet_path>
# env:  KAIROS_SERVER_LIB  lib dir to load kairos_mcp from
#       KAIROS_DATA_DIR    the server's data dir (the chain written)
#       KAIROS_PROJECT_ROOT the server's working directory

require 'json'

packet_path = ARGV[0] or abort 'usage: agent_shadow_judge.rb <packet_path>'

begin
  Process.setsid
rescue StandardError
  # Already a group leader (spawned with pgroup): acceptable.
end

begin
  Dir.chdir(ENV['KAIROS_PROJECT_ROOT']) if ENV['KAIROS_PROJECT_ROOT'] && Dir.exist?(ENV['KAIROS_PROJECT_ROOT'])
  $LOAD_PATH.unshift(ENV['KAIROS_SERVER_LIB']) if ENV['KAIROS_SERVER_LIB']
  require 'kairos_mcp'
  KairosMcp.data_dir = ENV['KAIROS_DATA_DIR'] if ENV['KAIROS_DATA_DIR'] && !ENV['KAIROS_DATA_DIR'].empty?
  require 'kairos_mcp/kairos_chain/chain'

  lib = File.expand_path('../lib', __dir__)
  require File.join(lib, 'agent', 'answer_ruling')
  require File.join(lib, 'agent', 'delegation')
  require File.join(lib, 'agent', 'shadow_judge')
  require 'kairos_mcp/tools/base_tool'
  # agent depends on llm_client; both are installed side by side.
  require File.expand_path('../../llm_client/tools/llm_call', __dir__)
rescue ScriptError, StandardError => e
  dir = File.dirname(packet_path)
  File.write(File.join(dir, 'error.json'),
             JSON.generate({ 'sealed' => false, 'error' => "bootstrap: #{e.class}: #{e.message[0, 200]}" }))
  exit 1
end

llm = lambda do |system:, user:, model:, effort:, provider:|
  out = KairosMcp::SkillSets::LlmClient::Tools::LlmCall.new(nil).call(
    'messages' => [{ 'role' => 'user', 'content' => user }], 'system' => system, 'model' => model,
    'effort' => effort, 'sandbox_mode' => true, 'provider_override' => provider
  )
  payload = JSON.parse(Array(out).first[:text])
  raise "llm_call #{payload.dig('error', 'type')}: #{payload.dig('error', 'message')}" unless payload['status'] == 'ok'

  payload['response'].merge('provider' => payload['provider'])
end

result = KairosMcp::SkillSets::Agent::ShadowJudge.judge_and_seal(
  packet_path, llm: llm, chain: KairosMcp::KairosChain::Chain.new
)
warn JSON.generate(result)
exit(result['sealed'] ? 0 : 1)
