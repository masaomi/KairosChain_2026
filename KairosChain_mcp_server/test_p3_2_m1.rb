#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.2 M1 — ScopeClassifier + EditKernel tests.
#
# Usage:
#   ruby KairosChain_mcp_server/test_p3_2_m1.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'digest'

require 'kairos_mcp/daemon/scope_classifier'
require 'kairos_mcp/daemon/edit_kernel'

# ---------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------

$pass = 0
$fail = 0
$failed_names = []

def assert(description)
  ok = yield
  if ok
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    $failed_names << description
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  $failed_names << description
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

SC = KairosMcp::Daemon::ScopeClassifier
EK = KairosMcp::Daemon::EditKernel

# ---------------------------------------------------------------------------
# ScopeClassifier
# ---------------------------------------------------------------------------

section 'ScopeClassifier: L0 scopes'

Dir.mktmpdir('sc_test') do |ws|
  # Create minimal directory structure
  FileUtils.mkdir_p(File.join(ws, 'KairosChain_mcp_server', 'lib'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'skills'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'knowledge'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'context'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'skillsets', 'mypkg'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'run', 'proposals'))
  FileUtils.mkdir_p(File.join(ws, '.kairos', 'storage'))
  FileUtils.mkdir_p(File.join(ws, 'projects'))

  assert('T1: KairosChain_mcp_server/foo.rb → :l0, auto=false') do
    r = SC.classify(File.join(ws, 'KairosChain_mcp_server', 'foo.rb'), workspace_root: ws)
    r[:scope] == :l0 && r[:auto_approve] == false && r[:matched_rule] == :core_code
  end

  assert('T2: .kairos/skills/my.rb → :l0') do
    r = SC.classify(File.join(ws, '.kairos', 'skills', 'my.rb'), workspace_root: ws)
    r[:scope] == :l0 && r[:matched_rule] == :skills_dsl
  end

  assert('T5: .kairos/skillsets/mypkg/main.rb → :l0 (all skillsets)') do
    r = SC.classify(File.join(ws, '.kairos', 'skillsets', 'mypkg', 'main.rb'), workspace_root: ws)
    r[:scope] == :l0 && r[:auto_approve] == false && r[:matched_rule] == :skillset
  end

  section 'ScopeClassifier: L1 scopes'

  assert('T3: .kairos/knowledge/x.md → :l1') do
    r = SC.classify(File.join(ws, '.kairos', 'knowledge', 'x.md'), workspace_root: ws)
    r[:scope] == :l1 && r[:auto_approve] == false && r[:matched_rule] == :knowledge
  end

  section 'ScopeClassifier: L2 scopes'

  assert('T4: .kairos/context/session.md → :l2, auto=true') do
    r = SC.classify(File.join(ws, '.kairos', 'context', 'session.md'), workspace_root: ws)
    r[:scope] == :l2 && r[:auto_approve] == true && r[:matched_rule] == :context
  end

  assert('T7: foo.txt (workspace root) → :l2') do
    r = SC.classify(File.join(ws, 'foo.txt'), workspace_root: ws)
    r[:scope] == :l2 && r[:auto_approve] == true && r[:matched_rule] == :general_workspace
  end

  assert('T7b: projects/genomicschain/index.html → :l2') do
    r = SC.classify(File.join(ws, 'projects', 'genomicschain', 'index.html'), workspace_root: ws)
    r[:scope] == :l2 && r[:auto_approve] == true
  end

  section 'ScopeClassifier: fail-closed .kairos/ (MF1)'

  assert('T8: .kairos/run/proposals/x.json → :l0 (kairos_unknown)') do
    r = SC.classify(File.join(ws, '.kairos', 'run', 'proposals', 'x.json'), workspace_root: ws)
    r[:scope] == :l0 && r[:auto_approve] == false && r[:matched_rule] == :kairos_unknown
  end

  assert('T9: .kairos/storage/blockchain.json → :l0 (kairos_unknown)') do
    r = SC.classify(File.join(ws, '.kairos', 'storage', 'blockchain.json'), workspace_root: ws)
    r[:scope] == :l0 && r[:auto_approve] == false && r[:matched_rule] == :kairos_unknown
  end

  assert('T9b: .kairos/config/safety.yml → :l0 (kairos_unknown)') do
    r = SC.classify(File.join(ws, '.kairos', 'config', 'safety.yml'), workspace_root: ws)
    r[:scope] == :l0 && r[:matched_rule] == :kairos_unknown
  end

  section 'ScopeClassifier: error handling'

  assert('T10: path escapes workspace → ArgumentError') do
    begin
      SC.classify('/etc/passwd', workspace_root: ws)
      false
    rescue ArgumentError => e
      e.message.include?('escapes workspace')
    end
  end

  assert('T10b: non-absolute path → ArgumentError') do
    begin
      SC.classify('relative/path.rb', workspace_root: ws)
      false
    rescue ArgumentError => e
      e.message.include?('must be absolute')
    end
  end

  assert('T10c: result is frozen') do
    r = SC.classify(File.join(ws, 'foo.txt'), workspace_root: ws)
    r.frozen?
  end
end

# ---------------------------------------------------------------------------
# EditKernel
# ---------------------------------------------------------------------------

section 'EditKernel: basic replacement'

assert('T11: single occurrence replacement') do
  r = EK.compute("hello world", old_string: 'world', new_string: 'ruby')
  r[:new_content] == 'hello ruby' &&
    r[:occurrences] == 1 &&
    r[:pre_hash].start_with?('sha256:') &&
    r[:post_hash].start_with?('sha256:') &&
    r[:pre_hash] != r[:post_hash]
end

assert('T12: old_string not found → NotFoundError') do
  begin
    EK.compute("hello world", old_string: 'nope', new_string: 'x')
    false
  rescue EK::NotFoundError
    true
  end
end

assert('T13: multiple occurrences + replace_all=false → AmbiguousError') do
  begin
    EK.compute("aaa", old_string: 'a', new_string: 'b')
    false
  rescue EK::AmbiguousError => e
    e.message.include?('3 occurrences')
  end
end

assert('T13b: multiple occurrences + replace_all=true → all replaced') do
  r = EK.compute("aaa", old_string: 'a', new_string: 'b', replace_all: true)
  r[:new_content] == 'bbb' && r[:occurrences] == 3
end

assert('T14: empty old_string → ArgumentError') do
  begin
    EK.compute("hello", old_string: '', new_string: 'x')
    false
  rescue ArgumentError => e
    e.message.include?('empty')
  end
end

assert('T14b: nil old_string → ArgumentError') do
  begin
    EK.compute("hello", old_string: nil, new_string: 'x')
    false
  rescue ArgumentError
    true
  end
end

assert('T14c: old_string == new_string → ArgumentError') do
  begin
    EK.compute("hello", old_string: 'hello', new_string: 'hello')
    false
  rescue ArgumentError => e
    e.message.include?('no-op')
  end
end

section 'EditKernel: hash correctness'

assert('T15: pre_hash matches Digest::SHA256 of original') do
  content = "test content\nline 2\n"
  r = EK.compute(content, old_string: 'line 2', new_string: 'line two')
  expected = "sha256:#{Digest::SHA256.hexdigest(content)}"
  r[:pre_hash] == expected
end

assert('T15b: post_hash matches actual write output (property test)') do
  # Simulate what safe_file_edit would do
  Dir.mktmpdir('ek_test') do |dir|
    path = File.join(dir, 'test.txt')
    original = "alpha beta gamma beta delta"
    File.binwrite(path, original)

    r = EK.compute(original, old_string: 'beta', new_string: 'BETA', replace_all: true)

    # Write and verify
    File.binwrite(path, r[:new_content])
    actual_hash = "sha256:#{Digest::SHA256.hexdigest(File.binread(path))}"
    actual_hash == r[:post_hash]
  end
end

assert('T15c: hash is deterministic') do
  a = EK.compute("abc", old_string: 'a', new_string: 'x')
  b = EK.compute("abc", old_string: 'a', new_string: 'x')
  a[:pre_hash] == b[:pre_hash] && a[:post_hash] == b[:post_hash]
end

section 'EditKernel: binary content handling'

assert('T15d: works with binary content') do
  content = "line1\r\nline2\x00line3"
  r = EK.compute(content, old_string: 'line2', new_string: 'LINE2')
  r[:new_content] == "line1\r\nLINE2\x00line3"
end

assert('T15e: hash_bytes utility') do
  h = EK.hash_bytes("test")
  h.start_with?('sha256:') && h.length == 7 + 64  # "sha256:" + 64 hex chars
end

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

puts
puts '=' * 60
puts "Results: #{$pass} passed, #{$fail} failed"
puts '=' * 60

unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end

exit($fail.zero? ? 0 : 1)
