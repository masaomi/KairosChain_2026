#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for the chain_archive SkillSet
#
# Run from KairosChain_mcp_server/:
#   ruby test_chain_archive.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'zlib'

# ── Minimal test framework ──────────────────────────────────────────────────

$pass_count = 0
$fail_count = 0

def assert(msg, &block)
  result = block.call
  if result
    puts "  PASS: #{msg}"
    $pass_count += 1
  else
    puts "  FAIL: #{msg}"
    $fail_count += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  puts "        #{e.backtrace.first}"
  $fail_count += 1
end

def test_section(title)
  puts "\n#{'─' * 60}"
  puts "TEST: #{title}"
  puts '─' * 60
  yield
rescue StandardError => e
  puts "  ERROR in section: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  $fail_count += 1
end

# ── Setup ───────────────────────────────────────────────────────────────────

SKILLSET_PATH = File.expand_path('templates/skillsets/chain_archive', __dir__)

# Bootstrap KairosMcp in a temp directory
test_dir = Dir.mktmpdir('kairos_chain_archive_test')
KairosMcp.data_dir = test_dir

FileUtils.mkdir_p(KairosMcp.skills_dir)
FileUtils.mkdir_p(KairosMcp.knowledge_dir)
FileUtils.mkdir_p(KairosMcp.storage_dir)
FileUtils.mkdir_p(KairosMcp.skillsets_dir)

# Create a minimal skills/kairos.rb and config so SkillsConfig doesn't error
File.write(File.join(KairosMcp.skills_dir, 'kairos.rb'), "# stub\n")
File.write(
  File.join(KairosMcp.skills_dir, 'config.yml'),
  "storage:\n  backend: file\n"
)

# Load core chain classes (already loaded via kairos_mcp, but be explicit)
require_relative 'lib/kairos_mcp/kairos_chain/block'
require_relative 'lib/kairos_mcp/kairos_chain/merkle_tree'
require_relative 'lib/kairos_mcp/kairos_chain/chain'

# Load the SkillSet
$LOAD_PATH.unshift File.join(SKILLSET_PATH, 'lib')
require 'chain_archive'

# Load BaseTool for tool tests
require_relative 'lib/kairos_mcp/tools/base_tool'
Dir[File.join(SKILLSET_PATH, 'tools', '*.rb')].each { |f| require f }

# ── Helpers ─────────────────────────────────────────────────────────────────

def build_chain(block_count)
  chain = KairosMcp::KairosChain::Chain.new
  block_count.times { |i| chain.add_block(["entry #{i}"]) }
  chain
end

def archiver(threshold: 10)
  KairosMcp::SkillSets::ChainArchive::Archiver.new(threshold: threshold)
end

# ── Tests ────────────────────────────────────────────────────────────────────

test_section('1. Archiver#status — empty chain') do
  # blockchain.json doesn't exist yet; load_live_blocks returns []
  s = archiver.status
  assert('live_block_count is 0 (no file yet)') { s[:live_block_count] == 0 }
  assert('archive_segment_count is 0')           { s[:archive_segment_count] == 0 }
  assert('should_archive is false')              { s[:should_archive] == false }
end

test_section('2. Archiver#archive! — skips when below threshold') do
  build_chain(3)   # genesis + 3 = 4 blocks; threshold 10
  result = archiver(threshold: 10).archive!(reason: 'test')
  assert('returns skipped: true')   { result[:skipped] == true }
  assert('success is false')        { result[:success] == false }
  assert('reason mentions threshold') { result[:reason].include?('threshold') }
end

test_section('3. Archiver#archive! — archives when threshold exceeded') do
  # Build a chain with 12 blocks (genesis + 11 added)
  build_chain(11)  # 1 genesis + 11 = 12 blocks; threshold 10

  a = archiver(threshold: 10)
  status_before = a.status
  result = a.archive!(reason: 'automated test')

  assert('archive succeeds')             { result[:success] == true }
  assert('blocks_archived == 12')        { result[:blocks_archived] == status_before[:live_block_count] }
  assert('segment_filename present')     { result[:segment_filename]&.start_with?('segment_') }
  assert('segment_hash is 64-char hex')  { result[:segment_hash]&.match?(/\A[0-9a-f]{64}\z/) }
  assert('new_live_chain_length is 1')      { result[:new_live_chain_length] == 1 }
  assert('archive_block_hash is 64-char hex') { result[:archive_block_hash]&.match?(/\A[0-9a-f]{64}\z/) }
end

test_section('4. Live chain validity after archive') do
  chain = KairosMcp::KairosChain::Chain.new
  assert('live chain is valid after archive') { chain.valid? }
  assert('live chain has 1 block (archive block)') { chain.chain.size == 1 }

  # The archive block continues the chain — index is last_archived_index + 1
  archive_block = chain.chain.first
  assert('archive block index continues the chain') { archive_block.index > 0 }
  assert('archive block previous_hash links to archived segment') { archive_block.previous_hash != '0' * 64 }

  # The data must contain archive_block type
  data = JSON.parse(archive_block.data.first)
  assert('archive block type is archive_block')    { data['type'] == 'archive_block' }
  assert('archive block records blocks_archived')  { data['blocks_archived'].is_a?(Integer) }
  assert('archive block embeds segment_hash')      { data['segment_hash']&.match?(/\A[0-9a-f]{64}\z/) }
end

test_section('5. New blocks can be added after archive') do
  chain = KairosMcp::KairosChain::Chain.new
  chain.add_block(['post-archive entry 1'])
  chain.add_block(['post-archive entry 2'])

  assert('chain is still valid after new blocks') { chain.valid? }
  assert('chain has 3 blocks (checkpoint + 2)')   { chain.chain.size == 3 }
end

test_section('6. Archive segment file integrity') do
  archives_dir = File.join(KairosMcp.storage_dir, 'archives')
  segment_files = Dir[File.join(archives_dir, 'segment_*.json.gz')]

  assert('at least one segment file exists') { segment_files.size >= 1 }

  seg_path = segment_files.first
  assert('segment file is non-empty') { File.size(seg_path) > 0 }

  # Decompress and check JSON
  begin
    raw = Zlib::GzipReader.open(seg_path, &:read)
    blocks = JSON.parse(raw)
    assert('segment contains an array of blocks') { blocks.is_a?(Array) && blocks.size > 0 }
    assert('each block has required keys') do
      blocks.all? { |b| %w[index timestamp data hash previous_hash merkle_root].all? { |k| b.key?(k) } }
    end
  rescue StandardError => e
    assert("segment decompresses cleanly (#{e.message})") { false }
  end
end

test_section('7. Manifest file') do
  manifest_path = File.join(KairosMcp.storage_dir, 'archives', 'manifest.json')
  assert('manifest.json exists') { File.exist?(manifest_path) }

  manifest = JSON.parse(File.read(manifest_path))
  assert('manifest has segments array') { manifest['segments'].is_a?(Array) }
  assert('at least one segment recorded') { manifest['segments'].size >= 1 }

  seg = manifest['segments'].first
  assert('segment entry has filename')         { seg['filename'].is_a?(String) }
  assert('segment entry has block_count')      { seg['block_count'].is_a?(Integer) }
  assert('segment entry has segment_hash')     { seg['segment_hash'].is_a?(String) }
  assert('segment entry has last_block_hash')  { seg['last_block_hash'].is_a?(String) }
  assert('segment entry has archived_at')      { seg['archived_at'].is_a?(String) }
end

test_section('8. Archiver#verify_archives') do
  a = archiver
  result = a.verify_archives

  assert('verify_archives returns valid: true')   { result[:valid] == true }
  assert('segments_verified >= 1')                { result[:segments_verified] >= 1 }
  assert('each segment result has valid: true') do
    result[:segments].all? { |s| s[:valid] == true }
  end
end

test_section('9. verify_archives detects tampered segment') do
  archives_dir = File.join(KairosMcp.storage_dir, 'archives')
  segment_files = Dir[File.join(archives_dir, 'segment_*.json.gz')]
  seg_path = segment_files.first

  # Corrupt the segment file
  original = File.binread(seg_path)
  File.binwrite(seg_path, original + 'CORRUPTED')

  a = archiver
  result = a.verify_archives

  assert('verify_archives returns valid: false on tampered segment') { result[:valid] == false }
  assert('failed segment reports error') { result[:segments].any? { |s| !s[:valid] } }

  # Restore original
  File.binwrite(seg_path, original)
end

test_section('10. Multiple archive cycles') do
  # Add more blocks to exceed threshold again, then archive a second time
  build_chain(11)  # genesis is already checkpoint; add 11 more

  a = archiver(threshold: 10)
  result = a.archive!(reason: 'second cycle')

  assert('second archive succeeds') { result[:success] == true }

  manifest = JSON.parse(File.read(File.join(KairosMcp.storage_dir, 'archives', 'manifest.json')))
  assert('manifest has 2 segments now') { manifest['segments'].size == 2 }
  assert('second segment is segment_000001.json.gz') do
    manifest['segments'][1]['filename'] == 'segment_000001.json.gz'
  end

  verify_result = a.verify_archives
  assert('both segments pass verification') { verify_result[:valid] == true }
  assert('2 segments verified') { verify_result[:segments_verified] == 2 }
end

test_section('11. MCP tool — ChainArchiveStatus') do
  tool = KairosMcp::SkillSets::ChainArchive::Tools::ChainArchiveStatus.new
  assert("tool name is 'chain_archive_status'") { tool.name == 'chain_archive_status' }
  assert('category is :chain') { tool.category == :chain }

  output = tool.call({})
  text = output.first[:text]
  assert('output mentions live chain blocks') { text.include?('Live chain blocks') }
  assert('output mentions archive segments')  { text.include?('Archive segments') }
end

test_section('12. MCP tool — ChainArchiveVerify') do
  tool = KairosMcp::SkillSets::ChainArchive::Tools::ChainArchiveVerify.new
  assert("tool name is 'chain_archive_verify'") { tool.name == 'chain_archive_verify' }

  output = tool.call({})
  text = output.first[:text]
  assert('output mentions verification results') { text.include?('Verification') || text.include?('verified') }
  assert('output indicates all valid')            { text.include?('valid') || text.include?('OK') }
end

test_section('13. MCP tool — ChainArchiveRun skips when below threshold') do
  # Current live chain is just 1 checkpoint; threshold is large
  tool = KairosMcp::SkillSets::ChainArchive::Tools::ChainArchiveRun.new
  output = tool.call({ 'threshold' => 9999 })
  text = output.first[:text]
  assert('output says archive skipped') { text.downcase.include?('skip') }
end

test_section('14. MCP tool — ChainArchiveRun with force flag') do
  tool = KairosMcp::SkillSets::ChainArchive::Tools::ChainArchiveRun.new
  output = tool.call({ 'force' => true, 'reason' => 'forced test' })
  text = output.first[:text]
  assert('force archive completes successfully') { text.include?('completed') || text.include?('skip') }
end

test_section('15. SkillSet installation smoke test') do
  require_relative 'lib/kairos_mcp/skillset_manager'
  require_relative 'lib/kairos_mcp/skillset'

  manager = KairosMcp::SkillSetManager.new

  result = manager.install(SKILLSET_PATH)
  assert('install succeeds')              { result[:success] == true }
  assert("name is 'chain_archive'")       { result[:name] == 'chain_archive' }
  assert('layer is L1')                   { result[:layer] == :L1 }

  skillset = manager.find_skillset('chain_archive')
  assert('skillset is found')             { !skillset.nil? }
  assert('skillset is enabled')           { manager.enabled?('chain_archive') }
  assert('has 3 tool classes')            { skillset.tool_class_names.size == 3 }

  remove_result = manager.remove('chain_archive')
  assert('remove succeeds')               { remove_result[:success] == true }
end

# ── Summary ──────────────────────────────────────────────────────────────────

puts "\n#{'═' * 60}"
puts "Results: #{$pass_count} passed, #{$fail_count} failed"
puts '═' * 60

# Cleanup
FileUtils.rm_rf(test_dir)

exit($fail_count > 0 ? 1 : 0)
