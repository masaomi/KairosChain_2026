#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.2 M4 — CodeGenAct pipeline tests (invoker stub).

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'
require 'digest'

require 'kairos_mcp/daemon/code_gen_act'
require 'kairos_mcp/daemon/approval_gate'
require 'kairos_mcp/daemon/execution_context'

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

CGA = KairosMcp::Daemon::CodeGenAct
AG  = KairosMcp::Daemon::ApprovalGate
EC  = KairosMcp::Daemon::ExecutionContext

# Minimal Safety stub
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

# Helper: set up workspace with file
def with_workspace
  Dir.mktmpdir('cga_test') do |ws|
    FileUtils.mkdir_p(File.join(ws, '.kairos', 'context'))
    FileUtils.mkdir_p(File.join(ws, '.kairos', 'knowledge'))
    FileUtils.mkdir_p(File.join(ws, '.kairos', 'run', 'proposals'))
    yield ws
  end
end

def make_cga(ws, chain_recorder: nil)
  safety = StubSafety.new
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  invoker = ->(_tool, _args) { {} }  # stub
  CGA.new(
    workspace_root: ws,
    safety: safety,
    invoker: invoker,
    approval_gate: gate,
    chain_recorder: chain_recorder
  )
end

# ---------------------------------------------------------------------------

section 'CodeGenAct: L2 auto-approve (happy path)'

with_workspace do |ws|
  # Create a L2 file
  path = File.join(ws, '.kairos', 'context', 'notes.md')
  File.write(path, "hello world\n")

  cga = make_cga(ws)
  decision = {
    action: 'code_edit',
    target: '.kairos/context/notes.md',
    old_string: 'hello',
    new_string: 'goodbye'
  }
  mandate = { id: 'mandate_1', allow_llm_upload: ['l2'] }

  assert('T30: L2 auto-approve end-to-end succeeds') do
    result = cga.run(decision, mandate)
    result[:status] == 'applied' && result[:scope] == :l2
  end

  assert('T30b: file content actually changed') do
    File.read(path) == "goodbye world\n"
  end

  assert('T30c: pre/post hash in result') do
    # run again with new content
    File.write(path, "goodbye world\n")
    cga2 = make_cga(ws)
    r = cga2.run({ target: '.kairos/context/notes.md',
                    old_string: 'goodbye', new_string: 'farewell' },
                  { id: 'm2', allow_llm_upload: ['l2'] })
    r[:pre_hash].start_with?('sha256:') && r[:post_hash].start_with?('sha256:')
  end
end

section 'CodeGenAct: L1 requires approval (PauseForApproval)'

with_workspace do |ws|
  path = File.join(ws, '.kairos', 'knowledge', 'skill.md')
  File.write(path, "old content\n")

  cga = make_cga(ws)
  decision = { target: '.kairos/knowledge/skill.md',
               old_string: 'old content', new_string: 'new content' }
  mandate = { id: 'mandate_2', allow_llm_upload: %w[l1 l2] }

  assert('T31: L1 edit raises PauseForApproval') do
    begin
      cga.run(decision, mandate)
      false
    rescue CGA::PauseForApproval => e
      e.proposal_id.start_with?('prop_')
    end
  end

  assert('T31b: file NOT changed (proposal only staged)') do
    File.read(path) == "old content\n"
  end
end

section 'CodeGenAct: L1 with approved grant'

with_workspace do |ws|
  path = File.join(ws, '.kairos', 'knowledge', 'skill.md')
  File.write(path, "old content\n")

  safety = StubSafety.new
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  chain_calls = []
  chain_recorder = ->(payload) { chain_calls << payload; 'tx_123' }

  cga = CGA.new(workspace_root: ws, safety: safety, invoker: ->(_,_){{}},
                 approval_gate: gate, chain_recorder: chain_recorder)

  decision = { target: '.kairos/knowledge/skill.md',
               old_string: 'old content', new_string: 'new content' }
  mandate = { id: 'mandate_3', allow_llm_upload: %w[l1 l2] }

  # First call: PauseForApproval
  proposal_id = nil
  begin
    cga.run(decision, mandate)
  rescue CGA::PauseForApproval => e
    proposal_id = e.proposal_id
  end

  # Approve
  gate.record_decision(proposal_id, decision: 'approve', reviewer: 'masa')

  assert('T32: resume after approval succeeds') do
    EC.current_elevation_token = nil
    result = cga.resume(proposal_id)
    result[:status] == 'applied' && result[:scope] == :l1
  end

  assert('T32b: file changed after approval') do
    File.read(path) == "new content\n"
  end

  assert('T32c: chain_record called for L1') do
    chain_calls.size == 1 && chain_calls[0][:scope] == 'l1'
  end

  assert('T32d: elevation cleaned up') do
    EC.current_elevation_token.nil? && safety.overrides.empty?
  end
end

section 'CodeGenAct: CAS — PreHashMismatch'

with_workspace do |ws|
  path = File.join(ws, '.kairos', 'context', 'notes.md')
  File.write(path, "original\n")

  cga = make_cga(ws)
  decision = { target: '.kairos/context/notes.md',
               old_string: 'original', new_string: 'modified' }
  mandate = { id: 'm4', allow_llm_upload: ['l2'] }

  # Tamper with file between propose simulation and apply
  # We need to intercept — simplest: modify after auto-approve but before perform_apply
  # Instead, test via resume with a stale proposal
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  cga2 = CGA.new(workspace_root: ws, safety: StubSafety.new, invoker: ->(_,_){{}},
                  approval_gate: gate)

  # Stage a proposal manually with correct pre_hash
  content = File.binread(path)
  pre_hash = KairosMcp::Daemon::EditKernel.hash_bytes(content)
  result = KairosMcp::Daemon::EditKernel.compute(content, old_string: 'original', new_string: 'modified')

  proposal = {
    proposal_id: 'prop_cas_test',
    mandate_id: 'm4',
    target: { path: '.kairos/context/notes.md', pre_hash: pre_hash },
    edit: { old_string: 'original', new_string: 'modified',
            replace_all: false, proposed_post_hash: result[:post_hash] },
    scope: { scope: :l2, auto_approve: true, reason: 'test', matched_rule: :context }
  }
  gate.auto_approve(proposal)

  # Tamper with file
  File.write(path, "tampered content\n")

  assert('T33: PreHashMismatch when file changed between propose and apply') do
    begin
      EC.current_elevation_token = nil
      cga2.resume('prop_cas_test')
      false
    rescue CGA::PreHashMismatch
      true
    end
  end

  assert('T33b: file still has tampered content (no write occurred)') do
    File.read(path) == "tampered content\n"
  end
end

section 'CodeGenAct: LLM content policy'

with_workspace do |ws|
  path = File.join(ws, '.kairos', 'knowledge', 'secret.md')
  File.write(path, "secret data\n")

  cga = make_cga(ws)
  decision = { target: '.kairos/knowledge/secret.md',
               old_string: 'secret', new_string: 'public' }
  mandate = { id: 'm5', allow_llm_upload: ['l2'] }  # L1 NOT allowed

  assert('T37d: LlmContentPolicyViolation for L1 without opt-in') do
    begin
      cga.run(decision, mandate)
      false
    rescue CGA::LlmContentPolicyViolation => e
      e.message.include?('l1') && e.message.include?('allow_llm_upload')
    end
  end
end

section 'CodeGenAct: resume — still pending'

with_workspace do |ws|
  path = File.join(ws, '.kairos', 'knowledge', 'x.md')
  File.write(path, "data\n")

  safety = StubSafety.new
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  cga = CGA.new(workspace_root: ws, safety: safety, invoker: ->(_,_){{}},
                 approval_gate: gate)

  # Stage but don't approve
  proposal = {
    proposal_id: 'prop_pending1',
    mandate_id: 'm6',
    target: { path: '.kairos/knowledge/x.md', pre_hash: 'sha256:abc' },
    edit: { old_string: 'data', new_string: 'info', replace_all: false, proposed_post_hash: 'sha256:def' },
    scope: { scope: :l1, auto_approve: false, reason: 'test', matched_rule: :knowledge }
  }
  gate.stage(proposal)

  assert('T37: resume returns :still_pending when not approved') do
    EC.current_elevation_token = nil
    cga.resume('prop_pending1') == :still_pending
  end
end

# ---------------------------------------------------------------------------
# ScopeDrift test (T37c — R1 consensus fix)
# ---------------------------------------------------------------------------

section 'CodeGenAct: ScopeDrift'

with_workspace do |ws|
  # Create file in L2 scope (context)
  path = File.join(ws, '.kairos', 'context', 'movable.md')
  File.write(path, "original content\n")

  safety = StubSafety.new
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))

  content = File.binread(path)
  pre_hash = KairosMcp::Daemon::EditKernel.hash_bytes(content)
  result = KairosMcp::Daemon::EditKernel.compute(content, old_string: 'original', new_string: 'modified')

  # Stage proposal with WRONG stored scope (:l0) for a file that's actually :l2
  # This simulates: scope was L0 at propose time, but path now classifies as L2
  # (or vice versa — the point is the mismatch triggers ScopeDrift)
  proposal = {
    proposal_id: 'prop_drift1',
    mandate_id: 'm_drift',
    target: { path: '.kairos/context/movable.md', pre_hash: pre_hash },
    edit: { old_string: 'original', new_string: 'modified',
            replace_all: false, proposed_post_hash: result[:post_hash] },
    scope: { scope: :l0, auto_approve: false, reason: 'test', matched_rule: :core_code }
  }
  gate.auto_approve(proposal)

  assert('T37c: ScopeDrift raised when stored scope differs from re-classified') do
    begin
      EC.current_elevation_token = nil
      cga = CGA.new(workspace_root: ws, safety: safety, invoker: ->(_,_){{}},
                      approval_gate: gate)
      cga.resume('prop_drift1')
      false
    rescue CGA::ScopeDrift => e
      e.message.include?('l0') && e.message.include?('l2')
    end
  end
end

# ---------------------------------------------------------------------------
# Resume: rejected proposal
# ---------------------------------------------------------------------------

section 'CodeGenAct: resume rejected'

with_workspace do |ws|
  path = File.join(ws, '.kairos', 'knowledge', 'rejected.md')
  File.write(path, "data\n")

  safety = StubSafety.new
  gate = AG.new(dir: File.join(ws, '.kairos', 'run', 'proposals'))
  cga = CGA.new(workspace_root: ws, safety: safety, invoker: ->(_,_){{}},
                 approval_gate: gate)

  proposal = {
    proposal_id: 'prop_rej1',
    mandate_id: 'm_rej',
    target: { path: '.kairos/knowledge/rejected.md', pre_hash: 'sha256:abc' },
    edit: { old_string: 'data', new_string: 'info', replace_all: false, proposed_post_hash: 'sha256:def' },
    scope: { scope: :l1, auto_approve: false, reason: 'test', matched_rule: :knowledge }
  }
  gate.stage(proposal)
  gate.record_decision('prop_rej1', decision: 'reject', reviewer: 'masa', reason: 'not now')

  assert('T37e: resume returns :rejected for rejected proposal') do
    EC.current_elevation_token = nil
    cga.resume('prop_rej1') == :rejected
  end

  assert('T37f: resume returns :not_found for unknown proposal') do
    cga.resume('prop_nonexistent') == :not_found
  end
end

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

puts
puts '=' * 60
puts "Results: #{$pass} passed, #{$fail} failed"
puts '=' * 60

unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end

exit($fail.zero? ? 0 : 1)
