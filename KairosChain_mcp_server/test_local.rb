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

# Test 3: Knowledge List
test_section("Knowledge List (L1)") do
  request = {
    jsonrpc: '2.0',
    id: 2,
    method: 'tools/call',
    params: {
      name: 'knowledge_list',
      arguments: {}
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 4: Knowledge Get
test_section("Knowledge Get (L1)") do
  request = {
    jsonrpc: '2.0',
    id: 3,
    method: 'tools/call',
    params: {
      name: 'knowledge_get',
      arguments: { 'name' => 'example_knowledge', 'include_scripts' => true }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 5: Context Sessions
test_section("Context Sessions (L2)") do
  request = {
    jsonrpc: '2.0',
    id: 4,
    method: 'tools/call',
    params: {
      name: 'context_sessions',
      arguments: {}
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 6: Context Save
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
    id: 5,
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

# Test 7: Context List
test_section("Context List (L2)") do
  request = {
    jsonrpc: '2.0',
    id: 6,
    method: 'tools/call',
    params: {
      name: 'context_list',
      arguments: { 'session_id' => 'test_session' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 8: Context Get
test_section("Context Get (L2)") do
  request = {
    jsonrpc: '2.0',
    id: 7,
    method: 'tools/call',
    params: {
      name: 'context_get',
      arguments: { 'session_id' => 'test_session', 'name' => 'test_hypothesis' }
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts response[:result][:content].first[:text]
end

# Test 9: Skills DSL List (L0)
test_section("Skills DSL List (L0)") do
  request = {
    jsonrpc: '2.0',
    id: 8,
    method: 'tools/call',
    params: {
      name: 'skills_dsl_list',
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
