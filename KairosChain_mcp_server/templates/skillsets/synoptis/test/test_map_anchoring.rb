# frozen_string_literal: true

# Design-constraint tests for the AUD-L2 mutual-anchoring slice
# (aud_l2_mutual_anchoring_design v0.5, FROZEN; invariants MAP-1..4).
# Each block names the invariant whose implementable consequence it pins.

require 'json'
require 'digest'
require 'open3'
require 'tmpdir'

anchoring = File.expand_path('../lib/synoptis/anchoring', __dir__)
require File.join(anchoring, 'entry')
require File.join(anchoring, 'chain_credential')
require File.join(anchoring, 'succession')
require File.join(anchoring, 'anchoring_rule')
require File.join(anchoring, 'attestation_types')
require File.join(anchoring, 'log')

Entry = Synoptis::Anchoring::Entry
Cred = Synoptis::Anchoring::ChainCredential
Succ = Synoptis::Anchoring::Succession
Rule = Synoptis::Anchoring::AnchoringRule
AType = Synoptis::Anchoring::AttestationTypes
AnchorLog = Synoptis::Anchoring::Log

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

IDENTITY_A = "block1-sha256:#{'a' * 64}"
IDENTITY_B = "block1-sha256:#{'b' * 64}"
KEY_A = Cred.generate_key
KEY_B = Cred.generate_key
CRED_A = Cred.build(IDENTITY_A, KEY_A)
CRED_B = Cred.build(IDENTITY_B, KEY_B)

puts '== MAP-2: self-authenticating credential =='

assert(Cred.validate!(CRED_A), 'a built credential validates (no registry, no network)')
assert(Cred.credential_digest(CRED_A).match?(/\A[a-f0-9]{64}\z/), 'credential digest is 64-hex')

sig = Cred.sign_attestation(CRED_A, KEY_A, 'payload-1')
assert(Cred.verify_attestation(CRED_A, 'payload-1', sig), 'attestation verifies with credential+payload+signature only')
assert(!Cred.verify_attestation(CRED_A, 'payload-2', sig), 'tampered payload fails verification')
assert(!Cred.verify_attestation(CRED_B, 'payload-1', sig), 'foreign credential fails verification')

assert_raises(Cred::CredentialError, 'signing under a key not matching the credential is refused (issuer-only)') do
  Cred.sign_attestation(CRED_A, KEY_B, 'x')
end

tampered = CRED_A.merge('chain_identity' => IDENTITY_B)
assert_raises(Cred::CredentialError, 'credential with re-pointed identity fails binding_sig check') do
  Cred.validate!(tampered)
end

extra = CRED_A.merge('note' => 'x')
assert_raises(Cred::CredentialError, 'extra field is refused, not coerced (closed field set)') do
  Cred.validate!(extra)
end

puts '== MAP-4 / AHM-4: typed entries, additive only =='

untyped = Entry.anchor(position: 0, prev: nil, digest: 'ab' * 32, anchor_type: 'document',
                       source_id: 's', depositor: 'd', moment: '2026-07-21T00:00:00Z')
assert(!untyped.body.key?('attestation_type'), 'entry without attestation_type carries NO key (byte-identical to pre-map-1)')
assert(untyped.attestation_type.nil?, 'untyped entry reads as nil type (grandfathered)')

typed = Entry.anchor(position: 0, prev: nil, digest: 'ab' * 32, anchor_type: 'chain_head',
                     source_id: 's', depositor: 'd', moment: '2026-07-21T00:00:00Z',
                     attestation_type: 'observation')
assert(typed.attestation_type == 'observation', 'head inscription carries observation type (MAP-1/MAP-4)')
assert(typed.body['attestation_type'] == 'observation', 'attestation_type is committed body content (covered by entry_hash)')
assert(untyped.entry_hash != typed.entry_hash, 'type participates in the committed hash')

reference = Entry.anchor(position: 0, prev: nil, digest: 'ab' * 32, anchor_type: 'document',
                         source_id: 's', depositor: 'd', moment: '2026-07-21T00:00:00Z')
assert(reference.entry_hash == untyped.entry_hash, 'AHM-4: identical pre-map-1 construction yields identical hash after the extension')

puts '== MAP-2: succession governance =='

desig_b = Succ.designation_record(CRED_A, KEY_A, IDENTITY_B, Cred.credential_digest(CRED_B))
retract_b = Succ.retraction_record(CRED_A, KEY_A, desig_b)

v = Succ.governance(CRED_A, [desig_b])
assert(v[:status] == 'governed' && v[:governing][:successor_identity] == IDENTITY_B,
       'a valid designation governs')

v = Succ.governance(CRED_A, [])
assert(v[:status] == 'orphan', 'no designation → orphan (disclosed terminal state)')

v = Succ.governance(CRED_A, [desig_b, retract_b])
assert(v[:status] == 'orphan', 'all designations retracted → orphan')

identity_c = "block1-sha256:#{'c' * 64}"
key_c = Cred.generate_key
cred_c = Cred.build(identity_c, key_c)
desig_c = Succ.designation_record(CRED_A, KEY_A, identity_c, Cred.credential_digest(cred_c))

v = Succ.governance(CRED_A, [desig_b, desig_c])
assert(v[:status] == 'governed' && v[:governing][:successor_identity] == IDENTITY_B,
       'earliest non-retracted designation governs; later competitor does not override')
assert(v[:contested].any? { |c| c[:reason].include?('later non-retracted') },
       'trail-less later competitor is surfaced as contested')

v = Succ.governance(CRED_A, [desig_b, retract_b, desig_c])
assert(v[:status] == 'governed' && v[:governing][:successor_identity] == identity_c,
       'retract-then-redesignate shifts governance pre-changeover (append-visible trail)')
assert(v[:contested].any? { |c| c[:reason].include?('retract-and-redesignate trail') },
       'retracted designation is surfaced in the contested register (MAP-2: one and the same register)')

v = Succ.governance(CRED_A, [desig_b, retract_b, desig_c], changeover_position: 0)
assert(v[:status] == 'governed' && v[:governing][:successor_identity] == IDENTITY_B,
       'post-changeover retraction never alters governance (settled succession cannot be reopened)')
assert(v[:contested].size >= 2, 'post-changeover acts are surfaced as contested')

v = Succ.governance(CRED_A, [desig_b, retract_b], changeover_position: 1)
assert(v[:status] == 'orphan',
       'a retraction AT the changeover position counts (map-1 §4.1 "at or before")')

v = Succ.governance(CRED_A, [desig_b, desig_b, retract_b])
assert(v[:status] == 'orphan',
       'duplicate identical designations share one digest; retraction retracts the claim, not one copy')

sloppy = "  #{desig_b}"
v = Succ.governance(CRED_A, [sloppy])
assert(v[:status] == 'orphan', 'non-canonical serialization is not a succession artifact (ignored as noise)')

assert_raises(Succ::SuccessionError, 'non-integer changeover_position is refused, not coerced') do
  Succ.governance(CRED_A, [desig_b], changeover_position: '1')
end

assert_raises(Succ::SuccessionError, 'designation under a foreign key is refused at build (issuer-only)') do
  Succ.designation_record(CRED_A, KEY_B, IDENTITY_B, Cred.credential_digest(CRED_B))
end

forged = Succ.designation_record(CRED_B, KEY_B, identity_c, Cred.credential_digest(cred_c))
v = Succ.governance(CRED_A, [forged])
assert(v[:status] == 'orphan', 'designation signed by a foreign credential is ignored as noise, never governs')

hostile = ['not json', '{"format":"map-1/succession-designation"}', '42']
v = Succ.governance(CRED_A, hostile)
assert(v[:status] == 'orphan', 'hostile/malformed records yield a verdict, not an exception (diagnostic posture)')

puts '== MAP-4: vocabulary intake and retraction coherence =='

assert(AType.validate_intake!(nil, {}), 'untyped entry passes intake (grandfathered)')
assert(AType.validate_intake!('observation', {}), 'vocabulary type passes intake')
assert_raises(AType::VocabularyError, 'off-vocabulary type refused at intake') do
  AType.validate_intake!('banana', {})
end
assert_raises(AType::VocabularyError, 'retraction without target reference refused') do
  AType.validate_intake!('retraction', {})
end
assert(AType.validate_intake!('retraction', { 'target_entry_hash' => 'a' * 64 }), 'retraction with target passes')
assert_raises(AType::VocabularyError, 'anchor-log retraction targeting an internal-chain record digest is refused (unresolvable on this surface)') do
  AType.validate_intake!('retraction', { 'target_record_sha256' => 'a' * 64 })
end
assert_raises(AType::VocabularyError, 'stray target_record_sha256 alongside a valid target_entry_hash is refused (ONLY target form, map-1 §3)') do
  AType.validate_intake!('retraction', { 'target_entry_hash' => 'a' * 64, 'target_record_sha256' => 'b' * 64 })
end

Dir.mktmpdir do |dir|
  log = AnchorLog.new(storage_path: File.join(dir, 'log.jsonl'), operator_id: 'op')
  typed = log.append_anchor(digest: 'ab' * 32, anchor_type: 'chain_head', source_id: 's',
                            depositor: 'op', attestation_type: 'observation')
  assert(typed.attestation_type == 'observation', 'observation type reachable through the REAL append path (Log#append_anchor)')
  assert_raises(AType::VocabularyError, 'off-vocabulary type refused at the real append path') do
    log.append_anchor(digest: 'ab' * 32, anchor_type: 'document', source_id: 's',
                      depositor: 'op', attestation_type: 'banana')
  end
  target = log.append_anchor(digest: 'cd' * 32, anchor_type: 'document', source_id: 's2', depositor: 'op')
  retraction = log.append_anchor(digest: 'ef' * 32, anchor_type: 'document', source_id: 's3', depositor: 'op',
                                 metadata: { 'target_entry_hash' => target.entry_hash },
                                 attestation_type: 'retraction')
  verdict = AType.retraction_coherence(retraction.to_h, target.to_h)
  assert(verdict[:coherent], 'same-depositor retraction with matching target is coherent (map-1 §3)')
  foreign = Entry.anchor(position: 99, prev: nil, digest: 'ab' * 32, anchor_type: 'document',
                         source_id: 's4', depositor: 'someone-else', moment: '2026-07-21T00:00:00Z',
                         metadata: { 'target_entry_hash' => target.entry_hash },
                         attestation_type: 'retraction')
  verdict = AType.retraction_coherence(foreign.to_h, target.to_h)
  assert(!verdict[:coherent] && verdict[:mismatches].any? { |m| m.include?('depositor') },
         'foreign-depositor retraction is incoherent (issuer-only at map-1 = depositor equality)')
  second = log.append_anchor(digest: '11' * 32, anchor_type: 'document', source_id: 's5', depositor: 'op',
                             metadata: { 'target_entry_hash' => retraction.entry_hash },
                             attestation_type: 'retraction')
  verdict = AType.retraction_coherence(second.to_h, retraction.to_h)
  assert(!verdict[:coherent] && verdict[:mismatches].any? { |m| m.include?('retraction of a retraction') },
         'retraction of a retraction is not recognized (map-1 §3)')
end

puts '== MAP-3: declared anchoring rule =='

rule = Rule.build('every_n_records', 10)
assert(Rule.parse!(rule)['n'] == 10, 'built rule parses back')
assert(JSON.parse(Rule.commitment_record(rule))['rule_digest'] == Digest::SHA256.hexdigest(rule),
       'rule commitment carries the rule digest (decidable anteriority, MPR-8)')

assert_raises(Rule::RuleError, 'outcome-referencing field is unrepresentable (closed schema, result-free by construction)') do
  Rule.parse!('{"format":"map-1/anchoring-rule","n":5,"trigger":"every_n_records","on_success":true}')
end
assert_raises(Rule::RuleError, 'unknown trigger refused') { Rule.build('on_green_tests', 5) }

report = Rule.coverage(rule, [{ 'tree_size' => 12 }, { 'tree_size' => 31 }], chain_extent: 40, rule_position: 0)
assert(report[:conforms], 'rule conforms regardless of coverage (MAP-3: adequacy priced, not legislated)')
assert(report[:expected] == [10, 20, 30, 40], 'expected anchor points derived from rule + extent')
assert(report[:gaps] == [20, 40], 'gaps are visible in the report (cost of sparseness)')

vacuous = Rule.build('every_n_records', 1_000_000)
report = Rule.coverage(vacuous, [], chain_extent: 500, rule_position: 0)
assert(report[:conforms] && report[:expected].empty?, 'vacuous rule conforms; its (empty) expectation is visible')

assert_raises(Rule::RuleError, 'non-canonical rule serialization refused (one rule, one digest)') do
  Rule.parse!('{"trigger":"every_n_records","n":10,"format":"map-1/anchoring-rule"}')
end
assert_raises(Rule::RuleError, 'non-integer chain_extent refused, not coerced') do
  Rule.coverage(rule, [], chain_extent: 'abc', rule_position: 0)
end

daily = Rule.build('every_n_days', 2)
report = Rule.coverage(daily, [{ 'moment' => '2026-07-03T10:00:00Z' }],
                       rule_moment: '2026-07-01T00:00:00Z', now: '2026-07-07T00:00:00Z')
assert(report[:expected].size == 3, 'every_n_days expected boundaries derived from rule_moment..now')
assert(report[:matched].size == 1 && report[:gaps].size == 2,
       'every_n_days matches an anchor within its window and shows the gaps')

assert_raises(Cred::CredentialError, 'non-String attestation payload refused (byte strings only)') do
  Cred.sign_attestation(CRED_A, KEY_A, { a: 1 })
end

puts '== MAP-1: offline pair verification (bin/map_verify.rb) =='

require 'tmpdir'
Dir.mktmpdir do |dir|
  binding_for = lambda do |identity|
    { 'convention' => 'khab-1', 'convention_sha256' => 'c' * 64, 'chain_identity' => identity,
      'cumulative_root' => 'd' * 64, 'tree_size' => 3, 'chain_head_index' => 1, 'chain_head_hash' => 'e' * 64 }
  end
  entry_ab = Entry.anchor(position: 4, prev: 'f' * 64, digest: 'd' * 64, anchor_type: 'chain_head',
                          source_id: 'sa', depositor: 'b-operator', moment: '2026-07-21T00:00:00Z',
                          head_binding: binding_for.call(IDENTITY_B), attestation_type: 'observation')
  entry_ba = Entry.anchor(position: 7, prev: '9' * 64, digest: 'd' * 64, anchor_type: 'chain_head',
                          source_id: 'sb', depositor: 'a-operator', moment: '2026-07-21T00:00:00Z',
                          head_binding: binding_for.call(IDENTITY_A))
  log_a = File.join(dir, 'log_a.json')
  log_b = File.join(dir, 'log_b.json')
  File.write(log_a, JSON.generate([entry_ab.to_h]))
  File.write(log_b, JSON.generate([entry_ba.to_h]))

  bin = File.expand_path('../bin/map_verify.rb', __dir__)
  out, _err, status = Open3.capture3('ruby', bin, 'pair', log_a, IDENTITY_A, log_b, IDENTITY_B)
  assert(status.exitstatus.zero?, 'pair report succeeds on a mutual pair')
  assert(out.include?('PAIR ESTABLISHED'), 'report states what the pair establishes')
  assert(out.include?('closes nothing'), 'report carries the MAP-1 conditions, never asserts stronger readings')
  assert(out.include?('grandfathered'), 'untyped inscription is surfaced as pre-map-1, not rejected')

  out, _err, status = Open3.capture3('ruby', bin, 'pair', log_a, IDENTITY_A, log_a, IDENTITY_B)
  assert(status.exitstatus == 1, 'one-sided relationship is rejected as a pair (unilateral anchor is legitimate but not mutual)')

  # credential + attestation subcommands, standalone
  cred_path = File.join(dir, 'cred.json')
  File.write(cred_path, JSON.generate(CRED_A))
  out, _err, status = Open3.capture3('ruby', bin, 'credential', cred_path)
  assert(status.exitstatus.zero? && out.include?('VERIFIED'), 'credential verifies offline')
  assert(out.include?('SELF-attestation'), 'credential report discloses the self-attestation limit')

  payload_path = File.join(dir, 'payload.bin')
  File.write(payload_path, 'payload-1')
  out, _err, status = Open3.capture3('ruby', bin, 'attestation', cred_path, payload_path, sig)
  assert(status.exitstatus.zero?, 'attestation verifies offline with credential+payload+signature only')

  records_path = File.join(dir, 'records.json')
  File.write(records_path, JSON.generate([desig_b, retract_b, desig_c]))
  out, _err, status = Open3.capture3('ruby', bin, 'succession', cred_path, records_path)
  assert(status.exitstatus.zero? && out.include?('"status": "governed"'), 'succession verdict runs offline')
  out, _err, status = Open3.capture3('ruby', bin, 'succession', cred_path, records_path, '0')
  assert(out.include?(IDENTITY_B), 'changeover position freezes governance at the settled successor')

  bad_records = File.join(dir, 'bad_records.json')
  File.write(bad_records, JSON.generate([{ 'format' => 'x' }]))
  _out, _err, status = Open3.capture3('ruby', bin, 'succession', cred_path, bad_records)
  assert(status.exitstatus == 2, 'records that are not strings are unresolvable input (exit 2)')

  rule_path = File.join(dir, 'rule.json')
  File.write(rule_path, Rule.build('every_n_records', 10))
  anchors_path = File.join(dir, 'anchors.json')
  File.write(anchors_path, JSON.generate([{ 'tree_size' => 12 }]))
  _out, _err, status = Open3.capture3('ruby', bin, 'coverage', rule_path, anchors_path, 'abc', '0')
  assert(status.exitstatus == 2, 'garbage numeric CLI argument is unresolvable (exit 2), never a covered report')

  daily_path = File.join(dir, 'daily_rule.json')
  File.write(daily_path, Rule.build('every_n_days', 2))
  moments_path = File.join(dir, 'moments.json')
  File.write(moments_path, JSON.generate([{ 'moment' => '2026-07-03T10:00:00Z' }]))
  _out, _err, status = Open3.capture3('ruby', bin, 'coverage', daily_path, moments_path)
  assert(status.exitstatus == 2, 'every_n_days without rule_moment/now is a usage gap (exit 2), not REJECTED')
  out, _err, status = Open3.capture3('ruby', bin, 'coverage', daily_path, moments_path,
                                     '0', '0', '2026-07-01T00:00:00Z', '2026-07-07T00:00:00Z')
  assert(status.exitstatus.zero? && out.include?('"gaps"'), 'every_n_days coverage IS verifiable offline via CLI')

  forged_log = File.join(dir, 'forged.json')
  tampered = entry_ab.to_h
  tampered['body'] = tampered['body'].merge('depositor' => 'evil')
  File.write(forged_log, JSON.generate([tampered]))
  _out, _err, status = Open3.capture3('ruby', bin, 'pair', forged_log, IDENTITY_A, log_b, IDENTITY_B)
  assert(status.exitstatus == 1, 'in-place edited entry (hash mismatch) is REJECTED by pair, not established')

  malformed_binding_log = File.join(dir, 'malformed.json')
  bad = binding_for.call(IDENTITY_B).merge('convention' => 'not-khab', 'tree_size' => 'three')
  bad_entry = Entry.anchor(position: 0, prev: nil, digest: 'd' * 64, anchor_type: 'chain_head',
                           source_id: 's', depositor: 'x', moment: '2026-07-21T00:00:00Z',
                           head_binding: bad)
  File.write(malformed_binding_log, JSON.generate([bad_entry.to_h]))
  _out, _err, status = Open3.capture3('ruby', bin, 'pair', malformed_binding_log, IDENTITY_A, log_b, IDENTITY_B)
  assert(status.exitstatus == 2, 'malformed binding shape is unresolvable input (exit 2), never PAIR ESTABLISHED')

  ret_log_path = File.join(dir, 'ret_log.json')
  t_entry = Entry.anchor(position: 0, prev: nil, digest: 'ab' * 32, anchor_type: 'document',
                         source_id: 's', depositor: 'op', moment: '2026-07-21T00:00:00Z')
  r_entry = Entry.anchor(position: 1, prev: t_entry.entry_hash, digest: 'cd' * 32, anchor_type: 'document',
                         source_id: 's2', depositor: 'op', moment: '2026-07-21T00:00:00Z',
                         metadata: { 'target_entry_hash' => t_entry.entry_hash },
                         attestation_type: 'retraction')
  File.write(ret_log_path, JSON.generate([t_entry.to_h, r_entry.to_h]))
  out, _err, status = Open3.capture3('ruby', bin, 'retraction', ret_log_path, r_entry.entry_hash)
  assert(status.exitstatus.zero? && out.include?('"coherent": true'), 'retraction coherence verifiable offline via CLI')
end

puts '== map-1 convention pinning =='

map1 = File.expand_path('../lib/synoptis/anchoring/conventions/map-1.md', __dir__)
assert(File.exist?(map1), 'map-1.md convention definition ships with the skillset')
assert(Cred.convention_sha256 == Digest::SHA256.hexdigest(File.binread(map1)),
       'credential module pins the shipped map-1 definition by digest (MPR-3 pattern)')
khab1 = File.expand_path('../lib/synoptis/anchoring/conventions/khab-1.md', __dir__)
assert(File.exist?(khab1), 'khab-1.md untouched in place (map-1 builds on, never edits)')

puts "\n== Result =="
puts "PASS: #{$pass}, FAIL: #{$fail}"
exit($fail.zero? ? 0 : 1)
