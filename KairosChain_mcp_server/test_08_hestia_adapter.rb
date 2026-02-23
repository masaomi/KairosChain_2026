#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# Phase 4A: HestiaChain Adapter Test
# ============================================================================
# Tests for the Hestia SkillSet — HestiaChain foundation layer.
#
# Tests:
#   1. Hestia::Chain Core (Anchor, Config, Client, InMemory backend)
#   2. HestiaChainAdapter (MMP::ChainAdapter interface)
#   3. Chain Migration (in_memory → private)
#   4. Philosophy Protocol (PhilosophyDeclaration, ObservationLog)
#   5. SkillSet Discovery & Loading
#
# Usage:
#   ruby test_08_hestia_adapter.rb
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/mmp/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/hestia/lib', __dir__)

require 'kairos_mcp'
require 'mmp'
require 'hestia'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'

$pass_count = 0
$fail_count = 0
$section_pass = 0
$section_fail = 0

def assert(msg)
  result = yield
  if result
    puts "  PASS: #{msg}"
    $pass_count += 1
    $section_pass += 1
  else
    puts "  FAIL: #{msg}"
    $fail_count += 1
    $section_fail += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail_count += 1
  $section_fail += 1
end

def section(title)
  puts ''
  puts '=' * 60
  puts "SECTION: #{title}"
  puts '=' * 60
  $section_pass = 0
  $section_fail = 0
  yield
  puts "  -- #{$section_pass} passed, #{$section_fail} failed"
rescue StandardError => e
  puts "  SECTION ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  $fail_count += 1
end

puts ''
puts '=' * 60
puts 'Phase 4A: HestiaChain Adapter Test'
puts '=' * 60

# ============================================================================
# Section 1: Hestia::Chain Core
# ============================================================================
section('1. Hestia::Chain Core (Anchor, Config, Client)') do
  # Config
  config = Hestia::Chain::Core::Config.new
  assert('Config defaults to in_memory backend') { config.backend == 'in_memory' }
  assert('Config defaults to enabled') { config.enabled? }
  assert('Config batching disabled by default') { !config.batching_enabled? }

  # Config with custom values
  custom = Hestia::Chain::Core::Config.new('backend' => 'private', 'enabled' => false)
  assert('Custom config respects backend') { custom.backend == 'private' }
  assert('Custom config respects enabled') { !custom.enabled? }

  # Anchor
  test_hash = Digest::SHA256.hexdigest('test data')
  anchor = Hestia::Chain::Core::Anchor.new(
    anchor_type: 'meeting',
    source_id: 'test_001',
    data_hash: test_hash,
    participants: ['agent_a', 'agent_b'],
    metadata: { test: true }
  )
  assert('Anchor has correct type') { anchor.anchor_type == 'meeting' }
  assert('Anchor has source_id') { anchor.source_id == 'test_001' }
  assert('Anchor has deterministic hash') { anchor.anchor_hash.is_a?(String) && anchor.anchor_hash.length == 64 }
  assert('Anchor is valid') { anchor.valid? }
  assert('Anchor to_h includes all fields') { anchor.to_h.key?(:anchor_hash) && anchor.to_h.key?(:anchor_type) }

  # Invalid anchor types raise
  raised = false
  begin
    Hestia::Chain::Core::Anchor.new(anchor_type: 'invalid', source_id: 'x', data_hash: test_hash)
  rescue ArgumentError
    raised = true
  end
  assert('Invalid anchor_type raises ArgumentError') { raised }

  # Client with InMemory backend
  client = Hestia::Chain::Core::Client.new
  assert('Client backend is in_memory') { client.backend_type == :in_memory }
  assert('Client is enabled') { client.status[:enabled] }

  # Submit and verify
  result = client.submit(anchor)
  assert('Submit returns status submitted') { result[:status] == 'submitted' }
  assert('Submit returns anchor_hash') { result[:anchor_hash] == anchor.anchor_hash }

  # Verify
  verify_result = client.verify(anchor.anchor_hash)
  assert('Verify returns exists: true') { verify_result[:exists] == true }

  # List
  list_result = client.list(anchor_type: 'meeting')
  assert('List returns submitted anchor') { list_result.any? { |a| a[:anchor_hash] == anchor.anchor_hash } }

  # Duplicate submission
  dup_result = client.submit(anchor)
  assert('Duplicate submit returns exists') { dup_result[:status] == 'exists' }
end

# ============================================================================
# Section 2: HestiaChainAdapter (MMP::ChainAdapter interface)
# ============================================================================
section('2. HestiaChainAdapter (MMP::ChainAdapter)') do
  adapter = Hestia::HestiaChainAdapter.new
  assert('Adapter includes MMP::ChainAdapter') { adapter.is_a?(MMP::ChainAdapter) }
  assert('Adapter has client') { adapter.client.is_a?(Hestia::Chain::Core::Client) }
  assert('Adapter has meeting_protocol') { adapter.meeting_protocol.is_a?(Hestia::Chain::Integrations::MeetingProtocol) }

  # record (string)
  result = adapter.record('test log entry')
  assert('record(String) succeeds') { result[:status] == 'submitted' }

  # record (hash)
  result2 = adapter.record({ anchor_type: 'meeting', source_id: 'sess_001', data: 'test' })
  assert('record(Hash) succeeds') { result2[:status] == 'submitted' }

  # history
  hist = adapter.history
  assert('history returns array') { hist.is_a?(Array) && hist.size >= 2 }

  # chain_data
  data = adapter.chain_data
  assert('chain_data returns stats hash') { data.is_a?(Hash) && data.key?(:client) }

  # anchor_session
  session_result = adapter.anchor_session({
    session_id: 'sess_test_001',
    peer_id: 'peer_abc',
    messages: [{ type: 'text', content: 'hello' }],
    started_at: Time.now.utc.iso8601
  })
  assert('anchor_session succeeds') { session_result[:status] == 'submitted' }
  assert('anchor_session returns session_id') { session_result[:session_id] == 'sess_test_001' }

  # anchor_skill_exchange
  skill_hash = Digest::SHA256.hexdigest('skill content')
  exchange_result = adapter.anchor_skill_exchange({
    skill_name: 'test_skill',
    skill_hash: skill_hash,
    direction: :sent,
    peer_id: 'peer_xyz'
  })
  assert('anchor_skill_exchange succeeds') { exchange_result[:status] == 'submitted' }

  # meeting_stats
  stats = adapter.meeting_stats
  assert('meeting_stats returns hash with counts') { stats.key?(:total_anchors) && stats[:total_anchors] >= 2 }
end

# ============================================================================
# Section 3: Chain Migration (in_memory → private)
# ============================================================================
section('3. Chain Migration (in_memory → private)') do
  # Setup: create client with some anchors
  client = Hestia::Chain::Core::Client.new
  3.times do |i|
    client.anchor(
      anchor_type: 'meeting',
      source_id: "migrate_test_#{i}",
      data: "data_#{i}"
    )
  end

  migrator = Hestia::ChainMigrator.new(current_backend: client.backend)
  assert('Migrator detects stage 0 (in_memory)') { migrator.current_stage == 0 }

  # Status
  status = migrator.status
  assert('Status shows 3 anchors') { status[:total_anchors] == 3 }
  assert('Status shows available migration to stage 1') {
    status[:available_migrations].any? { |m| m[:to] == 1 && m[:self_contained] }
  }

  # Dry run
  tmp_dir = Dir.mktmpdir('hestia_migration')
  storage_path = File.join(tmp_dir, 'hestia_anchors.json')
  dry_result = migrator.migrate(target_stage: 1, dry_run: true, storage_path: storage_path)
  assert('Dry run status is dry_run') { dry_result[:status] == 'dry_run' }
  assert('Dry run shows 3 would migrate') { dry_result[:would_migrate] == 3 }

  # Actual migration
  result = migrator.migrate(target_stage: 1, storage_path: storage_path)
  assert('Migration completed') { result[:status] == 'completed' }
  assert('Migrated 3 anchors') { result[:migrated] == 3 }
  assert('Verification passed') { result[:verification][:verification_rate] == 100.0 }
  assert('Private storage file created') { File.exist?(storage_path) }

  # Cannot migrate backwards
  backwards_error = false
  begin
    migrator.migrate(target_stage: 0)
  rescue ArgumentError
    backwards_error = true
  end
  assert('Backwards migration raises error') { backwards_error }

  # Cannot skip stages
  skip_error = false
  begin
    migrator.migrate(target_stage: 2)
  rescue ArgumentError
    skip_error = true
  end
  assert('Skip-stage migration raises error') { skip_error }

  FileUtils.rm_rf(tmp_dir)
end

# ============================================================================
# Section 4: Philosophy Protocol
# ============================================================================
section('4. Philosophy Protocol (PhilosophyDeclaration, ObservationLog)') do
  client = Hestia::Chain::Core::Client.new

  # PhilosophyDeclaration
  philosophy_content = { stance: 'cooperative', principles: ['open exchange', 'mutual respect'] }
  philosophy_hash = Digest::SHA256.hexdigest(philosophy_content.to_json)

  declaration = Hestia::Chain::Protocol::PhilosophyDeclaration.new(
    agent_id: 'agent_test_001',
    philosophy_type: 'exchange',
    philosophy_hash: philosophy_hash,
    compatible_with: %w[cooperative observational],
    version: '1.0'
  )
  assert('Declaration has correct agent_id') { declaration.agent_id == 'agent_test_001' }
  assert('Declaration has declaration_id') { declaration.declaration_id.start_with?('philo_') }

  # Submit declaration as anchor
  anchor = declaration.to_anchor
  assert('Declaration converts to anchor') { anchor.is_a?(Hestia::Chain::Core::Anchor) }
  assert('Anchor type is philosophy_declaration') { anchor.anchor_type == 'philosophy_declaration' }

  submit_result = client.submit(anchor)
  assert('Philosophy declaration submitted') { submit_result[:status] == 'submitted' }

  # Verify on chain
  verify_result = client.verify(anchor.anchor_hash)
  assert('Philosophy declaration verifiable') { verify_result[:exists] }

  # ObservationLog
  interaction_data = { type: 'skill_exchange', skill: 'test_skill', outcome: 'completed' }
  interaction_hash = Digest::SHA256.hexdigest(interaction_data.to_json)

  observation = Hestia::Chain::Protocol::ObservationLog.new(
    observer_id: 'agent_test_001',
    observed_id: 'agent_test_002',
    interaction_hash: interaction_hash,
    observation_type: 'completed',
    interpretation: { quality: 'productive', learned_something: true }
  )
  assert('Observation has observation_id') { observation.observation_id.start_with?('obs_') }
  assert('Not self-observation') { !observation.self_observation? }
  assert('Not fadeout') { !observation.fadeout? }

  # Submit observation
  obs_anchor = observation.to_anchor
  assert('Observation converts to anchor') { obs_anchor.anchor_type == 'observation_log' }

  obs_result = client.submit(obs_anchor)
  assert('Observation submitted') { obs_result[:status] == 'submitted' }

  # Fade-out observation
  fadeout = Hestia::Chain::Protocol::ObservationLog.new(
    observer_id: 'agent_test_001',
    observed_id: 'agent_test_003',
    interaction_hash: Digest::SHA256.hexdigest('fadeout_data'),
    observation_type: 'faded',
    interpretation: { reason: 'natural_decay', duration_days: 30 }
  )
  assert('Fadeout observation is fadeout') { fadeout.fadeout? }

  fadeout_result = client.submit(fadeout.to_anchor)
  assert('Fadeout observation submitted') { fadeout_result[:status] == 'submitted' }

  # Self-observation
  self_obs = Hestia::Chain::Protocol::ObservationLog.new(
    observer_id: 'agent_test_001',
    observed_id: 'agent_test_001',
    interaction_hash: Digest::SHA256.hexdigest('self_reflection'),
    observation_type: 'observed'
  )
  assert('Self-observation detected') { self_obs.self_observation? }

  # Invalid types raise
  invalid_type_error = false
  begin
    Hestia::Chain::Protocol::PhilosophyDeclaration.new(
      agent_id: 'x', philosophy_type: 'invalid', philosophy_hash: philosophy_hash
    )
  rescue ArgumentError
    invalid_type_error = true
  end
  assert('Invalid philosophy_type raises error') { invalid_type_error }

  invalid_obs_error = false
  begin
    Hestia::Chain::Protocol::ObservationLog.new(
      observer_id: 'x', observed_id: 'y',
      interaction_hash: interaction_hash, observation_type: 'invalid'
    )
  rescue ArgumentError
    invalid_obs_error = true
  end
  assert('Invalid observation_type raises error') { invalid_obs_error }

  # Protocol module methods
  assert('valid_philosophy_type? works') { Hestia::Chain::Protocol.valid_philosophy_type?('exchange') }
  assert('valid_observation_type? works') { Hestia::Chain::Protocol.valid_observation_type?('faded') }
  assert('custom types accepted') { Hestia::Chain::Protocol.valid_philosophy_type?('custom.my_type') }
end

# ============================================================================
# Section 5: SkillSet Discovery & Tool Schema
# ============================================================================
section('5. SkillSet Discovery & Tool Schema') do
  # Check skillset.json exists and is valid
  skillset_path = File.join(
    File.expand_path('templates/skillsets/hestia', __dir__),
    'skillset.json'
  )
  assert('skillset.json exists') { File.exist?(skillset_path) }

  skillset = JSON.parse(File.read(skillset_path))
  assert('SkillSet name is hestia') { skillset['name'] == 'hestia' }
  assert('SkillSet depends on mmp') {
    skillset['depends_on'].any? { |d| d.is_a?(Hash) ? d['name'] == 'mmp' : d == 'mmp' }
  }
  assert('SkillSet has 6 tool classes') { skillset['tool_classes'].size == 6 }

  # Require tool base class and tool files (normally done by SkillSetManager.load!)
  require_relative 'lib/kairos_mcp/tools/base_tool'
  Dir[File.expand_path('templates/skillsets/hestia/tools/*.rb', __dir__)].each { |f| require f }

  # Verify tool classes can be instantiated
  tool_classes = [
    KairosMcp::SkillSets::Hestia::Tools::ChainMigrateStatus,
    KairosMcp::SkillSets::Hestia::Tools::ChainMigrateExecute,
    KairosMcp::SkillSets::Hestia::Tools::PhilosophyAnchor,
    KairosMcp::SkillSets::Hestia::Tools::RecordObservation
  ]
  tool_classes.each do |klass|
    tool = klass.new
    assert("#{klass.name.split('::').last} has name") { tool.name.is_a?(String) && !tool.name.empty? }
    assert("#{klass.name.split('::').last} has schema") { tool.input_schema.is_a?(Hash) }
  end

  # chain_migrate_status tool — call it
  status_tool = KairosMcp::SkillSets::Hestia::Tools::ChainMigrateStatus.new
  result = status_tool.call({})
  parsed = JSON.parse(result.first[:text])
  assert('chain_migrate_status returns current_stage') { parsed.key?('current_stage') }
  assert('chain_migrate_status returns client_status') { parsed.key?('client_status') }

  # Config file exists
  config_path = File.join(
    File.expand_path('templates/skillsets/hestia', __dir__),
    'config', 'hestia.yml'
  )
  assert('hestia.yml config exists') { File.exist?(config_path) }

  config = YAML.load_file(config_path)
  assert('Config has chain section') { config.key?('chain') }
  assert('Config has trust_anchor section') { config.key?('trust_anchor') }

  # Knowledge file exists
  knowledge_path = File.join(
    File.expand_path('templates/skillsets/hestia', __dir__),
    'knowledge', 'hestia_meeting_place', 'hestia_meeting_place.md'
  )
  assert('Knowledge file exists') { File.exist?(knowledge_path) }
end

# ============================================================================
# Cleanup & Summary
# ============================================================================
puts ''
puts '=' * 60
puts "Phase 4A RESULTS: #{$pass_count} passed, #{$fail_count} failed"
puts '=' * 60
puts ''

exit($fail_count > 0 ? 1 : 0)
