# frozen_string_literal: true

# Release gate: the whole write path, driven from an INSTALLED gem.
#
# Run this before every push. The unit suite cannot stand in for it and did not.
# 137 tests were green while record_to_chain guarded on a constant that does not
# exist, so every apply refused and stage 2 had never once written a file. The
# test double replaces that method, so the real one had never executed. A
# reviewer found it in one run of this path; nobody on the authoring side had
# ever taken it.
#
# Usage:
#   gem build kairos-chain.gemspec
#   GEM_HOME=/tmp/kcsmoke/gems GEM_PATH=/tmp/kcsmoke/gems \
#     gem install --no-document -i /tmp/kcsmoke/gems kairos-chain-<version>.gem
#   ruby test_installed_gem_smoke.rb
#
# The first install fetches the base64 dependency, so that step needs network.
#
# Nothing here may touch the real ledger or the real harness configuration:
# KAIROS_DATA_DIR and the working directory are both inside the scratch tree,
# and the script proposes before it applies so the reported write set can be
# read before anything is written.

require 'json'
require 'fileutils'
require 'shellwords'

ROOT = '/tmp/kcsmoke'
PROJECT = File.join(ROOT, 'project')
DATA = File.join(PROJECT, '.kairos')
GEMS = File.join(ROOT, 'gems')

FileUtils.rm_rf(PROJECT)
FileUtils.mkdir_p(File.join(DATA, 'skills'))
FileUtils.mkdir_p(File.join(PROJECT, '.claude'))

BODY = <<~MD
  # Smoke Mode

  ## § Readable output

  Keep replies under 12 lines.
MD
File.write(File.join(DATA, 'skills', 'smoke.md'), BODY)

require 'digest'
File.write(File.join(DATA, 'skills', 'smoke.mode_hooks.json'), JSON.pretty_generate(
  'mode_name' => 'smoke', 'version' => '1',
  'binding' => { 'mode_version' => '0.1', 'mode_body_sha256' => Digest::SHA256.hexdigest(BODY) },
  'hooks' => { 'Stop' => [{ 'gate' => 'readable_gate', 'section' => '§ Readable output',
                            'blocking' => false,
                            'params' => { 'max_lines' => 12,
                                          'log_path' => File.join(PROJECT, 'gate.log') } }] }
))

# A harness config with content of its own, to see whether it survives.
File.write(File.join(PROJECT, '.claude', 'settings.json'), JSON.pretty_generate(
  'permissions' => { 'allow' => ['Bash(git:*)'] },
  'hooks' => { 'Stop' => [{ 'hooks' => [{ 'command' => 'hand-written.sh' }] }] }
))

gem_dir = Dir.glob(File.join(GEMS, 'gems', 'kairos-chain-*')).max
abort 'installed gem not found' if gem_dir.nil?
$LOAD_PATH.unshift(File.join(gem_dir, 'lib'))
$LOAD_PATH.unshift(File.join(GEMS, 'gems', 'base64-0.3.0', 'lib'))
ENV['KAIROS_DATA_DIR'] = DATA
Dir.chdir(PROJECT)

require 'kairos_mcp'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/kairos_chain/chain'
KairosMcp.project_root = PROJECT if KairosMcp.respond_to?(:project_root=)

tool_path = File.join(gem_dir, 'templates', 'skillsets', 'kairos_hook_projector',
                      'tools', 'mode_hooks_project.rb')
abort "tool not in the gem: #{tool_path}" unless File.file?(tool_path)
require tool_path

T = KairosMcp::SkillSets::KairosHookProjector::Tools::ModeHooksProject
def call(args)
  JSON.parse(T.new.call(args).first[:text])
end

puts "gem      : #{File.basename(gem_dir)}"
puts "data dir : #{KairosMcp.data_dir}"
puts "project  : #{KairosMcp.project_root}"
puts "chain    : #{KairosMcp.blockchain_path rescue '(unresolved)'}"
puts
proposal = call('mode' => 'smoke')
puts JSON.pretty_generate(proposal)

# --- apply, then check what actually happened ------------------------------

applied = call('mode' => 'smoke', 'apply' => true,
               'confirm_sha256' => proposal['plan_sha256'])
puts
puts JSON.pretty_generate(applied)

checks = []
def ok(checks, name, cond, detail = '')
  checks << [name, cond ? 'PASS' : "FAIL #{detail}"]
end

settings = JSON.parse(File.read(File.join(PROJECT, '.claude', 'settings.json')))
groups = settings.dig('hooks', 'Stop') || []
ours = groups.select { |g| g['_projected_by'] == 'kairos_hook_projector' && g['_mode'] == 'smoke' }

ok(checks, 'apply reports applied', applied['action'] == 'applied', applied['action'].to_s)
ok(checks, 'chain recorded', applied.dig('chain', 'recorded') == true,
   applied['chain'].to_s)
ok(checks, 'our hook is in settings.json', ours.length == 1, "found #{ours.length}")
ok(checks, "hand-written hook survived",
   groups.any? { |g| g.dig('hooks', 0, 'command') == 'hand-written.sh' })
ok(checks, 'permissions survived', settings.dig('permissions', 'allow') == ['Bash(git:*)'],
   settings['permissions'].to_s)

cmd = ours.first&.dig('hooks', 0, 'command').to_s
cfg_path = cmd[%r{\S+\.json}]
ok(checks, 'the command names a config that exists', cfg_path && File.file?(cfg_path),
   cfg_path.to_s)
ok(checks, 'the command names the shipped executable', cmd.start_with?('kairos-readable-gate'),
   cmd[0, 60])

chain_file = KairosMcp.blockchain_path
ok(checks, 'a block landed on the scratch ledger',
   File.file?(chain_file) && File.read(chain_file).include?('mode_hooks_project mode=smoke'))

# The gate itself, driven the way the harness drives it.
transcript = File.join(PROJECT, 't.jsonl')
long = (0...30).map { |i| "line #{i}" }.join('\n')
File.write(transcript, JSON.generate(
  'type' => 'assistant',
  'message' => { 'content' => [{ 'type' => 'text', 'text' => long.gsub('\n', "\n") }] }
) + "\n")
exe = File.join(GEMS, 'bin', 'kairos-readable-gate')
ok(checks, 'the executable is on the installed bin path', File.executable?(exe), exe)
# No rescue here: a gate that cannot even be invoked must crash this script,
# not degrade into an ordinary FAIL indistinguishable from a gate that ran.
out = `GEM_HOME=#{GEMS} GEM_PATH=#{GEMS} #{Shellwords.escape(exe)} --config #{Shellwords.escape(cfg_path.to_s)} <<'IN'
#{JSON.generate('transcript_path' => transcript, 'stop_hook_active' => false)}
IN`
ok(checks, 'the gate measured and reported', out.include?('readable') || out.include?('LENGTH'),
   out[0, 200])
ok(checks, 'the gate wrote its log', File.file?(File.join(PROJECT, 'gate.log')))

puts
puts format('%-46s %s', 'CHECK', 'RESULT')
checks.each { |n, r| puts format('%-46s %s', n, r) }
puts
all_pass = checks.all? { |_, r| r == 'PASS' }
puts all_pass ? 'ALL CHECKS PASS' : 'SOME CHECKS FAILED'
exit 1 unless all_pass
