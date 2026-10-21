#!/usr/bin/env ruby
# L0 apply integrity: the bytes on disk and the chain record never disagree,
# and two applies computed on one base never both commit.
# Run from the server directory: ruby test_l0_apply_integrity.rb
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'

TMP = Dir.mktmpdir('l0_apply_integrity')
ENV['KAIROS_DATA_DIR'] = TMP

$LOAD_PATH.unshift(File.join(__dir__, 'lib'))
require 'kairos_mcp'
require 'kairos_mcp/safe_evolver'

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

# A transition is a block whose data carries prev_ast_hash.
def transitions
  KairosMcp::KairosChain::Chain.new.chain.count do |b|
    (b.respond_to?(:data) ? b.data : b['data']).to_s.include?('prev_ast_hash')
  end
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
        Evolution rules, revision #{version}. Only content is evolvable.
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

begin
  unless KairosMcp.blockchain_path.to_s.start_with?(TMP)
    abort "refusing to run: chain path #{KairosMcp.blockchain_path} is outside #{TMP}"
  end

  FileUtils.mkdir_p(File.dirname(KairosMcp.dsl_path))
  FileUtils.cp(File.join(__dir__, 'templates', 'skills', 'kairos.rb'), KairosMcp.dsl_path)
  FileUtils.mkdir_p(KairosMcp.versions_dir)
  # The L0 config lives at skills/config.yml (KairosMcp.skills_config_path).
  File.write(KairosMcp.skills_config_path, "evolution_enabled: true\nrequire_human_approval: true\n")
  Kairos.reload! if defined?(Kairos) && Kairos.respond_to?(:reload!)
  base = File.read(KairosMcp.dsl_path)

  # 1. Runaway recursion while the approved definition is loaded.
  t = transitions
  pid = propose('9.1', "def __r(n) = __r(n + 1)\n  __r(0)",
                'case 1: recursion during load')[:proposal_id]
  r = apply_catching(pid, SystemStackError)
  check('1 apply did not report success', !(r.is_a?(Hash) && r[:success]))
  check('1 file equals the base bytes', File.read(KairosMcp.dsl_path) == base)
  check('1 no transition added', transitions == t)

  # 2. The approved definition calls exit.
  t = transitions
  pid = propose('9.2', 'exit 3', 'case 2: exit during load')[:proposal_id]
  r = apply_catching(pid, SystemExit)
  check('2 apply did not report success', !(r.is_a?(Hash) && r[:success]))
  check('2 file equals the base bytes', File.read(KairosMcp.dsl_path) == base)
  check('2 no transition added', transitions == t)

  # 3. The record landed; only the report of it failed.
  t = transitions
  pr = propose('9.3', '', 'case 3: landed record must not be reverted')
  sc = KairosMcp::SafeEvolver.singleton_class
  sc.send(:alias_method, :kc_orig_record_transition, :record_transition)
  begin
    sc.send(:define_method, :record_transition) do |*args|
      kc_orig_record_transition(*args)
      raise KairosMcp::Storage::Error, 'unknown whether the write landed'
    end
    r = apply_catching(pr[:proposal_id], Exception)
  ensure
    sc.send(:alias_method, :record_transition, :kc_orig_record_transition)
    sc.send(:remove_method, :kc_orig_record_transition)
  end
  check('3 apply reported success', r.is_a?(Hash) && r[:success] == true)
  check('3 new bytes kept on disk', File.read(KairosMcp.dsl_path) != base)
  check('3 file hashes to the proposal result',
        pr[:result].nil? || sha(File.read(KairosMcp.dsl_path)) == pr[:result])
  check('3 exactly one transition added', transitions == t + 1)
  base = File.read(KairosMcp.dsl_path)

  # 4. Two proposals on one base; exactly one may commit.
  t = transitions
  pa = propose('9.4', '', 'case 4: first of two on one base')
  pb = propose('9.5', '', 'case 4: second of two on one base')
  dsl = KairosMcp::SkillsDsl.singleton_class
  dsl.send(:alias_method, :kc_orig_load, :load)
  out = []
  begin
    dsl.send(:define_method, :load) do |*args|
      sleep 0.3
      kc_orig_load(*args)
    end
    Thread.report_on_exception = false
    out = [pa, pb].map do |p|
      Thread.new do
        begin
          [p, KairosMcp::SafeEvolver.apply(proposal_id: p[:proposal_id], approved: true)]
        rescue Exception => e
          [p, { success: false, error: e.message }]
        end
      end
    end.map(&:value)
  ensure
    dsl.send(:alias_method, :load, :kc_orig_load)
    dsl.send(:remove_method, :kc_orig_load)
    Thread.report_on_exception = true
  end
  won = out.select { |(_, res)| res[:success] }
  check('4 exactly one apply committed', won.size == 1)
  check('4 the other reports stale', out.count { |(_, res)| res[:stale] } == 1)
  check('4 file hashes to the winner result',
        won.size == 1 && (won[0][0][:result].nil? ||
                          sha(File.read(KairosMcp.dsl_path)) == won[0][0][:result]))
  check('4 exactly one transition added', transitions == t + 1)

  puts
  puts "checks run: #{RUN[0]}, failed: #{FAILED.size}"
  FAILED.each { |l| puts "  - #{l}" }
  exit(FAILED.empty? ? 0 : 1)
ensure
  FileUtils.rm_rf(TMP)
end
