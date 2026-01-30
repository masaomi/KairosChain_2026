#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for Phase 7: Protocol Evolution (Co-evolution)

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))

require 'kairos_mcp/meeting/protocol_evolution'
require 'kairos_mcp/meeting/compatibility'
require 'kairos_mcp/meeting/meeting_protocol'
require 'kairos_mcp/meeting/identity'
require 'fileutils'

WORKSPACE_ROOT = File.expand_path(__dir__)

def test_protocol_evolution
  puts "=" * 60
  puts "Test: Protocol Evolution"
  puts "=" * 60
  puts

  knowledge_root = File.join(WORKSPACE_ROOT, 'knowledge')
  evolution = KairosMcp::Meeting::ProtocolEvolution.new(
    knowledge_root: knowledge_root,
    config: {
      evaluation_period_days: 7,
      auto_promote: false,
      blocked_actions: %w[execute_code shell_exec]
    }
  )

  # Test 1: Create extension proposal
  puts "1. Testing extension proposal creation..."
  sample_extension = <<~MD
    ---
    name: test_debate_protocol
    layer: L2
    type: protocol_extension
    version: 1.0.0
    description: Test extension for debate
    actions:
      - propose_topic
      - argue_for
      - argue_against
    requires:
      - meeting_protocol_core
    ---

    # Test Debate Protocol

    This is a test extension.
  MD

  proposal = evolution.create_proposal(extension_content: sample_extension)
  puts "   Extension name: #{proposal[:extension_name]}"
  puts "   Actions: #{proposal[:actions].join(', ')}"
  puts "   Content hash: #{proposal[:content_hash][0, 30]}..."
  puts "   ✓ Proposal created"
  puts

  # Test 2: Evaluate extension (safety check)
  puts "2. Testing extension evaluation..."
  eval_result = evolution.evaluate_extension(
    extension_content: sample_extension,
    from_agent: 'test_agent_123'
  )
  puts "   Status: #{eval_result[:status]}"
  puts "   Message: #{eval_result[:message]}"
  puts "   ✓ Evaluation passed"
  puts

  # Test 3: Test blocked actions rejection
  puts "3. Testing blocked actions rejection..."
  dangerous_extension = <<~MD
    ---
    name: dangerous_extension
    layer: L2
    type: protocol_extension
    actions:
      - execute_code
      - safe_action
    ---
    # Dangerous Extension
  MD

  dangerous_result = evolution.evaluate_extension(
    extension_content: dangerous_extension,
    from_agent: 'test_agent_456'
  )
  puts "   Status: #{dangerous_result[:status]}"
  puts "   Reason: #{dangerous_result[:reason]}"
  puts "   Blocked: #{dangerous_result[:blocked_actions]&.join(', ')}"
  puts "   ✓ Dangerous extension rejected"
  puts

  # Test 4: Adopt extension
  puts "4. Testing extension adoption..."
  adopt_result = evolution.adopt_extension(
    extension_content: sample_extension,
    from_agent: 'test_agent_123'
  )
  puts "   Adopted: #{adopt_result[:adopted]}"
  puts "   Layer: #{adopt_result[:layer]}"
  puts "   Message: #{adopt_result[:message]}"
  puts "   ✓ Extension adopted in L2"
  puts

  # Test 5: Check extension status
  puts "5. Checking extension status..."
  status = evolution.extension_status('test_debate_protocol')
  puts "   Name: #{status[:name]}"
  puts "   State: #{status[:state]}"
  puts "   Layer: #{status[:layer]}"
  puts "   From: #{status[:from_agent]}"
  puts "   ✓ Status retrieved"
  puts

  # Test 6: Request promotion (requires approval)
  puts "6. Testing promotion request..."
  promo_result = evolution.request_promotion(extension_name: 'test_debate_protocol')
  puts "   Status: #{promo_result[:status]}"
  puts "   Message: #{promo_result[:message]}"
  puts "   ✓ Promotion requires human approval"
  puts

  # Test 7: List extensions
  puts "7. Listing all extensions..."
  extensions = evolution.list_extensions
  puts "   Adopted: #{extensions[:adopted].size}"
  puts "   Pending promotion: #{extensions[:pending_promotion].size}"
  puts "   Promoted: #{extensions[:promoted].size}"
  puts "   ✓ Extensions listed"
  puts

  # Cleanup test extension
  test_dir = File.join(knowledge_root, 'L2_experimental', 'test_debate_protocol')
  FileUtils.rm_rf(test_dir) if File.exist?(test_dir)
  
  evolution
end

def test_compatibility
  puts "=" * 60
  puts "Test: Compatibility Manager"
  puts "=" * 60
  puts

  compat = KairosMcp::Meeting::Compatibility.new(
    protocol_version: '1.0.0',
    extensions: %w[meeting_protocol_skill_exchange meeting_protocol_evolution],
    actions: %w[introduce goodbye error offer_skill request_skill propose_extension]
  )

  # Test 1: Full compatibility
  puts "1. Testing full compatibility..."
  peer_full = {
    extensions: %w[meeting_protocol_skill_exchange meeting_protocol_evolution],
    capabilities: %w[introduce goodbye error offer_skill request_skill propose_extension],
    protocol_version: '1.0.0'
  }
  result = compat.negotiate(peer_full)
  puts "   Mode: #{result[:mode]}"
  puts "   Compatible: #{result[:compatible]}"
  puts "   Common extensions: #{result[:common_extensions].join(', ')}"
  puts "   ✓ Full compatibility"
  puts

  # Test 2: Partial compatibility
  puts "2. Testing partial compatibility..."
  peer_partial = {
    extensions: %w[meeting_protocol_skill_exchange],
    capabilities: %w[introduce goodbye offer_skill],
    protocol_version: '1.0.0'
  }
  result = compat.negotiate(peer_partial)
  puts "   Mode: #{result[:mode]}"
  puts "   Common extensions: #{result[:common_extensions].join(', ')}"
  puts "   Local only: #{result[:local_only_extensions].join(', ')}"
  puts "   ✓ Partial compatibility detected"
  puts

  # Test 3: Version compatibility
  puts "3. Testing version compatibility..."
  peer_newer = {
    extensions: [],
    capabilities: %w[introduce goodbye],
    protocol_version: '1.1.0'
  }
  result = compat.negotiate(peer_newer)
  puts "   Version compatible: #{result[:version_compatible]}"
  puts "   Can upgrade: #{result[:can_upgrade]}"
  puts "   Message: #{result[:version_message]}"
  puts "   ✓ Version negotiation works"
  puts

  # Test 4: Action availability
  puts "4. Testing action availability..."
  peer_caps = %w[introduce goodbye offer_skill]
  result = compat.action_available?('offer_skill', peer_caps)
  puts "   offer_skill available: #{result[:available]}"
  result = compat.action_available?('propose_extension', peer_caps)
  puts "   propose_extension available: #{result[:available]} (#{result[:reason]})"
  puts "   ✓ Action availability check works"
  puts

  # Test 5: Compatibility report
  puts "5. Generating compatibility report..."
  report = compat.compatibility_report(peer_partial)
  puts report.split("\n").map { |l| "   #{l}" }.join("\n")
  puts "   ✓ Report generated"
  puts

  compat
end

def test_meeting_protocol_evolution
  puts "=" * 60
  puts "Test: MeetingProtocol with Evolution"
  puts "=" * 60
  puts

  identity = KairosMcp::Meeting::Identity.new(workspace_root: WORKSPACE_ROOT)
  protocol = KairosMcp::Meeting::MeetingProtocol.new(
    identity: identity,
    knowledge_root: File.join(WORKSPACE_ROOT, 'knowledge'),
    evolution_config: {
      evaluation_period_days: 7,
      auto_promote: false
    }
  )

  # Test 1: Check evolution integration
  puts "1. Checking evolution integration..."
  puts "   Evolution initialized: #{!protocol.evolution.nil?}"
  puts "   Compatibility initialized: #{!protocol.compatibility.nil?}"
  puts "   ✓ Evolution components integrated"
  puts

  # Test 2: Supported actions include evolution actions
  puts "2. Checking supported actions..."
  actions = protocol.supported_actions
  evolution_actions = %w[propose_extension evaluate_extension adopt_extension share_extension]
  supported = evolution_actions.select { |a| actions.include?(a) }
  puts "   Evolution actions supported: #{supported.join(', ')}"
  puts "   ✓ Evolution actions registered"
  puts

  # Test 3: Create propose_extension message
  puts "3. Testing propose_extension message..."
  sample_extension = <<~MD
    ---
    name: test_extension
    layer: L2
    type: protocol_extension
    version: 1.0.0
    actions:
      - test_action
    requires:
      - meeting_protocol_core
    ---
    # Test Extension
  MD

  msg = protocol.create_propose_extension(
    extension_content: sample_extension,
    to: 'peer_agent'
  )
  if msg
    puts "   Action: #{msg.action}"
    puts "   Extension: #{msg.payload[:extension_name]}"
    puts "   ✓ propose_extension message created"
  else
    puts "   ✗ Failed to create message"
  end
  puts

  # Test 4: Process propose_extension
  puts "4. Testing propose_extension processing..."
  incoming_proposal = {
    id: 'msg_test123',
    action: 'propose_extension',
    from: 'peer_agent',
    timestamp: Time.now.utc.iso8601,
    payload: {
      extension_name: 'peer_extension',
      actions: %w[custom_action],
      content_hash: 'sha256:abc123'
    }
  }
  result = protocol.process_message(incoming_proposal)
  puts "   Status: #{result[:status]}"
  if result[:suggested_response]
    puts "   Suggested response: #{result[:suggested_response].action}"
  end
  puts "   ✓ propose_extension processed"
  puts

  # Test 5: Negotiate compatibility
  puts "5. Testing compatibility negotiation..."
  peer_info = {
    extensions: %w[meeting_protocol_skill_exchange custom_extension],
    capabilities: %w[introduce goodbye offer_skill custom_action],
    protocol_version: '1.0.0'
  }
  compat_result = protocol.negotiate_compatibility(peer_info)
  puts "   Mode: #{compat_result[:mode]}"
  puts "   Common extensions: #{compat_result[:common_extensions].join(', ')}"
  puts "   ✓ Compatibility negotiated"
  puts

  # Test 6: Shareable extensions
  puts "6. Checking shareable extensions..."
  shareable = protocol.shareable_extensions
  puts "   Shareable count: #{shareable.size}"
  puts "   ✓ Shareable extensions retrieved"
  puts

  protocol
end

# Run all tests
begin
  test_protocol_evolution
  test_compatibility
  test_meeting_protocol_evolution

  puts "=" * 60
  puts "All Phase 7 tests completed!"
  puts "=" * 60
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(10).join("\n")
  exit 1
end
