#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: KnowledgeProvider robustness against backup directories and YAML frontmatter integrity
# Regression tests for Phase 2 Case A deployment_realism findings:
#   1. .bak.* directories created by `kairos-chain upgrade` must be skipped during scan
#   2. All bundled L1 knowledge frontmatter must round-trip through YAML.safe_load
#      and have description as String (not Hash) — guards the v3.24.6 → v3.24.7
#      class of bug where unquoted description with embedded `:` parsed as mapping

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/knowledge_provider'
require 'tmpdir'
require 'fileutils'
require 'yaml'

failures = 0
passes = 0

def assert(cond, msg)
  if cond
    print '.'
    @passes += 1
  else
    puts "\nFAIL: #{msg}"
    @failures += 1
  end
end

@failures = 0
@passes = 0

# ============================================================================
# Section 1: Backup directory pattern matching
# ============================================================================

puts "\n[Section 1] BACKUP_DIR_PATTERN matching"

pattern = KairosMcp::KnowledgeProvider::BACKUP_DIR_PATTERN

# Should match upgrade-created backup names
assert pattern.match?('.bak.20260503154913'), '.bak.<timestamp> should match'
assert pattern.match?('context_graph_recall.bak.20260503154913'), '<name>.bak.<timestamp> should match'
assert pattern.match?('foo.bak'), '<name>.bak (no timestamp) should match'
assert pattern.match?('.bak'), '.bak alone should match'

# Should NOT match normal knowledge names
assert !pattern.match?('context_graph_recall'), 'normal name should not match'
assert !pattern.match?('kairoschain_capability_boundary'), 'normal name should not match'
assert !pattern.match?('backup_workflow'), '"backup" prefix without .bak should not match'
assert !pattern.match?('.archived'), '.archived should not match (separate constant)'

# ============================================================================
# Section 2: skill_dirs skips .bak.* directories
# ============================================================================

puts "\n[Section 2] skill_dirs skips backup directories"

Dir.mktmpdir do |tmp|
  knowledge_dir = File.join(tmp, 'knowledge')
  FileUtils.mkdir_p(knowledge_dir)

  # Create normal knowledge dir
  FileUtils.mkdir_p(File.join(knowledge_dir, 'normal_skill'))
  File.write(File.join(knowledge_dir, 'normal_skill', 'normal_skill.md'),
             "---\nname: normal_skill\ndescription: \"normal\"\n---\n# normal\n")

  # Create .bak.* directory with broken frontmatter (would crash YAML parse if scanned)
  FileUtils.mkdir_p(File.join(knowledge_dir, 'normal_skill.bak.20260503154913'))
  File.write(File.join(knowledge_dir, 'normal_skill.bak.20260503154913', 'normal_skill.md'),
             "---\nname: broken\ndescription: a `relations: informed_by` is unquoted\n---\n# broken\n")

  # Create .archived directory (already excluded, should also be excluded)
  FileUtils.mkdir_p(File.join(knowledge_dir, '.archived'))

  provider = KairosMcp::KnowledgeProvider.new(knowledge_dir, vector_search_enabled: false)
  dirs = provider.send(:skill_dirs)

  basenames = dirs.map { |d| File.basename(d) }
  assert basenames.include?('normal_skill'), 'normal_skill must be listed'
  assert !basenames.include?('normal_skill.bak.20260503154913'), '.bak.<timestamp> must be skipped'
  assert !basenames.include?('.archived'), '.archived must remain skipped'

  # provider.list should not raise even though backup contains broken YAML
  begin
    result = provider.list
    assert true, 'provider.list does not raise on .bak.* with broken YAML'
    assert result.is_a?(Array), 'provider.list returns array'
    listed_names = result.map { |r| r[:name] }
    assert listed_names.include?('normal_skill'), 'normal_skill appears in list'
    assert !listed_names.include?('broken'), 'broken (in .bak.*) does not appear in list'
  rescue => e
    assert false, "provider.list raised: #{e.message}"
  end
end

# ============================================================================
# Section 3: Frontmatter round-trip guard for bundled L1 knowledge
# ============================================================================

puts "\n[Section 3] Bundled L1 knowledge frontmatter round-trip"

bundled_knowledge = File.expand_path('knowledge', __dir__)
md_files = Dir[File.join(bundled_knowledge, '**', '*.md')].reject do |f|
  # Skip backup, archive, and example files
  parts = f.split('/')
  parts.any? { |p| p.match?(KairosMcp::KnowledgeProvider::BACKUP_DIR_PATTERN) || p == '.archived' || p == 'example_knowledge' }
end

md_files.each do |md|
  content = File.read(md)
  unless content.start_with?('---')
    # Skip files without frontmatter (some are pure markdown)
    next
  end

  m = content.match(/\A---\n(.*?)\n---/m)
  unless m
    assert false, "#{md}: frontmatter terminator missing"
    next
  end

  begin
    fm = YAML.safe_load(m[1], permitted_classes: [Symbol, Date, Time])
  rescue Psych::SyntaxError => e
    assert false, "#{md}: YAML parse error — #{e.message}"
    next
  rescue => e
    assert false, "#{md}: unexpected error — #{e.message}"
    next
  end

  assert fm.is_a?(Hash), "#{md}: frontmatter must be a Hash, got #{fm.class}"

  if fm.is_a?(Hash) && fm.key?('description')
    assert fm['description'].is_a?(String) || fm['description'].is_a?(NilClass),
           "#{md}: description must be String (or nil), got #{fm['description'].class} — likely unquoted value with embedded ':'"
  end
end

# ============================================================================
# Summary
# ============================================================================

puts "\n\n#{@passes} passed, #{@failures} failed"
exit(@failures.zero? ? 0 : 1)
