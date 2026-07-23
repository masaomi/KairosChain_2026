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
      CG::Regime.skillset_root = File.expand_path('../../confidentiality_guard', __dir__)
    end
  end
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

puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
