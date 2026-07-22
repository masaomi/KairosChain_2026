# frozen_string_literal: true

# Design-constraint tests for the AUD-L3 reproduction-endorsement slice
# (aud_l3_reproducibility_design v0.4, freeze candidate; invariants RPR-1..5).
# Each block names the invariant whose implementable consequence it pins.

require 'json'
require 'digest'

anchoring = File.expand_path('../lib/synoptis/anchoring', __dir__)
require File.join(anchoring, 'entry')
require File.join(anchoring, 'chain_credential')
require File.join(anchoring, 'attestation_types')
require File.join(anchoring, 'reproduction')

Entry = Synoptis::Anchoring::Entry
Cred = Synoptis::Anchoring::ChainCredential
AType = Synoptis::Anchoring::AttestationTypes
Repro = Synoptis::Anchoring::Reproduction

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

HEX_A = 'a' * 64
HEX_B = 'b' * 64
HEX_C = 'c' * 64
HEX_D = 'd' * 64
HEX_E = 'e' * 64

OPERATOR_IDENTITY = "block1-sha256:#{'1' * 64}"
ENDORSER_IDENTITY = "block1-sha256:#{'2' * 64}"
OPERATOR_KEY = Cred.generate_key
ENDORSER_KEY = Cred.generate_key
OPERATOR_CRED = Cred.build(OPERATOR_IDENTITY, OPERATOR_KEY)
ENDORSER_CRED = Cred.build(ENDORSER_IDENTITY, ENDORSER_KEY)

puts '== rpr-1 convention is content-addressed =='

assert(Repro.convention_sha256.match?(/\A[a-f0-9]{64}\z/), 'rpr-1 convention digest is 64-hex (content-addressed)')

puts '== RPR-2: re-execution target, output included, closed schema =='

target = Repro.build_target(input_sha256: HEX_A, environment_sha256: HEX_B,
                            pipeline_sha256: HEX_C, output_sha256: HEX_D)
assert(Repro.parse_target!(target).is_a?(Hash), 'a built target parses (canonical, exact fields)')
assert(Repro.target_digest(target).match?(/\A[a-f0-9]{64}\z/), 'target digest is 64-hex of canonical JSON')

assert_raises(Repro::ReproductionError, 'extra field is refused, not coerced (closed schema)') do
  extra = JSON.parse(target).merge('note' => 'x')
  Repro.parse_target!(Entry.canonical_json(extra))
end

assert_raises(Repro::ReproductionError, 'non-canonical serialization is refused (one record, one digest)') do
  Repro.parse_target!(JSON.pretty_generate(JSON.parse(target)))
end

assert_raises(Repro::ReproductionError, 'mutable/uncommitted referent (bad hex) is refused (RPR-2)') do
  Repro.build_target(input_sha256: 'not-a-digest', environment_sha256: HEX_B,
                     pipeline_sha256: HEX_C, output_sha256: HEX_D)
end

puts '== §3(b): computation identification excludes the output digest =='

sibling = Repro.build_target(input_sha256: HEX_A, environment_sha256: HEX_B,
                             pipeline_sha256: HEX_C, output_sha256: HEX_E)
other = Repro.build_target(input_sha256: HEX_E, environment_sha256: HEX_B,
                           pipeline_sha256: HEX_C, output_sha256: HEX_D)
assert(Repro.computation_id(target) == Repro.computation_id(sibling),
       'targets differing only in output share the computation identification')
assert(Repro.computation_id(target) != Repro.computation_id(other),
       'targets differing in input do not share the computation identification')
assert(Repro.target_digest(target) != Repro.target_digest(sibling),
       'sibling targets remain distinct targets (identification is coarser than identity)')

puts '== RPR-3: tolerance is target-bound, result-free, closed schema =='

tol = Repro.build_tolerance(target_sha256: Repro.target_digest(target))
assert(Repro.parse_tolerance!(tol)['kind'] == 'bit-identity', 'rpr-1 tolerance kind is bit-identity (narrowness disclosed)')
assert(Repro.parse_tolerance!(tol)['target_sha256'] == Repro.target_digest(target), 'tolerance binds its target by digest')

assert_raises(Repro::ReproductionError, 'unknown tolerance kind is refused (closed schema = result-free by construction)') do
  Repro.build_tolerance(target_sha256: Repro.target_digest(target), kind: 'whatever-fits')
end

puts '== RPR-1: verdict both ways, nothing else =='

endo = Repro.build_endorsement(target_sha256: Repro.target_digest(target),
                               tolerance_sha256: Repro.tolerance_digest(tol),
                               verdict: 'reproduced', adjudication_mode: 'hand')
nendo = Repro.build_endorsement(target_sha256: Repro.target_digest(target),
                                tolerance_sha256: Repro.tolerance_digest(tol),
                                verdict: 'not-reproduced', adjudication_mode: 'hand')
assert(Repro.parse_endorsement!(endo)['verdict'] == 'reproduced', 'affirmative verdict is a conforming record')
assert(Repro.parse_endorsement!(nendo)['verdict'] == 'not-reproduced', 'negative verdict is the same kind of record (RPR-1: no publication bias by vocabulary)')

assert_raises(Repro::ReproductionError, 'a verdict outside reproduced/not-reproduced is refused') do
  Repro.build_endorsement(target_sha256: Repro.target_digest(target),
                          tolerance_sha256: Repro.tolerance_digest(tol),
                          verdict: 'correct', adjudication_mode: 'hand')
end

puts '== RPR-4: adjudication mode is named, per mode closed schema =='

pendo = Repro.build_endorsement(target_sha256: Repro.target_digest(target),
                                tolerance_sha256: Repro.tolerance_digest(tol),
                                verdict: 'reproduced', adjudication_mode: 'procedure',
                                procedure_sha256: HEX_E)
assert(Repro.parse_endorsement!(pendo)['procedure_sha256'] == HEX_E, 'procedure mode names the adopted procedure')

assert_raises(Repro::ReproductionError, 'procedure mode without procedure_sha256 is refused (gate must be readable)') do
  Repro.build_endorsement(target_sha256: Repro.target_digest(target),
                          tolerance_sha256: Repro.tolerance_digest(tol),
                          verdict: 'reproduced', adjudication_mode: 'procedure')
end

assert_raises(Repro::ReproductionError, 'hand mode carrying procedure_sha256 is refused (closed schema per mode)') do
  Repro.build_endorsement(target_sha256: Repro.target_digest(target),
                          tolerance_sha256: Repro.tolerance_digest(tol),
                          verdict: 'reproduced', adjudication_mode: 'hand',
                          procedure_sha256: HEX_E)
end

puts '== map-1 §1.1 signature reuse: sign/verify endorsement =='

sig = Repro.sign_endorsement(endo, ENDORSER_CRED, ENDORSER_KEY)
assert(Repro.verify_endorsement(endo, ENDORSER_CRED, sig), 'endorsement verifies with credential+record+signature only (MAP-2 self-authentication)')
assert(!Repro.verify_endorsement(nendo, ENDORSER_CRED, sig), 'signature does not transfer to a different verdict record')
assert(!Repro.verify_endorsement(endo, OPERATOR_CRED, sig), 'signature does not verify under a foreign credential')

puts '== RPR-4: foreignness is a conformance condition =='

assert(Repro.foreign?(ENDORSER_CRED, OPERATOR_CRED), 'distinct endorser credential is foreign (conforming)')
assert(!Repro.foreign?(OPERATOR_CRED, OPERATOR_CRED), 'operator self-endorsement is not foreign (non-conforming as rpr-1)')

puts '== RPR-3: declaration-set assessment (menu + siblings + residue) =='

tol_sib = Repro.build_tolerance(target_sha256: Repro.target_digest(sibling))
tol_other = Repro.build_tolerance(target_sha256: Repro.target_digest(other))
tol_orphan = Repro.build_tolerance(target_sha256: HEX_E) # target not in supplied view

report = Repro.assess_declarations(
  targets: [target, sibling, other],
  declarations: [
    { 'tolerance' => tol, 'position' => 10 },
    { 'tolerance' => tol_sib, 'position' => 11 },
    { 'tolerance' => tol_other, 'position' => 12 },
    { 'tolerance' => tol_orphan, 'position' => 13 }
  ],
  invoked_tolerance_sha256: Repro.tolerance_digest(tol),
  endorsement_position: 20
)
assert(report[:invoked_conforming], 'anterior invoked tolerance is conforming (RPR-3)')
assert(report[:multiplicity] == 2, 'sibling-target declaration pools into the same set (target-splitting exposed)')
assert(report[:declaration_set].none? { |e| e[:target_sha256] == Repro.target_digest(other) },
       'a different computation does not pool into the set')
assert(report[:residue].size == 1 && report[:residue][0][:reason].include?('unresolvable'),
       'unresolvable target binding is disclosed as residue, not silently dropped')

posterior = Repro.assess_declarations(
  targets: [target],
  declarations: [{ 'tolerance' => tol, 'position' => 30 }],
  invoked_tolerance_sha256: Repro.tolerance_digest(tol),
  endorsement_position: 20
)
assert(!posterior[:invoked_conforming], 'a tolerance committed after the endorsement is non-conforming (anteriority, MPR-8)')

puts '== RPR-3: assessment is order-independent over commitments =='

both_orders = [
  [{ 'tolerance' => tol, 'position' => 5 }, { 'tolerance' => tol, 'position' => 30 }],
  [{ 'tolerance' => tol, 'position' => 30 }, { 'tolerance' => tol, 'position' => 5 }]
].map do |decls|
  Repro.assess_declarations(targets: [target], declarations: decls,
                            invoked_tolerance_sha256: Repro.tolerance_digest(tol),
                            endorsement_position: 20)
end
assert(both_orders.all? { |r| r[:invoked_conforming] },
       'a digest committed anterior AND posterior conforms in both presentation orders (committed order, not array order)')
assert(both_orders.all? { |r| r[:invoked][:position] == 5 },
       'the earliest anterior commitment represents the invoked declaration in both orders')
assert(both_orders.all? { |r| r[:invoked_posterior].size == 1 && r[:invoked_posterior][0][:position] == 30 },
       'the posterior commitment of the invoked digest is disclosed, not dropped')

dup = Repro.assess_declarations(
  targets: [target],
  declarations: [{ 'tolerance' => tol, 'position' => 10 }, { 'tolerance' => tol, 'position' => 10 }],
  invoked_tolerance_sha256: Repro.tolerance_digest(tol),
  endorsement_position: 20
)
assert(dup[:multiplicity] == 1, 'the same (digest, position) supplied twice is one commitment; multiplicity counts distinct declarations')
assert(dup[:invoked_rank] == 1, 'the invoked declaration reports its rank in the pooled anterior set (rpr-1 §2.1)')

tol_a = Repro.build_tolerance(target_sha256: Repro.target_digest(target))
tol_b = Repro.build_tolerance(target_sha256: Repro.target_digest(sibling))
tie_orders = [
  [{ 'tolerance' => tol_a, 'position' => 5 }, { 'tolerance' => tol_b, 'position' => 5 }],
  [{ 'tolerance' => tol_b, 'position' => 5 }, { 'tolerance' => tol_a, 'position' => 5 }]
].map do |decls|
  Repro.assess_declarations(targets: [target, sibling], declarations: decls,
                            invoked_tolerance_sha256: Repro.tolerance_digest(tol_a),
                            endorsement_position: 20)
end
assert(tie_orders[0][:invoked_rank] == tie_orders[1][:invoked_rank],
       'equal earliest positions rank identically in both presentation orders (digest tiebreak, rpr-1 §2.1)')

puts '== RPR-5: retraction is the map-1 §3 act unchanged =='

retraction_ok = AType.validate_intake!('retraction', { 'target_entry_hash' => HEX_A })
assert(retraction_ok, 'a reproduction-endorsement retraction rides map-1 §3 intake unchanged')
assert(AType::VOCABULARY.include?('quality-endorsement'), 'endorsements are carried by the unchanged map-1 quality-endorsement type')

puts '== additive-only: rpr-1 leaves map-1 vocabulary untouched =='

assert(AType::VOCABULARY == %w[observation quality-endorsement succession-designation retraction],
       'map-1 vocabulary unchanged by the rpr-1 slice (extension would be a new convention)')

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
