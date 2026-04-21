#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.2 M2 — ApprovalGate tests.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'
require 'digest'

require 'kairos_mcp/daemon/approval_gate'

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
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

AG = KairosMcp::Daemon::ApprovalGate

def make_proposal(id: 'prop_test1', scope: :l1)
  {
    proposal_id: id,
    mandate_id: 'mandate_1',
    target: { path: '.kairos/knowledge/foo.md', pre_hash: 'sha256:abc' },
    edit: { old_string: 'old', new_string: 'new', replace_all: false, proposed_post_hash: 'sha256:def' },
    scope: { scope: scope, auto_approve: scope == :l2, matched_rule: :knowledge }
  }
end

# ---------------------------------------------------------------------------

section 'ApprovalGate: stage and status'

Dir.mktmpdir('ag_test') do |dir|
  now = Time.utc(2026, 4, 21, 12, 0, 0)
  gate = AG.new(dir: dir, clock: -> { now })

  assert('T16: stage returns pending_approval status') do
    p = gate.stage(make_proposal)
    p[:status] == 'pending_approval' && p[:proposal_hash].start_with?('sha256:')
  end

  assert('T16b: status_of is :pending after stage') do
    gate.status_of('prop_test1') == :pending
  end

  assert('T16c: proposal file exists with correct permissions') do
    path = File.join(dir, 'prop_test1.json')
    File.exist?(path) && (File.stat(path).mode & 0o777) == 0o600
  end

  assert('T16d: proposal file contains proposal_hash') do
    data = JSON.parse(File.read(File.join(dir, 'prop_test1.json')))
    data['proposal_hash']&.start_with?('sha256:')
  end
end

section 'ApprovalGate: auto_approve'

Dir.mktmpdir('ag_test') do |dir|
  now = Time.utc(2026, 4, 21, 12, 0, 0)
  gate = AG.new(dir: dir, clock: -> { now })

  assert('T17: auto_approve → :approved immediately') do
    gate.auto_approve(make_proposal(id: 'prop_auto1', scope: :l2))
    gate.status_of('prop_auto1') == :approved
  end

  assert('T17b: auto_approve creates decision file') do
    d = gate.read_decision('prop_auto1')
    d && d['decision'] == 'approve' && d['reviewer'] == 'policy:auto_approve'
  end

  assert('T17c: decision includes proposal_hash') do
    d = gate.read_decision('prop_auto1')
    p = gate.read_proposal('prop_auto1')
    d['proposal_hash'] == p['proposal_hash']
  end
end

section 'ApprovalGate: expiry'

Dir.mktmpdir('ag_test') do |dir|
  t = Time.utc(2026, 4, 21, 12, 0, 0)
  current = t
  gate = AG.new(dir: dir, clock: -> { current })

  gate.stage(make_proposal(id: 'prop_exp1'))

  assert('T18: before expiry → :pending') do
    gate.status_of('prop_exp1') == :pending
  end

  # Advance clock past TTL (8h default)
  current = t + 28_801

  assert('T18b: after expiry → :expired') do
    gate.status_of('prop_exp1') == :expired
  end
end

section 'ApprovalGate: record_decision'

Dir.mktmpdir('ag_test') do |dir|
  now = Time.utc(2026, 4, 21, 12, 0, 0)
  gate = AG.new(dir: dir, clock: -> { now })

  gate.stage(make_proposal(id: 'prop_dec1'))
  gate.record_decision('prop_dec1', decision: 'approve', reviewer: 'masa', reason: 'looks good')

  assert('T19: approved after record_decision') do
    gate.status_of('prop_dec1') == :approved
  end

  assert('T19b: double decision → ConflictError') do
    begin
      gate.record_decision('prop_dec1', decision: 'reject', reviewer: 'masa')
      false
    rescue AG::ConflictError
      true
    end
  end
end

section 'ApprovalGate: expired decision attempt'

Dir.mktmpdir('ag_test') do |dir|
  t = Time.utc(2026, 4, 21, 12, 0, 0)
  current = t
  gate = AG.new(dir: dir, clock: -> { current })

  gate.stage(make_proposal(id: 'prop_edec1'))
  current = t + 28_801

  assert('T20: record_decision on expired → ExpiredError') do
    begin
      gate.record_decision('prop_edec1', decision: 'approve', reviewer: 'masa')
      false
    rescue AG::ExpiredError
      true
    end
  end
end

section 'ApprovalGate: consume_grant'

Dir.mktmpdir('ag_test') do |dir|
  now = Time.utc(2026, 4, 21, 12, 0, 0)
  gate = AG.new(dir: dir, clock: -> { now })

  gate.stage(make_proposal(id: 'prop_cg1'))

  assert('T21: consume_grant returns nil when pending') do
    gate.consume_grant('prop_cg1').nil?
  end

  gate.record_decision('prop_cg1', decision: 'approve', reviewer: 'masa')

  assert('T21b: consume_grant returns ApprovalGrant when approved') do
    g = gate.consume_grant('prop_cg1')
    g.is_a?(AG::ApprovalGrant) &&
      g.proposal_id == 'prop_cg1' &&
      g.decision['decision'] == 'approve' &&
      g.proposal.is_a?(Hash)
  end
end

section 'ApprovalGate: proposal integrity verification (MF6)'

Dir.mktmpdir('ag_test') do |dir|
  now = Time.utc(2026, 4, 21, 12, 0, 0)
  gate = AG.new(dir: dir, clock: -> { now })

  gate.stage(make_proposal(id: 'prop_int1'))
  gate.record_decision('prop_int1', decision: 'approve', reviewer: 'masa')

  assert('T22b: verify_proposal_integrity returns true for untampered') do
    gate.verify_proposal_integrity('prop_int1')
  end

  assert('T22c: verify_proposal_integrity returns false after tampering') do
    path = File.join(dir, 'prop_int1.json')
    data = JSON.parse(File.read(path))
    data['target']['path'] = '.kairos/skills/evil.rb'  # tamper
    File.write(path, JSON.pretty_generate(data))
    !gate.verify_proposal_integrity('prop_int1')
  end
end

section 'ApprovalGate: canonical JSON determinism'

Dir.mktmpdir('ag_test') do |dir|
  now = Time.utc(2026, 4, 21, 12, 0, 0)
  gate = AG.new(dir: dir, clock: -> { now })

  # Two proposals with same content but different key insertion order
  p1 = { proposal_id: 'prop_ord1', target: { path: 'a' }, edit: { old: 'x', new: 'y' } }
  p2 = { edit: { new: 'y', old: 'x' }, proposal_id: 'prop_ord1', target: { path: 'a' } }

  s1 = gate.stage(p1)
  # Clean up for second attempt
  File.delete(File.join(dir, 'prop_ord1.json'))
  s2 = gate.stage(p2)

  assert('T22d: canonical hash is same regardless of key order') do
    s1[:proposal_hash] == s2[:proposal_hash]
  end
end

section 'ApprovalGate: error cases'

Dir.mktmpdir('ag_test') do |dir|
  gate = AG.new(dir: dir)

  assert('T22e: stage without proposal_id → ArgumentError') do
    begin
      gate.stage({ target: 'x' })
      false
    rescue ArgumentError
      true
    end
  end

  assert('T22f: status_of unknown → :not_found') do
    gate.status_of('nonexistent') == :not_found
  end

  assert('T22g: record_decision on unknown → NotFoundError') do
    begin
      gate.record_decision('nonexistent', decision: 'approve', reviewer: 'x')
      false
    rescue AG::NotFoundError
      true
    end
  end

  assert('T22h: invalid decision → ArgumentError') do
    begin
      gate.record_decision('x', decision: 'maybe', reviewer: 'x')
      false
    rescue ArgumentError
      true
    end
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
