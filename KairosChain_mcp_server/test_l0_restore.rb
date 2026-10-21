#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test_l0_restore.rb — the L0 restore path: SafeEvolver.propose_restore / apply
# and the skills_rollback tool. Everything runs inside a throwaway data dir.

require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require 'yaml'

tmp = Dir.mktmpdir('kairos_l0_restore')
ENV['KAIROS_DATA_DIR'] = tmp

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/safe_evolver'
require 'kairos_mcp/tools/skills_rollback'

abort "data dir not isolated: #{KairosMcp.blockchain_path}" unless
  KairosMcp.blockchain_path.to_s.start_with?(tmp)

@passes = 0
@failures = []

def assert(label, cond)
  if cond
    @passes += 1
    puts "PASS  #{label}"
  else
    @failures << label
    puts "FAIL  #{label}"
  end
end

# Tolerate symbol- or string-keyed result hashes.
def val(hash, key)
  return nil unless hash.is_a?(Hash)

  v = hash[key.to_sym]
  v.nil? ? hash[key.to_s] : v
end

def l0_bytes
  File.binread(KairosMcp.dsl_path)
end

def block_data(block)
  # A block carries an array of JSON strings; transitions hold exactly one.
  if block.respond_to?(:data) then Array(block.data).first.to_s
  elsif block.is_a?(Hash) then (block['data'] || block[:data]).to_s
  else block.to_s
  end
end

# A transition is any block whose data carries prev_ast_hash (evolve or restore).
def transitions
  KairosMcp::KairosChain::Chain.new.chain.select { |b| block_data(b).include?('prev_ast_hash') }
end

def text_of(result)
  Array(result).map { |h| h.is_a?(Hash) ? (h[:text] || h['text']) : h.to_s }.join("\n")
end

# Newest first, ignoring anything that is not a generated snapshot name.
def newest_snapshot
  entry = KairosMcp::VersionManager.list_versions.find do |e|
    val(e, 'filename').to_s.match?(/\Akairos_\d{8}_\d{6}(_\d+)?\.rb\z/)
  end
  entry && val(entry, 'filename')
end

def write_config(evolution_enabled)
  File.write(KairosMcp.skills_config_path,
             { 'evolution_enabled' => evolution_enabled,
               'require_human_approval' => true }.to_yaml)
end

# Legacy evolve: snapshots the current L0 first, then rewrites the skill.
def evolve!(version)
  KairosMcp::SafeEvolver.reset_session!
  definition = <<~DSL
    skill :evolution_rules do
      version '#{version}'
      title 'Evolution rules'

      evolve do
        allow :content
        deny :guarantees, :evolve, :behavior
      end

      content 'Evolution rule set #{version}: content may change, guarantees may not.'
    end
  DSL
  KairosMcp::SafeEvolver.apply(skill_id: 'evolution_rules', new_definition: definition,
                               approved: true, reason: "test evolve #{version}")
end

begin
  FileUtils.mkdir_p(File.dirname(KairosMcp.dsl_path))
  FileUtils.cp(File.expand_path('templates/skills/kairos.rb', __dir__), KairosMcp.dsl_path)
  FileUtils.mkdir_p(KairosMcp.versions_dir)
  write_config(true)

  tool = KairosMcp::Tools::SkillsRollback.new
  original = l0_bytes

  # Setup: one evolve, so a snapshot holding the original bytes exists.
  assert('evolve #1 succeeded', val(evolve!('1.0.1'), 'success'))
  s1 = newest_snapshot
  s1_bytes = File.binread(KairosMcp::VersionManager.version_path(s1))
  evolved = l0_bytes
  assert('C1 snapshot holds the original L0 bytes', s1_bytes == original)
  assert('C1 evolve changed L0', evolved != original)

  # Case 1: a rollback without approval changes nothing and leaves a proposal.
  n = transitions.size
  t1 = text_of(tool.call('command' => 'rollback', 'version' => s1, 'reason' => 'back to original'))
  assert('C1 asks for approval', t1.include?('requires approval'))
  assert('C1 shows the proposal', t1.include?('Proposal:'))
  assert('C1 L0 untouched', l0_bytes == evolved)
  assert('C1 no new transition', transitions.size == n)
  pending = KairosMcp::SafeEvolver.pending_proposals.select { |p| val(p, 'kind') == 'restore' }
  assert('C1 a pending restore proposal exists', !pending.empty?)

  # Case 3: with evolution disabled, even an approved rollback is refused.
  # Runs here because it needs a snapshot that still differs from the current L0.
  write_config(false)
  n = transitions.size
  t3 = text_of(tool.call('command' => 'rollback', 'version' => s1,
                         'reason' => 'disabled', 'approved' => true))
  assert('C3 refused while evolution is disabled', !t3.include?('Rollback successful'))
  assert('C3 L0 untouched', l0_bytes == evolved)
  assert('C3 no new transition', transitions.size == n)
  write_config(true)

  # Case 2: an approved rollback writes the snapshot and records exactly one block.
  n = transitions.size
  t2 = text_of(tool.call('command' => 'rollback', 'version' => s1,
                         'reason' => 'back to original', 'approved' => true))
  assert('C2 reports success', t2.include?('Rollback successful'))
  assert('C2 L0 equals the snapshot bytes', l0_bytes == s1_bytes)
  after = transitions
  assert('C2 exactly one new transition', after.size - n == 1)
  sha = Digest::SHA256.hexdigest(s1_bytes)
  data = block_data(after.last)
  payload = begin
    JSON.parse(data)
  rescue StandardError
    {}
  end
  assert('C2 skill_id is kairos.rb',
         payload['skill_id'] == 'kairos.rb' || data.include?('"kairos.rb"'))
  assert('C2 next_ast_hash is sha256 of the snapshot',
         payload['next_ast_hash'] == sha || data.include?(sha))
  ref = payload['reason_ref'].to_s
  ref = data if ref.empty?
  assert('C2 reason_ref cites the hash and the snapshot name',
         ref.include?(sha) && ref.include?(s1))

  # Case 4: version_path rejects anything that is not a plain snapshot name.
  outside = File.join(tmp, 'outside_target.rb')
  File.write(outside, "# a real file outside the versions directory\n")
  File.symlink(outside, File.join(KairosMcp.versions_dir, 'link.rb'))
  ['../skills/config.yml', '/etc/passwd', '.x.rb', 'sub/kairos_x.rb', 'link.rb'].each do |bad|
    assert("C4 view refuses #{bad}",
           text_of(tool.call('command' => 'view', 'version' => bad)).include?('Error'))
  end

  # Case 5: a snapshot that fails to load leaves L0 exactly as it was.
  File.write(File.join(KairosMcp.versions_dir, 'kairos_19990101_000000.rb'), %(raise "boom"\n))
  before5 = l0_bytes
  n = transitions.size
  planted_name = 'kairos_19990101_000000.rb'
  p5 = KairosMcp::SafeEvolver.propose_restore(version: planted_name,
                                              reason: 'unloadable snapshot')
  assert('C5 planted snapshot refused (it was never in force)', !val(p5, 'success'))

  # Record a transition naming the planted bytes, so the snapshot now describes
  # a definition that was once in force and the provenance check lets it past.
  planted_bytes = File.read(KairosMcp::VersionManager.version_path(planted_name))
  KairosMcp::KairosChain::Chain.new.add_block(
    [{ skill_id: 'kairos.rb',
       prev_ast_hash: '0' * 64,
       next_ast_hash: Digest::SHA256.hexdigest(planted_bytes),
       diff_hash: '0' * 64 }.to_json]
  )

  n = transitions.size
  p5 = KairosMcp::SafeEvolver.propose_restore(version: planted_name,
                                              reason: 'unloadable snapshot')
  assert('C5 proposal accepted (the snapshot now has recorded provenance)', val(p5, 'success'))
  a5 = KairosMcp::SafeEvolver.apply(proposal_id: val(p5, 'proposal_id'), approved: true)
  assert('C5 approved restore fails on the load check', val(a5, 'success') == false)
  assert('C5 L0 restored to the previous bytes', l0_bytes == before5)
  assert('C5 no transition recorded', transitions.size == n)

  # Case 7: a snapshot identical to the current L0 is refused.
  # L0 has equalled s1 since case 2; cases 4 and 5 changed nothing.
  p7 = KairosMcp::SafeEvolver.propose_restore(version: s1, reason: 'identical content')
  assert('C7 identical snapshot refused', val(p7, 'success') == false)
  assert('C7 refusal carries an error', !val(p7, 'error').to_s.empty?)

  # Case 6: a proposal goes stale when L0 moves under it.
  sleep 1 # snapshot names are second-resolution; keep them distinct
  assert('evolve #2 succeeded', val(evolve!('1.0.2'), 'success'))
  s2 = newest_snapshot
  p6 = KairosMcp::SafeEvolver.propose_restore(version: s2, reason: 'stale check')
  assert('C6 restore proposal accepted', val(p6, 'success'))
  sleep 1
  assert('evolve #3 succeeded', val(evolve!('1.0.3'), 'success'))
  moved = l0_bytes
  n = transitions.size
  a6 = KairosMcp::SafeEvolver.apply(proposal_id: val(p6, 'proposal_id'), approved: true)
  assert('C6 apply reports stale', val(a6, 'stale') == true)
  assert('C6 stale apply left L0 alone', l0_bytes == moved)
  assert('C6 stale apply recorded nothing', transitions.size == n)

  puts
  puts "passes: #{@passes}  failures: #{@failures.size}"
  @failures.each { |f| puts "  - #{f}" }
  exit(@failures.empty? ? 0 : 1)
ensure
  FileUtils.rm_rf(tmp)
end
