# frozen_string_literal: true

# The policy report (design v0.7.2 INV-8): for each rule of the adopted
# policy, what the runs the chain records as ended hold against it — counts
# with their denominators and the operator's words of each act. The operator
# runs it outside runs. It reads the data directory, calls no model,
# evaluates no file from a run directory, writes one file under
# storage/agent/policy_reports (and storage/agent/.gitignore when absent), and
# changes no policy.
#
#   ruby .kairos/skillsets/agent/bin/agent_policy_report.rb [--data-dir DIR]

require_relative '../lib/agent/policy_report'

def arg(name)
  i = ARGV.index(name)
  i && ARGV[i + 1]
end

data_dir = arg('--data-dir') || ENV['KAIROS_DATA_DIR'] || File.join(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd, '.kairos')
paths = KairosMcp::SkillSets::Agent::Paths.new(data_dir)
begin
  puts KairosMcp::SkillSets::Agent::PolicyReport.new(paths).write
rescue ArgumentError, IOError, SystemCallError => e
  abort e.message
end
