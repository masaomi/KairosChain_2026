#!/usr/bin/env ruby
# frozen_string_literal: true

# skills_rollback with proposal_id: everything shown, applied and logged
# describes the stored proposal. The caller's `version` never changes what is
# summarised or what is written; a non-restore proposal and a stale one are
# refused by the tool itself.
#
# Run from the server directory: ruby test_skills_rollback_binding.rb

require 'fileutils'
require 'tmpdir'
require 'digest'
require 'json'

TMP = Dir.mktmpdir('skills_rollback_binding')
ENV['KAIROS_DATA_DIR'] = TMP

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
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

def definition_for(revision, extra_lines = 0)
  filler = (1..extra_lines).map { |i| "      # filler line #{i} of revision #{revision}" }.join("\n")
  <<~DSL.chomp
    skill :evolution_rules do
      version "1.#{revision}"
      title "Evolution Rules"
      evolve do
        allow :content
        deny :guarantees, :evolve, :behavior
      end
      content 'Revision #{revision}.'
    #{filler}
    end
  DSL
end

def evolve(revision, extra_lines = 0)
  KairosMcp::SafeEvolver.reset_session!
  res = KairosMcp::SafeEvolver.apply(skill_id: 'evolution_rules',
                                     new_definition: definition_for(revision, extra_lines),
                                     approved: true, reason: "revision #{revision}")
  raise "evolve failed: #{res.inspect}" unless res[:success]
end

def snapshot_names
  Dir.children(KairosMcp.versions_dir).select { |f| f.end_with?('.rb') }.sort
end

def l0_bytes
  File.read(KairosMcp.dsl_path)
end

def rollback(args)
  out = KairosMcp::Tools::SkillsRollback.new.call({ 'command' => 'rollback' }.merge(args))
  Array(out).map { |e| e.is_a?(Hash) ? (e[:text] || e['text']).to_s : e.to_s }.join("\n")
end

def line_summary(restored, current)
  r = restored.lines
  c = current.lines
  "+#{(r - c).size} / -#{(c - r).size} lines"
end

begin
  unless KairosMcp.blockchain_path.to_s.start_with?(TMP)
    abort "refusing to run: chain path #{KairosMcp.blockchain_path} is outside #{TMP}"
  end

  FileUtils.mkdir_p(File.dirname(KairosMcp.dsl_path))
  FileUtils.cp(File.expand_path('templates/skills/kairos.rb', __dir__), KairosMcp.dsl_path)
  FileUtils.mkdir_p(KairosMcp.versions_dir)
  File.write(KairosMcp.skills_config_path, "evolution_enabled: true\nrequire_human_approval: true\n")

  # Two snapshots whose distance from the current content differs, so a
  # summary of the wrong one is visible in the numbers.
  before = snapshot_names
  evolve(1, 12)
  s_far = (snapshot_names - before).first # the template, far from what follows
  before = snapshot_names
  evolve(2)
  s_near = (snapshot_names - before).first # revision 1
  evolve(3)
  current = l0_bytes
  far_bytes = File.read(File.join(KairosMcp.versions_dir, s_far))
  near_bytes = File.read(File.join(KairosMcp.versions_dir, s_near))
  check('setup: the two summaries differ',
        line_summary(far_bytes, current) != line_summary(near_bytes, current))

  # 1. Pending: proposal for s_far, caller passes version s_near.
  text = rollback('version' => s_far)
  pid = text[/proposal_id=([0-9a-f]+)/, 1]
  check('1 a proposal id is shown', !pid.nil?)
  text = rollback('proposal_id' => pid, 'version' => s_near)
  check('1 nothing was written', l0_bytes == current)
  check('1 the summary describes the proposal', text.include?(line_summary(far_bytes, current)))
  check('1 the summary is not the caller version\'s', !text.include?(line_summary(near_bytes, current)))
  check('1 the proposal\'s snapshot is named', text.include?(s_far))
  check('1 the ignored version is called out', text.include?("version #{s_near} was given"))

  # 2. Approved with the mismatching version: the proposal's content is written.
  text = rollback('proposal_id' => pid, 'version' => s_near, 'approved' => true)
  check('2 the rollback succeeded', text.include?('Rollback successful'))
  check('2 L0 holds the proposal\'s content', l0_bytes == far_bytes)
  check('2 the success text names the written hash', text.include?(sha(far_bytes)))
  check('2 the success text does not claim the caller version', !text.include?("Restored to: #{s_near}"))

  # 3. An evolve proposal cannot be applied through the rollback tool.
  KairosMcp::SafeEvolver.reset_session!
  evolve_pid = KairosMcp::SafeEvolver.propose(skill_id: 'evolution_rules',
                                              new_definition: definition_for(4),
                                              reason: 'not a restore')[:proposal_id]
  held = l0_bytes
  text = rollback('proposal_id' => evolve_pid, 'approved' => true)
  check('3 refused as not a restore', text.include?('not restore'))
  check('3 nothing was written', l0_bytes == held)

  # 4. A stale restore proposal is reported stale, not offered for approval.
  text = rollback('version' => s_near)
  stale_pid = text[/proposal_id=([0-9a-f]+)/, 1]
  evolve(5)
  held = l0_bytes
  text = rollback('proposal_id' => stale_pid)
  check('4 reported stale', text.include?('stale'))
  check('4 not offered for approval', !text.include?('requires approval'))
  check('4 nothing was written', l0_bytes == held)

  puts
  puts "checks run: #{RUN[0]}, failed: #{FAILED.size}"
  FAILED.each { |l| puts "  - #{l}" }
  exit(FAILED.empty? ? 0 : 1)
ensure
  FileUtils.rm_rf(TMP)
end
