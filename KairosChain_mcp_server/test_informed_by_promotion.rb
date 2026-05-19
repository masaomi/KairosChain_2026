#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: L2 → L1 promotion auto-attaches relations.informed_by edge.
# Design: docs/drafts/l1_informed_by_field_design_v0.2_draft.md
# Verifies Inv 1/2/3 and Success Criteria §7.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'yaml'

require 'kairos_mcp/anthropic_skill_parser'
require 'kairos_mcp/context_manager'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/skills_config'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tools/skills_promote'

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

def test_section(title)
  puts '-' * 60
  puts "TEST: #{title}"
  puts '-' * 60
  yield
rescue StandardError => e
  $fail_count += 1
  $errors << "#{title} (#{e.class}: #{e.message})"
  puts "  ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

test_dir = Dir.mktmpdir('kairos_informed_by_test')
KairosMcp.data_dir = test_dir
FileUtils.mkdir_p(KairosMcp.skills_dir)
FileUtils.mkdir_p(KairosMcp.knowledge_dir)
FileUtils.mkdir_p(KairosMcp.storage_dir)
FileUtils.mkdir_p(KairosMcp.context_dir)

File.write(File.join(KairosMcp.skills_dir, 'kairos.rb'), "# stub\n")
File.write(File.join(KairosMcp.skills_dir, 'config.yml'),
          "storage:\n  backend: file\nskills:\n  state_commit:\n    enabled: false\n")

puts "informed_by promotion test"
puts "Temp dir: #{test_dir}"
puts ""

# ---------- helpers ----------

def write_l2_context(session_id, name, body: 'L2 body', extra_frontmatter: {})
  ctx_dir = File.join(KairosMcp.context_dir, session_id, name)
  FileUtils.mkdir_p(ctx_dir)
  fm = { 'title' => name, 'description' => "L2 context #{name}" }.merge(extra_frontmatter)
  content = "---\n#{fm.to_yaml.sub(/^---\n/, '')}---\n\n# #{name}\n\n#{body}\n"
  File.write(File.join(ctx_dir, "#{name}.md"), content)
end

def promote(session_id, source_name, target_name = nil)
  tool = KairosMcp::Tools::SkillsPromote.new
  tool.call(
    'command' => 'promote',
    'source_name' => source_name,
    'target_name' => target_name,
    'from_layer' => 'L2',
    'to_layer' => 'L1',
    'session_id' => session_id,
    'reason' => 'test'
  )
end

def read_l1_frontmatter(name)
  path = File.join(KairosMcp.knowledge_dir, name, "#{name}.md")
  raise "L1 file not found: #{path}" unless File.exist?(path)
  raw = File.read(path)
  fm, = KairosMcp::AnthropicSkillParser.extract_frontmatter(raw)
  fm
end

# ---------- T1: SC #1 — identifiable ancestor records informed_by ----------
test_section('T1: identifiable L2 ancestor → relations.informed_by recorded') do
  write_l2_context('sess_t1', 'ctx_t1', body: 'content T1')
  promote('sess_t1', 'ctx_t1', 'l1_t1')
  fm = read_l1_frontmatter('l1_t1')

  rels = fm['relations']
  assert('relations is an Array') { rels.is_a?(Array) }
  edge = rels&.find { |e| e['type'] == 'informed_by' }
  assert('informed_by edge present') { !edge.nil? }
  assert('target uses v1:<session>/<name>') do
    edge && edge['target'] == 'v1:sess_t1/ctx_t1'
  end
end

# ---------- T2: SC #3 — existing L1 (absent field) still valid ----------
test_section('T2: pre-existing L1 without relations field loads valid') do
  # Simulate an L1 created without our changes
  l1_dir = File.join(KairosMcp.knowledge_dir, 'legacy_l1')
  FileUtils.mkdir_p(l1_dir)
  fm = { 'name' => 'legacy_l1', 'description' => 'no relations field' }
  legacy_content = "---\n#{fm.to_yaml.sub(/^---\n/, '')}---\n\n# Legacy\n\nbody\n"
  File.write(File.join(l1_dir, 'legacy_l1.md'), legacy_content)

  loaded_fm = read_l1_frontmatter('legacy_l1')
  assert('legacy L1 loads') { !loaded_fm.nil? }
  assert('relations field absent') { !loaded_fm.key?('relations') }
  # Inv 1: absence is valid — no exception, no warning required
end

# ---------- T3: Inv 2 — unknown edge types preserved verbatim ----------
test_section('T3: unknown edge types preserved through promotion') do
  unknown_edge = { 'type' => 'future_kind', 'target' => 'something_external' }
  write_l2_context('sess_t3', 'ctx_t3',
                   body: 'content T3',
                   extra_frontmatter: { 'relations' => [unknown_edge] })
  promote('sess_t3', 'ctx_t3', 'l1_t3')
  fm = read_l1_frontmatter('l1_t3')

  rels = fm['relations']
  assert('relations is Array') { rels.is_a?(Array) }
  assert('unknown edge survived') do
    rels&.any? { |e| e['type'] == 'future_kind' && e['target'] == 'something_external' }
  end
  assert('informed_by edge also added') do
    rels&.any? { |e| e['type'] == 'informed_by' && e['target'] == 'v1:sess_t3/ctx_t3' }
  end
end

# ---------- T4: idempotency — re-promotion does not duplicate ----------
test_section('T4: re-promotion is idempotent on informed_by edge') do
  write_l2_context('sess_t4', 'ctx_t4', body: 'content T4')
  promote('sess_t4', 'ctx_t4', 'l1_t4')
  # Promote a second time (update path)
  promote('sess_t4', 'ctx_t4', 'l1_t4')
  fm = read_l1_frontmatter('l1_t4')

  matching = (fm['relations'] || []).count do |e|
    e['type'] == 'informed_by' && e['target'] == 'v1:sess_t4/ctx_t4'
  end
  assert('informed_by edge appears exactly once') { matching == 1 }
end

# ---------- T5: Inv 3 — missing session_id → no edge written (field absent) ----------
test_section('T5: ancestor identify 不能 (session_id missing in injector) → field absent') do
  tool = KairosMcp::Tools::SkillsPromote.new
  # Call injector helper directly through send (private method) to verify Inv 3 fallback
  ref_missing_session = tool.send(:build_l2_ancestor_ref, nil, 'something')
  ref_missing_name = tool.send(:build_l2_ancestor_ref, 'sess_x', '')
  ref_ok = tool.send(:build_l2_ancestor_ref, 'sess_x', 'name')

  assert('nil session → nil ref (no auto-attach)') { ref_missing_session.nil? }
  assert('empty name → nil ref (no auto-attach)') { ref_missing_name.nil? }
  assert('both present → v1: ref') { ref_ok == 'v1:sess_x/name' }
end

# ---------- T6: SC #4 — manual relations.informed_by preserved ----------
test_section('T6: manually-authored informed_by entries preserved') do
  manual_edge = { 'type' => 'informed_by', 'target' => 'ref:external_paper_2026' }
  write_l2_context('sess_t6', 'ctx_t6',
                   body: 'content T6',
                   extra_frontmatter: { 'relations' => [manual_edge] })
  promote('sess_t6', 'ctx_t6', 'l1_t6')
  fm = read_l1_frontmatter('l1_t6')

  rels = fm['relations'] || []
  assert('manual external ref preserved') do
    rels.any? { |e| e['type'] == 'informed_by' && e['target'] == 'ref:external_paper_2026' }
  end
  assert('auto informed_by added alongside') do
    rels.any? { |e| e['type'] == 'informed_by' && e['target'] == 'v1:sess_t6/ctx_t6' }
  end
  assert('two informed_by edges total') do
    rels.count { |e| e['type'] == 'informed_by' } == 2
  end
end

# ---------- Summary ----------
puts ''
puts '=' * 60
puts "Results: #{$pass_count} passed, #{$fail_count} failed"
unless $errors.empty?
  puts 'Failures:'
  $errors.each { |e| puts "  - #{e}" }
end
puts '=' * 60

FileUtils.remove_entry(test_dir) if File.exist?(test_dir)

exit($fail_count.zero? ? 0 : 1)
