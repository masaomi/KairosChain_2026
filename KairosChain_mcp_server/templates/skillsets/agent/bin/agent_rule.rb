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
#                                                             # with your answers (records nothing)
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
# activate, withdraw and answer read a nonce typed back at /dev/tty and refuse to run
# without a terminal. That keeps an MCP call from producing a ruling through
# this path. It does not prove a person typed: any process that can start
# programs can open a pseudo-terminal, read the nonce and type it back (shown
# in review, 2026-10-06), and such a process can write the chain directly
# anyway. 'attested' therefore records the path the ruling came by, not who
# was at the keyboard (INV-D8 boundary; the constrained party is the agent).

require 'json'

action = ARGV.find { |a| %w[activate withdraw status answer shadow].include?(a) }
abort 'usage: agent_rule.rb activate|withdraw [--table act_classification|delegation]|status|answer SESSION_ID|shadow ' \
      '[--data-dir DIR] [--project-dir DIR]' unless action
session_id = action == 'answer' ? ARGV[ARGV.index('answer') + 1].to_s : nil
abort 'usage: agent_rule.rb answer SESSION_ID [--data-dir DIR]' if session_id&.then { |s| s.empty? || s.start_with?('-') }

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
ac = KairosMcp::SkillSets::Agent::ActClassification
dl = KairosMcp::SkillSets::Agent::Delegation
path = ac::BASE_PATH

puts "Data dir: #{data_dir}"
if %w[answer shadow].include?(action)
  require 'kairos_mcp/invocation_context'
  require File.join(lib, 'agent', 'session')
  require File.join(lib, 'agent', 'advance_gate')
  # The server keeps agent sessions under <its working directory>/.kairos/storage
  # (Session.storage_path without Autonomos loaded), and its chain under its
  # data dir. The two can differ; the answer is read from the first and
  # recorded on the second, the chain the server reads.
  pidx = ARGV.index('--project-dir')
  abort 'usage: agent_rule.rb answer SESSION_ID --project-dir DIR' if pidx && ARGV[pidx + 1].to_s.then { |v| v.empty? || v.start_with?('-') }
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
  deff['reads'].each { |p| puts "  judge reads #{p['name']}: #{p['path']} (sha256 #{p['sha256']})" }
  exit 0
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
  sum = sj.agreement(records, verdict_dir: verdict_dir)
  yes = sum['operator_approved']
  no = sum['operator_did_not_approve']
  puts "Pairs that count as evidence (your terminal answer, sealed before it): #{sum['pairs']}"
  puts "  you approved:          #{yes['n']}; the judge also approved #{yes['judge_agreed']}"
  puts "  you did not approve:   #{no['n']}; the judge gave the same answer #{no['judge_agreed']}, approved #{no['judge_approved']}"
  puts "  the judge approved #{sum['judge_approved']} of #{sum['pairs']}"
  puts "Not counted: #{sum['not_counted'].empty? ? '(none)' : sum['not_counted'].map { |k, v| "#{k} #{v}" }.join(', ')}"
  exit 0
end

tty = begin
  File.open('/dev/tty', 'r+')
rescue StandardError => e
  abort "#{action} needs a terminal (/dev/tty: #{e.class}). Run it yourself in a terminal."
end

begin
  result = if action == 'answer'
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
