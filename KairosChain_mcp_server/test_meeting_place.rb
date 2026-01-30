#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for KairosChain Meeting Place Server (Phase 4)
# Usage:
#   1. Start the server: bin/kairos_meeting_place
#   2. Run this test: ruby test_meeting_place.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'net/http'
require 'json'
require 'uri'
require 'time'

BASE_URL = ENV['MEETING_PLACE_URL'] || 'http://localhost:8888'

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
  puts "Connection refused. Is the Meeting Place server running?"
  puts "Start with: bin/kairos_meeting_place"
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
  puts "Body: #{JSON.generate(body)[0, 80]}..."
  puts "Status: #{response.code}"

  if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
    data = JSON.parse(response.body, symbolize_names: true)
    puts JSON.pretty_generate(data)
    data
  else
    puts "Error: #{response.body}"
    nil
  end
rescue Errno::ECONNREFUSED
  puts "Connection refused. Is the Meeting Place server running?"
  nil
end

puts "KairosChain Meeting Place Server - Test"
puts "Base URL: #{BASE_URL}"
puts "Time: #{Time.now}"

# Test 1: Health Check
test_section("Health Check") do
  result = http_get('/health')
  if result && result[:status] == 'ok'
    puts "\n✓ Server is healthy"
    puts "  Place: #{result[:place]}"
  else
    puts "\n✗ Server health check failed"
    puts "Make sure the server is running: bin/kairos_meeting_place"
    exit 1
  end
end

# Test 2: Place Info
test_section("Place Info") do
  result = http_get('/place/v1/info')
  if result && result[:name]
    puts "\n✓ Place info received"
    puts "  Name: #{result[:name]}"
    puts "  Features: #{result[:features]&.join(', ')}"
  else
    puts "\n✗ Failed to get place info"
  end
end

# Test 3: Register Agent
$agent_id = nil
test_section("Register Agent") do
  result = http_post('/place/v1/register', {
    name: 'Test Agent Alpha',
    description: 'A test KairosChain agent',
    scope: 'testing',
    capabilities: {
      meeting_protocol_version: '1.0.0',
      supported_actions: %w[introduce offer_skill request_skill]
    },
    endpoint: 'http://localhost:8080'
  })

  if result && result[:agent_id]
    $agent_id = result[:agent_id]
    puts "\n✓ Agent registered"
    puts "  Agent ID: #{$agent_id}"
  else
    puts "\n✗ Failed to register agent"
  end
end

# Test 4: Register Second Agent
$agent_id_2 = nil
test_section("Register Second Agent") do
  result = http_post('/place/v1/register', {
    name: 'Test Agent Beta',
    description: 'Another test KairosChain agent',
    scope: 'bioinformatics',
    capabilities: {
      meeting_protocol_version: '1.0.0',
      supported_actions: %w[introduce offer_skill discuss]
    },
    endpoint: 'http://localhost:9090'
  })

  if result && result[:agent_id]
    $agent_id_2 = result[:agent_id]
    puts "\n✓ Second agent registered"
    puts "  Agent ID: #{$agent_id_2}"
  else
    puts "\n✗ Failed to register second agent"
  end
end

# Test 5: List Agents
test_section("List All Agents") do
  result = http_get('/place/v1/agents')
  if result && result[:agents]
    puts "\n✓ Agent list received"
    puts "  Count: #{result[:count]}"
    result[:agents].each do |agent|
      puts "  - #{agent[:name]} (#{agent[:scope]})"
    end
  else
    puts "\n✗ Failed to list agents"
  end
end

# Test 6: Filter Agents by Scope
test_section("Filter Agents by Scope") do
  result = http_get('/place/v1/agents?scope=bioinformatics')
  if result
    puts "\n✓ Filtered agents received"
    puts "  Count: #{result[:count]}"
  else
    puts "\n✗ Failed to filter agents"
  end
end

# Test 7: Heartbeat
test_section("Agent Heartbeat") do
  result = http_post('/place/v1/heartbeat', { agent_id: $agent_id })
  if result && result[:status] == 'active'
    puts "\n✓ Heartbeat successful"
  else
    puts "\n✗ Heartbeat failed"
  end
end

# Test 8: Post Skill Offer
$posting_id = nil
test_section("Post Skill Offer") do
  result = http_post('/place/v1/board/post', {
    agent_id: $agent_id,
    agent_name: 'Test Agent Alpha',
    type: 'offer_skill',
    skill_name: 'Japanese-English Translation',
    skill_summary: 'High-quality translation between Japanese and English',
    skill_format: 'markdown',
    tags: %w[translation japanese english nlp]
  })

  if result && result[:posting_id]
    $posting_id = result[:posting_id]
    puts "\n✓ Skill offer posted"
    puts "  Posting ID: #{$posting_id}"
    puts "  Expires: #{result[:expires_at]}"
  else
    puts "\n✗ Failed to post skill offer"
  end
end

# Test 9: Post Skill Request
$request_posting_id = nil
test_section("Post Skill Request") do
  result = http_post('/place/v1/board/post', {
    agent_id: $agent_id_2,
    agent_name: 'Test Agent Beta',
    type: 'request_skill',
    skill_name: 'RNA-seq Analysis',
    skill_summary: 'Looking for RNA-seq analysis pipeline guidance',
    skill_format: 'markdown',
    tags: %w[bioinformatics rnaseq genomics]
  })

  if result && result[:posting_id]
    $request_posting_id = result[:posting_id]
    puts "\n✓ Skill request posted"
    puts "  Posting ID: #{$request_posting_id}"
  else
    puts "\n✗ Failed to post skill request"
  end
end

# Test 10: Browse All Postings
test_section("Browse All Postings") do
  result = http_get('/place/v1/board/browse')
  if result && result[:postings]
    puts "\n✓ Postings received"
    puts "  Count: #{result[:count]}"
    result[:postings].each do |p|
      puts "  - [#{p[:type]}] #{p[:skill_name]} by #{p[:agent_name]}"
    end
  else
    puts "\n✗ Failed to browse postings"
  end
end

# Test 11: Browse Skill Offers Only
test_section("Browse Skill Offers Only") do
  result = http_get('/place/v1/board/browse?type=offer_skill')
  if result
    puts "\n✓ Filtered postings received"
    puts "  Offers count: #{result[:count]}"
  else
    puts "\n✗ Failed to filter postings"
  end
end

# Test 12: Search Postings
test_section("Search Postings") do
  result = http_get('/place/v1/board/browse?search=translation')
  if result
    puts "\n✓ Search results received"
    puts "  Results: #{result[:count]}"
  else
    puts "\n✗ Failed to search postings"
  end
end

# Test 13: Get Specific Posting
test_section("Get Specific Posting") do
  result = http_get("/place/v1/board/posting/#{$posting_id}")
  if result && result[:id]
    puts "\n✓ Posting retrieved"
    puts "  Name: #{result[:skill_name]}"
    puts "  Summary: #{result[:skill_summary]}"
  else
    puts "\n✗ Failed to get posting"
  end
end

# Test 14: Get My Postings
test_section("Get My Postings") do
  result = http_get("/place/v1/board/my_postings?agent_id=#{$agent_id}")
  if result
    puts "\n✓ My postings retrieved"
    puts "  Count: #{result[:count]}"
  else
    puts "\n✗ Failed to get my postings"
  end
end

# Test 15: Stats
test_section("Place Statistics") do
  result = http_get('/place/v1/stats')
  if result
    puts "\n✓ Stats received"
    puts "  Registry:"
    puts "    Total agents: #{result.dig(:registry, :total_agents)}"
    puts "  Bulletin Board:"
    puts "    Total postings: #{result.dig(:bulletin_board, :total_postings)}"
    puts "    By type: #{result.dig(:bulletin_board, :by_type)}"
  else
    puts "\n✗ Failed to get stats"
  end
end

# Test 16: Remove Posting
test_section("Remove Posting") do
  result = http_post('/place/v1/board/remove', {
    posting_id: $posting_id,
    agent_id: $agent_id
  })

  if result && result[:status] == 'removed'
    puts "\n✓ Posting removed"
  else
    puts "\n✗ Failed to remove posting"
  end
end

# Test 17: Unregister Agent
test_section("Unregister Agent") do
  result = http_post('/place/v1/unregister', { agent_id: $agent_id })
  if result && result[:status] == 'unregistered'
    puts "\n✓ Agent unregistered"
    puts "  Was registered for: #{result[:was_registered_for]} seconds"
  else
    puts "\n✗ Failed to unregister agent"
  end
end

# Test 18: Final Agent Count
test_section("Final Agent Count") do
  result = http_get('/place/v1/agents')
  if result
    puts "\n✓ Final agent count: #{result[:count]}"
    puts "  (Should be 1 - only Agent Beta remains)"
  else
    puts "\n✗ Failed to get final count"
  end
end

separator
puts "\nPhase 4 Meeting Place Tests Complete!"
puts "\nSummary:"
puts "  - Server URL: #{BASE_URL}"
puts "  - Registry and Bulletin Board tested"
puts "\nTo run the Meeting Place server:"
puts "  bin/kairos_meeting_place"
puts "\nTo connect from a KairosChain instance:"
puts "  Use PlaceClient in lib/kairos_mcp/meeting/place_client.rb"
