#!/usr/bin/env ruby
# frozen_string_literal: true

# Restore provenance, and approval bound to the proposal that was displayed.
#
#   F2a  propose_restore accepts a snapshot only when its bytes appear in a
#        recorded transition of the core definition.
#   F2b  an approved rollback applies the proposal that was shown, not a fresh one.
#   F2c  VersionManager.rollback no longer exists.
#
# Everything happens inside a temporary data directory, which is removed at the end.

require 'fileutils'
require 'tmpdir'
require 'digest'
require 'json'

TMP = File.join(Dir.tmpdir, "l0_restore_provenance_#{Process.pid}")
FileUtils.mkdir_p(TMP)

# Set before the library is required, so every path it computes lands in TMP.
ENV['KAIROS_DATA_DIR'] = TMP

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'kairos_mcp'
require 'kairos_mcp/safe_evolver'
require 'kairos_mcp/tools/skills_rollback'

chain_path = KairosMcp.blockchain_path.to_s
unless chain_path.start_with?(TMP)
  FileUtils.rm_rf(TMP)
  abort "refusing to run: chain path #{chain_path} is outside #{TMP}"
end

def definition_for(revision)
  <<~DSL.chomp
    skill :evolution_rules do
      version "1.#{revision}"
      title "Evolution Rules"
      evolve do
        allow :content
        deny :guarantees, :evolve, :behavior
      end
      content 'Revision #{revision}.'
    end
  DSL
end

# The same instance the sibling L0 tests build: the shipped template L0 and
# the L0 config at skills/config.yml.
FileUtils.mkdir_p(File.dirname(KairosMcp.dsl_path))
FileUtils.cp(File.expand_path('templates/skills/kairos.rb', __dir__), KairosMcp.dsl_path)
FileUtils.mkdir_p(KairosMcp.versions_dir)
File.write(KairosMcp.skills_config_path, "evolution_enabled: true\nrequire_human_approval: true\n")

PASSED = []
FAILED = []

def assert(label, ok)
  if ok
    PASSED << label
    puts "  ok   #{label}"
  else
    FAILED << label
    puts "  FAIL #{label}"
  end
  ok
end

def val(hash, key)
  return nil unless hash.is_a?(Hash)

  v = hash[key.to_sym]
  v.nil? ? hash[key.to_s] : v
end

def transitions
  KairosMcp::KairosChain::Chain.new.chain.select do |block|
    entries = block.data
    entries.is_a?(Array) && entries.any? { |e| e.to_s.include?('"prev_ast_hash"') }
  end
end

def versions_dir
  KairosMcp.versions_dir
end

def snapshot_names
  FileUtils.mkdir_p(versions_dir)
  Dir.children(versions_dir).select { |f| f.end_with?('.rb') }.sort
end

# Crude but read-only: the proposal store path is not part of the public API,
# so stored proposals are counted by scanning the temporary data directory.
def proposal_files
  Dir.glob(File.join(TMP, '**', '*')).select { |f| File.file?(f) && f.include?('proposal') }.sort
end

def l0_bytes
  File.read(KairosMcp.dsl_path)
end

def evolve(revision, reason)
  KairosMcp::SafeEvolver.reset_session!
  KairosMcp::SafeEvolver.apply(skill_id: 'evolution_rules',
                               new_definition: definition_for(revision),
                               approved: true, reason: reason)
end

def tool_text(result)
  entries = result.is_a?(Array) ? result : (result[:content] || result['content'] || [])
  entries.map { |e| e.is_a?(Hash) ? (e[:text] || e['text']).to_s : e.to_s }.join("\n")
end

begin
  puts 'Case 1: a snapshot that was never in force is refused'
  FileUtils.mkdir_p(versions_dir)
  planted = File.join(versions_dir, 'kairos_20990101_000000.rb')
  File.write(planted, "#{l0_bytes}\n# a change that was never proposed or recorded\n")
  planted_hash = Digest::SHA256.hexdigest(File.read(planted))
  stored_before = proposal_files

  r1 = KairosMcp::SafeEvolver.propose_restore(version: File.basename(planted), reason: 'planted')
  assert('C1 refused', !val(r1, 'success'))
  assert('C1 the error names the hash', val(r1, 'error').to_s.include?(planted_hash))
  assert('C1 the error points at skills_evolve', val(r1, 'error').to_s.include?('skills_evolve'))
  assert('C1 no proposal was stored', proposal_files == stored_before)

  puts 'Case 2: the snapshot of a definition that was in force is accepted'
  original = l0_bytes
  names_before = snapshot_names
  evolve(1, 'revision 1')
  added = snapshot_names - names_before
  assert('C2 the evolve wrote exactly one snapshot', added.size == 1)
  snapshot = added.first
  assert('C2 that snapshot holds the original bytes',
         !snapshot.nil? && File.read(File.join(versions_dir, snapshot)) == original)
  r2 = KairosMcp::SafeEvolver.propose_restore(version: snapshot, reason: 'return to revision 0')
  assert('C2 accepted', val(r2, 'success') == true)

  puts 'Case 3: the approval binds the proposal that was displayed'
  pending = KairosMcp::Tools::SkillsRollback.new.call('command' => 'rollback', 'version' => snapshot)
  pending_text = tool_text(pending)
  assert('C3 the pending message names a proposal_id', pending_text.include?('proposal_id='))
  pid = pending_text[/proposal_id=([^\s,.'")]+)/, 1]
  assert('C3 the proposal_id is readable', !pid.nil? && !pid.empty?)

  evolve(2, 'revision 2')
  drifted = l0_bytes

  applied = KairosMcp::Tools::SkillsRollback.new.call('command' => 'rollback',
                                                      'proposal_id' => pid,
                                                      'approved' => true)
  applied_text = tool_text(applied)
  assert('C3 a stale proposal is not applied', !applied_text.include?('Rollback successful'))
  assert('C3 the definition is unchanged', l0_bytes == drifted)

  puts 'Case 4: the ungated write path is gone'
  assert('C4 VersionManager.rollback removed',
         KairosMcp::VersionManager.respond_to?(:rollback) == false)

  puts
  puts "passed: #{PASSED.size}  failed: #{FAILED.size}  recorded transitions: #{transitions.size}"
  FAILED.each { |label| puts "  failed: #{label}" }
  exit(FAILED.empty? ? 0 : 1)
ensure
  FileUtils.rm_rf(TMP)
end
