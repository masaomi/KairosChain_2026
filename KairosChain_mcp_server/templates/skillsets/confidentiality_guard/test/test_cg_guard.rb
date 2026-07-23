# frozen_string_literal: true
# Design-constraint tests for the Confidentiality Guard slice 1
# (confidentiality_guard_skillset_design v0.3, FROZEN; invariants CG-1..CG-6).
# Each block names the invariant whose implementable consequence it pins.

require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'digest'

require_relative '../../../../lib/kairos_mcp/tool_registry'
require_relative '../lib/confidentiality_guard/canon'
require_relative '../lib/confidentiality_guard/policy'
require_relative '../lib/confidentiality_guard/surfaces'
require_relative '../lib/confidentiality_guard/verdict'
require_relative '../lib/confidentiality_guard/recorder'
require_relative '../lib/confidentiality_guard/regime'

CG = KairosMcp::SkillSets::ConfidentialityGuard

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

# Captures chain appends in-memory (CG-4 records must not hit the live store
# from tests; the seam is Recorder.chain_factory).
class FakeChain
  attr_reader :blocks
  def initialize = @blocks = []
  def add_block(data)
    @blocks << data
    Struct.new(:index, :hash).new(@blocks.size, 'fake')
  end
end

# Minimal registry honoring the real gate contract (register/unregister/run).
class FakeRegistry
  @gates = {}
  class << self
    attr_reader :gates
    def register_gate(name, &block) = @gates[name.to_sym] = block
    def unregister_gate(name) = @gates.delete(name.to_sym)
    def run_gates(tool_name, arguments)
      @gates.values.each { |g| g.call(tool_name, arguments, nil) }
    end
    def clear! = @gates = {}
  end
end

SECRET = 'api_key: SUPER-SECRET-VALUE-12345'

def with_regime(profile_yaml, env: nil)
  Dir.mktmpdir do |root|
    FileUtils.mkdir_p(File.join(root, 'config'))
    File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
               { 'guard' => { 'enabled' => true, 'profile' => 'profile.yml' } }.to_yaml)
    File.write(File.join(root, 'config', 'profile.yml'), profile_yaml.to_yaml) if profile_yaml
    fake = FakeChain.new
    CG::Recorder.chain_factory = -> { fake }
    CG::Regime.skillset_root = root
    FakeRegistry.clear!
    old_env = ENV['KAIROS_CONFIDENTIALITY_GUARD']
    ENV['KAIROS_CONFIDENTIALITY_GUARD'] = env
    begin
      CG::Regime.ensure_activated!(registry_class: FakeRegistry)
      yield fake, root
    ensure
      ENV['KAIROS_CONFIDENTIALITY_GUARD'] = old_env
      CG::Regime.reset!
      CG::Recorder.chain_factory = nil
      CG::Regime.skillset_root = File.expand_path('../..', __dir__)
    end
  end
end

PERMISSIVE = {
  'version' => 1,
  'persistent_admissions' => { 'l2' => 'permitted' },
  # Pattern tolerates a quote between name and separator, because detection
  # runs over canonical JSON ("api_key":"...") — impl review R1.
  'content_classes' => [{ 'id' => 'api_key', 'pattern' => '(?i)api[_-]?key["\']?\s*[:=]' }]
}.freeze

records = ->(fake) { fake.blocks.flatten.map { |s| JSON.parse(s) } }

# ---------------------------------------------------------------------------
# CG-1: shipped default is off; activation is environment-level with env
# precedence; regime state is readable.
shipped = YAML.safe_load(File.read(File.expand_path('../config/confidentiality_guard.yml', __dir__)))
assert(shipped.dig('guard', 'enabled') == false, 'CG-1: shipped config is selectable-off')

Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
             { 'guard' => { 'enabled' => true } }.to_yaml)
  CG::Regime.skillset_root = root
  old = ENV['KAIROS_CONFIDENTIALITY_GUARD']
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = '0'
  assert(!CG::Regime.enabled?, 'CG-1: env var "0" overrides config enabled:true')
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = '1'
  assert(CG::Regime.enabled?, 'CG-1: env var "1" forces enabled')
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = old
  CG::Regime.skillset_root = File.expand_path('../..', __dir__)
end

# CG-1: zero-profile activation = total denial on guarded classes; activation
# recorded; status readable.
with_regime(nil) do |fake, _root|
  assert(CG::Regime.active?, 'CG-1: regime activates with no profile (fail-closed, not error)')
  assert(records.call(fake).any? { |r| r['type'] == 'cg_guard_regime' && r['event'] == 'activation' },
         'CG-1: activation recorded on chain')
  assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'CG-1: zero-profile denies inward L2 write') do
    FakeRegistry.run_gates('context_save', { 'name' => 'x', 'content' => 'hello' })
  end
  status = CG::Regime.status
  assert(status[:active] == true && status[:policy_sha256].is_a?(String) && status[:engine] == CG::Policy::ENGINE_VERSION,
         'CG-1: regime state readable at any time (active, policy sha, engine)')
end

# CG-1: policy pinned at activation — file edits after activation are inert.
with_regime(PERMISSIVE) do |_fake, root|
  FakeRegistry.run_gates('context_save', { 'name' => 'x', 'content' => 'clean' })
  File.write(File.join(root, 'config', 'profile.yml'),
             { 'version' => 2, 'persistent_admissions' => { 'l2' => 'denied' } }.to_yaml)
  begin
    FakeRegistry.run_gates('context_save', { 'name' => 'x', 'content' => 'clean' })
    assert(true, 'CG-1: pinned policy — post-activation file edit is inert')
  rescue KairosMcp::ToolRegistry::GateDeniedError
    assert(false, 'CG-1: pinned policy — post-activation file edit is inert')
  end
end

# CG-1: cessation recorded; gate unregistered after deactivation.
with_regime(PERMISSIVE) do |fake, _root|
  CG::Regime.deactivate!(reason: 'test')
  assert(records.call(fake).any? { |r| r['type'] == 'cg_guard_regime' && r['event'] == 'cessation/test' },
         'CG-1: cessation recorded on chain')
  assert(FakeRegistry.gates.empty?, 'CG-1: gate unregistered at cessation')
end

# ---------------------------------------------------------------------------
# CG-2: enrollment manifest — the slice-1 surface tables are release-gated
# against this pinned manifest; extending the tool surface without extending
# the tables (or this manifest) fails here.
assert(CG::Surfaces::INWARD_WRITE_TOOLS == {
         'context_save' => 'l2', 'context_create_subdir' => 'l2',
         'knowledge_update' => 'l1', 'skills_promote' => 'l1'
       }, 'CG-2: inward-write enrollment matches pinned manifest')
assert(CG::Surfaces::STORAGE_READ_TOOLS.keys.sort == %w[safe_file_list safe_file_read],
       'CG-2: storage-read enrollment matches pinned manifest')
assert(CG::Surfaces::UNMAPPED_READ_TOOLS.sort == %w[resource_read resource_render],
       'CG-2: unmapped-read enrollment matches pinned manifest')
assert(CG::Surfaces::OUTWARD_TOOLS.sort == %w[
         chain_export llm_call meeting_attest_skill meeting_deposit
         meeting_publish_needs meeting_update_deposit philosophy_anchor safe_git_push skillset_deposit
       ], 'CG-2: outward enrollment matches pinned manifest')
assert(CG::Surfaces::DISTILLATION_TOOLS.sort == %w[cd_release_certificate cd_release_distillate],
       'CG-2: distillation-crossing enrollment matches pinned manifest (guard slice-2 first increment)')

# ---------------------------------------------------------------------------
# Guard slice-2 first increment: distillation crossing (chain_distillation
# design v0.5 §5). Conjunctive per-destination verdict; outward verdicts
# recorded pass or deny (CG-4); the rest of the outward class stays denied.
DISTILL_PROFILE = PERMISSIVE.merge(
  'distillation_crossings' => %w[cd_release_distillate cd_release_certificate]
).freeze

with_regime(PERMISSIVE) do |_fake, _root|
  assert_raises(KairosMcp::ToolRegistry::GateDeniedError,
                'distillation: undesignated crossing denied (closed-world, CG-1)') do
    FakeRegistry.run_gates('cd_release_distillate', { 'content' => 'clean payload' })
  end
end

with_regime(DISTILL_PROFILE) do |fake, _root|
  FakeRegistry.run_gates('cd_release_distillate', { 'content' => 'clean payload' })
  passed = records.call(fake).select { |r| r['type'] == 'cg_guard_decision' && r['verdict'] == 'pass' }
  assert(passed.any? { |r| r['rule'] == 'designation/distillation:cd_release_distillate' },
         'distillation: designated clean crossing passes and is RECORDED (outward CG-4)')
  assert_raises(KairosMcp::ToolRegistry::GateDeniedError,
                'distillation: content-class hit denies conjunctively (CG-3/CG-6)') do
    FakeRegistry.run_gates('cd_release_certificate', { 'content' => SECRET })
  end
  denied = records.call(fake).select { |r| r['type'] == 'cg_guard_decision' && r['verdict'] == 'deny' }
  assert(denied.any? { |r| r['rule'].start_with?('content/') && r.dig('crossing', 'tool') == 'cd_release_certificate' },
         'distillation: denial recorded with rule and crossing, no content (CG-4)')
  # The remainder of the outward class stays denied wholesale.
  assert_raises(KairosMcp::ToolRegistry::GateDeniedError,
                'distillation: general outward class still denied wholesale (CG-1 coverage)') do
    FakeRegistry.run_gates('llm_call', { 'prompt' => 'clean' })
  end
  status = CG::Regime.status
  assert(status[:surfaces][:distillation_outward] == CG::Surfaces::DISTILLATION_TOOLS,
         'distillation: surface inspectable in regime status (CG-1)')
  # CD-1 coupling: a caller-presented certificate identity (an identifier)
  # is carried into the verdict record so the record cites the certificate.
  FakeRegistry.run_gates('cd_release_certificate',
                         { 'content' => 'clean cert', 'certificate_identity' => 'cert-uuid-1' })
  cited = records.call(fake).any? do |r|
    r['type'] == 'cg_guard_decision' && r.dig('crossing', 'certificate_identity') == 'cert-uuid-1'
  end
  assert(cited, 'distillation: certificate-crossing verdict record cites the certificate identity (identifier only)')
end

# CG-2: verdict precedes effect — the deny raise happens at the gate, before
# any tool body could run (gates run before tool.call in ToolRegistry).
with_regime(PERMISSIVE) do |_fake, _root|
  effect = false
  begin
    FakeRegistry.run_gates('knowledge_update', { 'content' => 'x' })
    effect = true
  rescue KairosMcp::ToolRegistry::GateDeniedError
    # denied before effect
  end
  assert(!effect, 'CG-2: denied crossing never reaches the effect')
end

# ---------------------------------------------------------------------------
# CG-3: deterministic conjunctive verdict.
policy = CG::Policy.new(PERMISSIVE)
desc_l2 = { class: :inward_write, layer: 'l2', tool: 'context_save' }
desc_l1 = { class: :inward_write, layer: 'l1', tool: 'knowledge_update' }
clean = CG::Verdict.present_content({ 'content' => 'hello world' })
dirty = CG::Verdict.present_content({ 'content' => SECRET })

v1 = CG::Verdict.judge(policy, desc_l2, dirty)
v2 = CG::Verdict.judge(policy, desc_l2, dirty)
assert(v1 == v2, 'CG-3: verdict is deterministic (same inputs, same output)')
assert(CG::Verdict.judge(policy, desc_l2, clean)[:verdict] == 'pass',
       'CG-3: designated crossing with clean content passes')
assert(v1[:verdict] == 'deny' && v1[:rule] == 'content/api_key',
       'CG-3: designated crossing with detected content denies (conjunction)')
assert(CG::Verdict.judge(policy, desc_l1, clean)[:verdict] == 'deny',
       'CG-3: undesignated layer denies even with clean content (closed-world designation)')
assert(v1[:basis][:policy_sha256] == policy.sha256 && v1[:basis][:engine] == CG::Policy::ENGINE_VERSION,
       'CG-3: verdict carries the versioned verdict basis')

# Invalid pattern aborts activation (fail-closed, never runs unpinnable policy).
assert_raises(CG::Policy::ActivationError, 'CG-3: invalid detection pattern aborts activation') do
  CG::Policy.new({ 'content_classes' => [{ 'id' => 'bad', 'pattern' => '(' }] })
end

# ---------------------------------------------------------------------------
# CG-4: record scope and commitment binding.
with_regime(PERMISSIVE) do |fake, _root|
  baseline = fake.blocks.size
  FakeRegistry.run_gates('context_save', { 'name' => 'x', 'content' => 'clean note' })
  assert(fake.blocks.size == baseline, 'CG-4: permitted inward write is NOT recorded (principled asymmetry)')

  denied = false
  begin
    FakeRegistry.run_gates('context_save', { 'name' => 'x', 'content' => SECRET })
  rescue KairosMcp::ToolRegistry::GateDeniedError => e
    denied = true
    report = JSON.parse(e.message)
    entry = records.call(fake).find { |r| r['type'] == 'cg_guard_decision' && r['verdict'] == 'deny' }
    assert(!entry.nil?, 'CG-4: denial recorded on chain')
    chain_text = fake.blocks.flatten.join
    assert(!chain_text.include?('SUPER-SECRET-VALUE'), 'CG-4: record never contains the content')
    assert(entry['commitment'] =~ /\A[0-9a-f]{64}\z/ && entry['policy_sha256'] == CG::Regime.policy.sha256,
           'CG-4: record carries commitment digest and versioned basis')
    content = CG::Verdict.present_content({ 'name' => 'x', 'content' => SECRET })
    assert(CG::Recorder.commitment_valid?(report['commitment'], report['salt'], content),
           'CG-4: re-presentation + salt re-derives the commitment')
    assert(!CG::Recorder.commitment_valid?(report['commitment'], report['salt'], 'other content'),
           'CG-4: commitment does not verify against different content')
  end
  assert(denied, 'CG-4: detected inward write MUST be denied (strict pin)')
end

# CG-4: restricted reads recorded permitted-or-not; undesignated reads are
# not crossings.
Dir.mktmpdir do |store|
  profile = {
    'version' => 1,
    'restricted_storage' => [{ 'id' => 'store', 'path' => store, 'reads' => 'permitted' }]
  }
  with_regime(profile) do |fake, _root|
    FakeRegistry.run_gates('safe_file_read', { 'path' => File.join(store, 'a.txt') })
    entry = records.call(fake).find { |r| r['type'] == 'cg_guard_decision' && r['verdict'] == 'pass' }
    assert(!entry.nil? && entry['rule'] == 'designation/read:store',
           'CG-4: permitted restricted read is recorded')
    baseline = fake.blocks.size
    FakeRegistry.run_gates('safe_file_read', { 'path' => '/tmp/unrelated.txt' })
    assert(fake.blocks.size == baseline, 'CG-4: undesignated read is not a crossing (no record)')
  end
  profile['restricted_storage'][0]['reads'] = 'denied'
  with_regime(profile) do |fake, _root|
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'CG-4: denied restricted read raises') do
      FakeRegistry.run_gates('safe_file_read', { 'path' => File.join(store, 'a.txt') })
    end
    assert(records.call(fake).any? { |r| r['type'] == 'cg_guard_decision' && r['verdict'] == 'deny' },
           'CG-4: denied restricted read is recorded')
  end
end

# CG-4/CG-1: edits to the policy file through the tool surface are recorded
# and pass (inert until adoption).
with_regime(PERMISSIVE) do |fake, root|
  profile_path = File.join(root, 'config', 'profile.yml')
  FakeRegistry.run_gates('safe_file_write', { 'path' => profile_path, 'content' => 'anything' })
  assert(records.call(fake).any? { |r| r['type'] == 'cg_policy_edit' },
         'CG-4: policy-file edit through tool surface is recorded')
end

# ---------------------------------------------------------------------------
# CG-5 (via CG-1 coverage clause): outward crossings denied wholesale in
# slice 1, with the coverage rule named.
with_regime(PERMISSIVE) do |fake, _root|
  begin
    FakeRegistry.run_gates('llm_call', { 'prompt' => 'hi' })
    assert(false, 'CG-5/CG-1: outward crossing denied wholesale in slice 1')
  rescue KairosMcp::ToolRegistry::GateDeniedError => e
    report = JSON.parse(e.message)
    assert(report['rule'] == 'coverage/outward-unenforced',
           'CG-5/CG-1: outward denial names the coverage rule')
    assert(records.call(fake).any? { |r| r['type'] == 'cg_guard_decision' && r['rule'] == 'coverage/outward-unenforced' },
           'CG-4: outward denial recorded')
  end
end

# ---------------------------------------------------------------------------
# CG-6: denial report is operator-visible, names rule and crossing, and
# never republishes the content.
with_regime(PERMISSIVE) do |_fake, _root|
  cg6_denied = false
  begin
    FakeRegistry.run_gates('context_save', { 'name' => 'x', 'content' => SECRET })
  rescue KairosMcp::ToolRegistry::GateDeniedError => e
    cg6_denied = true
    report = JSON.parse(e.message)
    assert(report['rule'] == 'content/api_key' && report.dig('crossing', 'tool') == 'context_save',
           'CG-6: denial report names rule and crossing')
    assert(!e.message.include?('SUPER-SECRET-VALUE'), 'CG-6: denial report excludes the content')
    assert(report['salt'] =~ /\A[0-9a-f]{32}\z/, 'CG-6/CG-4: report carries the operator-side salt')
  end
  assert(cg6_denied, 'CG-6: detected content MUST be denied (strict pin)')
end

# ---------------------------------------------------------------------------
# R1 regression: canonical serialization is faithful to false/nil and to
# mixed string/symbol keys (CG-3/CG-4 reproducibility, detection integrity).
assert(CG::Canon.canonical({ 'a' => false }) != CG::Canon.canonical({ 'a' => nil }),
       'R1: false and nil are distinct in canonical form')
assert(CG::Canon.canonical({ 'a' => false }) == '{"a":false}',
       'R1: false is preserved, not collapsed to null')
mixed = { 'content' => 'clean' }
mixed[:content] = SECRET
assert(CG::Canon.canonical(mixed).include?(SECRET),
       'R1: symbol-keyed value is not dropped when a string key of same name exists')
p2 = CG::Policy.new(PERMISSIVE)
assert(CG::Verdict.judge(p2, { class: :inward_write, layer: 'l2', tool: 'context_save' },
                         CG::Verdict.present_content(mixed))[:verdict] == 'deny',
       'R1: secret hidden under a symbol key is still detected')

# R1 regression: symbol-keyed path is classified (classify normalizes keys
# via Regime.gate stringify — test through the gate).
Dir.mktmpdir do |store|
  profile = { 'version' => 1,
              'restricted_storage' => [{ 'id' => 'store', 'path' => store, 'reads' => 'denied' }] }
  with_regime(profile) do |_fake, _root|
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'R1: symbol-keyed restricted-read path is denied') do
      FakeRegistry.run_gates('safe_file_read', { path: File.join(store, 'a.txt') })
    end
  end
end

# R1 regression: enrolled read tool with unextractable path fails closed.
policy_none = CG::Policy.new({ 'version' => 1 })
uv = CG::Verdict.judge(policy_none, { class: :storage_read, tool: 'safe_file_read', path: '' },
                       CG::Verdict.present_content({}))
assert(uv[:verdict] == 'deny' && uv[:rule] == 'coverage/unextractable-path',
       'R1: enrolled read with empty path denies (degrade-closed)')

# R1 regression: resource-scheme readers denied wholesale (unmapped in slice 1).
with_regime(PERMISSIVE) do |_fake, _root|
  assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'R1: resource_read denied wholesale (unmapped)') do
    FakeRegistry.run_gates('resource_read', { 'uri' => 'knowledge://x' })
  end
end

# R1 regression: symlink into a restricted root is resolved and denied.
Dir.mktmpdir do |real|
  Dir.mktmpdir do |outside|
    link = File.join(outside, 'alias')
    File.symlink(real, link)
    profile = { 'version' => 1,
                'restricted_storage' => [{ 'id' => 'store', 'path' => real, 'reads' => 'denied' }] }
    with_regime(profile) do |_fake, _root|
      assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'R1: symlink alias into restricted root is denied') do
        FakeRegistry.run_gates('safe_file_read', { 'path' => File.join(link, 'secret.txt') })
      end
    end
  end
end

# R1 regression: storage-read record carries the designation id, not the
# raw path (CG-4 record hygiene).
Dir.mktmpdir do |store|
  profile = { 'version' => 1,
              'restricted_storage' => [{ 'id' => 'chain_store', 'path' => store, 'reads' => 'permitted' }] }
  with_regime(profile) do |fake, _root|
    FakeRegistry.run_gates('safe_file_read', { 'path' => File.join(store, 'secret_filename.txt') })
    entry = records.call(fake).find { |r| r['type'] == 'cg_guard_decision' }
    assert(entry['crossing']['designation'] == 'chain_store' && !entry['crossing'].key?('path'),
           'R1: read record carries designation id, not raw path')
    assert(!fake.blocks.flatten.join.include?('secret_filename'),
           'R1: raw restricted path is not written to the record')
  end
end

# R1 regression: env var accepts true/false/on/off, not only 1/0.
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
             { 'guard' => { 'enabled' => false } }.to_yaml)
  CG::Regime.skillset_root = root
  old = ENV['KAIROS_CONFIDENTIALITY_GUARD']
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = 'true'
  assert(CG::Regime.enabled?, 'R1: env "true" enables')
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = 'off'
  assert(!CG::Regime.enabled?, 'R1: env "off" disables')
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = old
  CG::Regime.skillset_root = File.expand_path('../..', __dir__)
end

# R1 regression: fail-closed loader contract — activation failure raises
# FailClosedError (never a swallowed warn).
assert(defined?(KairosMcp::ToolRegistry::FailClosedError),
       'R1: FailClosedError exists for the loader seam')
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
             { 'guard' => { 'enabled' => true, 'profile' => 'profile.yml' } }.to_yaml)
  File.write(File.join(root, 'config', 'profile.yml'),
             { 'content_classes' => [{ 'id' => 'bad', 'pattern' => '(' }] }.to_yaml)
  CG::Recorder.chain_factory = -> { FakeChain.new }
  CG::Regime.skillset_root = root
  FakeRegistry.clear!
  old = ENV['KAIROS_CONFIDENTIALITY_GUARD']
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = '1'
  assert_raises(KairosMcp::ToolRegistry::FailClosedError, 'R1: unpinnable policy raises FailClosedError') do
    CG::Regime.ensure_activated!(registry_class: FakeRegistry)
  end
  assert(FakeRegistry.gates.empty?, 'R1: no gate left registered after failed activation')
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = old
  CG::Regime.reset!
  CG::Recorder.chain_factory = nil
  CG::Regime.skillset_root = File.expand_path('../..', __dir__)
end

# R1 regression: config-file edits are observed too (policy change scope).
with_regime(PERMISSIVE) do |fake, root|
  cfg = File.join(root, 'config', 'confidentiality_guard.yml')
  FakeRegistry.run_gates('safe_file_edit', { 'path' => cfg, 'content' => 'x' })
  assert(records.call(fake).any? { |r| r['type'] == 'cg_policy_edit' },
         'R1: edit to regime config file is recorded as a policy edit')
end

# ---------------------------------------------------------------------------
# R2 regression: safe_file_copy source read is a restricted crossing (a
# restricted file must not be copied out).
Dir.mktmpdir do |store|
  profile = { 'version' => 1,
              'restricted_storage' => [{ 'id' => 'vault', 'path' => store, 'reads' => 'denied' }] }
  with_regime(profile) do |fake, _root|
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'R2: copy OUT of a restricted root is denied (source read)') do
      FakeRegistry.run_gates('safe_file_copy',
                             { 'source' => File.join(store, 'secret.txt'), 'destination' => '/tmp/exfil.txt' })
    end
    assert(records.call(fake).any? { |r| r['rule'] == 'designation/read-denied:vault' },
           'R2: copy source-read denial recorded')
  end
end

# R2 regression: gate resolves a RELATIVE read path against workspace_root
# (matching the tool), not the server cwd.
Dir.mktmpdir do |ws|
  restricted = File.join(ws, 'restricted')
  FileUtils.mkdir_p(restricted)
  profile = { 'version' => 1,
              'restricted_storage' => [{ 'id' => 'r', 'path' => restricted, 'reads' => 'denied' }] }
  with_regime(profile) do |_fake, _root|
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'R2: relative read path resolved against workspace_root is denied') do
      FakeRegistry.run_gates('safe_file_read',
                             { 'path' => 'restricted/secret.txt', 'workspace_root' => ws })
    end
  end
end

# R2 regression: activation_hook drives activation independent of any tool
# instantiation; skillset.json declares it.
sj = JSON.parse(File.read(File.expand_path('../skillset.json', __dir__)))
assert(sj['activation_hook'] == 'KairosMcp::SkillSets::ConfidentialityGuard::Regime',
       'R2: skillset.json declares the activation_hook')
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
             { 'guard' => { 'enabled' => true, 'profile' => 'profile.yml' } }.to_yaml)
  File.write(File.join(root, 'config', 'profile.yml'), PERMISSIVE.to_yaml)
  CG::Recorder.chain_factory = -> { FakeChain.new }
  CG::Regime.skillset_root = root
  FakeRegistry.clear!
  old = ENV['KAIROS_CONFIDENTIALITY_GUARD']
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = '1'
  CG::Regime.activate_on_load!(registry_class: FakeRegistry)
  assert(CG::Regime.active? && !FakeRegistry.gates.empty?,
         'R2: activate_on_load! registers the gate with no tool instantiated')
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = old
  CG::Regime.reset!
  CG::Recorder.chain_factory = nil
  CG::Regime.skillset_root = File.expand_path('../..', __dir__)
end

# R2 regression: no fail-open window — the gate is only registered once the
# regime is active (a registered gate never reads @active == false).
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, 'config'))
  File.write(File.join(root, 'config', 'confidentiality_guard.yml'),
             { 'guard' => { 'enabled' => true, 'profile' => 'profile.yml' } }.to_yaml)
  File.write(File.join(root, 'config', 'profile.yml'), PERMISSIVE.to_yaml)
  seen_inactive = false
  probe = Class.new do
    define_singleton_method(:register_gate) do |_n, &blk|
      # At the moment the gate is registered, the regime must already be active.
      seen_inactive = true unless CG::Regime.active?
      @blk = blk
    end
    define_singleton_method(:unregister_gate) { |_n| @blk = nil }
  end
  CG::Recorder.chain_factory = -> { FakeChain.new }
  CG::Regime.skillset_root = root
  old = ENV['KAIROS_CONFIDENTIALITY_GUARD']
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = '1'
  CG::Regime.ensure_activated!(registry_class: probe)
  assert(!seen_inactive, 'R2: gate is registered only after the regime is active (no fail-open window)')
  ENV['KAIROS_CONFIDENTIALITY_GUARD'] = old
  CG::Regime.reset!
  CG::Recorder.chain_factory = nil
  CG::Regime.skillset_root = File.expand_path('../..', __dir__)
end

# R2 regression: malformed (null-byte) and non-string read paths deny as
# unextractable rather than crashing or passing.
Dir.mktmpdir do |store|
  profile = { 'version' => 1,
              'restricted_storage' => [{ 'id' => 'v', 'path' => store, 'reads' => 'denied' }] }
  with_regime(profile) do |_fake, _root|
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'R2: null-byte path denies (crash-closed)') do
      FakeRegistry.run_gates('safe_file_read', { 'path' => "#{store}/sec\0ret" })
    end
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'R2: non-string path denies as unextractable') do
      FakeRegistry.run_gates('safe_file_read', { 'path' => [File.join(store, 'x')] })
    end
  end
end

# R3 regression: symlink + ".." composition resolves through the filesystem
# (matching File.realpath, as the read tool does), not lexically. A symlink
# into a restricted root followed by ".." must still be judged against the
# real target, not the lexical parent of the link.
Dir.mktmpdir do |ws|
  secret = File.join(ws, 'secret'); sub = File.join(secret, 'sub')
  FileUtils.mkdir_p(sub)
  File.write(File.join(secret, 'data'), 'x')
  File.symlink(sub, File.join(ws, 'link')) # /ws/link -> /ws/secret/sub
  profile = { 'version' => 1,
              'restricted_storage' => [{ 'id' => 's', 'path' => secret, 'reads' => 'denied' }] }
  with_regime(profile) do |_fake, _root|
    # link/../data -> fs: /ws/secret/sub/../data -> /ws/secret/data (restricted)
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError, 'R3: symlink+".." into restricted root is denied') do
      FakeRegistry.run_gates('safe_file_read', { 'path' => 'link/../data', 'workspace_root' => ws })
    end
  end
end

# R2 regression: under_root? matches children of root "/" correctly.
assert(CG::Policy.new({ 'version' => 1 }).send(:under_root?, '/etc/passwd', '/'),
       'R2: under_root? matches children of "/"')
assert(!CG::Policy.new({ 'version' => 1 }).send(:under_root?, '/etcpasswd', '/etc'),
       'R2: under_root? rejects sibling-prefix false match')

# Regime off => gate inert even if invoked.
CG::Regime.reset!
begin
  CG::Regime.gate('context_save', { 'content' => SECRET })
  assert(true, 'CG-1: inactive regime does not judge')
rescue StandardError
  assert(false, 'CG-1: inactive regime does not judge')
end

puts "\n#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
