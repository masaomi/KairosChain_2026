#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for KairosChain Meeting Protocol HTTP Server (Phase 3)
# Usage: 
#   1. Start the server: bin/kairos_meeting_server
#   2. Run this test: ruby test_http_server.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'net/http'
require 'json'
require 'uri'
require 'time'

BASE_URL = ENV['MEETING_SERVER_URL'] || 'http://localhost:8080'

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
  puts e.backtrace.first(3).join("\n")
end

def http_get(path)
  uri = URI.parse("#{BASE_URL}#{path}")
  response = Net::HTTP.get_response(uri)
  
  puts "GET #{path}"
  puts "Status: #{response.code}"
  
  if response.is_a?(Net::HTTPSuccess)
    data = JSON.parse(response.body, symbolize_names: true)
    puts JSON.pretty_generate(data)
    data
  else
    puts "Error: #{response.body}"
    nil
  end
rescue Errno::ECONNREFUSED
  puts "Connection refused. Is the server running?"
  puts "Start with: bin/kairos_meeting_server"
  nil
end

def http_post(path, body)
  uri = URI.parse("#{BASE_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  
  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request.body = JSON.generate(body)
  
  response = http.request(request)
  
  puts "POST #{path}"
  puts "Body: #{JSON.generate(body)[0, 100]}..."
  puts "Status: #{response.code}"
  
  if response.is_a?(Net::HTTPSuccess)
    data = JSON.parse(response.body, symbolize_names: true)
    puts JSON.pretty_generate(data)
    data
  else
    puts "Error: #{response.body}"
    nil
  end
rescue Errno::ECONNREFUSED
  puts "Connection refused. Is the server running?"
  puts "Start with: bin/kairos_meeting_server"
  nil
end

puts "KairosChain Meeting Protocol HTTP Server - Test"
puts "Base URL: #{BASE_URL}"
puts "Time: #{Time.now}"

# Test 1: Health Check
test_section("Health Check") do
  result = http_get('/health')
  if result && result[:status] == 'ok'
    puts "\n✓ Server is healthy"
  else
    puts "\n✗ Server health check failed"
    puts "Make sure the server is running: bin/kairos_meeting_server"
    exit 1
  end
end

# Test 2: Get Introduction
test_section("Get Introduction (GET)") do
  result = http_get('/meeting/v1/introduce')
  # Response format: { action: 'introduce', payload: { identity: {...}, ... } }
  identity = result&.dig(:payload, :identity)
  if identity
    puts "\n✓ Introduction received"
    puts "  Name: #{identity[:name]}"
    puts "  Instance ID: #{identity[:instance_id]}"
  else
    puts "\n✗ Failed to get introduction"
  end
end

# Test 3: Get Capabilities
test_section("Get Capabilities") do
  result = http_get('/meeting/v1/capabilities')
  if result && result[:meeting_protocol_version]
    puts "\n✓ Capabilities received"
    puts "  Protocol: #{result[:meeting_protocol_version]}"
    puts "  Actions: #{result[:supported_actions]&.join(', ')}"
  else
    puts "\n✗ Failed to get capabilities"
  end
end

# Test 4: Get Skills
test_section("Get Skills") do
  result = http_get('/meeting/v1/skills')
  if result
    puts "\n✓ Skills received"
    puts "  Count: #{result[:skills]&.length || 0}"
    puts "  Exchange policy: #{result[:exchange_policy][:allowed_formats]&.join(', ')}"
  else
    puts "\n✗ Failed to get skills"
  end
end

# Test 5: Post Introduction (simulate peer)
test_section("Post Introduction (simulate incoming peer)") do
  incoming_intro = {
    id: 'msg_test_001',
    action: 'introduce',
    from: 'peer_test_abc123',
    timestamp: Time.now.utc.iso8601,
    payload: {
      identity: {
        name: 'Test Peer',
        description: 'A test KairosChain instance',
        scope: 'testing',
        version: '0.4.0',
        instance_id: 'peer_test_abc123'
      },
      capabilities: {
        meeting_protocol_version: '1.0.0',
        supported_actions: %w[introduce offer_skill request_skill],
        skill_formats: %w[markdown]
      }
    },
    protocol_version: '1.0.0'
  }
  
  result = http_post('/meeting/v1/introduce', incoming_intro)
  if result && result[:status] == 'received'
    puts "\n✓ Introduction processed"
    puts "  Peer: #{result[:from]}"
  else
    puts "\n✗ Failed to process introduction"
  end
end

# Test 6: Request Skill
test_section("Create Request Skill") do
  result = http_post('/meeting/v1/request_skill', {
    description: 'Looking for skills about data analysis',
    to: 'peer_test_abc123'
  })
  
  if result && result[:message]
    puts "\n✓ Request skill message created"
    puts "  Message ID: #{result[:message][:id]}"
    $test_message_id = result[:message][:id]
  else
    puts "\n✗ Failed to create request skill message"
  end
end

# Test 7: Create Accept
test_section("Create Accept Message") do
  result = http_post('/meeting/v1/accept', {
    in_reply_to: $test_message_id || 'msg_test',
    to: 'peer_test_abc123'
  })
  
  if result && result[:message]
    puts "\n✓ Accept message created"
  else
    puts "\n✗ Failed to create accept message"
  end
end

# Test 8: Create Reflect
test_section("Create Reflect Message") do
  result = http_post('/meeting/v1/reflect', {
    to: 'peer_test_abc123',
    reflection: 'Thank you for the interaction!',
    in_reply_to: $test_message_id
  })
  
  if result && result[:message]
    puts "\n✓ Reflect message created"
  else
    puts "\n✗ Failed to create reflect message"
  end
end

# Test 9: Start Session
test_section("Start Session") do
  result = http_post('/meeting/v1/session/start', {
    peer_id: 'peer_test_abc123'
  })
  
  if result && result[:session_id]
    puts "\n✓ Session started"
    puts "  Session ID: #{result[:session_id]}"
  else
    puts "\n✗ Failed to start session"
  end
end

# Test 10: End Session
test_section("End Session") do
  result = http_post('/meeting/v1/session/end', {
    summary: 'Test session completed'
  })
  
  if result
    puts "\n✓ Session ended"
  else
    puts "\n✗ Failed to end session"
  end
end

# Test 11: Get History
test_section("Get Interaction History") do
  result = http_get('/meeting/v1/history?limit=10')
  
  if result
    puts "\n✓ History retrieved"
    puts "  Total: #{result[:summary][:total_interactions]}"
    puts "  Unique peers: #{result[:summary][:unique_peers]}"
  else
    puts "\n✗ Failed to get history"
  end
end

separator
puts "\nPhase 3 HTTP Server Tests Complete!"
puts "\nSummary:"
puts "  - Server URL: #{BASE_URL}"
puts "  - All core endpoints tested"
puts "\nFor P2P testing with a friend:"
puts "  1. Start your server: bin/kairos_meeting_server"
puts "  2. Friend creates SSH tunnel: ssh -L 9999:localhost:8080 you@your-ip"
puts "  3. Friend tests: curl http://localhost:9999/meeting/v1/introduce"
