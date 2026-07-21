# frozen_string_literal: true

# Design-constraint tests for the auditability head-anchor slice
# (auditability_head_anchor_design_v0.3, FROZEN; invariants MPR-1..9).
# Each block below names the invariant whose implementable consequence it pins.

require 'tmpdir'
require 'json'
require 'digest'
require 'open3'

anchoring = File.expand_path('../lib/synoptis/anchoring', __dir__)
require File.join(anchoring, 'cumulative_commitment')
require File.join(anchoring, 'head_binding')
require File.join(anchoring, 'entry')
require File.join(anchoring, 'log')
require File.join(anchoring, 'public_verifier')

CC = Synoptis::Anchoring::CumulativeCommitment
HB = Synoptis::Anchoring::HeadBinding
Entry = Synoptis::Anchoring::Entry
Log = Synoptis::Anchoring::Log
Containment = Synoptis::Anchoring::Containment

$pass = 0
$fail = 0

def assert(condition, message)
  if condition
    $pass += 1
    puts "  PASS: #{message}"
  else
    $fail += 1
    puts "  FAIL: #{message}"
  end
end

def assert_raises(klass, message)
  yield
  assert(false, "#{message} (no exception raised)")
rescue klass
  assert(true, message)
rescue StandardError => e
  assert(false, "#{message} (raised #{e.class}: #{e.message})")
end

# Deterministic fake internal-chain state in the persisted blocks shape.
def make_blocks(n_blocks, records_per_block: 2, salt: 'r')
  (0...n_blocks).map do |i|
    data = i.zero? ? ['Genesis Block'] : (0...records_per_block).map { |j| "#{salt}-#{i}-#{j}" }
    { 'index' => i, 'data' => data,
      'hash' => Digest::SHA256.hexdigest("blockhash-#{salt}-#{i}"),
      'previous_hash' => i.zero? ? '0' * 64 : Digest::SHA256.hexdigest("blockhash-#{salt}-#{i - 1}"),
      'merkle_root' => '0' * 64, 'timestamp' => '2026-01-01T00:00:00.000000Z' }
  end
end

puts "\n== MPR-3: self-describing determinism =="
blocks = make_blocks(5)
b1 = HB.build(blocks)
b2 = HB.build(blocks)
assert(b1 == b2, 'same chain state yields the same binding (determinism)')
assert(b1['convention'] == 'khab-1', 'binding names its convention')
assert(b1['convention_sha256'] == Digest::SHA256.hexdigest(File.binread(HB::CONVENTION_PATH)),
       'committed convention digest matches the shipped resolvable definition')
assert(b1['tree_size'] == 1 + 4 * 2, 'tree_size counts every record incl. genesis')
coh = HB.coherence(b1, blocks)
assert(coh[:coherent] && coh[:informational_mismatches].empty?, 'coherence check re-derives every component')

puts "\n== MPR-3: role-ambiguity exclusion (domain separation) =="
two = [Digest::SHA256.hexdigest('a'), Digest::SHA256.hexdigest('b')]
interior = CC.root(two)
assert(!CC.verify_inclusion(record_commitment: interior, index: 0, tree_size: 1, path: [], root: interior),
       'an interior-node value cannot verify as a record commitment')
single_root = CC.root([two.first])
assert(single_root != two.first, 'a leaf hash is domain-separated from its input digest')

puts "\n== MPR-1: binding is committed content =="
entry = Entry.anchor(position: 0, prev: nil, digest: b1['cumulative_root'], anchor_type: 'chain_head',
                     source_id: 'https://example.org/anchor/head', depositor: 'op',
                     moment: '2026-07-21T00:00:00Z', head_binding: b1)
assert(entry.canonical_content['body']['head_binding'] == b1, 'head binding lives inside the committed body')
tampered = entry.to_h
tampered['body'] = tampered['body'].merge('head_binding' => b1.merge('tree_size' => 999))
assert(Entry.compute_hash(Entry.from_h(tampered).canonical_content) != entry.entry_hash,
       'substituting the bound state breaks the entry hash')

plain = Entry.anchor(position: 0, prev: nil, digest: 'ab' * 32, anchor_type: 'document',
                     source_id: 'https://example.org/a', depositor: 'op', moment: '2026-07-21T00:00:00Z')
assert(!plain.body.key?('head_binding'), 'binding-less entries carry no key at all (hash-identical to old format)')

puts "\n== MPR-1/ANC-2: containment of the binding field =="
assert_raises(Containment::ContainmentError, 'extra field in binding rejected (no content channel)') do
  Containment.validate_head_binding!(b1.merge('note' => 'smuggled'))
end
assert_raises(Containment::ContainmentError, 'missing field rejected') do
  Containment.validate_head_binding!(b1.reject { |k, _| k == 'tree_size' })
end
assert_raises(Containment::ContainmentError, 'non-hex root rejected') do
  Containment.validate_head_binding!(b1.merge('cumulative_root' => 'zz' * 32))
end
assert_raises(Containment::ContainmentError, 'unknown convention rejected') do
  Containment.validate_head_binding!(b1.merge('convention' => 'khab-9'))
end
assert(Containment.validate_head_binding!(b1), 'well-formed binding accepted')

puts "\n== MPR-7: membership for pre-first-anchor records =="
genesis_commitment = Digest::SHA256.hexdigest('Genesis Block')
proof0 = HB.inclusion_proof_artifact(blocks, 0, b1)
assert(proof0['record_commitment'] == genesis_commitment,
       'record #0 (committed long before any anchor) is the genesis record')
assert(CC.verify_inclusion(record_commitment: proof0['record_commitment'], index: 0,
                           tree_size: b1['tree_size'], path: proof0['path'], root: b1['cumulative_root']),
       'a record older than the first anchor is provable as a member (limit is temporal, not membership)')

puts "\n== MPR-8: committed position and order arithmetic =="
pa = HB.inclusion_proof_artifact(blocks, 2, b1)
pb = HB.inclusion_proof_artifact(blocks, 7, b1)
ok_a = CC.verify_inclusion(record_commitment: pa['record_commitment'], index: 2,
                           tree_size: b1['tree_size'], path: pa['path'], root: b1['cumulative_root'])
ok_b = CC.verify_inclusion(record_commitment: pb['record_commitment'], index: 7,
                           tree_size: b1['tree_size'], path: pb['path'], root: b1['cumulative_root'])
assert(ok_a && ok_b && pa['index'] < pb['index'],
       'order between two proven records is arithmetic on committed positions')
assert(!CC.verify_inclusion(record_commitment: pa['record_commitment'], index: 3,
                            tree_size: b1['tree_size'], path: pa['path'], root: b1['cumulative_root']),
       'a proof does not verify at a position other than its committed one')

puts "\n== MPR-9: inter-anchor consistency =="
grown = blocks + (5...8).map do |i|
  { 'index' => i, 'data' => ["r-#{i}-0", "r-#{i}-1"],
    'hash' => Digest::SHA256.hexdigest("blockhash-r-#{i}"), 'previous_hash' => '0' * 64,
    'merkle_root' => '0' * 64, 'timestamp' => '2026-01-02T00:00:00.000000Z' }
end
b_later = HB.build(grown)
assert(b_later['chain_identity'] == b1['chain_identity'], 'growing the chain preserves committed identity')
cons = HB.consistency_proof_artifact(grown, b1, b_later)
assert(CC.verify_consistency(first_root: b1['cumulative_root'], first_size: b1['tree_size'],
                             second_root: b_later['cumulative_root'], second_size: b_later['tree_size'],
                             path: cons['path']),
       'later anchored state verifiably extends the earlier one')

rewritten = grown.map { |b| b.dup }
rewritten[2] = rewritten[2].merge('data' => ['REWRITTEN', 'r-2-1'])
b_evil = HB.build(rewritten)
evil_cons = HB.consistency_proof_artifact(rewritten, b1, b_evil) rescue nil
verified_evil = evil_cons && CC.verify_consistency(
  first_root: b1['cumulative_root'], first_size: b1['tree_size'],
  second_root: b_evil['cumulative_root'], second_size: b_evil['tree_size'], path: evil_cons['path']
)
assert(!verified_evil, 'a rewritten history cannot produce a verifying consistency proof against the old binding')

other_chain = make_blocks(5, salt: 'x')
b_other = HB.build(other_chain)
assert(b_other['chain_identity'] != b1['chain_identity'], 'a different chain commits a different identity')
assert_raises(HB::BindingError, 'consistency generation refuses to relate different committed identities (MPR-9)') do
  HB.consistency_proof_artifact(other_chain, b1, b_other)
end

puts "\n== MPR-1/AHM-4 + log integration =="
Dir.mktmpdir do |dir|
  store = File.join(dir, 'anchor_log.jsonl')
  log = Log.new(storage_path: store, operator_id: 'op')
  first = log.append_anchor(digest: 'ab' * 32, anchor_type: 'document',
                            source_id: 'https://example.org/a', depositor: 'op')
  pre_hash = first.entry_hash
  head_entry = log.append_anchor(digest: b1['cumulative_root'], anchor_type: 'chain_head',
                                 source_id: 'https://example.org/anchor/head', depositor: 'op',
                                 head_binding: b1)
  assert(log.entries.first.entry_hash == pre_hash,
         'appending a binding-carrying entry leaves published entries untouched (AHM-4)')
  assert(log.verify[:valid], 'anchor log hash chain verifies with a head-binding entry')

  reloaded = Log.new(storage_path: store, operator_id: 'op')
  got = reloaded.get(head_entry.entry_hash)
  assert(got.head_binding == b1 && got.entry_hash == head_entry.entry_hash,
         'binding survives persistence round-trip with identical entry hash')
  assert(reloaded.verify[:valid], 'reloaded log verifies from genesis')

  pv = Synoptis::Anchoring::PublicVerifier.new(log: reloaded)
  rec = pv.get(head_entry.entry_hash)
  assert(rec[:head_binding] == b1, 'public verification record surfaces the committed binding')
  rec_plain = pv.get(pre_hash)
  assert(rec_plain[:head_binding].nil?, 'ordinary entries surface no binding (absence = provenance)')

  assert_raises(Synoptis::Anchoring::Containment::ContainmentError, 'log intake rejects malformed binding') do
    log.append_anchor(digest: 'cd' * 32, anchor_type: 'chain_head',
                      source_id: 'https://example.org/anchor/head', depositor: 'op',
                      head_binding: { 'convention' => 'khab-1' })
  end
end

puts "\n== MPR-4: offline verifier (disclosed trust base only) =="
Dir.mktmpdir do |dir|
  verifier = File.expand_path('../bin/khab_verify.rb', __dir__)
  proof_p = File.join(dir, 'proof.json')
  bind_p = File.join(dir, 'binding.json')
  File.write(proof_p, JSON.generate(pa))
  File.write(bind_p, JSON.generate('head_binding' => b1))

  out, status = Open3.capture2e('ruby', verifier, 'inclusion', proof_p, bind_p)
  assert(status.exitstatus.zero? && out.include?('VERIFIED'),
         'offline verifier verifies inclusion from proof+binding+convention alone')

  bad = pa.merge('record_commitment' => Digest::SHA256.hexdigest('forged'))
  File.write(proof_p, JSON.generate(bad))
  _, status = Open3.capture2e('ruby', verifier, 'inclusion', proof_p, bind_p)
  assert(status.exitstatus == 1, 'offline verifier rejects a forged record commitment')

  File.write(proof_p, JSON.generate(pa))
  File.write(bind_p, JSON.generate('head_binding' => b1.merge('convention_sha256' => 'ef' * 32)))
  out, status = Open3.capture2e('ruby', verifier, 'inclusion', proof_p, bind_p)
  assert(status.exitstatus == 1 && out.include?('unresolvable'),
         'a binding naming an unresolvable convention definition is refused (MPR-3)')

  cons_p = File.join(dir, 'cons.json')
  e_p = File.join(dir, 'earlier.json')
  l_p = File.join(dir, 'later.json')
  File.write(cons_p, JSON.generate(cons))
  File.write(e_p, JSON.generate(b1))
  File.write(l_p, JSON.generate(b_later))
  out, status = Open3.capture2e('ruby', verifier, 'consistency', cons_p, e_p, l_p)
  assert(status.exitstatus.zero? && out.include?('VERIFIED'), 'offline verifier verifies consistency')

  File.write(l_p, JSON.generate(b_evil))
  bad_cons = cons.merge('second_root' => b_evil['cumulative_root'], 'second_size' => b_evil['tree_size'])
  File.write(cons_p, JSON.generate(bad_cons))
  out, status = Open3.capture2e('ruby', verifier, 'consistency', cons_p, e_p, l_p)
  assert(status.exitstatus == 1 && out.include?('UNESTABLISHED'),
         'failed consistency reports UNESTABLISHED, not forgery (MPR-9 non-production posture)')

  File.write(l_p, JSON.generate(b_other))
  cross = cons.merge('second_root' => b_other['cumulative_root'], 'second_size' => b_other['tree_size'],
                     'chain_identity' => b_other['chain_identity'])
  File.write(cons_p, JSON.generate(cross))
  out, status = Open3.capture2e('ruby', verifier, 'consistency', cons_p, e_p, l_p)
  assert(status.exitstatus == 1 && out.include?('identity change'),
         'identity change terminates the extension claim (MPR-9)')
end

puts "\n== MPR-2: proofs carry only hashes and structural data =="
leak = [pa, pb, cons].any? do |artifact|
  JSON.generate(artifact).include?('r-1-0') || JSON.generate(artifact).include?('Genesis Block')
end
assert(!leak, 'no record content crosses the anchor boundary inside any proof artifact')
structural_keys = pa.keys - %w[format chain_identity record_commitment index tree_size path cumulative_root]
assert(structural_keys.empty?, 'inclusion artifact carries exactly the khab-1 §3 fields')

puts "\n== R1 additions: tree edge cases (odd sizes, large tree, RFC branches) =="
[1, 3, 5, 308].each do |n|
  leaves = (0...n).map { |i| Digest::SHA256.hexdigest("edge-#{i}") }
  r = CC.root(leaves)
  bad = (0...n).reject do |i|
    CC.verify_inclusion(record_commitment: leaves[i], index: i, tree_size: n,
                        path: CC.inclusion_proof(leaves, i), root: r)
  end
  assert(bad.empty?, "every index verifies in a tree of #{n} leaves")
end

leaves13 = (0...13).map { |i| Digest::SHA256.hexdigest("c-#{i}") }
r8 = CC.root(leaves13[0...8])
r13 = CC.root(leaves13)
assert(CC.verify_consistency(first_root: r8, first_size: 8, second_root: r13, second_size: 13,
                             path: CC.consistency_proof(leaves13, 8)),
       'power-of-two first_size consistency verifies (prefix-omission branch)')
assert(CC.verify_consistency(first_root: r13, first_size: 13, second_root: r13, second_size: 13, path: []),
       'equal-size consistency: empty path + equal roots verifies')
assert(!CC.verify_consistency(first_root: r8, first_size: 13, second_root: r13, second_size: 13, path: []),
       'equal-size consistency with unequal roots fails')

puts "\n== R1 additions: binding intake hardening =="
assert_raises(HB::BindingError, 'validate! rejects uppercase cumulative_root (lowercase canonical)') do
  HB.validate!(b1.merge('cumulative_root' => b1['cumulative_root'].upcase))
end
assert_raises(HB::BindingError, 'validate! rejects a convention_sha256 that does not resolve to the shipped definition') do
  HB.validate!(b1.merge('convention_sha256' => 'ef' * 32))
end
assert_raises(HB::BindingError, 'validate! rejects tree_size beyond the JSON-safe bound') do
  HB.validate!(b1.merge('tree_size' => 2**53))
end
assert_raises(HB::BindingError, 'non-string record refused, never coerced (khab-1 §1)') do
  HB.record_commitments([{ 'index' => 0, 'data' => [42], 'hash' => 'aa' * 32 }])
end
assert_raises(HB::BindingError, 'block without data array refused') do
  HB.record_commitments([{ 'index' => 0, 'hash' => 'aa' * 32 }])
end
assert(HB.field({ 'index' => 0 }, 'index') == 0, 'field returns a falsy-adjacent 0 from the string key')
assert_raises(HB::BindingError, 'artifact generation validates the target binding first') do
  HB.inclusion_proof_artifact(blocks, 0, b1.merge('convention_sha256' => 'ef' * 32))
end
assert_raises(HB::BindingError, 'consistency generation refuses earlier tree_size > later') do
  HB.consistency_proof_artifact(blocks, b1.merge('tree_size' => b1['tree_size'] + 1), b1)
end

unicode_blocks = [
  { 'index' => 0, 'data' => ['Genesis Block'], 'hash' => Digest::SHA256.hexdigest('u0') },
  { 'index' => 1, 'data' => ['日本語レコード', ''], 'hash' => Digest::SHA256.hexdigest('u1') }
]
ub = HB.build(unicode_blocks)
up = HB.inclusion_proof_artifact(unicode_blocks, 1, ub)
assert(CC.verify_inclusion(record_commitment: up['record_commitment'], index: 1,
                           tree_size: ub['tree_size'], path: up['path'], root: ub['cumulative_root']),
       'non-ASCII and empty-string records commit and verify deterministically')

puts "\n== R2 additions: build self-consistency and state-match guards =="
assert_raises(HB::BindingError, 'build refuses a chain whose blocks all carry empty data arrays') do
  HB.build([{ 'index' => 0, 'data' => [], 'hash' => 'aa' * 32 }, { 'index' => 1, 'data' => [], 'hash' => 'bb' * 32 }])
end
assert_raises(HB::BindingError, 'non-Hash block element raises a structured error') do
  HB.record_commitments(['not a block'])
end
assert(HB.validate!(HB.build(blocks)), 'build output always passes its own validator')

same_size_other = blocks.map { |b| b.dup }
same_size_other[3] = same_size_other[3].merge('data' => ['swapped-a', 'swapped-b'])
b_same_size = HB.build(same_size_other)
assert(b_same_size['tree_size'] == b1['tree_size'] && b_same_size['cumulative_root'] != b1['cumulative_root'],
       'fixture: equal extent, divergent content')
assert_raises(HB::BindingError, 'inclusion artifact refuses a binding whose root does not derive from this state') do
  HB.inclusion_proof_artifact(same_size_other, 0, b1)
end
assert_raises(HB::BindingError, 'consistency artifact refuses an earlier binding that is not a prefix of this history') do
  HB.consistency_proof_artifact(grown, b_same_size, b_later)
end

l5 = (0...13).map { |i| Digest::SHA256.hexdigest("o-#{i}") }
assert(CC.verify_consistency(first_root: CC.root(l5[0...5]), first_size: 5, second_root: CC.root(l5),
                             second_size: 13, path: CC.consistency_proof(l5, 5)),
       'odd first_size consistency verifies (5 -> 13)')

Dir.mktmpdir do |dir|
  verifier = File.expand_path('../bin/khab_verify.rb', __dir__)
  e_p = File.join(dir, 'e.json')
  l_p = File.join(dir, 'l.json')
  c_p = File.join(dir, 'c.json')
  File.write(e_p, JSON.generate(b1))
  File.write(l_p, JSON.generate(b_same_size))
  File.write(c_p, JSON.generate('format' => 'khab-1/consistency', 'chain_identity' => b1['chain_identity'],
                                'first_root' => b1['cumulative_root'], 'first_size' => b1['tree_size'],
                                'second_root' => b_same_size['cumulative_root'],
                                'second_size' => b_same_size['tree_size'], 'path' => []))
  out, st = Open3.capture2e('ruby', verifier, 'consistency', c_p, e_p, l_p)
  assert(st.exitstatus == 1 && out.include?('DIVERGENCE'),
         'equal extent + different roots reported as a positive divergence witness, not mere UNESTABLISHED')
end

puts "\n== R3 additions: divergence-witness reachability and self-consistency completions =="
assert_raises(HB::BindingError, 'chain_identity refuses a malformed block-1 hash (build self-consistency)') do
  HB.build([{ 'index' => 0, 'data' => ['g'], 'hash' => 'aa' * 32 },
            { 'index' => 1, 'data' => ['r'], 'hash' => 'not-hex' }])
end
assert_raises(HB::BindingError, 'build refuses a string-typed head index (strict, matching chain_identity)') do
  HB.build([{ 'index' => 0, 'data' => ['g'], 'hash' => 'aa' * 32 },
            { 'index' => '1', 'data' => ['r'], 'hash' => 'bb' * 32 }])
end
empty_coh = HB.coherence(b1, [{ 'index' => 0, 'data' => [], 'hash' => 'aa' * 32 }])
assert(empty_coh[:coherent] == false && empty_coh[:mismatches].first.start_with?('build_failed'),
       'coherence reports build failure as incoherent instead of raising (diagnostic contract)')

Dir.mktmpdir do |dir|
  verifier = File.expand_path('../bin/khab_verify.rb', __dir__)
  e_p = File.join(dir, 'e.json')
  l_p = File.join(dir, 'l.json')
  c_p = File.join(dir, 'c.json')
  File.write(c_p, JSON.generate('format' => 'khab-1/consistency', 'chain_identity' => b1['chain_identity'],
                                'first_root' => b1['cumulative_root'], 'first_size' => b1['tree_size'],
                                'second_root' => b1['cumulative_root'], 'second_size' => b1['tree_size'],
                                'path' => []))
  # Same state, one file uppercased: unresolvable input, NEVER a divergence witness.
  File.write(e_p, JSON.generate(b1))
  File.write(l_p, JSON.generate(b1.merge('cumulative_root' => b1['cumulative_root'].upcase)))
  out, st = Open3.capture2e('ruby', verifier, 'consistency', c_p, e_p, l_p)
  assert(st.exitstatus == 2 && !out.include?('DIVERGENCE'),
         'non-canonical root is exit-2 unresolvable, not a fabricated divergence witness')
  # Missing cumulative_root entirely: also unresolvable, not divergence.
  File.write(l_p, JSON.generate(b1.reject { |k, _| k == 'cumulative_root' }))
  out, st = Open3.capture2e('ruby', verifier, 'consistency', c_p, e_p, l_p)
  assert(st.exitstatus == 2 && !out.include?('DIVERGENCE'),
         'missing root is exit-2 unresolvable, not a fabricated divergence witness')
  # Control: genuinely divergent well-formed bindings still yield DIVERGENCE.
  swapped = blocks.map { |b| b.dup }
  swapped[2] = swapped[2].merge('data' => ['x-a', 'x-b'])
  File.write(l_p, JSON.generate(HB.build(swapped)))
  out, st = Open3.capture2e('ruby', verifier, 'consistency', c_p, e_p, l_p)
  assert(st.exitstatus == 1 && out.include?('DIVERGENCE'),
         'well-formed equal-extent different-root bindings still yield the positive witness')
end

puts "\n== R4 additions: gate symmetry with khab-1 canonical forms =="
assert_raises(HB::BindingError, 'build refuses a head index beyond the JSON-safe bound (validate! closure complete)') do
  HB.build([{ 'index' => 0, 'data' => ['g'], 'hash' => 'aa' * 32 },
            { 'index' => 1, 'data' => ['r'], 'hash' => 'bb' * 32 },
            { 'index' => 2**53 + 7, 'data' => ['s'], 'hash' => 'cc' * 32 }])
end
assert_raises(HB::BindingError, 'build refuses head index exactly at the exclusive bound (2**53)') do
  HB.build([{ 'index' => 0, 'data' => ['g'], 'hash' => 'aa' * 32 },
            { 'index' => 1, 'data' => ['r'], 'hash' => 'bb' * 32 },
            { 'index' => 2**53, 'data' => ['s'], 'hash' => 'cc' * 32 }])
end
boundary_ok = HB.build([{ 'index' => 0, 'data' => ['g'], 'hash' => 'aa' * 32 },
                        { 'index' => 1, 'data' => ['r'], 'hash' => 'bb' * 32 },
                        { 'index' => 2**53 - 1, 'data' => ['s'], 'hash' => 'cc' * 32 }])
assert(HB.validate!(boundary_ok) && boundary_ok['chain_head_index'] == 2**53 - 1,
       'head index 2**53 - 1 (largest JSON-safe) accepted and validates')
assert(HB.validate!(b1.merge('tree_size' => b1['tree_size'])), 'tree_size boundary semantics unchanged for valid bindings')
Dir.mktmpdir do |dir|
  verifier = File.expand_path('../bin/khab_verify.rb', __dir__)
  e_p = File.join(dir, 'e.json')
  l_p = File.join(dir, 'l.json')
  c_p = File.join(dir, 'c.json')
  garbage = b1.merge('chain_identity' => 'zzz-garbage')
  File.write(e_p, JSON.generate(garbage))
  File.write(l_p, JSON.generate(garbage.merge('cumulative_root' => 'dd' * 32)))
  File.write(c_p, JSON.generate('format' => 'khab-1/consistency', 'chain_identity' => 'zzz-garbage',
                                'first_root' => b1['cumulative_root'], 'first_size' => b1['tree_size'],
                                'second_root' => 'dd' * 32, 'second_size' => b1['tree_size'], 'path' => []))
  out, st = Open3.capture2e('ruby', verifier, 'consistency', c_p, e_p, l_p)
  assert(st.exitstatus == 2 && !out.include?('DIVERGENCE'),
         'non-canonical chain_identity is exit-2 unresolvable, never a divergence witness')
end

puts "\n== R1 additions: verifier exit-code contract =="
verifier_bin = File.expand_path('../bin/khab_verify.rb', __dir__)
_, st = Open3.capture2e('ruby', verifier_bin)
assert(st.exitstatus == 2, 'no-args usage exits 2')
_, st = Open3.capture2e('ruby', verifier_bin, 'inclusion', '/nonexistent.json', '/nonexistent.json')
assert(st.exitstatus == 2, 'unreadable input exits 2 (unresolvable, not rejected)')

puts "\n== Result =="
puts "PASS: #{$pass}, FAIL: #{$fail}"
exit($fail.zero? ? 0 : 1)
