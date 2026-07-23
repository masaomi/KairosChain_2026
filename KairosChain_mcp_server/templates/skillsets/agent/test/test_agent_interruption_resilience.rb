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

    puts '== R2 fixes: terminated guard + fail-closed reload =='
    r10 = JSON.parse(tool3.call({ 'session_id' => 'seam3', 'action' => 'adjudicate',
                                  'resolution' => 'reattempt' })[0][:text])
    assert('adjudicate refused on a terminated session (no resurrection)') do
      r10['status'] == 'error' && r10['error'].include?('terminated')
    end
    assert('next_move on terminated-with-kept-intent reports audit record, never a looping adjudicate') do
      sess3 = SessK.load('seam3')
      mv = Gate.new(s3.guard_dir).next_move(sess3)
      mv['tool'].nil? && mv['audit_intent']
    end
    r10b = JSON.parse(tool3.call({ 'session_id' => 'seam3', 'action' => 'stop' })[0][:text])
    assert('retried agent_step stop on terminated session is a no-op (no duplicate commit)') do
      log3 = File.join(s3.guard_dir, 'advance_log.jsonl')
      r10b['already_terminated'] == true && File.readlines(log3).grep(/"action":"stop"/).size == 1
    end
    assert('advance on a session whose record vanished fails closed (never a stale snapshot)') do
      FileUtils.rm_f(File.join(s3.guard_dir, 'session.json'))
      r11 = JSON.parse(tool3.call({ 'session_id' => 'seam3', 'action' => 'approve' })[0][:text])
      r11['status'] == 'error' &&
        (r11['error'].include?('not found') || r11['error'].include?('unreadable'))
    end

    puts '== R2 fixes: agent_stop tool gated + idempotent on terminated =='
    begin
      require_relative '../tools/agent_stop'
      s4 = new_seam_session('seam4')
      stop_tool = KairosMcp::SkillSets::Agent::Tools::AgentStop.new
      r12 = JSON.parse(stop_tool.call({ 'session_id' => 'seam4' })[0][:text])
      log4 = File.join(s4.guard_dir, 'advance_log.jsonl')
      assert('agent_stop tool terminates through the gate and commits once') do
        r12['status'] == 'ok' && r12['state'] == 'terminated' &&
          File.readlines(log4).size == 1
      end
      r13 = JSON.parse(stop_tool.call({ 'session_id' => 'seam4' })[0][:text])
      assert('retried agent_stop is a no-op, not a duplicate commit') do
        r13['already_terminated'] == true && File.readlines(log4).size == 1
      end
    rescue LoadError => e
      puts "  SKIP: agent_stop tool probes (#{e.message})"
    end
  end
rescue LoadError => e
  puts "  SKIP: tool-seam probes (#{e.message})"
end

# ---- Slice A-2: delegation handle + wait surface ----
begin
  require_relative '../lib/agent/step_delegation'
  require_relative '../tools/agent_wait'
  Delegation = KairosMcp::SkillSets::Agent::StepDelegation

  Dir.mktmpdir('resilience_a2_') do |tmp|
    Autonomos.base = tmp

    puts '== A-2: delegation handle lifecycle (INV-A1/A3), anchor+action keyed =='
    s = new_seam_session('a2s1')
    d = Delegation.new(s.guard_dir)
    assert('no handle -> status none') { d.status == 'none' }
    how1, tok1 = d.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    d.touch_heartbeat(tok1)
    assert('opened handle is pending with a token') { how1 == :opened && tok1 && d.status == 'still_pending' }
    assert('issue-anchor + action_key injected/recorded (always anchored re-entry)') do
      d.pending['arguments']['anchor'] == '0:observed:0' && d.pending['issue_anchor'] == '0:observed:0' &&
        d.pending['action_key'] == 'approve'
    end
    how2, tok2 = d.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    assert('re-open for same anchor+action is idempotent (same token, no second worker)') do
      how2 == :existing && tok2 == tok1
    end
    how2b, tok2b = d.open_handle({ 'action' => 'revise', 'feedback' => 'x' }, '0:observed:0', 'revise:deadbeef')
    assert('DIFFERENT action at the SAME anchor is a new delegation (not a reuse)') do
      how2b == :opened && tok2b != tok1
    end
    how3, tok3 = d.open_handle({ 'action' => 'approve' }, '1:proposed:0', 'approve')
    assert('different anchor opens a NEW handle') { how3 == :opened && tok3 != tok1 }

    puts '== A-2: status transitions (teardown owned by collector) =='
    d.clear_pending_if(tok3)
    how4, tok4 = d.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    d.touch_heartbeat(tok4)
    hb = File.join(s.guard_dir, "delegation.heartbeat.#{tok4}")
    FileUtils.touch(hb, mtime: Time.now - 60)
    assert('stale heartbeat -> crashed') { d.status == 'crashed' }
    FileUtils.rm_f(hb)
    stale_pending = JSON.parse(File.read(File.join(s.guard_dir, 'delegation.json')))
    stale_pending['spawned_at'] = (Time.now - 120).utc.iso8601
    File.write(File.join(s.guard_dir, 'delegation.json'), JSON.generate(stale_pending))
    assert('no heartbeat past startup grace -> crashed') { d.status == 'crashed' }
    d.write_result({ 'status' => 'ok', 'state' => 'proposed' })
    assert('matching anchor+action result -> ready (even after crash markers)') { d.status == 'ready' }
    assert('a result whose action_key mismatches the pending handle does NOT read ready') do
      res = JSON.parse(File.read(File.join(s.guard_dir, 'delegation_result.json')))
      res['action_key'] = 'revise:zzzz'
      File.write(File.join(s.guard_dir, 'delegation_result.json'), JSON.generate(res))
      d.status != 'ready'
    end
    d.clear_pending_if(tok4)
    d.collect # no-op cleanup of any leftover

    puts '== A-2: agent_wait surface + collect-once =='
    FileUtils.rm_f(File.join(s.guard_dir, 'delegation_result.json'))
    wait_tool = KairosMcp::SkillSets::Agent::Tools::AgentWait.new
    _, tokw = d.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    d.write_result({ 'status' => 'ok', 'state' => 'proposed' })
    w1 = JSON.parse(wait_tool.call({ 'session_id' => 'a2s1' })[0][:text])
    assert('wait on ready delegation returns outcome + next_move') do
      w1['status'] == 'ready' && w1['outcome']['state'] == 'proposed' && w1['next_move']
    end
    assert('collect-once: after wait, the result+handle are consumed') do
      d.status == 'none' && !File.exist?(File.join(s.guard_dir, 'delegation_result.json'))
    end
    w2 = JSON.parse(wait_tool.call({ 'session_id' => 'a2s1' })[0][:text])
    assert('wait with no delegation -> no_delegation + agent_status hint') do
      w2['status'] == 'no_delegation' && w2['next_action']['tool'] == 'agent_status'
    end

    puts '== A-2: delegated agent_step end-to-end with stub spawn =='
    s2 = new_seam_session('a2s2')
    tool = SeamStep.new
    ENV['KAIROS_AGENT_WORKER_CMD'] = 'true' # spawn no-op; we drive the worker logic below
    r1 = JSON.parse(tool.call({ 'session_id' => 'a2s2', 'action' => 'approve',
                                'execution' => 'delegated' })[0][:text])
    assert('delegated start returns a step token + agent_wait next_action, executes nothing') do
      r1['status'] == 'delegation_pending' && r1['step_token'] &&
        r1['next_action']['tool'] == 'agent_wait' && tool.approve_runs == 0
    end
    r2 = JSON.parse(tool.call({ 'session_id' => 'a2s2', 'action' => 'approve',
                                'execution' => 'delegated' })[0][:text])
    assert('re-issued delegated start reuses the handle (no double spawn)') do
      r2['reused'] == true && r2['step_token'] == r1['step_token']
    end
    # Simulate the worker: re-enter the gated path with the recorded args
    # (which carry the injected anchor), write the result, LEAVE the handle
    # (teardown is the collector's job now).
    d3 = Delegation.new(s2.guard_dir)
    pending = d3.pending
    assert('recorded worker args carry the injected issue-anchor') do
      pending['arguments']['anchor'] == '0:observed:0'
    end
    worker_result = JSON.parse(tool.call(pending['arguments'].merge('session_id' => 'a2s2'))[0][:text])
    d3.write_result(worker_result)
    w4 = JSON.parse(KairosMcp::SkillSets::Agent::Tools::AgentWait.new
                      .call({ 'session_id' => 'a2s2' })[0][:text])
    assert('worker-executed step lands under the gate; wait collects it with next_move') do
      w4['status'] == 'ready' && w4['outcome']['state'] == 'proposed' &&
        w4['outcome']['anchor'] == '1:proposed:0' && tool.approve_runs == 1
    end
    assert('collected advance is replayable through the gate (A-1 inheritance)') do
      rp = JSON.parse(tool.call({ 'session_id' => 'a2s2', 'action' => 'approve',
                                  'anchor' => '0:observed:0' })[0][:text])
      rp['replayed'] == true && tool.approve_runs == 1
    end

    puts '== A-2: delegated start honors the anchored-retry contract =='
    s6 = new_seam_session('a2s6')
    tool6 = SeamStep.new
    # advance the session inline so a stale anchor is meaningful
    tool6.call({ 'session_id' => 'a2s6', 'action' => 'approve', 'anchor' => '0:observed:0' })
    rj = JSON.parse(tool6.call({ 'session_id' => 'a2s6', 'action' => 'approve',
                                 'anchor' => '0:observed:0', 'execution' => 'delegated' })[0][:text])
    assert('delegated start with a consumed anchor replays (does not spawn a new worker)') do
      rj['replayed'] == true
    end
    ENV.delete('KAIROS_AGENT_WORKER_CMD')

    puts '== A-2: crash-window (b) — committed but no result -> recovered (action-matched) =='
    s5 = new_seam_session('a2s5')
    tool5 = SeamStep.new
    d5 = Delegation.new(s5.guard_dir)
    how5, tok5 = d5.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    # worker commits the gated advance but "dies" before write_result:
    tool5.call(d5.pending['arguments'].merge('session_id' => 'a2s5'))
    FileUtils.touch(File.join(s5.guard_dir, "delegation.heartbeat.#{tok5}"), mtime: Time.now - 60)
    assert('committed-but-no-result handle reports crashed at the delegation layer') do
      how5 == :opened && d5.result.nil? && d5.status == 'crashed'
    end
    w5 = JSON.parse(KairosMcp::SkillSets::Agent::Tools::AgentWait.new
                      .call({ 'session_id' => 'a2s5' })[0][:text])
    assert('agent_wait recovers the committed outcome from the gate log (action-matched)') do
      w5['status'] == 'ready' && w5['recovered'] == true &&
        w5['outcome']['state'] == 'proposed' && tool5.approve_runs == 1
    end

    puts '== A-2: crashed recovery declines a superseded generation (atomic claim) =='
    # clear_pending_if now returns false when a DIFFERENT token holds the handle,
    # so crashed_response must NOT return a recovered outcome for a stale one.
    s5b = new_seam_session('a2s5b')
    d5b = Delegation.new(s5b.guard_dir)
    _, tokC = d5b.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    assert('clear_pending_if returns true for the owning token') do
      # a NEW handle supersedes; the OLD token no longer owns it
      d5c = Delegation.new(s5b.guard_dir)
      _, tokD = d5c.open_handle({ 'action' => 'approve' }, '1:proposed:0', 'approve')
      d5c.clear_pending_if(tokC) == false && # stale token cannot clear the new handle
        d5c.clear_pending_if(tokD) == true    # owning token clears it
    end

    puts '== A-2: a finishing old worker tags its result with its OWN identity =='
    s7 = new_seam_session('a2s7')
    d7 = Delegation.new(s7.guard_dir)
    _, tokA = d7.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    old_identity = { 'issue_anchor' => '0:observed:0', 'action_key' => 'approve', 'step_token' => tokA }
    # a fresh delegation overtakes the pending file before the old worker writes
    _, tokB = d7.open_handle({ 'action' => 'revise', 'feedback' => 'y' }, '0:observed:0', 'revise:beef')
    # old worker finishes now, tagging with its startup identity (not current pending)
    d7.write_result({ 'status' => 'ok', 'state' => 'proposed' }, identity: old_identity)
    assert('old worker result is NOT read as ready for the new (revise) handle') do
      d7.status != 'ready'
    end
    assert('collect() returns nil (old result does not belong to the new pending)') do
      d7.collect.nil?
    end

    puts '== A-2: step_token completes identity — SAME anchor+action supersede =='
    s7b = new_seam_session('a2s7b')
    d7b = Delegation.new(s7b.guard_dir)
    _, tokOld2 = d7b.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    old_id2 = { 'issue_anchor' => '0:observed:0', 'action_key' => 'approve', 'step_token' => tokOld2 }
    # crash-classify the old handle (past startup grace) so the re-delegation
    # of the SAME judgment opens a FRESH handle with a NEW token
    sp2 = JSON.parse(File.read(File.join(s7b.guard_dir, 'delegation.json')))
    sp2['spawned_at'] = (Time.now - 120).utc.iso8601
    File.write(File.join(s7b.guard_dir, 'delegation.json'), JSON.generate(sp2))
    _, tokNew2 = d7b.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    assert('re-delegation of a crashed same-anchor+action handle gets a NEW token') do
      tokNew2 != tokOld2
    end
    # the old worker (same anchor+action, OLD token) finishes now
    d7b.write_result({ 'status' => 'ok', 'state' => 'proposed' }, identity: old_id2)
    assert('old-token result is NOT ready for the new same-anchor+action handle (token scoped)') do
      d7b.status != 'ready'
    end
    assert('collect() does not consume the old-token result nor remove the NEW pending handle') do
      d7b.collect.nil? && d7b.pending && d7b.pending['step_token'] == tokNew2
    end
    assert('open_handle is pending-centric: a token-mismatched stale result is NOT :ready') do
      # a fresh delegated start for the same judgment sees the stale old-token
      # result but must NOT treat it as :ready (it belongs to a dead worker);
      # the current pending tokNew2 is live -> :existing
      how, tok = d7b.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
      how == :existing && tok == tokNew2
    end

    puts '== A-2: per-token heartbeat — orphan worker cannot mask a new crash =='
    s8 = new_seam_session('a2s8')
    d8 = Delegation.new(s8.guard_dir)
    _, tokOld = d8.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    d8.touch_heartbeat(tokOld)
    # a fresh delegation supersedes it; the NEW worker never heartbeats (it crashed at startup)
    _, tokNew = d8.open_handle({ 'action' => 'revise', 'feedback' => 'z' }, '0:observed:0', 'revise:cafe')
    # the orphaned OLD worker keeps touching ITS OWN heartbeat
    d8.touch_heartbeat(tokOld)
    assert('old worker heartbeat does NOT keep the new (crashed) handle alive') do
      # new handle has no fresh heartbeat of its own; spawned_at is recent so
      # it is within startup grace (still_pending), but crucially NOT masked as
      # still_pending by the OLD worker's heartbeat once grace passes.
      hbn = File.join(s8.guard_dir, "delegation.heartbeat.#{tokNew}")
      hbo = File.join(s8.guard_dir, "delegation.heartbeat.#{tokOld}")
      # force past startup grace
      sp = JSON.parse(File.read(File.join(s8.guard_dir, 'delegation.json')))
      sp['spawned_at'] = (Time.now - 120).utc.iso8601
      File.write(File.join(s8.guard_dir, 'delegation.json'), JSON.generate(sp))
      File.exist?(hbo) && !File.exist?(hbn) && d8.status == 'crashed'
    end

    puts '== A-2: bootstrap-failure result is identity-tagged (surfaced as ready) =='
    s9 = new_seam_session('a2s9')
    d9 = Delegation.new(s9.guard_dir)
    _, tok9 = d9.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    # simulate the worker's bootstrap fallback writing a raw, identity-tagged result
    identity9 = { 'issue_anchor' => '0:observed:0', 'action_key' => 'approve', 'step_token' => tok9 }
    File.write(File.join(s9.guard_dir, 'delegation_result.json'),
               JSON.generate(identity9.merge('outcome' => { 'status' => 'error', 'error' => 'worker bootstrap failed: LoadError' })))
    assert('a bootstrap-failure result tagged with the handle identity reads as ready') do
      d9.status == 'ready'
    end
  end
rescue LoadError => e
  puts "  SKIP: A-2 probes (#{e.message})"
end

# ---- A-2: REAL detached worker smoke test (the make-or-break bootstrap) ----
# Spawns the actual bin/agent_step_worker.rb against a real session and a real
# ToolRegistry built from the template skillset under review, and asserts the
# worker resolves agent_step, runs the gated advance, and writes a collectable
# result. This is the coverage the stubbed probes cannot provide.
begin
  require 'open3'
  agent_dir = File.expand_path('..', __dir__)
  server_lib = File.expand_path('../../../lib', agent_dir) # KairosChain_mcp_server/lib
  worker = File.join(agent_dir, 'bin', 'agent_step_worker.rb')

  if File.exist?(File.join(server_lib, 'kairos_mcp', 'tool_registry.rb'))
    Dir.mktmpdir('resilience_realworker_') do |proj|
      data_dir = File.join(proj, '.kairos')
      # Install the template agent skillset (+ its deps' presence is assumed in
      # the real tree) so ToolRegistry can load it from the data dir.
      skills_dst = File.join(data_dir, 'skillsets', 'agent')
      FileUtils.mkdir_p(File.dirname(skills_dst))
      FileUtils.cp_r(agent_dir, skills_dst)

      puts '== A-2: real detached worker bootstrap smoke test =='
      # Create a session in the data dir via a registry in-process, so the
      # session record the worker loads is real.
      env = { 'KAIROS_DATA_DIR' => data_dir, 'KAIROS_SERVER_LIB' => server_lib,
              'KAIROS_PROJECT_ROOT' => proj }
      setup = <<~RUBY
        Dir.chdir(#{proj.inspect})
        $LOAD_PATH.unshift(#{server_lib.inspect})
        $LOAD_PATH.unshift(#{File.join(skills_dst, 'lib').inspect})
        require 'kairos_mcp/invocation_context'
        require 'agent/session'
        S = KairosMcp::SkillSets::Agent::Session
        s = S.new(session_id: 'rw1', mandate_id: 'm', goal_name: 'g',
                  invocation_context: KairosMcp::InvocationContext.new, config: {}, autonomous: false)
        s.update_state('checkpoint'); s.save
        # open a delegation handle for a 'stop' step (no LLM needed) at the current anchor
        require 'agent/advance_gate'; require 'agent/step_delegation'
        g = KairosMcp::SkillSets::Agent::AdvanceGate.new(s.guard_dir)
        d = KairosMcp::SkillSets::Agent::StepDelegation.new(s.guard_dir)
        d.open_handle({ 'action' => 'stop' }, g.current_anchor(s), 'stop')
        puts File.expand_path(s.guard_dir)
      RUBY
      out, st = Open3.capture2e(env, RbConfig.ruby, '-e', setup)
      guard_dir = out.lines.last&.strip

      if st.success? && guard_dir && Dir.exist?(guard_dir)
        # Run the REAL worker (foreground for determinism: KAIROS_AGENT_WORKER
        # is not stubbed here).
        wout, = Open3.capture2e(env, RbConfig.ruby, worker, 'rw1', guard_dir)
        result_file = File.join(guard_dir, 'delegation_result.json')
        # Poll briefly for the result (worker detaches via setsid but we ran it
        # foreground, so it should be present on return).
        20.times { break if File.exist?(result_file); sleep 0.1 }
        assert('real worker resolved agent_step, ran the gated stop, wrote a result') do
          File.exist?(result_file) &&
            (JSON.parse(File.read(result_file)).dig('outcome', 'state') == 'terminated')
        end
        assert('real worker left the handle for the collector (teardown is collect-owned)') do
          File.exist?(File.join(guard_dir, 'delegation.json')) &&
            JSON.parse(File.read(result_file))['action_key'] == 'stop'
        end
      else
        puts "  SKIP: real-worker smoke test setup failed (#{out.lines.last&.strip})"
      end
    end
  else
    puts '  SKIP: real-worker smoke test (server lib not found at expected path)'
  end
rescue StandardError => e
  puts "  SKIP: real-worker smoke test (#{e.class}: #{e.message})"
end

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
