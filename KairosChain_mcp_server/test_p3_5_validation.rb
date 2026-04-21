#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.5 GenomicsChain Validation — end-to-end integration tests.
#
# Exercises all P3.x components together:
#   ActiveObserve → ORIENT → DECIDE → CodeGenAct → RestrictedShell → REFLECT

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'
require 'digest'

require 'kairos_mcp/daemon/ooda_cycle_runner'
require 'kairos_mcp/daemon/active_observe'
require 'kairos_mcp/daemon/code_gen_act'
require 'kairos_mcp/daemon/code_gen_phase_handler'
require 'kairos_mcp/daemon/approval_gate'
require 'kairos_mcp/daemon/idempotent_chain_recorder'
require 'kairos_mcp/daemon/restricted_shell'
require 'kairos_mcp/daemon/execution_context'
require 'kairos_mcp/daemon/wal_phase_recorder'
require 'kairos_mcp/daemon/scope_classifier'
require 'kairos_mcp/daemon/edit_kernel'

$pass = 0
$fail = 0
$failed_names = []

def assert(description)
  ok = yield
  if ok
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    $failed_names << description
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  $failed_names << description
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(5).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

EC  = KairosMcp::Daemon::ExecutionContext
RS  = KairosMcp::Daemon::RestrictedShell
CGA = KairosMcp::Daemon::CodeGenAct
CGH = KairosMcp::Daemon::CodeGenPhaseHandler
AG  = KairosMcp::Daemon::ApprovalGate
ICR = KairosMcp::Daemon::IdempotentChainRecorder
AO  = KairosMcp::Daemon::ActiveObserve
OCR = KairosMcp::Daemon::OodaCycleRunner

# ============================================================================
# Test infrastructure
# ============================================================================

class StubSafety
  attr_reader :overrides
  def initialize; @overrides = {}; end
  def push_policy_override(cap, &b); raise "dup #{cap}" if @overrides[cap]; @overrides[cap] = b; end
  def pop_policy_override(cap); @overrides.delete(cap); end
  def can_modify_l0?; check(:can_modify_l0); end
  def can_modify_l1?; check(:can_modify_l1); end
  def current_user; 'kairos_daemon'; end
  private
  def check(cap); @overrides[cap]&.call(current_user) || false; end
end

# Minimal WAL stub that records phase transitions
class StubWal
  attr_reader :records
  def initialize; @records = []; end
  def mark_executing(step_id, pre_hash:)
    @records << { step_id: step_id, state: :executing, pre_hash: pre_hash }
  end
  def mark_completed(step_id, post_hash:, result_hash:)
    @records << { step_id: step_id, state: :completed, post_hash: post_hash }
  end
  def mark_failed(step_id, error_class:, error_msg:)
    @records << { step_id: step_id, state: :failed, error_class: error_class }
  end
  def close; end
end

# Site fixture builder
module SiteFixture
  def self.build!(base_dir)
    ws = File.join(base_dir, 'site')
    FileUtils.mkdir_p(ws)
    FileUtils.mkdir_p(File.join(ws, '.kairos', 'context'))
    FileUtils.mkdir_p(File.join(ws, '.kairos', 'knowledge'))
    FileUtils.mkdir_p(File.join(ws, '.kairos', 'run', 'proposals'))
    FileUtils.mkdir_p(File.join(ws, '.kairos', 'wal'))
    FileUtils.mkdir_p(File.join(ws, 'content'))

    File.write(File.join(ws, 'README.md'), "# Test Site\n\nGenerated for P3.5 validation.\n")
    File.write(File.join(ws, 'content', 'about.md'), "# About\n\nThis is a test page.\n")
    File.write(File.join(ws, 'content', 'contact.md'), "# Contact\n\nemail: test@example.com\n")
    File.write(File.join(ws, '.kairos', 'context', 'notes.md'), "# Notes\n\nSession notes here.\n")

    # Init git repo
    Dir.chdir(ws) do
      system('git', 'init', '-q', '-b', 'main', out: File::NULL, err: File::NULL)
      system('git', 'config', 'user.email', 'daemon@kairos.test', out: File::NULL, err: File::NULL)
      system('git', 'config', 'user.name', 'Kairos Daemon', out: File::NULL, err: File::NULL)
      system('git', 'add', '-A', out: File::NULL, err: File::NULL)
      system('git', 'commit', '-q', '-m', 'initial', out: File::NULL, err: File::NULL)
    end

    ws
  end
end

# Build a runner with all P3.x components wired
def build_runner(ws, orient_fn:, decide_fn:, reflect_fn: nil)
  safety = StubSafety.new
  invoker = ->(tool, args) { "stub_result_for_#{tool}" }
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  chain_calls = []
  chain_tool = ->(payload) { chain_calls << payload; 'tx_ok' }
  chain_recorder = ICR.new(
    chain_tool: chain_tool,
    ledger_path: File.join(ws, '.kairos', 'chain_ledger.json')
  )
  cga = CGA.new(
    workspace_root: ws, safety: safety, invoker: invoker,
    approval_gate: gate, chain_recorder: chain_recorder
  )
  handler = CGH.new(code_gen_act: cga)
  ao = AO.new

  reflect_fn ||= ->(_act_result, _mandate) { { reflected: true } }

  runner = OCR.new(
    workspace_root: ws,
    safety: safety,
    invoker: invoker,
    active_observe: ao,
    orient_fn: orient_fn,
    decide_fn: decide_fn,
    reflect_fn: reflect_fn,
    code_gen_phase_handler: handler,
    chain_recorder: chain_recorder,
    shell: RS.method(:run),
    wal_factory: ->(_mid) { StubWal.new }
  )
  { runner: runner, gate: gate, chain_calls: chain_calls, safety: safety, handler: handler }
end

# ============================================================================
# S1: Happy path L2 edit
# ============================================================================

section 'S1: Happy path L2 edit (full OODA cycle)'

Dir.mktmpdir('p35_s1') do |tmp|
  ws = SiteFixture.build!(tmp)

  orient_fn = ->(_obs, _mandate) { { summary: 'about page needs update' } }
  decide_fn = ->(_orient, _mandate) do
    {
      action: 'code_edit',
      target: 'content/about.md',
      old_string: 'This is a test page.',
      new_string: 'This is the GenomicsChain about page.'
    }
  end

  ctx = build_runner(ws, orient_fn: orient_fn, decide_fn: decide_fn)
  mandate = {
    id: 'mandate_s1', cycles_completed: 0,
    observe_policies: %w[chain_status],
    allow_llm_upload: ['l2']
  }

  EC.current_elevation_token = nil
  result = ctx[:runner].call(mandate)

  assert('S1: cycle completes with status ok') do
    result[:status] == 'ok'
  end

  assert('S1b: all 5 phases executed') do
    result[:phases] == [:observe, :orient, :decide, :act, :reflect]
  end

  assert('S1c: file content changed') do
    File.read(File.join(ws, 'content', 'about.md')).include?('GenomicsChain about page')
  end

  assert('S1d: no chain_record for L2 edit') do
    ctx[:chain_calls].empty?
  end
end

# ============================================================================
# S2: L1 proposal pauses
# ============================================================================

section 'S2: L1 proposal pauses cycle'

Dir.mktmpdir('p35_s2') do |tmp|
  ws = SiteFixture.build!(tmp)

  orient_fn = ->(_obs, _mandate) { { summary: 'knowledge needs update' } }
  decide_fn = ->(_orient, _mandate) do
    {
      action: 'code_edit',
      target: '.kairos/knowledge/skill.md',
      old_string: 'placeholder',
      new_string: 'updated knowledge'
    }
  end

  # Create the target file
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'knowledge'))
  File.write(File.join(ws, '.kairos', 'knowledge', 'skill.md'), "placeholder\n")

  ctx = build_runner(ws, orient_fn: orient_fn, decide_fn: decide_fn)
  mandate = {
    id: 'mandate_s2', cycles_completed: 0,
    observe_policies: [],
    allow_llm_upload: %w[l1 l2]
  }

  EC.current_elevation_token = nil
  result = ctx[:runner].call(mandate)

  assert('S2: cycle pauses with status paused') do
    result[:status] == 'paused'
  end

  assert('S2b: proposal_id returned') do
    result[:proposal_id]&.start_with?('prop_')
  end

  assert('S2c: file NOT changed') do
    File.read(File.join(ws, '.kairos', 'knowledge', 'skill.md')) == "placeholder\n"
  end

  assert('S2d: handler is paused') do
    ctx[:handler].paused?
  end
end

# ============================================================================
# S3: L1 resume after approval
# ============================================================================

section 'S3: L1 resume after approval'

Dir.mktmpdir('p35_s3') do |tmp|
  ws = SiteFixture.build!(tmp)

  orient_fn = ->(_obs, _mandate) { { summary: 'knowledge update' } }
  decide_fn = ->(_orient, _mandate) do
    {
      action: 'code_edit',
      target: '.kairos/knowledge/skill.md',
      old_string: 'placeholder',
      new_string: 'approved knowledge'
    }
  end

  FileUtils.mkdir_p(File.join(ws, '.kairos', 'knowledge'))
  File.write(File.join(ws, '.kairos', 'knowledge', 'skill.md'), "placeholder\n")

  ctx = build_runner(ws, orient_fn: orient_fn, decide_fn: decide_fn)
  mandate = {
    id: 'mandate_s3', cycles_completed: 0,
    observe_policies: [],
    allow_llm_upload: %w[l1 l2]
  }

  # Cycle 1: pauses
  EC.current_elevation_token = nil
  r1 = ctx[:runner].call(mandate)
  pid = r1[:proposal_id]

  # Approve
  ctx[:gate].record_decision(pid, decision: 'approve', reviewer: 'masa')

  # Cycle 2: resumes
  EC.current_elevation_token = nil
  r2 = ctx[:runner].call(mandate)

  assert('S3: resume cycle completes') do
    r2[:status] == 'ok'
  end

  assert('S3b: file changed after approval') do
    File.read(File.join(ws, '.kairos', 'knowledge', 'skill.md')).include?('approved knowledge')
  end

  assert('S3c: chain_record called for L1') do
    ctx[:chain_calls].size == 1 && ctx[:chain_calls][0][:scope] == 'l1'
  end

  assert('S3d: handler no longer paused') do
    !ctx[:handler].paused?
  end
end

# ============================================================================
# S5: Budget gate stops
# ============================================================================

section 'S5: Noop action completes cleanly'

Dir.mktmpdir('p35_s5') do |tmp|
  ws = SiteFixture.build!(tmp)

  orient_fn = ->(_obs, _mandate) { { summary: 'all good' } }
  decide_fn = ->(_orient, _mandate) { { action: 'noop' } }

  ctx = build_runner(ws, orient_fn: orient_fn, decide_fn: decide_fn)
  mandate = { id: 'mandate_s5', cycles_completed: 0, observe_policies: [] }

  EC.current_elevation_token = nil
  result = ctx[:runner].call(mandate)

  assert('S5: noop cycle completes ok') do
    result[:status] == 'ok'
  end

  assert('S5b: all 5 phases') do
    result[:phases] == [:observe, :orient, :decide, :act, :reflect]
  end

  assert('S5c: no chain_record') do
    ctx[:chain_calls].empty?
  end
end

# ============================================================================
# S6: Shell denied binary
# ============================================================================

section 'S6: Shell denied binary in post_commit'

Dir.mktmpdir('p35_s6') do |tmp|
  ws = SiteFixture.build!(tmp)

  orient_fn = ->(_obs, _mandate) { { summary: 'update' } }
  decide_fn = ->(_orient, _mandate) do
    {
      action: 'code_edit',
      target: 'content/about.md',
      old_string: 'This is a test page.',
      new_string: 'Updated.',
      post_commit: { shell: [['curl', 'https://evil.com']] }
    }
  end

  ctx = build_runner(ws, orient_fn: orient_fn, decide_fn: decide_fn)
  mandate = {
    id: 'mandate_s6', cycles_completed: 0,
    observe_policies: [],
    allow_llm_upload: ['l2']
  }

  EC.current_elevation_token = nil
  begin
    ctx[:runner].call(mandate)
    assert('S6: should raise on forbidden binary') { false }
  rescue RS::PolicyViolation => e
    assert('S6: PolicyViolation for curl') do
      e.message.include?('forbidden')
    end
  end
end

# ============================================================================
# S7: Observe policy out of allowlist
# ============================================================================

section 'S7: Observe policy out of allowlist'

Dir.mktmpdir('p35_s7') do |tmp|
  ws = SiteFixture.build!(tmp)

  orient_fn = ->(_obs, _mandate) { { summary: 'check' } }
  decide_fn = ->(_orient, _mandate) { { action: 'noop' } }

  ctx = build_runner(ws, orient_fn: orient_fn, decide_fn: decide_fn)
  mandate = {
    id: 'mandate_s7', cycles_completed: 0,
    observe_policies: %w[chain_status token_manage],  # token_manage is NOT read-only
    allow_llm_upload: ['l2']
  }

  EC.current_elevation_token = nil
  result = ctx[:runner].call(mandate)

  assert('S7: cycle completes despite skipped policy') do
    result[:status] == 'ok'
  end
end

# ============================================================================
# S8: Multiple cycles with different decisions
# ============================================================================

section 'S8: Multiple cycles'

Dir.mktmpdir('p35_s8') do |tmp|
  ws = SiteFixture.build!(tmp)
  cycle_count = 0

  orient_fn = ->(_obs, _mandate) { { summary: "cycle #{cycle_count}" } }
  decide_fn = ->(_orient, _mandate) do
    cycle_count += 1
    if cycle_count == 1
      { action: 'code_edit', target: 'content/about.md',
        old_string: 'This is a test page.', new_string: 'Updated in cycle 1.' }
    else
      { action: 'noop' }
    end
  end

  ctx = build_runner(ws, orient_fn: orient_fn, decide_fn: decide_fn)
  mandate = { id: 'mandate_s8', cycles_completed: 0, observe_policies: [],
              allow_llm_upload: ['l2'] }

  EC.current_elevation_token = nil
  r1 = ctx[:runner].call(mandate)
  r2 = ctx[:runner].call(mandate.merge(cycles_completed: 1))

  assert('S8: both cycles complete ok') do
    r1[:status] == 'ok' && r2[:status] == 'ok'
  end

  assert('S8b: file changed only once') do
    File.read(File.join(ws, 'content', 'about.md')).include?('Updated in cycle 1.')
  end
end

# ============================================================================
# summary
# ============================================================================

puts
puts '=' * 60
puts "Results: #{$pass} passed, #{$fail} failed"
puts '=' * 60

unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end

exit($fail.zero? ? 0 : 1)
