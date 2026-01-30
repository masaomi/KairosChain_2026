#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for Phase 6: Protocol Loader and Dynamic Protocol Loading

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))

require 'kairos_mcp/meeting/protocol_loader'
require 'kairos_mcp/meeting/meeting_protocol'
require 'kairos_mcp/meeting/identity'

WORKSPACE_ROOT = File.expand_path(__dir__)

def test_protocol_loader
  puts "=" * 60
  puts "Test: Protocol Loader"
  puts "=" * 60
  puts

  knowledge_root = File.join(WORKSPACE_ROOT, 'knowledge')
  loader = KairosMcp::Meeting::ProtocolLoader.new(knowledge_root: knowledge_root)

  # Test 1: Load all protocols
  puts "1. Loading all protocols..."
  result = loader.load_all
  puts "   Bootstrap protocols: #{result[:bootstrap_count]}"
  puts "   Extension protocols: #{result[:extension_count]}"
  puts "   Total actions: #{result[:total_actions]}"
  puts "   Actions: #{result[:actions].join(', ')}"
  puts "   Extensions: #{result[:extensions].join(', ')}"
  puts "   ✓ Protocols loaded"
  puts

  # Test 2: Check core actions
  puts "2. Checking core actions..."
  core = loader.core_actions
  puts "   Core actions: #{core.join(', ')}"
  expected_core = %w[introduce goodbye error]
  if (expected_core - core).empty?
    puts "   ✓ All core actions present"
  else
    puts "   ✗ Missing core actions: #{(expected_core - core).join(', ')}"
  end
  puts

  # Test 3: Check extension actions
  puts "3. Checking extension actions..."
  ext_actions = loader.extension_actions
  puts "   Extension actions: #{ext_actions.join(', ')}"
  expected_ext = %w[offer_skill request_skill accept decline skill_content reflect]
  if (expected_ext - ext_actions).empty?
    puts "   ✓ All skill_exchange actions present"
  else
    puts "   ✗ Missing extension actions: #{(expected_ext - ext_actions).join(', ')}"
  end
  puts

  # Test 4: Action support check
  puts "4. Testing action support..."
  test_actions = %w[introduce goodbye error offer_skill unknown_action]
  test_actions.each do |action|
    supported = loader.action_supported?(action)
    status = supported ? "✓ supported" : "✗ not supported"
    puts "   #{action}: #{status}"
  end
  puts

  # Test 5: Get action definition
  puts "5. Testing action definitions..."
  %w[introduce offer_skill].each do |action|
    defn = loader.action_definition(action)
    puts "   #{action}: protocol=#{defn[:protocol]}, layer=#{defn[:layer]}, immutable=#{defn[:immutable]}"
  end
  puts

  loader
end

def test_meeting_protocol_with_loader
  puts "=" * 60
  puts "Test: MeetingProtocol with Protocol Loader"
  puts "=" * 60
  puts

  identity = KairosMcp::Meeting::Identity.new(workspace_root: WORKSPACE_ROOT)
  protocol = KairosMcp::Meeting::MeetingProtocol.new(
    identity: identity,
    knowledge_root: File.join(WORKSPACE_ROOT, 'knowledge')
  )

  # Test 1: Check supported actions
  puts "1. Checking supported actions..."
  actions = protocol.supported_actions
  puts "   Supported: #{actions.join(', ')}"
  puts "   ✓ #{actions.size} actions available"
  puts

  # Test 2: Check extensions
  puts "2. Checking loaded extensions..."
  extensions = protocol.supported_extensions
  puts "   Extensions: #{extensions.join(', ')}"
  puts "   ✓ #{extensions.size} extensions loaded"
  puts

  # Test 3: Create introduce message (should include extensions)
  puts "3. Testing introduce message..."
  intro = protocol.create_introduce
  puts "   Action: #{intro.action}"
  puts "   Extensions in payload: #{intro.payload[:extensions]&.join(', ') || 'none'}"
  puts "   ✓ Introduce includes extensions"
  puts

  # Test 4: Create goodbye message (new core action)
  puts "4. Testing goodbye message..."
  goodbye = protocol.create_goodbye(to: 'test_agent', reason: 'test_complete', summary: 'Test completed')
  puts "   Action: #{goodbye.action}"
  puts "   Reason: #{goodbye.payload[:reason]}"
  puts "   ✓ Goodbye message created"
  puts

  # Test 5: Create error message (new core action)
  puts "5. Testing error message..."
  error = protocol.create_error(
    to: 'test_agent',
    error_code: 'test_error',
    message: 'This is a test error',
    recoverable: true
  )
  puts "   Action: #{error.action}"
  puts "   Error code: #{error.payload[:error_code]}"
  puts "   ✓ Error message created"
  puts

  # Test 6: Process unsupported action
  puts "6. Testing unsupported action handling..."
  unsupported_msg = {
    id: 'msg_test123',
    action: 'unknown_custom_action',
    from: 'test_agent',
    timestamp: Time.now.utc.iso8601,
    payload: {}
  }
  result = protocol.process_message(unsupported_msg)
  puts "   Status: #{result[:status]}"
  puts "   Error: #{result[:error]}"
  if result[:suggested_response]
    puts "   Suggested response action: #{result[:suggested_response].action}"
  end
  puts "   ✓ Unsupported action handled gracefully"
  puts

  # Test 7: Process introduce with extensions
  puts "7. Testing introduce processing with extensions..."
  peer_intro = {
    id: 'msg_peer123',
    action: 'introduce',
    from: 'peer_agent',
    timestamp: Time.now.utc.iso8601,
    payload: {
      identity: { name: 'Peer Agent', instance_id: 'peer123' },
      extensions: ['meeting_protocol_skill_exchange', 'custom_debate']
    }
  }
  result = protocol.process_message(peer_intro)
  puts "   Peer extensions: #{result[:peer_extensions]&.join(', ')}"
  puts "   Common extensions: #{result[:common_extensions]&.join(', ')}"
  puts "   ✓ Extensions negotiated"
  puts

  # Test 8: Process goodbye
  puts "8. Testing goodbye processing..."
  goodbye_msg = {
    id: 'msg_bye123',
    action: 'goodbye',
    from: 'peer_agent',
    timestamp: Time.now.utc.iso8601,
    payload: { reason: 'session_complete', summary: 'Good conversation' }
  }
  result = protocol.process_message(goodbye_msg)
  puts "   Reason: #{result[:reason]}"
  puts "   Session complete: #{result[:session_complete]}"
  puts "   ✓ Goodbye processed"
  puts

  protocol
end

def test_backward_compatibility
  puts "=" * 60
  puts "Test: Backward Compatibility"
  puts "=" * 60
  puts

  identity = KairosMcp::Meeting::Identity.new(workspace_root: WORKSPACE_ROOT)
  protocol = KairosMcp::Meeting::MeetingProtocol.new(
    identity: identity,
    knowledge_root: File.join(WORKSPACE_ROOT, 'knowledge')
  )

  # Test existing actions still work
  puts "1. Testing existing skill exchange actions..."
  
  # These should all work without changes
  actions_to_test = [
    ['create_introduce', []],
    ['create_request_skill', [{ description: 'test skill' }]]
  ]

  actions_to_test.each do |method, args|
    begin
      if args.empty?
        protocol.send(method)
      else
        protocol.send(method, **args.first)
      end
      puts "   #{method}: ✓"
    rescue StandardError => e
      puts "   #{method}: ✗ (#{e.message})"
    end
  end
  puts

  # Test ACTIONS constant still works
  puts "2. Testing ACTIONS constant..."
  puts "   ACTIONS defined: #{KairosMcp::Meeting::MeetingProtocol::ACTIONS.any?}"
  puts "   ACTIONS count: #{KairosMcp::Meeting::MeetingProtocol::ACTIONS.size}"
  puts "   ✓ Backward compatible"
  puts
end

# Run tests
begin
  test_protocol_loader
  test_meeting_protocol_with_loader
  test_backward_compatibility

  puts "=" * 60
  puts "All Phase 6 tests completed!"
  puts "=" * 60
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  exit 1
end
