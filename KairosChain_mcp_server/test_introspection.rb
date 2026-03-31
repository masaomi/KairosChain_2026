#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Phase 2: introspection SkillSet
# Tests: 10 sections (M1-M10)
# Usage: ruby test_introspection.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'

require 'kairos_mcp/anthropic_skill_parser'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/kairos_chain/chain'
require 'kairos_mcp/kairos_chain/block'
require 'kairos_mcp/safety'
require 'kairos_mcp/skills_config'
require 'kairos_mcp/tools/base_tool'

# Load introspection SkillSet from templates
introspection_path = File.join(__dir__, '..', 'templates', 'skillsets', 'introspection')
require File.join(introspection_path, 'lib', 'introspection')
require File.join(introspection_path, 'tools', 'introspection_check')
require File.join(introspection_path, 'tools', 'introspection_health')
require File.join(introspection_path, 'tools', 'introspection_safety')

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
  puts e.backtrace.first(3).map { |l| "    #{l}" }.join("\n")
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
test_dir = Dir.mktmpdir('kairos_introspection_test')
KairosMcp.data_dir = test_dir

FileUtils.mkdir_p(KairosMcp.skills_dir)
FileUtils.mkdir_p(KairosMcp.knowledge_dir)
FileUtils.mkdir_p(KairosMcp.storage_dir)
FileUtils.mkdir_p(KairosMcp.skillsets_dir)
FileUtils.mkdir_p(KairosMcp.context_dir)

# Stub config files
File.write(
  File.join(KairosMcp.skills_dir, 'config.yml'),
  "storage:\n  backend: file\nskills:\n  state_commit:\n    enabled: false\n"
)
File.write(File.join(KairosMcp.skills_dir, 'kairos.rb'), "# stub\n")

puts "introspection SkillSet Test Suite"
puts "Ruby version: #{RUBY_VERSION}"
puts "Temp dir: #{test_dir}"
puts ""

# ===== Helpers =====

def create_test_knowledge(name, tags: [], content: "Knowledge content", mtime: nil)
  k_dir = File.join(KairosMcp.knowledge_dir, name)
  FileUtils.mkdir_p(k_dir)
  frontmatter = { 'name' => name, 'tags' => tags, 'description' => "Test knowledge #{name}" }
  md_content = "#{YAML.dump(frontmatter)}---\n\n# #{name}\n\n#{content}"
  md_path = File.join(k_dir, "#{name}.md")
  File.write(md_path, md_content)
  # Set custom mtime if requested (for staleness testing)
  if mtime
    File.utime(mtime, mtime, md_path)
  end
  k_dir
end

# ===== M1: introspection_check returns all V1 domains =====
test_section('M1: introspection_check returns all V1 domains') do
  create_test_knowledge('m1_test_knowledge', tags: %w[test])

  tool = KairosMcp::SkillSets::Introspection::Tools::IntrospectionCheck.new(nil)
  result = tool.call({})
  text = result.first[:text]

  # Markdown format by default
  assert('returns text output') { text.is_a?(String) && !text.empty? }
  assert('contains health section') { text.include?('Knowledge Health') }
  assert('contains blockchain section') { text.include?('Blockchain') }
  assert('contains safety section') { text.include?('Safety Mechanisms') }
  assert('contains inspected_at marker') { text.include?('Inspected at') }
end

# ===== M2: health scoring with TrustScorer available =====
# (Synoptis is not loaded in test env, so we test the fallback path)
test_section('M2: health scoring with TrustScorer — fallback to staleness') do
  create_test_knowledge('m2_trust_test', tags: %w[trust test])

  scorer = KairosMcp::SkillSets::Introspection::HealthScorer.new
  result = scorer.score_l1

  assert('trust_scorer_available is false (Synoptis not loaded)') { result[:trust_scorer_available] == false }
  assert('entries present') { result[:entries].is_a?(Array) }

  m2_entry = result[:entries].find { |e| e[:name] == 'm2_trust_test' }
  assert('m2 entry found') { m2_entry != nil }
  # Freshly created file should have high staleness score (close to 1.0)
  assert('health_score > 0.8 for fresh entry') { m2_entry && m2_entry[:health_score] > 0.8 }
  # Without TrustScorer, trust_score should be 0.0
  assert('trust_score is 0.0 without TrustScorer') { m2_entry && m2_entry[:trust_score] == 0.0 }
end

# ===== M3: health scoring without TrustScorer (staleness only) =====
test_section('M3: health scoring without TrustScorer — staleness only') do
  # Create a knowledge with old mtime (200 days ago)
  old_time = Time.now - (200 * 86400)
  create_test_knowledge('m3_stale_knowledge', tags: %w[stale], mtime: old_time)

  scorer = KairosMcp::SkillSets::Introspection::HealthScorer.new
  result = scorer.score_l1

  assert('trust_scorer_available is false') { result[:trust_scorer_available] == false }

  stale_entry = result[:entries].find { |e| e[:name] == 'm3_stale_knowledge' }
  assert('stale entry found') { stale_entry != nil }
  # 200 days with 180 day threshold => staleness = max(1 - 200/180, 0) = 0.0
  assert('health_score near 0.0 for stale entry') { stale_entry && stale_entry[:health_score] < 0.2 }
end

# ===== M4: blockchain integrity check =====
test_section('M4: blockchain integrity check') do
  tool = KairosMcp::SkillSets::Introspection::Tools::IntrospectionCheck.new(nil)
  result = tool.call('domains' => ['blockchain'])
  text = result.first[:text]

  assert('contains blockchain info') { text.include?('Blockchain') }
  assert('contains valid marker') { text.include?('Valid') || text.include?('valid') }
  assert('contains block count') { text.include?('Block count') || text.include?('block_count') }
end

# ===== M5: safety shows all mechanism layers =====
test_section('M5: safety shows all 4 mechanism layers') do
  tool = KairosMcp::SkillSets::Introspection::Tools::IntrospectionSafety.new(nil)
  result = tool.call({})
  text = result.first[:text]
  parsed = JSON.parse(text)

  layers = parsed['layers']
  assert('layers key present') { layers.is_a?(Hash) }
  assert('l0_approval_workflow present') { layers.key?('l0_approval_workflow') }
  assert('runtime_rbac present') { layers.key?('runtime_rbac') }
  assert('agent_safety_gates present') { layers.key?('agent_safety_gates') }
  assert('blockchain_recording present') { layers.key?('blockchain_recording') }
end

# ===== M6: Safety.registered_policy_names works =====
test_section('M6: Safety.registered_policy_names public API') do
  # Clear any existing policies
  KairosMcp::Safety.clear_policies!

  # Register test policies
  KairosMcp::Safety.register_policy(:test_introspection_policy) { true }
  KairosMcp::Safety.register_policy(:can_modify_l0) { |u| u[:role] == 'owner' }

  names = KairosMcp::Safety.registered_policy_names
  assert('returns array of strings') { names.is_a?(Array) && names.all? { |n| n.is_a?(String) } }
  assert('includes test_introspection_policy') { names.include?('test_introspection_policy') }
  assert('includes can_modify_l0') { names.include?('can_modify_l0') }

  # Cleanup
  KairosMcp::Safety.unregister_policy(:test_introspection_policy)
  KairosMcp::Safety.unregister_policy(:can_modify_l0)
end

# ===== M7: recommendations from low health scores =====
test_section('M7: recommendations from low health scores') do
  # Create knowledge with very old mtime (1 year ago)
  very_old = Time.now - (365 * 86400)
  create_test_knowledge('m7_ancient_knowledge', tags: %w[old], mtime: very_old)

  tool = KairosMcp::SkillSets::Introspection::Tools::IntrospectionCheck.new(nil)
  result = tool.call('format' => 'json')
  text = result.first[:text]
  parsed = JSON.parse(text)

  recs = parsed['recommendations']
  assert('recommendations is array') { recs.is_a?(Array) }

  medium_rec = recs.find { |r| r['priority'] == 'medium' && r['target'] == 'm7_ancient_knowledge' }
  assert('medium priority recommendation for ancient knowledge') { medium_rec != nil }
end

# ===== M8: recommendations from blockchain failure =====
test_section('M8: recommendations from blockchain failure') do
  tool = KairosMcp::SkillSets::Introspection::Tools::IntrospectionCheck.new(nil)

  # Call with blockchain domain — a fresh chain should be valid
  result = tool.call('format' => 'json', 'domains' => ['blockchain'])
  text = result.first[:text]
  parsed = JSON.parse(text)

  assert('fresh blockchain is valid') { parsed['blockchain']['valid'] == true }
  assert('no critical rec for valid chain') do
    parsed['recommendations'].none? { |r| r['priority'] == 'critical' }
  end

  # Test build_recommendations directly with a simulated invalid blockchain report
  report = {
    blockchain: { valid: false, block_count: 5, status: 'INTEGRITY_FAILURE' },
    health: nil,
    safety: nil
  }
  recs = tool.send(:build_recommendations, report)
  critical = recs.find { |r| r[:priority] == 'critical' && r[:target] == 'blockchain' }
  assert('critical rec generated for invalid blockchain') { critical != nil }
  assert('critical message mentions integrity') { critical[:message].include?('integrity') || critical[:message].include?('Integrity') }
end

# ===== M9: json format output =====
test_section('M9: json format output') do
  tool = KairosMcp::SkillSets::Introspection::Tools::IntrospectionCheck.new(nil)
  result = tool.call('format' => 'json')
  text = result.first[:text]

  parsed = nil
  assert('JSON.parse succeeds') do
    parsed = JSON.parse(text)
    true
  end
  assert('has inspected_at key') { parsed && parsed.key?('inspected_at') }
  assert('has health key') { parsed && parsed.key?('health') }
  assert('has blockchain key') { parsed && parsed.key?('blockchain') }
  assert('has safety key') { parsed && parsed.key?('safety') }
  assert('has recommendations key') { parsed && parsed.key?('recommendations') }
end

# ===== M10: introspection_health single entry =====
test_section('M10: introspection_health single entry') do
  create_test_knowledge('m10_single_entry', tags: %w[single test])

  tool = KairosMcp::SkillSets::Introspection::Tools::IntrospectionHealth.new(nil)
  result = tool.call('name' => 'm10_single_entry')
  text = result.first[:text]
  parsed = JSON.parse(text)

  assert('returns entry (not entries array)') { parsed.key?('entry') }
  assert('entry has name') { parsed['entry']['name'] == 'm10_single_entry' }
  assert('entry has health_score') { parsed['entry'].key?('health_score') }
  assert('trust_scorer_available present') { parsed.key?('trust_scorer_available') }

  # Test not-found case
  result_missing = tool.call('name' => 'nonexistent_knowledge')
  text_missing = result_missing.first[:text]
  parsed_missing = JSON.parse(text_missing)
  assert('not found returns error') { parsed_missing.key?('error') }
end

# ===== Summary =====
separator
puts ""
puts "RESULTS: #{$pass_count} passed, #{$fail_count} failed"
if $errors.any?
  puts ""
  puts "FAILURES:"
  $errors.each { |e| puts "  - #{e}" }
end
puts ""

# Cleanup
FileUtils.rm_rf(test_dir)

exit($fail_count > 0 ? 1 : 0)
