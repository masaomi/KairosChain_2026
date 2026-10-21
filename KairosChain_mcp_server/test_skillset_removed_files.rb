# frozen_string_literal: true
# A release that drops files names them in skillset.json "removed_files";
# system_upgrade archives them out of the installed copy (agent 1.0 removing
# the 0.x tree, design log/agent_skillset_rebuild_design_v0.5.1 §5).

require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'lib/kairos_mcp'
require_relative 'lib/kairos_mcp/skillset_manager'

$pass = 0
$fail = 0

def assert(condition, message)
  if condition
    $pass += 1
  else
    $fail += 1
    puts "FAIL: #{message}"
  end
end

Dir.mktmpdir do |root|
  data = File.join(root, '.kairos')
  KairosMcp.data_dir = data
  gem_tpl = File.join(root, 'gem', 'templates', 'skillsets', 'thing')
  installed = File.join(data, 'skillsets', 'thing')
  [File.join(gem_tpl, 'tools'), File.join(installed, 'tools'), File.join(installed, 'config')].each { |d| FileUtils.mkdir_p(d) }
  File.write(File.join(gem_tpl, 'skillset.json'),
             JSON.generate('name' => 'thing', 'version' => '1.0.0', 'description' => 'd', 'layer' => 'L1',
                           'removed_files' => ['tools/old_tool.rb', 'config/old.yml', '../escape.rb', '/abs.rb']))
  File.write(File.join(gem_tpl, 'tools', 'new_tool.rb'), "# new\n")
  File.write(File.join(installed, 'skillset.json'),
             JSON.generate('name' => 'thing', 'version' => '0.1.0', 'description' => 'd', 'layer' => 'L1'))
  File.write(File.join(installed, 'tools', 'old_tool.rb'), "# old\n")
  File.write(File.join(installed, 'config', 'old.yml'), "x: 1\n")
  File.write(File.join(root, 'escape.rb'), "# outside\n")

  ss = KairosMcp::Skillset.new(gem_tpl)
  assert(ss.removed_files == ['tools/old_tool.rb', 'config/old.yml'], 'unsafe removed paths are ignored')

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: File.join(data, 'skillsets'))
  KairosMcp.singleton_class.send(:define_method, :gem_root) { File.join(root, 'gem') }
  info = manager.upgrade_check.find { |u| u[:name] == 'thing' }
  assert(info && info[:removed_files].sort == ['config/old.yml', 'tools/old_tool.rb'], 'upgrade_check lists removals')
  manager.upgrade_apply(names: ['thing'])
  assert(!File.exist?(File.join(installed, 'tools', 'old_tool.rb')), 'old tool removed from the installed copy')
  assert(!File.exist?(File.join(installed, 'config', 'old.yml')), 'retired config removed')
  assert(File.exist?(File.join(installed, 'tools', 'new_tool.rb')), 'new file installed')
  archived = Dir.glob(File.join(data, 'storage', 'skillset_removed', 'thing', '*', 'tools', 'old_tool.rb'))
  assert(archived.size == 1 && File.read(archived.first) == "# old\n", 'removed file archived, not lost')
  assert(File.exist?(File.join(root, 'escape.rb')), 'a path outside the SkillSet is never touched')
end

puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
