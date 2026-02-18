#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick smoke test for SkillSet Plugin Infrastructure (Phase 1)

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'json'

PASS = 0
FAIL = 0

def assert(msg, &block)
  result = block.call
  if result
    puts "  PASS: #{msg}"
    $pass_count = ($pass_count || 0) + 1
  else
    puts "  FAIL: #{msg}"
    $fail_count = ($fail_count || 0) + 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail_count = ($fail_count || 0) + 1
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
  puts "  ERROR: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  $fail_count = ($fail_count || 0) + 1
end

# Setup: create a temp data directory
test_dir = Dir.mktmpdir('kairos_skillset_test')
KairosMcp.data_dir = test_dir

# Create initial data structure
FileUtils.mkdir_p(KairosMcp.skills_dir)
FileUtils.mkdir_p(KairosMcp.knowledge_dir)
FileUtils.mkdir_p(KairosMcp.storage_dir)
FileUtils.mkdir_p(KairosMcp.skillsets_dir)

# ===== Test 1: Path helpers =====
test_section('KairosMcp path helpers') do
  assert('skillsets_dir exists') { KairosMcp.skillsets_dir.include?('skillsets') }
  assert('skillsets_config_path exists') { KairosMcp.skillsets_config_path.include?('config.yml') }
end

# ===== Test 2: Skillset class =====
test_section('Skillset class') do
  ss_dir = File.join(KairosMcp.skillsets_dir, 'test-ss')
  FileUtils.mkdir_p(ss_dir)
  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate({
    name: 'test-ss',
    version: '0.1.0',
    description: 'A test SkillSet',
    author: 'Test Author',
    layer: 'L2',
    depends_on: [],
    provides: ['testing'],
    tool_classes: [],
    knowledge_dirs: []
  }))

  require 'kairos_mcp/skillset'
  ss = KairosMcp::Skillset.new(ss_dir)

  assert('name is correct') { ss.name == 'test-ss' }
  assert('version is correct') { ss.version == '0.1.0' }
  assert('layer is L2') { ss.layer == :L2 }
  assert('valid? is true') { ss.valid? }
  assert('content_hash is not empty') { !ss.content_hash.empty? }
  assert('to_h returns hash') { ss.to_h.is_a?(Hash) }

  # Test layer override
  ss.layer = :L0
  assert('layer override works') { ss.layer == :L0 }
end

# ===== Test 3: SkillSetManager discovery =====
test_section('SkillSetManager discovery') do
  require 'kairos_mcp/skillset_manager'
  manager = KairosMcp::SkillSetManager.new

  all = manager.all_skillsets
  assert('discovers SkillSets') { all.size >= 1 }
  assert('finds test-ss') { all.any? { |s| s.name == 'test-ss' } }
end

# ===== Test 4: Enable / Disable =====
test_section('SkillSetManager enable/disable') do
  manager = KairosMcp::SkillSetManager.new

  assert('default is enabled') { manager.enabled?('test-ss') }

  result = manager.disable('test-ss')
  assert('disable succeeds (L2)') { result[:success] }
  assert('is now disabled') { !manager.enabled?('test-ss') }

  result = manager.enable('test-ss')
  assert('enable succeeds') { result[:success] }
  assert('is now enabled') { manager.enabled?('test-ss') }
end

# ===== Test 5: L0 disable requires approval =====
test_section('L0 SkillSet requires approval') do
  l0_dir = File.join(KairosMcp.skillsets_dir, 'l0-test')
  FileUtils.mkdir_p(l0_dir)
  File.write(File.join(l0_dir, 'skillset.json'), JSON.pretty_generate({
    name: 'l0-test',
    version: '1.0.0',
    description: 'An L0 SkillSet',
    layer: 'L0',
    depends_on: [],
    provides: [],
    tool_classes: []
  }))

  manager = KairosMcp::SkillSetManager.new
  result = manager.disable('l0-test')
  assert('L0 disable returns requires_approval') { result[:requires_approval] == true }
  assert('L0 disable does not succeed') { result[:success] == false }
end

# ===== Test 6: Install from path =====
test_section('SkillSetManager install') do
  # Create a source SkillSet outside the skillsets dir
  src = File.join(test_dir, 'external-source')
  FileUtils.mkdir_p(src)
  File.write(File.join(src, 'skillset.json'), JSON.pretty_generate({
    name: 'installed-ss',
    version: '2.0.0',
    description: 'Installed from path',
    layer: 'L1',
    depends_on: [],
    provides: ['installed_feature'],
    tool_classes: []
  }))

  manager = KairosMcp::SkillSetManager.new
  result = manager.install(src)

  assert('install succeeds') { result[:success] }
  assert('install name is correct') { result[:name] == 'installed-ss' }
  assert('install layer is L1') { result[:layer] == :L1 }
  assert('install path exists') { File.directory?(result[:path]) }

  # Verify it appears in list
  manager2 = KairosMcp::SkillSetManager.new
  assert('installed appears in list') { manager2.all_skillsets.any? { |s| s.name == 'installed-ss' } }
end

# ===== Test 7: Install with layer override =====
test_section('Install with layer override') do
  src2 = File.join(test_dir, 'external-source2')
  FileUtils.mkdir_p(src2)
  File.write(File.join(src2, 'skillset.json'), JSON.pretty_generate({
    name: 'overridden-ss',
    version: '1.0.0',
    description: 'Layer will be overridden',
    layer: 'L1',
    depends_on: [],
    provides: [],
    tool_classes: []
  }))

  manager = KairosMcp::SkillSetManager.new
  result = manager.install(src2, layer_override: :L2)

  assert('install with override succeeds') { result[:success] }
  assert('layer is overridden to L2') { result[:layer] == :L2 }

  # Verify override persists
  manager2 = KairosMcp::SkillSetManager.new
  ss = manager2.find_skillset('overridden-ss')
  assert('persisted layer is L2') { ss.layer == :L2 }
end

# ===== Test 8: Remove =====
test_section('SkillSetManager remove') do
  manager = KairosMcp::SkillSetManager.new
  result = manager.remove('overridden-ss')
  assert('remove succeeds') { result[:success] }

  manager2 = KairosMcp::SkillSetManager.new
  assert('removed not in list') { manager2.find_skillset('overridden-ss').nil? }
end

# ===== Test 9: Dependency checking =====
test_section('Dependency checking') do
  dep_dir = File.join(KairosMcp.skillsets_dir, 'depends-on-test')
  FileUtils.mkdir_p(dep_dir)
  File.write(File.join(dep_dir, 'skillset.json'), JSON.pretty_generate({
    name: 'depends-on-test',
    version: '1.0.0',
    layer: 'L1',
    depends_on: ['test-ss'],
    provides: [],
    tool_classes: []
  }))

  manager = KairosMcp::SkillSetManager.new
  manager.enable('depends-on-test')

  # Should not be able to disable test-ss because depends-on-test depends on it
  begin
    manager.disable('test-ss')
    assert('dependency block works') { false }
  rescue ArgumentError => e
    assert('dependency block works') { e.message.include?('depends-on-test') }
  end
end

# ===== Test 10: LayerRegistry extension =====
test_section('LayerRegistry SkillSet layer support') do
  require 'kairos_mcp/layer_registry'

  assert('L0 maps to full blockchain') { KairosMcp::LayerRegistry.blockchain_mode(:L0) == :full }
  assert('L1 maps to hash_only blockchain') { KairosMcp::LayerRegistry.blockchain_mode(:L1) == :hash_only }
  assert('L2 maps to no blockchain') { KairosMcp::LayerRegistry.blockchain_mode(:L2) == :none }
  assert('L0 requires blockchain') { KairosMcp::LayerRegistry.requires_blockchain?(:L0) }
  assert('L2 does not require blockchain') { !KairosMcp::LayerRegistry.requires_blockchain?(:L2) }
end

# ===== Test 11: KnowledgeProvider external dirs =====
test_section('KnowledgeProvider external dir integration') do
  # Create a SkillSet with knowledge
  ss_know_dir = File.join(KairosMcp.skillsets_dir, 'test-ss', 'knowledge', 'test_knowledge')
  FileUtils.mkdir_p(ss_know_dir)
  File.write(File.join(ss_know_dir, 'test_knowledge.md'), <<~MD)
    ---
    name: test_knowledge
    description: Knowledge from a SkillSet
    version: 1.0
    tags: [test, skillset]
    ---

    # Test Knowledge

    This is test knowledge from a SkillSet.
  MD

  require 'kairos_mcp/knowledge_provider'
  provider = KairosMcp::KnowledgeProvider.new(KairosMcp.knowledge_dir, vector_search_enabled: false)

  # Before adding external dir
  before = provider.list.size

  # Add external dir
  provider.add_external_dir(
    File.join(KairosMcp.skillsets_dir, 'test-ss', 'knowledge'),
    source: 'skillset:test-ss',
    layer: :L2,
    index: false
  )

  after = provider.list.size
  assert('external knowledge appears in list') { after > before }

  ext_entry = provider.list.find { |k| k[:name] == 'test_knowledge' }
  assert('external entry has source field') { ext_entry && ext_entry[:source] == 'skillset:test-ss' }

  # Test get from external dir
  skill = provider.get('test_knowledge')
  assert('can get external knowledge') { !skill.nil? }
end

# Cleanup
FileUtils.rm_rf(test_dir)

# Summary
separator
puts ""
puts "Results: #{$pass_count || 0} passed, #{$fail_count || 0} failed"
puts ""
exit(($fail_count || 0) > 0 ? 1 : 0)
