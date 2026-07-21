#!/usr/bin/env ruby
# frozen_string_literal: true

# Interruption resilience Slice A probes (design v0.3.1 FROZEN):
# INV-A2 serialized atomic advance (lock exclusion, atomic writes),
# INV-A3 anchored at-most-once (replay, stale rejection, consumed-by-other-
# action rejection, side-effect intent bracket / no silent drop),
# INV-A4 monotone derivable recovery (next_move from persisted state alone,
# unresolved-effect precedence, transient-state mapping),
# INV-A5 adjudication as a gated judgment.
# Usage: ruby test_agent_interruption_resilience.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../KairosChain_mcp_server/lib', __dir__)

require 'json'
require 'fileutils'
require 'tmpdir'
require_relative '../lib/agent/advance_gate'

Gate = KairosMcp::SkillSets::Agent::AdvanceGate

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

# Minimal stand-in for Session: the gate only reads state / cycle_number /
# session_id from it.
FakeSession = Struct.new(:session_id, :state, :cycle_number)

Dir.mktmpdir('resilience_') do |dir|
  session = FakeSession.new('s1', 'observed', 0)
  gate = Gate.new(dir)

  puts '== Anchor derivation (INV-A3/A4) =='
  assert('initial anchor is seq 0 + state + cycle') { gate.current_anchor(session) == '0:observed:0' }
  assert('anchorless call proceeds (compatibility, §7)') do
    gate.check(nil, 'approve', session)['disposition'] == 'proceed'
  end
  assert('matching anchor proceeds') do
    gate.check('0:observed:0', 'approve', session)['disposition'] == 'proceed'
  end
  assert('unknown anchor rejected with current state') do
    gate.check('9:bogus:9', 'approve', session)['disposition'] == 'rejected'
  end

  puts '== Commit and replay (INV-A3 at-most-once) =='
  outcome = { 'status' => 'ok', 'state' => 'proposed', 'anchor' => '1:proposed:0' }
  gate.commit('0:observed:0', 'approve', outcome)
  session.state = 'proposed'
  assert('seq advances after commit') { gate.seq == 1 }
  assert('new anchor reflects committed advance') { gate.current_anchor(session) == '1:proposed:0' }
  assert('re-issue of consumed anchor + same action replays recorded outcome') do
    d = gate.check('0:observed:0', 'approve', session)
    d['disposition'] == 'replay' && d['outcome']['state'] == 'proposed'
  end
  assert('consumed anchor + different action rejected (not an identical judgment)') do
    d = gate.check('0:observed:0', 'stop', session)
    d['disposition'] == 'rejected' && d['consumed_by'] == 'approve'
  end
  assert('gate state survives process re-instantiation (persisted, not in-memory)') do
    Gate.new(dir).seq == 1 && Gate.new(dir).check('0:observed:0', 'approve', session)['disposition'] == 'replay'
  end

  puts '== Serialization (INV-A2) =='
  assert('lock excludes a concurrent advance (second caller gets busy)') do
    results = []
    barrier = Queue.new
    t1 = Thread.new do
      gate.with_lock do
        barrier << :held
        sleep 0.3
        :first
      end
    end
    barrier.pop
    r2 = Gate.new(dir).with_lock { :second }
    results << r2 << t1.value
    r2.is_a?(Hash) && r2['status'] == 'busy' && t1.value == :first
  end
  assert('busy? sees a held lock; free after release') do
    held = nil
    barrier = Queue.new
    release = Queue.new
    t = Thread.new do
      gate.with_lock do
        barrier << :held
        release.pop
      end
    end
    barrier.pop
    held = Gate.new(dir).busy?
    release << :go
    t.join
    held == true && Gate.new(dir).busy? == false
  end
  assert('atomic write leaves no tmp residue') do
    Dir.glob(File.join(dir, '*.tmp.*')).empty?
  end

  puts '== Side-effect intent bracket (INV-A3, no silent drop) =='
  assert('no intent -> no unresolved point') { gate.unresolved_intent.nil? }
  gate.open_intent('1:proposed:0', { 'summary' => 'write a file' })
  assert('orphan intent (advance never committed) surfaces as unresolved') do
    intent = gate.unresolved_intent
    intent && intent['anchor'] == '1:proposed:0'
  end
  assert('unresolved-effect adjudication takes precedence in next_move (INV-A4 uniqueness)') do
    mv = gate.next_move(session)
    mv['args']['action'] == 'adjudicate'
  end
  gate.commit('1:proposed:0', 'approve', { 'status' => 'ok', 'state' => 'checkpoint' })
  session.state = 'checkpoint'
  assert('intent whose advance committed is stale: resolved on read, deleted only under gated cleanup') do
    gate.unresolved_intent.nil? && File.exist?(File.join(dir, 'act_intent.json')) &&
      gate.unresolved_intent(cleanup: true).nil? && !File.exist?(File.join(dir, 'act_intent.json'))
  end
  gate.open_intent('2:checkpoint:0', { 'summary' => 'x' })
  gate.close_intent
  assert('close_intent clears the bracket') { gate.unresolved_intent.nil? }

  puts '== Derivable next move (INV-A4) =='
  moves = {
    'observed'   => 'approve', 'proposed' => 'approve', 'checkpoint' => 'approve',
    'paused_risk' => 'approve', 'paused_error' => 'approve'
  }
  moves.each do |st, act|
    session.state = st
    assert("next_move at #{st} -> agent_step #{act} with current anchor") do
      mv = gate.next_move(session)
      mv['tool'] == 'agent_step' && mv['args']['action'] == act &&
        mv['args']['anchor'] == gate.current_anchor(session)
    end
  end
  session.state = 'terminated'
  assert('next_move at terminated -> no move') { gate.next_move(session)['tool'].nil? }
  session.state = 'orienting'
  assert('transient orienting maps to observed for recovery') do
    gate.effective_state(session) == 'observed' && gate.next_move(session)['args']['action'] == 'approve'
  end
  session.state = 'acting'
  assert('transient acting maps to proposed for recovery') do
    gate.effective_state(session) == 'proposed'
  end
end

# ---- R1 hardening probes (impl review round 1) ----
Dir.mktmpdir('resilience_hardening_') do |dir|
  session = FakeSession.new('s2', 'proposed', 1)
  gate = Gate.new(dir)
  gate.commit('0:proposed:1', 'approve', { 'status' => 'ok' })
  gate.commit('1:proposed:1', 'revise:abcd1234', { 'status' => 'ok' })

  puts '== Seq fails closed against the committed log (R1: at-most-once bypass) =='
  assert('corrupt advance.json does not regress seq below log max + 1') do
    File.write(File.join(dir, 'advance.json'), '{corrupt')
    g = Gate.new(dir)
    g.seq == 2
  end
  assert('missing advance.json reconciles seq from log') do
    File.delete(File.join(dir, 'advance.json'))
    g = Gate.new(dir)
    g.seq == 2
  end
  assert('after reconcile, consumed anchor still replays instead of proceeding') do
    g = Gate.new(dir)
    g.check('0:proposed:1', 'approve', session)['disposition'] == 'replay'
  end

  puts '== Torn log tail repair (R1) =='
  assert('commit after a torn tail line keeps the new record parseable') do
    File.open(File.join(dir, 'advance_log.jsonl'), 'a') { |f| f.write('{"seq":9,"anch') }
    g = Gate.new(dir)
    g.commit('2:proposed:1', 'approve', { 'status' => 'ok', 'marker' => 'post_torn' })
    found = g.check('2:proposed:1', 'approve', session)
    found['disposition'] == 'replay' && found['outcome']['marker'] == 'post_torn'
  end

  puts '== Intent cleanup only under lock (R1: unlocked-delete race) =='
  gate2 = Gate.new(dir)
  gate2.open_intent('3:proposed:1', { 'x' => 1 })
  gate2.commit('3:proposed:1', 'approve', { 'status' => 'ok' })
  assert('read-only probe reports stale intent as resolved but does NOT delete the file') do
    gate2.unresolved_intent.nil? && File.exist?(File.join(dir, 'act_intent.json'))
  end
  assert('gated probe (cleanup: true) deletes the stale intent') do
    gate2.unresolved_intent(cleanup: true).nil? && !File.exist?(File.join(dir, 'act_intent.json'))
  end
end

# ---- integration probes against the real Session (atomic save) ----
Dir.mktmpdir('resilience_session_') do |tmp|
  module Autonomos
    def self.storage_path(subpath)
      path = File.join(@base, subpath)
      FileUtils.mkdir_p(path)
      path
    end

    def self.base=(b)
      @base = b
    end
  end
  Autonomos.base = tmp

  begin
    require 'kairos_mcp/invocation_context'
    require_relative '../lib/agent/session'
    Sess = KairosMcp::SkillSets::Agent::Session

    puts '== Session atomic persistence (INV-A2) =='
    ctx = KairosMcp::InvocationContext.new
    s = Sess.new(session_id: 'rs1', mandate_id: 'm1', goal_name: 'g',
                 invocation_context: ctx, config: {}, autonomous: false)
    s.update_state('observed')
    s.save
    s.save_decision({ 'summary' => 'd' })
    s.save_observation({ 'o' => 1 })
    sdir = s.guard_dir
    assert('session files persisted') do
      File.exist?(File.join(sdir, 'session.json')) &&
        File.exist?(File.join(sdir, 'decision_payload.json'))
    end
    assert('no tmp residue after atomic saves') do
      Dir.glob(File.join(sdir, '*.tmp.*')).empty?
    end
    assert('reloaded session observes the full committed state') do
      r = Sess.load('rs1')
      r && r.state == 'observed' && r.load_decision['summary'] == 'd'
    end
  rescue LoadError => e
    puts "  SKIP: session integration probes (#{e.message})"
  end
end

# ---- tool-seam probes (R1: the gate/tool binding is invariant-bearing) ----
# Drives the REAL advance_under_lock / commit_advance / handle_adjudicate /
# handle_stop code in agent_step.rb with stubbed cognitive handlers.
begin
  require 'kairos_mcp/tools/base_tool'
  require_relative '../tools/agent_step'

  class SeamStep < KairosMcp::SkillSets::Agent::Tools::AgentStep
    attr_accessor :approve_runs, :act_reflect_runs

    def initialize
      super()
      @approve_runs = 0
      @act_reflect_runs = 0
    end

    # Stub the cognitive phases: approve advances observed -> proposed.
    def handle_approve(session)
      @approve_runs += 1
      session.update_state('proposed')
      session.save
      text_content(JSON.generate({ 'status' => 'ok', 'session_id' => session.session_id,
                                   'state' => 'proposed' }))
    end

    # Stub the ACT re-entry used by adjudicate reattempt.
    def run_act_reflect(session)
      @act_reflect_runs += 1
      @gate&.open_intent(@anchor_at_issue, { 'summary' => 'reattempt' })
      session.increment_cycle
      session.update_state('checkpoint')
      session.save
      text_content(JSON.generate({ 'status' => 'ok', 'session_id' => session.session_id,
                                   'state' => 'checkpoint' }))
    end

    def log_agent(*); end
  end

  SessK = KairosMcp::SkillSets::Agent::Session

  def new_seam_session(id)
    ctx = KairosMcp::InvocationContext.new
    s = SessK.new(session_id: id, mandate_id: 'm', goal_name: 'g',
                  invocation_context: ctx, config: {}, autonomous: false)
    s.update_state('observed')
    s.save
    s
  end

  Dir.mktmpdir('resilience_seam_') do |tmp|
    Autonomos.base = tmp

    puts '== Tool seam: gated advance + replay (INV-A2/A3) =='
    s = new_seam_session('seam1')
    tool = SeamStep.new
    r1 = JSON.parse(tool.call({ 'session_id' => 'seam1', 'action' => 'approve',
                                'anchor' => '0:observed:0' })[0][:text])
    assert('gated approve executes and returns the post-commit anchor') do
      r1['status'] == 'ok' && r1['state'] == 'proposed' && r1['anchor'] == '1:proposed:0' &&
        tool.approve_runs == 1
    end
    r2 = JSON.parse(tool.call({ 'session_id' => 'seam1', 'action' => 'approve',
                                'anchor' => '0:observed:0' })[0][:text])
    assert('re-issued identical call replays without re-executing') do
      r2['replayed'] == true && r2['state'] == 'proposed' && tool.approve_runs == 1
    end
    r3 = JSON.parse(tool.call({ 'session_id' => 'seam1', 'action' => 'stop',
                                'anchor' => '0:observed:0' })[0][:text])
    assert('consumed anchor with different action is rejected with next_move') do
      r3['status'] == 'anchor_rejected' && r3['next_move']['args']['action'] == 'approve'
    end

    puts '== Tool seam: unresolved effect refusal + adjudication (INV-A3/A5) =='
    sdir = s.guard_dir
    g = Gate.new(sdir)
    g.open_intent('1:proposed:0', { 'summary' => 'side effect' })
    r4 = JSON.parse(tool.call({ 'session_id' => 'seam1', 'action' => 'approve' })[0][:text])
    assert('approve refused while a side effect is unresolved') do
      r4['status'] == 'unresolved_effect' && r4['next_move']['args']['action'] == 'adjudicate'
    end
    r5 = JSON.parse(tool.call({ 'session_id' => 'seam1', 'action' => 'adjudicate',
                                'resolution' => 'already_done' })[0][:text])
    assert('adjudicate already_done advances to checkpoint and clears the intent after commit') do
      r5['status'] == 'ok' && r5['state'] == 'checkpoint' &&
        !File.exist?(File.join(sdir, 'act_intent.json'))
    end
    assert('adjudicate with the other resolution does not replay this outcome') do
      anchor_used = JSON.parse(File.readlines(File.join(sdir, 'advance_log.jsonl')).last)['anchor']
      r6 = JSON.parse(tool.call({ 'session_id' => 'seam1', 'action' => 'adjudicate',
                                  'resolution' => 'reattempt', 'anchor' => anchor_used })[0][:text])
      r6['status'] != 'ok' || r6['replayed'] != true
    end

    puts '== Tool seam: reattempt re-runs ACT; error is not committed =='
    s2 = new_seam_session('seam2')
    g2 = Gate.new(s2.guard_dir)
    s2.save_decision({ 'summary' => 'd' })
    s2.update_state('proposed')
    s2.save
    g2.open_intent("0:proposed:0", { 'summary' => 'd' })
    tool2 = SeamStep.new
    r7 = JSON.parse(tool2.call({ 'session_id' => 'seam2', 'action' => 'adjudicate',
                                 'resolution' => 'reattempt' })[0][:text])
    assert('adjudicate reattempt re-enters ACT and commits the advance') do
      r7['status'] == 'ok' && r7['state'] == 'checkpoint' && tool2.act_reflect_runs == 1 &&
        !File.exist?(File.join(s2.guard_dir, 'act_intent.json'))
    end
    r8 = JSON.parse(tool2.call({ 'session_id' => 'seam2', 'action' => 'revise' })[0][:text])
    assert('errored call (revise at checkpoint) is not committed; anchor regime unchanged') do
      r8['status'] == 'error' && Gate.new(s2.guard_dir).seq == 1
    end

    puts '== Tool seam: stop over unresolved intent keeps the audit trace =='
    s3 = new_seam_session('seam3')
    g3 = Gate.new(s3.guard_dir)
    g3.open_intent('0:observed:0', { 'summary' => 'orphan' })
    tool3 = SeamStep.new
    r9 = JSON.parse(tool3.call({ 'session_id' => 'seam3', 'action' => 'stop' })[0][:text])
    assert('stop succeeds, reports the unresolved intent, and keeps the intent file') do
      r9['status'] == 'ok' && r9['unresolved_intent_at_stop'] &&
        File.exist?(File.join(s3.guard_dir, 'act_intent.json'))
    end
  end
rescue LoadError => e
  puts "  SKIP: tool-seam probes (#{e.message})"
end

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
