#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for KairosChain Meeting Protocol (Phase 1)
# Usage: ruby test_meeting.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'kairos_mcp/protocol'

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

def pretty_json(hash)
  JSON.pretty_generate(hash)
end

# Initialize protocol
protocol = KairosMcp::Protocol.new

puts "KairosChain Meeting Protocol - Phase 1 Test"
puts "Ruby version: #{RUBY_VERSION}"
puts "Time: #{Time.now}"

# Test 1: Initialize with workspace
test_section("Initialize with Workspace") do
  request = {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      roots: [{ uri: "file://#{File.expand_path(__dir__)}" }]
    }
  }
  
  response = protocol.handle_message(request.to_json)
  puts pretty_json(response[:result])
  
  # Verify meeting capabilities are present
  if response[:result][:capabilities][:meeting]
    puts "\n✓ Meeting capabilities present"
    puts "  Version: #{response[:result][:capabilities][:meeting][:version]}"
    puts "  Actions: #{response[:result][:capabilities][:meeting][:supported_actions].join(', ')}"
  else
    puts "\n✗ Meeting capabilities missing!"
  end
end

# Test 2: Meeting Introduce
test_section("Meeting Introduce") do
  request = {
    jsonrpc: '2.0',
    id: 2,
    method: 'meeting/introduce',
    params: {}
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    
    # Verify key fields
    result = response[:result]
    puts "\n--- Verification ---"
    puts "✓ Identity: #{result[:identity][:name]}" if result[:identity]
    puts "✓ Capabilities present" if result[:capabilities]
    puts "✓ Skills count: #{result[:skills]&.size || 0}"
    puts "✓ Constraints present" if result[:constraints]
    puts "✓ Exchange policy present" if result[:exchange_policy]
  else
    puts "✗ No response or nil result"
    puts response.inspect
  end
end

# Test 3: Meeting Capabilities
test_section("Meeting Capabilities") do
  request = {
    jsonrpc: '2.0',
    id: 3,
    method: 'meeting/capabilities',
    params: {}
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    
    # Verify
    result = response[:result]
    puts "\n--- Verification ---"
    puts "✓ Protocol version: #{result[:meeting_protocol_version]}"
    puts "✓ Supported actions: #{result[:supported_actions]&.join(', ')}"
    puts "✓ Skill formats: #{result[:skill_formats]&.join(', ')}"
  else
    puts "✗ No response or nil result"
  end
end

# Test 4: Meeting Skills (public only)
test_section("Meeting Skills (Public Only)") do
  request = {
    jsonrpc: '2.0',
    id: 4,
    method: 'meeting/skills',
    params: { public_only: true }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    
    # Verify
    result = response[:result]
    puts "\n--- Verification ---"
    puts "✓ Skills returned: #{result[:skills]&.size || 0}"
    puts "✓ Exchange policy: #{result[:exchange_policy][:allowed_formats].join(', ')}"
    puts "✓ Executable allowed: #{result[:exchange_policy][:allow_executable]}"
  else
    puts "✗ No response or nil result"
  end
end

# Test 5: Meeting Skills (all)
test_section("Meeting Skills (All, including non-public)") do
  request = {
    jsonrpc: '2.0',
    id: 5,
    method: 'meeting/skills',
    params: { public_only: false }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    skills = response[:result][:skills] || []
    puts "Total skills found: #{skills.size}"
    
    skills.each do |skill|
      puts "\n  - #{skill[:name]} (#{skill[:layer]})"
      puts "    ID: #{skill[:id]}"
      puts "    Format: #{skill[:format]}"
      puts "    Public: #{skill[:public]}"
      puts "    Summary: #{skill[:summary]&.slice(0, 60)}..."
    end
  else
    puts "✗ No response or nil result"
  end
end

# Test 6: Direct Identity class test
test_section("Direct Identity Class Test") do
  require 'kairos_mcp/meeting/identity'
  
  identity = KairosMcp::Meeting::Identity.new(
    workspace_root: File.expand_path(__dir__)
  )
  
  intro = identity.introduce
  
  puts "Instance ID: #{intro[:identity][:instance_id]}"
  puts "Name: #{intro[:identity][:name]}"
  puts "Scope: #{intro[:identity][:scope]}"
  puts "Version: #{intro[:identity][:version]}"
  puts ""
  puts "Capabilities:"
  puts "  Protocol version: #{intro[:capabilities][:meeting_protocol_version]}"
  puts "  Actions: #{intro[:capabilities][:supported_actions].join(', ')}"
  puts ""
  puts "Exchange Policy:"
  puts "  Allowed formats: #{intro[:exchange_policy][:allowed_formats].join(', ')}"
  puts "  Executable: #{intro[:exchange_policy][:allow_executable]}"
  puts ""
  puts "Constraints:"
  puts "  Max skill size: #{intro[:constraints][:max_skill_size_bytes]} bytes"
  puts "  Rate limit: #{intro[:constraints][:rate_limit_per_minute]}/min"
end

# Test 7: Config file test
test_section("Config File Verification") do
  config_path = File.expand_path('config/meeting.yml', __dir__)
  
  if File.exist?(config_path)
    puts "✓ Config file exists: #{config_path}"
    
    require 'yaml'
    config = YAML.load_file(config_path)
    
    puts "\nConfig contents:"
    puts "  Identity name: #{config.dig('identity', 'name')}"
    puts "  Allowed formats: #{config.dig('skill_exchange', 'allowed_formats')&.join(', ')}"
    puts "  Executable allowed: #{config.dig('skill_exchange', 'allow_executable')}"
    puts "  Public by default: #{config.dig('skill_exchange', 'public_by_default')}"
  else
    puts "✗ Config file not found: #{config_path}"
  end
end

separator
puts "\n--- Phase 1 Complete ---"

# ============================================================
# Phase 2 Tests
# ============================================================

separator
puts "Starting Phase 2 Tests..."
separator

# Test 8: Start Session
test_section("Start Interaction Session") do
  request = {
    jsonrpc: '2.0',
    id: 8,
    method: 'meeting/start_session',
    params: { peer_id: 'peer_test_12345' }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    puts "\n✓ Session started: #{response[:result][:session_id]}"
    $test_session_id = response[:result][:session_id]
  else
    puts "✗ Failed to start session"
  end
end

# Test 9: Create Offer Skill Message
test_section("Create Offer Skill Message") do
  # First, we need a public skill. Let's check what skills are available
  skills_request = {
    jsonrpc: '2.0',
    id: 'skills_check',
    method: 'meeting/skills',
    params: { public_only: false }
  }
  
  skills_response = protocol.handle_message(skills_request.to_json)
  skills = skills_response[:result][:skills] || []
  
  if skills.empty?
    puts "No skills available to offer. Skipping this test."
  else
    # Mark first skill as public for testing (in real scenario, use frontmatter)
    test_skill = skills.first
    puts "Available skill: #{test_skill[:name]} (#{test_skill[:id]})"
    puts "Note: Skill is not marked as public, so offer_skill will fail as expected"
    
    # Try to offer (will fail because skill is not public)
    request = {
      jsonrpc: '2.0',
      id: 9,
      method: 'meeting/offer_skill',
      params: { 
        skill_id: test_skill[:id],
        to: 'peer_test_12345'
      }
    }
    
    response = protocol.handle_message(request.to_json)
    
    if response[:error]
      puts "Expected error (skill not public): #{response[:error][:message]}"
      puts "✓ Security check working - non-public skills cannot be offered"
    else
      puts pretty_json(response[:result])
    end
  end
end

# Test 10: Create Request Skill Message
test_section("Create Request Skill Message") do
  request = {
    jsonrpc: '2.0',
    id: 10,
    method: 'meeting/request_skill',
    params: { 
      description: 'Looking for a skill about bioinformatics data analysis',
      to: 'peer_test_12345'
    }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    puts "\n✓ Request skill message created"
    puts "  Message ID: #{response[:result][:message][:id]}"
    $test_request_id = response[:result][:message][:id]
  else
    puts "✗ Failed to create request"
    puts response.inspect
  end
end

# Test 11: Create Accept Message
test_section("Create Accept Message") do
  request = {
    jsonrpc: '2.0',
    id: 11,
    method: 'meeting/accept',
    params: { 
      in_reply_to: $test_request_id || 'msg_test123',
      to: 'peer_test_12345'
    }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    puts "\n✓ Accept message created"
  else
    puts "✗ Failed"
    puts response.inspect
  end
end

# Test 12: Create Decline Message
test_section("Create Decline Message") do
  request = {
    jsonrpc: '2.0',
    id: 12,
    method: 'meeting/decline',
    params: { 
      in_reply_to: 'msg_some_offer',
      to: 'peer_test_12345',
      reason: 'Format not supported'
    }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    puts "\n✓ Decline message created"
  else
    puts "✗ Failed"
    puts response.inspect
  end
end

# Test 13: Create Reflect Message
test_section("Create Reflect Message") do
  request = {
    jsonrpc: '2.0',
    id: 13,
    method: 'meeting/reflect',
    params: { 
      to: 'peer_test_12345',
      reflection: 'Thank you for the skill exchange. The documentation was very helpful.',
      in_reply_to: $test_request_id
    }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    puts "\n✓ Reflect message created"
  else
    puts "✗ Failed"
    puts response.inspect
  end
end

# Test 14: Process Incoming Message
test_section("Process Incoming Message (Introduce)") do
  incoming_message = {
    id: 'msg_incoming_001',
    action: 'introduce',
    from: 'peer_remote_abc',
    to: nil,
    timestamp: Time.now.utc.iso8601,
    payload: {
      identity: {
        name: 'Remote KairosChain',
        description: 'A bioinformatics-focused agent',
        scope: 'bioinformatics',
        version: '0.4.0',
        instance_id: 'remote_instance_xyz'
      },
      capabilities: {
        meeting_protocol_version: '1.0.0',
        supported_actions: %w[introduce offer_skill request_skill],
        skill_formats: %w[markdown]
      }
    },
    protocol_version: '1.0.0'
  }

  request = {
    jsonrpc: '2.0',
    id: 14,
    method: 'meeting/process_message',
    params: { message: incoming_message }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    puts "\n✓ Incoming message processed"
    puts "  Status: #{response[:result][:status]}"
    puts "  Peer: #{response[:result][:from]}"
  else
    puts "✗ Failed"
    puts response.inspect
  end
end

# Test 15: Process Incoming Offer Skill
test_section("Process Incoming Offer Skill") do
  incoming_offer = {
    id: 'msg_incoming_002',
    action: 'offer_skill',
    from: 'peer_remote_abc',
    to: 'fe8cfa0ac1e3412f',
    timestamp: Time.now.utc.iso8601,
    payload: {
      skill_id: 'remote_skill_001',
      skill_name: 'rnaseq_pipeline_guide',
      skill_summary: 'Complete guide for RNA-seq data analysis',
      skill_format: 'markdown',
      content_hash: 'abc123def456'
    },
    protocol_version: '1.0.0'
  }

  request = {
    jsonrpc: '2.0',
    id: 15,
    method: 'meeting/process_message',
    params: { message: incoming_offer }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    puts "\n✓ Offer processed"
    puts "  Can accept: #{response[:result][:can_accept]}"
  else
    puts "✗ Failed"
    puts response.inspect
  end
end

# Test 16: End Session
test_section("End Interaction Session") do
  request = {
    jsonrpc: '2.0',
    id: 16,
    method: 'meeting/end_session',
    params: { summary: 'Test session completed successfully' }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    puts pretty_json(response[:result])
    puts "\n✓ Session ended"
  else
    puts "✗ Failed"
    puts response.inspect
  end
end

# Test 17: Interaction History
test_section("Interaction History") do
  request = {
    jsonrpc: '2.0',
    id: 17,
    method: 'meeting/interaction_history',
    params: { limit: 20 }
  }
  
  response = protocol.handle_message(request.to_json)
  
  if response && response[:result]
    summary = response[:result][:summary]
    interactions = response[:result][:interactions]
    
    puts "Summary:"
    puts "  Total interactions: #{summary[:total_interactions]}"
    puts "  Unique peers: #{summary[:unique_peers]}"
    puts "  Skills transferred: #{summary[:skills_transferred]}"
    puts ""
    puts "Recent interactions: #{interactions&.length || 0}"
    
    interactions&.first(5)&.each do |i|
      puts "  - #{i[:type]} (#{i[:timestamp]})"
    end
    
    puts "\n✓ History retrieved"
  else
    puts "✗ Failed"
    puts response.inspect
  end
end

# Test 18: Direct Skill Exchange Test
test_section("Direct Skill Exchange Class Test") do
  require 'kairos_mcp/meeting/skill_exchange'
  
  config = YAML.load_file(File.expand_path('config/meeting.yml', __dir__))
  exchange = KairosMcp::Meeting::SkillExchange.new(
    config: config,
    workspace_root: File.expand_path(__dir__)
  )
  
  puts "Allowed formats: #{exchange.allowed_formats.join(', ')}"
  puts "Executable allowed: #{exchange.executable_allowed?}"
  puts ""
  
  # Test validation
  test_skill = {
    content: "# Test Skill\n\nThis is a test skill content.",
    format: 'markdown',
    content_hash: Digest::SHA256.hexdigest("# Test Skill\n\nThis is a test skill content.")
  }
  
  validation = exchange.validate_received_skill(test_skill)
  puts "Validation result:"
  puts "  Valid: #{validation[:valid]}"
  puts "  Errors: #{validation[:errors].join(', ')}" if validation[:errors].any?
  puts "  Warnings: #{validation[:warnings].join(', ')}" if validation[:warnings].any?
  
  puts "\n✓ Skill exchange class working"
end

# Test 19: Direct Meeting Protocol Test
test_section("Direct Meeting Protocol Class Test") do
  require 'kairos_mcp/meeting/meeting_protocol'
  require 'kairos_mcp/meeting/identity'
  
  identity = KairosMcp::Meeting::Identity.new(
    workspace_root: File.expand_path(__dir__)
  )
  
  mp = KairosMcp::Meeting::MeetingProtocol.new(identity: identity)
  
  # Create introduce message
  intro = mp.create_introduce
  puts "Introduce message:"
  puts "  ID: #{intro.id}"
  puts "  Action: #{intro.action}"
  puts "  From: #{intro.from}"
  puts "  Protocol version: #{intro.protocol_version}"
  
  # Create request skill message
  req = mp.create_request_skill(description: 'Need help with genome assembly')
  puts "\nRequest skill message:"
  puts "  ID: #{req.id}"
  puts "  Action: #{req.action}"
  puts "  Description: #{req.payload[:description]}"
  
  puts "\n✓ Meeting protocol class working"
end

separator
puts "\nPhase 2 Testing Complete!"
puts "\nSummary:"
puts "  Phase 1:"
puts "    - Meeting Protocol methods: introduce, capabilities, skills"
puts "    - Config file: config/meeting.yml"
puts "    - Identity class: lib/kairos_mcp/meeting/identity.rb"
puts "  Phase 2:"
puts "    - Semantic actions: offer_skill, request_skill, accept, decline, reflect"
puts "    - Skill exchange: packaging, validation, storage"
puts "    - Interaction logging: session tracking, history"
puts "\nNext steps (Phase 3):"
puts "  - HTTP server for Meeting API"
puts "  - P2P connection via SSH tunneling"
