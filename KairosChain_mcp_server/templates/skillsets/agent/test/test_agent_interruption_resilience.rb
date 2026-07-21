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
  assert('intent whose advance committed is stale, auto-cleaned, not unresolved') do
    gate.unresolved_intent.nil? && !File.exist?(File.join(dir, 'act_intent.json'))
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

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
