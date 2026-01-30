#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration test for E2E encrypted message relay

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))

require 'kairos_mcp/meeting/crypto'
require 'kairos_mcp/meeting_place/message_relay'
require 'kairos_mcp/meeting_place/audit_logger'

class E2ERelayTest
  def initialize
    @passed = 0
    @failed = 0
  end

  def run_all
    puts "=" * 60
    puts "KairosChain E2E Message Relay Tests"
    puts "=" * 60
    puts

    test_relay_enqueue_dequeue
    test_e2e_encrypted_relay
    test_meeting_place_cannot_decrypt
    test_audit_log_contains_no_content
    test_ttl_expiration
    test_relay_stats

    puts
    puts "=" * 60
    puts "Results: #{@passed} passed, #{@failed} failed"
    puts "=" * 60

    @failed == 0
  end

  private

  def test_relay_enqueue_dequeue
    print "Testing relay enqueue/dequeue... "
    
    audit_logger = KairosMcp::MeetingPlace::AuditLogger.new
    relay = KairosMcp::MeetingPlace::MessageRelay.new(audit_logger: audit_logger)
    
    # Enqueue a message
    result = relay.enqueue(
      from: 'agent_A',
      to: 'agent_B',
      encrypted_blob: 'encrypted_content_here',
      blob_hash: 'sha256:abc123',
      message_type: 'test'
    )
    
    assert result[:relay_id].start_with?('relay_'), "Should have relay_id"
    assert result[:status] == 'queued', "Should be queued"
    
    # Dequeue
    received = relay.dequeue('agent_B')
    assert received[:count] == 1, "Should receive 1 message"
    assert received[:messages][0][:from] == 'agent_A', "From should be agent_A"
    assert received[:messages][0][:encrypted_blob] == 'encrypted_content_here', "Blob should match"
    
    # Queue should be empty now
    received_again = relay.dequeue('agent_B')
    assert received_again[:count] == 0, "Queue should be empty"
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_e2e_encrypted_relay
    print "Testing E2E encrypted relay... "
    
    # Create two agents with crypto
    agent_a = KairosMcp::Meeting::Crypto.new
    agent_b = KairosMcp::Meeting::Crypto.new
    
    # Create relay (simulating Meeting Place)
    audit_logger = KairosMcp::MeetingPlace::AuditLogger.new
    relay = KairosMcp::MeetingPlace::MessageRelay.new(audit_logger: audit_logger)
    
    # Agent A encrypts a message for Agent B
    original_message = { greeting: "Hello from A!", secret_data: [1, 2, 3] }
    encrypted = agent_a.encrypt(original_message, agent_b.export_public_key)
    
    # Agent A sends via relay (Meeting Place only sees encrypted blob)
    relay.enqueue(
      from: 'agent_A',
      to: 'agent_B',
      encrypted_blob: encrypted[:encrypted_blob],
      blob_hash: encrypted[:blob_hash],
      message_type: 'greeting'
    )
    
    # Agent B receives from relay
    received = relay.dequeue('agent_B')
    encrypted_blob = received[:messages][0][:encrypted_blob]
    
    # Agent B decrypts
    decrypted = agent_b.decrypt(encrypted_blob)
    
    assert decrypted[:greeting] == original_message[:greeting], "Message should match"
    assert decrypted[:secret_data] == original_message[:secret_data], "Data should match"
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_meeting_place_cannot_decrypt
    print "Testing that Meeting Place CANNOT decrypt messages... "
    
    agent_a = KairosMcp::Meeting::Crypto.new
    agent_b = KairosMcp::Meeting::Crypto.new
    meeting_place_crypto = KairosMcp::Meeting::Crypto.new  # Meeting Place's own key (if it had one)
    
    # Agent A encrypts for Agent B
    original_message = "Secret between A and B only"
    encrypted = agent_a.encrypt(original_message, agent_b.export_public_key)
    
    # Meeting Place tries to decrypt (should fail)
    begin
      meeting_place_crypto.decrypt(encrypted[:encrypted_blob])
      puts "FAILED: Meeting Place should NOT be able to decrypt"
      @failed += 1
    rescue OpenSSL::PKey::RSAError
      puts "PASSED (Meeting Place cannot decrypt - as designed)"
      @passed += 1
    rescue => e
      puts "PASSED (decryption failed with: #{e.class})"
      @passed += 1
    end
  end

  def test_audit_log_contains_no_content
    print "Testing that audit log contains NO content... "
    
    audit_logger = KairosMcp::MeetingPlace::AuditLogger.new
    relay = KairosMcp::MeetingPlace::MessageRelay.new(audit_logger: audit_logger)
    
    # Send some messages
    secret_content = "THIS IS SECRET AND SHOULD NOT BE LOGGED"
    agent_a = KairosMcp::Meeting::Crypto.new
    agent_b = KairosMcp::Meeting::Crypto.new
    encrypted = agent_a.encrypt(secret_content, agent_b.export_public_key)
    
    relay.enqueue(
      from: 'agent_A',
      to: 'agent_B',
      encrypted_blob: encrypted[:encrypted_blob],
      blob_hash: encrypted[:blob_hash],
      message_type: 'secret'
    )
    
    # Verify audit log does NOT contain the secret
    audit_logger.verify_no_content_logged
    
    entries = audit_logger.recent_entries
    entry_json = entries.to_s
    
    assert !entry_json.include?(secret_content), "Audit log should NOT contain message content"
    assert !entry_json.include?('THIS IS SECRET'), "Audit log should NOT contain any part of message"
    
    # But it should contain the hash
    assert entry_json.include?(encrypted[:blob_hash]), "Audit log should contain blob hash"
    
    puts "PASSED"
    @passed += 1
  rescue SecurityError => e
    puts "FAILED: Security violation - #{e.message}"
    @failed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_ttl_expiration
    print "Testing TTL expiration... "
    
    # Create relay with very short TTL (1 second)
    relay = KairosMcp::MeetingPlace::MessageRelay.new(
      config: { ttl_seconds: 1 }
    )
    
    relay.enqueue(
      from: 'agent_A',
      to: 'agent_B',
      encrypted_blob: 'test_blob',
      blob_hash: 'sha256:test',
      message_type: 'test'
    )
    
    # Verify message is there
    stats_before = relay.stats
    assert stats_before[:total_messages] == 1, "Should have 1 message"
    
    # Wait for expiration
    sleep 1.5
    
    # Cleanup expired
    relay.cleanup_expired
    
    # Message should be gone
    stats_after = relay.stats
    assert stats_after[:total_messages] == 0, "Message should be expired"
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_relay_stats
    print "Testing relay statistics... "
    
    audit_logger = KairosMcp::MeetingPlace::AuditLogger.new
    relay = KairosMcp::MeetingPlace::MessageRelay.new(audit_logger: audit_logger)
    
    # Add some messages
    3.times do |i|
      relay.enqueue(
        from: "agent_#{i}",
        to: 'agent_receiver',
        encrypted_blob: "blob_#{i}" * 100,
        blob_hash: "sha256:hash#{i}",
        message_type: 'test'
      )
    end
    
    stats = relay.stats
    
    assert stats[:total_messages] == 3, "Should have 3 messages"
    assert stats[:active_queues] == 1, "Should have 1 active queue"
    assert stats[:total_size_bytes] > 0, "Should have some size"
    assert stats[:average_size_bytes] > 0, "Should have average size"
    
    # Stats should NOT contain any message content
    stats_json = stats.to_s
    assert !stats_json.include?('blob_0'), "Stats should not contain blob content"
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def assert(condition, message = "Assertion failed")
    raise message unless condition
  end
end

if __FILE__ == $0
  exit(E2ERelayTest.new.run_all ? 0 : 1)
end
