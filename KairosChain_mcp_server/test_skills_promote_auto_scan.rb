#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: skills_promote auto_scan extension + attestation on promote
# Tests: 9 sections (M1-M9)

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'set'

require 'kairos_mcp/anthropic_skill_parser'
require 'kairos_mcp/context_manager'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/skills_config'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tools/skills_promote'

# ===== Test Harness =====
$pass_count = 0
$fail_count = 0
$errors = []

def assert(desc)
  result = yield
  if result
    $pass_count += 1
    puts "  PASS: #{desc}"
  else
    $fail_count += 1
    $errors << desc
    puts "  FAIL: #{desc}"
  end
rescue StandardError => e
  $fail_count += 1
  $errors << "#{desc} (#{e.class}: #{e.message})"
  puts "  FAIL: #{desc} — #{e.class}: #{e.message}"
end

def separator
  puts '-' * 60
end

def test_section(title)
  separator
  puts "TEST: #{title}"
  separator
  yield
rescue StandardError => e
  $fail_count += 1
  $errors << "#{title} (#{e.class}: #{e.message})"
  puts "  ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

# ===== Setup =====
test_dir = Dir.mktmpdir('kairos_promote_scan_test')
KairosMcp.data_dir = test_dir

FileUtils.mkdir_p(KairosMcp.skills_dir)
FileUtils.mkdir_p(KairosMcp.knowledge_dir)
FileUtils.mkdir_p(KairosMcp.storage_dir)
FileUtils.mkdir_p(KairosMcp.skillsets_dir)
FileUtils.mkdir_p(KairosMcp.context_dir)

# Stub config files
File.write(File.join(KairosMcp.skills_dir, 'kairos.rb'), "# stub\n")
File.write(File.join(KairosMcp.skills_dir, 'config.yml'), "storage:\n  backend: file\nskills:\n  state_commit:\n    enabled: false\n")

puts "skills_promote auto_scan Test Suite"
puts "Ruby version: #{RUBY_VERSION}"
puts "Temp dir: #{test_dir}"
puts ""

# ===== Helpers =====

def create_test_context(session_id, name, tags: [], content: "Test content")
  ctx_dir = File.join(KairosMcp.context_dir, session_id, name)
  FileUtils.mkdir_p(ctx_dir)
  frontmatter = { 'title' => name, 'tags' => tags, 'description' => "Test context #{name}" }
  # YAML.dump includes leading "---\n", so we just append the closing "---\n"
  md_content = "#{YAML.dump(frontmatter)}---\n\n# #{name}\n\n#{content}"
  File.write(File.join(ctx_dir, "#{name}.md"), md_content)
  ctx_dir
end

def create_test_knowledge(name, tags: [], content: "Knowledge content")
  k_dir = File.join(KairosMcp.knowledge_dir, name)
  FileUtils.mkdir_p(k_dir)
  frontmatter = { 'title' => name, 'tags' => tags, 'description' => "Test knowledge #{name}" }
  md_content = "#{YAML.dump(frontmatter)}---\n\n# #{name}\n\n#{content}"
  File.write(File.join(k_dir, "#{name}.md"), md_content)
  k_dir
end

def build_tool
  KairosMcp::Tools::SkillsPromote.new(nil)
end

# ===== M1: auto_scan returns candidates from L2 patterns =====
test_section('M1: auto_scan basic — returns candidates from L2 patterns') do
  # Setup: 5 L2 contexts across 4 sessions with overlapping tags
  # This produces: recurrence=40, tag_consistency~22, session_diversity=30 => ~92
  create_test_context('session_m1_a', 'debug_namespace_1', tags: %w[debug namespace ruby])
  create_test_context('session_m1_b', 'debug_namespace_2', tags: %w[debug namespace ruby])
  create_test_context('session_m1_c', 'debug_namespace_3', tags: %w[debug namespace ruby])
  create_test_context('session_m1_d', 'debug_namespace_4', tags: %w[debug namespace ruby])
  create_test_context('session_m1_e', 'debug_namespace_5', tags: %w[debug namespace ruby])

  tool = build_tool
  result = tool.call('command' => 'auto_scan', 'scan_depth' => 10)

  text = result.first[:text]
  parsed = JSON.parse(text)

  assert('scan_summary present') { parsed['scan_summary'].is_a?(Hash) }
  assert('contexts_loaded >= 5') { parsed['scan_summary']['contexts_loaded'] >= 5 }
  assert('candidates is array') { parsed['candidates'].is_a?(Array) }
  assert('at least 1 candidate') { parsed['candidates'].size >= 1 }

  first = parsed['candidates'].first
  assert('candidate has suggested_name') { first && first['suggested_name'].is_a?(String) }
  assert('candidate has confidence >= 70') { first && first['confidence'] >= 70 }
  assert('candidate has recurrence >= 2') { first && first['recurrence'] >= 2 }
  assert('candidate has source_contexts') { first && first['source_contexts'].is_a?(Array) }
  assert('candidate has common_tags') { first && first['common_tags'].is_a?(Array) }
end

# ===== M2: auto_scan deduplicates against existing L1 (name match) =====
test_section('M2: dedup by name') do
  # Create L1 knowledge with similar name
  create_test_knowledge('debug_namespace_pattern', tags: %w[other])

  # Create L2 contexts that would produce "debug_namespace_pattern" as name
  create_test_context('session_m2_a', 'debug_ns_ctx_1', tags: %w[debug namespace])
  create_test_context('session_m2_a', 'debug_ns_ctx_2', tags: %w[debug namespace])
  create_test_context('session_m2_b', 'debug_ns_ctx_3', tags: %w[debug namespace])

  tool = build_tool
  result = tool.call('command' => 'auto_scan', 'scan_depth' => 50)
  parsed = JSON.parse(result.first[:text])

  assert('already_in_l1 >= 1') { parsed['scan_summary']['already_in_l1'] >= 1 }
end

# ===== M3: auto_scan deduplicates against existing L1 (tag overlap) =====
test_section('M3: dedup by tags') do
  # Create L1 knowledge with high tag overlap
  create_test_knowledge('some_review_workflow', tags: %w[review multi-llm workflow orchestration])

  # Create L2 contexts with nearly identical tags
  create_test_context('session_m3_a', 'review_ctx_1', tags: %w[review multi-llm workflow orchestration])
  create_test_context('session_m3_a', 'review_ctx_2', tags: %w[review multi-llm workflow])
  create_test_context('session_m3_b', 'review_ctx_3', tags: %w[review multi-llm workflow orchestration])

  tool = build_tool
  result = tool.call('command' => 'auto_scan', 'scan_depth' => 50)
  parsed = JSON.parse(result.first[:text])

  # The cluster formed by review_ctx_* should match the L1 entry via tag overlap
  assert('already_in_l1 >= 1 (tag match)') { parsed['scan_summary']['already_in_l1'] >= 1 }
end

# ===== M4: auto_scan respects confidence threshold =====
test_section('M4: confidence threshold filtering') do
  # Create a weak pattern: only 2 contexts in 1 session (low score)
  create_test_context('session_m4_a', 'weak_ctx_1', tags: %w[alpha beta gamma])
  create_test_context('session_m4_a', 'weak_ctx_2', tags: %w[alpha beta delta])

  tool = build_tool
  result = tool.call('command' => 'auto_scan', 'scan_depth' => 50, 'confidence_threshold' => 90)
  parsed = JSON.parse(result.first[:text])

  # Score for 2 items in 1 session: recurrence=10 + tag_consistency + session_diversity=0
  # Should be well below 90
  weak_candidates = parsed['candidates'].select do |c|
    c['common_tags']&.include?('alpha')
  end
  assert('no weak candidates above threshold 90') { weak_candidates.empty? }
end

# ===== M5: promote_to_l1 issues attestation via invoke_tool =====
test_section('M5: promote issues attestation via invoke_tool') do
  # Create a context to promote
  create_test_context('session_m5', 'promote_test_ctx', tags: %w[test], content: "---\ntitle: promote_test_ctx\ntags:\n  - test\n---\n\nPromotable content")

  # Create a mock registry that tracks invoke_tool calls
  invocations = []
  mock_registry = Object.new
  mock_registry.define_singleton_method(:call_tool) do |tool_name, arguments, invocation_context: nil|
    invocations << { tool: tool_name, args: arguments }
    [{ type: 'text', text: '{"success": true}' }]
  end

  tool = KairosMcp::Tools::SkillsPromote.new(nil, registry: mock_registry)
  tool.call(
    'command' => 'promote',
    'source_name' => 'promote_test_ctx',
    'from_layer' => 'L2',
    'to_layer' => 'L1',
    'session_id' => 'session_m5',
    'reason' => 'Test promotion'
  )

  attestation_call = invocations.find { |i| i[:tool] == 'attestation_issue' }
  assert('attestation_issue was called') { !attestation_call.nil? }
  assert('subject_ref starts with knowledge://') do
    attestation_call && attestation_call[:args]['subject_ref'].start_with?('knowledge://')
  end
  assert('claim is promoted_from_l2') do
    attestation_call && attestation_call[:args]['claim'] == 'promoted_from_l2'
  end
end

# ===== M6: promote_to_l1 graceful without Synoptis =====
test_section('M6: promote graceful without Synoptis') do
  create_test_context('session_m6', 'promote_no_synoptis', tags: %w[test], content: "---\ntitle: promote_no_synoptis\ntags:\n  - test\n---\n\nContent")

  # Tool without registry — synoptis_available? returns false
  tool = build_tool
  result = tool.call(
    'command' => 'promote',
    'source_name' => 'promote_no_synoptis',
    'from_layer' => 'L2',
    'to_layer' => 'L1',
    'session_id' => 'session_m6',
    'reason' => 'Test without synoptis'
  )

  text = result.first[:text]
  assert('promotion succeeds without Synoptis') { text.include?('Promotion Successful') }
end

# ===== M7: auto_scan with empty L2 =====
test_section('M7: auto_scan with empty L2') do
  # Use a clean temp dir for this test
  empty_dir = Dir.mktmpdir('kairos_empty_test')
  original_data_dir = KairosMcp.data_dir
  KairosMcp.data_dir = empty_dir
  FileUtils.mkdir_p(KairosMcp.skills_dir)
  FileUtils.mkdir_p(KairosMcp.knowledge_dir)
  FileUtils.mkdir_p(KairosMcp.storage_dir)
  FileUtils.mkdir_p(KairosMcp.skillsets_dir)
  FileUtils.mkdir_p(KairosMcp.context_dir)
  File.write(File.join(KairosMcp.skills_dir, 'kairos.rb'), "# stub\n")
  File.write(File.join(KairosMcp.skills_dir, 'config.yml'), "storage:\n  backend: file\nskills:\n  state_commit:\n    enabled: false\n")

  tool = build_tool
  result = tool.call('command' => 'auto_scan')
  parsed = JSON.parse(result.first[:text])

  assert('candidates empty') { parsed['candidates'].empty? }
  assert('contexts_loaded is 0') { parsed['scan_summary']['contexts_loaded'] == 0 }
  assert('no error raised') { true }

  # Restore
  KairosMcp.data_dir = original_data_dir
  FileUtils.rm_rf(empty_dir)
end

# ===== M8: auto_scan skips tagless contexts =====
test_section('M8: tagless contexts skipped from clusters') do
  # Clean environment for isolation
  tagless_dir = Dir.mktmpdir('kairos_tagless_test')
  original_data_dir = KairosMcp.data_dir
  KairosMcp.data_dir = tagless_dir
  FileUtils.mkdir_p(KairosMcp.skills_dir)
  FileUtils.mkdir_p(KairosMcp.knowledge_dir)
  FileUtils.mkdir_p(KairosMcp.storage_dir)
  FileUtils.mkdir_p(KairosMcp.skillsets_dir)
  FileUtils.mkdir_p(KairosMcp.context_dir)
  File.write(File.join(KairosMcp.skills_dir, 'kairos.rb'), "# stub\n")
  File.write(File.join(KairosMcp.skills_dir, 'config.yml'), "storage:\n  backend: file\nskills:\n  state_commit:\n    enabled: false\n")

  # Create contexts without tags
  create_test_context('session_m8_a', 'no_tags_1', tags: [], content: "No tags here")
  create_test_context('session_m8_a', 'no_tags_2', tags: [], content: "No tags here either")
  create_test_context('session_m8_b', 'no_tags_3', tags: [], content: "Still no tags")

  tool = build_tool
  result = tool.call('command' => 'auto_scan')
  parsed = JSON.parse(result.first[:text])

  assert('contexts_loaded counts tagless contexts') { parsed['scan_summary']['contexts_loaded'] >= 3 }
  assert('no clusters formed from tagless') { parsed['candidates'].empty? }

  # Restore
  KairosMcp.data_dir = original_data_dir
  FileUtils.rm_rf(tagless_dir)
end

# ===== M9: scan_depth capped at 50 =====
test_section('M9: scan_depth capped at 50') do
  tool = build_tool
  result = tool.call('command' => 'auto_scan', 'scan_depth' => 999)
  parsed = JSON.parse(result.first[:text])

  assert('sessions_scanned <= 50') { parsed['scan_summary']['sessions_scanned'] <= 50 }
end

# ===== Summary =====
puts ''
separator
puts "RESULTS: #{$pass_count} passed, #{$fail_count} failed"
unless $errors.empty?
  puts "\nFailed tests:"
  $errors.each { |e| puts "  - #{e}" }
end
separator

FileUtils.rm_rf(test_dir)

exit($fail_count.zero? ? 0 : 1)
