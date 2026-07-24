# frozen_string_literal: true
# Regression test: skillset upgrade must never overwrite an EXISTING
# config/ file with the gem template (production incident 2026-07-24:
# `kairos-chain upgrade --apply` reset the confidentiality guard's
# operator-set `enabled: true` back to the template's `false`, silently
# deactivating a fail-closed regime on every upgrade). An ABSENT config
# file still counts as a pending install (new shipped config).

require 'fileutils'
require 'tmpdir'
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
  template = File.join(root, 'template', 'guardish')
  installed = File.join(root, 'installed', 'guardish')
  FileUtils.mkdir_p(File.join(template, 'config'))
  FileUtils.mkdir_p(File.join(template, 'lib'))
  FileUtils.mkdir_p(File.join(installed, 'config'))
  FileUtils.mkdir_p(File.join(installed, 'lib'))

  # Template ships enabled: false; the operator flipped it to true.
  File.write(File.join(template, 'config', 'guardish.yml'), "guard:\n  enabled: false\n")
  File.write(File.join(installed, 'config', 'guardish.yml'), "guard:\n  enabled: true\n")

  # A genuinely upgraded code file must still be listed.
  File.write(File.join(template, 'lib', 'code.rb'), "NEW = 2\n")
  File.write(File.join(installed, 'lib', 'code.rb'), "NEW = 1\n")

  # A config file the user has NOT installed yet must be listed (new ship).
  File.write(File.join(template, 'config', 'brand_new.example.yml'), "fresh: true\n")

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: File.join(root, 'installed'))
  changed = manager.send(:diff_files, template, installed)

  assert(!changed.include?('config/guardish.yml'),
         'existing operator config is user-owned: never listed as a pending upgrade')
  assert(changed.include?('lib/code.rb'),
         'changed code files are still listed for upgrade')
  assert(changed.include?('config/brand_new.example.yml'),
         'absent config files are still listed (new shipped config installs)')

  # And the copy loop upgrade_apply uses would therefore never touch the
  # operator file: simulate its exact copy semantics over `changed`.
  changed.each do |rel|
    src = File.join(template, rel)
    dst = File.join(installed, rel)
    FileUtils.mkdir_p(File.dirname(dst))
    FileUtils.cp(src, dst) if File.exist?(src)
  end
  assert(File.read(File.join(installed, 'config', 'guardish.yml')).include?('enabled: true'),
         'operator activation state survives the upgrade copy')
  assert(File.read(File.join(installed, 'lib', 'code.rb')) == "NEW = 2\n",
         'code upgrade applied')
  assert(File.exist?(File.join(installed, 'config', 'brand_new.example.yml')),
         'newly shipped config installed')
end

puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
