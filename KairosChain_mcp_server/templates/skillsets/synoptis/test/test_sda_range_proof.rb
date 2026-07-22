# frozen_string_literal: true

# Design-constraint tests for the AUD-L4 ZK range proof, Phase 2
# (aud_l4_zk_range_proof_design v0.3, converged R2 5/6). Each block names the
# spec section whose implementable consequence it pins. This suite carries the
# spike's "first genuine zero-knowledge proof" guarantee: the mandatory §6
# negative tests demonstrate the forgery the whole construction exists to stop.

require 'json'
require 'digest'

anchoring = File.expand_path('../lib/synoptis/anchoring', __dir__)
require File.join(anchoring, 'entry')
require File.join(anchoring, 'ec_group')
require File.join(anchoring, 'pedersen')
require File.join(anchoring, 'aggregate_disclosure')
require File.join(anchoring, 'range_proof')

Entry = Synoptis::Anchoring::Entry
EC = Synoptis::Anchoring::EcGroup
Ped = Synoptis::Anchoring::Pedersen
Agg = Synoptis::Anchoring::AggregateDisclosure
RP = Synoptis::Anchoring::RangeProof

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
  $fail += 1
  puts "  FAIL: #{message} (no error raised)"
rescue klass
  $pass += 1
  puts "  PASS: #{message}"
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{message} (raised #{e.class}: #{e.message})"
end

# Re-canonicalize a mutated proof object so it stays well-formed (admission
# passes) and the ALGEBRAIC checks are what fails (§5 raise-vs-return contract).
def reserialize(obj)
  Entry.canonical_json(obj)
end

puts '== §6 positive: every in-band score proves and verifies (commit_score path) =='

END_SHA = Digest::SHA256.hexdigest('rpr-1-endorsement-for-range-test')
TGT_SHA = Digest::SHA256.hexdigest('rpr-1-target-for-range-test')

(0..7).each do |s|
  r = 10_000 + s
  rec = Agg.score_record(endorsement_sha256: END_SHA, target_sha256: TGT_SHA, score: s)
  c_enc = Agg.commit_score(rec, score: s, blinding: r)['commitment']
  proof = RP.prove_range(s, r)
  assert(RP.verify_range(c_enc, proof), "score #{s} proves in [0,7] and verifies (same blinding both sides)")
end

puts '== §6 negative (mandatory), path (i): the 32000 forgery fails reconstruction =='

r32 = 424_242
c32 = EC.encode(Ped.commit(32_000, r32))
# The forger's best 3-bit attempt: 32000 mod 8 = 0, same blinding r. The proof
# itself is internally valid (commits 0), but against C(32000) reconstruction
# yields commit(0, r) != C — RETURNS false, never raises (well-formed proof).
forged = RP.prove_range(32_000 % 8, r32)
assert(RP.verify_range(c32, forged) == false,
       'a well-formed low-3-bits proof against commit(32000) RETURNS false (reconstruction mismatch, spec §6 path i)')

puts '== §6 negative (mandatory), path (ii): an over-width object is inadmissible =='

valid = JSON.parse(RP.prove_range(5, 555))
overwidth = valid.dup
overwidth['bit_commitments'] = valid['bit_commitments'] + [valid['bit_commitments'][0]]
overwidth['or_proofs'] = valid['or_proofs'] + [valid['or_proofs'][0]]
assert_raises(RP::RangeError, 'a 4-bit (over-width) object RAISES RangeError at step 0 (spec §6 path ii — range escape closed)') do
  RP.verify_range(c32, reserialize(overwidth))
end
widened = valid.dup
widened['bits'] = 4
assert_raises(RP::RangeError, 'bits=4 metadata is rejected at step 0 (policy pinned to 3 bits)') do
  RP.verify_range(c32, reserialize(widened))
end

puts '== §6 tamper: any mutated element fails (well-formed => false; inadmissible => raise) =='

S_T = 5
R_T = 777_777
C_T = EC.encode(Ped.commit(S_T, R_T))
P_T = RP.prove_range(S_T, R_T)
assert(RP.verify_range(C_T, P_T), 'baseline: honest proof for s=5 verifies')

obj = JSON.parse(P_T)
t1 = JSON.parse(P_T)
e0 = Integer(t1['or_proofs'][0]['e0'], 16)
t1['or_proofs'][0]['e0'] = ((e0 + 1) % EC::N).to_s(16).rjust(64, '0')
assert(RP.verify_range(C_T, reserialize(t1)) == false, 'tampered e0 (+1 mod N, still canonical) => false')

t2 = JSON.parse(P_T)
z0 = Integer(t2['or_proofs'][1]['z0'], 16)
t2['or_proofs'][1]['z0'] = ((z0 + 1) % EC::N).to_s(16).rjust(64, '0')
assert(RP.verify_range(C_T, reserialize(t2)) == false, 'tampered z0 => false')

t3 = JSON.parse(P_T)
t3['or_proofs'][2]['a1'] = EC.encode(EC.g)
assert(RP.verify_range(C_T, reserialize(t3)) == false, 'replaced A_1 with a valid but wrong point => false')

t4 = JSON.parse(P_T)
t4['bit_commitments'][0], t4['bit_commitments'][1] = t4['bit_commitments'][1], t4['bit_commitments'][0]
assert(RP.verify_range(C_T, reserialize(t4)) == false, 'swapped B_0/B_1 => reconstruction false (position weights bind)')

other_c = EC.encode(Ped.commit(3, 999))
assert(RP.verify_range(other_c, P_T) == false, "a proof for s=5's commitment presented against another commitment => false")

puts '== §5 admission: non-canonical scalars and malformed points RAISE =='

n_hex = EC::N.to_s(16).rjust(64, '0')
t5 = JSON.parse(P_T)
t5['or_proofs'][0]['e0'] = n_hex
assert_raises(RP::RangeError, 'e0 == N (64-hex but >= N) raises — non-canonical scalar rejected (malleability guard)') do
  RP.verify_range(C_T, reserialize(t5))
end

t6 = JSON.parse(P_T)
t6['bit_commitments'][0] = '00'
assert_raises(RP::RangeError, 'identity point as a bit commitment raises (degenerate statement rejected)') do
  RP.verify_range(C_T, reserialize(t6))
end

off_x = (2..1000).find { |x| EC.sqrt_mod((x.pow(3, EC::P) + EC::B) % EC::P).nil? }
t7 = JSON.parse(P_T)
t7['or_proofs'][0]['a0'] = '02' + off_x.to_s(16).rjust(64, '0')
assert_raises(RP::RangeError, 'off-curve A_0 raises (proof points are validated, R1 fix)') do
  RP.verify_range(C_T, reserialize(t7))
end

assert_raises(RP::RangeError, 'identity commitment raises') { RP.verify_range('00', P_T) }
assert_raises(RP::RangeError, 'non-canonical proof serialization raises (one artifact, one digest)') do
  RP.verify_range(C_T, P_T + ' ')
end
t8 = JSON.parse(P_T)
t8.delete('vmax')
assert_raises(RP::RangeError, 'missing field raises (closed schema)') { RP.verify_range(C_T, reserialize(t8)) }

puts '== impl R1 pins: type-strict admission (executable-adversary findings) =='

# (a) fix pin: Float metadata is a DISTINCT byte-string that must never verify —
# Ruby 7.0 == 7 coerces, so admission is type-strict (one artifact, one digest).
t9 = JSON.parse(P_T)
t9['bits'] = 3.0
assert_raises(RP::RangeError, 'bits: 3.0 (Float) raises — encoding-malleability closed [impl R1 (a) fix]') do
  RP.verify_range(C_T, reserialize(t9))
end
t10 = JSON.parse(P_T)
t10['vmax'] = 7.0
assert_raises(RP::RangeError, 'vmax: 7.0 (Float) raises [impl R1 (a) fix]') do
  RP.verify_range(C_T, reserialize(t10))
end

# False-positive pins (impl R1 INFERRED findings, verified unfounded — pinned so
# they stay that way): non-string proof elements are rejected at step 1, and the
# proof argument must be the raw String.
t11 = JSON.parse(P_T)
t11['or_proofs'][0]['a0'] = 123
assert_raises(RP::RangeError, 'a numeric a0 raises (element types enforced at step 1)') do
  RP.verify_range(C_T, reserialize(t11))
end
t12 = JSON.parse(P_T)
t12['bit_commitments'][0] = nil
assert_raises(RP::RangeError, 'a null bit commitment raises') { RP.verify_range(C_T, reserialize(t12)) }
assert_raises(RP::RangeError, 'a nil proof argument raises a clear type error') { RP.verify_range(C_T, nil) }

# r_0, r_1 non-zero (spec §2): Pedersen.random_blinding loops until non-zero by
# construction — pin the guarantee the prover relies on.
assert((1..64).all? { Ped.random_blinding != 0 }, 'Pedersen.random_blinding never returns zero (r_0/r_1 non-zero guaranteed, spec §2)')

puts '== prover refusals (§5: prover refuses out-of-band; verifier never trusts it) =='

assert_raises(RP::RangeError, 'prove_range(8, r) refused (out of band)') { RP.prove_range(8, 123) }
assert_raises(RP::RangeError, 'prove_range(32000, r) refused at the prover') { RP.prove_range(32_000, 123) }
assert_raises(RP::RangeError, 'zero blinding refused (would collapse hiding)') { RP.prove_range(3, 0) }

puts '== §2 reconstruction invariant: bit blindings recombine to the commitment blinding =='

# Structural cross-check: for a proof of s, the reconstruction sum EQUALS the
# commitment — i.e. Sum 2^j B_j = C exactly, not merely same value.
(0..7).step(3) do |s|
  r = 31_337 + s
  c_pt = Ped.commit(s, r)
  pf = JSON.parse(RP.prove_range(s, r))
  sum = pf['bit_commitments'].each_with_index.reduce(EC::INFINITY) do |acc, (enc, j)|
    EC.add(acc, EC.scalar_mul(1 << j, EC.decode(enc)))
  end
  assert(sum == c_pt, "reconstruction Sum 2^j*B_j equals C exactly for s=#{s} (blinding split correct)")
end

puts '== §9 ZK smoke: proofs reveal nothing and are randomized =='

p1 = RP.prove_range(6, 2024)
p2 = RP.prove_range(6, 2024)
c6 = EC.encode(Ped.commit(6, 2024))
assert(p1 != p2, 'two proofs of the same (score, blinding) differ (fresh randomness)')
assert(RP.verify_range(c6, p1) && RP.verify_range(c6, p2), 'both randomized proofs verify')
parsed = JSON.parse(p1)
assert(!parsed.key?('score') && !parsed.to_s.include?('"s"=>6'), 'the proof object carries no opened score field')
scores_leaked = (0..7).select do |s|
  # A trivial distinguisher: does any bit commitment literally equal b*G (i.e.
  # unblinded)? Perfect hiding means never.
  JSON.parse(p1)['bit_commitments'].any? { |enc| enc == EC.encode(EC.scalar_mul(s, EC.g)) }
end
assert(scores_leaked.empty?, 'no bit commitment is an unblinded multiple of G (hiding holds structurally)')

puts '== determinism boundary: same challenge inputs, same challenge =='

pf = JSON.parse(P_T)
b0 = EC.decode(pf['bit_commitments'][0])
a0 = EC.decode(pf['or_proofs'][0]['a0'])
a1 = EC.decode(pf['or_proofs'][0]['a1'])
c_pt = EC.decode(C_T)
e_a = RP.range_challenge(0, c_pt, b0, a0, a1)
e_b = RP.range_challenge(0, c_pt, b0, a0, a1)
e_other = RP.range_challenge(1, c_pt, b0, a0, a1)
assert(e_a == e_b, 'Fiat-Shamir challenge is deterministic over the transcript')
assert(e_a != e_other, 'challenge binds the bit index j (cross-position replay blocked, §4)')

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
