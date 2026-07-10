#!/usr/bin/env ruby
# frozen_string_literal: true

# Guard track Stage C probes (design v0.3.1 FROZEN, §5 Slice 1 acceptance):
# out-of-declaration store write refused (in-process route), record store
# never declarable, no-bypass (enforcement at the governed invoke_tool
# dispatch), live-tree writers refused in-process (AGT-1 route symmetry),
# exemption boundary (driver recording path distinct from ACT context).
# Usage: ruby test_agent_admission.rb

$LOAD_PATH.unshift File.expand_path('../../../../KairosChain_mcp_server/lib', __dir__)

require 'json'
require_relative '../lib/agent/admission'
require 'kairos_mcp/invocation_context'

ADM = KairosMcp::SkillSets::Agent::Admission

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
end

def assert_raises(description, klass)
  yield
  $fail += 1
  puts "  FAIL: #{description} (no exception raised)"
rescue klass
  $pass += 1
  puts "  PASS: #{description}"
end

puts '== Surface validation (fail-closed, AGT-5) =='
assert('l1 surface is declarable') { ADM.validate_surface!(['l1']) == ['l1'] }
assert('empty surface is declarable (deny-all default)') { ADM.validate_surface!([]) == [] }
assert_raises('record store never declarable: "record"', ADM::SurfaceError) do
  ADM.validate_surface!(['record'])
end
assert_raises('record store never declarable: "chain"', ADM::SurfaceError) do
  ADM.validate_surface!(['chain'])
end
assert_raises('record store never declarable: "attestation"', ADM::SurfaceError) do
  ADM.validate_surface!(['attestation'])
end
assert_raises('unknown surface refused: "l2" is not a governance store', ADM::SurfaceError) do
  ADM.validate_surface!(['l2'])
end
assert_raises('unknown surface refused: typo', ADM::SurfaceError) do
  ADM.validate_surface!(%w[l0 lX])
end

puts '== Deny-set construction =='
deny_l1 = ADM.act_blacklist(['l1'])
assert('declared l1 surface admits l1 writers') do
  !deny_l1.include?('knowledge_update') && !deny_l1.include?('skills_promote')
end
assert('undeclared l0 writers denied under l1-only surface') do
  ADM::LAYER_WRITE_TOOLS['l0'].all? { |t| deny_l1.include?(t) }
end
deny_none = ADM.act_blacklist([])
assert('empty surface denies all governance writers') do
  (ADM::LAYER_WRITE_TOOLS['l0'] + ADM::LAYER_WRITE_TOOLS['l1']).all? { |t| deny_none.include?(t) }
end
assert('record-store writers denied for EVERY declarable surface') do
  [[], ['l0'], ['l1'], %w[l0 l1]].all? do |surface|
    deny = ADM.act_blacklist(surface)
    ADM::RECORD_STORE_TOOLS.all? { |t| deny.include?(t) }
  end
end
assert('live-tree writers denied in-process (AGT-1 route symmetry)') do
  ADM::LIVE_TREE_WRITE_TOOLS.all? { |t| deny_l1.include?(t) }
end
assert('configured extras are honored') do
  ADM.act_blacklist(['l1'], extra_denied: ['dataset_register']).include?('dataset_register')
end

puts '== Refusal at dispatch (no-bypass probe: the governed invoke path itself refuses) =='
ctx = KairosMcp::InvocationContext.new(blacklist: ADM.act_blacklist(['l1']))
assert('chain_record refused on ACT context (write never lands)') { !ctx.allowed?('chain_record') }
assert('skills_evolve refused under l1-only surface') { !ctx.allowed?('skills_evolve') }
assert('knowledge_update admitted under l1 surface') { ctx.allowed?('knowledge_update') }
assert('write_section (live-tree writer) refused in-process') { !ctx.allowed?('write_section') }
assert('read tools unaffected') { ctx.allowed?('knowledge_get') && ctx.allowed?('resource_read') }
child = ctx.child(caller_tool: 'autoexec_run')
assert('deny survives context inheritance (child contexts, nested calls)') do
  !child.allowed?('chain_record') && !child.allowed?('l2_attestation_commit')
end

puts '== Exemption boundary (AGT-5: driver recording path is structurally distinct) =='
driver_ctx = KairosMcp::InvocationContext.new(blacklist: nil)
assert('driver context (no ACT blacklist) can reach the recording path') do
  driver_ctx.allowed?('chain_record')
end
assert('the exemption is the context split, not a tool exception inside the ACT deny set') do
  ADM.act_blacklist(%w[l0 l1]).include?('chain_record')
end

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
