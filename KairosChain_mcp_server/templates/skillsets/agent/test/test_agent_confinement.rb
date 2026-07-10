#!/usr/bin/env ruby
# frozen_string_literal: true

# Guard track Stage B probes (design v0.3.1 FROZEN, §5 Slice 1 acceptance):
# blocked store write, blocked store read, scratch write allowed
# (discrimination of the deny), overlap-declaration refusal, merge-store
# refusal, realpath fail-closed. Each confinement probe exercises the
# guarded-FAILURE branch, with an unconfined control proving the probe
# itself can succeed (deny-probe pattern from the external track).
# Usage: ruby test_agent_confinement.rb

require 'tmpdir'
require 'fileutils'
require 'open3'
require_relative '../lib/agent/confinement'

CONF = KairosMcp::SkillSets::Agent::Confinement

$pass = 0
$fail = 0

def assert(description)
  result = yield
  if result
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
end

def assert_raises(description, klass)
  yield
  $fail += 1
  puts "  FAIL: #{description} (no exception raised)"
rescue klass
  $pass += 1
  puts "  PASS: #{description}"
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (wrong exception #{e.class}: #{e.message})"
end

darwin = RUBY_PLATFORM.include?('darwin') && system('which sandbox-exec > /dev/null 2>&1')

Dir.mktmpdir('guard_probe_root_') do |raw_root|
  root = File.realpath(raw_root)
  stores = File.join(root, '.kairos')
  FileUtils.mkdir_p(File.join(stores, 'storage'))
  File.write(File.join(stores, 'storage', 'secret.json'), '{"canary":"stores"}')
  File.write(File.join(root, 'live_file.txt'), 'live tree content')

  Dir.mktmpdir('guard_probe_scratch_') do |raw_scratch|
    scratch = File.realpath(raw_scratch)

    puts "== Path hygiene (fail-closed realpath) =="
    assert_raises('nonexistent path fails closed', CONF::ConfinementError) do
      CONF.realpath_strict(File.join(root, 'no_such_dir'), 'probe')
    end
    assert('realpath resolves /tmp symlink to physical path') do
      !scratch.start_with?('/tmp/') || scratch == File.realpath(scratch)
    end

    puts "== Overlap-declaration probe (AGT-1 disjointness) =="
    inside = File.join(root, 'inner_scratch')
    FileUtils.mkdir_p(inside)
    assert_raises('scratch inside project root is refused', CONF::ConfinementError) do
      CONF.assert_disjoint!(inside, root)
    end
    assert_raises('scratch inside stores is refused', CONF::ConfinementError) do
      s = File.join(stores, 'sneaky')
      FileUtils.mkdir_p(s)
      CONF.assert_disjoint!(s, root)
    end
    assert('disjoint scratch is accepted') do
      CONF.assert_disjoint!(scratch, root) == scratch
    end

    puts "== Profile content (raw-device deny, metacharacter fail-closed) =="
    prof = CONF.profile(scratch, stores)
    assert('profile denies raw disk under the /dev write-allow') do
      prof.include?('(deny file-write* (subpath "/dev/disk") (subpath "/dev/rdisk"))')
    end
    assert('profile denies store reads') { prof.include?("(deny file-read* (subpath \"#{stores}\"))") }
    assert_raises('a scratch path with an SBPL metacharacter is refused', CONF::ConfinementError) do
      evil = File.join(Dir.mktmpdir, 'a"b'); FileUtils.mkdir_p(evil)
      CONF.profile(File.realpath(evil), stores)
    end

    unless darwin
      $fail += 1
      puts "  UNPROVEN: substrate deny probes require darwin sandbox-exec — NOT green, counted as failure on this platform"
    end

    if darwin
      puts "== Substrate probes (sandbox-exec, deny-probe pattern) =="
      wrap = ->(cmd) { CONF.wrap(['/bin/sh', '-c', cmd], scratch, stores) }

      # Blocked store write: confined attempt fails, unconfined control succeeds.
      canary = File.join(stores, 'write_canary')
      system(*wrap.call("echo x > #{canary} 2>/dev/null"))
      assert('store write BLOCKED from executor position') { !File.exist?(canary) }
      system('/bin/sh', '-c', "echo x > #{canary} 2>/dev/null")
      assert('unconfined control CAN write the same path (probe is live)') { File.exist?(canary) }
      FileUtils.rm_f(canary)

      # Blocked live-tree write (scratch-only allowlist).
      tree_canary = File.join(root, 'tree_canary')
      system(*wrap.call("echo x > #{tree_canary} 2>/dev/null"))
      assert('live-tree write BLOCKED from executor position') { !File.exist?(tree_canary) }

      # Blocked store read (AGT-2).
      out, = Open3.capture2(*wrap.call("cat #{File.join(stores, 'storage', 'secret.json')} 2>/dev/null"))
      assert('store read BLOCKED from executor position') { !out.include?('canary') }
      out, = Open3.capture2('/bin/sh', '-c', "cat #{File.join(stores, 'storage', 'secret.json')}")
      assert('unconfined control CAN read the same file (probe is live)') { out.include?('canary') }

      # Scratch write allowed (the deny discriminates, it does not blanket-fail).
      system(*wrap.call("echo ok > #{File.join(scratch, 'work.txt')}"))
      assert('scratch write ALLOWED under confinement') do
        File.exist?(File.join(scratch, 'work.txt'))
      end
    else
      puts "== Substrate probes skipped (sandbox-exec unavailable on this platform) =="
    end

    puts "== Manifest (baseline-diff, symlink-safe) =="
    File.write(File.join(scratch, 'input.txt'), 'curated input')
    base = CONF.baseline(scratch, ['input.txt'])
    File.write(File.join(scratch, 'result_a.txt'), 'a')
    FileUtils.mkdir_p(File.join(scratch, 'sub'))
    File.write(File.join(scratch, 'sub', 'result_b.txt'), 'b')
    m = CONF.manifest(scratch, baseline: base)
    assert('manifest lists produced files, excludes UNCHANGED curated inputs') do
      m.include?('result_a.txt') && m.include?('sub/result_b.txt') && !m.include?('input.txt')
    end
    File.write(File.join(scratch, 'input.txt'), 'OVERWRITTEN by the act')
    m2 = CONF.manifest(scratch, baseline: base)
    assert('an input the act OVERWROTE is included (no false drop)') { m2.include?('input.txt') }
    File.symlink('/etc/hosts', File.join(scratch, 'evil_link'))
    m3 = CONF.manifest(scratch, baseline: base)
    assert('a symlink in scratch is never a produced result') { !m3.include?('evil_link') }

    puts "== Merge (AGT-1 return path; merge-store refusal) =="
    dest_root = File.join(root)
    written = CONF.merge!(scratch, ['result_a.txt', 'sub/result_b.txt'], dest_root)
    assert('merge promotes manifest files into the live tree') do
      written.size == 2 && File.read(File.join(root, 'result_a.txt')) == 'a' &&
        File.read(File.join(root, 'sub', 'result_b.txt')) == 'b'
    end
    File.write(File.join(scratch, 'evil.txt'), 'x')
    FileUtils.mkdir_p(File.join(scratch, '.kairos'))
    File.write(File.join(scratch, '.kairos', 'forge.json'), '{}')
    assert_raises('merge set containing a store path is REFUSED', CONF::ConfinementError) do
      CONF.merge!(scratch, ['.kairos/forge.json'], dest_root)
    end
    assert_raises('manifest path escaping scratch is REFUSED', CONF::ConfinementError) do
      CONF.merge!(scratch, ['../outside.txt'], dest_root)
    end
    assert_raises('absolute manifest path is REFUSED', CONF::ConfinementError) do
      CONF.merge!(scratch, ['/etc/hosts'], dest_root)
    end
    assert('refused merge did not land in the stores') do
      !File.exist?(File.join(stores, 'forge.json'))
    end
    # Symlink copy-out: an executor-planted symlink in scratch pointing at the
    # stores must be refused, not dereferenced into the live tree (AGT-2).
    File.symlink(File.join(stores, 'storage', 'secret.json'), File.join(scratch, 'exfil'))
    assert_raises('symlink-in-scratch pointing at stores is REFUSED by merge', CONF::ConfinementError) do
      CONF.merge!(scratch, ['exfil'], dest_root)
    end
    assert('symlinked store content was NOT copied into the live tree') do
      !File.exist?(File.join(root, 'exfil'))
    end
  end
end

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
