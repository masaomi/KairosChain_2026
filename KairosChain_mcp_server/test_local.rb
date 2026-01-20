#!/usr/bin/env ruby
# frozen_string_literal: true

# Local test script for KairosChain MCP Server
# Usage: ruby test_local.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'kairos_mcp/protocol'
require 'kairos_mcp/layer_registry'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/context_manager'
require 'kairos_mcp/anthropic_skill_parser'
require 'kairos_mcp/resource_registry'

def separator
  puts "\n#{'=' * 60}\n"
end

def test_section(title)
  separator
  puts "TEST: #{title}"
  separator
  yield
rescue StandardError => e
  puts "ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

# Initialize protocol
protocol = KairosMcp::Protocol.new

puts "KairosChain MCP Server - Local Test"
puts "Ruby version: #{RUBY_VERSION}"

# Test 1: Layer Registry
test_section("Layer Registry") do
  puts "Layers summary:"
  KairosMcp::LayerRegistry.summary.each do |layer|
    puts "  #{layer[:layer]}: #{layer[:path]} (mutable: #{layer[:mutable]}, blockchain: #{layer[:blockchain]})"
  end
  
  puts "\nKairos meta-skills:"
  puts "  #{KairosMcp::LayerRegistry::KAIROS_META_SKILLS.join(', ')}"
end

# Test 2: Tools List
test_section("List Available Tools") do
  request = {
    jsonrpc: '2.0',
    id: 1,
    method: 'tools/list'
  }
  
  response = protocol.handle_message(request.to_json)
  tools = response[:result][:tools]
  
  puts "Available tools (#{tools.size}):"
  tools.each do |tool|
    puts "  - #{tool[:name]}: #{tool[:description][0, 60]}..."
  end
end

# Test 3: Resource List (All)
test_section("Resource List - All Layers") do
  request = {
    jsonrpc: '2.0',
    id: 3,
    method: 'tools/call',
    params: {
      name: 'resource_list',
      arguments: {}
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 4: Resource List (L0 only)
test_section("Resource List - L0 Only") do
  request = {
    jsonrpc: '2.0',
    id: 4,
    method: 'tools/call',
    params: {
      name: 'resource_list',
      arguments: { 'layer' => 'l0' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 5: Resource List (L1, scripts only)
test_section("Resource List - L1 Scripts Only") do
  request = {
    jsonrpc: '2.0',
    id: 5,
    method: 'tools/call',
    params: {
      name: 'resource_list',
      arguments: { 'layer' => 'l1', 'type' => 'scripts' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 6: Resource Read - L0 kairos.md
test_section("Resource Read - L0 kairos.md") do
  request = {
    jsonrpc: '2.0',
    id: 6,
    method: 'tools/call',
    params: {
      name: 'resource_read',
      arguments: { 'uri' => 'l0://kairos.md' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  # Only show first 1000 chars to avoid flooding
  text = response[:result][:content].first[:text]
  puts text.length > 1000 ? "#{text[0, 1000]}...\n\n[truncated]" : text
end

# Test 7: Resource Read - L0 kairos.rb
test_section("Resource Read - L0 kairos.rb") do
  request = {
    jsonrpc: '2.0',
    id: 7,
    method: 'tools/call',
    params: {
      name: 'resource_read',
      arguments: { 'uri' => 'l0://kairos.rb' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  text = response[:result][:content].first[:text]
  puts text.length > 1000 ? "#{text[0, 1000]}...\n\n[truncated]" : text
end

# Test 8: Resource Read - L1 Knowledge
test_section("Resource Read - L1 Knowledge") do
  request = {
    jsonrpc: '2.0',
    id: 8,
    method: 'tools/call',
    params: {
      name: 'resource_read',
      arguments: { 'uri' => 'knowledge://example_knowledge' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 9: Resource Read - L1 Script
test_section("Resource Read - L1 Script") do
  request = {
    jsonrpc: '2.0',
    id: 9,
    method: 'tools/call',
    params: {
      name: 'resource_read',
      arguments: { 'uri' => 'knowledge://example_knowledge/scripts/example_script.sh' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 10: Resource Read - Not Found
test_section("Resource Read - Not Found") do
  request = {
    jsonrpc: '2.0',
    id: 10,
    method: 'tools/call',
    params: {
      name: 'resource_read',
      arguments: { 'uri' => 'knowledge://nonexistent' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 11: Context Save (to test L2 resources)
test_section("Context Save (L2)") do
  content = <<~MD
    ---
    name: test_hypothesis
    description: Test hypothesis for local testing
    ---

    # Test Hypothesis

    This is a test context created by the local test script.

    ## Notes
    - Created at: #{Time.now}
    - Purpose: Verify L2 context functionality
  MD

  request = {
    jsonrpc: '2.0',
    id: 11,
    method: 'tools/call',
    params: {
      name: 'context_save',
      arguments: {
        'session_id' => 'test_session',
        'name' => 'test_hypothesis',
        'content' => content
      }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 12: Resource List - L2 Context
test_section("Resource List - L2 Context") do
  request = {
    jsonrpc: '2.0',
    id: 12,
    method: 'tools/call',
    params: {
      name: 'resource_list',
      arguments: { 'layer' => 'l2' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 13: Resource Read - L2 Context
test_section("Resource Read - L2 Context") do
  request = {
    jsonrpc: '2.0',
    id: 13,
    method: 'tools/call',
    params: {
      name: 'resource_read',
      arguments: { 'uri' => 'context://test_session/test_hypothesis' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 14: Skills DSL List (L0)
test_section("Skills DSL List (L0)") do
  request = {
    jsonrpc: '2.0',
    id: 14,
    method: 'tools/call',
    params: {
      name: 'skills_dsl_list',
      arguments: {}
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 15: Knowledge List (L1)
test_section("Knowledge List (L1)") do
  request = {
    jsonrpc: '2.0',
    id: 15,
    method: 'tools/call',
    params: {
      name: 'knowledge_list',
      arguments: {}
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

separator
puts "All tests completed!"
puts "\nTest artifacts created:"
puts "  - context/test_session/test_hypothesis/"
puts "\nTo clean up test artifacts:"
puts "  rm -rf #{File.expand_path('context/test_session', __dir__)}"
