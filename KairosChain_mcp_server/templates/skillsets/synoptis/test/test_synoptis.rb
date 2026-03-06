# frozen_string_literal: true

require 'tmpdir'
require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'
require 'time'

# Locate project root from this test file (.kairos/skillsets/synoptis/test/)
project_root = File.expand_path('../../../..', __dir__)
mcp_server = File.join(project_root, 'KairosChain_mcp_server')

# Load MMP dependencies from the project templates
mmp_lib = File.join(mcp_server, 'templates', 'skillsets', 'mmp', 'lib')
$LOAD_PATH.unshift(mmp_lib) unless $LOAD_PATH.include?(mmp_lib)

# Load Synoptis
synoptis_lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(synoptis_lib) unless $LOAD_PATH.include?(synoptis_lib)

# MMP requires
require 'mmp/protocol'
require 'mmp/identity'
require 'mmp/crypto'
require 'mmp/protocol_loader'
require 'mmp/protocol_evolution'
require 'mmp/compatibility'
require 'mmp/peer_manager'

# MMP module-level config helper
module MMP
  VERSION = '1.0.0' unless defined?(VERSION)
  def self.load_config
    {}
  end
end

require 'synoptis'

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

def section(title)
  puts "\n#{'=' * 60}"
  puts "SECTION: #{title}"
  puts '=' * 60
end

# ============================================================
section '1. ProofEnvelope'
# ============================================================

env1 = Synoptis::ProofEnvelope.new(
  attester_id: 'agent-abc123',
  subject_ref: 'knowledge/test_skill',
  claim: 'integrity_verified',
  evidence: 'sha256:deadbeef',
  ttl: 3600
)

assert env1.proof_id.is_a?(String), 'proof_id is generated'
assert env1.attester_id == 'agent-abc123', 'attester_id preserved'
assert env1.subject_ref == 'knowledge/test_skill', 'subject_ref preserved'
assert env1.claim == 'integrity_verified', 'claim preserved'
assert env1.evidence == 'sha256:deadbeef', 'evidence preserved'
assert env1.ttl == 3600, 'ttl preserved'
assert env1.timestamp.is_a?(String), 'timestamp generated'
assert env1.version == '1.0.0', 'version defaulted'

# S-C1 fix: canonical_json retains nil values
env_nil = Synoptis::ProofEnvelope.new(
  attester_id: 'agent-x',
  subject_ref: 'ref-1',
  claim: 'test'
)
canonical = JSON.parse(env_nil.canonical_json)
assert canonical.key?('evidence'), 'S-C1: canonical_json includes nil evidence key'
assert canonical['evidence'].nil?, 'S-C1: nil evidence is JSON null, not omitted'
assert canonical.key?('merkle_root'), 'S-C1: canonical_json includes nil merkle_root key'

# content_hash is deterministic
hash1 = env1.content_hash
hash2 = env1.content_hash
assert hash1 == hash2, 'content_hash is deterministic'

# expired?
env_expired = Synoptis::ProofEnvelope.new(
  attester_id: 'a', subject_ref: 's', claim: 'c',
  ttl: -1, timestamp: (Time.now.utc - 10).iso8601
)
assert env_expired.expired?, 'expired envelope detected'
assert !env1.expired?, 'non-expired envelope detected'

# from_h round-trip
h = env1.to_h
env_restored = Synoptis::ProofEnvelope.from_h(h)
assert env_restored.proof_id == env1.proof_id, 'from_h preserves proof_id'
assert env_restored.attester_id == env1.attester_id, 'from_h preserves attester_id'
assert env_restored.content_hash == env1.content_hash, 'from_h preserves content_hash'

# ============================================================
section '2. Verifier'
# ============================================================

verifier_strict = Synoptis::Verifier.new(config: { require_signature: true })
verifier_lenient = Synoptis::Verifier.new(config: { require_signature: false })

# Valid envelope without signature (strict mode should fail)
result_strict = verifier_strict.verify(env1)
assert !result_strict[:valid], 'S-C5: strict verifier rejects unsigned proof'
assert result_strict[:errors].include?('missing_signature'), 'S-C5: error includes missing_signature'

# Valid envelope without signature (lenient mode)
result_lenient = verifier_lenient.verify(env1)
assert result_lenient[:valid], 'lenient verifier accepts unsigned proof'

# Missing fields
env_bad = Synoptis::ProofEnvelope.new({})
result_bad = verifier_lenient.verify(env_bad)
assert !result_bad[:valid], 'rejects envelope with missing fields'
assert result_bad[:errors].include?('missing_attester_id'), 'detects missing_attester_id'
assert result_bad[:errors].include?('missing_subject_ref'), 'detects missing_subject_ref'
assert result_bad[:errors].include?('missing_claim'), 'detects missing_claim'

# Expired envelope
result_exp = verifier_lenient.verify(env_expired)
assert !result_exp[:valid], 'rejects expired envelope'
assert result_exp[:errors].include?('expired'), 'detects expired'

# ============================================================
section '3. FileRegistry with hash chaining'
# ============================================================

Dir.mktmpdir('synoptis_test') do |tmpdir|
  registry = Synoptis::Registry::FileRegistry.new(data_dir: tmpdir)

  # Store proofs
  e1 = Synoptis::ProofEnvelope.new(
    attester_id: 'agent-1', subject_ref: 'ref-1', claim: 'claim-1', ttl: 3600
  )
  e2 = Synoptis::ProofEnvelope.new(
    attester_id: 'agent-2', subject_ref: 'ref-1', claim: 'claim-2', ttl: 3600
  )

  id1 = registry.store_proof(e1)
  id2 = registry.store_proof(e2)

  assert id1 == e1.proof_id, 'store_proof returns proof_id'
  assert id2 == e2.proof_id, 'store_proof returns second proof_id'

  # Find proof
  found = registry.find_proof(id1)
  assert found.is_a?(Synoptis::ProofEnvelope), 'find_proof returns ProofEnvelope'
  assert found.attester_id == 'agent-1', 'find_proof finds correct proof'

  # List proofs
  all = registry.list_proofs
  assert all.size == 2, 'list_proofs returns all proofs'

  filtered = registry.list_proofs(filter: { attester_id: 'agent-1' })
  assert filtered.size == 1, 'list_proofs filter works'

  # Hash chain verification (PHIL-C1)
  chain_status = registry.verify_chain(:proofs)
  assert chain_status[:valid], 'PHIL-C1: proof chain is valid'
  assert chain_status[:length] == 2, 'PHIL-C1: chain length is 2'

  # Verify chain contains prev_entry_hash
  lines = File.readlines(File.join(tmpdir, 'proofs.jsonl'))
  first_record = JSON.parse(lines[0])
  second_record = JSON.parse(lines[1])
  assert first_record['_prev_entry_hash'].nil?, 'first entry has nil prev_entry_hash'
  assert second_record['_prev_entry_hash'].is_a?(String), 'second entry has prev_entry_hash'
  expected_hash = Digest::SHA256.hexdigest(JSON.generate(JSON.parse(lines[0], symbolize_names: true), sort_keys: true))
  assert second_record['_prev_entry_hash'] == expected_hash, 'PHIL-C1: hash chain links correctly'

  # Revocations
  registry.store_revocation({ proof_id: id1, revoker_id: 'agent-1', reason: 'test' })
  assert registry.revoked?(id1), 'revoked proof detected'
  assert !registry.revoked?(id2), 'non-revoked proof not detected'

  rev_chain = registry.verify_chain(:revocations)
  assert rev_chain[:valid], 'revocation chain is valid'

  # Challenges
  challenge = { challenge_id: 'ch-1', proof_id: id2, status: 'pending' }
  registry.store_challenge(challenge)
  found_ch = registry.find_challenge('ch-1')
  assert found_ch[:challenge_id] == 'ch-1', 'find_challenge works'

  ch_chain = registry.verify_chain(:challenges)
  assert ch_chain[:valid], 'challenge chain is valid'
end

# ============================================================
section '4. AttestationEngine'
# ============================================================

Dir.mktmpdir('synoptis_engine_test') do |tmpdir|
  registry = Synoptis::Registry::FileRegistry.new(data_dir: tmpdir)
  engine = Synoptis::AttestationEngine.new(
    registry: registry,
    config: { 'default_ttl' => 3600, 'require_signature' => false }
  )

  # Create attestation
  result = engine.create_attestation(
    attester_id: 'agent-test',
    subject_ref: 'knowledge/my_skill',
    claim: 'integrity_verified',
    evidence: 'sha256:abc',
    actor_user_id: 'masa',
    actor_role: 'owner'
  )
  assert result[:status] == 'created', 'create_attestation succeeds'
  assert result[:proof_id].is_a?(String), 'returns proof_id'
  assert result[:envelope][:actor_user_id] == 'masa', 'audit: actor_user_id recorded'
  assert result[:envelope][:actor_role] == 'owner', 'audit: actor_role recorded'

  proof_id = result[:proof_id]

  # S-C4: Duplicate detection
  dup_result = engine.create_attestation(
    attester_id: 'agent-test',
    subject_ref: 'knowledge/my_skill',
    claim: 'integrity_verified'
  )
  assert dup_result[:status] == 'error', 'S-C4: duplicate attestation rejected'
  assert dup_result[:existing_proof_id] == proof_id, 'S-C4: references existing proof'

  # Verify attestation
  verify_result = engine.verify_attestation(proof_id)
  assert verify_result[:valid], 'verify_attestation succeeds (lenient mode)'

  # List attestations
  list_result = engine.list_attestations
  assert list_result.size == 1, 'list_attestations returns 1'
  assert list_result.first[:attester_id] == 'agent-test', 'list includes correct attester'

  # Verify non-existent
  missing = engine.verify_attestation('nonexistent-id')
  assert missing[:status] == 'error', 'verify non-existent returns error'
end

# ============================================================
section '5. RevocationManager'
# ============================================================

Dir.mktmpdir('synoptis_revoke_test') do |tmpdir|
  registry = Synoptis::Registry::FileRegistry.new(data_dir: tmpdir)
  engine = Synoptis::AttestationEngine.new(
    registry: registry, config: { 'require_signature' => false }
  )
  revoker = Synoptis::RevocationManager.new(registry: registry)

  result = engine.create_attestation(
    attester_id: 'agent-a', subject_ref: 'ref-x', claim: 'test-claim'
  )
  proof_id = result[:proof_id]

  # Unauthorized revocation
  unauth = revoker.revoke(
    proof_id: proof_id, reason: 'test', revoker_id: 'agent-b'
  )
  assert unauth[:status] == 'error', 'unauthorized revocation rejected'

  # Admin can revoke
  admin_revoke = revoker.revoke(
    proof_id: proof_id, reason: 'admin action', revoker_id: 'agent-b',
    actor_user_id: 'admin_user', actor_role: 'admin'
  )
  assert admin_revoke[:status] == 'revoked', 'admin can revoke any proof'
  assert admin_revoke[:revocation][:actor_user_id] == 'admin_user', 'audit: admin user recorded'

  # Double revocation
  double = revoker.revoke(
    proof_id: proof_id, reason: 'again', revoker_id: 'agent-a'
  )
  assert double[:status] == 'error', 'double revocation rejected'

  # Verify shows revoked
  verify = engine.verify_attestation(proof_id)
  assert verify[:status] == 'revoked', 'verify returns revoked status'
end

# ============================================================
section '6. ChallengeManager'
# ============================================================

Dir.mktmpdir('synoptis_challenge_test') do |tmpdir|
  registry = Synoptis::Registry::FileRegistry.new(data_dir: tmpdir)
  engine = Synoptis::AttestationEngine.new(
    registry: registry, config: { 'require_signature' => false }
  )
  cm = Synoptis::ChallengeManager.new(
    registry: registry, config: { 'max_active_per_subject' => 2 }
  )

  result = engine.create_attestation(
    attester_id: 'agent-att', subject_ref: 'ref-ch', claim: 'claim-ch'
  )
  proof_id = result[:proof_id]

  # Create challenge
  ch1 = cm.create_challenge(
    proof_id: proof_id, challenger_id: 'agent-challenger',
    challenge_type: 'validity', details: 'Suspicious claim'
  )
  assert ch1[:status] == 'created', 'create_challenge succeeds'
  assert ch1[:challenge][:challenge_id].is_a?(String), 'challenge_id generated'
  challenge_id = ch1[:challenge][:challenge_id]

  # Unauthorized response
  bad_resp = cm.respond_to_challenge(
    challenge_id: challenge_id, responder_id: 'agent-wrong',
    response: 'I am not the attester'
  )
  assert bad_resp[:status] == 'error', 'unauthorized responder rejected'

  # Authorized response
  good_resp = cm.respond_to_challenge(
    challenge_id: challenge_id, responder_id: 'agent-att',
    response: 'Evidence provided', evidence: 'proof-of-work'
  )
  assert good_resp[:status] == 'responded', 'authorized respond succeeds'

  # Max active challenges
  ch2 = cm.create_challenge(
    proof_id: proof_id, challenger_id: 'c2', challenge_type: 'validity'
  )
  ch3 = cm.create_challenge(
    proof_id: proof_id, challenger_id: 'c3', challenge_type: 'validity'
  )
  assert ch2[:status] == 'created', 'second challenge allowed'
  assert ch3[:status] == 'created', 'third challenge allowed (first was responded, not pending)'

  # Challenge against non-existent proof
  bad_ch = cm.create_challenge(
    proof_id: 'nonexistent', challenger_id: 'x', challenge_type: 'validity'
  )
  assert bad_ch[:status] == 'error', 'challenge against non-existent proof rejected'
end

# ============================================================
section '7. TrustScorer'
# ============================================================

Dir.mktmpdir('synoptis_trust_test') do |tmpdir|
  registry = Synoptis::Registry::FileRegistry.new(data_dir: tmpdir)
  engine = Synoptis::AttestationEngine.new(
    registry: registry, config: { 'require_signature' => false }
  )
  scorer = Synoptis::TrustScorer.new(registry: registry)

  # Empty subject
  empty_score = scorer.calculate('no-attestations')
  assert empty_score[:score] == 0.0, 'empty subject has 0 trust score'

  # Add attestations
  engine.create_attestation(
    attester_id: 'agent-1', subject_ref: 'ref-scored', claim: 'claim-a',
    evidence: 'some-evidence'
  )
  engine.create_attestation(
    attester_id: 'agent-2', subject_ref: 'ref-scored', claim: 'claim-b',
    evidence: 'other-evidence'
  )

  score = scorer.calculate('ref-scored')
  assert score[:score] > 0.0, 'scored subject has positive trust'
  assert score[:attestation_count] == 2, 'attestation_count is 2'
  assert score[:active_count] == 2, 'active_count is 2'
  assert score[:details].key?(:quality), 'details include quality'
  assert score[:details].key?(:freshness), 'details include freshness'
  assert score[:details].key?(:diversity), 'details include diversity'
end

# ============================================================
section '8. MMP Protocol register_handler integration'
# ============================================================

MMP::Protocol.clear_extended_handlers!

# Register
assert MMP::Protocol.extended_actions.empty?, 'starts with no extended actions'

Synoptis.load!
assert Synoptis.loaded?, 'Synoptis loads successfully'

registered = MMP::Protocol.extended_actions
assert registered.include?('attestation_request'), 'attestation_request registered'
assert registered.include?('attestation_response'), 'attestation_response registered'
assert registered.include?('attestation_revoke'), 'attestation_revoke registered'
assert registered.include?('challenge_create'), 'challenge_create registered'
assert registered.include?('challenge_respond'), 'challenge_respond registered'
assert registered.size == 5, '5 Synoptis actions registered'

# Override protection
begin
  MMP::Protocol.register_handler('introduce') { |_m, _p| {} }
  assert false, 'should raise on built-in override'
rescue ArgumentError => e
  assert e.message.include?('Cannot override'), 'guard rejects built-in action override'
end

# Handler execution via process_message
identity = MMP::Identity.new(workspace_root: Dir.tmpdir, config: {
  'enabled' => true,
  'identity' => { 'name' => 'Test' }
})
protocol = MMP::Protocol.new(identity: identity)

msg = { 'action' => 'attestation_request', 'from' => 'peer-1', 'payload' => {} }
result = protocol.process_message(msg)
assert result[:status] == 'received', 'handler processes attestation_request'
assert result[:action] == 'attestation_request', 'handler returns correct action'

# Unknown extended action
unknown_msg = { 'action' => 'nonexistent_action', 'from' => 'peer-1' }
unknown_result = protocol.process_message(unknown_msg)
assert unknown_result[:status] == 'error', 'unknown action returns error'

# Unload
Synoptis.unload!
assert !Synoptis.loaded?, 'Synoptis unloads successfully'
assert MMP::Protocol.extended_actions.empty?, 'handlers unregistered after unload'

# ============================================================
section '9. Transport availability checks'
# ============================================================

mmp_transport = Synoptis::Transport::MMPTransport.new
assert mmp_transport.available?, 'MMP transport available (MMP loaded)'

hestia_transport = Synoptis::Transport::HestiaTransport.new
assert !hestia_transport.available?, 'Hestia transport not available (not loaded)'

local_transport = Synoptis::Transport::LocalTransport.new
assert !local_transport.available?, 'Local transport not available (not loaded)'

# ============================================================
puts "\n#{'=' * 60}"
puts "FINAL RESULTS: #{$pass} passed, #{$fail} failed"
puts '=' * 60

exit(1) if $fail > 0
