#!/usr/bin/env ruby
# frozen_string_literal: true
#
# The operator's terminal rulings for the agent (design v0.3, INV-A2 / INV-D8):
# the act-route allow-list, the delegation table, and answers at a stopped
# session.
#
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb activate   # rule the current table into force
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb withdraw   # take it out of force
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb status     # show what is in force (records nothing)
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb answer SESSION_ID
#                         # answer a stopped session; the MCP answer there must then match
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb shadow     # count the shadow judge's agreement
#                                                             # with your answers, per version of what
#                                                             # shaped the judge (records nothing)
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb distill    # draft judgment precedents now, whatever
#                                                             # the count (calls the distiller model)
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb adopt [STAMP]
#                         # adopt a draft (the newest by default) after editing its .edit.md copy
#
# Options: --table NAME       activate / withdraw: act_classification (default)
#                             or delegation
#          --data-dir DIR     the instance data dir whose chain is written
#                             (default: the .kairos this script is installed in)
#          --project-dir DIR  answer / shadow: the directory the MCP server runs
#                             in, whose .kairos/storage holds its agent sessions
#                             (default: the directory holding the data dir).
#                             Needed when the server runs with --data-dir
#                             pointing at another project's .kairos.
#
# activate, withdraw, answer and adopt read a nonce typed back at /dev/tty and refuse to run
# without a terminal. That keeps an MCP call from producing a ruling through
# this path. It does not prove a person typed: any process that can start
# programs can open a pseudo-terminal, read the nonce and type it back (shown
# in review, 2026-10-06), and such a process can write the chain directly
# anyway. 'attested' therefore records the path the ruling came by, not who
# was at the keyboard (INV-D8 boundary; the constrained party is the agent).

require 'json'
require 'rbconfig'

action = ARGV.find { |a| %w[activate withdraw status answer shadow distill adopt].include?(a) }
abort 'usage: agent_rule.rb activate|withdraw [--table act_classification|delegation]|status|answer SESSION_ID|shadow|' \
      'distill|adopt [STAMP] [--data-dir DIR] [--project-dir DIR]' unless action
session_id = action == 'answer' ? ARGV[ARGV.index('answer') + 1].to_s : nil
abort 'usage: agent_rule.rb answer SESSION_ID [--data-dir DIR]' if session_id&.then { |s| s.empty? || s.start_with?('-') }
stamp = action == 'adopt' ? ARGV[ARGV.index('adopt') + 1] : nil
stamp = nil if stamp.to_s.start_with?('-')

tidx = ARGV.index('--table')
table = tidx ? ARGV[tidx + 1].to_s : 'act_classification'
abort "--table must be act_classification or delegation, not #{table.inspect}" unless %w[act_classification delegation].include?(table)

idx = ARGV.index('--data-dir')
data_dir = idx ? File.expand_path(ARGV[idx + 1].to_s) : File.expand_path('../../..', __dir__)
abort "no data dir at #{data_dir}" unless File.directory?(data_dir)

$LOAD_PATH.unshift(ENV['KAIROS_SERVER_LIB']) if ENV['KAIROS_SERVER_LIB']
begin
  require 'kairos_mcp'
  require 'kairos_mcp/kairos_chain/chain'
rescue LoadError => e
  abort "cannot load kairos_mcp (#{e.message}); install the kairos-chain gem or set KAIROS_SERVER_LIB"
end
KairosMcp.data_dir = data_dir

lib = File.expand_path('../lib', __dir__)
require File.join(lib, 'agent', 'admission')
require File.join(lib, 'agent', 'mandate_adapter')
require File.join(lib, 'agent', 'act_classification')
require File.join(lib, 'agent', 'answer_ruling')
require File.join(lib, 'agent', 'delegation')
require File.join(lib, 'agent', 'shadow_judge')
require File.join(lib, 'agent', 'point_facts')
require File.join(lib, 'agent', 'distiller')
require File.join(lib, 'agent', 'distill_run')
require File.join(lib, 'agent', 'adoption')
ac = KairosMcp::SkillSets::Agent::ActClassification
dl = KairosMcp::SkillSets::Agent::Delegation
path = ac::BASE_PATH

puts "Data dir: #{data_dir}"
if %w[answer shadow status distill adopt].include?(action)
  require 'kairos_mcp/invocation_context'
  require File.join(lib, 'agent', 'session')
  require File.join(lib, 'agent', 'advance_gate')
  # The server keeps agent sessions under <its working directory>/.kairos/storage
  # (Session.storage_path without Autonomos loaded), and its chain under its
  # data dir. The two can differ; the answer is read from the first and
  # recorded on the second, the chain the server reads.
  pidx = ARGV.index('--project-dir')
  if pidx && ARGV[pidx + 1].to_s.then { |v| v.empty? || v.start_with?('-') }
    abort "usage: agent_rule.rb #{action == 'answer' ? 'answer SESSION_ID' : action} --project-dir DIR"
  end
  project_dir = pidx ? File.expand_path(ARGV[pidx + 1].to_s) : File.dirname(data_dir)
  abort "no project dir at #{project_dir}" unless File.directory?(project_dir)
  Dir.chdir(project_dir)
  puts "Sessions from: #{project_dir}"
  if action == 'answer'
    session = KairosMcp::SkillSets::Agent::Session.load(session_id)
    unless session
      abort "no agent session #{session_id} under #{File.join(Dir.pwd, '.kairos', 'storage', 'agent_sessions')} " \
            '(if the MCP server runs in another directory, pass --project-dir)'
    end
  end
end
if action == 'status'
  eff = ac.load_effective(path: path)
  puts "Table #{ac::TABLE_ID}: #{eff['status']}"
  puts "  file sha256:  #{eff['sha256']}"
  puts "  ruled sha256: #{eff['ruled_sha256'] || '(none)'}"
  puts "  detail: #{eff['detail']}" if eff['detail']
  puts "  tools in force: #{eff['tools'].keys.sort.join(', ')}" unless eff['tools'].empty?
  deff = dl.load_effective
  puts "Table #{dl::TABLE_ID}: #{deff['status']}"
  puts "  file sha256:  #{deff['sha256']}"
  puts "  detail: #{deff['detail']}" if deff['detail']
  deff['rows'].each { |r| puts "  row #{r['id']} at #{r['point']} (#{r['mode']})" }
  deff['reads'].each do |p|
    puts(p['absent'] ? "  judge reads #{p['name']}: #{p['path']} (absent: nothing adopted yet)" :
                       "  judge reads #{p['name']}: #{p['path']} (sha256 #{p['sha256']})")
  end
  # Drafting (distillation design v0.2 INV-K4): shown here, never in an advance.
  distill_dir = KairosMcp::SkillSets::Agent::Session.storage_path('agent_distill')
  drun = KairosMcp::SkillSets::Agent::DistillRun
  st = drun.state(distill_dir)
  records, rerr = KairosMcp::SkillSets::Agent::AnswerRuling.chain_records
  counted = rerr ? "unknown (#{rerr})" :
                   KairosMcp::SkillSets::Agent::Distiller.count_new(records, high_water: st['high_water'].to_i)
  puts 'Judgment precedents drafting:'
  puts "  reasoned answers since the last draft: #{counted} (a draft starts at #{KairosMcp::SkillSets::Agent::Distiller::THRESHOLD}; " \
       "only while the delegation table is in force)"
  last = st['last'] || {}
  puts "  last run: #{last.empty? ? '(none)' : last.map { |k, v| "#{k} #{v}" }.join(', ')}"
  if last['status'] == 'running'
    # A run holds the lock for its whole life; a free lock means it died.
    # Read the state again while holding the lock: a run that finished in
    # between released it, and is not dead.
    died = File.open(File.join(distill_dir, drun::LOCK_FILE), 'a') do |f|
      f.flock(File::LOCK_EX | File::LOCK_NB) && drun.state(distill_dir).dig('last', 'status') == 'running'
    end
    puts '  (no process holds the drafting lock: that run died before it finished)' if died
  end
  drafts = drun.drafts(distill_dir)
  puts "  drafts: #{drafts.empty? ? '(none)' : drafts.first(3).map { |d| d['stamp'] }.join(', ')}"
  puts "  to adopt the newest: edit #{drafts.first['edit_path']}, then run agent_rule.rb adopt" unless drafts.empty?
  exit 0
end
if action == 'distill'
  # The worker in the foreground, run by the operator: the same code path a
  # count starts, without the count.
  env = { 'KAIROS_PROJECT_ROOT' => Dir.pwd, 'KAIROS_DATA_DIR' => data_dir }
  env['KAIROS_SERVER_LIB'] = ENV['KAIROS_SERVER_LIB'] if ENV['KAIROS_SERVER_LIB']
  puts 'Drafting (this calls the distiller model and may take several minutes)...'
  ok = system(env, RbConfig.ruby, File.expand_path('agent_distill.rb', __dir__), '--manual')
  exit(ok ? 0 : 1)
end
if action == 'shadow'
  ar = KairosMcp::SkillSets::Agent::AnswerRuling
  sj = KairosMcp::SkillSets::Agent::ShadowJudge
  records, error = ar.chain_records
  abort "The chain could not be read (#{error}); nothing to count." if error
  sessions = File.expand_path(File.join('.kairos', 'storage', 'agent_sessions'))
  verdict_dir = lambda do |sid, anchor|
    sid.to_s.match?(/\A[\w-]+\z/) ? sj.anchor_dir(File.join(sessions, sid.to_s), anchor) : File::NULL
  end
  # Counted apart for each version of what shaped the judge (distillation
  # design v0.2 INV-K5): a new adoption, a mode edit or a new judge prompt
  # starts a new count; earlier counts are shown, not merged.
  by = sj.agreement_by_version(records, verdict_dir: verdict_dir)
  total = by['versions'].sum { |v| v['summary']['pairs'] }
  puts "Pairs that count as evidence (your terminal answer, sealed before it): #{total}, " \
       "in #{by['versions'].size} version(s), newest first"
  by['versions'].each_with_index do |v, i|
    sum = v['summary']
    key = v['version']
    yes = sum['operator_approved']
    no = sum['operator_did_not_approve']
    puts "Version #{i + 1} (seals ##{v['first_seal']}..##{v['last_seal']}): judge prompt #{key['judge_prompt'].to_s[0, 12].then { |x| x.empty? ? '(before 3.92.0)' : x }}, " \
         "reads #{key['reads'].map { |r| r.sub(/:(\h{12})\h+\z/, ':\1') }.join(' ')}"
    puts "  you approved:          #{yes['n']}; the judge also approved #{yes['judge_agreed']}"
    puts "  you did not approve:   #{no['n']}; the judge gave the same answer #{no['judge_agreed']}, approved #{no['judge_approved']}"
    puts "  the judge approved #{sum['judge_approved']} of #{sum['pairs']}"
  end
  puts "Not counted: #{by['not_counted'].empty? ? '(none)' : by['not_counted'].map { |k, v| "#{k} #{v}" }.join(', ')}"
  exit 0
end

tty = begin
  File.open('/dev/tty', 'r+')
rescue StandardError => e
  abort "#{action} needs a terminal (/dev/tty: #{e.class}). Run it yourself in a terminal."
end

begin
  result = if action == 'adopt'
             KairosMcp::SkillSets::Agent::Adoption.interactive_adopt(
               dir: KairosMcp::SkillSets::Agent::Session.storage_path('agent_distill'),
               sessions_dir: KairosMcp::SkillSets::Agent::Session.storage_path('agent_sessions'),
               stamp: stamp, tty_in: tty, tty_out: tty
             )
           elsif action == 'answer'
             KairosMcp::SkillSets::Agent::AnswerRuling.interactive_answer(
               session: session, gate: KairosMcp::SkillSets::Agent::AdvanceGate.new(session.guard_dir),
               tty_in: tty, tty_out: tty, reload: -> { KairosMcp::SkillSets::Agent::Session.load(session_id) }
             )
           elsif table == 'delegation'
             dl.interactive_rule(action: action, tty_in: tty, tty_out: tty)
           else
             ac.interactive_rule(action: action, tty_in: tty, tty_out: tty, path: path)
           end
ensure
  tty.close
end
exit(result['recorded'] ? 0 : 1)
