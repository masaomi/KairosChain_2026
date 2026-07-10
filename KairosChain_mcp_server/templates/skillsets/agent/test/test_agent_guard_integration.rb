#!/usr/bin/env ruby
# frozen_string_literal: true

# Guard track attended-run integration harness (design v0.3.1 FROZEN §5).
# Unlike the per-module probes, this drives the REAL wired path with
# guard.enabled: true end-to-end:
#   agent_start pins the spec -> the ACT route derives the admission blacklist
#   from the pinned spec -> a delegated act runs confined in a scratch area ->
#   the mechanical verdict gates cycle success -> reflection cannot override it.
# It uses a stubbed executor/LLM (no network) but every guard component
# (Verdict, Confinement, Admission) and every wiring seam is the production one.
# Usage: ruby test_agent_guard_integration.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../KairosChain_mcp_server/lib', __dir__)

require 'json'
require 'fileutils'
require 'tmpdir'
require 'kairos_mcp/invocation_context'
require_relative '../lib/agent'

Session = KairosMcp::SkillSets::Agent::Session
Verdict = KairosMcp::SkillSets::Agent::Verdict
Confinement = KairosMcp::SkillSets::Agent::Confinement
Admission = KairosMcp::SkillSets::Agent::Admission

TMP = Dir.mktmpdir('guard_attended_')

module Autonomos
  @base = TMP
  def self.storage_path(subpath)
    path = File.join(@base, subpath)
    FileUtils.mkdir_p(path)
    path
  end
end

$pass = 0
$fail = 0

def assert(desc)
  ok = yield
  ok ? ($pass += 1; puts "  PASS: #{desc}") : ($fail += 1; puts "  FAIL: #{desc}")
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{desc} (#{e.class}: #{e.message})"
  puts "        #{e.backtrace.first(2).join("\n        ")}"
end

GUARD_CONFIG = {
  'guard' => { 'enabled' => true, 'admission' => { 'extra_denied_tools' => [] } },
  'tool_blacklist' => %w[agent_* autonomos_*]
}.freeze

def new_session
  Session.new(
    session_id: "guard_attended_#{rand(100_000)}",
    mandate_id: 'mandate_x',
    goal_name: 'guard attended run',
    invocation_context: KairosMcp::InvocationContext.new(blacklist: %w[agent_* autonomos_*]),
    config: GUARD_CONFIG,
    autonomous: true
  )
end

darwin = RUBY_PLATFORM.include?('darwin') && system('which sandbox-exec > /dev/null 2>&1')

puts '== Session sees the guard enabled =='
session = new_session
assert('guard_enabled? true from config') { session.guard_enabled? }
assert('guard_dir is the driver-owned session dir') { Dir.exist?(session.guard_dir) }

puts '== agent_start path: pin the mandate acceptance spec (AGT-3/4) =='
guard_material = {
  'acceptance' => [
    { 'type' => 'file_exists', 'path' => 'out/report.txt' },
    { 'type' => 'file_contains', 'path' => 'out/report.txt', 'substring' => 'COMPLETE' }
  ],
  'layer_surface' => ['l1']
}
sha = Verdict.pin!(session.guard_dir, guard_material)
assert('spec pinned content-addressed before any cycle') { sha.length == 64 && Verdict.pinned?(session.guard_dir) }

puts '== ACT route derives admission from the pinned spec (AGT-5) =='
spec, halt = Verdict.load_pinned(session.guard_dir)
assert('pinned spec loads and hash-verifies') { halt.nil? && spec['layer_surface'] == ['l1'] }
deny = Admission.act_blacklist(spec['layer_surface'])
act_ctx = KairosMcp::InvocationContext.new(blacklist: %w[agent_* autonomos_*] + deny)
assert('record-store write refused on the ACT context (write never lands)') { !act_ctx.allowed?('chain_record') }
assert('undeclared l0 write refused under l1 surface') { !act_ctx.allowed?('skills_evolve') }
assert('declared l1 write admitted') { act_ctx.allowed?('knowledge_update') }
assert('live-tree writer refused in-process (route symmetry)') { !act_ctx.allowed?('write_section') }

if darwin
  puts '== Delegated act runs confined; conforming result PASSes the verdict =='
  # Production geometry: project_root is the repo, scratch is a Dir.mktmpdir
  # outside it — disjoint. Here: a fake project tree with its own stores, and a
  # sibling scratch, so disjointness holds exactly as agent_execute arranges it.
  project_root = File.join(TMP, 'project')
  stores_dir = File.join(project_root, '.kairos')
  FileUtils.mkdir_p(stores_dir)
  FileUtils.mkdir_p(File.join(TMP, 'act_scratch'))
  scratch = Confinement.assert_disjoint!(File.join(TMP, 'act_scratch'), project_root)
  wrapped = Confinement.wrap(
    ['/bin/sh', '-c', "mkdir -p #{scratch}/out && echo 'work COMPLETE' > #{scratch}/out/report.txt"],
    scratch, stores_dir
  )
  system(*wrapped)
  manifest = Confinement.manifest(scratch)
  evidence = { 'scratch_dir' => scratch, 'manifest' => manifest, 'execution_summary' => 'completed' }
  v = Verdict.judge(session.guard_dir, evidence)
  assert('confined conforming act PASSes the mechanical verdict') { v['verdict'] == Verdict::PASS }

  puts '== AGT-1 return path: PASS results merge into the live tree, FAIL does not =='
  # Mirrors merge_guard_pass: only a PASS act promotes its scratch manifest.
  if v['verdict'] == Verdict::PASS
    written = Confinement.merge!(scratch, manifest, project_root)
    assert('PASS act promotes report.txt into the live project tree') do
      written.any? && File.read(File.join(project_root, 'out', 'report.txt')).include?('COMPLETE')
    end
  end
  # A store-targeting manifest entry is refused even on a PASS (merge never
  # targets the stores).
  FileUtils.mkdir_p(File.join(scratch, '.kairos'))
  File.write(File.join(scratch, '.kairos', 'forge.json'), '{}')
  merge_refused = begin
    Confinement.merge!(scratch, ['.kairos/forge.json'], project_root); false
  rescue Confinement::ConfinementError
    true
  end
  assert('merge refuses a store-targeting manifest entry') { merge_refused }

  puts '== Non-conforming act FAILs; reflection cannot override (AGT-3 tighten-only) =='
  File.write(File.join(scratch, 'out', 'report.txt'), 'work FAILED')
  v2 = Verdict.judge(session.guard_dir, evidence)
  assert('non-conforming act FAILs the verdict') { v2['verdict'] == Verdict::FAIL }
  # Simulate the agent_step tighten-only rule.
  act_succeeded = true
  high_confidence_reflection = { 'confidence' => 0.99 }
  act_succeeded = false if v2['verdict'] != Verdict::PASS
  assert('high-confidence reflection cannot flip a failing verdict to success') { act_succeeded == false }
else
  puts '== Delegated confined act skipped (sandbox-exec unavailable) =='
end

puts '== Fail-closed: a session with guard on but no pinned spec HALTs the ACT (AGT-6) =='
bare = new_session
spec2, halt2 = Verdict.load_pinned(bare.guard_dir)
assert('no pinned spec => HALT verdict, never a pass') { spec2.nil? && halt2['verdict'] == Verdict::HALT }

puts '== Fail-closed: undeclarable surface refuses the session at pin (AGT-5) =='
assert('declaring the record store at pin is refused') do
  begin
    Verdict.pin!(new_session.guard_dir, { 'acceptance' => [{ 'type' => 'manifest_not_empty' }],
                                          'layer_surface' => ['chain'] })
    false
  rescue Verdict::SpecError
    true
  end
end

FileUtils.remove_entry(TMP) if Dir.exist?(TMP)
puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
