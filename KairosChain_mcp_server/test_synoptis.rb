#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Synoptis SkillSet (Phase 0 + Phase 1 + Phase 2 + Phase 3 + Phase 4)
# Usage: ruby test_synoptis.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/synoptis/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/mmp/lib', __dir__)

require 'json'
require 'tmpdir'
require 'fileutils'
require 'openssl'
require 'base64'
require 'digest'

# Load MMP::Crypto for signing
require 'mmp'

# Load Synoptis
require 'synoptis'

$pass_count = 0
$fail_count = 0

def assert(msg)
  result = yield
  if result
    puts "  PASS: #{msg}"
    $pass_count += 1
  else
    puts "  FAIL: #{msg}"
    $fail_count += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail_count += 1
end

def separator
  puts '-' * 60
end

def test_section(title)
  separator
  puts "TEST: #{title}"
  separator
  yield
rescue StandardError => e
  puts "  ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  $fail_count += 1
end

puts "Synoptis SkillSet Test Suite"
puts "Ruby version: #{RUBY_VERSION}"
puts

# ===== Phase 0: SkillSet Skeleton =====

test_section('SkillSet manifest loading') do
  manifest_path = File.expand_path('templates/skillsets/synoptis/skillset.json', __dir__)
  assert('skillset.json exists') { File.exist?(manifest_path) }

  manifest = JSON.parse(File.read(manifest_path))
  assert('name is synoptis') { manifest['name'] == 'synoptis' }
  assert('version is 0.1.0') { manifest['version'] == '0.1.0' }
  assert('layer is L1') { manifest['layer'] == 'L1' }
  assert('depends_on is empty') { manifest['depends_on'] == [] }
  assert('has 8 tool_classes') { manifest['tool_classes'].size == 8 }
  assert('provides mutual_attestation') { manifest['provides'].include?('mutual_attestation') }
end

test_section('Synoptis module loading') do
  assert('Synoptis module defined') { defined?(Synoptis) }
  assert('VERSION is 0.1.0') { Synoptis::VERSION == '0.1.0' }
  assert('SKILLSET_ROOT is set') { Synoptis::SKILLSET_ROOT.include?('synoptis') }
  assert('default_config returns hash') { Synoptis.default_config.is_a?(Hash) }
  assert('default enabled is false') { Synoptis.default_config['enabled'] == false }
  assert('default storage backend is file') { Synoptis.default_config.dig('storage', 'backend') == 'file' }
end

test_section('ClaimTypes') do
  assert('CLAIM_TYPES defined') { Synoptis::ClaimTypes::CLAIM_TYPES.is_a?(Hash) }
  assert('has 7 claim types') { Synoptis::ClaimTypes::CLAIM_TYPES.size == 7 }
  assert('PIPELINE_EXECUTION weight is 1.0') { Synoptis::ClaimTypes.weight_for('PIPELINE_EXECUTION') == 1.0 }
  assert('OBSERVATION_CONFIRM weight is 0.2') { Synoptis::ClaimTypes.weight_for('OBSERVATION_CONFIRM') == 0.2 }
  assert('valid_claim_type? works for valid') { Synoptis::ClaimTypes.valid_claim_type?('SKILL_QUALITY') }
  assert('valid_claim_type? works for invalid') { !Synoptis::ClaimTypes.valid_claim_type?('FAKE_TYPE') }
  assert('DISCLOSURE_LEVELS has existence_only') { Synoptis::ClaimTypes::DISCLOSURE_LEVELS.key?('existence_only') }
  assert('DISCLOSURE_LEVELS has full') { Synoptis::ClaimTypes::DISCLOSURE_LEVELS.key?('full') }
end

test_section('Synoptis.load! and hooks') do
  assert('load! responds') { Synoptis.respond_to?(:load!) }

  # Stub load_config to enable Synoptis for testing
  original_method = Synoptis.method(:load_config)
  Synoptis.define_singleton_method(:load_config) do
    config = original_method.call
    config['enabled'] = true
    config
  end

  # Load Synoptis (registers MMP actions via hooks/mmp_hooks.rb)
  Synoptis.load!

  # Restore original
  Synoptis.define_singleton_method(:load_config, original_method)

  assert('Hooks module defined') { defined?(Synoptis::Hooks) }
  assert('ATTESTATION_ACTIONS constant') { Synoptis::Hooks::ATTESTATION_ACTIONS.is_a?(Array) && Synoptis::Hooks::ATTESTATION_ACTIONS.size == 7 }
  assert('register_actions responds') { MMP::Protocol.respond_to?(:register_actions) }
  assert('extended_actions responds') { MMP::Protocol.respond_to?(:extended_actions) }
  assert('attestation_request registered') { MMP::Protocol.extended_actions.include?('attestation_request') }
  assert('attestation_proof registered') { MMP::Protocol.extended_actions.include?('attestation_proof') }
  assert('attestation_revoke registered') { MMP::Protocol.extended_actions.include?('attestation_revoke') }
end

test_section('Synoptis.load! disabled') do
  # With default config (enabled: false), load! should skip hooks
  # Hooks are already loaded from the previous test, so we test the return behavior
  assert('load! returns nil when disabled') { Synoptis.load!.nil? }
end

# ===== Phase 1: Attestation Engine MVP =====

# Setup crypto for testing
crypto_attester = MMP::Crypto.new
crypto_attestee = MMP::Crypto.new

test_section('ProofEnvelope creation and signing') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    disclosure_level: 'full',
    attester_id: 'agent_alpha',
    attestee_id: 'agent_beta',
    subject_ref: 'skill:fastqc_v1',
    target_hash: "sha256:#{Digest::SHA256.hexdigest('skill:fastqc_v1')}",
    evidence_hash: "sha256:#{Digest::SHA256.hexdigest('test_evidence')}",
    evidence: { quality: 'good', score: 0.95 },
    transport: 'mmp_direct'
  )

  assert('proof_id starts with att_') { proof.proof_id.start_with?('att_') }
  assert('status is active') { proof.status == 'active' }
  assert('nonce is set') { !proof.nonce.nil? && proof.nonce.length == 32 }

  # Canonical JSON
  cj = proof.canonical_json
  assert('canonical_json is valid JSON') { JSON.parse(cj).is_a?(Hash) }
  parsed = JSON.parse(cj)
  assert('canonical_json keys are sorted') { parsed.keys == parsed.keys.sort }
  assert('canonical_json excludes evidence') { !parsed.key?('evidence') }

  # Sign
  proof.sign!(crypto_attester)
  assert('signature is set after sign!') { !proof.signature.nil? }
  assert('fingerprint is set after sign!') { !proof.attester_pubkey_fingerprint.nil? }

  # Verify signature
  assert('valid_signature? with crypto') { proof.valid_signature?(crypto_attester) }
  assert('valid_signature? with PEM') { proof.valid_signature?(crypto_attester.export_public_key) }
  assert('invalid_signature? with wrong key') { !proof.valid_signature?(crypto_attestee) }
end

test_section('ProofEnvelope serialization round-trip') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'DATA_INTEGRITY',
    attester_id: 'agent_a',
    attestee_id: 'agent_b',
    subject_ref: 'chain:main',
    target_hash: "sha256:#{Digest::SHA256.hexdigest('chain:main')}",
    evidence_hash: "sha256:#{Digest::SHA256.hexdigest('integrity_ok')}"
  )
  proof.sign!(crypto_attester)

  # to_h -> from_h round-trip
  hash = proof.to_h
  restored = Synoptis::ProofEnvelope.from_h(hash)

  assert('proof_id preserved') { restored.proof_id == proof.proof_id }
  assert('claim_type preserved') { restored.claim_type == proof.claim_type }
  assert('signature preserved') { restored.signature == proof.signature }
  assert('nonce preserved') { restored.nonce == proof.nonce }

  # JSON round-trip
  json = proof.to_json
  hash2 = JSON.parse(json, symbolize_names: true)
  restored2 = Synoptis::ProofEnvelope.from_h(hash2)
  assert('JSON round-trip preserves proof_id') { restored2.proof_id == proof.proof_id }
end

test_section('ProofEnvelope expiry and status') do
  # Expired proof
  expired_proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
    expires_at: (Time.now.utc - 86400).iso8601
  )
  assert('expired? returns true for past expiry') { expired_proof.expired? }
  assert('active? returns false for expired') { !expired_proof.active? }

  # Active proof
  active_proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
    expires_at: (Time.now.utc + 86400 * 180).iso8601
  )
  assert('expired? returns false for future expiry') { !active_proof.expired? }
  assert('active? returns true') { active_proof.active? }

  # Revoked proof
  revoked_proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
    status: 'revoked'
  )
  assert('revoked? returns true') { revoked_proof.revoked? }
  assert('active? returns false for revoked') { !revoked_proof.active? }
end

test_section('MerkleTree construction and verification') do
  leaves = %w[alpha beta gamma delta]
  tree = Synoptis::MerkleTree.new(leaves)

  assert('root is a hex string') { tree.root.match?(/\A[0-9a-f]{64}\z/) }
  assert('root is deterministic') { tree.root == Synoptis::MerkleTree.new(leaves).root }

  # Different leaves -> different root
  tree2 = Synoptis::MerkleTree.new(%w[alpha beta gamma epsilon])
  assert('different leaves -> different root') { tree.root != tree2.root }

  # Proof generation and verification
  proof0 = tree.proof_for(0)
  assert('proof is an array') { proof0.is_a?(Array) }
  assert('proof elements have hash and side') { proof0.all? { |s| s.key?(:hash) && s.key?(:side) } }

  # Verify leaf 0
  assert('verify leaf 0 passes') { Synoptis::MerkleTree.verify('alpha', proof0, tree.root) }

  # Verify leaf 2
  proof2 = tree.proof_for(2)
  assert('verify leaf 2 passes') { Synoptis::MerkleTree.verify('gamma', proof2, tree.root) }

  # Invalid leaf fails verification
  assert('verify wrong leaf fails') { !Synoptis::MerkleTree.verify('wrong', proof0, tree.root) }

  # Odd number of leaves
  tree_odd = Synoptis::MerkleTree.new(%w[one two three])
  assert('odd leaves tree has root') { tree_odd.root.match?(/\A[0-9a-f]{64}\z/) }
  proof_odd = tree_odd.proof_for(2)
  assert('verify last leaf of odd tree') { Synoptis::MerkleTree.verify('three', proof_odd, tree_odd.root) }

  # Single leaf
  tree_one = Synoptis::MerkleTree.new(%w[solo])
  assert('single leaf tree works') { tree_one.root.match?(/\A[0-9a-f]{64}\z/) }

  # Error on empty
  begin
    Synoptis::MerkleTree.new([])
    assert('empty leaves raises') { false }
  rescue ArgumentError
    assert('empty leaves raises') { true }
  end
end

# Setup temp storage for registry tests
test_dir = Dir.mktmpdir('synoptis_test')

test_section('FileRegistry CRUD') do
  registry = Synoptis::Registry::FileRegistry.new(storage_path: test_dir)

  # Save proof
  proof_data = {
    proof_id: 'att_test_001',
    claim_type: 'SKILL_QUALITY',
    attester_id: 'agent_alpha',
    attestee_id: 'agent_beta',
    subject_ref: 'skill:test',
    target_hash: 'sha256:abc',
    evidence_hash: 'sha256:def',
    nonce: 'test_nonce',
    signature: 'test_sig',
    attester_pubkey_fingerprint: 'fp:123',
    transport: 'local',
    issued_at: Time.now.utc.iso8601,
    status: 'active'
  }
  registry.save_proof(proof_data)

  # Find proof
  found = registry.find_proof('att_test_001')
  assert('find_proof returns saved proof') { found && found[:proof_id] == 'att_test_001' }
  assert('find_proof returns nil for missing') { registry.find_proof('nonexistent').nil? }

  # Save second proof
  proof_data2 = proof_data.merge(
    proof_id: 'att_test_002',
    claim_type: 'DATA_INTEGRITY',
    attester_id: 'agent_gamma'
  )
  registry.save_proof(proof_data2)

  # List proofs
  all = registry.list_proofs
  assert('list_proofs returns all') { all.size == 2 }

  # Filter by agent_id
  by_agent = registry.list_proofs(agent_id: 'agent_alpha')
  assert('filter by agent_id works') { by_agent.size == 1 && by_agent.first[:proof_id] == 'att_test_001' }

  # Filter by claim_type
  by_claim = registry.list_proofs(claim_type: 'DATA_INTEGRITY')
  assert('filter by claim_type works') { by_claim.size == 1 && by_claim.first[:proof_id] == 'att_test_002' }

  # Filter by status
  by_status = registry.list_proofs(status: 'active')
  assert('filter by status works') { by_status.size == 2 }

  # Save revocation
  rev = {
    revocation_id: 'rev_test_001',
    proof_id: 'att_test_001',
    reason: 'test revocation',
    revoked_by: 'agent_alpha',
    revoked_at: Time.now.utc.iso8601
  }
  registry.save_revocation(rev)

  # Find revocation
  found_rev = registry.find_revocation('att_test_001')
  assert('find_revocation returns saved') { found_rev && found_rev[:proof_id] == 'att_test_001' }
  assert('find_revocation nil for unrevoked') { registry.find_revocation('att_test_002').nil? }

  # Update proof status
  registry.update_proof_status('att_test_001', 'revoked', { reason: 'test' })
  updated = registry.find_proof('att_test_001')
  assert('update_proof_status changes status') { updated[:status] == 'revoked' }
end

test_section('AttestationEngine - create_request') do
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config)

  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test_v1', 'full')
  assert('request has request_id') { request[:request_id].start_with?('req_') }
  assert('request has target_id') { request[:target_id] == 'agent_beta' }
  assert('request has claim_type') { request[:claim_type] == 'SKILL_QUALITY' }
  assert('request has nonce') { !request[:nonce].nil? }

  # Invalid claim_type
  begin
    engine.create_request('agent_beta', 'INVALID_TYPE', 'skill:test')
    assert('invalid claim_type raises') { false }
  rescue ArgumentError
    assert('invalid claim_type raises') { true }
  end
end

test_section('AttestationEngine - build_proof and verify round-trip') do
  storage = Dir.mktmpdir('synoptis_engine_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  # Create request
  request = engine.create_request('agent_beta', 'PIPELINE_EXECUTION', 'skill:rnaseq_v1', 'full')

  # Build proof with evidence
  evidence = {
    skill_id: 'rnaseq_v1',
    input_hash: "sha256:#{Digest::SHA256.hexdigest('input_data')}",
    output_hash: "sha256:#{Digest::SHA256.hexdigest('output_data')}",
    reproducibility: 'exact_match'
  }

  proof = engine.build_proof(request, evidence, crypto_attester, attester_id: 'agent_alpha')

  assert('build_proof returns ProofEnvelope') { proof.is_a?(Synoptis::ProofEnvelope) }
  assert('proof is signed') { !proof.signature.nil? }
  assert('proof has evidence in full mode') { !proof.evidence.nil? }
  assert('proof has merkle_root') { !proof.merkle_root.nil? }
  assert('proof claim_type matches') { proof.claim_type == 'PIPELINE_EXECUTION' }
  assert('proof attester_id matches') { proof.attester_id == 'agent_alpha' }
  assert('proof attestee_id matches') { proof.attestee_id == 'agent_beta' }

  # Verify the proof
  result = engine.verify_proof(proof, public_key: crypto_attester.export_public_key)
  assert('verify returns valid: true') { result[:valid] == true }
  assert('verify has no failure reasons') { result[:reasons].empty? }

  # Verify with wrong key should fail
  result_bad = engine.verify_proof(proof, public_key: crypto_attestee.export_public_key)
  assert('verify with wrong key returns valid: false') { result_bad[:valid] == false }
  assert('verify with wrong key has signature_invalid') { result_bad[:reasons].include?('signature_invalid') }

  # Proof stored in registry
  stored = registry.find_proof(proof.proof_id)
  assert('proof stored in registry') { !stored.nil? }

  FileUtils.rm_rf(storage)
end

test_section('AttestationEngine - self-attestation rejection') do
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config)

  request = engine.create_request('agent_alpha', 'SKILL_QUALITY', 'skill:test')

  begin
    engine.build_proof(request, { test: true }, crypto_attester, attester_id: 'agent_alpha')
    assert('self-attestation rejected') { false }
  rescue ArgumentError => e
    assert('self-attestation rejected') { e.message.include?('Self-attestation') }
  end
end

test_section('Revocation and verify after revoke') do
  storage = Dir.mktmpdir('synoptis_revoke_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  # Build a proof
  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')
  proof = engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto_attester, attester_id: 'agent_alpha')

  # Verify before revoke
  result_before = engine.verify_proof(proof, public_key: crypto_attester.export_public_key)
  assert('valid before revocation') { result_before[:valid] == true }

  # Revoke
  revocation = engine.revoke_proof(proof.proof_id, 'Evidence was incorrect', 'agent_alpha')
  assert('revoke returns revocation record') { revocation[:revocation_id].start_with?('rev_') }
  assert('revoke has reason') { revocation[:reason] == 'Evidence was incorrect' }

  # Verify after revoke (should return revoked)
  result_after = engine.verify_proof(proof, public_key: crypto_attester.export_public_key)
  assert('invalid after revocation') { result_after[:valid] == false }
  assert('has revoked reason') { result_after[:reasons].include?('revoked') }

  # Double revoke should raise
  begin
    engine.revoke_proof(proof.proof_id, 'second revoke', 'agent_alpha')
    assert('double revoke raises') { false }
  rescue RuntimeError => e
    assert('double revoke raises') { e.message.include?('already revoked') }
  end

  FileUtils.rm_rf(storage)
end

test_section('Verifier - evidence hash mismatch') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'agent_alpha',
    attestee_id: 'agent_beta',
    target_hash: 'sha256:abc',
    evidence_hash: 'sha256:wrong_hash',
    evidence: { quality: 'good', score: 0.9 }
  )
  proof.sign!(crypto_attester)

  verifier = Synoptis::Verifier.new
  result = verifier.verify(proof, public_key: crypto_attester.export_public_key)
  assert('evidence hash mismatch detected') { result[:reasons].include?('evidence_hash_mismatch') }
  assert('invalid due to evidence hash') { result[:valid] == false }
end

test_section('Verifier - expired proof') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
    expires_at: (Time.now.utc - 86400).iso8601
  )
  proof.sign!(crypto_attester)

  verifier = Synoptis::Verifier.new
  result = verifier.verify(proof, public_key: crypto_attester.export_public_key)
  assert('expired proof detected') { result[:reasons].include?('expired') }
end

# ===== Phase 2: Transport Layer =====

test_section('Transport::Base interface') do
  base = Synoptis::Transport::Base.new
  assert('send_message raises NotImplementedError') do
    begin
      base.send_message('test', {})
      false
    rescue NotImplementedError
      true
    end
  end
  assert('available? raises NotImplementedError') do
    begin
      base.available?
      false
    rescue NotImplementedError
      true
    end
  end
  assert('transport_name raises NotImplementedError') do
    begin
      base.transport_name
      false
    rescue NotImplementedError
      true
    end
  end
end

test_section('Transport::MMPTransport') do
  transport = Synoptis::Transport::MMPTransport.new
  assert('transport_name is mmp') { transport.transport_name == 'mmp' }
  assert('available? returns true when MMP::Protocol defined') { transport.available? == defined?(MMP::Protocol) }

  # Send a message (no live MeetingRouter — should report failure)
  result = transport.send_message('agent_beta', { action: 'attestation_request', payload: { test: true } })
  assert('send_message returns failure without MeetingRouter') { result[:success] == false }
  assert('send_message returns transport name') { result[:transport] == 'mmp' }
  assert('send_message reports no MeetingRouter') { result[:error].include?('MeetingRouter') }
end

test_section('Transport::HestiaTransport') do
  transport = Synoptis::Transport::HestiaTransport.new
  assert('transport_name is hestia') { transport.transport_name == 'hestia' }
  assert('available? returns false when Hestia not loaded') { !transport.available? }

  result = transport.send_message('agent_beta', { action: 'attestation_request' })
  assert('send_message fails when unavailable') { result[:success] == false }
  assert('error mentions Hestia') { result[:error].include?('Hestia') }
end

test_section('Transport::LocalTransport') do
  transport = Synoptis::Transport::LocalTransport.new
  assert('transport_name is local') { transport.transport_name == 'local' }
  assert('available? returns false when Multiuser not loaded') { !transport.available? }

  result = transport.send_message('agent_beta', { action: 'attestation_request' })
  assert('send_message fails when unavailable') { result[:success] == false }
  assert('error mentions Multiuser') { result[:error].include?('Multiuser') }
end

test_section('Transport::Router routing and fallback') do
  router = Synoptis::Transport::Router.new
  assert('available_transports includes mmp') { router.available_transports.include?('mmp') }
  assert('available_transports excludes hestia') { !router.available_transports.include?('hestia') }
  assert('available_transports excludes local') { !router.available_transports.include?('local') }

  # Send via router (all transports fail without live infrastructure)
  result = router.send('agent_beta', { action: 'attestation_request', payload: { test: true } })
  assert('router send fails without live infrastructure') { result[:success] == false }
  assert('router reports all transports failed') { result[:error] == 'All transports failed' }
end

# ===== Phase 3: Trust Scoring =====

test_section('TrustScorer - basic scoring') do
  storage = Dir.mktmpdir('synoptis_trust_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  # Build multiple proofs from different attesters
  3.times do |i|
    attester = "attester_#{i}"
    crypto = MMP::Crypto.new
    request = engine.create_request('target_agent', 'SKILL_QUALITY', "skill:test_#{i}")
    engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto, attester_id: attester)
  end

  scorer = Synoptis::TrustScorer.new(registry: registry)
  result = scorer.score('target_agent')

  assert('score is between 0 and 1') { result[:score] >= 0.0 && result[:score] <= 1.0 }
  assert('score is positive') { result[:score] > 0.0 }
  assert('breakdown has quality') { result[:breakdown].key?(:quality) }
  assert('breakdown has freshness') { result[:breakdown].key?(:freshness) }
  assert('breakdown has diversity') { result[:breakdown].key?(:diversity) }
  assert('breakdown has revocation_penalty') { result[:breakdown].key?(:revocation_penalty) }
  assert('breakdown has velocity_penalty') { result[:breakdown].key?(:velocity_penalty) }
  assert('attestation_count is 3') { result[:attestation_count] == 3 }

  FileUtils.rm_rf(storage)
end

test_section('TrustScorer - zero score for unknown agent') do
  storage = Dir.mktmpdir('synoptis_trust_zero')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  scorer = Synoptis::TrustScorer.new(registry: registry)

  result = scorer.score('nonexistent_agent')
  assert('zero score for unknown agent') { result[:score] == 0.0 }
  assert('zero attestation_count') { result[:attestation_count] == 0 }

  FileUtils.rm_rf(storage)
end

test_section('TrustScorer - diversity affects score') do
  storage = Dir.mktmpdir('synoptis_diversity_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  # High diversity: 3 unique attesters for 3 proofs
  3.times do |i|
    crypto = MMP::Crypto.new
    request = engine.create_request('diverse_agent', 'SKILL_QUALITY', "skill:#{i}")
    engine.build_proof(request, { quality: 'good', idx: i }, crypto, attester_id: "unique_attester_#{i}")
  end

  scorer = Synoptis::TrustScorer.new(registry: registry)
  diverse_result = scorer.score('diverse_agent')

  # Low diversity: same attester for multiple proofs in a separate registry
  storage2 = Dir.mktmpdir('synoptis_low_diversity_test')
  registry2 = Synoptis::Registry::FileRegistry.new(storage_path: storage2)
  engine2 = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry2)
  crypto_single = MMP::Crypto.new

  3.times do |i|
    request = engine2.create_request('uniform_agent', 'SKILL_QUALITY', "skill:#{i}")
    engine2.build_proof(request, { quality: 'good', idx: i }, crypto_single, attester_id: 'same_attester')
  end

  scorer2 = Synoptis::TrustScorer.new(registry: registry2)
  uniform_result = scorer2.score('uniform_agent')

  assert('diverse agent has higher diversity score') { diverse_result[:breakdown][:diversity] > uniform_result[:breakdown][:diversity] }

  FileUtils.rm_rf(storage)
  FileUtils.rm_rf(storage2)
end

test_section('GraphAnalyzer - anomaly detection') do
  storage = Dir.mktmpdir('synoptis_graph_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)

  # Create a closed cluster: A->B, B->A, A->C, C->A, B->C, C->B
  agents = %w[agent_a agent_b agent_c]
  agents.combination(2).each do |a, b|
    # a -> b
    registry.save_proof({
      proof_id: "att_#{a}_#{b}", claim_type: 'SKILL_QUALITY',
      attester_id: a, attestee_id: b, subject_ref: 'skill:test',
      target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
      nonce: SecureRandom.hex(16), signature: 'sig', attester_pubkey_fingerprint: 'fp',
      transport: 'local', issued_at: Time.now.utc.iso8601, status: 'active'
    })
    # b -> a
    registry.save_proof({
      proof_id: "att_#{b}_#{a}", claim_type: 'SKILL_QUALITY',
      attester_id: b, attestee_id: a, subject_ref: 'skill:test',
      target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
      nonce: SecureRandom.hex(16), signature: 'sig', attester_pubkey_fingerprint: 'fp',
      transport: 'local', issued_at: Time.now.utc.iso8601, status: 'active'
    })
  end

  analyzer = Synoptis::GraphAnalyzer.new(registry: registry)
  result = analyzer.analyze('agent_a')

  assert('metrics has cluster_coefficient') { result[:metrics].key?(:cluster_coefficient) }
  assert('metrics has external_connection_ratio') { result[:metrics].key?(:external_connection_ratio) }
  assert('metrics has velocity_24h') { result[:metrics].key?(:velocity_24h) }

  # Closed cluster should have high cluster coefficient
  assert('high cluster coefficient for closed group') { result[:metrics][:cluster_coefficient] >= 0.8 }

  # Should flag anomaly for high clustering
  assert('anomaly_flags not empty for closed cluster') { result[:anomaly_flags].any? { |f| f[:type] == 'high_cluster_coefficient' } }

  FileUtils.rm_rf(storage)
end

# ===== Phase 4: ChallengeProtocol =====

test_section('ChallengeManager - open challenge') do
  storage = Dir.mktmpdir('synoptis_challenge_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  # Build a proof first
  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')
  proof = engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto_attester, attester_id: 'agent_alpha')

  # Open a challenge
  manager = Synoptis::ChallengeManager.new(registry: registry)
  challenge = manager.open_challenge(proof.proof_id, 'agent_gamma', 'Evidence is suspicious')

  assert('challenge_id starts with chl_') { challenge[:challenge_id].start_with?('chl_') }
  assert('status is open') { challenge[:status] == 'open' }
  assert('challenger_id is set') { challenge[:challenger_id] == 'agent_gamma' }
  assert('reason is set') { challenge[:reason] == 'Evidence is suspicious' }
  assert('deadline_at is set') { !challenge[:deadline_at].nil? }

  # Proof status should be updated to challenged
  updated_proof = registry.find_proof(proof.proof_id)
  assert('proof status changed to challenged') { updated_proof[:status] == 'challenged' }

  # Challenge stored in registry
  found_challenge = registry.find_challenge(challenge[:challenge_id])
  assert('challenge found in registry') { found_challenge && found_challenge[:challenge_id] == challenge[:challenge_id] }

  FileUtils.rm_rf(storage)
end

test_section('ChallengeManager - resolve challenge (uphold)') do
  storage = Dir.mktmpdir('synoptis_resolve_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')
  proof = engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto_attester, attester_id: 'agent_alpha')

  manager = Synoptis::ChallengeManager.new(registry: registry)
  challenge = manager.open_challenge(proof.proof_id, 'agent_gamma', 'Suspicious evidence')

  # Resolve: uphold (attestation valid)
  result = manager.resolve_challenge(challenge[:challenge_id], 'uphold', response: 'Evidence verified independently')

  assert('resolved status is resolved_valid') { result[:status] == 'resolved_valid' }
  assert('response is recorded') { result[:response] == 'Evidence verified independently' }
  assert('resolved_at is set') { !result[:resolved_at].nil? }

  # Proof should be restored to active
  restored_proof = registry.find_proof(proof.proof_id)
  assert('proof restored to active after uphold') { restored_proof[:status] == 'active' }

  FileUtils.rm_rf(storage)
end

test_section('ChallengeManager - resolve challenge (invalidate)') do
  storage = Dir.mktmpdir('synoptis_invalidate_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')
  proof = engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto_attester, attester_id: 'agent_alpha')

  manager = Synoptis::ChallengeManager.new(registry: registry)
  challenge = manager.open_challenge(proof.proof_id, 'agent_gamma', 'Evidence is fabricated')

  # Resolve: invalidate (attestation revoked)
  result = manager.resolve_challenge(challenge[:challenge_id], 'invalidate', response: 'Evidence confirmed fabricated')

  assert('resolved status is resolved_invalid') { result[:status] == 'resolved_invalid' }

  # Proof should be revoked
  revoked_proof = registry.find_proof(proof.proof_id)
  assert('proof revoked after invalidation') { revoked_proof[:status] == 'revoked' }

  FileUtils.rm_rf(storage)
end

test_section('ChallengeManager - expired challenge') do
  storage = Dir.mktmpdir('synoptis_expired_challenge')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')
  proof = engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto_attester, attester_id: 'agent_alpha')

  # Create challenge with 0h window (immediately expired)
  config = Synoptis.default_config.dup
  config['challenge'] = { 'response_window_hours' => 0 }
  manager = Synoptis::ChallengeManager.new(registry: registry, config: config)
  challenge = manager.open_challenge(proof.proof_id, 'agent_gamma', 'Test expiry')

  # Allow a tiny delay for time to pass
  sleep(0.01)

  # Check for expired challenges
  expired = manager.check_expired_challenges
  assert('expired challenges found') { expired.size >= 1 }
  assert('expired challenge status is challenged_unresolved') { expired.first[:status] == 'challenged_unresolved' }

  FileUtils.rm_rf(storage)
end

test_section('ChallengeManager - cannot challenge revoked proof') do
  storage = Dir.mktmpdir('synoptis_challenge_revoked')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')
  proof = engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto_attester, attester_id: 'agent_alpha')

  # Revoke first
  engine.revoke_proof(proof.proof_id, 'test reason', 'agent_alpha')

  # Try to challenge revoked proof
  manager = Synoptis::ChallengeManager.new(registry: registry)
  begin
    manager.open_challenge(proof.proof_id, 'agent_gamma', 'Should fail')
    assert('cannot challenge revoked proof') { false }
  rescue ArgumentError => e
    assert('cannot challenge revoked proof') { e.message.include?('revoked') }
  end

  FileUtils.rm_rf(storage)
end

test_section('ChallengeManager - cannot resolve already resolved') do
  storage = Dir.mktmpdir('synoptis_double_resolve')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')
  proof = engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto_attester, attester_id: 'agent_alpha')

  manager = Synoptis::ChallengeManager.new(registry: registry)
  challenge = manager.open_challenge(proof.proof_id, 'agent_gamma', 'Test')
  manager.resolve_challenge(challenge[:challenge_id], 'uphold')

  begin
    manager.resolve_challenge(challenge[:challenge_id], 'invalidate')
    assert('cannot resolve already resolved challenge') { false }
  rescue ArgumentError => e
    assert('cannot resolve already resolved challenge') { e.message.include?('already resolved') }
  end

  FileUtils.rm_rf(storage)
end

test_section('FileRegistry - challenge CRUD') do
  storage = Dir.mktmpdir('synoptis_challenge_crud')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)

  challenge = {
    challenge_id: 'chl_test_001',
    challenged_proof_id: 'att_test_001',
    challenger_id: 'agent_gamma',
    reason: 'Test challenge',
    status: 'open',
    deadline_at: (Time.now.utc + 72 * 3600).iso8601,
    created_at: Time.now.utc.iso8601
  }

  registry.save_challenge(challenge)

  found = registry.find_challenge('chl_test_001')
  assert('find_challenge returns saved') { found && found[:challenge_id] == 'chl_test_001' }
  assert('find_challenge nil for missing') { registry.find_challenge('nonexistent').nil? }

  # List challenges
  all = registry.list_challenges
  assert('list_challenges returns all') { all.size == 1 }

  by_status = registry.list_challenges(status: 'open')
  assert('filter by status works') { by_status.size == 1 }

  by_closed = registry.list_challenges(status: 'resolved_valid')
  assert('filter by closed status returns empty') { by_closed.empty? }

  # Update challenge
  updated = challenge.merge(status: 'resolved_valid', resolved_at: Time.now.utc.iso8601)
  registry.update_challenge('chl_test_001', updated)
  found_updated = registry.find_challenge('chl_test_001')
  assert('update_challenge changes status') { found_updated[:status] == 'resolved_valid' }

  FileUtils.rm_rf(storage)
end

# ===== Additional Coverage Tests (from agent review) =====

test_section('Verifier - check_merkle: true') do
  storage = Dir.mktmpdir('synoptis_merkle_verify_test')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  request = engine.create_request('agent_beta', 'PIPELINE_EXECUTION', 'skill:rnaseq', 'full')
  evidence = { skill_id: 'rnaseq', output_hash: 'sha256:abc', reproducibility: 'exact_match' }
  proof = engine.build_proof(request, evidence, crypto_attester, attester_id: 'agent_alpha')

  verifier = Synoptis::Verifier.new(registry: registry)
  result = verifier.verify(proof, public_key: crypto_attester.export_public_key, check_merkle: true)
  assert('merkle verification passes for valid proof') { !result[:reasons].include?('merkle_proof_invalid') }

  # Tamper with merkle_root
  proof_tampered = Synoptis::ProofEnvelope.from_h(proof.to_h.merge(merkle_root: 'deadbeef' * 8))
  result_bad = verifier.verify(proof_tampered, public_key: crypto_attester.export_public_key, check_merkle: true)
  assert('merkle verification fails for tampered root') { result_bad[:reasons].include?('merkle_proof_invalid') }

  FileUtils.rm_rf(storage)
end

test_section('Verifier - no public key provided') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def'
  )
  proof.sign!(crypto_attester)

  verifier = Synoptis::Verifier.new
  result = verifier.verify(proof)
  assert('no_public_key_provided in reasons') { result[:reasons].include?('no_public_key_provided') }
  assert('trust_hints note is set') { result[:trust_hints][:note].is_a?(String) }
end

test_section('Verifier - unknown claim type') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'NONEXISTENT_TYPE',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def'
  )
  proof.sign!(crypto_attester)

  verifier = Synoptis::Verifier.new
  result = verifier.verify(proof, public_key: crypto_attester.export_public_key)
  assert('unknown_claim_type detected') { result[:reasons].include?('unknown_claim_type') }
end

test_section('Verifier - revocation via registry lookup') do
  storage = Dir.mktmpdir('synoptis_revocation_lookup')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)

  # Create a properly signed proof
  proof = Synoptis::ProofEnvelope.new(
    proof_id: 'att_rev_lookup', claim_type: 'SKILL_QUALITY',
    attester_id: 'agent_a', attestee_id: 'agent_b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def'
  )
  proof.sign!(crypto_attester)
  registry.save_proof(proof.to_h)

  # Save a revocation record (without updating proof status — simulates external revocation)
  registry.save_revocation({
    revocation_id: 'rev_lookup', proof_id: 'att_rev_lookup',
    reason: 'External revocation', revoked_by: 'agent_a',
    revoked_at: Time.now.utc.iso8601
  })

  # Verify — status is still 'active' but registry has revocation
  verifier = Synoptis::Verifier.new(registry: registry)
  result = verifier.verify(proof, public_key: crypto_attester.export_public_key)
  assert('revocation detected via registry lookup') { result[:reasons].include?('revoked') }
  assert('trust_hints has revoke_reason') { result[:trust_hints][:revoke_reason] == 'External revocation' }

  FileUtils.rm_rf(storage)
end

test_section('TrustScorer - revocation penalty') do
  storage = Dir.mktmpdir('synoptis_revocation_penalty')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  # agent_x issues 3 attestations, 2 will be revoked
  3.times do |i|
    request = engine.create_request("target_#{i}", 'SKILL_QUALITY', "skill:#{i}")
    engine.build_proof(request, { quality: 'good', idx: i }, crypto_attester, attester_id: 'agent_x')
  end

  proofs = registry.list_proofs(agent_id: 'agent_x').select { |p| p[:attester_id] == 'agent_x' }
  # Revoke 2 of 3
  engine.revoke_proof(proofs[0][:proof_id], 'bad evidence', 'agent_x')
  engine.revoke_proof(proofs[1][:proof_id], 'bad evidence', 'agent_x')

  # Also have agent_x receive 1 attestation so we can score agent_x
  crypto_other = MMP::Crypto.new
  request = engine.create_request('agent_x', 'SKILL_QUALITY', 'skill:check')
  engine.build_proof(request, { quality: 'good', idx: 99 }, crypto_other, attester_id: 'external_agent')

  scorer = Synoptis::TrustScorer.new(registry: registry)
  result = scorer.score('agent_x')
  # revocation_penalty = 2 revoked / 3 issued = 0.667
  assert('revocation_penalty is approximately 0.667') do
    result[:breakdown][:revocation_penalty] >= 0.6 && result[:breakdown][:revocation_penalty] <= 0.7
  end

  FileUtils.rm_rf(storage)
end

test_section('TrustScorer - velocity penalty') do
  storage = Dir.mktmpdir('synoptis_velocity_penalty')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  # fast_attester issues 15 attestations to various targets
  15.times do |i|
    request = engine.create_request("target_#{i}", 'SKILL_QUALITY', "skill:#{i}")
    engine.build_proof(request, { quality: 'good', idx: i }, crypto_attester, attester_id: 'fast_attester')
  end

  # Also have fast_attester receive at least 1 attestation so score is not zero
  crypto_other = MMP::Crypto.new
  request = engine.create_request('fast_attester', 'SKILL_QUALITY', 'skill:check')
  engine.build_proof(request, { quality: 'good', idx: 99 }, crypto_other, attester_id: 'external_agent')

  scorer = Synoptis::TrustScorer.new(registry: registry)
  result = scorer.score('fast_attester')
  # velocity_penalty should be (15 - 10) / 15 = 0.333
  assert('velocity_penalty is positive') { result[:breakdown][:velocity_penalty] > 0.0 }
  assert('velocity_penalty is approximately 0.333') do
    result[:breakdown][:velocity_penalty] >= 0.3 && result[:breakdown][:velocity_penalty] <= 0.4
  end

  FileUtils.rm_rf(storage)
end

test_section('GraphAnalyzer - low external connections flag') do
  storage = Dir.mktmpdir('synoptis_graph_external')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)

  # Closed 3-agent mutual cluster with no external attesters
  %w[agent_a agent_b agent_c].combination(2).each do |a, b|
    registry.save_proof({
      proof_id: "att_#{a}_#{b}", claim_type: 'SKILL_QUALITY',
      attester_id: a, attestee_id: b, subject_ref: 'skill:test',
      target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
      nonce: SecureRandom.hex(16), signature: 'sig', attester_pubkey_fingerprint: 'fp',
      transport: 'local', issued_at: Time.now.utc.iso8601, status: 'active'
    })
    registry.save_proof({
      proof_id: "att_#{b}_#{a}", claim_type: 'SKILL_QUALITY',
      attester_id: b, attestee_id: a, subject_ref: 'skill:test',
      target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
      nonce: SecureRandom.hex(16), signature: 'sig', attester_pubkey_fingerprint: 'fp',
      transport: 'local', issued_at: Time.now.utc.iso8601, status: 'active'
    })
  end

  analyzer = Synoptis::GraphAnalyzer.new(registry: registry)
  result = analyzer.analyze('agent_a')

  # All attesters are mutual — external_connection_ratio should be 0.0
  assert('external_connection_ratio is 0.0 for closed cluster') { result[:metrics][:external_connection_ratio] == 0.0 }
  assert('low_external_connections flag raised') do
    result[:anomaly_flags].any? { |f| f[:type] == 'low_external_connections' }
  end

  FileUtils.rm_rf(storage)
end

test_section('ChallengeManager - max active challenges') do
  storage = Dir.mktmpdir('synoptis_max_challenges')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  # Create 5 separate proofs and challenge each
  config = Synoptis.default_config
  manager = Synoptis::ChallengeManager.new(registry: registry, config: config)

  5.times do |i|
    request = engine.create_request("target_#{i}", 'SKILL_QUALITY', "skill:#{i}")
    proof = engine.build_proof(request, { quality: 'good', idx: i }, crypto_attester, attester_id: 'agent_alpha')
    manager.open_challenge(proof.proof_id, 'challenger_x', "Reason #{i}")
  end

  # 6th challenge should fail
  request6 = engine.create_request('target_6', 'SKILL_QUALITY', 'skill:6')
  proof6 = engine.build_proof(request6, { quality: 'good', idx: 6 }, crypto_attester, attester_id: 'agent_alpha')
  begin
    manager.open_challenge(proof6.proof_id, 'challenger_x', 'Too many')
    assert('max_active_challenges enforced') { false }
  rescue ArgumentError => e
    assert('max_active_challenges enforced') { e.message.include?('Maximum active challenges') }
  end

  FileUtils.rm_rf(storage)
end

test_section('Router - all transports fail') do
  # Configure with only unavailable transports
  config = Synoptis.default_config.dup
  config['transport'] = { 'priority' => %w[hestia local] }
  router = Synoptis::Transport::Router.new(config: config)

  result = router.send('agent_x', { action: 'attestation_request' })
  assert('all transports failed') { result[:success] == false }
  assert('error says all transports failed') { result[:error] == 'All transports failed' }
end

test_section('MMPTransport - available? returns boolean-like') do
  transport = Synoptis::Transport::MMPTransport.new
  # available? should be truthy when MMP::Protocol is defined
  assert('available? is truthy') { transport.available? ? true : false }
end

test_section('ProofEnvelope - round-trip preserves merkle_proof keys') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def',
    merkle_proof: [{ hash: 'abc123', side: :left }, { hash: 'def456', side: :right }]
  )

  # JSON round-trip
  json = proof.to_json
  restored = Synoptis::ProofEnvelope.from_h(JSON.parse(json, symbolize_names: true))
  assert('merkle_proof keys are symbols after round-trip') do
    restored.merkle_proof.all? { |step| step.key?(:hash) && step.key?(:side) }
  end
end

test_section('ProofEnvelope - to_anchor returns nil without Hestia') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def'
  )
  assert('to_anchor returns nil without Hestia') { proof.to_anchor.nil? }
end

test_section('ProofEnvelope - unsigned proof returns false from valid_signature?') do
  proof = Synoptis::ProofEnvelope.new(
    claim_type: 'SKILL_QUALITY',
    attester_id: 'a', attestee_id: 'b',
    target_hash: 'sha256:abc', evidence_hash: 'sha256:def'
  )
  assert('unsigned proof returns false') { proof.valid_signature?(crypto_attester) == false }
end

test_section('AttestationEngine - existence_only hides evidence') do
  storage = Dir.mktmpdir('synoptis_existence_only')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test', 'existence_only')
  evidence = { quality: 'good', score: 0.9 }
  proof = engine.build_proof(request, evidence, crypto_attester, attester_id: 'agent_alpha')

  assert('evidence is nil in existence_only mode') { proof.evidence.nil? }
  assert('evidence_hash is still set') { !proof.evidence_hash.nil? }

  FileUtils.rm_rf(storage)
end

test_section('ChallengeManager - duplicate challenge prevention') do
  storage = Dir.mktmpdir('synoptis_dup_challenge')
  registry = Synoptis::Registry::FileRegistry.new(storage_path: storage)
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config, registry: registry)

  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')
  proof = engine.build_proof(request, { quality: 'good', score: 0.9 }, crypto_attester, attester_id: 'agent_alpha')

  manager = Synoptis::ChallengeManager.new(registry: registry)
  manager.open_challenge(proof.proof_id, 'agent_gamma', 'First challenge')

  begin
    manager.open_challenge(proof.proof_id, 'agent_delta', 'Duplicate challenge')
    assert('duplicate challenge rejected') { false }
  rescue ArgumentError => e
    assert('duplicate challenge rejected') { e.message.include?('open challenge already exists') }
  end

  FileUtils.rm_rf(storage)
end

test_section('AttestationEngine - min_evidence_fields rejection') do
  engine = Synoptis::AttestationEngine.new(config: Synoptis.default_config)
  request = engine.create_request('agent_beta', 'SKILL_QUALITY', 'skill:test')

  begin
    engine.build_proof(request, { only_one: 'field' }, crypto_attester, attester_id: 'agent_alpha')
    assert('min_evidence_fields enforced') { false }
  rescue ArgumentError => e
    assert('min_evidence_fields enforced') { e.message.include?('at least 2 fields') }
  end
end

test_section('MerkleTree - proof_for on single-leaf tree') do
  tree = Synoptis::MerkleTree.new(%w[solo])
  proof = tree.proof_for(0)
  assert('single leaf proof_for returns array') { proof.is_a?(Array) }
  assert('single leaf verifies') { Synoptis::MerkleTree.verify('solo', proof, tree.root) }
end

# Cleanup
FileUtils.rm_rf(test_dir)

# ===== Summary =====
separator
puts
puts "Results: #{$pass_count} passed, #{$fail_count} failed"
puts
exit($fail_count > 0 ? 1 : 0)
