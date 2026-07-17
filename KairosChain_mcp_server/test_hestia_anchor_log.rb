#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# Slice 1 / 2A: Hestia Anchor Log (ANC-1) Test
# ============================================================================
# Realizes design hestia_anchor_attestation_design_v0.5, invariant ANC-1:
#   - append-only, hash-chained, headed
#   - recompute detects reorder / in-place edit / deletion
#   - withdrawal-by-append keeps the target readable and the lineage recomputable
#
# Usage:
#   ruby test_hestia_anchor_log.rb
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/mmp/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/synoptis/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/hestia/lib', __dir__)

require 'kairos_mcp'
require 'mmp'
require 'synoptis'
require 'hestia'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'

$pass_count = 0
$fail_count = 0

def assert(msg)
  ok = yield
  if ok
    puts "  PASS: #{msg}"
    $pass_count += 1
  else
    puts "  FAIL: #{msg}"
    $fail_count += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (raised #{e.class}: #{e.message})"
  $fail_count += 1
end

def digest_for(str)
  Digest::SHA256.hexdigest(str)
end

# Read/write the append-line anchor store (one JSON entry per line). Used by the
# tamper tests to reach into the persisted chain and by the torn-tail test.
def read_store_entries(path)
  File.readlines(path).map(&:strip).reject(&:empty?).map { |l| JSON.parse(l) }
end

def write_store_entries(path, entries)
  File.write(path, entries.map { |h| JSON.generate(h) }.join("\n") + "\n")
end

Dir.mktmpdir do |dir|
  path = File.join(dir, 'anchor_log.json')

  # --------------------------------------------------------------------------
  puts "\n[1] Append + head + positions"
  log = Synoptis::Anchoring::Log.new(storage_path: path)
  assert('empty log has nil head') { log.head.nil? }
  e0 = log.append_anchor(digest: digest_for('a'), anchor_type: 'constitutive_note',
                         source_id: 'place://p/anchor/1', depositor: 'op',
                         external_reference: 'https://doi.org/10.5281/zenodo.1')
  e1 = log.append_anchor(digest: digest_for('b'), anchor_type: 'generic',
                         source_id: 'place://p/anchor/2', depositor: 'op')
  e2 = log.append_anchor(digest: digest_for('c'), anchor_type: 'generic',
                         source_id: 'place://p/anchor/3', depositor: 'peer1')
  assert('positions are 0,1,2') { [e0.position, e1.position, e2.position] == [0, 1, 2] }
  assert('genesis prev is nil') { e0.prev.nil? }
  assert('e1 binds e0 head') { e1.prev == e0.entry_hash }
  assert('e2 binds e1 head') { e2.prev == e1.entry_hash }
  assert('head is last entry_hash') { log.head == e2.entry_hash }
  assert('length is 3') { log.length == 3 }

  # --------------------------------------------------------------------------
  puts "\n[2] Verify clean chain"
  v = log.verify
  assert('clean chain is valid') { v[:valid] == true }
  assert('verify reports head') { v[:head] == e2.entry_hash }
  assert('verify reports length 3') { v[:length] == 3 }

  # --------------------------------------------------------------------------
  puts "\n[3] Lookup indices (chain-length-independent)"
  assert('find_by_digest hits') { log.find_by_digest(digest_for('b')).map(&:entry_hash) == [e1.entry_hash] }
  assert('find_by_source_id hits') { log.find_by_source_id('place://p/anchor/3').map(&:entry_hash) == [e2.entry_hash] }
  assert('get by entry_hash') { log.get(e0.entry_hash).digest == digest_for('a') }

  # --------------------------------------------------------------------------
  puts "\n[4] Detect in-place EDIT (tamper stored digest)"
  raw = read_store_entries(path)
  raw[1]['body']['digest'] = digest_for('EVIL')
  write_store_entries(path, raw)
  tampered = Synoptis::Anchoring::Log.new(storage_path: path)
  ve = tampered.verify
  assert('edit is detected') { ve[:valid] == false }
  assert('edit broken_at == 1') { ve[:broken_at] == 1 }
  assert('edit reason is hash_mismatch') { ve[:reason] == 'hash_mismatch' }

  # --------------------------------------------------------------------------
  puts "\n[5] Detect REORDER (swap two entries)"
  raw = read_store_entries(path)
  raw[1]['body']['digest'] = digest_for('b') # undo edit
  raw[0], raw[1] = raw[1], raw[0]
  write_store_entries(path, raw)
  reordered = Synoptis::Anchoring::Log.new(storage_path: path)
  vr = reordered.verify
  assert('reorder is detected') { vr[:valid] == false }
  assert('reorder broken at 0') { vr[:broken_at] == 0 }

  # --------------------------------------------------------------------------
  puts "\n[6] Detect DELETE (drop middle entry)"
  # rebuild a clean 3-entry log
  FileUtils.rm_f(path)
  log2 = Synoptis::Anchoring::Log.new(storage_path: path)
  d0 = log2.append_anchor(digest: digest_for('x'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  d1 = log2.append_anchor(digest: digest_for('y'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  d2 = log2.append_anchor(digest: digest_for('z'), anchor_type: 'generic', source_id: 's2', depositor: 'op')
  raw = read_store_entries(path)
  raw.delete_at(1) # remove middle
  write_store_entries(path, raw)
  deleted = Synoptis::Anchoring::Log.new(storage_path: path)
  vd = deleted.verify
  assert('delete is detected') { vd[:valid] == false }
  assert('delete broken at 1') { vd[:broken_at] == 1 }

  # --------------------------------------------------------------------------
  puts "\n[7] Withdrawal-by-append keeps target readable + lineage recomputable"
  FileUtils.rm_f(path)
  log3 = Synoptis::Anchoring::Log.new(storage_path: path)
  a = log3.append_anchor(digest: digest_for('note'), anchor_type: 'constitutive_note',
                        source_id: 'place://p/anchor/note', depositor: 'op',
                        external_reference: 'https://doi.org/10.5281/zenodo.9',
                        metadata: { 'title' => 'the note' })
  b = log3.append_anchor(digest: digest_for('other'), anchor_type: 'generic',
                        source_id: 'place://p/anchor/other', depositor: 'op')
  w = log3.append_withdrawal(target: a.entry_hash, withdrawer: 'op', reason: 'superseded')

  assert('withdrawal entry appended (len 3)') { log3.length == 3 }
  assert('withdrawal binds prior head') { w.prev == b.entry_hash }
  assert('target is now withdrawn') { log3.withdrawn?(a.entry_hash) }
  assert('non-target not withdrawn') { !log3.withdrawn?(b.entry_hash) }

  # chain still verifies after withdrawal (append-only, nothing removed)
  vw = log3.verify
  assert('chain valid after withdrawal') { vw[:valid] == true }
  assert('withdrawal head advanced') { vw[:head] == w.entry_hash }

  # target still readable at storage layer (digest/moment/position intact)
  target_raw = log3.get(a.entry_hash)
  assert('withdrawn target digest still readable') { target_raw.digest == digest_for('note') }
  assert('withdrawn target position still readable') { target_raw.position == 0 }

  # view suppresses depositor-supplied surfaced fields, keeps durable fields
  view = log3.view(a.entry_hash)
  assert('view marks withdrawn') { view['withdrawn'] == true }
  assert('view keeps digest') { view['body']['digest'] == digest_for('note') }
  assert('view keeps algorithm') { view['body']['digest_algorithm'] == 'sha256' }
  assert('view keeps depositor') { view['body']['depositor'] == 'op' }
  assert('view keeps moment') { !view['body']['moment'].nil? }
  assert('view suppresses external_reference') { !view['body'].key?('external_reference') }
  assert('view suppresses source_id') { !view['body'].key?('source_id') }
  assert('view suppresses metadata') { !view['body'].key?('metadata') }

  # a non-withdrawn entry's view keeps its surfaced fields navigable
  view_b = log3.view(b.entry_hash)
  assert('non-withdrawn view keeps source_id') { view_b['body']['source_id'] == 'place://p/anchor/other' }

  # withdrawal of an unknown / non-anchor target is rejected
  assert('withdrawing unknown target raises') do
    begin
      log3.append_withdrawal(target: 'deadbeef', withdrawer: 'op'); false
    rescue ArgumentError
      true
    end
  end
  assert('withdrawing a withdrawal entry raises') do
    begin
      log3.append_withdrawal(target: w.entry_hash, withdrawer: 'op'); false
    rescue ArgumentError
      true
    end
  end

  # --------------------------------------------------------------------------
  puts "\n[8] Persistence round-trip"
  reloaded = Synoptis::Anchoring::Log.new(storage_path: path)
  assert('reload preserves length') { reloaded.length == 3 }
  assert('reload preserves head') { reloaded.head == w.entry_hash }
  assert('reload verifies valid') { reloaded.verify[:valid] == true }
  assert('reload preserves withdrawn state') { reloaded.withdrawn?(a.entry_hash) }
  assert('reload preserves digest index') { reloaded.find_by_digest(digest_for('note')).size == 1 }

  # --------------------------------------------------------------------------
  puts "\n[9] Determinism: entry_hash is insertion-order independent"
  h1 = Synoptis::Anchoring::Entry.compute_hash({ 'position' => 0, 'prev' => nil, 'kind' => 'anchor',
                                               'body' => { 'a' => 1, 'b' => 2 } })
  h2 = Synoptis::Anchoring::Entry.compute_hash({ 'body' => { 'b' => 2, 'a' => 1 }, 'kind' => 'anchor',
                                               'prev' => nil, 'position' => 0 })
  assert('canonical hash is key-order independent') { h1 == h2 }

  # --------------------------------------------------------------------------
  puts "\n[10] ANC-2 containment: write-path rejects content"
  FileUtils.rm_f(path)
  clog = Synoptis::Anchoring::Log.new(storage_path: path)
  good = digest_for('ok')

  def rejects(code, msg)
    yield
    puts "  FAIL: #{msg} (no error raised)"; $fail_count += 1
  rescue Synoptis::Anchoring::Containment::ContainmentError => e
    if e.code == code
      puts "  PASS: #{msg}"; $pass_count += 1
    else
      puts "  FAIL: #{msg} (got code #{e.code.inspect}, wanted #{code.inspect})"; $fail_count += 1
    end
  end

  # accepts a clean anchor with safe DOI + inert bounded metadata
  assert('clean anchor accepted') do
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 's', depositor: 'op',
                       external_reference: 'https://doi.org/10.5281/zenodo.1',
                       metadata: { 'title' => 'note', 'version' => 2 })
    clog.length == 1
  end
  assert('doi: scheme accepted') do
    clog.append_anchor(digest: digest_for('ok2'), anchor_type: 'generic', source_id: 's2',
                       depositor: 'op', external_reference: 'doi:10.5281/zenodo.2')
    clog.length == 2
  end

  # digest must be 64-hex sha256
  rejects(:digest_format, 'short digest rejected') do
    clog.append_anchor(digest: 'abc', anchor_type: 'generic', source_id: 'x', depositor: 'op')
  end
  rejects(:digest_format, 'non-hex digest rejected') do
    clog.append_anchor(digest: 'z' * 64, anchor_type: 'generic', source_id: 'x', depositor: 'op')
  end

  # no content: nested metadata / oversized / too many keys rejected
  rejects(:metadata_nested, 'nested metadata rejected (content channel)') do
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 'x', depositor: 'op',
                       metadata: { 'payload' => { 'body' => 'smuggled' } })
  end
  rejects(:metadata_value_too_long, 'oversized metadata value rejected') do
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 'x', depositor: 'op',
                       metadata: { 'blob' => 'A' * 300 })
  end
  rejects(:metadata_too_many_keys, 'too many metadata keys rejected') do
    big = (1..9).each_with_object({}) { |i, h| h["k#{i}"] = i }
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 'x', depositor: 'op', metadata: big)
  end
  rejects(:metadata_key, 'active metadata key rejected') do
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 'x', depositor: 'op',
                       metadata: { 'Bad Key!' => 1 })
  end
  rejects(:metadata_value_active, 'control char in metadata value rejected') do
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 'x', depositor: 'op',
                       metadata: { 'note' => "line1\nline2" })
  end

  # external reference: only https / doi safe schemes
  rejects(:reference_unsafe_scheme, 'javascript: reference rejected') do
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 'x', depositor: 'op',
                       external_reference: 'javascript:alert(1)')
  end
  rejects(:reference_unsafe_scheme, 'http: (cleartext) reference rejected') do
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 'x', depositor: 'op',
                       external_reference: 'http://example.com')
  end
  rejects(:reference_unsafe_scheme, 'data: reference rejected') do
    clog.append_anchor(digest: good, anchor_type: 'generic', source_id: 'x', depositor: 'op',
                       external_reference: 'data:text/html,<script>')
  end

  # withdrawal reason: inert bounded
  a_ok = clog.append_anchor(digest: digest_for('w'), anchor_type: 'generic', source_id: 'sw', depositor: 'op')
  assert('bounded reason accepted') do
    clog.append_withdrawal(target: a_ok.entry_hash, withdrawer: 'op', reason: 'superseded'); true
  end
  a_ok2 = clog.append_anchor(digest: digest_for('w2'), anchor_type: 'generic', source_id: 'sw2', depositor: 'op')
  rejects(:reason_too_long, 'oversized withdrawal reason rejected') do
    clog.append_withdrawal(target: a_ok2.entry_hash, withdrawer: 'op', reason: 'R' * 300)
  end

  # a rejected write must not have advanced the chain
  len_before = clog.length
  begin
    clog.append_anchor(digest: 'nope', anchor_type: 'generic', source_id: 'x', depositor: 'op')
  rescue Synoptis::Anchoring::Containment::ContainmentError
    # expected
  end
  assert('rejected write did not touch the store') { clog.length == len_before }
  assert('chain still valid after rejections') { clog.verify[:valid] == true }

  # --------------------------------------------------------------------------
  puts "\n[11] ANC-5 store-level authority: withdrawal is depositor-or-operator"
  FileUtils.rm_f(path)
  alog = Synoptis::Anchoring::Log.new(storage_path: path, operator_id: 'operator')
  peerA = alog.append_anchor(digest: digest_for('A'), anchor_type: 'generic', source_id: 'sa', depositor: 'peerA')
  peerB_entry = alog.append_anchor(digest: digest_for('B'), anchor_type: 'generic', source_id: 'sb', depositor: 'peerB')

  # attribution guarantee: anonymous deposit rejected even on a direct call
  assert('blank depositor rejected') do
    begin
      alog.append_anchor(digest: digest_for('C'), anchor_type: 'generic', source_id: 'sc', depositor: '  ')
      false
    rescue ArgumentError
      true
    end
  end

  # a third party cannot withdraw someone else's entry
  assert('cross-depositor withdrawal rejected at write time') do
    begin
      alog.append_withdrawal(target: peerA.entry_hash, withdrawer: 'peerB')
      false
    rescue Synoptis::Anchoring::UnauthorizedWithdrawal
      true
    end
  end
  assert('rejected withdrawal did not append') { alog.length == 2 }
  assert('rejected withdrawal left target not withdrawn') { !alog.withdrawn?(peerA.entry_hash) }

  # the depositor may self-withdraw
  assert('depositor self-withdrawal allowed') do
    alog.append_withdrawal(target: peerA.entry_hash, withdrawer: 'peerA')
    alog.withdrawn?(peerA.entry_hash)
  end
  # the operator may withdraw any entry (takedown duty)
  assert('operator withdrawal of another entry allowed') do
    alog.append_withdrawal(target: peerB_entry.entry_hash, withdrawer: 'operator')
    alog.withdrawn?(peerB_entry.entry_hash)
  end
  assert('chain valid after authorized withdrawals') { alog.verify[:valid] == true }

  # --------------------------------------------------------------------------
  puts "\n[12] ANC-5 WritePath: only a verified principal may write, identity is bound"
  FileUtils.rm_f(path)
  wlog = Synoptis::Anchoring::Log.new(storage_path: path, operator_id: 'operator')
  WP = Synoptis::Anchoring::WritePath

  anon = WP.new(log: wlog, principal: nil)
  unverified = WP.new(log: wlog, principal: WP::Principal.new(peer_id: 'peerX', verified: false))
  blankid = WP.new(log: wlog, principal: WP::Principal.new(peer_id: '', verified: true))
  verified = WP.new(log: wlog, principal: WP::Principal.new(peer_id: 'peerX', verified: true))

  assert('nil principal cannot deposit') do
    begin
      anon.deposit(digest: digest_for('x'), anchor_type: 'generic', source_id: 's'); false
    rescue WP::Unauthenticated
      true
    end
  end
  assert('unverified principal cannot deposit') do
    begin
      unverified.deposit(digest: digest_for('x'), anchor_type: 'generic', source_id: 's'); false
    rescue WP::Unauthenticated
      true
    end
  end
  assert('blank-id principal cannot deposit') do
    begin
      blankid.deposit(digest: digest_for('x'), anchor_type: 'generic', source_id: 's'); false
    rescue WP::Unauthenticated
      true
    end
  end
  assert('no unauthenticated write reached the store') { wlog.length == 0 }

  # verified principal writes; depositor is bound to the authenticated peer_id
  entry = verified.deposit(digest: digest_for('x'), anchor_type: 'generic', source_id: 's',
                           external_reference: 'https://doi.org/10.5281/zenodo.7')
  assert('verified principal can deposit') { wlog.length == 1 }
  assert('depositor bound to authenticated peer_id') { entry.depositor == 'peerX' }

  # WritePath#deposit has no depositor parameter -> caller cannot spoof identity
  assert('deposit signature does not accept a depositor arg') do
    !WP.instance_method(:deposit).parameters.map(&:last).include?(:depositor)
  end

  # withdrawal via WritePath is bound + authority-checked by the Log
  other = WP.new(log: wlog, principal: WP::Principal.new(peer_id: 'peerY', verified: true))
  assert('verified non-owner withdrawal rejected by Log authority') do
    begin
      other.withdraw(target: entry.entry_hash); false
    rescue Synoptis::Anchoring::UnauthorizedWithdrawal
      true
    end
  end
  assert('owner withdrawal via WritePath allowed') do
    verified.withdraw(target: entry.entry_hash)
    wlog.withdrawn?(entry.entry_hash)
  end

  # --------------------------------------------------------------------------
  puts "\n[13] BRD-1 unified deposit record: by-reference, kind fixed at deposit"
  logpath = File.join(dir, 'brd_anchor_log.json')
  attpath = File.join(dir, 'brd_attestations.json')
  FileUtils.rm_f(logpath); FileUtils.rm_f(attpath)
  blog = Synoptis::Anchoring::Log.new(storage_path: logpath, operator_id: 'operator')
  board = Synoptis::Anchoring::DepositBoard.new(log: blog, attestation_store_path: attpath)
  P = Synoptis::Anchoring::WritePath::Principal
  opp = P.new(peer_id: 'operator', verified: true)
  peerp = P.new(peer_id: 'peerA', verified: true)

  dep = board.deposit_by_reference(principal: peerp, digest: digest_for('paper'),
                                   source_id: 'place://p/anchor/paper',
                                   retrieval_pointer: 'https://doi.org/10.5281/zenodo.100',
                                   discovery_metadata: { 'title' => 'the paper' })
  assert('deposit is content-by-reference') { dep.availability_kind == :by_reference }
  assert('deposit digest recorded') { dep.digest == digest_for('paper') }
  assert('deposit id is anchor entry_hash') { !blog.get(dep.deposit_id).nil? }
  assert('retrieval pointer is the DOI (BRD-4 locator)') { dep.retrieval_pointer == 'https://doi.org/10.5281/zenodo.100' }
  assert('depositor bound to authenticated peer') { dep.depositor == 'peerA' }
  assert('provenance is append-only lineage') { dep.provenance.first['event'] == 'deposited' }
  # BRD-1 kind immutability: no method to change a deposit's kind
  assert('no mutate-kind method on board') do
    !board.respond_to?(:change_kind) && !board.respond_to?(:set_availability_kind)
  end
  assert('discovery lists the deposit uniformly') { board.list.map(&:deposit_id).include?(dep.deposit_id) }

  # BRD-4: proof is self-contained — survives an absent pointer
  dep_noptr = board.deposit_by_reference(principal: peerp, digest: digest_for('nopointer'),
                                         source_id: 'place://p/anchor/np')
  assert('deposit without pointer still has digest') { dep_noptr.digest == digest_for('nopointer') }
  assert('deposit without pointer has nil pointer') { dep_noptr.retrieval_pointer.nil? }

  # --------------------------------------------------------------------------
  puts "\n[14] BRD-3 attestation: bounded, content-inert, append-only, never aggregated"
  # board must NOT expose any aggregation / scoring surface
  assert('board has no score method') { !board.respond_to?(:score) }
  assert('board has no rank method') { !board.respond_to?(:rank) }
  assert('board has no trust_score / aggregate method') do
    !board.respond_to?(:trust_score) && !board.respond_to?(:aggregate)
  end

  # unauthenticated peer cannot attest
  assert('unverified principal cannot attest') do
    begin
      board.attest(deposit_id: dep.deposit_id, principal: P.new(peer_id: 'x', verified: false),
                   claim_type: 'vouch'); false
    rescue Synoptis::Anchoring::DepositBoard::Unauthenticated
      true
    end
  end

  # a verified peer attests (correspondence claim, bound to the digest)
  att = board.attest(deposit_id: dep.deposit_id, principal: opp, claim_type: 'correspondence',
                     reference: 'https://doi.org/10.5281/zenodo.100', note: 'digest matches Zenodo file')
  assert('attestation attached') { board.attestations_for(dep.deposit_id).size == 1 }
  assert('attestation is attributable') { att['attester'] == 'operator' }
  assert('attestation bound to the deposit digest') { att['bound_digest'] == digest_for('paper') }
  assert('attestation surfaces on the deposit view') { board.get(dep.deposit_id).attestations.size == 1 }

  # content-inertness: free-prose / unbounded / nested rejected
  assert('unknown claim_type rejected') do
    begin
      board.attest(deposit_id: dep.deposit_id, principal: opp, claim_type: 'arbitrary_blob'); false
    rescue Synoptis::Anchoring::Containment::ContainmentError => e
      e.code == :attestation_claim_type
    end
  end
  assert('oversized attestation note rejected') do
    begin
      board.attest(deposit_id: dep.deposit_id, principal: opp, claim_type: 'review', note: 'N' * 300); false
    rescue Synoptis::Anchoring::Containment::ContainmentError => e
      e.code == :text_too_long
    end
  end
  assert('unsafe reference in attestation rejected') do
    begin
      board.attest(deposit_id: dep.deposit_id, principal: opp, claim_type: 'review',
                   reference: 'javascript:alert(1)'); false
    rescue Synoptis::Anchoring::Containment::ContainmentError => e
      e.code == :reference_unsafe_scheme
    end
  end

  # unilateral: any authenticated peer may attest to any deposit
  att2 = board.attest(deposit_id: dep.deposit_id, principal: peerp, claim_type: 'vouch')
  assert('second peer may attest (unilateral)') { board.attestations_for(dep.deposit_id).size == 2 }

  # append-only withdrawal, authority = attester or operator
  assert('non-owner cannot withdraw attestation') do
    begin
      board.withdraw_attestation(attestation_id: att['attestation_id'], principal: peerp); false
    rescue Synoptis::Anchoring::DepositBoard::UnauthorizedAttestationWithdrawal
      true
    end
  end
  assert('attester may withdraw own attestation') do
    board.withdraw_attestation(attestation_id: att2['attestation_id'], principal: peerp)
    board.attestations_for(dep.deposit_id).find { |a| a['attestation_id'] == att2['attestation_id'] }['withdrawn']
  end
  assert('withdrawn attestation stays readable (append-only)') do
    board.attestations_for(dep.deposit_id).size == 2
  end

  # --------------------------------------------------------------------------
  puts "\n[15] BRD persistence round-trip"
  board2 = Synoptis::Anchoring::DepositBoard.new(log: blog, attestation_store_path: attpath)
  assert('reload preserves attestations') { board2.attestations_for(dep.deposit_id).size == 2 }
  assert('reload preserves withdrawn state') do
    board2.attestations_for(dep.deposit_id).find { |a| a['attestation_id'] == att2['attestation_id'] }['withdrawn']
  end

  # withdrawing the deposit itself suppresses its pointer but keeps the digest
  board.instance_variable_get(:@log).append_withdrawal(target: dep.deposit_id, withdrawer: 'operator')
  wd = board.get(dep.deposit_id)
  assert('withdrawn deposit marked withdrawn') { wd.withdrawn == true }
  assert('withdrawn deposit keeps digest') { wd.digest == digest_for('paper') }
  assert('withdrawn deposit suppresses pointer') { wd.retrieval_pointer.nil? }

  # --------------------------------------------------------------------------
  puts "\n[16] 2E authenticated read (ANC-7 slice 1): verify digest, position, pointer"
  rpath = File.join(dir, 'read_anchor_log.json')
  FileUtils.rm_f(rpath)
  rlog = Synoptis::Anchoring::Log.new(storage_path: rpath, operator_id: 'operator')
  rboard = Synoptis::Anchoring::DepositBoard.new(log: rlog, attestation_store_path: File.join(dir, 'read_att.json'))
  RP = Synoptis::Anchoring::ReadPath
  rpeer = Synoptis::Anchoring::WritePath::Principal.new(peer_id: 'peerA', verified: true)

  d1 = rboard.deposit_by_reference(principal: rpeer, digest: digest_for('doc1'),
                                   source_id: 'place://p/anchor/doc1',
                                   retrieval_pointer: 'https://doi.org/10.5281/zenodo.200')
  rboard.attest(deposit_id: d1.deposit_id, principal: rpeer, claim_type: 'correspondence')

  reader = RP.new(log: rlog, principal: rpeer, board: rboard)
  anon_reader = RP.new(log: rlog, principal: Synoptis::Anchoring::WritePath::Principal.new(peer_id: 'x', verified: false))

  # authenticated gate: unverified principal cannot read (public view is slice 2)
  assert('unauthenticated read rejected') do
    begin
      anon_reader.verify_digest(digest_for('doc1')); false
    rescue RP::Unauthenticated
      true
    end
  end

  recs = reader.verify_digest(digest_for('doc1'))
  assert('verify_digest finds the recorded digest') { recs.size == 1 }
  rec = recs.first
  assert('read shows chain position') { rec[:position] == 0 }
  assert('read shows depositor') { rec[:depositor] == 'peerA' }
  assert('read shows moment') { !rec[:moment].nil? }
  assert('read shows algorithm + canonicalization') do
    rec[:digest_algorithm] == 'sha256' && rec[:canonicalization].include?('raw-bytes')
  end
  assert('read exposes retrieval pointer to follow') { rec[:retrieval_pointer] == 'https://doi.org/10.5281/zenodo.200' }
  assert('read includes attestations (board wired)') { rec[:attestations].size == 1 }

  # honest proof-scope statement (ANC-7)
  assert('read states honest proof scope') { rec[:proof_scope].include?('does NOT prove') }

  # ANC-9: per-read record does NOT carry a full-chain verify result
  assert('read record is chain-length-independent (no chain_valid field)') { !rec.key?(:chain_valid) }
  assert('verify_chain is a separate explicit call') { reader.verify_chain[:valid] == true }

  # unknown digest -> empty; follow_pointer convenience
  assert('verify_digest of unknown returns empty') { reader.verify_digest(digest_for('nope')).empty? }
  assert('follow_pointer returns the DOI') { reader.follow_pointer(d1.deposit_id) == 'https://doi.org/10.5281/zenodo.200' }

  # withdrawn entry: digest still verifiable, pointer suppressed
  rlog.append_withdrawal(target: d1.deposit_id, withdrawer: 'operator')
  wrec = reader.get(d1.deposit_id)
  assert('withdrawn entry still readable (digest)') { wrec[:digest] == digest_for('doc1') }
  assert('withdrawn entry marked withdrawn') { wrec[:withdrawn] == true }
  assert('withdrawn entry pointer suppressed') { wrec[:retrieval_pointer].nil? }
  assert('follow_pointer nil after withdrawal') { reader.follow_pointer(d1.deposit_id).nil? }

  # --------------------------------------------------------------------------
  puts "\n[17] Implementation-review fixes (persona team REVISE items)"

  # (fix 2) durable-write rollback: a save failure must not leave the entry in memory
  fpath = File.join(dir, 'rollback_log.json')
  FileUtils.rm_f(fpath)
  flog = Synoptis::Anchoring::Log.new(storage_path: fpath, operator_id: 'operator')
  flog.append_anchor(digest: digest_for('r0'), anchor_type: 'generic', source_id: 's0', depositor: 'op')
  head_before = flog.head
  len_before = flog.length
  # force the next durable write to fail
  def flog.save_storage; raise IOError, 'simulated disk failure'; end
  raised = false
  begin
    flog.append_anchor(digest: digest_for('r1'), anchor_type: 'generic', source_id: 's1', depositor: 'op')
  rescue IOError
    raised = true
  end
  assert('save failure propagates') { raised }
  assert('failed write rolled back: length unchanged') { flog.length == len_before }
  assert('failed write rolled back: head unchanged') { flog.head == head_before }
  assert('failed write rolled back: not in digest index') { flog.find_by_digest(digest_for('r1')).empty? }
  assert('chain still valid after rolled-back write') { flog.verify[:valid] == true }

  # (fix 3) non-finite float metadata -> structured ContainmentError, not a raw JSON error
  glog = Synoptis::Anchoring::Log.new(storage_path: File.join(dir, 'nf.json'))
  assert('Infinity metadata rejected as ContainmentError') do
    begin
      glog.append_anchor(digest: digest_for('nf'), anchor_type: 'generic', source_id: 'x',
                         depositor: 'op', metadata: { 'n' => Float::INFINITY })
      false
    rescue Synoptis::Anchoring::Containment::ContainmentError => e
      e.code == :metadata_value_nonfinite
    end
  end

  # (fix 5) blank operator_id treated as "no operator"
  nolog = Synoptis::Anchoring::Log.new(storage_path: File.join(dir, 'noop.json'), operator_id: '  ')
  assert('blank operator_id normalized to nil') { nolog.operator_id.nil? }
  na = nolog.append_anchor(digest: digest_for('na'), anchor_type: 'generic', source_id: 'x', depositor: 'peerA')
  assert('with no operator, third party still cannot withdraw') do
    begin
      nolog.append_withdrawal(target: na.entry_hash, withdrawer: 'peerB'); false
    rescue Synoptis::Anchoring::UnauthorizedWithdrawal
      true
    end
  end

  # (fix 6) corrupt store degrades to empty rather than crashing on load
  cpath = File.join(dir, 'corrupt.json')
  File.write(cpath, JSON.pretty_generate({ 'entries' => [{ 'position' => 0, 'prev' => nil,
                                                            'kind' => 'not_a_kind', 'body' => {},
                                                            'entry_hash' => 'x' }] }))
  clog2 = nil
  assert('load of structurally-valid-but-invalid store does not crash') do
    clog2 = Synoptis::Anchoring::Log.new(storage_path: cpath); true
  end
  assert('corrupt store degraded to empty') { clog2.length == 0 }

  # (fix 4) attestation bound_digest must equal the deposit digest
  bpath = File.join(dir, 'bound_log.json')
  bapath = File.join(dir, 'bound_att.json')
  blog2 = Synoptis::Anchoring::Log.new(storage_path: bpath, operator_id: 'operator')
  bboard = Synoptis::Anchoring::DepositBoard.new(log: blog2, attestation_store_path: bapath)
  bpr = Synoptis::Anchoring::WritePath::Principal.new(peer_id: 'op', verified: true)
  bd = bboard.deposit_by_reference(principal: bpr, digest: digest_for('bd'), source_id: 'sbd')
  assert('mismatched bound_digest rejected') do
    begin
      bboard.attest(deposit_id: bd.deposit_id, principal: bpr, claim_type: 'correspondence',
                    bound_digest: digest_for('OTHER')); false
    rescue Synoptis::Anchoring::Containment::ContainmentError => e
      e.code == :attestation_digest_mismatch
    end
  end
  assert('matching bound_digest accepted') do
    bboard.attest(deposit_id: bd.deposit_id, principal: bpr, claim_type: 'correspondence',
                  bound_digest: digest_for('bd'))
    bboard.attestations_for(bd.deposit_id).size == 1
  end

  # (fix 1) DepositBoard attestation withdrawal rollback on durable-write failure
  aid = bboard.attestations_for(bd.deposit_id).first['attestation_id']
  att_count_before = bboard.attestations_for(bd.deposit_id).size
  def bboard.save_store; raise IOError, 'simulated disk failure'; end
  raised2 = false
  begin
    bboard.withdraw_attestation(attestation_id: aid, principal: bpr)
  rescue IOError
    raised2 = true
  end
  assert('board save failure propagates') { raised2 }
  assert('board rollback: attestation not marked withdrawn') do
    bboard.attestations_for(bd.deposit_id).none? { |a| a['withdrawn'] }
  end
  assert('board rollback: count unchanged') { bboard.attestations_for(bd.deposit_id).size == att_count_before }

  # --------------------------------------------------------------------------
  puts "\n[18] ANC-9 write budget: per-identity + aggregate bounds, operator exempt, disclosed"
  WB = Synoptis::Anchoring::WriteBudget
  # controllable clock for window rollover
  clock_now = [Time.now]
  budget = WB.new(per_identity: 2, aggregate: 3, window_seconds: 100,
                  operator_id: 'operator', clock: -> { clock_now[0] })
  blog3 = Synoptis::Anchoring::Log.new(storage_path: File.join(dir, 'budget_log.json'), operator_id: 'operator')
  bboard3 = Synoptis::Anchoring::DepositBoard.new(log: blog3,
                                                attestation_store_path: File.join(dir, 'budget_att.json'),
                                                budget: budget)
  pA = Synoptis::Anchoring::WritePath::Principal.new(peer_id: 'peerA', verified: true)
  pB = Synoptis::Anchoring::WritePath::Principal.new(peer_id: 'peerB', verified: true)
  pC = Synoptis::Anchoring::WritePath::Principal.new(peer_id: 'peerC', verified: true)
  pOp = Synoptis::Anchoring::WritePath::Principal.new(peer_id: 'operator', verified: true)

  dep_n = 0
  mk = lambda do |pr|
    dep_n += 1
    bboard3.deposit_by_reference(principal: pr, digest: digest_for("bud#{dep_n}"),
                                 source_id: "s#{dep_n}")
  end

  assert('peerA deposit 1 ok') { mk.call(pA); true }
  assert('peerA deposit 2 ok') { mk.call(pA); true }
  assert('peerA deposit 3 -> per_identity exceeded') do
    begin
      mk.call(pA); false
    rescue WB::BudgetExceeded => e
      e.scope == :per_identity
    end
  end
  assert('peerB deposit 1 ok (aggregate now 3)') { mk.call(pB); true }
  assert('peerC deposit -> aggregate exceeded') do
    begin
      mk.call(pC); false
    rescue WB::BudgetExceeded => e
      e.scope == :aggregate
    end
  end
  assert('BudgetExceeded carries the Sybil disclosure') do
    begin
      mk.call(pC); false
    rescue WB::BudgetExceeded => e
      e.disclosure.include?('Sybil')
    end
  end

  # operator is exempt even though aggregate is full
  assert('operator exempt from budget') do
    5.times { mk.call(pOp) }
    true
  end

  # window rollover refills the budget
  assert('window rollover refills budget') do
    clock_now[0] = clock_now[0] + 200 # past the 100s window
    mk.call(pA) # peerA was at limit; after roll should succeed
    true
  end

  # a rejected write (containment failure) does not consume budget (refund)
  clock_now[0] = clock_now[0] + 200 # fresh window
  budget2 = WB.new(per_identity: 1, aggregate: 10, window_seconds: 100,
                   operator_id: 'operator', clock: -> { clock_now[0] })
  rlog = Synoptis::Anchoring::Log.new(storage_path: File.join(dir, 'refund_log.json'), operator_id: 'operator')
  rboard = Synoptis::Anchoring::DepositBoard.new(log: rlog,
                                               attestation_store_path: File.join(dir, 'refund_att.json'),
                                               budget: budget2)
  # a containment-rejected deposit (bad digest) by peerA
  begin
    rboard.deposit_by_reference(principal: pA, digest: 'nothex', source_id: 'x')
  rescue Synoptis::Anchoring::Containment::ContainmentError
    # expected
  end
  assert('rejected write refunded: peerA still has budget') do
    rboard.deposit_by_reference(principal: pA, digest: digest_for('refund_ok'), source_id: 'y')
    true
  end

  # attestation writes also draw on the budget (BRD-3 extends ANC-9)
  clock_now[0] = clock_now[0] + 200
  budget3 = WB.new(per_identity: 1, aggregate: 10, window_seconds: 100, clock: -> { clock_now[0] })
  alog2 = Synoptis::Anchoring::Log.new(storage_path: File.join(dir, 'attbud_log.json'), operator_id: 'operator')
  aboard2 = Synoptis::Anchoring::DepositBoard.new(log: alog2,
                                                attestation_store_path: File.join(dir, 'attbud_att.json'),
                                                budget: budget3)
  ad = aboard2.deposit_by_reference(principal: pOp, digest: digest_for('adep'), source_id: 'ad')
  aboard2.attest(deposit_id: ad.deposit_id, principal: pB, claim_type: 'vouch') # peerB uses its 1 write
  assert('attestation beyond per-identity budget rejected') do
    begin
      aboard2.attest(deposit_id: ad.deposit_id, principal: pB, claim_type: 'review'); false
    rescue WB::BudgetExceeded
      true
    end
  end

  assert('budget status discloses limits + Sybil residual') do
    s = budget.status
    s[:per_identity_limit] == 2 && s[:aggregate_limit] == 3 && s[:disclosure].include?('disclosed limit')
  end
end

puts "\n" + ('=' * 60)
puts "RESULT: #{$pass_count} passed, #{$fail_count} failed"
puts('=' * 60)
exit($fail_count.zero? ? 0 : 1)
