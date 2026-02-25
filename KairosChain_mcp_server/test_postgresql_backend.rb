#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for KairosChain PostgreSQL Backend
# Requires: docker compose -f Echoria/docker/docker-compose.dev.yml up -d
# Usage: ruby test_postgresql_backend.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'kairos_mcp/storage/postgresql_backend'

PASS = "\u2713"
FAIL = "\u2717"
$test_count = 0
$pass_count = 0

def assert(description, &block)
  $test_count += 1
  result = block.call
  if result
    $pass_count += 1
    puts "  #{PASS} #{description}"
  else
    puts "  #{FAIL} #{description}"
  end
rescue StandardError => e
  puts "  #{FAIL} #{description} — #{e.class}: #{e.message}"
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "  #{title}"
  puts "#{'=' * 60}"
  yield
end

puts "KairosChain PostgreSQL Backend Test"
puts "Ruby version: #{RUBY_VERSION}"
puts

# Connect to the dev PostgreSQL instance
config = {
  host: 'localhost',
  port: 5433,
  dbname: 'echoria_development',
  user: 'echoria',
  password: 'echoria_dev',
  tenant_id: 'test_tenant_1'
}

backend = KairosMcp::Storage::PostgresqlBackend.new(config)

# Clean up test data before starting
backend.exec_params("DELETE FROM kairos_blocks WHERE tenant_id = $1", ['test_tenant_1'])
backend.exec_params("DELETE FROM kairos_blocks WHERE tenant_id = $1", ['test_tenant_2'])
backend.exec_params("DELETE FROM kairos_action_logs WHERE tenant_id = $1", ['test_tenant_1'])
backend.exec_params("DELETE FROM kairos_action_logs WHERE tenant_id = $1", ['test_tenant_2'])
backend.exec_params("DELETE FROM kairos_knowledge_meta WHERE tenant_id = $1", ['test_tenant_1'])
backend.exec_params("DELETE FROM kairos_knowledge_meta WHERE tenant_id = $1", ['test_tenant_2'])

section("Basic Connection") do
  assert("backend is ready") { backend.ready? }
  assert("backend_type is :postgresql") { backend.backend_type == :postgresql }
  assert("tenant_id is set") { backend.tenant_id == 'test_tenant_1' }
end

section("Block Operations") do
  block1 = {
    index: 0,
    timestamp: Time.now.iso8601,
    data: { type: 'genesis', message: 'test genesis block' },
    previous_hash: '0' * 64,
    merkle_root: 'abc123',
    hash: 'def456'
  }

  block2 = {
    index: 1,
    timestamp: Time.now.iso8601,
    data: { type: 'skill_evolution', skill_id: 'test_skill' },
    previous_hash: 'def456',
    merkle_root: 'ghi789',
    hash: 'jkl012'
  }

  assert("save_block returns true") { backend.save_block(block1) }
  assert("save_block (second block) returns true") { backend.save_block(block2) }

  blocks = backend.load_blocks
  assert("load_blocks returns 2 blocks") { blocks&.length == 2 }
  assert("blocks are ordered by index") { blocks[0][:index] == 0 && blocks[1][:index] == 1 }
  assert("block data is preserved") { blocks[0][:data]['type'] == 'genesis' }

  assert("all_blocks returns array") { backend.all_blocks.is_a?(Array) }
  assert("all_blocks length is 2") { backend.all_blocks.length == 2 }

  # Test upsert (ON CONFLICT)
  block1_updated = block1.merge(data: { type: 'genesis', message: 'updated' })
  assert("upsert block returns true") { backend.save_block(block1_updated) }
  assert("upsert preserves block count") { backend.all_blocks.length == 2 }
  assert("upsert updates data") { backend.load_blocks[0][:data]['message'] == 'updated' }

  # Test save_all_blocks
  assert("save_all_blocks returns true") { backend.save_all_blocks([block1, block2]) }
end

section("Action Log Operations") do
  entry1 = { timestamp: Time.now.iso8601, action: 'skill_execute', skill_id: 'greet', layer: 'L2', details: { args: { name: 'test' } } }
  entry2 = { action: 'skill_evolve', skill_id: 'greet', layer: 'L1' }

  assert("record_action returns true") { backend.record_action(entry1) }
  assert("record_action (no timestamp) returns true") { backend.record_action(entry2) }

  history = backend.action_history(limit: 10)
  assert("action_history returns array") { history.is_a?(Array) }
  assert("action_history has 2 entries") { history.length == 2 }
  assert("history is chronological (oldest first)") { history[0][:action] == 'skill_execute' }
  assert("details are preserved as hash") { history[0][:details].is_a?(Hash) }

  assert("clear_action_log! returns true") { backend.clear_action_log! }
  assert("action_history is empty after clear") { backend.action_history.empty? }
end

section("Knowledge Meta Operations") do
  meta1 = { content_hash: 'sha256_abc', version: '1.0', description: 'Test knowledge', tags: ['test', 'ruby'] }
  meta2 = { content_hash: 'sha256_def', version: '2.0', description: 'Updated knowledge', tags: ['test', 'updated'] }

  assert("save_knowledge_meta returns true") { backend.save_knowledge_meta('test_knowledge', meta1) }

  result = backend.get_knowledge_meta('test_knowledge')
  assert("get_knowledge_meta returns hash") { result.is_a?(Hash) }
  assert("name is preserved") { result[:name] == 'test_knowledge' }
  assert("content_hash is preserved") { result[:content_hash] == 'sha256_abc' }
  assert("tags are preserved as array") { result[:tags] == ['test', 'ruby'] }
  assert("is_archived defaults to false") { result[:is_archived] == false }

  # Test upsert
  assert("update via save returns true") { backend.save_knowledge_meta('test_knowledge', meta2) }
  updated = backend.get_knowledge_meta('test_knowledge')
  assert("version is updated") { updated[:version] == '2.0' }
  assert("tags are updated") { updated[:tags] == ['test', 'updated'] }

  # Test list
  backend.save_knowledge_meta('another_knowledge', meta1)
  list = backend.list_knowledge_meta
  assert("list_knowledge_meta returns 2 entries") { list.length == 2 }

  # Test archive
  assert("update_knowledge_archived returns true") { backend.update_knowledge_archived('test_knowledge', true, reason: 'superseded') }
  archived = backend.get_knowledge_meta('test_knowledge')
  assert("is_archived is true after archive") { archived[:is_archived] == true }
  assert("archived_reason is set") { archived[:archived_reason] == 'superseded' }

  # Test unarchive
  backend.update_knowledge_archived('test_knowledge', false)
  unarchived = backend.get_knowledge_meta('test_knowledge')
  assert("is_archived is false after unarchive") { unarchived[:is_archived] == false }

  # Test delete
  assert("delete_knowledge_meta returns true") { backend.delete_knowledge_meta('test_knowledge') }
  assert("deleted knowledge returns nil") { backend.get_knowledge_meta('test_knowledge').nil? }
end

section("Multi-Tenant Isolation") do
  # Tenant 1 data (already has blocks from earlier tests)
  tenant1_blocks = backend.all_blocks
  assert("tenant 1 has blocks") { tenant1_blocks.length > 0 }

  # Switch to tenant 2
  backend.switch_tenant!('test_tenant_2')
  assert("tenant_id changed") { backend.tenant_id == 'test_tenant_2' }

  assert("tenant 2 has no blocks") { backend.all_blocks.empty? }
  assert("tenant 2 load_blocks returns nil") { backend.load_blocks.nil? }

  # Add data for tenant 2
  backend.save_block({ index: 0, timestamp: Time.now.iso8601, data: { tenant: 2 }, previous_hash: '0' * 64, merkle_root: 'x', hash: 'y' })
  assert("tenant 2 has 1 block") { backend.all_blocks.length == 1 }

  # Switch back to tenant 1 and verify isolation
  backend.switch_tenant!('test_tenant_1')
  assert("tenant 1 still has original blocks") { backend.all_blocks.length == 2 }
  assert("tenant 1 data is not tenant 2 data") { backend.load_blocks[0][:data]['tenant'].nil? }
end

section("Factory Method") do
  factory_backend = KairosMcp::Storage::Backend.create(
    backend: 'postgresql',
    postgresql: config
  )
  assert("factory creates PostgresqlBackend") { factory_backend.is_a?(KairosMcp::Storage::PostgresqlBackend) }
  assert("factory backend is ready") { factory_backend.ready? }
  factory_backend.close
end

# Clean up
backend.switch_tenant!('test_tenant_1')
backend.exec_params("DELETE FROM kairos_blocks WHERE tenant_id IN ($1, $2)", ['test_tenant_1', 'test_tenant_2'])
backend.exec_params("DELETE FROM kairos_action_logs WHERE tenant_id IN ($1, $2)", ['test_tenant_1', 'test_tenant_2'])
backend.exec_params("DELETE FROM kairos_knowledge_meta WHERE tenant_id IN ($1, $2)", ['test_tenant_1', 'test_tenant_2'])
backend.close

puts "\n#{'=' * 60}"
puts "  Results: #{$pass_count}/#{$test_count} passed"
puts "#{'=' * 60}"

exit($pass_count == $test_count ? 0 : 1)
