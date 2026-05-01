# frozen_string_literal: true

# Test: Context Graph Phase 1 (v2.1)
# Covers: §9 step 4 test suite enumeration

require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'date'
require 'time'
require_relative 'lib/kairos_mcp/context_graph'

# Minimal KairosMcp.context_dir stub for ContextManager integration
module KairosMcp
  class << self
    attr_accessor :_test_context_dir
  end

  def self.context_dir(user_context: nil)
    @_test_context_dir
  end
end

require_relative 'lib/kairos_mcp/context_manager'

$pass = 0
$fail = 0
$errors = []

def assert(label)
  if yield
    $pass += 1
    puts "  ok  #{label}"
  else
    $fail += 1
    $errors << label
    puts "  FAIL #{label}"
  end
rescue StandardError => e
  $fail += 1
  $errors << "#{label} (#{e.class}: #{e.message})"
  puts "  FAIL #{label} (#{e.class}: #{e.message})"
end

def assert_raises(label, klass)
  yield
  $fail += 1
  $errors << "#{label} (no exception, expected #{klass})"
  puts "  FAIL #{label} (no exception)"
rescue StandardError => e
  if e.is_a?(klass)
    $pass += 1
    puts "  ok  #{label}"
  else
    $fail += 1
    $errors << "#{label} (got #{e.class}: #{e.message})"
    puts "  FAIL #{label} (got #{e.class})"
  end
end

def section(name)
  puts "\n--- #{name} ---"
end

CG = KairosMcp::ContextGraph

# ============================================================
section('1. Canonical regex (§2)')
# ============================================================

# Canonical session_id format
assert('canonical sid + name match') { CG::TARGET_RE.match?('v1:session_20260420_051349_c68d4622/multi_llm_review') }

# Human-readable session_id (15 such on disk currently)
assert('human-readable sid match') { CG::TARGET_RE.match?('v1:coaching_insights_20260327/perspective_rotation') }
assert('hyphenated sid match') { CG::TARGET_RE.match?('v1:service_grant_fix_plan_review_2026-03-19/result') }

# Reject leading dot/hyphen (path tricks)
assert('reject leading dot in sid') { !CG::TARGET_RE.match?('v1:.hidden/name') }
assert('reject leading dot in name') { !CG::TARGET_RE.match?('v1:sid/.hidden') }
assert('reject leading hyphen sid') { !CG::TARGET_RE.match?('v1:-rf/name') }

# Reject path traversal
assert('reject ..') { !CG::TARGET_RE.match?('v1:../etc/passwd') }
assert('reject /') { !CG::TARGET_RE.match?('v1:sid/sub/dir') }
assert('reject prefix') { !CG::TARGET_RE.match?('not_v1:sid/name') }
assert('reject empty sid') { !CG::TARGET_RE.match?('v1:/name') }

# Length bounds (1..128)
assert('1-char sid OK') { CG::TARGET_RE.match?('v1:a/b') }
assert('128-char sid OK') { CG::TARGET_RE.match?("v1:#{'a' * 128}/name") }
assert('129-char sid rejected') { !CG::TARGET_RE.match?("v1:#{'a' * 129}/name") }

# parse_target
assert('parse_target returns hash') { CG.parse_target('v1:abc/xyz') == { sid: 'abc', name: 'xyz' } }
assert('parse_target returns nil on miss') { CG.parse_target('garbage').nil? }

# ============================================================
section('2. resolve_target path containment (§3)')
# ============================================================

Dir.mktmpdir do |root|
  # Setup: valid target file
  sid = 'session_20260501_120000_aabbccdd'
  name = 'valid_target'
  ctx_dir = File.join(root, sid, name)
  FileUtils.mkdir_p(ctx_dir)
  md = File.join(ctx_dir, "#{name}.md")
  File.write(md, "---\nname: valid_target\n---\nbody")

  result = CG.resolve_target("v1:#{sid}/#{name}", root)
  assert('resolve_target returns :ok status') { result[:status] == :ok }
  assert('resolved path matches') { result[:path] == File.realpath(md) }

  # ENOENT → dangling
  result = CG.resolve_target("v1:#{sid}/missing_target", root)
  assert('ENOENT returns :dangling') { result[:status] == :dangling && result[:path].nil? }

  # Malformed target
  assert_raises('malformed target raises', CG::MalformedTargetError) do
    CG.resolve_target('not_a_target', root)
  end

  # Path escape via symlink (the .md file itself is a symlink to outside)
  outside = Dir.mktmpdir
  outside_target = File.join(outside, 'outside.md')
  File.write(outside_target, '---\nname: outside\n---\n')
  evil_sid = 'session_20260501_999999_deadbeef'
  evil_name = 'evil_target'
  evil_dir = File.join(root, evil_sid, evil_name)
  FileUtils.mkdir_p(evil_dir)
  evil_md = File.join(evil_dir, "#{evil_name}.md")
  File.symlink(outside_target, evil_md)

  assert_raises('symlink final component rejected', CG::SymlinkRejectedError) do
    CG.resolve_target("v1:#{evil_sid}/#{evil_name}", root)
  end

  FileUtils.rm_rf(outside)
end

# ============================================================
section('3. validate_relations! (§4.2 step 2-3)')
# ============================================================

# Non-Array
assert_raises('non-Array relations', CG::MalformedRelationsError) do
  CG.validate_relations!('not an array')
end

# Non-Hash item
assert_raises('non-Hash item', CG::MalformedRelationsError) do
  CG.validate_relations!(['string item'])
end

# Missing type
assert_raises('missing type', CG::MalformedRelationsError) do
  CG.validate_relations!([{ 'target' => 'v1:a/b' }])
end

# Missing target
assert_raises('missing target', CG::MalformedRelationsError) do
  CG.validate_relations!([{ 'type' => 'informed_by' }])
end

# Non-String type
assert_raises('non-String type', CG::MalformedRelationsError) do
  CG.validate_relations!([{ 'type' => 123, 'target' => 'v1:a/b' }])
end

# Bad target regex
assert_raises('bad target regex', CG::MalformedTargetError) do
  CG.validate_relations!([{ 'type' => 'informed_by', 'target' => 'garbage' }])
end

# Type whitelist: Symbol value rejected (Symbol not in SAFE_VALUE_TYPES)
assert_raises('Symbol value rejected', CG::UnsafeRelationValueError) do
  CG.validate_relations!([{
    'type' => 'informed_by',
    'target' => 'v1:a/b',
    'extra' => :symbol_value
  }])
end

# Valid: minimal informed_by
assert('valid informed_by') do
  CG.validate_relations!([{ 'type' => 'informed_by', 'target' => 'v1:a/b' }])
  true
end

# Valid: with extra string metadata
assert('valid with extra metadata') do
  CG.validate_relations!([{
    'type' => 'informed_by',
    'target' => 'v1:a/b',
    'observed_at' => '2026-05-01T10:00:00+02:00',
    'reason' => 'manual'
  }])
  true
end

# Unknown type accepted on write (Phase 2 forward-compat)
assert('unknown type accepted on write') do
  CG.validate_relations!([{ 'type' => 'supersedes', 'target' => 'v1:a/b' }])
  true
end

# ============================================================
section('4. atomic_write (§4.2 step 4)')
# ============================================================

Dir.mktmpdir do |dir|
  target = File.join(dir, 'sub', 'file.txt')
  CG.atomic_write(target, 'hello')
  assert('atomic_write creates file with content') { File.read(target) == 'hello' }
  assert('atomic_write creates parent dir') { File.directory?(File.dirname(target)) }

  # Replace existing
  CG.atomic_write(target, 'replaced')
  assert('atomic_write replaces existing') { File.read(target) == 'replaced' }

  # No tempfile leak after success
  leftover = Dir[File.join(File.dirname(target), '*.tmp.*')]
  assert('no tempfile leak') { leftover.empty? }
end

# ============================================================
section('5. ContextManager integration')
# ============================================================

Dir.mktmpdir do |root|
  KairosMcp._test_context_dir = root
  cm = KairosMcp::ContextManager.new(root)

  # Save a target context first (so informed_by can resolve)
  sid_a = 'session_20260501_100000_aaaaaaaa'
  cm.save_context(sid_a, 'target_ctx', "---\nname: target_ctx\n---\nbody A")

  # Save context with valid relations referencing target
  sid_b = 'session_20260501_110000_bbbbbbbb'
  content_b = <<~MD
    ---
    name: source_ctx
    relations_schema: 1
    relations:
      - type: informed_by
        target: v1:#{sid_a}/target_ctx
    ---
    body B
  MD
  result = cm.save_context(sid_b, 'source_ctx', content_b)
  assert('save valid relations succeeds') { result[:success] == true }

  # Save context with bad target regex
  bad_content = <<~MD
    ---
    name: bad_ctx
    relations_schema: 1
    relations:
      - type: informed_by
        target: garbage_target
    ---
    body
  MD
  result = cm.save_context(sid_b, 'bad_ctx', bad_content)
  assert('bad target regex rejected') { result[:success] == false && result[:error].include?('MalformedTargetError') }

  # Save context with non-Array relations
  bad_content2 = <<~MD
    ---
    name: bad_ctx2
    relations: not an array
    ---
    body
  MD
  result = cm.save_context(sid_b, 'bad_ctx2', bad_content2)
  assert('non-Array relations rejected') { result[:success] == false && result[:error].include?('MalformedRelations') }

  # Save context with forward reference (ENOENT target = dangling, allowed on write)
  fwd_content = <<~MD
    ---
    name: fwd_ctx
    relations_schema: 1
    relations:
      - type: informed_by
        target: v1:#{sid_a}/nonexistent
    ---
    body
  MD
  result = cm.save_context(sid_b, 'fwd_ctx', fwd_content)
  assert('forward reference (dangling) accepted') { result[:success] == true }

  # No relations: legacy L2 context still works
  result = cm.save_context(sid_b, 'legacy_ctx', "---\nname: legacy\n---\nbody")
  assert('legacy context (no relations) works') { result[:success] == true }
end

# ============================================================
section('6. traverse_informed_by (§5)')
# ============================================================

Dir.mktmpdir do |root|
  KairosMcp._test_context_dir = root
  cm = KairosMcp::ContextManager.new(root)

  # Build a small graph: A -> B -> C, also A -> D, with one dangling edge D -> missing
  sid = 'session_20260501_010000_11111111'

  cm.save_context(sid, 'node_c', "---\nname: node_c\n---\nleaf")

  cm.save_context(sid, 'node_b', <<~MD)
    ---
    name: node_b
    relations_schema: 1
    relations:
      - type: informed_by
        target: v1:#{sid}/node_c
    ---
    body
  MD

  cm.save_context(sid, 'node_d', <<~MD)
    ---
    name: node_d
    relations_schema: 1
    relations:
      - type: informed_by
        target: v1:#{sid}/missing
    ---
    body
  MD

  cm.save_context(sid, 'node_a', <<~MD)
    ---
    name: node_a
    relations_schema: 1
    relations:
      - type: informed_by
        target: v1:#{sid}/node_b
      - type: informed_by
        target: v1:#{sid}/node_d
    ---
    body
  MD

  result = CG.traverse_informed_by(start_sid: sid, start_name: 'node_a',
                                   context_root: root, max_depth: 3)

  assert('traverse returns root') { result[:root] == "v1:#{sid}/node_a" }
  assert('traverse visits node_a (depth 0)') do
    result[:nodes].any? { |n| n[:target] == "v1:#{sid}/node_a" && n[:depth] == 0 && n[:status] == :ok }
  end
  assert('traverse visits node_b at depth 1') do
    result[:nodes].any? { |n| n[:target] == "v1:#{sid}/node_b" && n[:depth] == 1 && n[:status] == :ok }
  end
  assert('traverse visits node_c at depth 2') do
    result[:nodes].any? { |n| n[:target] == "v1:#{sid}/node_c" && n[:depth] == 2 && n[:status] == :ok }
  end
  assert('traverse visits node_d (dangling child) at depth 1') do
    result[:nodes].any? { |n| n[:target] == "v1:#{sid}/node_d" && n[:depth] == 1 && n[:status] == :ok }
  end
  assert('traverse marks missing as :dangling') do
    result[:nodes].any? { |n| n[:target] == "v1:#{sid}/missing" && n[:status] == :dangling }
  end
  assert('result has warnings array') { result[:warnings].is_a?(Array) }

  # Cycle: make node_c -> node_a, then traverse should not infinite-loop
  cm.save_context(sid, 'node_c', <<~MD)
    ---
    name: node_c
    relations_schema: 1
    relations:
      - type: informed_by
        target: v1:#{sid}/node_a
    ---
    leaf cycled
  MD

  result = CG.traverse_informed_by(start_sid: sid, start_name: 'node_a',
                                   context_root: root, max_depth: 5)
  visit_count = result[:nodes].count { |n| n[:target] == "v1:#{sid}/node_a" }
  assert('cycle does not double-visit node_a') { visit_count == 1 }

  # Depth limit
  deep_result = CG.traverse_informed_by(start_sid: sid, start_name: 'node_a',
                                        context_root: root, max_depth: 1)
  max_depth = deep_result[:nodes].map { |n| n[:depth] }.max
  assert('max_depth=1 limits depth to 1') { max_depth <= 1 }
end

# ============================================================
section('7. read-side: parse fail / unknown schema → skip + warn')
# ============================================================

Dir.mktmpdir do |root|
  sid = 'session_20260501_020000_22222222'

  # Manually create a context with malformed YAML to bypass write validation
  ctx_dir = File.join(root, sid, 'broken')
  FileUtils.mkdir_p(ctx_dir)
  File.write(File.join(ctx_dir, 'broken.md'), "---\nname: broken\n  invalid: yaml: [unclosed\n---\nbody")

  # And one with unknown relations_schema
  ctx_dir2 = File.join(root, sid, 'future_schema')
  FileUtils.mkdir_p(ctx_dir2)
  File.write(File.join(ctx_dir2, 'future_schema.md'), "---\nname: future_schema\nrelations_schema: 99\nrelations:\n  - type: future_kind\n    target: v1:#{sid}/whatever\n---\nbody")

  # Build a source pointing at both
  ctx_dir3 = File.join(root, sid, 'source')
  FileUtils.mkdir_p(ctx_dir3)
  File.write(File.join(ctx_dir3, 'source.md'), <<~MD)
    ---
    name: source
    relations_schema: 1
    relations:
      - type: informed_by
        target: v1:#{sid}/broken
      - type: informed_by
        target: v1:#{sid}/future_schema
    ---
    body
  MD

  result = CG.traverse_informed_by(start_sid: sid, start_name: 'source',
                                   context_root: root, max_depth: 3)

  assert('parse failure produces warning') do
    result[:warnings].any? { |w| w.include?('parse_failed') }
  end
  assert('unknown schema produces warning') do
    result[:warnings].any? { |w| w.include?('unknown_schema_version') }
  end
  # Both nodes themselves should be visited (ok status, since they exist) but
  # their outgoing edges not followed. broken has no parseable schema so no
  # outgoing edges either way.
  assert('broken/future_schema visited as :ok') do
    result[:nodes].count { |n| %w[broken future_schema].include?(n[:target].split('/').last) && n[:status] == :ok } == 2
  end
end

# ===== Summary =====
puts "\n===== RESULTS ====="
puts "  PASS: #{$pass}"
puts "  FAIL: #{$fail}"
if $fail > 0
  puts "\n  Failed tests:"
  $errors.each { |e| puts "    - #{e}" }
end
exit($fail > 0 ? 1 : 0)
