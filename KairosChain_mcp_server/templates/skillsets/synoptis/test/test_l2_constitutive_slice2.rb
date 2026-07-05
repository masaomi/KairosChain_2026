# frozen_string_literal: true

# Slice 2 unit tests: supersession + revocation-withdrawal + fold (LED-2b, ACT-3, §Kinds).
# Pure Ruby (no MMP). Run from project root:
#   ruby -I KairosChain_mcp_server/templates/skillsets/synoptis/lib \
#     KairosChain_mcp_server/templates/skillsets/synoptis/test/test_l2_constitutive_slice2.rb

require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'

lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'synoptis/registry/file_registry'
require 'synoptis/constitutive/content_attestation_entry'
require 'synoptis/constitutive/revocation_withdrawal_entry'
require 'synoptis/constitutive/attestation_chain'

$pass = 0
$fail = 0

def assert(cond, msg)
  if cond
    $pass += 1
    puts "  PASS: #{msg}"
  else
    $fail += 1
    puts "  FAIL: #{msg}"
  end
end

def section(t)
  puts "\n#{'=' * 60}\nSECTION: #{t}\n#{'=' * 60}"
end

CAE = Synoptis::Constitutive::ContentAttestationEntry
RWE = Synoptis::Constitutive::RevocationWithdrawalEntry
AC  = Synoptis::Constitutive::AttestationChain

SUBJ = 'context://s1/ctx_a'
OTHER = 'context://s1/ctx_b'

Dir.mktmpdir do |root|
  reg = Synoptis::Registry::FileRegistry.new(data_dir: root)
  chain = AC.new(registry: reg)

  # ---------------------------------------------------------------
  section('Entry shapes (§Kinds)')

  sup = CAE.new(subject_id: SUBJ, digest: 'd2', moment: 'm2', target_ref: 'e1')
  assert(sup.supersession?, 'content-attestation with target_ref is a supersession')
  assert(CAE.new(subject_id: SUBJ, digest: 'd1', moment: 'm1').supersession? == false, 'first attestation is not a supersession')
  assert(sup.to_h[:target_ref] == 'e1', 'supersession to_h carries target_ref')

  rev = RWE.new(subject_id: SUBJ, target_ref: 'e1', moment: 'm3')
  rh = rev.to_h
  assert(rh[:kind] == 'revocation_withdrawal', 'revocation kind correct')
  assert(rh[:target_ref] == 'e1', 'revocation binds target_ref')
  assert(!rh.key?(:digest) && !rh.key?(:snapshot), 'revocation commits no digest / no content (§Kinds)')
  assert(RWE.from_h(rev.to_h).entry_hash == rev.entry_hash, 'revocation from_h round-trips hash')

  # ---------------------------------------------------------------
  section('Fold: first → supersession → withdrawal → re-attest')

  e1 = CAE.new(subject_id: SUBJ, digest: 'd1', moment: 'm1')
  chain.append_content_attestation(e1)
  st = chain.current_state(SUBJ)
  assert(st[:status] == 'attested', 'after first attestation: status attested')
  assert(st[:head][:entry_id] == e1.entry_id, 'head is the first entry')
  assert(st[:head][:target_ref].nil?, 'first head has no target_ref')

  e2 = CAE.new(subject_id: SUBJ, digest: 'd2', moment: 'm2', target_ref: e1.entry_id)
  chain.append_content_attestation(e2)
  st = chain.current_state(SUBJ)
  assert(st[:status] == 'attested', 'after supersession: status attested')
  assert(st[:head][:entry_id] == e2.entry_id, 'head is the supersession')
  assert(st[:head][:target_ref] == e1.entry_id, 'supersession head points at the entry it superseded (LED-2b)')

  rev1 = RWE.new(subject_id: SUBJ, target_ref: e2.entry_id, moment: 'm3')
  chain.append_revocation_withdrawal(rev1)
  st = chain.current_state(SUBJ)
  assert(st[:status] == 'withdrawn', 'after withdrawing the head: status withdrawn')
  assert(st[:head].nil?, 'no live head after withdrawal')

  e3 = CAE.new(subject_id: SUBJ, digest: 'd3', moment: 'm4')
  chain.append_content_attestation(e3)
  st = chain.current_state(SUBJ)
  assert(st[:status] == 'attested', 're-attest after withdrawal: status attested')
  assert(st[:head][:entry_id] == e3.entry_id && st[:head][:target_ref].nil?,
         're-attest after withdrawal is a fresh first attestation (no target)')

  # ---------------------------------------------------------------
  section('Append-only: history retained, chain valid, subject isolation')

  assert(chain.entries_for(SUBJ).length == 4, 'all 4 acts retained in history (nothing erased)')
  assert(chain.entries.length == 4, 'ledger has 4 lines total (one subject so far)')
  vc = chain.verify_chain(AC::LEDGER)
  assert(vc[:valid] && vc[:length] == 4, 'hash chain valid across mixed entry kinds')

  # revocation of a non-head (already-superseded) entry does not change the head
  chain.append_content_attestation(CAE.new(subject_id: OTHER, digest: 'x1', moment: 'n1'))
  other_head = chain.current_head(OTHER)
  chain.append_revocation_withdrawal(RWE.new(subject_id: SUBJ, target_ref: e1.entry_id, moment: 'm5'))
  assert(chain.current_head(SUBJ)[:entry_id] == e3.entry_id, 'withdrawing a non-head entry does not change the head')
  assert(chain.current_head(OTHER)[:entry_id] == other_head[:entry_id], 'subject isolation: OTHER unaffected by SUBJ acts')
  assert(chain.entries_for(OTHER).length == 1, 'entries_for filters by subject')

  # ---------------------------------------------------------------
  section('Withdraw a subject with no live attestation → head stays nil')

  none_subj = 'context://s1/never'
  assert(chain.current_head(none_subj).nil?, 'never-attested subject has no head')
  assert(chain.current_state(none_subj)[:status] == 'none', 'never-attested status is none')
end

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed"
puts '=' * 60
exit($fail.zero? ? 0 : 1)
