#!/usr/bin/env ruby
# L0 apply on its failure paths: the bytes on disk and the chain record agree
# however the apply ends -- thread kill, interrupt after the record landed,
# another block appended before the error surfaced -- and the restore
# exemption is decided from the chain, never from a stored proposal's kind.
# Run from the server directory: ruby test_l0_interrupted_apply.rb
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'

TMP = Dir.mktmpdir('l0_interrupted_apply')
ENV['KAIROS_DATA_DIR'] = TMP

$LOAD_PATH.unshift(File.join(__dir__, 'lib'))
require 'kairos_mcp'
require 'kairos_mcp/safe_evolver'
require 'kairos_mcp/tools/skills_rollback'

FAILED = []
RUN = [0]

def check(label, ok)
  RUN[0] += 1
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  FAILED << label unless ok
end

def sha(text)
  Digest::SHA256.hexdigest(text)
end

def transitions
  KairosMcp::KairosChain::Chain.new.chain.count do |b|
    (b.respond_to?(:data) ? b.data : b['data']).to_s.include?('prev_ast_hash')
  end
end

def snapshots
  Dir.children(KairosMcp.versions_dir).select { |f| f.end_with?('.rb') }.sort
end

def skill_def(version, body)
  <<~DSL
    skill :evolution_rules do
      version '#{version}'
      title 'Evolution Rules'

      evolve do
        allow :content
        deny :guarantees, :evolve, :behavior
      end

      content <<~MD
        Evolution rules, revision #{version}.
      MD

      #{body}
    end
  DSL
end

def propose(version, body, reason)
  KairosMcp::SafeEvolver.reset_session!
  res = KairosMcp::SafeEvolver.propose(skill_id: 'evolution_rules',
                                       new_definition: skill_def(version, body),
                                       reason: reason)
  raise "propose failed: #{res.inspect}" unless res[:proposal_id]

  res
end

def apply_catching(pid, *fatal)
  KairosMcp::SafeEvolver.apply(proposal_id: pid, approved: true)
rescue *fatal => e
  { success: false, raised: e.class.name }
end

# Replace SafeEvolver.record_transition for the duration of the block.
def with_record_transition(impl)
  sc = KairosMcp::SafeEvolver.singleton_class
  sc.send(:alias_method, :kc_orig_record_transition, :record_transition)
  sc.send(:define_method, :record_transition, &impl)
  yield
ensure
  sc.send(:alias_method, :record_transition, :kc_orig_record_transition)
  sc.send(:remove_method, :kc_orig_record_transition)
end

def tool_text(result)
  Array(result).map { |e| e.is_a?(Hash) ? (e[:text] || e['text']).to_s : e.to_s }.join("\n")
end

begin
  unless KairosMcp.blockchain_path.to_s.start_with?(TMP)
    abort "refusing to run: chain path #{KairosMcp.blockchain_path} is outside #{TMP}"
  end

  FileUtils.mkdir_p(File.dirname(KairosMcp.dsl_path))
  FileUtils.cp(File.join(__dir__, 'templates', 'skills', 'kairos.rb'), KairosMcp.dsl_path)
  FileUtils.mkdir_p(KairosMcp.versions_dir)
  File.write(KairosMcp.skills_config_path, "evolution_enabled: true\nrequire_human_approval: true\n")
  Kairos.reload! if defined?(Kairos) && Kairos.respond_to?(:reload!)
  base = File.read(KairosMcp.dsl_path)

  # 1 (C1). The thread is killed while the approved definition loads. Thread#kill
  # runs ensure clauses only, so a revert in rescue never runs.
  t = transitions
  pid = propose('9.1', '', 'case 1: thread killed during load')[:proposal_id]
  dsl = KairosMcp::SkillsDsl.singleton_class
  dsl.send(:alias_method, :kc_orig_load, :load)
  begin
    dsl.send(:define_method, :load) do |*args|
      sleep 1.0 unless Thread.current == Thread.main
      kc_orig_load(*args)
    end
    worker = Thread.new { KairosMcp::SafeEvolver.apply(proposal_id: pid, approved: true) }
    sleep 0.3
    worker.kill
    worker.join
  ensure
    dsl.send(:alias_method, :load, :kc_orig_load)
    dsl.send(:remove_method, :kc_orig_load)
  end
  check('1 file equals the base bytes after the kill', File.read(KairosMcp.dsl_path) == base)
  check('1 no transition added', transitions == t)

  # 2 (C1). An interrupt arrives after the record landed: the L0 the chain
  # records as in force stays, and the interrupt still propagates.
  t = transitions
  pr = propose('9.2', '', 'case 2: interrupt after the record landed')
  r = nil
  with_record_transition(lambda do |*args|
    kc_orig_record_transition(*args)
    raise Interrupt
  end) { r = apply_catching(pr[:proposal_id], Interrupt) }
  check('2 the interrupt propagated', r.is_a?(Hash) && r[:raised] == 'Interrupt')
  check('2 file hashes to the recorded result', sha(File.read(KairosMcp.dsl_path)) == pr[:result])
  check('2 exactly one transition added', transitions == t + 1)
  base = File.read(KairosMcp.dsl_path)

  # 3 (C4). The record landed, another block was appended after it, then the
  # append reported an unknown outcome. The last block is not ours; the record is.
  t = transitions
  pr = propose('9.3', '', 'case 3: landed, then another block')
  with_record_transition(lambda do |*args|
    kc_orig_record_transition(*args)
    KairosMcp::KairosChain::Chain.new.add_block([{ type: 'unrelated', note: 'appended by someone else' }.to_json])
    raise KairosMcp::Storage::Error, 'unknown whether the write landed'
  end) { r = apply_catching(pr[:proposal_id], Exception) }
  check('3 apply reported success', r.is_a?(Hash) && r[:success] == true)
  check('3 file hashes to the recorded result', sha(File.read(KairosMcp.dsl_path)) == pr[:result])
  check('3 exactly one transition added', transitions == t + 1)
  base = File.read(KairosMcp.dsl_path)

  # 4. Unknown outcome and the record did not land: revert.
  t = transitions
  pr = propose('9.4', '', 'case 4: unknown outcome, not landed')
  with_record_transition(lambda do |*_args|
    raise KairosMcp::Storage::Error, 'unknown whether the write landed'
  end) { r = apply_catching(pr[:proposal_id], Exception) }
  check('4 apply did not report success', r.is_a?(Hash) && r[:success] == false)
  check('4 file equals the base bytes', File.read(KairosMcp.dsl_path) == base)
  check('4 no transition added', transitions == t)

  # 5. The approved definition calls exit: reverted, and SystemExit propagates.
  t = transitions
  pid = propose('9.5', 'exit 3', 'case 5: exit during load')[:proposal_id]
  r = apply_catching(pid, SystemExit)
  check('5 SystemExit propagated', r.is_a?(Hash) && r[:raised] == 'SystemExit')
  check('5 file equals the base bytes', File.read(KairosMcp.dsl_path) == base)
  check('5 no transition added', transitions == t)

  # 6 (C2). A hand-written proposal file that claims kind restore, for content
  # that was never in force. Neither apply nor the rollback tool may write it.
  t = transitions
  forged = "#{base}\n# never proposed, never recorded\n"
  fid = KairosMcp::L0ProposalStore.save(skill_id: 'kairos.rb', kind: 'restore',
                                        base: sha(base), result: sha(forged), content: forged,
                                        reason: 'hand-written')
  r = apply_catching(fid, Exception)
  check('6 apply refused the forged restore', r.is_a?(Hash) && r[:success] == false)
  check('6 file equals the base bytes', File.read(KairosMcp.dsl_path) == base)
  check('6 no transition added', transitions == t)
  text = tool_text(KairosMcp::Tools::SkillsRollback.new.call('command' => 'rollback',
                                                              'proposal_id' => fid, 'approved' => true))
  check('6 the rollback tool refused it too', !text.include?('Rollback successful'))
  check('6 file still equals the base bytes', File.read(KairosMcp.dsl_path) == base)

  # 7. A proposal whose content does not hash to its result: refused before
  # anything is written -- no snapshot, no write.
  t = transitions
  s = snapshots
  pr = propose('9.7', '', 'case 7: content tampered after storing')
  path = KairosMcp::L0ProposalStore.path_for(pr[:proposal_id])
  stored = JSON.parse(File.read(path))
  stored['content'] = "#{stored['content']}\n# tampered\n"
  File.write(path, JSON.pretty_generate(stored))
  r = apply_catching(pr[:proposal_id], Exception)
  check('7 apply refused', r.is_a?(Hash) && r[:success] == false)
  check('7 no snapshot was taken', snapshots == s)
  check('7 file equals the base bytes', File.read(KairosMcp.dsl_path) == base)
  check('7 no transition added', transitions == t)

  # 8. Provenance filters: a hash that appears only in an instruction-mode
  # transition, or only in an entry without prev_ast_hash, was never in force.
  only_instr = "#{base}\n# seen only in an instruction-mode record\n"
  only_next = "#{base}\n# seen only in an entry without prev_ast_hash\n"
  File.write(File.join(KairosMcp.versions_dir, 'kairos_20990101_000001.rb'), only_instr)
  File.write(File.join(KairosMcp.versions_dir, 'kairos_20990101_000002.rb'), only_next)
  KairosMcp::KairosChain::Chain.new.add_block([
    { skill_id: 'instructions:masa', prev_ast_hash: sha(base), next_ast_hash: sha(only_instr) }.to_json,
    { type: 'note', next_ast_hash: sha(only_next) }.to_json
  ])
  r = KairosMcp::SafeEvolver.propose_restore(version: 'kairos_20990101_000001.rb')
  check('8 instruction-mode-only hash refused', r[:success] == false)
  r = KairosMcp::SafeEvolver.propose_restore(version: 'kairos_20990101_000002.rb')
  check('8 hash without prev_ast_hash refused', r[:success] == false)

  puts
  puts "checks run: #{RUN[0]}, failed: #{FAILED.size}"
  FAILED.each { |l| puts "  - #{l}" }
  exit(FAILED.empty? ? 0 : 1)
ensure
  FileUtils.rm_rf(TMP)
end
