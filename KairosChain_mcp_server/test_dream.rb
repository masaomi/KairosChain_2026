#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: Dream SkillSet — Scanner, Archiver, Proposer, Tools
# Tests: 27 sections, ~60 assertions

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'zlib'
require 'digest'
require 'set'

# Load core classes needed by Scanner (ContextManager) and Tools (BaseTool)
require 'kairos_mcp/anthropic_skill_parser'
require 'kairos_mcp/context_manager'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/tools/base_tool'

# Load Dream SkillSet classes
require_relative 'templates/skillsets/dream/lib/dream/scanner'
require_relative 'templates/skillsets/dream/lib/dream/archiver'
require_relative 'templates/skillsets/dream/lib/dream/proposer'
require_relative 'templates/skillsets/dream/tools/dream_scan'
require_relative 'templates/skillsets/dream/tools/dream_archive'
require_relative 'templates/skillsets/dream/tools/dream_recall'
require_relative 'templates/skillsets/dream/tools/dream_propose'

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
test_dir = Dir.mktmpdir('kairos_dream_test')
KairosMcp.data_dir = test_dir

FileUtils.mkdir_p(KairosMcp.skills_dir)
FileUtils.mkdir_p(KairosMcp.knowledge_dir)
FileUtils.mkdir_p(KairosMcp.storage_dir)
FileUtils.mkdir_p(KairosMcp.skillsets_dir)
FileUtils.mkdir_p(KairosMcp.context_dir)

# Stub config files
File.write(File.join(KairosMcp.skills_dir, 'kairos.rb'), "# stub\n")
File.write(File.join(KairosMcp.skills_dir, 'config.yml'), "storage:\n  backend: file\n")

puts "Dream SkillSet Test Suite"
puts "Ruby version: #{RUBY_VERSION}"
puts "Temp dir: #{test_dir}"
puts ""

# ===== Helpers =====

def create_test_context(session_id, name, tags: [], content: "Test content", status: nil)
  ctx_dir = File.join(KairosMcp.context_dir, session_id, name)
  FileUtils.mkdir_p(ctx_dir)
  frontmatter = { 'title' => name, 'tags' => tags, 'description' => "Test context #{name}" }
  frontmatter['status'] = status if status
  md_content = "---\n#{YAML.dump(frontmatter)}---\n\n# #{name}\n\n#{content}"
  File.write(File.join(ctx_dir, "#{name}.md"), md_content)
  ctx_dir
end

def make_old(path, days_ago)
  old_time = Time.now - (days_ago * 86400)
  FileUtils.touch(path, mtime: old_time)
end

# =========================================================================
# Scanner Tests
# =========================================================================

# Test 1: Scanner with empty context dir — returns empty scan_result
test_section('Test 1: Scanner with empty context dir') do
  scanner = KairosMcp::SkillSets::Dream::Scanner.new(config: {})
  result = scanner.scan(scope: 'l2')

  assert('returns a Hash') { result.is_a?(Hash) }
  assert('promotion_candidates is empty') { result[:promotion_candidates].empty? }
  assert('consolidation_candidates is empty') { result[:consolidation_candidates].empty? }
  assert('archive_candidates is empty') { result[:archive_candidates].empty? }
  assert('scope is l2') { result[:scope] == 'l2' }
  assert('scanned_at is present') { !result[:scanned_at].nil? }
end

# Test 2: Scanner detects tag co-occurrence across sessions
test_section('Test 2: Scanner detects tag co-occurrence across sessions') do
  # Create 4 sessions with overlapping tags — 'workflow' appears in all 4
  create_test_context('sess_a', 'ctx_alpha', tags: %w[workflow design])
  create_test_context('sess_b', 'ctx_beta', tags: %w[workflow testing])
  create_test_context('sess_c', 'ctx_gamma', tags: %w[workflow review])
  create_test_context('sess_d', 'ctx_delta', tags: %w[workflow deploy])

  scanner = KairosMcp::SkillSets::Dream::Scanner.new(config: { 'scan' => { 'min_recurrence' => 3 } })
  result = scanner.scan(scope: 'l2')

  promo = result[:promotion_candidates]
  assert('at least one promotion candidate') { promo.size >= 1 }
  workflow_candidate = promo.find { |c| c[:tag] == 'workflow' }
  assert('workflow tag detected') { !workflow_candidate.nil? }
  assert('workflow session_count >= 3') { workflow_candidate[:session_count] >= 3 }
  assert('signal is tag_recurrence') { workflow_candidate[:signal] == 'tag_recurrence' }
  assert('strength > 1.0') { workflow_candidate[:strength] > 1.0 }
end

# Test 3: Scanner detects L2 staleness (old mtime)
test_section('Test 3: Scanner detects L2 staleness') do
  ctx_dir = create_test_context('sess_stale', 'old_context', tags: %w[legacy])
  md_path = File.join(ctx_dir, 'old_context.md')
  make_old(md_path, 120) # 120 days old — exceeds default 90-day threshold

  scanner = KairosMcp::SkillSets::Dream::Scanner.new(
    config: { 'archive' => { 'staleness_threshold_days' => 90 } }
  )
  result = scanner.scan(scope: 'l2')

  archive = result[:archive_candidates]
  stale = archive.find { |c| c[:name] == 'old_context' }
  assert('stale context detected') { !stale.nil? }
  assert('days_stale >= 120') { stale[:days_stale] >= 119 }
  assert('signal is l2_staleness') { stale[:signal] == 'l2_staleness' }
end

# Test 4: Scanner skips soft-archived contexts in promotion detection
test_section('Test 4: Scanner skips soft-archived in promotion') do
  create_test_context('sess_arch1', 'archived_ctx', tags: %w[unique_archived_tag], status: 'soft-archived')
  create_test_context('sess_arch2', 'archived_ctx2', tags: %w[unique_archived_tag], status: 'soft-archived')
  create_test_context('sess_arch3', 'archived_ctx3', tags: %w[unique_archived_tag], status: 'soft-archived')

  scanner = KairosMcp::SkillSets::Dream::Scanner.new(
    config: { 'scan' => { 'min_recurrence' => 3 } }
  )
  result = scanner.scan(scope: 'l2')

  promo = result[:promotion_candidates]
  archived_promo = promo.find { |c| c[:tag] == 'unique_archived_tag' }
  assert('soft-archived contexts not promoted') { archived_promo.nil? }
end

# Test 5: Scanner includes archived contexts in health_summary counts
test_section('Test 5: Scanner includes archived in health_summary') do
  scanner = KairosMcp::SkillSets::Dream::Scanner.new(config: {})
  result = scanner.scan(scope: 'l2')

  health = result[:health_summary]
  assert('total_l2 is present') { !health[:total_l2].nil? }
  assert('total_live is present') { !health[:total_live].nil? }
  assert('total_archived is present') { !health[:total_archived].nil? }
  assert('total_archived > 0 (from test 4)') { health[:total_archived] > 0 }
  assert('total_l2 = total_live + total_archived') { health[:total_l2] == health[:total_live] + health[:total_archived] }
end

# Test 6: Scanner detects L1 staleness (L1 not referenced in L2 tags)
test_section('Test 6: Scanner detects L1 staleness') do
  # Create an L1 knowledge entry that no L2 tag references
  orphan_name = 'orphan_knowledge_entry'
  orphan_dir = File.join(KairosMcp.knowledge_dir, orphan_name)
  FileUtils.mkdir_p(orphan_dir)
  File.write(File.join(orphan_dir, "#{orphan_name}.md"),
             "---\nname: #{orphan_name}\ndescription: Orphan\ntags: []\n---\n\n# Orphan\n")

  scanner = KairosMcp::SkillSets::Dream::Scanner.new(config: {})
  result = scanner.scan(scope: 'all')

  health = result[:health_summary]
  assert('total_l1 is present') { !health[:total_l1].nil? }
  assert('stale_l1 is present') { !health[:stale_l1].nil? }
  # The orphan L1 should be stale (not referenced by any L2 tag)
  assert('orphan L1 detected as stale') { health[:stale_l1].include?(orphan_name) }
end

# Test 7: Name token Jaccard similarity calculation
test_section('Test 7: Jaccard similarity') do
  scanner = KairosMcp::SkillSets::Dream::Scanner.new(config: {})

  # Access private method via send
  sim_identical = scanner.send(:jaccard_similarity, 'foo_bar_baz', 'foo_bar_baz')
  sim_partial   = scanner.send(:jaccard_similarity, 'foo_bar', 'bar_baz')
  sim_disjoint  = scanner.send(:jaccard_similarity, 'aaa_bbb', 'ccc_ddd')
  sim_subset    = scanner.send(:jaccard_similarity, 'foo_bar', 'foo_bar_baz')

  assert('identical names => 1.0') { sim_identical == 1.0 }
  assert('partial overlap => 0 < sim < 1') { sim_partial > 0 && sim_partial < 1 }
  assert('partial overlap Jaccard = 1/3') { (sim_partial - 1.0 / 3).abs < 0.001 }
  assert('disjoint names => 0.0') { sim_disjoint == 0.0 }
  assert('subset Jaccard = 2/3') { (sim_subset - 2.0 / 3).abs < 0.001 }
end

# =========================================================================
# Archiver Tests
# =========================================================================

# Test 8: Archive a context — creates stub + gzip in archive dir
test_section('Test 8: Archive creates stub + gzip') do
  create_test_context('sess_archive_test', 'archivable', tags: %w[test archive], content: 'Full content here.')

  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})
  result = archiver.archive_context!(
    session_id: 'sess_archive_test',
    context_name: 'archivable',
    summary: 'Test archive summary'
  )

  assert('archive result success') { result[:success] == true }
  assert('content_hash present') { !result[:content_hash].nil? && result[:content_hash].length == 64 }
  assert('verified is true') { result[:verified] == true }

  # Check gzip exists in storage
  gz_path = File.join(KairosMcp.storage_dir, 'dream/archive', 'sess_archive_test', 'archivable', 'archivable.md.gz')
  assert('gzip file created') { File.exist?(gz_path) }

  # Check stub was written
  stub_path = File.join(KairosMcp.context_dir, 'sess_archive_test', 'archivable', 'archivable.md')
  stub_content = File.read(stub_path)
  assert('stub contains soft-archived status') { stub_content.include?('soft-archived') }
end

# Test 9: Archive verifies SHA256 immediately after gzip
test_section('Test 9: SHA256 verification on archive') do
  create_test_context('sess_sha_test', 'sha_ctx', tags: %w[sha], content: 'SHA256 verification content.')

  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})
  result = archiver.archive_context!(
    session_id: 'sess_sha_test',
    context_name: 'sha_ctx',
    summary: 'SHA test'
  )

  assert('verified flag is true') { result[:verified] == true }

  # Manually verify: decompress gzip and check hash matches
  gz_path = File.join(KairosMcp.storage_dir, 'dream/archive', 'sess_sha_test', 'sha_ctx', 'sha_ctx.md.gz')
  decompressed = Zlib::GzipReader.open(gz_path, &:read)
  actual_hash = Digest::SHA256.hexdigest(decompressed)
  assert('SHA256 of gzip content matches result') { actual_hash == result[:content_hash] }
end

# Test 10: Archive moves subdirectories to archive
test_section('Test 10: Archive moves subdirectories') do
  ctx_dir = create_test_context('sess_subdir_test', 'subdir_ctx', tags: %w[scripts], content: 'Has subdirs.')

  # Create subdirectories with files
  scripts_dir = File.join(ctx_dir, 'scripts')
  assets_dir  = File.join(ctx_dir, 'assets')
  FileUtils.mkdir_p(scripts_dir)
  FileUtils.mkdir_p(assets_dir)
  File.write(File.join(scripts_dir, 'run.sh'), '#!/bin/bash\necho hello')
  File.write(File.join(assets_dir, 'data.csv'), 'col1,col2')

  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})
  result = archiver.archive_context!(
    session_id: 'sess_subdir_test',
    context_name: 'subdir_ctx',
    summary: 'Subdir test'
  )

  assert('moved_subdirs includes scripts') { result[:moved_subdirs].include?('scripts') }
  assert('moved_subdirs includes assets') { result[:moved_subdirs].include?('assets') }

  # Original dirs should be gone
  assert('scripts dir removed from source') { !File.directory?(scripts_dir) }
  assert('assets dir removed from source') { !File.directory?(assets_dir) }

  # Archive should have them
  arch_scripts = File.join(KairosMcp.storage_dir, 'dream/archive', 'sess_subdir_test', 'subdir_ctx', 'scripts')
  assert('scripts dir in archive') { File.directory?(arch_scripts) }
end

# Test 11: Stub contains correct metadata
test_section('Test 11: Stub metadata') do
  stub_path = File.join(KairosMcp.context_dir, 'sess_archive_test', 'archivable', 'archivable.md')
  stub_content = File.read(stub_path)

  # Parse frontmatter
  if stub_content =~ /\A---\n(.*?)\n---/m
    meta = YAML.safe_load($1)
  end

  assert('stub has tags') { meta['tags'].is_a?(Array) }
  assert('stub has content_hash') { meta['content_hash'].is_a?(String) && meta['content_hash'].length == 64 }
  assert('stub has archive_ref') { meta['archive_ref'].is_a?(String) }
  assert('stub has status soft-archived') { meta['status'] == 'soft-archived' }
  assert('stub has archived_at') { !meta['archived_at'].nil? }
  assert('stub has summary') { meta['summary'] == 'Test archive summary' }
end

# Test 12: archived? returns true for archived context
test_section('Test 12: archived? returns true') do
  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})
  is_archived = archiver.archived?(session_id: 'sess_archive_test', context_name: 'archivable')
  assert('archived? returns true for archived context') { is_archived == true }

  # Non-archived context
  create_test_context('sess_live', 'live_ctx', tags: %w[live])
  is_live = archiver.archived?(session_id: 'sess_live', context_name: 'live_ctx')
  assert('archived? returns false for live context') { is_live == false }
end

# Test 13: Cannot archive already-archived context
test_section('Test 13: Cannot archive already-archived') do
  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})
  error_raised = false
  begin
    archiver.archive_context!(
      session_id: 'sess_archive_test',
      context_name: 'archivable',
      summary: 'Should fail'
    )
  rescue RuntimeError => e
    error_raised = e.message.include?('Already archived')
  end
  assert('raises error for already-archived context') { error_raised }
end

# Test 14: Recall restores original content + subdirs
test_section('Test 14: Recall restores content') do
  # Archive a fresh context with known content
  original_content_body = "This is the original content for recall test."
  create_test_context('sess_recall_test', 'recall_ctx', tags: %w[recall], content: original_content_body)

  # Add a subdirectory
  ctx_dir = File.join(KairosMcp.context_dir, 'sess_recall_test', 'recall_ctx')
  refs_dir = File.join(ctx_dir, 'references')
  FileUtils.mkdir_p(refs_dir)
  File.write(File.join(refs_dir, 'ref.bib'), '@article{test}')

  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: { 'archive' => { 'preserve_gzip' => true } })
  archiver.archive_context!(
    session_id: 'sess_recall_test',
    context_name: 'recall_ctx',
    summary: 'Recall test'
  )

  # Verify it is archived
  assert('context is archived before recall') { archiver.archived?(session_id: 'sess_recall_test', context_name: 'recall_ctx') }

  # Recall
  recall_result = archiver.recall_context!(
    session_id: 'sess_recall_test',
    context_name: 'recall_ctx'
  )

  assert('recall success') { recall_result[:success] == true }
  assert('recall verified') { recall_result[:verified] == true }

  # Check content is restored
  restored_path = File.join(ctx_dir, 'recall_ctx.md')
  restored_content = File.read(restored_path)
  assert('original content restored') { restored_content.include?(original_content_body) }
  assert('status is no longer soft-archived') { !restored_content.include?('status: soft-archived') }

  # Check references dir restored
  assert('references dir restored') { recall_result[:moved_back].include?('references') }
  assert('ref.bib file exists') { File.exist?(File.join(ctx_dir, 'references', 'ref.bib')) }
end

# Test 15: Recall verifies SHA256 before restore
test_section('Test 15: Recall SHA256 verification') do
  create_test_context('sess_recall_sha', 'recall_sha_ctx', tags: %w[sha], content: 'SHA recall test.')

  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: { 'archive' => { 'preserve_gzip' => true } })
  archive_result = archiver.archive_context!(
    session_id: 'sess_recall_sha',
    context_name: 'recall_sha_ctx',
    summary: 'SHA recall'
  )

  # Corrupt the gzip to test SHA verification failure
  gz_path = File.join(KairosMcp.storage_dir, 'dream/archive', 'sess_recall_sha', 'recall_sha_ctx', 'recall_sha_ctx.md.gz')
  # Write valid gzip but with different content
  Zlib::GzipWriter.open(gz_path) { |gz| gz.write("CORRUPTED CONTENT") }

  error_raised = false
  begin
    archiver.recall_context!(session_id: 'sess_recall_sha', context_name: 'recall_sha_ctx')
  rescue RuntimeError => e
    error_raised = e.message.include?('integrity check failed')
  end
  assert('recall rejects corrupted archive') { error_raised }
end

# Test 16: Preview shows content without modifying files
test_section('Test 16: Preview mode') do
  create_test_context('sess_preview', 'preview_ctx', tags: %w[preview], content: 'Preview content body.')

  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})
  archiver.archive_context!(
    session_id: 'sess_preview',
    context_name: 'preview_ctx',
    summary: 'Preview test'
  )

  # Save stub content before preview
  stub_path = File.join(KairosMcp.context_dir, 'sess_preview', 'preview_ctx', 'preview_ctx.md')
  stub_before = File.read(stub_path)

  preview_result = archiver.preview(session_id: 'sess_preview', context_name: 'preview_ctx')

  assert('preview success') { preview_result[:success] == true }
  assert('preview includes original content') { preview_result[:content].include?('Preview content body.') }
  assert('preview has content_hash') { preview_result[:content_hash].is_a?(String) }

  # Stub should be unchanged
  stub_after = File.read(stub_path)
  assert('stub unchanged after preview') { stub_before == stub_after }
end

# Test 17: verify checks integrity without restoring
test_section('Test 17: Verify integrity') do
  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})
  verify_result = archiver.verify(session_id: 'sess_preview', context_name: 'preview_ctx')

  assert('verify success for intact archive') { verify_result[:success] == true }
  assert('no issues') { verify_result[:issues].empty? }
  assert('gzip_exists is true') { verify_result[:gzip_exists] == true }
  assert('archive_dir_exists is true') { verify_result[:archive_dir_exists] == true }
end

# Test 18: dry_run mode (preview only, no modification)
test_section('Test 18: Archiver dry_run concept') do
  # The dry_run is handled at the tool level (DreamArchive), not Archiver itself.
  # We test that archived? correctly distinguishes states for dry_run logic.
  create_test_context('sess_dryrun', 'dryrun_ctx', tags: %w[dryrun], content: 'Dry run content.')

  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})

  # Before archiving, archived? should be false
  assert('not archived before dry_run') { archiver.archived?(session_id: 'sess_dryrun', context_name: 'dryrun_ctx') == false }

  # verify on non-archived context should report issues
  verify_result = archiver.verify(session_id: 'sess_dryrun', context_name: 'dryrun_ctx')
  assert('verify reports issues for non-archived') { !verify_result[:success] }
end

# =========================================================================
# Proposer Tests
# =========================================================================

# Test 19: Propose with content generates ready command
test_section('Test 19: Propose with content') do
  proposer = KairosMcp::SkillSets::Dream::Proposer.new(config: {})
  candidates = [
    { target_name: 'new_skill', source_sessions: %w[s1 s2], source_contexts: %w[ctx1 ctx2], reason: 'Pattern detected' }
  ]

  proposals = proposer.propose(candidates: candidates, content: 'Synthesized L1 content here.')

  assert('one proposal returned') { proposals.size == 1 }
  p = proposals.first
  assert('status is ready') { p[:status] == 'ready' }
  assert('command tool is knowledge_update') { p[:command][:tool] == 'knowledge_update' }
  assert('command has content') { p[:command][:arguments][:content] == 'Synthesized L1 content here.' }
  assert('target_name matches') { p[:target_name] == 'new_skill' }
end

# Test 20: Propose without content generates synthesis prompt
test_section('Test 20: Propose without content') do
  proposer = KairosMcp::SkillSets::Dream::Proposer.new(config: {})
  candidates = [
    { target_name: 'prompt_skill', source_contexts: %w[ctx_a ctx_b], reason: 'Needs synthesis' }
  ]

  proposals = proposer.propose(candidates: candidates)

  p = proposals.first
  assert('status is needs_content') { p[:status] == 'needs_content' }
  assert('synthesis_prompt present') { !p[:synthesis_prompt].nil? }
  assert('synthesis_prompt mentions source contexts') { p[:synthesis_prompt].include?('ctx_a') }
  assert('command_template present') { !p[:command_template].nil? }
  assert('command_template has placeholder') { p[:command_template][:arguments][:content] == '<<LLM_GENERATED_CONTENT>>' }
end

# Test 21: Propose with assembly generates assembly template
test_section('Test 21: Propose with assembly') do
  proposer = KairosMcp::SkillSets::Dream::Proposer.new(config: {})
  candidates = [
    { target_name: 'assembly_skill', reason: 'Assembly test' }
  ]

  proposals = proposer.propose(candidates: candidates, content: 'Content.', assembly: true, personas: %w[kairos critic])

  p = proposals.first
  assert('assembly_template present') { !p[:assembly_template].nil? }
  assert('assembly tool is skills_promote') { p[:assembly_template][:tool] == 'skills_promote' }
  assert('personas passed through') { p[:assembly_template][:arguments][:personas] == %w[kairos critic] }
  assert('from_layer is L2') { p[:assembly_template][:arguments][:from_layer] == 'L2' }
  assert('to_layer is L1') { p[:assembly_template][:arguments][:to_layer] == 'L1' }
  assert('source_name matches target') { p[:assembly_template][:arguments][:source_name] == 'assembly_skill' }
end

# =========================================================================
# Tool Tests
# =========================================================================

# Test 22: DreamScan tool metadata
test_section('Test 22: DreamScan tool metadata') do
  tool = KairosMcp::SkillSets::Dream::Tools::DreamScan.new

  assert('name is dream_scan') { tool.name == 'dream_scan' }
  assert('category is :knowledge') { tool.category == :knowledge }
  assert('input_schema has scope property') { tool.input_schema[:properties].key?(:scope) }
  assert('input_schema has since_session') { tool.input_schema[:properties].key?(:since_session) }
  assert('input_schema has include_archive_candidates') { tool.input_schema[:properties].key?(:include_archive_candidates) }
  assert('usecase_tags includes dream') { tool.usecase_tags.include?('dream') }
end

# Test 23: DreamArchive tool metadata
test_section('Test 23: DreamArchive tool metadata') do
  tool = KairosMcp::SkillSets::Dream::Tools::DreamArchive.new

  assert('name is dream_archive') { tool.name == 'dream_archive' }
  assert('category is :knowledge') { tool.category == :knowledge }
  assert('input_schema has targets') { tool.input_schema[:properties].key?(:targets) }
  assert('input_schema has dry_run') { tool.input_schema[:properties].key?(:dry_run) }
  assert('required includes targets and summary') { tool.input_schema[:required] == %w[targets summary] }
end

# Test 24: DreamRecall tool metadata
test_section('Test 24: DreamRecall tool metadata') do
  tool = KairosMcp::SkillSets::Dream::Tools::DreamRecall.new

  assert('name is dream_recall') { tool.name == 'dream_recall' }
  assert('category is :knowledge') { tool.category == :knowledge }
  assert('input_schema has session_id') { tool.input_schema[:properties].key?(:session_id) }
  assert('input_schema has context_name') { tool.input_schema[:properties].key?(:context_name) }
  assert('input_schema has preview') { tool.input_schema[:properties].key?(:preview) }
  assert('input_schema has verify_only') { tool.input_schema[:properties].key?(:verify_only) }
end

# Test 25: DreamPropose tool metadata
test_section('Test 25: DreamPropose tool metadata') do
  tool = KairosMcp::SkillSets::Dream::Tools::DreamPropose.new

  assert('name is dream_propose') { tool.name == 'dream_propose' }
  assert('category is :knowledge') { tool.category == :knowledge }
  assert('input_schema has candidates') { tool.input_schema[:properties].key?(:candidates) }
  assert('input_schema has content') { tool.input_schema[:properties].key?(:content) }
  assert('input_schema has assembly') { tool.input_schema[:properties].key?(:assembly) }
  assert('required includes candidates') { tool.input_schema[:required].include?('candidates') }
end

# =========================================================================
# Integration Tests
# =========================================================================

# Test 26: SkillSet installation — install/remove cycle
test_section('Test 26: SkillSet install/remove cycle') do
  require 'kairos_mcp/skillset_manager'

  template_path = File.expand_path('templates/skillsets/dream', __dir__)
  manager = KairosMcp::SkillSetManager.new

  # Install
  install_result = manager.install(template_path)
  assert('install succeeds') { install_result[:success] == true || install_result[:status] == 'installed' }

  installed_dir = File.join(KairosMcp.skillsets_dir, 'dream')
  assert('dream dir exists after install') { File.directory?(installed_dir) }

  skillset_json = File.join(installed_dir, 'skillset.json')
  assert('skillset.json exists') { File.exist?(skillset_json) }

  # Verify skillset.json content
  meta = JSON.parse(File.read(skillset_json))
  assert('skillset name is dream') { meta['name'] == 'dream' }
  assert('provides includes pattern_detection') { meta['provides'].include?('pattern_detection') }

  # Remove
  remove_result = manager.remove('dream')
  assert('remove succeeds') { remove_result[:success] == true || remove_result[:status] == 'removed' }
  assert('dream dir removed') { !File.directory?(installed_dir) }
end

# Test 27: Full workflow: scan → archive → recall
test_section('Test 27: Full workflow — scan → archive → recall') do
  # Create contexts for a fresh workflow test
  original_body = "Full workflow integration test content — unique marker 7x9q."
  create_test_context('sess_wf1', 'workflow_ctx', tags: %w[integration wf], content: original_body)

  # Make it stale
  md_path = File.join(KairosMcp.context_dir, 'sess_wf1', 'workflow_ctx', 'workflow_ctx.md')
  make_old(md_path, 100)

  # Step 1: Scan — should detect staleness
  scanner = KairosMcp::SkillSets::Dream::Scanner.new(
    config: { 'archive' => { 'staleness_threshold_days' => 90 } }
  )
  scan_result = scanner.scan(scope: 'l2')
  stale_found = scan_result[:archive_candidates].any? { |c| c[:name] == 'workflow_ctx' }
  assert('scan detects workflow_ctx as stale') { stale_found }

  # Step 2: Archive
  archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: {})
  archive_result = archiver.archive_context!(
    session_id: 'sess_wf1',
    context_name: 'workflow_ctx',
    summary: 'Integration test archive'
  )
  assert('archive success') { archive_result[:success] == true }
  assert('context is now archived') { archiver.archived?(session_id: 'sess_wf1', context_name: 'workflow_ctx') }

  # Step 3: Recall
  recall_result = archiver.recall_context!(
    session_id: 'sess_wf1',
    context_name: 'workflow_ctx'
  )
  assert('recall success') { recall_result[:success] == true }
  assert('recall verified') { recall_result[:verified] == true }

  # Verify original content is back
  restored = File.read(md_path)
  assert('original content restored after full workflow') { restored.include?('7x9q') }
end

# =========================================================================
# Cleanup & Summary
# =========================================================================

separator
puts ""
puts "Dream SkillSet Test Results"
puts "  PASS: #{$pass_count}"
puts "  FAIL: #{$fail_count}"
puts "  TOTAL: #{$pass_count + $fail_count}"
puts ""

if $errors.any?
  puts "Failed tests:"
  $errors.each { |e| puts "  - #{e}" }
  puts ""
end

# Cleanup temp directory
FileUtils.rm_rf(test_dir)
puts "Cleaned up: #{test_dir}"

exit($fail_count > 0 ? 1 : 0)
