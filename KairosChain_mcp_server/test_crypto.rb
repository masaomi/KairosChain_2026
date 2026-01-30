#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for E2E encryption (crypto.rb)

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))

require 'kairos_mcp/meeting/crypto'

class CryptoTest
  def initialize
    @passed = 0
    @failed = 0
  end

  def run_all
    puts "=" * 60
    puts "KairosChain E2E Encryption Tests"
    puts "=" * 60
    puts

    test_keypair_generation
    test_encrypt_decrypt
    test_cannot_decrypt_without_private_key
    test_third_party_cannot_decrypt
    test_hash_verification
    test_keypair_save_load
    test_signing
    test_large_message

    puts
    puts "=" * 60
    puts "Results: #{@passed} passed, #{@failed} failed"
    puts "=" * 60

    @failed == 0
  end

  private

  def test_keypair_generation
    print "Testing keypair generation... "
    
    crypto = KairosMcp::Meeting::Crypto.new
    
    assert crypto.has_keypair?, "Should have complete keypair"
    assert !crypto.export_public_key.nil?, "Should export public key"
    assert crypto.export_public_key.include?('BEGIN PUBLIC KEY'), "Public key should be PEM format"
    
    fingerprint = crypto.key_fingerprint
    assert fingerprint.include?(':'), "Fingerprint should be colon-separated"
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_encrypt_decrypt
    print "Testing encrypt/decrypt round trip... "
    
    # Agent A generates keypair
    agent_a = KairosMcp::Meeting::Crypto.new
    
    # Agent B generates keypair
    agent_b = KairosMcp::Meeting::Crypto.new
    
    # Agent A encrypts message for Agent B
    original_message = { greeting: "Hello, Agent B!", data: [1, 2, 3] }
    encrypted = agent_a.encrypt(original_message, agent_b.export_public_key)
    
    assert encrypted[:encrypted_blob], "Should have encrypted blob"
    assert encrypted[:blob_hash].start_with?('sha256:'), "Should have hash"
    assert encrypted[:size_bytes] > 0, "Should have size"
    
    # Agent B decrypts the message
    decrypted = agent_b.decrypt(encrypted[:encrypted_blob])
    
    assert decrypted[:greeting] == original_message[:greeting], "Message content should match"
    assert decrypted[:data] == original_message[:data], "Message data should match"
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_cannot_decrypt_without_private_key
    print "Testing that encryption is one-way without private key... "
    
    agent_a = KairosMcp::Meeting::Crypto.new
    agent_b = KairosMcp::Meeting::Crypto.new
    
    message = "Secret message"
    encrypted = agent_a.encrypt(message, agent_b.export_public_key)
    
    # Agent A should NOT be able to decrypt (they don't have B's private key)
    begin
      agent_a.decrypt(encrypted[:encrypted_blob])
      puts "FAILED: Should not be able to decrypt without recipient's private key"
      @failed += 1
    rescue OpenSSL::PKey::RSAError
      puts "PASSED"
      @passed += 1
    rescue => e
      puts "PASSED (different error: #{e.class})"
      @passed += 1
    end
  end

  def test_third_party_cannot_decrypt
    print "Testing that third party cannot decrypt... "
    
    agent_a = KairosMcp::Meeting::Crypto.new
    agent_b = KairosMcp::Meeting::Crypto.new
    agent_c = KairosMcp::Meeting::Crypto.new  # Third party
    
    message = "Secret between A and B"
    encrypted = agent_a.encrypt(message, agent_b.export_public_key)
    
    # Agent C should NOT be able to decrypt
    begin
      agent_c.decrypt(encrypted[:encrypted_blob])
      puts "FAILED: Third party should not be able to decrypt"
      @failed += 1
    rescue OpenSSL::PKey::RSAError
      puts "PASSED"
      @passed += 1
    rescue => e
      puts "PASSED (different error: #{e.class})"
      @passed += 1
    end
  end

  def test_hash_verification
    print "Testing blob hash verification... "
    
    agent_a = KairosMcp::Meeting::Crypto.new
    agent_b = KairosMcp::Meeting::Crypto.new
    
    encrypted = agent_a.encrypt("Test message", agent_b.export_public_key)
    
    # Verify hash
    assert KairosMcp::Meeting::Crypto.verify_hash(encrypted[:encrypted_blob], encrypted[:blob_hash]),
           "Hash should verify"
    
    # Tampered blob should fail verification
    tampered_blob = encrypted[:encrypted_blob] + "tamper"
    assert !KairosMcp::Meeting::Crypto.verify_hash(tampered_blob, encrypted[:blob_hash]),
           "Tampered blob should fail verification"
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_keypair_save_load
    print "Testing keypair save/load... "
    
    # Generate and save
    crypto1 = KairosMcp::Meeting::Crypto.new
    original_fingerprint = crypto1.key_fingerprint
    
    temp_path = "/tmp/test_kairos_keypair_#{$$}.pem"
    crypto1.save_keypair(temp_path)
    
    # Load into new instance
    crypto2 = KairosMcp::Meeting::Crypto.new(keypair_path: temp_path, auto_generate: false)
    loaded_fingerprint = crypto2.key_fingerprint
    
    assert original_fingerprint == loaded_fingerprint, "Fingerprints should match after load"
    
    # Verify encryption still works
    message = "Test after reload"
    encrypted = crypto1.encrypt(message, crypto2.export_public_key)
    decrypted = crypto2.decrypt(encrypted[:encrypted_blob])
    
    assert decrypted == message, "Should decrypt after reload"
    
    # Cleanup
    File.delete(temp_path) if File.exist?(temp_path)
    File.delete("#{temp_path}.pub") if File.exist?("#{temp_path}.pub")
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_signing
    print "Testing message signing and verification... "
    
    agent_a = KairosMcp::Meeting::Crypto.new
    
    message = { important: "This must not be tampered with" }
    signature = agent_a.sign(message)
    
    # Verify with sender's public key
    assert agent_a.verify_signature(message, signature), "Signature should verify"
    
    # Tampered message should fail
    tampered = { important: "Tampered!" }
    assert !agent_a.verify_signature(tampered, signature), "Tampered message should fail"
    
    # Wrong key should fail
    agent_b = KairosMcp::Meeting::Crypto.new
    assert !agent_a.verify_signature(message, signature, agent_b.export_public_key),
           "Wrong key should fail verification"
    
    puts "PASSED"
    @passed += 1
  rescue => e
    puts "FAILED: #{e.message}"
    @failed += 1
  end

  def test_large_message
    print "Testing large message encryption... "
    
    agent_a = KairosMcp::Meeting::Crypto.new
    agent_b = KairosMcp::Meeting::Crypto.new
    
    # Create a large message (100KB)
    large_message = "x" * 100_000
    
    encrypted = agent_a.encrypt(large_message, agent_b.export_public_key)
    decrypted = agent_b.decrypt(encrypted[:encrypted_blob])
    
    assert decrypted == large_message, "Large message should decrypt correctly"
    assert encrypted[:size_bytes] > 100_000, "Encrypted size should be larger than plaintext"
    
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
  exit(CryptoTest.new.run_all ? 0 : 1)
end
