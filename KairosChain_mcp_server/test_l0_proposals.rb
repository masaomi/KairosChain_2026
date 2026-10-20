#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression test for the L0 proposal store: propose / apply / add_skill.
# Every case below fails on the pre-change code.

require 'tmpdir'
require 'fileutils'
require 'digest'
require 'yaml'

# Isolation first: the data dir must be set BEFORE kairos_mcp loads.
tmp = Dir.mktmpdir
ENV['KAIROS_DATA_DIR'] = tmp

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/safe_evolver'
require 'kairos_mcp/tools/skills_evolve'

abort "isolation failed: #{KairosMcp.blockchain_path}" unless
  KairosMcp.blockchain_path.to_s.start_with?(tmp)

@passes = 0
@failures = 0

def assert(cond, msg)
  if cond
    @passes += 1
    puts "  ok   #{msg}"
  else
    @failures += 1
    puts "  FAIL #{msg}"
  end
end

def sha(path)
  Digest::SHA256.hexdigest(File.binread(path))
end

# Count L0 transitions, not blocks: the first append also creates genesis.
def transitions
  KairosMcp::KairosChain::Chain.new.chain.count do |b|
    b.data.any? { |d| d.to_s.include?('"prev_ast_hash"') }
  end
end

# A complete evolution_rules block. title and the evolve block stay
# byte-identical across cases; only version, content and one optional
# extra body line vary.
def full_block(version, content, extra = nil)
  lines = ['skill :evolution_rules do',
           "  version '#{version}'",
           "  title 'Evolution Rules'",
           '  evolve do',
           '    allow :content',
           '    deny :guarantees, :evolve, :behavior',
           '  end']
  lines << "  #{extra}" if extra
  lines << "  content #{content}"
  lines << 'end'
  lines.join("\n") + "\n"
end

def propose(defn, reason)
  KairosMcp::SafeEvolver.propose(skill_id: 'evolution_rules',
                                 new_definition: defn, reason: reason)
end

# A missing reason counts as a mechanical auto-check failure, so every call
# carries one; older id-form apply signatures take no reason:.
def apply_proposal(id, approved, reason)
  KairosMcp::SafeEvolver.apply(proposal_id: id, approved: approved, reason: reason)
rescue ArgumentError
  KairosMcp::SafeEvolver.apply(proposal_id: id, approved: approved)
end

marker = File.join(tmp, 'marker.txt')

begin
  # --- instance setup ---
  src = File.binread(File.expand_path('templates/skills/kairos.rb', __dir__))

  # Excise audit_rules by literal index split, so add_skill('audit_rules') has an
  # allowed but absent target. No sub/gsub: a replacement string would
  # reinterpret backslash escapes.
  i = src.index('skill :audit_rules do') or abort 'audit_rules block not found'
  j = src.index("\nend\n", i) or abort 'audit_rules end not found'
  src = src[0...i] + src[(j + 5)..]

  FileUtils.mkdir_p(File.dirname(KairosMcp.dsl_path))
  File.binwrite(KairosMcp.dsl_path, src)
  FileUtils.mkdir_p(KairosMcp.versions_dir)
  FileUtils.mkdir_p(File.dirname(KairosMcp.skills_config_path))
  File.write(KairosMcp.skills_config_path,
             { 'evolution_enabled' => true, 'require_human_approval' => true }.to_yaml)

  assert !src.include?('skill :audit_rules'), 'setup: audit_rules absent from the copy'
  assert src.include?('skill :evolution_rules'), 'setup: evolution_rules present'
  assert transitions.zero?, 'setup: no L0 transitions yet'

  base_bytes = File.binread(KairosMcp.dsl_path)

  # --- case 1: propose stores, never evaluates (absolute pending count: runs first)
  d1 = full_block('9.1', "'case1'", %(File.write(#{marker.inspect}, "x")))
  p1 = propose(d1, 'test: propose must not evaluate the definition')
  assert p1[:success] && p1[:pending], 'case1: propose succeeded and is pending'
  assert !File.exist?(marker), 'case1: skill body never ran (no marker)'
  assert File.binread(KairosMcp.dsl_path) == base_bytes, 'case1: L0 bytes unchanged'
  assert KairosMcp::SafeEvolver.pending_proposals.size == 1, 'case1: exactly one pending proposal'

  # --- case 2: byte-exact write of an escape-laden single-quoted literal
  esc = <<~'TXT'.strip
    'esc \0 \& \\ \' ok'
  TXT
  d2 = full_block('9.2', esc)
  p2 = propose(d2, 'test: escapes must survive the write')
  assert p2[:success], 'case2: propose succeeded'
  t = transitions
  a2 = apply_proposal(p2[:proposal_id], true, 'test: approved apply')
  assert a2[:success], "case2: approved apply succeeded (#{a2[:error]})"
  assert sha(KairosMcp.dsl_path) == p2[:result], 'case2: file hashes to the proposal result'
  assert File.binread(KairosMcp.dsl_path).include?(d2), 'case2: definition bytes written verbatim'
  assert transitions == t + 1, 'case2: exactly one transition added'

  # --- case 3: two proposals on one base; the second is stale
  p3a = propose(full_block('9.3', "'case3a'"), 'test: first on the shared base')
  p3b = propose(full_block('9.4', "'case3b'"), 'test: second on the shared base')
  assert p3a[:base] == p3b[:base], 'case3: both proposals share one base'
  assert apply_proposal(p3a[:proposal_id], true, 'test: first wins')[:success], 'case3: first apply succeeded'
  a3b = apply_proposal(p3b[:proposal_id], true, 'test: second must be refused')
  assert !a3b[:success] && a3b[:stale], 'case3: second refused with stale: true'
  assert sha(KairosMcp.dsl_path) == p3a[:result], 'case3: file still hashes to the first result'

  # --- case 4: load failure restores the exact previous bytes
  p4 = propose(full_block('9.5', "'case4'", 'raise "boom"'), 'test: load failure must restore')
  assert p4[:success], 'case4: propose succeeded (definition not evaluated)'
  before = File.binread(KairosMcp.dsl_path)
  t = transitions
  assert !apply_proposal(p4[:proposal_id], true, 'test: load failure')[:success], 'case4: approved apply failed'
  assert File.binread(KairosMcp.dsl_path) == before, 'case4: file restored to the previous bytes'
  assert transitions == t, 'case4: no transition recorded'

  # --- case 5: the approval gate
  p5 = propose(full_block('9.6', "'case5'"), 'test: unapproved apply writes nothing')
  before = File.binread(KairosMcp.dsl_path)
  t = transitions
  a5 = apply_proposal(p5[:proposal_id], false, 'test: not approved')
  assert !a5[:success] && a5[:pending], 'case5: unapproved apply refused, still pending'
  assert File.binread(KairosMcp.dsl_path) == before, 'case5: nothing written'
  assert transitions == t, 'case5: no transition recorded'
  row = KairosMcp::SafeEvolver.pending_proposals.find { |h| h['id'] == p5[:proposal_id] }
  assert row && row['applied_at'].nil?, 'case5: proposal still pending in the store'

  # --- case 6: legacy one-call apply, then add_skill
  t = transitions
  a6 = KairosMcp::SafeEvolver.apply(skill_id: 'evolution_rules',
                                    new_definition: full_block('9.7', "'case6'"),
                                    approved: true, reason: 'test: legacy one-call path')
  assert a6[:success], "case6: legacy apply succeeded (#{a6[:error]})"
  assert transitions == t + 1, 'case6: legacy apply added exactly one transition'

  # The L0 auto-check limits evolutions per session (max_evolutions_per_session: 3);
  # three applies have run, so start a fresh session as the reset command does.
  KairosMcp::SafeEvolver.reset_session!
  body = ["  version '1.0'", "  title 'Audit Rules'", "  content 'audit'"].join("\n")
  t = transitions
  add = KairosMcp::SafeEvolver.add_skill(skill_id: 'audit_rules', definition: body,
                                         approved: true, reason: 'test: add an allowed absent skill')
  assert add[:success], "case6: add_skill succeeded (#{add[:error]})"
  assert transitions == t + 1, 'case6: add_skill added exactly one transition'
  dup = KairosMcp::SafeEvolver.add_skill(skill_id: 'audit_rules', definition: body,
                                         approved: true, reason: 'test: duplicate must be refused')
  assert !dup[:success], 'case6: second add_skill for the same id refused'

  # --- case 7: re-applying an already applied proposal
  re = apply_proposal(p2[:proposal_id], true, 'test: re-apply must be refused')
  assert !re[:success], 'case7: re-apply refused'
  assert re[:error].to_s.downcase.include?('already applied'), "case7: error says already applied (#{re[:error]})"

  # --- case 8: the tool surface lists the still-pending case-1 proposal
  out = KairosMcp::Tools::SkillsEvolve.new.call({ 'command' => 'pending' })
  items = out.is_a?(Array) ? out : (out[:content] || out['content'] || [])
  text = items.map { |c| (c[:text] || c['text']).to_s }.join("\n")
  assert text.include?(p1[:proposal_id].to_s), 'case8: pending command lists the case-1 id'
ensure
  puts "\npasses: #{@passes}  failures: #{@failures}"
  FileUtils.rm_rf(tmp)
end

exit(@failures.zero? ? 0 : 1)
