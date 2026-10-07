#!/usr/bin/env ruby
# frozen_string_literal: true
#
# The operator's terminal ruling on the agent's act-route allow-list
# (design v0.3, INV-A2 / INV-D8).
#
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb activate   # rule the current table into force
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb withdraw   # take it out of force
#   ruby .kairos/skillsets/agent/bin/agent_rule.rb status     # show what is in force (records nothing)
#
# Options: --data-dir DIR   the instance data dir whose chain is written
#                           (default: the .kairos this script is installed in)
#
# activate and withdraw read a nonce typed back at /dev/tty and refuse to run
# without a terminal. That keeps an MCP call from producing a ruling through
# this path. It does not prove a person typed: any process that can start
# programs can open a pseudo-terminal, read the nonce and type it back (shown
# in review, 2026-10-06), and such a process can write the chain directly
# anyway. 'attested' therefore records the path the ruling came by, not who
# was at the keyboard (INV-D8 boundary; the constrained party is the agent).

require 'json'

action = ARGV.find { |a| %w[activate withdraw status].include?(a) }
abort 'usage: agent_rule.rb activate|withdraw|status [--data-dir DIR]' unless action

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
ac = KairosMcp::SkillSets::Agent::ActClassification
path = ac::BASE_PATH

puts "Data dir: #{data_dir}"
if action == 'status'
  eff = ac.load_effective(path: path)
  puts "Table #{ac::TABLE_ID}: #{eff['status']}"
  puts "  file sha256:  #{eff['sha256']}"
  puts "  ruled sha256: #{eff['ruled_sha256'] || '(none)'}"
  puts "  detail: #{eff['detail']}" if eff['detail']
  puts "  tools in force: #{eff['tools'].keys.sort.join(', ')}" unless eff['tools'].empty?
  exit 0
end

tty = begin
  File.open('/dev/tty', 'r+')
rescue StandardError => e
  abort "#{action} needs a terminal (/dev/tty: #{e.class}). Run it yourself in a terminal."
end

begin
  result = ac.interactive_rule(action: action, tty_in: tty, tty_out: tty, path: path)
ensure
  tty.close
end
exit(result['recorded'] ? 0 : 1)
