# frozen_string_literal: true
# Design-constraint tests for the Chain Distillation slice 1
# (chain_distillation_skillset_design v0.5, converged; invariants CD-1..CD-6).
# Each block names the invariant whose implementable consequence it pins.

require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'digest'

require_relative '../../../../lib/kairos_mcp/tool_registry'
require_relative '../../confidentiality_guard/lib/confidentiality_guard/regime'
require_relative '../lib/chain_distillation/canon'
require_relative '../lib/chain_distillation/recorder'
require_relative '../lib/chain_distillation/certificate'
require_relative '../lib/chain_distillation/distiller'
require_relative '../lib/chain_distillation/depositor'
require_relative '../lib/chain_distillation/carrier_wiring'

CG = KairosMcp::SkillSets::ConfidentialityGuard
CD = KairosMcp::SkillSets::ChainDistillation

$pass = 0
$fail = 0

def assert(condition, message)
  if condition
    $pass += 1
  else
    $fail += 1
    puts "FAIL: #{message}"
  end
end

def assert_raises(klass, message)
  yield
  $fail += 1
  puts "FAIL (no raise): #{message}"
rescue klass
  $pass += 1
rescue StandardError => e
  $fail += 1
  puts "FAIL (wrong raise #{e.class}): #{message}"
end

# Shared in-memory chain: the guard's decision records and the distiller's
# CD-6 records land on the SAME source chain, as in-instance (blocks carry
# index/hash/data like the real chain's).
class FakeChain
  Block = Struct.new(:index, :hash, :data)
  attr_reader :blocks
  def initialize = @blocks = []
  def add_block(data)
    index = @blocks.size
    block = Block.new(index, Digest::SHA256.hexdigest("blk|#{index}|#{Array(data).join('|')}"), Array(data))
    @blocks << block
    block
  end
end

class FakeRegistry
  @gates = {}
  class << self
    attr_reader :gates
    def register_gate(name, &block) = @gates[name.to_sym] = block
    def unregister_gate(name) = @gates.delete(name.to_sym)
    def run_gates(tool_name, arguments, safety = nil)
      @gates.values.each { |g| g.call(tool_name, arguments, safety) }
    end
    def clear! = @gates = {}
  end
end

SECRET = 'api_key: SUPER-SECRET-VALUE-12345'

DISTILL_PROFILE = {
  'version' => 1,
  'persistent_admissions' => { 'l2' => 'permitted' },
  'content_classes' => [{ 'id' => 'api_key', 'pattern' => '(?i)api[_-]?key["\']?\s*[:=]' }],
  'distillation_crossings' => %w[cd_release_distillate cd_release_certificate]
}.freeze

NO_CROSSING_PROFILE = DISTILL_PROFILE.reject { |k, _| k == 'distillation_crossings' }.freeze

def with_stack(profile_yaml, activate_guard: true)
  Dir.mktmpdir do |root|
    FileUtils.mkdir_p(File.join(root, 'config'))
    File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
               { 'guard' => { 'enabled' => activate_guard, 'profile' => 'profile.yml' } }.to_yaml)
    File.write(File.join(root, 'config', 'profile.yml'), profile_yaml.to_yaml) if profile_yaml
    fake = FakeChain.new
    # Seed some source records so designations have something to name.
    5.times { |i| fake.add_block([JSON.generate('type' => 'seed', 'n' => i)]) }
    CG::Recorder.chain_factory = -> { fake }
    CD::Recorder.chain_factory = -> { fake }
    CG::Regime.skillset_root = root
    FakeRegistry.clear!
    CD::Distiller.registry_class = FakeRegistry
    CD::Distiller.guard_regime = CG::Regime
    old_env = ENV['KAIROS_CONFIDENTIALITY_GUARD']
    ENV['KAIROS_CONFIDENTIALITY_GUARD'] = nil
    begin
      CG::Regime.ensure_activated!(registry_class: FakeRegistry) if activate_guard
      yield fake
    ensure
      ENV['KAIROS_CONFIDENTIALITY_GUARD'] = old_env
      CG::Regime.reset!
      CG::Recorder.chain_factory = nil
      CD::Recorder.chain_factory = nil
      CD::Distiller.registry_class = nil
      CD::Distiller.guard_regime = nil
      CD::Distiller.carrier = nil
      CD::Depositor.exchange = nil
      CD::Depositor.package_root = nil
      CD::Depositor.exposure_path = nil
      CD::CarrierWiring.registry = nil
      CG::Regime.skillset_root = File.expand_path('../../confidentiality_guard', __dir__)
    end
  end
end

# Slice-2 profile: the deposit crossing joins the enrolled distillation
# family (the production guard profile must designate it the same way).
# The crossing name is distinct from the cd_deposit TOOL name (impl R1).
DEPOSIT_PROFILE = DISTILL_PROFILE.merge(
  'distillation_crossings' => %w[cd_release_distillate cd_release_certificate cd_release_package]
).freeze

# In-memory carrier registry (the synoptis registry surface the wiring
# consumes: store_proof / find_proof / revoked? / store_revocation).
class FakeCarrierRegistry
  def initialize
    @proofs = {}
    @revocations = {}
  end
  def store_proof(envelope) = (@proofs[envelope.proof_id] = envelope).proof_id
  def find_proof(proof_id) = @proofs[proof_id]
  def revoked?(proof_id) = @revocations.key?(proof_id)
  def store_revocation(revocation) = @revocations[revocation[:proof_id] || revocation['proof_id']] = revocation
end

entries_of = ->(fake) {
  fake.blocks.each_with_object({}) do |b, acc|
    acc[b.index] = JSON.parse(b.data.first) rescue nil
  end.compact
}

DISTILLATE = { 'skill' => 'demo', 'body' => 'clean distilled content' }.freeze

# ---------------------------------------------------------------------------
# CD-1: no active regime -> decline, never a degraded uncertified mode; the
# refusal names no content.
with_stack(DISTILL_PROFILE, activate_guard: false) do |fake|
  before = fake.blocks.size
  begin
    CD::Distiller.distill(designation: [1, 2], distillate: DISTILLATE)
    assert(false, 'CD-1: distillation without active regime must decline')
  rescue CD::Distiller::Declined => e
    report = JSON.parse(e.message)
    assert(report['rule'] == 'cd-1/guard-regime-inactive', 'CD-1: decline names the rule')
    assert(!e.message.include?('distilled content'), 'CD-1: decline report carries no content')
  end
  assert(fake.blocks.size == before, 'CD-1: decline leaves no record and releases nothing')
end

# CD-1: distillate crossing denied by the guard -> abort before any CD-6
# record or certificate exists (verdict precedes effect).
with_stack(DISTILL_PROFILE) do |fake|
  assert_raises(KairosMcp::ToolRegistry::GateDeniedError,
                'CD-1: content-class hit on the distillate crossing denies') do
    CD::Distiller.distill(designation: [1, 2], distillate: { 'body' => SECRET })
  end
  entries = entries_of.call(fake)
  assert(entries.values.none? { |e| e['type'] == 'cd_distillation' },
         'CD-1/CD-6: denied crossing -> no distillation record written')
end

# CD-1: undesignated crossing (guard profile without distillation_crossings)
# denies — the guard's closed-world designation governs the distiller too.
with_stack(NO_CROSSING_PROFILE) do |_fake|
  assert_raises(KairosMcp::ToolRegistry::GateDeniedError,
                'CD-1: undesignated distillation crossing denied by the guard') do
    CD::Distiller.distill(designation: [1, 2], distillate: DISTILLATE)
  end
end

# ---------------------------------------------------------------------------
# CD-6: designation closed-world — empty, absent-record, non-integer, or
# genesis designations decline (decline-not-coerce, impl review R1).
with_stack(DISTILL_PROFILE) do |_fake|
  assert_raises(CD::Distiller::Declined, 'CD-6: empty designation declines') do
    CD::Distiller.distill(designation: [], distillate: DISTILLATE)
  end
  assert_raises(CD::Distiller::Declined, 'CD-6: designation naming absent records declines') do
    CD::Distiller.distill(designation: [999], distillate: DISTILLATE)
  end
  assert_raises(CD::Distiller::Declined, 'CD-6: float designation declines, never truncates') do
    CD::Distiller.distill(designation: [1.9], distillate: DISTILLATE)
  end
  assert_raises(CD::Distiller::Declined, 'CD-6: string designation declines, never parses') do
    CD::Distiller.distill(designation: ['2'], distillate: DISTILLATE)
  end
  assert_raises(CD::Distiller::Declined, 'CD-6: genesis (index 0) is not designable') do
    CD::Distiller.distill(designation: [0], distillate: DISTILLATE)
  end
end

# ---------------------------------------------------------------------------
# Full pipeline: ordering, record shape, certificate shape, verification.
with_stack(DISTILL_PROFILE) do |fake|
  crossings = []
  original = FakeRegistry.method(:run_gates)
  FakeRegistry.define_singleton_method(:run_gates) do |tool_name, arguments, safety = nil|
    crossings << tool_name
    original.call(tool_name, arguments, safety)
  end

  carrier_calls = []
  CD::Distiller.carrier = ->(**kw) { carrier_calls << kw }

  result = CD::Distiller.distill(designation: [3, 1], distillate: DISTILLATE)
  cert = result[:certificate]
  core = cert['claim_core']
  entries = entries_of.call(fake)
  record_index = result[:record_block_index]
  record = entries[record_index]

  # CD-1: two separate crossings, distillate first.
  assert(crossings == %w[cd_release_distillate cd_release_certificate],
         'CD-1: distillate and certificate cross separately, in that order')

  # CD-6: record written before the certificate crossing (the guard's pass
  # record for the certificate crossing sits at a higher index).
  cert_pass_index = entries.find { |_, e|
    e['type'] == 'cg_guard_decision' && e.dig('crossing', 'tool') == 'cd_release_certificate'
  }&.first
  assert(record['type'] == 'cd_distillation', 'CD-6: distillation record on the source chain')
  assert(cert_pass_index && record_index < cert_pass_index,
         'CD-6: record precedes the certificate release crossing')

  # CD-6: record carries designation, policy version, commitments, identity —
  # and the claim-core commitment covers the core EXCLUDING the citation.
  assert(record['designation'] == [1, 3], 'CD-6: record carries the sorted designation (identifiers only)')
  assert(record['guard_policy_sha256'] == CG::Regime.policy.sha256, 'CD-6: record pins the guard policy version')
  assert(record['certificate_identity'] == core['certificate_identity'],
         'CD-6: pre-assigned identity in record and core agree')
  assert(CD::Recorder.commitment_valid?(CD::Recorder::CLAIM_CORE_DOMAIN, record['claim_core_commitment'],
                                        cert['openings']['claim_core_salt'], CD::Canon.canonical(core)),
         'CD-6: claim-core commitment re-derives from the disclosed opening (no fixed point)')
  assert(!CD::Canon.canonical(core).include?(record_index.to_s) || !core.key?('record_citation'),
         'CD-6: claim core excludes the record citation')
  assert(cert['record_citation']['block_index'] == record_index,
         'CD-6: finalized certificate cites the record (later cites earlier)')

  # CD-2: distillate commitment opens against the released artifact.
  assert(CD::Recorder.commitment_valid?(CD::Recorder::ARTIFACT_DOMAIN,
                                        core.dig('derivation', 'distillate_commitment'),
                                        cert['openings']['distillate_salt'], result[:distillate_json]),
         'CD-2: distillate commitment re-derives from the disclosed opening')
  assert(cert['openings'].keys.sort == %w[claim_core_salt distillate_salt],
         'CD-2: openings only over the released artifacts')

  # CD-3: origin-only vocabulary and pinned status table.
  assert(core.keys.sort == CD::Certificate::CLAIM_CORE_KEYS.sort,
         'CD-3: claim-core vocabulary exactly the pinned set (no quality field)')
  assert(core['statuses'] == CD::Certificate::STATUS_TABLE,
         'CD-2: certificate carries exactly the pinned status table')

  # Carrier: pre-assigned content-independent identity injected as proof_id;
  # attester defaults to the skillset identifier (declared tool surface).
  assert(carrier_calls.size == 1 && carrier_calls.first[:proof_id] == core['certificate_identity'],
         'CD-6: carrier envelope keyed by the pre-assigned identity')
  assert(carrier_calls.first[:attester_id] == 'chain_distillation',
         'CD-6: carrier attester defaults to the skillset identifier (attester_id surface declared)')

  # Verification: full pass with chain access + distillate.
  v = CD::Certificate.verify(cert, chain_entries: entries_of.call(fake),
                             distillate_json: result[:distillate_json])
  assert(v[:valid] && v[:revoked] == false, 'CD-2/CD-6: verification passes (grounded, unrevoked)')

  # Grounding tamper: altered core fails the positive match.
  tampered = JSON.parse(JSON.generate(cert))
  tampered['claim_core']['derivation']['designation'] = [1]
  vt = CD::Certificate.verify(tampered, chain_entries: entries_of.call(fake))
  assert(!vt[:valid], 'CD-6: tampered claim core fails grounding')

  # Transplant: certificate re-attached to a different distillate fails.
  other_json = CD::Canon.canonical('skill' => 'other')
  vx = CD::Certificate.verify(cert, chain_entries: entries_of.call(fake), distillate_json: other_json)
  assert(!vx[:valid], 'CD-2: certificate transplant fails the commitment binding')

  # CD-2 mislabeling defect, both directions.
  up = JSON.parse(JSON.generate(cert))
  up['claim_core']['statuses']['drawn_from'] = 'checkable'
  assert(!CD::Certificate.verify(up)[:valid], 'CD-2: trusted-presented-as-checkable fails verification')
  down = JSON.parse(JSON.generate(cert))
  down['claim_core']['statuses']['identity.binding'] = 'trusted'
  assert(!CD::Certificate.verify(down)[:valid], 'CD-2: checkable-presented-as-trusted fails verification')

  # CD-3: a quality field cannot ride the vocabulary.
  q = JSON.parse(JSON.generate(cert))
  q['claim_core']['quality'] = 'excellent'
  assert(!CD::Certificate.verify(q)[:valid], 'CD-3: quality claim outside the vocabulary fails verification')

  FakeRegistry.define_singleton_method(:run_gates, original)
end

# ---------------------------------------------------------------------------
# CD-6: revocation keyed to the identity; designation-overlap re-issuance
# citation obligation (evaluated at issuance, robust to output variation).
with_stack(DISTILL_PROFILE) do |fake|
  first = CD::Distiller.distill(designation: [1, 2], distillate: DISTILLATE)
  identity = first[:certificate]['claim_core']['certificate_identity']
  assert_raises(ArgumentError, 'CD-5: free-text revocation reason rejected (closed vocabulary)') do
    CD::Recorder.record_revocation(certificate_identity: identity, reason: 'because I felt like it')
  end
  CD::Recorder.record_revocation(certificate_identity: identity, reason: 'defective')

  v = CD::Certificate.verify(first[:certificate], chain_entries: entries_of.call(fake))
  assert(v[:revoked] == true, 'CD-6: revocation keyed to the certificate identity is visible chain-wide')
  assert(!v[:valid] && v[:errors].include?('revocation/revoked'),
         'CD-6: a revoked certificate does not verify (valid: false)')

  # Re-distillation with overlapping designation and a VARIED output: the
  # obligation fires regardless of the distillate commitment.
  second = CD::Distiller.distill(designation: [2, 4], distillate: { 'skill' => 'demo', 'body' => 'varied' })
  cited = second[:certificate]['claim_core']['predecessors']
  assert(cited.include?(identity),
         'CD-6: overlapping re-issuance cites the revoked predecessor (designation-keyed)')
  v2 = CD::Certificate.verify(second[:certificate], chain_entries: entries_of.call(fake))
  assert(v2[:valid], 'CD-6: citing re-issuance verifies')

  # A certificate omitting the required predecessor is defective.
  stripped = JSON.parse(JSON.generate(second[:certificate]))
  stripped['claim_core']['predecessors'] = []
  vs = CD::Certificate.verify(stripped, chain_entries: entries_of.call(fake))
  assert(!vs[:valid] || vs[:errors].any? { |e| e.start_with?('reissuance/') } || !vs[:valid],
         'CD-6: omitted predecessor citation is a defect')
  assert(!vs[:valid], 'CD-6: defective re-issuance fails verification')

  # Disjoint designation: no obligation (severs the origin claim instead).
  third = CD::Distiller.distill(designation: [3], distillate: DISTILLATE)
  assert(third[:certificate]['claim_core']['predecessors'].empty?,
         'CD-6: disjoint designation carries no predecessor obligation')
end

# ---------------------------------------------------------------------------
# CD-6: identity claims ground in the chain (identity family checkable as
# record-and-anchor bindings); the certificate-crossing verdict record
# cites the certificate identity (CD-1).
with_stack(DISTILL_PROFILE) do |fake|
  result = CD::Distiller.distill(designation: [1, 2], distillate: DISTILLATE)
  core = result[:certificate]['claim_core']
  assert(core.dig('identity', 'chain_identity') == "block1-sha256:#{fake.blocks.first.hash}",
         'CD-6: chain identity binds the genesis block hash (khab-1 form)')
  assert(core.dig('derivation', 'verdict_block_indices').all? { |i|
           entries_of.call(fake)[i] && entries_of.call(fake)[i]['type'] == 'cg_guard_decision'
         }, 'CD-1: cited verdict records exist on the chain and are guard decisions')

  cert_verdict = entries_of.call(fake).values.find { |e|
    e['type'] == 'cg_guard_decision' && e.dig('crossing', 'tool') == 'cd_release_certificate'
  }
  assert(cert_verdict && cert_verdict.dig('crossing', 'certificate_identity') == core['certificate_identity'],
         "CD-1: the certificate's release verdict record cites the certificate identity")

  # Identity-binding checks with block hashes (identity.binding checkable).
  hashes = fake.blocks.each_with_object({}) { |b, acc| acc[b.index] = b.hash }
  ok = CD::Certificate.verify(result[:certificate], chain_entries: entries_of.call(fake),
                              chain_hashes: hashes)
  assert(ok[:valid], 'CD-2: identity binding checks pass with chain hashes')
  tampered = JSON.parse(JSON.generate(result[:certificate]))
  tampered['claim_core']['identity']['chain_head_hash'] = 'deadbeef'
  bad = CD::Certificate.verify(tampered, chain_entries: entries_of.call(fake), chain_hashes: hashes)
  assert(!bad[:valid] && bad[:errors].any? { |e| e.start_with?('identity/') || e.start_with?('grounding/') },
         'CD-2: tampered head binding fails the checkable identity claim')

  # Full-citation grounding: a certificate stripped of the block hash must
  # not verify with chain access (impl review R3).
  stripped_hash = JSON.parse(JSON.generate(result[:certificate]))
  stripped_hash['record_citation'].delete('block_hash')
  vh = CD::Certificate.verify(stripped_hash, chain_entries: entries_of.call(fake), chain_hashes: hashes)
  assert(!vh[:valid] && vh[:errors].include?('grounding/no-block-hash'),
         'CD-2: missing citation block hash is a grounding defect, not optional')

  # CD-3 holds at every depth: the span sub-mapping is closed too.
  spanq = JSON.parse(JSON.generate(result[:certificate]))
  spanq['claim_core']['derivation']['span']['quality'] = 'excellent'
  vq = CD::Certificate.verify(spanq)
  assert(!vq[:valid], 'CD-3: quality claim inside span fails verification (closed at depth)')
end

# ---------------------------------------------------------------------------
# Verifier robustness (impl review R1): malformed inputs are invalid, never
# exceptions; nested vocabulary is closed; a supplied distillate without an
# opening is a defect.
with_stack(DISTILL_PROFILE) do |fake|
  [nil, 42, [1, 2], 'x'].each do |bad|
    v = CD::Certificate.verify(bad)
    assert(v[:valid] == false, "CD-2: verify(#{bad.class}) is invalid, not an exception")
  end
  result = CD::Distiller.distill(designation: [1, 2], distillate: DISTILLATE)
  nested = JSON.parse(JSON.generate(result[:certificate]))
  nested['claim_core']['identity']['reputation'] = 'excellent'
  vn = CD::Certificate.verify(nested)
  assert(!vn[:valid], 'CD-3: nested unknown key fails verification (closed nested vocabulary)')
  stripped = JSON.parse(JSON.generate(result[:certificate]))
  stripped['openings'].delete('distillate_salt')
  vd = CD::Certificate.verify(stripped, distillate_json: result[:distillate_json])
  assert(!vd[:valid] && vd[:errors].include?('distillate/no-opening'),
         'CD-2: supplied distillate without an opening is a defect, not a silent pass')
end

# ---------------------------------------------------------------------------
# Real-chain contract pin (impl review R1 P0): the distiller must work
# against the REAL KairosMcp::KairosChain::Chain API (attr_reader :chain),
# not only the test fake.
require_relative '../../../../lib/kairos_mcp/kairos_chain/chain'
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
             { 'guard' => { 'enabled' => true, 'profile' => 'profile.yml' } }.to_yaml)
  File.write(File.join(root, 'config', 'profile.yml'), DISTILL_PROFILE.to_yaml)
  # Isolate persistence: Chain#initialize does not use chain_file: for
  # storage — the backend resolves KAIROS_DATA_DIR (else CWD/.kairos), and
  # a real test chain must NEVER append to a live constitutive store
  # (impl review R2). PRODUCTION WIRING: no chain factories are injected —
  # both Recorders construct their own real Chain instances per call, the
  # exact seam whose divergence destroyed the distillate verdict record in
  # impl review R3 (memoized stale instance + whole-store-rewrite
  # persistence).
  old_data_dir = ENV['KAIROS_DATA_DIR']
  ENV['KAIROS_DATA_DIR'] = File.join(root, '.kairos')
  seeder = KairosMcp::KairosChain::Chain.new
  3.times { |i| seeder.add_block([JSON.generate('type' => 'seed', 'n' => i)]) }
  CG::Regime.skillset_root = root
  FakeRegistry.clear!
  CD::Distiller.registry_class = FakeRegistry
  CD::Distiller.guard_regime = CG::Regime
  begin
    CG::Regime.ensure_activated!(registry_class: FakeRegistry)
    assert(CD::Distiller.chain_height >= 3, 'real-chain: height read through Chain#chain')
    result = CD::Distiller.distill(designation: [1, 3], distillate: DISTILLATE)
    assert(result[:certificate].is_a?(Hash), 'real-chain: distillation succeeds against the real Chain API')
    v = CD::Certificate.verify(result[:certificate],
                               chain_entries: CD::Distiller.chain_entries,
                               chain_hashes: CD::Distiller.chain_block_hashes,
                               distillate_json: result[:distillate_json])
    assert(v[:valid], "real-chain: certificate verifies with grounding and identity binding (#{v[:errors].join('; ')})")
    reloaded = KairosMcp::KairosChain::Chain.new
    assert(CD::Distiller.chain_identity == "block1-sha256:#{reloaded.chain.first.hash}",
           'real-chain: chain identity binds the real genesis hash (String, never Object#hash)')
    # Production-wiring regression (impl review R3 P0): BOTH guard verdict
    # records must survive on the reloaded store — the distillate-crossing
    # verdict must not be clobbered by the CD-6 append — and the
    # certificate's verdict citation must point at a surviving guard
    # decision.
    persisted = reloaded.chain.each_with_object({}) do |blk, acc|
      first = Array(blk.data).first
      acc[blk.index] = (JSON.parse(first) rescue nil) if first.is_a?(String)
    end.compact
    decisions = persisted.values.select { |e| e['type'] == 'cg_guard_decision' }
    assert(decisions.size >= 2,
           "real-chain: both crossing verdict records persisted (got #{decisions.size})")
    cited = result[:certificate].dig('claim_core', 'derivation', 'verdict_block_indices')
    assert(!cited.empty? && cited.all? { |i| persisted[i] && persisted[i]['type'] == 'cg_guard_decision' },
           'real-chain: cited verdict records survive on the persisted store')
    # Structured-distillate content detection (impl review R3 P1): a
    # JSON-keyed secret must be caught single-encoded, not escape via
    # double encoding.
    begin
      CD::Distiller.distill(designation: [1], distillate: { 'api_key' => 'SUPER-SECRET-999' })
      assert(false, 'real-chain: structured secret distillate must be denied at the crossing')
    rescue KairosMcp::ToolRegistry::GateDeniedError
      assert(true, 'real-chain: structured secret distillate denied (single-encoded detection)')
    end
  ensure
    ENV['KAIROS_DATA_DIR'] = old_data_dir
    CG::Regime.reset!
    CG::Recorder.chain_factory = nil
    CD::Recorder.chain_factory = nil
    CD::Distiller.registry_class = nil
    CD::Distiller.guard_regime = nil
    CD::Distiller.carrier = nil
    CG::Regime.skillset_root = File.expand_path('../../confidentiality_guard', __dir__)
  end
end

# ===========================================================================
# SLICE 2 (design v0.4 FROZEN, CD-7..CD-11): distribution.
# ===========================================================================

# Helper: a full distill under the deposit-enrolled profile, returning the
# artifacts a depositor holds.
def distill_for_deposit
  r = CD::Distiller.distill(designation: [1, 2], distillate: DISTILLATE)
  [r[:certificate], r[:distillate_json], r[:certificate]['claim_core']['certificate_identity']]
end

def fresh_deposit_seams(root)
  CD::Depositor.package_root = File.join(root, 'pkgs')
  CD::Depositor.exposure_path = File.join(root, 'exposure.json')
  reg = FakeCarrierRegistry.new
  CD::CarrierWiring.registry = reg
  reg
end

# ---------------------------------------------------------------------------
# CD-9/CD-1 register: no active regime -> deposit declines, never degrades.
with_stack(DEPOSIT_PROFILE, activate_guard: false) do |_fake|
  begin
    CD::Depositor.deposit(certificate: {}, distillate_json: '{}', skillset_name: 'demo_pack')
    assert(false, 'CD-9: deposit without active regime must decline')
  rescue CD::Distiller::Declined => e
    assert(JSON.parse(e.message)['rule'] == 'cd-9/guard-regime-inactive',
           'CD-9: regime-inactive decline names the rule')
  end
end

# ---------------------------------------------------------------------------
# CD-7/CD-8/CD-9 happy path: crossing order, package constituents, exposure.
with_stack(DEPOSIT_PROFILE) do |fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    exchange_calls = []
    CD::Depositor.exchange = ->(name) { exchange_calls << name; { status: 'listed' } }

    crossings = []
    original = FakeRegistry.method(:run_gates)
    FakeRegistry.define_singleton_method(:run_gates) do |tool_name, arguments, safety = nil|
      crossings << tool_name
      original.call(tool_name, arguments, safety)
    end

    cert, djson, identity = distill_for_deposit
    assert(!CD::Depositor.exposed?(identity),
           'CD-8: no exposure before deposit approval (issuance alone exposes nothing)')

    result = CD::Depositor.deposit(certificate: cert, distillate_json: djson,
                                   skillset_name: 'demo_pack')
    assert(result[:status] == 'deposited', 'CD-9: admitted deposit completes')
    assert(crossings.include?('cd_release_package'),
           'CD-9: the deposit rides its own guard-judged crossing (distinct from the tool name)')
    assert(!crossings.include?('cd_deposit'),
           'CD-9: the tool name itself is never a judged crossing (no double judgment)')

    # CD-7: SkillSet layout with the certificate a mandatory constituent.
    dir = result[:package_path]
    assert(File.exist?(File.join(dir, 'skillset.json')), 'CD-7: package carries skillset.json')
    assert(File.exist?(File.join(dir, 'knowledge', 'demo_pack.json')),
           'CD-7: package carries the distillate as knowledge content')
    cert_file = File.join(dir, 'certificate.json')
    assert(File.exist?(cert_file), 'CD-7: certificate.json is a package constituent (BL-S2-6)')
    assert(JSON.parse(File.read(cert_file)) == JSON.parse(JSON.generate(cert)),
           'CD-7: the packaged certificate is the issued certificate, byte-equal as JSON')
    assert(File.read(File.join(dir, 'knowledge', 'demo_pack.json')) == djson,
           'CD-7: the packaged distillate is the certified distillate string')

    # BL-S2-1: exchange consumed unchanged through the delegate seam.
    assert(exchange_calls == ['demo_pack'], 'BL-S2-1: exchange delegate called once with the package name')

    # CD-8: exposure marker exists only after approval + listing.
    assert(CD::Depositor.exposed?(identity), 'CD-8: exposure begins at deposit approval')

    # The deposit verdict record cites the certificate identity (CD-1
    # discipline carried to the deposit crossing).
    entries = fake.blocks.each_with_object({}) { |b, acc|
      acc[b.index] = (JSON.parse(b.data.first) rescue nil)
    }.compact
    dep_verdict = entries.values.find { |e|
      e['type'] == 'cg_guard_decision' && e.dig('crossing', 'tool') == 'cd_release_package'
    }
    assert(dep_verdict && dep_verdict.dig('crossing', 'certificate_identity') == identity,
           'CD-9: deposit verdict record cites the certificate identity')

    FakeRegistry.define_singleton_method(:run_gates, original)
  end
end

# ---------------------------------------------------------------------------
# CD-9 admission: binding mismatch declines; nothing presents as certified
# without surviving the binding check. Verdict precedes effect: no package,
# no exchange call, no exposure on any decline.
with_stack(DEPOSIT_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    exchange_calls = []
    CD::Depositor.exchange = ->(name) { exchange_calls << name; { status: 'listed' } }
    cert, _djson, identity = distill_for_deposit
    other = CD::Canon.canonical('skill' => 'not-the-certified-content')
    begin
      CD::Depositor.deposit(certificate: cert, distillate_json: other, skillset_name: 'demo_pack')
      assert(false, 'CD-9: binding mismatch must decline')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-9/binding-or-verification-failure',
             'CD-9: binding mismatch names the rule')
    end
    assert(!Dir.exist?(File.join(root, 'pkgs', 'demo_pack')),
           'CD-9: declined deposit materializes no package')
    assert(exchange_calls.empty?, 'CD-9: declined deposit never reaches the exchange')
    assert(!CD::Depositor.exposed?(identity), 'CD-8: declined deposit exposes nothing')
  end
end

# ---------------------------------------------------------------------------
# CD-9: undesignated deposit crossing (slice-1 profile without cd_deposit)
# denies at the guard — verdict precedes every effect (Scenario C).
with_stack(DISTILL_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    exchange_calls = []
    CD::Depositor.exchange = ->(name) { exchange_calls << name; { status: 'listed' } }
    cert, djson, identity = distill_for_deposit
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError,
                  'CD-9: undesignated deposit crossing denied by the guard') do
      CD::Depositor.deposit(certificate: cert, distillate_json: djson, skillset_name: 'demo_pack')
    end
    assert(!Dir.exist?(File.join(root, 'pkgs', 'demo_pack')),
           'CD-9/Scenario C: denied crossing leaves no package')
    assert(exchange_calls.empty?, 'CD-9/Scenario C: denied crossing leaves no listing call')
    assert(!CD::Depositor.exposed?(identity),
           'CD-8/Scenario C: denied crossing leaves the carrier unexposed')
  end
end

# ---------------------------------------------------------------------------
# CD-9: revoked-at-judgment (source-local) declines; the trusted-claim
# register excuses remote unobservability, never local non-checking.
with_stack(DEPOSIT_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    CD::Depositor.exchange = ->(_name) { { status: 'listed' } }
    cert, djson, identity = distill_for_deposit
    CD::Recorder.record_revocation(certificate_identity: identity, reason: 'defective')
    begin
      CD::Depositor.deposit(certificate: cert, distillate_json: djson, skillset_name: 'demo_pack')
      assert(false, 'CD-9: revoked certificate must not distribute from its source instance')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-9/revoked-at-judgment',
             'CD-9: revoked-at-judgment names the rule')
    end
  end
end

# ---------------------------------------------------------------------------
# CD-9: third-party depositor (certificate names another source chain) —
# the revocation clause binds vacuously; certificate-local checks still
# gate admission (disclosed residual, CD-11).
with_stack(DEPOSIT_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    CD::Depositor.exchange = ->(_name) { { status: 'listed' } }
    cert, djson, _identity = distill_for_deposit
    # A GENUINELY foreign certificate: its identity has no cd_distillation
    # record on this chain (locality is identity-keyed — a mere
    # chain_identity edit on a locally issued certificate now gets FULL
    # local grounding and fails, see the grounding-evasion test below).
    foreign = JSON.parse(JSON.generate(cert))
    foreign['claim_core']['certificate_identity'] = 'f0e1d2c3-0000-4000-8000-feedfacefeed'
    foreign['claim_core']['identity']['chain_identity'] = 'block1-sha256:feedfacefeedface'
    result = CD::Depositor.deposit(certificate: foreign, distillate_json: djson,
                                   skillset_name: 'foreign_pack')
    assert(result[:status] == 'deposited',
           'CD-9: third-party re-deposit admits vacuously (revocation not locally decidable — disclosed residual)')
    # A coincidental LOCAL revocation record for the foreign identity does
    # not veto the vacuous case: the decline binds only where this chain
    # ISSUED the identity (CD-6 chain scoping; impl review R3 (b)).
    CD::Recorder.record_revocation(certificate_identity: foreign['claim_core']['certificate_identity'],
                                   reason: 'other')
    again = CD::Depositor.deposit(certificate: foreign, distillate_json: djson,
                                  skillset_name: 'foreign_pack')
    assert(again[:status] == 'deposited',
           'CD-9: locally revoking a never-issued foreign identity does not veto the vacuous lane')
    # No local SHADOW carrier for foreign certificates (impl review R6
    # (b)): their mirror form is the source chain's carrier (BL-S2-7).
    assert(CD::CarrierWiring.registry.find_proof(foreign['claim_core']['certificate_identity']).nil?,
           'CD-8: third-party deposit mints no local carrier envelope')
    # But a third-party package failing the binding check still declines.
    begin
      CD::Depositor.deposit(certificate: foreign, distillate_json: '{"x":1}', skillset_name: 'foreign_pack')
      assert(false, 'CD-9: third-party binding mismatch must still decline')
    rescue CD::Distiller::Declined
      assert(true, 'CD-9: third-party binding mismatch declines')
    end
  end
end

# ---------------------------------------------------------------------------
# CD-7 name-collision guard (impl review R3 (a)): the package root is the
# live skillsets directory — a deposit must never overwrite an existing
# SkillSet that is not this certificate's own prior package; re-deposit of
# the same certificate over its own package remains allowed.
with_stack(DEPOSIT_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    CD::Depositor.exchange = ->(_name) { { status: 'listed' } }
    cert, djson, _identity = distill_for_deposit
    occupied = File.join(root, 'pkgs', 'occupied_pack')
    FileUtils.mkdir_p(occupied)
    File.write(File.join(occupied, 'skillset.json'), '{"name":"occupied_pack"}')
    begin
      CD::Depositor.deposit(certificate: cert, distillate_json: djson, skillset_name: 'occupied_pack')
      assert(false, 'CD-7: deposit over a foreign existing SkillSet must decline')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-7/package-name-collision',
             'CD-7: name collision names the rule')
    end
    assert(File.read(File.join(occupied, 'skillset.json')) == '{"name":"occupied_pack"}',
           'CD-7: the existing SkillSet is untouched by the declined deposit')
    # Same-certificate re-deposit over its own package is allowed.
    ok1 = CD::Depositor.deposit(certificate: cert, distillate_json: djson, skillset_name: 'own_pack')
    assert(ok1[:status] == 'deposited', 'CD-7: first deposit succeeds')
    ok2 = CD::Depositor.deposit(certificate: cert, distillate_json: djson, skillset_name: 'own_pack')
    assert(ok2[:status] == 'deposited', 'CD-7: re-deposit over own package allowed (append-honest)')
  end
end

# ---------------------------------------------------------------------------
# CD-8 carrier wiring: the envelope is written at issuance with the injected
# content-independent proof_id (slice-2 wiring of the slice-1 seam).
with_stack(DEPOSIT_PROFILE) do |_fake|
  stored = []
  fake_registry = Object.new
  fake_registry.define_singleton_method(:store_proof) { |env| stored << env; env.proof_id }
  # Load the real synoptis envelope for the wiring path.
  begin
    require_relative '../../synoptis/lib/synoptis/proof_envelope'
    wired = CD::CarrierWiring.wire!(registry: fake_registry)
    assert(wired, 'CD-8: carrier wiring succeeds with a registry')
    cert, _djson, identity = distill_for_deposit
    assert(stored.size == 1 && stored.first.proof_id == identity,
           'CD-8/CD-6: carrier envelope keyed by the injected pre-assigned identity')
    assert(JSON.parse(stored.first.claim)['claim_core']['certificate_identity'] == identity,
           'CD-8: the carried claim is the certificate itself (identity round-trips)')
    assert(stored.first.ttl.nil?,
           'CD-8: carrier envelope does not expire on its own — revocation state is chain-authoritative (CD-6)')
    _ = cert
  rescue LoadError
    assert(true, 'CD-8: synoptis not present in this checkout — wiring degrades to unwired (disclosed)')
  end
end

# ---------------------------------------------------------------------------
# CD-11 end to end: deposit -> acquire (copy) -> verify valid -> revoke ->
# re-deposit declines and verification reports revoked; the revocation
# response carries the listing duty (BL-S2-8 withdrawal route).
with_stack(DEPOSIT_PROFILE) do |fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    CD::Depositor.exchange = ->(_name) { { status: 'listed' } }
    cert, djson, identity = distill_for_deposit
    result = CD::Depositor.deposit(certificate: cert, distillate_json: djson,
                                   skillset_name: 'e2e_pack')
    assert(result[:status] == 'deposited', 'CD-11 e2e: deposit succeeds')

    # Simulated acquisition: the acquirer holds the package constituents.
    acquired_cert = JSON.parse(File.read(File.join(result[:package_path], 'certificate.json')))
    acquired_json = File.read(File.join(result[:package_path], 'knowledge', 'e2e_pack.json'))

    v1 = CD::Certificate.verify(acquired_cert, chain_entries: entries_of.call(fake),
                                distillate_json: acquired_json)
    assert(v1[:valid] && v1[:revoked] == false, 'CD-11 e2e: acquired package verifies before revocation')

    CD::Recorder.record_revocation(certificate_identity: identity, reason: 'withdrawn')

    v2 = CD::Certificate.verify(acquired_cert, chain_entries: entries_of.call(fake),
                                distillate_json: acquired_json)
    assert(v2[:revoked] == true && !v2[:valid],
           'CD-11 e2e: a re-checking holder with chain access observes the revocation')

    # Offline snapshot alone: the frozen in-package copy still verifies
    # chain-less — the disclosed residual, not a failure (CD-8).
    v3 = CD::Certificate.verify(acquired_cert, distillate_json: acquired_json)
    assert(v3[:valid] && v3[:revoked].nil?,
           'CD-8: the snapshot alone verifies at acquisition-time semantics (disclosed residual)')

    # Re-deposit of the revoked certificate declines at the source.
    begin
      CD::Depositor.deposit(certificate: cert, distillate_json: djson, skillset_name: 'e2e_pack')
      assert(false, 'CD-11 e2e: revoked re-deposit must decline')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-9/revoked-at-judgment',
             'CD-11 e2e: revoked re-deposit names the rule')
    end

    # CD-9 anti-spoof (impl review R1 (a)): editing the certificate's
    # chain_identity claim must NOT dodge the identity-keyed local
    # revocation scan — the scan is unconditional.
    spoofed = JSON.parse(JSON.generate(cert))
    spoofed['claim_core']['identity']['chain_identity'] = 'block1-sha256:spoofed'
    begin
      CD::Depositor.deposit(certificate: spoofed, distillate_json: djson, skillset_name: 'e2e_pack')
      assert(false, 'CD-9: chain-identity spoof must not evade the revocation scan')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-9/revoked-at-judgment',
             'CD-9: spoofed identity still declines revoked-at-judgment (identity-keyed, unconditional)')
    end

    # Re-identity bypass closed (impl review R4 (a)): relabeling the
    # revoked certificate under a fresh identity must not shed the
    # revocation — the commitment-keyed scan binds the CONTENT.
    relabeled = JSON.parse(JSON.generate(cert))
    relabeled['claim_core']['certificate_identity'] = '99999999-0000-4000-8000-relabeledid1'
    relabeled['claim_core']['identity']['chain_identity'] = 'block1-sha256:elsewhere'
    begin
      CD::Depositor.deposit(certificate: relabeled, distillate_json: djson, skillset_name: 'e2e_pack')
      assert(false, 'CD-9: relabeled revoked certificate must decline (commitment-keyed)')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-9/revoked-at-judgment',
             'CD-9: commitment-keyed revocation scan catches the relabeled identity')
    end
    # Relabeled identity that still names THIS chain: grounding is forced
    # (chain-identity locality) and the missing record fails it.
    relabeled_local = JSON.parse(JSON.generate(cert))
    relabeled_local['claim_core']['certificate_identity'] = '99999999-0000-4000-8000-relabeledid2'
    begin
      CD::Depositor.deposit(certificate: relabeled_local, distillate_json: djson, skillset_name: 'e2e_pack')
      assert(false, 'CD-9: relabeled identity naming this chain must decline')
    rescue CD::Distiller::Declined => e
      rule = JSON.parse(e.message)['rule']
      assert(%w[cd-9/revoked-at-judgment cd-9/binding-or-verification-failure].include?(rule),
             "CD-9: relabeled local-claiming certificate declines (#{rule})")
    end

    # CD-6/CD-11 mirror: the carrier mirrors the chain-side revocation
    # (never the reverse) and a carrier-side query reports revoked.
    reg = CD::CarrierWiring.registry
    mirror = CD::CarrierWiring.mirror_revocation(identity, 'withdrawn')
    assert(mirror['status'] == 'revoked', "CD-11: carrier mirror succeeds (got #{mirror})")
    assert(reg.revoked?(identity), 'CD-11: carrier registry reports revoked after the mirror')
  end
end

# ---------------------------------------------------------------------------
# CD-8: no reachable carrier -> deposit declines (mirror form mandatory for
# distribution; in-instance distillation stays slice-1-compatible).
with_stack(DEPOSIT_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    CD::CarrierWiring.registry = false
    CD::Depositor.exchange = ->(_name) { { status: 'listed' } }
    cert, djson, _identity = distill_for_deposit
    begin
      CD::Depositor.deposit(certificate: cert, distillate_json: djson, skillset_name: 'demo_pack')
      assert(false, 'CD-8: deposit without a reachable carrier must decline')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-8/carrier-unavailable',
             'CD-8: carrier-unavailable decline names the rule')
    end
  end
end

# ---------------------------------------------------------------------------
# CD-8 exposure-store integrity (impl review R1 (a)): a corrupt store is
# quarantined and declines loudly BEFORE any effect — never silently
# reinitialized (prior exposure records must not vanish).
with_stack(DEPOSIT_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    CD::Depositor.exchange = ->(_name) { { status: 'listed' } }
    exchange_calls = 0
    CD::Depositor.exchange = ->(_name) { exchange_calls += 1; { status: 'listed' } }
    cert, djson, identity = distill_for_deposit
    first = CD::Depositor.deposit(certificate: cert, distillate_json: djson, skillset_name: 'pack_one')
    assert(first[:status] == 'deposited', 'CD-8: first deposit succeeds')
    File.write(File.join(root, 'exposure.json'), '{not valid json!!')
    calls_before = exchange_calls
    second = CD::Distiller.distill(designation: [3], distillate: { 'skill' => 'two' })
    begin
      CD::Depositor.deposit(certificate: second[:certificate],
                            distillate_json: second[:distillate_json], skillset_name: 'pack_two')
      assert(false, 'CD-8: corrupt exposure store must decline')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-8/exposure-store-corrupt',
             'CD-8: corrupt store names the rule')
    end
    assert(exchange_calls == calls_before, 'CD-8: corrupt store declines before the exchange leg')
    assert(!Dir.exist?(File.join(root, 'pkgs', 'pack_two')), 'CD-8: corrupt store declines before packaging')
    # The corrupt file is left EXACTLY as found (read-only admission —
    # impl review R4: not even a forensic copy is written pre-verdict),
    # and the next deposit keeps declining, never a fresh empty ledger
    # (impl review R2 (a)).
    assert(File.read(File.join(root, 'exposure.json')) == '{not valid json!!',
           'CD-8: corrupt store preserved byte-identical (admission is read-only)')
    begin
      CD::Depositor.deposit(certificate: second[:certificate],
                            distillate_json: second[:distillate_json], skillset_name: 'pack_three')
      assert(false, 'CD-8: deposits keep declining while the store is corrupt')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-8/exposure-store-corrupt',
             'CD-8: subsequent deposit still declines on the corrupt store')
    end
    _ = identity
  end
end

# ---------------------------------------------------------------------------
# CD-9/CG-3: the deposit crossing judges the CERTIFICATE content too — a
# secret smuggled into a certificate field (with a spoofed foreign chain
# identity, so chainless verification cannot catch the tamper) must be
# denied at the crossing, never ride out inside certificate.json (impl
# review R2 (a)).
with_stack(DEPOSIT_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    exchange_calls = []
    CD::Depositor.exchange = ->(name) { exchange_calls << name; { status: 'listed' } }
    cert, djson, _identity = distill_for_deposit
    smuggled = JSON.parse(JSON.generate(cert))
    smuggled['claim_core']['certificate_identity'] = 'ab12cd34-0000-4000-8000-smuggleident'
    smuggled['claim_core']['identity']['chain_identity'] = "block1-sha256:feedface #{SECRET}"
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError,
                  'CD-9: secret inside a certificate field is denied at the deposit crossing') do
      CD::Depositor.deposit(certificate: smuggled, distillate_json: djson, skillset_name: 'smuggle_pack')
    end
    assert(!Dir.exist?(File.join(root, 'pkgs', 'smuggle_pack')),
           'CD-9: denied certificate-content crossing leaves no package')
    assert(exchange_calls.empty?, 'CD-9: denied certificate-content crossing never reaches the exchange')

    # Secret in the caller's DESCRIPTION is judged at the crossing too
    # (impl review R3 — the description lands in the packaged manifest).
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError,
                  'CD-9: secret inside the listing description is denied at the deposit crossing') do
      CD::Depositor.deposit(certificate: cert, distillate_json: djson,
                            skillset_name: 'desc_pack', description: "great skills #{SECRET}")
    end
    assert(!Dir.exist?(File.join(root, 'pkgs', 'desc_pack')),
           'CD-9: denied description crossing leaves no package')

    # Grounding evasion closed (impl review R3 (b)): a LOCALLY ISSUED
    # certificate whose chain_identity is edited to a foreign value keeps
    # its identity-keyed locality — full grounding runs and the tamper
    # declines; the mutable claim cannot buy the vacuous lane.
    evader = JSON.parse(JSON.generate(cert))
    evader['claim_core']['identity']['chain_identity'] = 'block1-sha256:feedfacefeedface'
    begin
      CD::Depositor.deposit(certificate: evader, distillate_json: djson, skillset_name: 'evade_pack')
      assert(false, 'CD-9: locally issued certificate with edited chain_identity must decline')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-9/binding-or-verification-failure',
             'CD-9: identity-keyed locality forces full grounding on the tampered local certificate')
    end
  end
end

# ---------------------------------------------------------------------------
# Deposit-crossing content judgment: content classes govern the deposit
# crossing like any distillation crossing (CG-3 conjunctive coverage) — a
# certificate over secret-bearing content can exist only if the release
# crossings were somehow passed, but the deposit crossing still judges the
# presented content independently.
with_stack(DEPOSIT_PROFILE) do |_fake|
  Dir.mktmpdir do |root|
    fresh_deposit_seams(root)
    CD::Depositor.exchange = ->(_name) { { status: 'listed' } }
    cert, djson, _identity = distill_for_deposit
    # Tamper the distillate to smuggle a secret AND recompute nothing:
    # binding fails first (the certificate refuses the content); this pins
    # that the secret path cannot even reach the crossing bound to a
    # mismatched certificate.
    secret_json = CD::Canon.canonical('body' => SECRET)
    begin
      CD::Depositor.deposit(certificate: cert, distillate_json: secret_json, skillset_name: 'demo_pack')
      assert(false, 'CD-9: secret content under a mismatched certificate declines (binding first)')
    rescue CD::Distiller::Declined
      assert(true, 'CD-9: secret content under a mismatched certificate declines at binding')
    end
    _ = djson
  end
end

# ---------------------------------------------------------------------------
# Production-wiring regression (slice 2): REAL Chain, REAL regime gate, real
# path resolution for package root and exposure store via KAIROS_DATA_DIR;
# the exchange delegate is injected ONLY at the network boundary (the seam
# the design names in BL-S2-1).
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
             { 'guard' => { 'enabled' => true, 'profile' => 'profile.yml' } }.to_yaml)
  File.write(File.join(root, 'config', 'profile.yml'), DEPOSIT_PROFILE.to_yaml)
  old_data_dir = ENV['KAIROS_DATA_DIR']
  ENV['KAIROS_DATA_DIR'] = File.join(root, '.kairos')
  # KairosMcp.data_dir memoizes at boot in production; pin it here exactly
  # as a freshly booted server would resolve it, so the Depositor's real
  # default paths are exercised against THIS root (not a stale memo from an
  # earlier test section).
  KairosMcp.data_dir = File.join(root, '.kairos') if KairosMcp.respond_to?(:data_dir=)
  seeder = KairosMcp::KairosChain::Chain.new
  3.times { |i| seeder.add_block([JSON.generate('type' => 'seed', 'n' => i)]) }
  CG::Regime.skillset_root = root
  FakeRegistry.clear!
  CD::Distiller.registry_class = FakeRegistry
  CD::Distiller.guard_regime = CG::Regime
  exchange_calls = []
  CD::Depositor.exchange = ->(name) { exchange_calls << name; { status: 'listed' } }
  begin
    CG::Regime.ensure_activated!(registry_class: FakeRegistry)
    # REAL carrier wiring (impl review R1 (a)): the default registry under
    # the real data dir, wired BEFORE issuance exactly as cd_distill does —
    # the envelope must be persisted for the issued identity, or the CD-8
    # channel is dead in production while every isolated test passes.
    carrier_wired = CD::CarrierWiring.wire!
    result = CD::Distiller.distill(designation: [1, 3], distillate: DISTILLATE)
    cert = result[:certificate]
    identity = cert['claim_core']['certificate_identity']
    if carrier_wired
      reg = Synoptis::Registry::FileRegistry.new(
        data_dir: File.join(root, '.kairos', 'synoptis_data')
      )
      envelope = reg.find_proof(identity)
      assert(!envelope.nil?, 'real-chain: carrier envelope persisted at issuance (CD-8 channel live)')
      assert(envelope && JSON.parse(envelope.claim)['claim_core']['certificate_identity'] == identity,
             'real-chain: persisted envelope carries the certificate keyed by its identity')
    else
      assert(false, 'real-chain: carrier wiring must succeed in this checkout (synoptis present)')
    end
    dep = CD::Depositor.deposit(certificate: cert, distillate_json: result[:distillate_json],
                                skillset_name: 'prod_pack')
    assert(dep[:status] == 'deposited', 'real-chain: deposit succeeds under the real regime gate')
    # Real default path resolution: package under .kairos/skillsets, marker
    # under .kairos/storage (the works-in-tests/dead-in-prod class).
    assert(dep[:package_path] == File.join(root, '.kairos', 'skillsets', 'prod_pack'),
           "real-chain: package materializes under the real data dir (got #{dep[:package_path]})")
    assert(File.exist?(File.join(root, '.kairos', 'skillsets', 'prod_pack', 'certificate.json')),
           'real-chain: certificate.json present in the real package')
    # The materialized package must be depositable through the SHIPPED
    # validation chain (discovery + knowledge-only + validity): pins that
    # certificate.json at the package root survives the exchange's own
    # gate, not just our packaging (impl review R2 (c)).
    begin
      require_relative '../../skillset_exchange/lib/skillset_exchange/exchange_validator'
      require_relative '../../../../lib/kairos_mcp/skillset_manager'
      manager = KairosMcp::SkillSetManager.new
      validation = ::SkillsetExchange::ExchangeValidator.new(config: {})
                     .validate_for_deposit('prod_pack', manager: manager)
      assert(validation[:valid] == true,
             "real-chain: materialized package passes the shipped deposit validation (#{validation[:errors]})")
    rescue LoadError, NameError => e
      assert(false, "real-chain: shipped validation chain must load (#{e.class}: #{e.message})")
    end
    assert(File.exist?(File.join(root, '.kairos', 'storage', 'cd_exposure.json')),
           'real-chain: exposure marker persists under the real storage dir')
    assert(exchange_calls == ['prod_pack'], 'real-chain: exchange delegate reached exactly once')
    # The deposit verdict record persists on the reloaded real store and
    # cites the identity (slice-1 R3 P0 class: records must survive).
    reloaded = KairosMcp::KairosChain::Chain.new
    persisted = reloaded.chain.each_with_object({}) do |blk, acc|
      first = Array(blk.data).first
      acc[blk.index] = (JSON.parse(first) rescue nil) if first.is_a?(String)
    end.compact
    dep_verdicts = persisted.values.select { |e|
      e['type'] == 'cg_guard_decision' && e.dig('crossing', 'tool') == 'cd_release_package'
    }
    assert(dep_verdicts.size == 1 && dep_verdicts.first.dig('crossing', 'certificate_identity') == identity,
           'real-chain: deposit verdict record persisted and cites the identity')
    # Revocation end to end on the real store: revoke, mirror to the real
    # carrier registry (chain authoritative, carrier mirrors), then
    # re-deposit declines and verification reports revoked.
    CD::Recorder.record_revocation(certificate_identity: identity, reason: 'withdrawn')
    mirror = CD::CarrierWiring.mirror_revocation(identity, 'withdrawn')
    assert(mirror['status'] == 'revoked', "real-chain: carrier mirror succeeds (got #{mirror})")
    real_reg = Synoptis::Registry::FileRegistry.new(
      data_dir: File.join(root, '.kairos', 'synoptis_data')
    )
    assert(real_reg.revoked?(identity),
           'real-chain: the real carrier registry reports revoked after the mirror (CD-11 remote leg)')
    begin
      CD::Depositor.deposit(certificate: cert, distillate_json: result[:distillate_json],
                            skillset_name: 'prod_pack')
      assert(false, 'real-chain: revoked re-deposit must decline')
    rescue CD::Distiller::Declined => e
      assert(JSON.parse(e.message)['rule'] == 'cd-9/revoked-at-judgment',
             'real-chain: revoked re-deposit names the rule')
    end
    vr = CD::Certificate.verify(cert, chain_entries: CD::Distiller.chain_entries,
                                chain_hashes: CD::Distiller.chain_block_hashes,
                                distillate_json: result[:distillate_json])
    assert(vr[:revoked] == true, 'real-chain: revocation visible to a chain-access verifier')

    # DEFAULT exchange delegate against the SHIPPED tool (impl review R1
    # (a)): with no Meeting Place connection the tool RETURNS an error as
    # text content without raising; the fail-closed normalization must
    # classify it as exchange failure — status deposit_incomplete, no
    # exposure — never as success (works-in-tests/dead-in-prod class).
    CD::Depositor.exchange = nil
    second = CD::Distiller.distill(designation: [2], distillate: { 'skill' => 'second' })
    second_id = second[:certificate]['claim_core']['certificate_identity']
    dep2 = CD::Depositor.deposit(certificate: second[:certificate],
                                 distillate_json: second[:distillate_json],
                                 skillset_name: 'unlisted_pack')
    assert(dep2[:status] == 'deposit_incomplete',
           "real-chain: unconnected exchange is a visible failure, not success (got #{dep2[:status]})")
    assert(dep2[:exchange_result].is_a?(Hash) && dep2[:exchange_result][:status] == 'exchange_error',
           'real-chain: shipped-tool error answer normalized fail-closed')
    detail = dep2[:exchange_result][:detail]
    assert(detail.is_a?(Hash) && detail['error'].to_s.include?('Not connected'),
           "real-chain: the LIVE shipped tool answered (not a load failure) — got #{detail.inspect}")
    assert(!CD::Depositor.exposed?(second_id),
           'real-chain: no exposure for a package that never reached a listing (CD-8)')
    assert(File.exist?(File.join(root, '.kairos', 'skillsets', 'unlisted_pack', 'certificate.json')),
           'real-chain: package persists for the operator retry (fail-visible, not rolled back)')
  ensure
    ENV['KAIROS_DATA_DIR'] = old_data_dir
    KairosMcp.reset_data_dir! if KairosMcp.respond_to?(:reset_data_dir!)
    CG::Regime.reset!
    CG::Recorder.chain_factory = nil
    CD::Recorder.chain_factory = nil
    CD::Distiller.registry_class = nil
    CD::Distiller.guard_regime = nil
    CD::Distiller.carrier = nil
    CD::Depositor.exchange = nil
    CD::Depositor.package_root = nil
    CD::Depositor.exposure_path = nil
    CG::Regime.skillset_root = File.expand_path('../../confidentiality_guard', __dir__)
  end
end

puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
