#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# Slice S1: per-entry governing_identity (AHM-3 / AHM-4 / AHM-7)
# ============================================================================
# Realizes attestation_home_migration_design_v0.3, invariants:
#   - AHM-3: same_party/foreign relation resolves against the entry's OWN
#     governing_identity (fixed at commit), not a single current op. Withdrawal
#     authority resolves via the committed depositor OR the current owning agent,
#     which inherits the operator/takedown role on ownership transfer (AHM-7) —
#     it is NOT resolved against the per-entry governing_identity directly.
#   - AHM-4: governing_identity is excluded from canonical_content, so adding /
#     backfilling it must NOT perturb a committed entry's entry_hash. This
#     protects the frozen production citation (v1.7).
#   - AHM-7: when the owning identity changes (op boundary moves), old-format
#     entries inherit the legacy governing_identity; their relation is preserved.
#
# Usage:  ruby test_anchor_governing_identity.rb
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/mmp/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/synoptis/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/hestia/lib', __dir__)

require 'kairos_mcp'
require 'mmp'
require 'synoptis'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'

$pass = 0
$fail = 0
def assert(msg)
  ok = yield
  puts(ok ? "  PASS: #{msg}" : "  FAIL: #{msg}")
  ok ? $pass += 1 : $fail += 1
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail += 1
end

def digest_for(str)
  Digest::SHA256.hexdigest(str)
end

Dir.mktmpdir do |dir|
  # ------------------------------------------------------------------------
  puts "\n[1] New anchor: governing_identity == owning op; relation same_party"
  path1 = File.join(dir, 'log1.json')
  log = Synoptis::Anchoring::Log.new(storage_path: path1, operator_id: 'opA')
  e = log.append_anchor(digest: digest_for('paper'), anchor_type: 'constitutive_note',
                        source_id: 'place://p/anchor/1', depositor: 'opA')
  assert('new anchor carries governing_identity == opA') { e.governing_identity == 'opA' }

  pv = Synoptis::Anchoring::PublicVerifier.new(log: log)
  rec = pv.get(e.entry_hash)
  assert('PublicVerifier relation == :same_party') { rec[:relation] == :same_party }

  # ------------------------------------------------------------------------
  puts "\n[2] OLD-format entry (no governing_identity) backfilled; entry_hash UNCHANGED"
  # Construct an entry exactly as the pre-migration code would have: governing
  # identity was not a field, so it is absent. Its entry_hash is computed from
  # canonical_content, which never included governing_identity.
  old_entry = Synoptis::Anchoring::Entry.anchor(
    position: 0, prev: nil, digest: digest_for('frozen-v1.7'),
    anchor_type: 'custom.constitutive_note',
    source_id: 'place://p/anchor/constitutive-note-v1_7', depositor: 'opA',
    external_reference: 'https://doi.org/10.5281/zenodo.100'
  )
  original_hash = old_entry.entry_hash

  # Serialize to the on-disk shape and strip the governing_identity key entirely
  # (a genuinely old store predates the field).
  h = old_entry.to_h
  h.delete('governing_identity')
  assert('simulated old store has NO governing_identity key') { !h.key?('governing_identity') }

  path2 = File.join(dir, 'log2_old_format.json')
  File.write(path2, JSON.pretty_generate(
    'metadata' => { 'version' => '1.0', 'length' => 1, 'head' => original_hash },
    'entries' => [h]
  ))

  # The op boundary has moved: owning identity is now agentB, but the legacy
  # governing identity (opA) is supplied for backfill (AHM-7).
  reloaded = Synoptis::Anchoring::Log.new(storage_path: path2,
                                          operator_id: 'agentB',
                                          legacy_governing_identity: 'opA')
  loaded = reloaded.get(original_hash)
  assert('loaded entry found by its original entry_hash') { !loaded.nil? }
  assert('entry_hash is byte-identical after load (AHM-4)') { loaded.entry_hash == original_hash }
  assert('chain still verifies (head == original_hash)') do
    v = reloaded.verify
    v[:valid] == true && v[:head] == original_hash
  end
  assert('backfilled governing_identity == opA (AHM-7)') { loaded.governing_identity == 'opA' }
  assert('log operator_id is now agentB (boundary moved)') { reloaded.operator_id == 'agentB' }

  pv2 = Synoptis::Anchoring::PublicVerifier.new(log: reloaded)
  rec2 = pv2.get(original_hash)
  assert('relation == :same_party via per-entry governing (opA==opA), NOT current op agentB') do
    rec2[:relation] == :same_party
  end

  # ------------------------------------------------------------------------
  puts "\n[3] Foreign case: same governing (opA) but a different depositor (opX)"
  path3 = File.join(dir, 'log3.json')
  log3 = Synoptis::Anchoring::Log.new(storage_path: path3, operator_id: 'opA')
  same = log3.append_anchor(digest: digest_for('self'), anchor_type: 'generic',
                            source_id: 'place://p/anchor/self', depositor: 'opA')
  foreign = log3.append_anchor(digest: digest_for('other'), anchor_type: 'generic',
                               source_id: 'place://p/anchor/other', depositor: 'opX')
  assert('both entries governed by opA') do
    same.governing_identity == 'opA' && foreign.governing_identity == 'opA'
  end
  pv3 = Synoptis::Anchoring::PublicVerifier.new(log: log3)
  assert('depositor opA under governing opA => :same_party') { pv3.get(same.entry_hash)[:relation] == :same_party }
  assert('depositor opX under governing opA => :foreign') { pv3.get(foreign.entry_hash)[:relation] == :foreign }

  # Helper: write a genuinely old-format single-entry store (no governing_identity
  # key) for +depositor+, returning [path, entry_hash].
  build_old_store = lambda do |name, depositor|
    ent = Synoptis::Anchoring::Entry.anchor(
      position: 0, prev: nil, digest: digest_for(name), anchor_type: 'generic',
      source_id: "place://p/anchor/#{name}", depositor: depositor
    )
    hh = ent.to_h
    hh.delete('governing_identity')
    pth = File.join(dir, "#{name}.json")
    File.write(pth, JSON.pretty_generate(
      'metadata' => { 'version' => '1.0', 'length' => 1, 'head' => ent.entry_hash },
      'entries' => [hh]
    ))
    [pth, ent.entry_hash]
  end

  # ------------------------------------------------------------------------
  puts "\n[4] Re-save round trip: persisted governing survives, not re-backfilled to a 3rd op"
  # Force a save of the [2] log (backfilled old entry now materialized to disk),
  # then reload under a THIRD operator with NO legacy hint. The old entry must
  # read its persisted governing_identity (opA), never re-backfill to agentC.
  reloaded.append_anchor(digest: digest_for('second'), anchor_type: 'generic',
                         source_id: 'place://p/anchor/2', depositor: 'agentB')
  reloaded3 = Synoptis::Anchoring::Log.new(storage_path: path2, operator_id: 'agentC')
  back = reloaded3.get(original_hash)
  assert('re-saved old entry keeps entry_hash after round trip (AHM-4)') { back.entry_hash == original_hash }
  assert('persisted governing stays opA, NOT re-backfilled to agentC') { back.governing_identity == 'opA' }
  pv4 = Synoptis::Anchoring::PublicVerifier.new(log: reloaded3)
  assert('relation stays :same_party across re-save round trip') { pv4.get(original_hash)[:relation] == :same_party }

  # ------------------------------------------------------------------------
  puts "\n[5] Foreign OLD-format entry stays :foreign after uniform backfill"
  path5, fh5 = build_old_store.call('foreign_old', 'opX')
  rl5 = Synoptis::Anchoring::Log.new(storage_path: path5, operator_id: 'agentB',
                                     legacy_governing_identity: 'opA')
  l5 = rl5.get(fh5)
  assert('foreign old entry entry_hash unchanged') { l5.entry_hash == fh5 }
  assert('backfilled governing == opA') { l5.governing_identity == 'opA' }
  pv5 = Synoptis::Anchoring::PublicVerifier.new(log: rl5)
  assert('depositor opX != governing opA => :foreign preserved') { pv5.get(fh5)[:relation] == :foreign }

  # ------------------------------------------------------------------------
  puts "\n[6] Withdrawal authority across a boundary move (owner inherits; depositor self; stranger rejected)"
  p6a, h6a = build_old_store.call('wd_owner', 'opA')
  lg6a = Synoptis::Anchoring::Log.new(storage_path: p6a, operator_id: 'agentB',
                                      legacy_governing_identity: 'opA')
  assert('owning agent agentB (inherits operator role, AHM-7) may withdraw old entry') do
    !lg6a.append_withdrawal(target: h6a, withdrawer: 'agentB').nil?
  end

  p6b, h6b = build_old_store.call('wd_depositor', 'opA')
  lg6b = Synoptis::Anchoring::Log.new(storage_path: p6b, operator_id: 'agentB',
                                      legacy_governing_identity: 'opA')
  assert('committed depositor opA may self-withdraw after the move') do
    !lg6b.append_withdrawal(target: h6b, withdrawer: 'opA').nil?
  end

  p6c, h6c = build_old_store.call('wd_stranger', 'opA')
  lg6c = Synoptis::Anchoring::Log.new(storage_path: p6c, operator_id: 'agentB',
                                      legacy_governing_identity: 'opA')
  assert('unrelated opZ may NOT withdraw (not depositor, not owning agent)') do
    lg6c.append_withdrawal(target: h6c, withdrawer: 'opZ')
    false
  rescue Synoptis::Anchoring::UnauthorizedWithdrawal
    true
  end
end

puts "\n" + ('=' * 60)
puts "RESULT: #{$pass} passed, #{$fail} failed"
puts('=' * 60)
exit($fail.zero? ? 0 : 1)
