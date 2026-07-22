# frozen_string_literal: true

# Design/behaviour tests for the AUD-L4 ZK aggregate reproducibility SPIKE,
# Phase 1 (Pedersen commitments + aggregate opening + SDP-2 score binding;
# NOT the range proof). aud_l4_zk_aggregate_reproducibility_spike_design v0.1.
#
# The pure-Ruby EcGroup is cross-validated against OpenSSL's secp256k1 as a
# correctness ORACLE (tests only; OpenSSL is never on the library path), which
# is the disclosed way this hand-rolled arithmetic earns trust (SDP-5).

require 'json'
require 'digest'
require 'openssl'

anchoring = File.expand_path('../lib/synoptis/anchoring', __dir__)
require File.join(anchoring, 'entry')
require File.join(anchoring, 'selective_disclosure')
require File.join(anchoring, 'ec_group')
require File.join(anchoring, 'pedersen')
require File.join(anchoring, 'aggregate_disclosure')

Entry = Synoptis::Anchoring::Entry
EC = Synoptis::Anchoring::EcGroup
Ped = Synoptis::Anchoring::Pedersen
Agg = Synoptis::Anchoring::AggregateDisclosure

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

# -- OpenSSL secp256k1 oracle helpers (tests only) --

OSSL_GROUP = OpenSSL::PKey::EC::Group.new('secp256k1')

def ossl_generator_mul(k)
  res = OSSL_GROUP.generator.mul(OpenSSL::BN.new(k))
  affine(res)
end

def ossl_point(x, y)
  oct = ['04' + x.to_s(16).rjust(64, '0') + y.to_s(16).rjust(64, '0')].pack('H*')
  OpenSSL::PKey::EC::Point.new(OSSL_GROUP, OpenSSL::BN.new(oct, 2))
end

def affine(point)
  bytes = point.to_octet_string(:uncompressed).unpack1('H*')
  [Integer(bytes[2, 64], 16), Integer(bytes[66, 64], 16)]
end

puts '== EcGroup: generators and curve membership =='

assert(EC.on_curve?(EC.g), 'base point G is on the curve')
assert(EC.on_curve?(EC.h), 'second generator H is on the curve')
assert(EC.g != EC.h, 'G and H are distinct generators')
assert([EC.g.x, EC.g.y] == ossl_generator_mul(1), 'G matches OpenSSL secp256k1 generator (oracle)')
# H is nothing-up-my-sleeve: recomputing from the seed reproduces it bit-for-bit.
assert(EC.hash_to_curve(EC::H_SEED) == EC.h, 'H is deterministically re-derivable from the public seed (SDP-5)')

puts '== EcGroup: scalar multiplication cross-validated against OpenSSL =='

[1, 2, 3, 7, 255, 65_537, 2**128 + 1, EC::N - 1].each do |k|
  ours = EC.scalar_mul(k, EC.g)
  assert([ours.x, ours.y] == ossl_generator_mul(k), "scalar_mul(#{k}, G) matches OpenSSL (oracle)")
end
assert(EC.scalar_mul(EC::N, EC.g) == EC::INFINITY, 'N * G = O (G has order N)')
assert(EC.scalar_mul(EC::N + 5, EC.g) == EC.scalar_mul(5, EC.g), 'scalars reduce mod N')

puts '== EcGroup: group laws and non-generator scalar mul (H via oracle) =='

a = EC.scalar_mul(12_345, EC.g)
b = EC.scalar_mul(67_890, EC.h)
c = EC.scalar_mul(11, EC.g)
assert(EC.add(a, b) == EC.add(b, a), 'point addition is commutative')
assert(EC.add(EC.add(a, b), c) == EC.add(a, EC.add(b, c)), 'point addition is associative')
assert(EC.add(a, EC::INFINITY) == a, 'the identity is neutral')
assert(EC.add(a, EC.negate(a)) == EC::INFINITY, 'a point plus its negation is the identity')
# scalar_mul on a NON-generator point (H), cross-checked through OpenSSL.
h_ossl = ossl_point(EC.h.x, EC.h.y)
[2, 3, 100, 2**64].each do |k|
  ours = EC.scalar_mul(k, EC.h)
  assert([ours.x, ours.y] == affine(h_ossl.mul(OpenSSL::BN.new(k))), "scalar_mul(#{k}, H) matches OpenSSL (oracle)")
end

puts '== EcGroup: compressed encode/decode round-trip =='

[EC.g, EC.h, a, b, EC::INFINITY].each_with_index do |pt, i|
  assert(EC.decode(EC.encode(pt)) == pt, "encode/decode round-trips (point #{i})")
end
assert_raises(EC::GroupError, 'decoding an off-curve x is refused') do
  # Find an x whose (x^3 + 7) is a quadratic non-residue: no curve point exists.
  off = (2..1000).find { |x| EC.sqrt_mod((x.pow(3, EC::P) + EC::B) % EC::P).nil? }
  EC.decode('02' + off.to_s(16).rjust(64, '0'))
end

puts '== Pedersen: commitment, hiding-shape, homomorphism =='

c1 = Ped.commit(3, 111)
c2 = Ped.commit(4, 222)
assert(Ped.commit(3, 111) == c1, 'commitment is deterministic given (value, blinding)')
assert(EC.add(c1, c2) == Ped.commit(7, 333), 'Pedersen is additively homomorphic: C(3,111)+C(4,222)=C(7,333)')
assert_raises(Ped::CommitmentError, 'a zero blinding is refused (would disclose the value)') { Ped.commit(5, 0) }
assert_raises(Ped::CommitmentError, 'a negative value is refused') { Ped.commit(-1, 5) }

puts '== Pedersen: aggregate opening (plain) =='

scores = [1, 5, 7, 2, 6]
blindings = [10, 20, 30, 40, 50]
commitments = scores.zip(blindings).map { |s, r| Ped.commit(s, r) }
agg = Ped.aggregate(commitments)
sum_s = scores.sum
sum_r = blindings.sum
assert(Ped.open?(agg, sum_s, sum_r), 'aggregate opens for the true (Σs, Σr)')
assert(!Ped.open?(agg, sum_s + 1, sum_r), 'aggregate does NOT open for a wrong Σs')
assert(!Ped.open?(agg, sum_s, sum_r + 1), 'aggregate does NOT open for a wrong Σr')

puts '== Pedersen: Schnorr aggregate-randomness proof (hides Σr) =='

proof = Ped.prove_aggregate_randomness(agg, sum_s, sum_r, nonce: 424_242)
assert(Ped.prove_aggregate_randomness(agg, sum_s, sum_r, nonce: 424_242) == proof, 'Schnorr proof is deterministic given the nonce')
assert(Ped.verify_aggregate_randomness(agg, sum_s, proof), 'honest Schnorr proof verifies for the correct Σs')
assert(!Ped.verify_aggregate_randomness(agg, sum_s + 1, proof), 'Schnorr proof fails for a tampered Σs')
tampered = proof.merge('z' => (Integer(proof['z'], 16) ^ 1).to_s(16))
assert(!Ped.verify_aggregate_randomness(agg, sum_s, tampered), 'Schnorr proof fails when the response z is tampered')

puts '== §3 attack: Phase 1 alone does NOT constrain range (motivates Phase 2) =='

# True scores are poor; the auditor forges a high mean by committing one
# out-of-range term. Pedersen constrains the SUM but no term's range, so the
# aggregate opens. This is the gap the Phase 2 range proof exists to close.
forged_scores = ([1] * 999) + [32_000]
forged_blindings = (1..1000).to_a
forged_commitments = forged_scores.zip(forged_blindings).map { |s, r| Ped.commit(s, r) }
forged_agg = Ped.aggregate(forged_commitments)
assert(Ped.open?(forged_agg, forged_scores.sum, forged_blindings.sum),
       'an out-of-range term STILL opens at Phase 1 — the forged mean passes (design memo §3; Phase 2 range proof required)')

puts '== AggregateDisclosure: SDP-2 score binding (dual commitment of one integer) =='

END_SHA = Digest::SHA256.hexdigest('rpr-1-endorsement-for-doi-1')
TGT_SHA = Digest::SHA256.hexdigest('rpr-1-target-for-doi-1')
rec = Agg.score_record(endorsement_sha256: END_SHA, target_sha256: TGT_SHA, score: 6)
bound = Agg.commit_score(rec, score: 6, blinding: 7777, salts: nil)
assert(Agg.verify_binding(record_string: rec, aux_string: bound['aux'], salts: bound['salts'],
                          score: 6, blinding: 7777, commitment: bound['commitment']),
       'honest binding verifies: sdp-1 score digest and Pedersen commit the same integer')
# Desync: the Pedersen commitment commits a DIFFERENT score than the record.
desync = EC.encode(Ped.commit(2, 7777))
assert(!Agg.verify_binding(record_string: rec, aux_string: bound['aux'], salts: bound['salts'],
                           score: 6, blinding: 7777, commitment: desync),
       'a Pedersen commitment desynced from the score record is rejected (SDP-2: re-authoring is non-conforming)')
# Score out of band is refused at record construction.
assert_raises(Agg::AggregateError, 'a score outside [0,7] is refused (band VMAX=7, SDP-5 coarse)') do
  Agg.score_record(endorsement_sha256: END_SHA, target_sha256: TGT_SHA, score: 8)
end

puts '== AggregateDisclosure: DOI-set commitment fixes the referent =='

dois = %w[10.1101/aaa 10.1101/bbb 10.1101/ccc]
d1 = Agg.doi_set_commitment(dois)
assert(d1 == Agg.doi_set_commitment(dois.reverse), 'DOI-set commitment is order-independent (canonical over sorted digests)')
assert(d1 != Agg.doi_set_commitment(dois + ['10.1101/ddd']), 'adding a DOI changes the set commitment (no post-hoc substitution)')
assert_raises(Agg::AggregateError, 'a duplicate DOI is refused') { Agg.doi_set_commitment(%w[10.1101/aaa 10.1101/aaa]) }

puts '== AggregateDisclosure: end-to-end mean over committed scores =='

items = [
  { end: Digest::SHA256.hexdigest('e1'), tgt: Digest::SHA256.hexdigest('t1'), score: 7, r: 101 },
  { end: Digest::SHA256.hexdigest('e2'), tgt: Digest::SHA256.hexdigest('t2'), score: 5, r: 202 },
  { end: Digest::SHA256.hexdigest('e3'), tgt: Digest::SHA256.hexdigest('t3'), score: 6, r: 303 },
  { end: Digest::SHA256.hexdigest('e4'), tgt: Digest::SHA256.hexdigest('t4'), score: 4, r: 404 }
]
enc_commitments = items.map do |it|
  r = Agg.score_record(endorsement_sha256: it[:end], target_sha256: it[:tgt], score: it[:score])
  Agg.commit_score(r, score: it[:score], blinding: it[:r])['commitment']
end
tot_s = items.sum { |it| it[:score] }
tot_r = items.sum { |it| it[:r] }
report = Agg.verify_mean(commitments: enc_commitments, sum_s: tot_s, sum_r: tot_r)
assert(report[:valid], 'end-to-end aggregate opens for the honest sums')
assert(report[:count] == 4 && report[:mean_band] == Rational(22, 4), 'reported mean band = Σscore / N')
assert(report[:mean_percent] == Rational(22, 4 * 7) * 100, 'reported mean percent scales the band to 0–100')
bad = Agg.verify_mean(commitments: enc_commitments, sum_s: tot_s + 1, sum_r: tot_r)
assert(!bad[:valid], 'a wrong published mean does not open')

puts '== determinism: same inputs, same bytes =='

again = Agg.commit_score(rec, score: 6, blinding: 7777, salts: bound['salts'])
assert(again['commitment'] == bound['commitment'] && again['aux'] == bound['aux'],
       'commit_score is deterministic given (record, score, blinding, salts)')

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
