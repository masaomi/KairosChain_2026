# frozen_string_literal: true

# Design-constraint tests for the AUD-L4 selective-disclosure slice
# (aud_l4_selective_disclosure_design v0.3, FROZEN; invariants SDP-1..5).
# Each block names the invariant whose implementable consequence it pins.

require 'json'
require 'digest'

anchoring = File.expand_path('../lib/synoptis/anchoring', __dir__)
require File.join(anchoring, 'entry')
require File.join(anchoring, 'chain_credential')
require File.join(anchoring, 'reproduction')
require File.join(anchoring, 'selective_disclosure')

Entry = Synoptis::Anchoring::Entry
Cred = Synoptis::Anchoring::ChainCredential
Repro = Synoptis::Anchoring::Reproduction
SD = Synoptis::Anchoring::SelectiveDisclosure

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

OPERATOR_IDENTITY = "block1-sha256:#{'1' * 64}"
ENDORSER_IDENTITY = "block1-sha256:#{'2' * 64}"
OPERATOR_KEY = Cred.generate_key
ENDORSER_KEY = Cred.generate_key
OPERATOR_CRED = Cred.build(OPERATOR_IDENTITY, OPERATOR_KEY)
ENDORSER_CRED = Cred.build(ENDORSER_IDENTITY, ENDORSER_KEY)

# A committed rpr-1 lineage to blind: target -> tolerance -> endorsement.
TARGET = Repro.build_target(input_sha256: HEX_A, environment_sha256: HEX_B,
                            pipeline_sha256: HEX_C, output_sha256: HEX_D)
TOL = Repro.build_tolerance(target_sha256: Repro.target_digest(TARGET))
ENDO = Repro.build_endorsement(target_sha256: Repro.target_digest(TARGET),
                               tolerance_sha256: Repro.tolerance_digest(TOL),
                               verdict: 'reproduced', adjudication_mode: 'hand')
ENDO_SIG = Repro.sign_endorsement(ENDO, ENDORSER_CRED, ENDORSER_KEY)

puts '== sdp-1 convention is content-addressed =='

assert(SD.convention_sha256.match?(/\A[a-f0-9]{64}\z/), 'sdp-1 convention digest is 64-hex (content-addressed)')

puts '== SDP-2: field commitments are checkably bound, total coverage =='

built = SD.build_field_commitments(ENDO)
AUX = built['record']
SALTS = built['salts']
aux_parsed = SD.parse_field_commitments!(AUX)
assert(aux_parsed['record_sha256'] == Digest::SHA256.hexdigest(ENDO),
       'auxiliary commits the record digest (= khab-1 record commitment, sdp-1 §0)')
assert(aux_parsed['fields'].keys.sort == JSON.parse(ENDO).keys.sort,
       'coverage is total: one digest per record field (omission cannot hide)')
assert(SD.verify_field_commitments(AUX, ENDO, SALTS),
       'holder of record + salts recomputes every digest (SDP-2 checkable binding)')

tampered_fields = JSON.parse(AUX)
tampered_fields['fields']['verdict'] = HEX_A
assert(!SD.verify_field_commitments(Entry.canonical_json(tampered_fields), ENDO, SALTS),
       'a tampered field digest fails the binding check (bound, not asserted)')

other_record = Repro.build_endorsement(target_sha256: Repro.target_digest(TARGET),
                                       tolerance_sha256: Repro.tolerance_digest(TOL),
                                       verdict: 'not-reproduced', adjudication_mode: 'hand')
assert(!SD.verify_field_commitments(AUX, other_record, SALTS),
       'an auxiliary does not bind a different record (desync is decidable)')

wrong_salts = SALTS.merge('verdict' => 'f' * 32)
assert(!SD.verify_field_commitments(AUX, ENDO, wrong_salts),
       'a wrong salt fails recomputation (salt is part of the committed opening)')

assert_raises(SD::DisclosureError, 'extra field in auxiliary is refused (closed schema)') do
  extra = JSON.parse(AUX).merge('note' => 'x')
  SD.parse_field_commitments!(Entry.canonical_json(extra))
end

assert_raises(SD::DisclosureError, 'non-canonical auxiliary is refused (one record, one digest)') do
  SD.parse_field_commitments!(JSON.pretty_generate(JSON.parse(AUX)))
end

assert_raises(SD::DisclosureError, 'partial salt coverage is refused at build (coverage total by construction)') do
  SD.build_field_commitments(ENDO, salts: { 'verdict' => 'a' * 32 })
end

puts '== SDP-1/SDP-5: salted digests hide low-entropy values computationally =='

verdict_digest = aux_parsed['fields']['verdict']
guessed = SD.field_digest('0' * 32, 'verdict', 'reproduced')
assert(guessed != verdict_digest,
       'guessing the (2-value) verdict without the salt does not confirm against the digest (salt carries the hiding)')
assert(SD.field_digest(SALTS['verdict'], 'verdict', 'reproduced') == verdict_digest,
       'with the salt, the opening recomputes exactly (disclosure is an opening, not an assertion)')

puts '== sdp-1 §2: profile is closed, canonical, format always opened =='

profile = SD.build_profile(predicate: 'typed-existence', opened: %w[format])
assert(profile['opened'] == ['format'], 'profile.opened is sorted and includes format')

assert_raises(SD::DisclosureError, 'profile without format opened is refused (record kind always readable)') do
  SD.build_profile(predicate: 'typed-existence', opened: %w[verdict])
end

assert_raises(SD::DisclosureError, 'unknown predicate is refused (closed vocabulary)') do
  SD.build_profile(predicate: 'proves-correctness', opened: %w[format])
end

assert_raises(SD::DisclosureError, 'unknown currency is refused (closed vocabulary)') do
  SD.build_profile(predicate: 'typed-existence', opened: %w[format], currency: 'implied')
end

assert_raises(SD::DisclosureError, 'extra profile field is refused (no producer gloss, SDP-4)') do
  SD.validate_profile!(profile.merge('meaning' => 'trust me'))
end

puts '== typed-existence presentation: build, verify, withhold =='

pres = SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                             opened: %w[format], predicate: 'typed-existence')
report = SD.verify_presentation(pres)
assert(report[:valid], 'typed-existence presentation verifies')
assert(report[:opened] == { 'format' => 'rpr-1/endorsement' },
       'exactly the profiled fields are opened; everything else stays digests (SDP-1)')
assert(!pres.include?('reproduced') && !pres.include?(Repro.target_digest(TARGET)),
       'withheld values (verdict, target digest) appear nowhere in the presentation bytes')
assert(report[:record_sha256] == Digest::SHA256.hexdigest(ENDO),
       'the committed record digest is revealed (content-blinding, not referent-blinding — sdp-1 §0 narrowness)')

tampered = JSON.parse(pres)
tampered['opened']['format']['value'] = 'rpr-1/tolerance'
assert(!SD.verify_presentation(Entry.canonical_json(tampered))[:valid],
       'a tampered opened value fails recomputation against the committed digest')

assert_raises(SD::DisclosureError, 'opened set differing from profile.opened is refused (statement-determining, SDP-4)') do
  swap = JSON.parse(pres)
  swap['opened']['verdict'] = { 'salt' => SALTS['verdict'], 'value' => 'reproduced' }
  SD.verify_presentation(Entry.canonical_json(swap))
end

assert_raises(SD::DisclosureError, 'non-canonical presentation is refused (one artifact, one digest)') do
  SD.verify_presentation(JSON.pretty_generate(JSON.parse(pres)))
end

assert_raises(SD::DisclosureError, 'typed-existence with credential is refused (closed schema per shape)') do
  SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                        opened: %w[format], predicate: 'typed-existence',
                        credential: ENDORSER_CRED, signature: 'a' * 128)
end

puts '== claimed-verdict: signature verifies without record content (map-1 §1.1) =='

claimed = SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                                opened: %w[format verdict], predicate: 'claimed-verdict',
                                credential: ENDORSER_CRED, signature: ENDO_SIG)
creport = SD.verify_presentation(claimed)
assert(creport[:valid], 'claimed-verdict presentation verifies (signature checked from the digest alone)')
assert(creport[:opened]['verdict'] == 'reproduced', 'the verdict is opened and recomputes')
assert(!claimed.include?(Repro.target_digest(TARGET)),
       'the endorsement target digest stays withheld under claimed-verdict')

badsig = JSON.parse(claimed)
badsig['signature'] = ENDO_SIG.reverse
assert(!SD.verify_presentation(Entry.canonical_json(badsig))[:valid],
       'a wrong signature fails (the claim is the credential holder\'s, or it is nothing)')

forged = SD.build_field_commitments(other_record)
assert_raises(SD::DisclosureError, 'presenting a record against a foreign auxiliary is refused at build (SDP-2)') do
  SD.build_presentation(record_string: ENDO, aux_string: forged['record'], salts: SALTS,
                        opened: %w[format verdict], predicate: 'claimed-verdict',
                        credential: ENDORSER_CRED, signature: ENDO_SIG)
end

assert_raises(SD::DisclosureError, 'claimed-verdict without verdict opened is refused (sdp-1 §4)') do
  SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                        opened: %w[format], predicate: 'claimed-verdict',
                        credential: ENDORSER_CRED, signature: ENDO_SIG)
end

puts '== conforming-verdict: conformance conditions inside the predicate (SDP-1 upward bound) =='

conf_opened = %w[adjudication_mode format target_sha256 tolerance_sha256 verdict]
conforming = SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                                   opened: conf_opened, predicate: 'conforming-verdict',
                                   credential: ENDORSER_CRED, signature: ENDO_SIG)
material = { 'targets' => [TARGET],
             'declarations' => [{ 'tolerance' => TOL, 'position' => 10 }],
             'endorsement_position' => 20 }
freport = SD.verify_presentation(conforming, operator_credential: OPERATOR_CRED, assessment: material)
assert(freport[:valid], 'conforming-verdict verifies with foreignness + anterior tolerance material')

no_op = SD.verify_presentation(conforming, assessment: material)
assert(!no_op[:valid] && no_op[:failures].any? { |f| f.include?('operator credential') },
       'missing operator credential fails, never degrades (refuse-not-degrade)')

no_material = SD.verify_presentation(conforming, operator_credential: OPERATOR_CRED)
assert(!no_material[:valid] && no_material[:failures].any? { |f| f.include?('assessment material') },
       'missing anteriority material fails, never degrades (SDP-1 upward bound)')

same_party = SD.verify_presentation(conforming, operator_credential: ENDORSER_CRED, assessment: material)
assert(!same_party[:valid] && same_party[:failures].any? { |f| f.include?('not foreign') },
       'endorser == operator fails foreignness (RPR-4 carried into the blinded predicate)')

posterior = { 'targets' => [TARGET],
              'declarations' => [{ 'tolerance' => TOL, 'position' => 30 }],
              'endorsement_position' => 20 }
late = SD.verify_presentation(conforming, operator_credential: OPERATOR_CRED, assessment: posterior)
assert(!late[:valid] && late[:failures].any? { |f| f.include?('conforming') },
       'a posterior-only tolerance fails the anteriority assessment (RPR-3 inside the blinded predicate)')

assert_raises(SD::DisclosureError, 'conforming-verdict without the conformance fields opened is refused') do
  SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                        opened: %w[format verdict], predicate: 'conforming-verdict',
                        credential: ENDORSER_CRED, signature: ENDO_SIG)
end

puts '== SDP-3 currency: scan-checkable vs unestablished, declared never implied =='

carrier = 'e' * 64
scanpres = SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                                 opened: %w[format verdict], predicate: 'claimed-verdict',
                                 currency: 'scan-checkable',
                                 credential: ENDORSER_CRED, signature: ENDO_SIG,
                                 carrier_entry_hash: carrier)
sreport = SD.verify_presentation(scanpres)
assert(sreport[:valid], 'scan-checkable presentation verifies and names its carrier entry')

entries = [
  { 'entry_hash' => carrier, 'attestation_type' => 'quality-endorsement', 'depositor' => 'endorser', 'position' => 5 },
  { 'entry_hash' => 'f' * 64, 'attestation_type' => 'retraction', 'depositor' => 'endorser',
    'position' => 8, 'metadata' => { 'target_entry_hash' => carrier } }
]
scan = SD.scan_currency(entries: entries, carrier_entry_hash: carrier, extent: 10)
assert(scan[:status] == 'retracted' && scan[:hits] == [8],
       'a same-issuer retraction at or before the extent reads retracted (SDP-3 currency face)')

clean = SD.scan_currency(entries: [entries[0]], carrier_entry_hash: carrier, extent: 10)
assert(clean[:status] == 'unretracted', 'no retraction in view reads unretracted up to the extent, no further')

foreign_retract = [entries[0], entries[1].merge('depositor' => 'someone-else')]
fscan = SD.scan_currency(entries: foreign_retract, carrier_entry_hash: carrier, extent: 10)
assert(fscan[:status] == 'unretracted',
       'a retraction from a different depositor does not retract (map-1 §3 issuer rule)')

beyond = [entries[0], entries[1].merge('position' => 15)]
bscan = SD.scan_currency(entries: beyond, carrier_entry_hash: carrier, extent: 10)
assert(bscan[:status] == 'unretracted' && bscan[:note].include?('outside'),
       'a retraction beyond the extent is disclosed, not dropped (SDP-3)')

missing = SD.scan_currency(entries: [entries[1]], carrier_entry_hash: carrier, extent: 10)
assert(missing[:status] == 'unestablished',
       'carrier not in view reads unestablished, never unretracted (refuse-not-degrade)')

assert_raises(SD::DisclosureError, 'scan-checkable without carrier_entry_hash is refused at build') do
  SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                        opened: %w[format verdict], predicate: 'claimed-verdict',
                        currency: 'scan-checkable',
                        credential: ENDORSER_CRED, signature: ENDO_SIG)
end

assert_raises(SD::DisclosureError, 'carrier_entry_hash under unestablished currency is refused (closed schema per shape)') do
  SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                        opened: %w[format verdict], predicate: 'claimed-verdict',
                        credential: ENDORSER_CRED, signature: ENDO_SIG,
                        carrier_entry_hash: carrier)
end

puts '== R1 fixes: crafted records must not wear the endorsement face (SDP-1) =='

def crafted_presentation(record_hash, opened:, predicate:, operatorless: false)
  record = Entry.canonical_json(record_hash)
  sig = Cred.sign_attestation(ENDORSER_CRED, ENDORSER_KEY, record)
  built = SD.build_field_commitments(record)
  SD.build_presentation(record_string: record, aux_string: built['record'], salts: built['salts'],
                        opened: opened, predicate: predicate,
                        credential: ENDORSER_CRED, signature: sig)
end

extra_field = crafted_presentation(
  { 'adjudication_mode' => 'hand', 'extra' => 'x', 'format' => 'rpr-1/endorsement',
    'target_sha256' => HEX_A, 'tolerance_sha256' => HEX_B, 'verdict' => 'reproduced' },
  opened: %w[format verdict], predicate: 'claimed-verdict'
)
er = SD.verify_presentation(extra_field)
assert(!er[:valid] && er[:failures].any? { |f| f.include?('endorsement shape') },
       'a signed record with an extra public field is not an endorsement shape and fails verdict predicates [R1 fix]')

maybe = crafted_presentation(
  { 'adjudication_mode' => 'hand', 'format' => 'rpr-1/endorsement',
    'target_sha256' => HEX_A, 'tolerance_sha256' => HEX_B, 'verdict' => 'maybe' },
  opened: %w[format verdict], predicate: 'claimed-verdict'
)
mr = SD.verify_presentation(maybe)
assert(!mr[:valid] && mr[:failures].any? { |f| f.include?('closed vocabulary') },
       'a verdict outside the rpr-1 vocabulary fails, never overclaims [R1 fix]')

int_tol = crafted_presentation(
  { 'adjudication_mode' => 'hand', 'format' => 'rpr-1/endorsement',
    'target_sha256' => HEX_A, 'tolerance_sha256' => 5, 'verdict' => 'reproduced' },
  opened: %w[adjudication_mode format target_sha256 tolerance_sha256 verdict],
  predicate: 'conforming-verdict'
)
material0 = { 'targets' => [TARGET], 'declarations' => [{ 'tolerance' => TOL, 'position' => 10 }],
              'endorsement_position' => 20 }
ir = SD.verify_presentation(int_tol, operator_credential: OPERATOR_CRED, assessment: material0)
assert(!ir[:valid] && ir[:failures].any? { |f| f.include?('refuse, not degrade') },
       'a non-hex opened conformance digest FAILS instead of skipping the assessment [R1 fix, was PROBED skip]')

puts '== R1 fix: tolerance-target coherence (RPR-3 binding inside the blinded predicate) =='

OTHER_TARGET = Repro.build_target(input_sha256: HEX_D, environment_sha256: HEX_B,
                                  pipeline_sha256: HEX_C, output_sha256: HEX_A)
TOL_OTHER = Repro.build_tolerance(target_sha256: Repro.target_digest(OTHER_TARGET))
mismatched = Repro.build_endorsement(target_sha256: Repro.target_digest(TARGET),
                                     tolerance_sha256: Repro.tolerance_digest(TOL_OTHER),
                                     verdict: 'reproduced', adjudication_mode: 'hand')
mm_sig = Repro.sign_endorsement(mismatched, ENDORSER_CRED, ENDORSER_KEY)
mm_built = SD.build_field_commitments(mismatched)
mm_pres = SD.build_presentation(record_string: mismatched, aux_string: mm_built['record'], salts: mm_built['salts'],
                                opened: %w[adjudication_mode format target_sha256 tolerance_sha256 verdict],
                                predicate: 'conforming-verdict',
                                credential: ENDORSER_CRED, signature: mm_sig)
mm_material = { 'targets' => [TARGET, OTHER_TARGET],
                'declarations' => [{ 'tolerance' => TOL_OTHER, 'position' => 10 }],
                'endorsement_position' => 20 }
mmr = SD.verify_presentation(mm_pres, operator_credential: OPERATOR_CRED, assessment: mm_material)
assert(!mmr[:valid] && mmr[:failures].any? { |f| f.include?('RPR-3 target binding') },
       'a tolerance bound to an UNRELATED computation fails coherence [R1 fix, was PROBED pass]')

puts '== R2 fix: sibling-bound tolerance is one menu (rpr-1 §2.1 pooling) =='

SIB_TARGET = Repro.build_target(input_sha256: HEX_A, environment_sha256: HEX_B,
                                pipeline_sha256: HEX_C, output_sha256: HEX_B)
TOL_SIB = Repro.build_tolerance(target_sha256: Repro.target_digest(SIB_TARGET))
sib_endo = Repro.build_endorsement(target_sha256: Repro.target_digest(TARGET),
                                   tolerance_sha256: Repro.tolerance_digest(TOL_SIB),
                                   verdict: 'reproduced', adjudication_mode: 'hand')
sib_sig = Repro.sign_endorsement(sib_endo, ENDORSER_CRED, ENDORSER_KEY)
sib_built = SD.build_field_commitments(sib_endo)
sib_pres = SD.build_presentation(record_string: sib_endo, aux_string: sib_built['record'], salts: sib_built['salts'],
                                 opened: %w[adjudication_mode format target_sha256 tolerance_sha256 verdict],
                                 predicate: 'conforming-verdict',
                                 credential: ENDORSER_CRED, signature: sib_sig)
sib_material = { 'targets' => [TARGET, SIB_TARGET],
                 'declarations' => [{ 'tolerance' => TOL_SIB, 'position' => 10 }],
                 'endorsement_position' => 20 }
sibr = SD.verify_presentation(sib_pres, operator_credential: OPERATOR_CRED, assessment: sib_material)
assert(sibr[:valid],
       'an anterior tolerance bound to a SIBLING target (same computation identification) conforms — a convention-only verifier and this code now agree [R2 fix]')

no_end_target = { 'targets' => [SIB_TARGET],
                  'declarations' => [{ 'tolerance' => TOL_SIB, 'position' => 10 }],
                  'endorsement_position' => 20 }
ner = SD.verify_presentation(sib_pres, operator_credential: OPERATOR_CRED, assessment: no_end_target)
assert(!ner[:valid] && ner[:failures].any? { |f| f.include?('coherence undecidable') },
       'an unresolvable endorsement target refuses, never degrades [R2 fix]')

puts '== R1 fixes: presentation schema hardening + scan robustness =='

int_sig = JSON.parse(claimed)
int_sig['signature'] = 12_345
assert_raises(SD::DisclosureError, 'non-string signature is refused at parse (no TypeError escape) [R1 fix]') do
  SD.verify_presentation(Entry.canonical_json(int_sig))
end

noise_meta = [entries[0],
              { 'entry_hash' => 'f' * 64, 'attestation_type' => 'retraction', 'depositor' => 'endorser',
                'position' => 8, 'metadata' => 'NOTAHASH' }]
nm = SD.scan_currency(entries: noise_meta, carrier_entry_hash: carrier, extent: 10)
assert(nm[:status] == 'unretracted',
       'a retraction view with non-Hash metadata is noise, never a crash [R1 fix, was PROBED TypeError]')

foreign_beyond = [entries[0], entries[1].merge('depositor' => 'someone-else', 'position' => 15)]
fb = SD.scan_currency(entries: foreign_beyond, carrier_entry_hash: carrier, extent: 10)
assert(fb[:status] == 'unretracted' && !fb[:note].include?('outside'),
       'a FOREIGN retraction beyond the extent is not counted in the beyond note (map-1 §3 issuer rule everywhere) [R1 fix]')

dup_hits = [entries[0], entries[1], entries[1]]
dh = SD.scan_currency(entries: dup_hits, carrier_entry_hash: carrier, extent: 10)
assert(dh[:hits] == [8], 'duplicate retraction views collapse to one committed position [R1 fix]')

puts '== R2 fixes: scan residue disclosure (SDP-3) =='

no_dep = [{ 'entry_hash' => carrier, 'attestation_type' => 'quality-endorsement', 'position' => 5 }]
nd = SD.scan_currency(entries: no_dep, carrier_entry_hash: carrier, extent: 10)
assert(nd[:status] == 'unestablished' && nd[:note].include?('issuer rule is undecidable'),
       'a carrier without depositor reads unestablished (issuer rule undecidable, refuse-not-degrade) [R2 fix]')

miss = SD.scan_currency(entries: [entries[1]], carrier_entry_hash: carrier, extent: 10)
assert(miss[:scanned_extent] == 10, 'unestablished reports carry scanned_extent too [R2 fix]')

foreign_in = [entries[0], entries[1].merge('depositor' => 'someone-else')]
fi = SD.scan_currency(entries: foreign_in, carrier_entry_hash: carrier, extent: 10)
assert(fi[:status] == 'unretracted' && fi[:note].include?('non-issuer'),
       'a non-issuer targeting entry is disclosed as residue, never silently dropped [R2 fix]')

strpos = [entries[0], entries[1].merge('position' => '8')]
sp = SD.scan_currency(entries: strpos, carrier_entry_hash: carrier, extent: 10)
assert(sp[:status] == 'unretracted' && sp[:note].include?('no decidable position'),
       'a same-issuer retraction without a decidable position is disclosed distinctly, not mislabelled beyond-extent [R2 fix]')

puts '== determinism: same inputs, same bytes (MPR-3 register) =='

again = SD.build_field_commitments(ENDO, salts: SALTS)
assert(again['record'] == AUX, 'field commitments are deterministic given record + salts')
pres2 = SD.build_presentation(record_string: ENDO, aux_string: AUX, salts: SALTS,
                              opened: %w[format], predicate: 'typed-existence')
assert(pres2 == pres, 'presentations are deterministic given the same inputs')

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
