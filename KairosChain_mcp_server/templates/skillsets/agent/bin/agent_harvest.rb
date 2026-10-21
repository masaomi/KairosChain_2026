# frozen_string_literal: true

# Harvest the operator's own words from host transcripts into the agent's
# precedent store (design v0.5.1 INV-5). Run it apart from runs, regularly:
# the host deletes transcripts after 30 days. The operator runs it; the
# store governs runs, so no run writes it.
#
#   ruby .kairos/skillsets/agent/bin/agent_harvest.rb [--data-dir DIR] [--since-days N]
#                                                     [--import-snapshot SNAPSHOT_DIR] [--no-transcripts]

require_relative '../lib/agent/harvest'
require_relative '../lib/agent/run'

def arg(name)
  i = ARGV.index(name)
  i && ARGV[i + 1]
end

data_dir = arg('--data-dir') || ENV['KAIROS_DATA_DIR'] || File.join(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd, '.kairos')
since = (d = arg('--since-days')) ? Time.now - Integer(d) * 86_400 : nil
paths = KairosMcp::SkillSets::Agent::Paths.new(data_dir)
harvest = KairosMcp::SkillSets::Agent::Harvest.new(paths)
if (snap = arg('--import-snapshot'))
  puts "imported #{harvest.import_snapshot(File.expand_path(snap))} snapshot records"
end
puts "harvested #{harvest.run(since: since)} new records from transcripts" unless ARGV.include?('--no-transcripts')
total = KairosMcp::SkillSets::Agent::Precedents.new(paths.precedents_dir).all.size
puts "the store at #{paths.precedents_dir} holds #{total}"
