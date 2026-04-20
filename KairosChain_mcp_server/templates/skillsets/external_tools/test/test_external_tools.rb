#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for P2.5a: external_tools SkillSet.
#
# Usage:
#   ruby templates/skillsets/external_tools/test/test_external_tools.rb
#
# Coverage (≥30 tests):
#   * WorkspaceConfinement:
#     - resolve_path accepts relative inside workspace
#     - resolve_path accepts absolute inside workspace
#     - resolve_path rejects ../ escape (relative)
#     - resolve_path rejects absolute outside workspace
#     - resolve_path rejects null byte
#     - resolve_path rejects nil workspace
#     - resolve_path rejects empty path
#     - resolve_path detects symlink escape (target outside ws)
#     - resolve_path allows symlink inside ws
#     - resolve_path works for non-existent leaf (new file)
#     - resolve_path rejects prefix collision (wsX not inside ws)
#     - content_hash sha256 of string
#     - file_hash returns nil for missing file
#     - file_hash returns sha256 of existing file
#   * safe_file_read:
#     - reads existing file, returns content + sha256
#     - rejects traversal
#     - rejects non-file (directory)
#     - rejects file exceeding max_bytes
#   * safe_file_write:
#     - writes new file atomically, returns pre=nil post=hash
#     - overwrites existing file, returns differing pre/post hashes
#     - rejects overwrite=false when target exists
#     - create_dirs=true creates parents
#     - confinement rejects ../ path
#     - does not leave .tmp on success
#   * safe_file_edit:
#     - replaces unique old_string
#     - errors if old_string not found
#     - errors if old_string not unique (and replace_all=false)
#     - replace_all=true replaces all occurrences
#   * safe_file_list:
#     - lists entries in directory
#     - hidden files excluded by default
#     - include_hidden=true includes dotfiles
#   * safe_file_copy:
#     - copies file with hashes
#     - rejects destination outside workspace
#   * safe_file_delete:
#     - deletes file, returns pre_hash
#     - refuses to delete directory
#     - missing_ok=true returns ok when missing
#   * safe_git_status:
#     - returns clean=true on fresh repo
#     - detects new file as untracked
#   * safe_git_commit:
#     - commits staged files, returns sha
#     - rejects path escaping workspace
#     - errors on empty message
#   * safe_git_branch:
#     - lists branches
#     - rejects branch name starting with -
#     - creates + switches branch
#   * safe_git_push:
#     - rejects without risk_budget=high
#     - rejects without confirm=true
#     - rejects injection-shaped remote name

$LOAD_PATH.unshift File.expand_path('../../../../KairosChain_mcp_server/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('..', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'
require 'open3'
require 'digest'
require 'time'

require 'kairos_mcp/tools/base_tool'
require 'external_tools'

require_relative '../tools/safe_file_read'
require_relative '../tools/safe_file_write'
require_relative '../tools/safe_file_edit'
require_relative '../tools/safe_file_list'
require_relative '../tools/safe_file_copy'
require_relative '../tools/safe_file_delete'
require_relative '../tools/safe_git_status'
require_relative '../tools/safe_git_commit'
require_relative '../tools/safe_git_branch'
require_relative '../tools/safe_git_push'

WC  = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement
T   = ::KairosMcp::SkillSets::ExternalTools::Tools

# -----------------------------------------------------------------------------
# Test harness
# -----------------------------------------------------------------------------

$pass = 0
$fail = 0
$failed = []

def assert(desc)
  ok = yield
  if ok
    $pass += 1
    puts "  PASS: #{desc}"
  else
    $fail += 1
    $failed << desc
    puts "  FAIL: #{desc}"
  end
rescue StandardError => e
  $fail += 1
  $failed << desc
  puts "  FAIL: #{desc} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def assert_raises(desc, klass = StandardError)
  yield
  $fail += 1
  $failed << desc
  puts "  FAIL: #{desc} — no exception raised"
rescue Exception => e # rubocop:disable Lint/RescueException
  if e.is_a?(klass)
    $pass += 1
    puts "  PASS: #{desc}"
  else
    $fail += 1
    $failed << desc
    puts "  FAIL: #{desc} — expected #{klass}, got #{e.class}: #{e.message}"
  end
end

def section(title)
  puts "\n#{'=' * 60}\nTEST: #{title}\n#{'=' * 60}"
end

def decode(result)
  JSON.parse(result.first[:text])
end

def git_init(dir)
  Open3.capture3('git', '-C', dir, 'init', '-q', '-b', 'main')
  Open3.capture3('git', '-C', dir, 'config', 'user.email', 'test@example.invalid')
  Open3.capture3('git', '-C', dir, 'config', 'user.name', 'Test')
  Open3.capture3('git', '-C', dir, 'config', 'commit.gpgsign', 'false')
end

# -----------------------------------------------------------------------------
# WorkspaceConfinement
# -----------------------------------------------------------------------------

section 'WorkspaceConfinement'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  File.write(File.join(real_ws, 'a.txt'), 'hello')
  FileUtils.mkdir_p(File.join(real_ws, 'sub'))

  assert('resolve_path: relative inside workspace') do
    WC.resolve_path('a.txt', real_ws) == File.join(real_ws, 'a.txt')
  end

  assert('resolve_path: absolute inside workspace') do
    WC.resolve_path(File.join(real_ws, 'a.txt'), real_ws) == File.join(real_ws, 'a.txt')
  end

  assert_raises('resolve_path: rejects ../ escape', WC::ConfinementError) do
    WC.resolve_path('../../../etc/passwd', real_ws)
  end

  assert_raises('resolve_path: rejects absolute outside workspace', WC::ConfinementError) do
    WC.resolve_path('/etc/passwd', real_ws)
  end

  assert_raises('resolve_path: rejects null byte', WC::ConfinementError) do
    WC.resolve_path("a.txt\x00.evil", real_ws)
  end

  assert_raises('resolve_path: rejects nil workspace', WC::ConfinementError) do
    WC.resolve_path('a.txt', nil)
  end

  assert_raises('resolve_path: rejects empty path', WC::ConfinementError) do
    WC.resolve_path('', real_ws)
  end

  # Symlink escape
  Dir.mktmpdir do |outside|
    real_outside = File.realpath(outside)
    File.write(File.join(real_outside, 'secret.txt'), 'SECRET')
    evil_link = File.join(real_ws, 'evil')
    File.symlink(File.join(real_outside, 'secret.txt'), evil_link)
    assert_raises('resolve_path: detects symlink escape', WC::ConfinementError) do
      WC.resolve_path('evil', real_ws)
    end
    File.unlink(evil_link)
  end

  # Symlink inside
  inside_link = File.join(real_ws, 'inside_link')
  File.symlink(File.join(real_ws, 'a.txt'), inside_link)
  assert('resolve_path: symlink inside workspace allowed') do
    WC.resolve_path('inside_link', real_ws) == File.join(real_ws, 'a.txt')
  end
  File.unlink(inside_link)

  assert('resolve_path: non-existent leaf (new file)') do
    WC.resolve_path('sub/new_file.txt', real_ws) == File.join(real_ws, 'sub', 'new_file.txt')
  end

  # Prefix-collision attack: path ".../wsX" must NOT be considered inside ".../ws"
  Dir.mktmpdir do |parent|
    real_parent = File.realpath(parent)
    ws1 = File.join(real_parent, 'ws')
    ws2 = File.join(real_parent, 'wsX')
    Dir.mkdir(ws1)
    Dir.mkdir(ws2)
    File.write(File.join(ws2, 'target'), 'bad')
    assert_raises('resolve_path: rejects prefix collision (wsX vs ws)', WC::ConfinementError) do
      WC.resolve_path(File.join(ws2, 'target'), ws1)
    end
  end

  assert('content_hash: sha256 of string') do
    WC.content_hash('hello') == Digest::SHA256.hexdigest('hello')
  end

  assert('file_hash: nil for missing file') do
    WC.file_hash(File.join(real_ws, 'does_not_exist')).nil?
  end

  assert('file_hash: sha256 of existing file') do
    WC.file_hash(File.join(real_ws, 'a.txt')) == Digest::SHA256.hexdigest('hello')
  end
end

# -----------------------------------------------------------------------------
# safe_file_read
# -----------------------------------------------------------------------------

section 'safe_file_read'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  File.write(File.join(real_ws, 'hello.txt'), 'world')
  FileUtils.mkdir_p(File.join(real_ws, 'd'))

  tool = T::SafeFileRead.new(nil)

  res = decode(tool.call('path' => 'hello.txt', 'workspace_root' => real_ws))
  assert('safe_file_read: returns ok=true')    { res['ok'] == true }
  assert('safe_file_read: content matches')    { res['content'] == 'world' }
  assert('safe_file_read: sha256 matches')     { res['sha256'] == Digest::SHA256.hexdigest('world') }

  bad = decode(tool.call('path' => '../../etc/passwd', 'workspace_root' => real_ws))
  assert('safe_file_read: rejects traversal')  { bad['ok'] == false && bad['error'].include?('confinement') }

  dir_res = decode(tool.call('path' => 'd', 'workspace_root' => real_ws))
  assert('safe_file_read: rejects directory')  { dir_res['ok'] == false }

  big = decode(tool.call('path' => 'hello.txt', 'workspace_root' => real_ws, 'max_bytes' => 1))
  assert('safe_file_read: rejects > max_bytes') { big['ok'] == false && big['error'].include?('max_bytes') }
end

# -----------------------------------------------------------------------------
# safe_file_write
# -----------------------------------------------------------------------------

section 'safe_file_write'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  tool = T::SafeFileWrite.new(nil)

  r1 = decode(tool.call('path' => 'new.txt', 'content' => 'hi', 'workspace_root' => real_ws))
  assert('safe_file_write: creates new file') do
    r1['ok'] == true && r1['pre_hash'].nil? && r1['post_hash'] == Digest::SHA256.hexdigest('hi')
  end
  assert('safe_file_write: file content on disk') do
    File.read(File.join(real_ws, 'new.txt')) == 'hi'
  end

  r2 = decode(tool.call('path' => 'new.txt', 'content' => 'bye', 'workspace_root' => real_ws))
  assert('safe_file_write: overwrite yields differing pre/post') do
    r2['ok'] == true &&
      r2['pre_hash'] == Digest::SHA256.hexdigest('hi') &&
      r2['post_hash'] == Digest::SHA256.hexdigest('bye')
  end

  r3 = decode(tool.call('path' => 'new.txt', 'content' => 'x', 'workspace_root' => real_ws, 'overwrite' => false))
  assert('safe_file_write: overwrite=false rejected on existing file') { r3['ok'] == false }

  r4 = decode(tool.call('path' => 'deep/dir/file.txt', 'content' => 'x', 'workspace_root' => real_ws, 'create_dirs' => true))
  assert('safe_file_write: create_dirs creates parents') do
    r4['ok'] == true && File.file?(File.join(real_ws, 'deep', 'dir', 'file.txt'))
  end

  r5 = decode(tool.call('path' => '../escape.txt', 'content' => 'x', 'workspace_root' => real_ws))
  assert('safe_file_write: rejects ../ escape') { r5['ok'] == false && r5['error'].include?('confinement') }

  # Verify no leftover .tmp files
  tmp_leftover = Dir.glob(File.join(real_ws, '**/.*.tmp.*'))
  assert('safe_file_write: no leftover .tmp on success') { tmp_leftover.empty? }
end

# -----------------------------------------------------------------------------
# safe_file_edit
# -----------------------------------------------------------------------------

section 'safe_file_edit'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  tool = T::SafeFileEdit.new(nil)

  File.write(File.join(real_ws, 'a.txt'), 'The quick brown fox')
  r1 = decode(tool.call('path' => 'a.txt', 'old_string' => 'quick', 'new_string' => 'slow', 'workspace_root' => real_ws))
  assert('safe_file_edit: unique replace ok') { r1['ok'] == true && r1['replacements'] == 1 }
  assert('safe_file_edit: content updated')    { File.read(File.join(real_ws, 'a.txt')) == 'The slow brown fox' }

  r2 = decode(tool.call('path' => 'a.txt', 'old_string' => 'zzz', 'new_string' => 'q', 'workspace_root' => real_ws))
  assert('safe_file_edit: not found error') { r2['ok'] == false && r2['error'].include?('not found') }

  File.write(File.join(real_ws, 'b.txt'), 'foo foo foo')
  r3 = decode(tool.call('path' => 'b.txt', 'old_string' => 'foo', 'new_string' => 'bar', 'workspace_root' => real_ws))
  assert('safe_file_edit: non-unique error') { r3['ok'] == false && r3['error'].include?('not unique') }

  r4 = decode(tool.call('path' => 'b.txt', 'old_string' => 'foo', 'new_string' => 'bar', 'workspace_root' => real_ws, 'replace_all' => true))
  assert('safe_file_edit: replace_all replaces all') do
    r4['ok'] == true && r4['replacements'] == 3 && File.read(File.join(real_ws, 'b.txt')) == 'bar bar bar'
  end
end

# -----------------------------------------------------------------------------
# safe_file_list
# -----------------------------------------------------------------------------

section 'safe_file_list'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  File.write(File.join(real_ws, 'a.txt'), 'a')
  File.write(File.join(real_ws, '.hidden'), 'h')
  FileUtils.mkdir_p(File.join(real_ws, 'sub'))

  tool = T::SafeFileList.new(nil)
  r = decode(tool.call('workspace_root' => real_ws))
  names = r['entries'].map { |e| e['name'] }
  assert('safe_file_list: lists visible entries') { r['ok'] == true && names.include?('a.txt') && names.include?('sub') }
  assert('safe_file_list: excludes dotfiles by default') { !names.include?('.hidden') }

  r2 = decode(tool.call('workspace_root' => real_ws, 'include_hidden' => true))
  assert('safe_file_list: include_hidden=true includes dotfiles') do
    r2['entries'].map { |e| e['name'] }.include?('.hidden')
  end
end

# -----------------------------------------------------------------------------
# safe_file_copy
# -----------------------------------------------------------------------------

section 'safe_file_copy'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  File.write(File.join(real_ws, 'src.txt'), 'data')
  tool = T::SafeFileCopy.new(nil)

  r = decode(tool.call('source' => 'src.txt', 'destination' => 'dst.txt', 'workspace_root' => real_ws))
  assert('safe_file_copy: copies ok with hashes') do
    r['ok'] == true &&
      r['source_hash'] == Digest::SHA256.hexdigest('data') &&
      r['post_hash']  == Digest::SHA256.hexdigest('data') &&
      r['pre_hash'].nil?
  end

  bad = decode(tool.call('source' => 'src.txt', 'destination' => '../escape.txt', 'workspace_root' => real_ws))
  assert('safe_file_copy: rejects destination outside workspace') { bad['ok'] == false }
end

# -----------------------------------------------------------------------------
# safe_file_delete
# -----------------------------------------------------------------------------

section 'safe_file_delete'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  File.write(File.join(real_ws, 'd.txt'), 'x')
  FileUtils.mkdir_p(File.join(real_ws, 'dir'))

  tool = T::SafeFileDelete.new(nil)
  r = decode(tool.call('path' => 'd.txt', 'workspace_root' => real_ws))
  assert('safe_file_delete: deletes file + returns pre_hash') do
    r['ok'] == true && r['pre_hash'] == Digest::SHA256.hexdigest('x') && !File.exist?(File.join(real_ws, 'd.txt'))
  end

  r2 = decode(tool.call('path' => 'dir', 'workspace_root' => real_ws))
  assert('safe_file_delete: refuses directory') { r2['ok'] == false && r2['error'].include?('directory') }

  r3 = decode(tool.call('path' => 'gone.txt', 'workspace_root' => real_ws, 'missing_ok' => true))
  assert('safe_file_delete: missing_ok=true') { r3['ok'] == true && r3['deleted'] == false }
end

# -----------------------------------------------------------------------------
# safe_git_status
# -----------------------------------------------------------------------------

section 'safe_git_status'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  git_init(real_ws)

  tool = T::SafeGitStatus.new(nil)
  r = decode(tool.call('workspace_root' => real_ws))
  assert('safe_git_status: clean=true on fresh repo') { r['ok'] == true && r['clean'] == true }

  File.write(File.join(real_ws, 'new.txt'), 'x')
  r2 = decode(tool.call('workspace_root' => real_ws))
  assert('safe_git_status: detects untracked file') do
    r2['ok'] == true && r2['entries'].any? { |e| e['path'] == 'new.txt' && e['xy'].include?('?') }
  end
end

# -----------------------------------------------------------------------------
# safe_git_commit
# -----------------------------------------------------------------------------

section 'safe_git_commit'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  git_init(real_ws)
  File.write(File.join(real_ws, 'a.txt'), 'hello')

  tool = T::SafeGitCommit.new(nil)
  r = decode(tool.call('message' => 'first', 'paths' => ['a.txt'], 'workspace_root' => real_ws, 'daemon_mode' => true,
                       'author_name' => 'Test', 'author_email' => 'test@example.invalid'))
  assert('safe_git_commit: commits + returns sha') do
    r['ok'] == true && r['commit_sha'].is_a?(String) && r['commit_sha'].length >= 7
  end

  r2 = decode(tool.call('message' => 'x', 'paths' => ['../escape.txt'], 'workspace_root' => real_ws))
  assert('safe_git_commit: rejects path escaping workspace') { r2['ok'] == false && r2['error'].include?('confinement') }

  r3 = decode(tool.call('message' => '   ', 'workspace_root' => real_ws))
  assert('safe_git_commit: rejects empty message') { r3['ok'] == false && r3['error'].include?('empty') }
end

# -----------------------------------------------------------------------------
# safe_git_branch
# -----------------------------------------------------------------------------

section 'safe_git_branch'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  git_init(real_ws)
  File.write(File.join(real_ws, 'seed'), 'x')
  Open3.capture3('git', '-C', real_ws, 'add', 'seed')
  Open3.capture3('git', '-C', real_ws, 'commit', '-q', '-m', 'seed', '--no-verify')

  tool = T::SafeGitBranch.new(nil)
  r = decode(tool.call('action' => 'list', 'workspace_root' => real_ws))
  assert('safe_git_branch: list returns current branch') do
    r['ok'] == true && r['branches'].include?('main') && r['current'] == 'main'
  end

  r2 = decode(tool.call('action' => 'create', 'branch' => '--force', 'workspace_root' => real_ws))
  assert('safe_git_branch: rejects name starting with -') { r2['ok'] == false && r2['error'].include?('invalid') }

  r3 = decode(tool.call('action' => 'create', 'branch' => 'feature/test', 'workspace_root' => real_ws))
  assert('safe_git_branch: create ok') { r3['ok'] == true && r3['created'] == 'feature/test' }

  r4 = decode(tool.call('action' => 'switch', 'branch' => 'feature/test', 'workspace_root' => real_ws))
  assert('safe_git_branch: switch ok') { r4['ok'] == true && r4['switched_to'] == 'feature/test' }
end

# -----------------------------------------------------------------------------
# safe_git_push
# -----------------------------------------------------------------------------

section 'safe_git_push'

Dir.mktmpdir do |ws|
  real_ws = File.realpath(ws)
  git_init(real_ws)

  tool = T::SafeGitPush.new(nil)

  r1 = decode(tool.call('workspace_root' => real_ws, 'risk_budget' => 'medium', 'confirm' => true))
  assert('safe_git_push: rejects without risk_budget=high') { r1['ok'] == false && r1['error'].include?('risk_budget') }

  r2 = decode(tool.call('workspace_root' => real_ws, 'risk_budget' => 'high', 'confirm' => false))
  assert('safe_git_push: rejects without confirm=true') { r2['ok'] == false && r2['error'].include?('confirm') }

  r3 = decode(tool.call('workspace_root' => real_ws, 'risk_budget' => 'high', 'confirm' => true,
                        'remote' => '--upload-pack=rm -rf /', 'branch' => 'main'))
  assert('safe_git_push: rejects injection-shaped remote') { r3['ok'] == false && r3['error'].include?('invalid remote') }

  r4 = decode(tool.call('workspace_root' => real_ws, 'risk_budget' => 'high', 'confirm' => true,
                        'remote' => 'origin', 'branch' => '--force'))
  assert('safe_git_push: rejects injection-shaped branch') { r4['ok'] == false && r4['error'].include?('invalid branch') }
end

# -----------------------------------------------------------------------------

puts "\n#{'=' * 60}"
puts "RESULT: #{$pass} passed, #{$fail} failed (total #{$pass + $fail})"
puts '=' * 60
if $fail > 0
  puts "Failed tests:"
  $failed.each { |d| puts "  - #{d}" }
  exit 1
end
