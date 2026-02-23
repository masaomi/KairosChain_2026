#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# Phase 4B: Meeting Place Server Test
# ============================================================================
# Tests for the Hestia Meeting Place components:
#   1. AgentRegistry (register, unregister, self_register, persistence)
#   2. SkillBoard (browse, random sample, filters)
#   3. HeartbeatManager (TTL check, touch, fadeout recording)
#   4. PlaceRouter (HTTP endpoints, auth, self-registration)
#   5. MCP Tools & SkillSet Discovery
#
# Usage:
#   ruby test_09_meeting_place.rb
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/mmp/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/hestia/lib', __dir__)

require 'kairos_mcp'
require 'mmp'
require 'mmp/meeting_session_store'
require 'hestia'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'

$pass_count = 0
$fail_count = 0
$section_pass = 0
$section_fail = 0

def assert(msg)
  result = yield
  if result
    puts "  PASS: #{msg}"
    $pass_count += 1
    $section_pass += 1
  else
    puts "  FAIL: #{msg}"
    $fail_count += 1
    $section_fail += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail_count += 1
  $section_fail += 1
end

def section(name)
  $section_pass = 0
  $section_fail = 0
  puts "\n--- #{name} ---"
  yield
  puts "  Section: #{$section_pass} passed, #{$section_fail} failed"
end

# Helper: create a mock Identity that returns a known introduce hash
def mock_identity(name: 'TestAgent', instance_id: 'test-agent-001')
  config = {
    'enabled' => true,
    'identity' => {
      'name' => name,
      'instance_id' => instance_id
    },
    'capabilities' => {
      'supported_actions' => %w[meeting_protocol skill_exchange],
      'skill_formats' => %w[ruby_dsl yaml]
    }
  }
  MMP::Identity.new(config: config)
end

# Helper: build a Rack-compatible env hash
def rack_env(method, path, body: nil, bearer_token: nil, query: nil)
  env = {
    'REQUEST_METHOD' => method,
    'PATH_INFO' => path,
    'QUERY_STRING' => query || '',
    'HTTP_AUTHORIZATION' => bearer_token ? "Bearer #{bearer_token}" : nil
  }
  if body
    env['rack.input'] = StringIO.new(JSON.generate(body))
    env['CONTENT_TYPE'] = 'application/json'
  else
    env['rack.input'] = StringIO.new('')
  end
  env
end

puts "=" * 60
puts "Phase 4B: Meeting Place Server Tests"
puts "=" * 60

# ==========================================================================
# Section 1: AgentRegistry
# ==========================================================================
section("1. AgentRegistry") do
  Dir.mktmpdir do |dir|
    registry_path = File.join(dir, 'agents.json')
    registry = Hestia::AgentRegistry.new(registry_path: registry_path)

    # 1.1 Register an agent
    result = registry.register(id: 'agent-a', name: 'Agent A', capabilities: { supported_actions: ['test'] })
    assert("register returns status 'registered'") { result[:status] == 'registered' }

    # 1.2 Count
    assert("count is 1 after register") { registry.count == 1 }

    # 1.3 Get agent
    agent = registry.get('agent-a')
    assert("get returns agent with correct name") { agent[:name] == 'Agent A' }

    # 1.4 Register second agent
    registry.register(id: 'agent-b', name: 'Agent B', public_key: 'PEM_KEY_HERE')
    assert("count is 2 after second register") { registry.count == 2 }

    # 1.5 Update existing
    result2 = registry.register(id: 'agent-a', name: 'Agent A Updated')
    assert("re-register returns 'updated'") { result2[:status] == 'updated' }
    assert("name updated after re-register") { registry.get('agent-a')[:name] == 'Agent A Updated' }

    # 1.6 Unregister
    unreg = registry.unregister('agent-b')
    assert("unregister returns status 'unregistered'") { unreg[:status] == 'unregistered' }
    assert("count decreases after unregister") { registry.count == 1 }

    # 1.7 Unregister non-existent
    unreg2 = registry.unregister('no-such-agent')
    assert("unregister non-existent returns 'not_found'") { unreg2[:status] == 'not_found' }

    # 1.8 Self-register
    identity = mock_identity(name: 'PlaceSelf')
    intro = identity.introduce
    self_id = intro.dig(:identity, :instance_id)
    registry.self_register(identity)
    self_agent = registry.get(self_id)
    assert("self_register creates agent with is_self=true") { self_agent && self_agent[:is_self] == true }

    # 1.9 List with/without self
    all = registry.list(include_self: true)
    no_self = registry.list(include_self: false)
    assert("list include_self: true includes self agent") { all.any? { |a| a[:is_self] } }
    assert("list include_self: false excludes self agent") { no_self.none? { |a| a[:is_self] } }

    # 1.10 Public key
    registry.register(id: 'key-agent', name: 'KeyAgent', public_key: 'RSA_PUB_KEY')
    assert("public_key_for returns stored key") { registry.public_key_for('key-agent') == 'RSA_PUB_KEY' }

    # 1.11 Heartbeat
    old_hb = registry.get('agent-a')[:last_heartbeat]
    sleep 1.1  # Ensure timestamp changes (ISO8601 has 1-second granularity)
    registry.heartbeat('agent-a')
    new_hb = registry.get('agent-a')[:last_heartbeat]
    assert("heartbeat updates last_heartbeat") { new_hb != old_hb }

    # 1.12 Persistence: reload from file
    registry2 = Hestia::AgentRegistry.new(registry_path: registry_path)
    assert("persistence: reloaded registry has same count") { registry2.count == registry.count }
    assert("persistence: reloaded agent has correct name") { registry2.get('agent-a')[:name] == 'Agent A Updated' }

    # 1.13 visited_places field
    registry.register(id: 'traveler', name: 'Traveler', visited_places: ['http://place1.example.com'])
    traveler = registry.get('traveler')
    assert("visited_places stored on register") { traveler[:visited_places] == ['http://place1.example.com'] }
  end
end

# ==========================================================================
# Section 2: SkillBoard
# ==========================================================================
section("2. SkillBoard") do
  Dir.mktmpdir do |dir|
    registry = Hestia::AgentRegistry.new(registry_path: File.join(dir, 'agents.json'))
    registry.register(
      id: 'board-agent-1', name: 'BoardAgent1',
      capabilities: { supported_actions: %w[skill_exchange meeting_protocol], skill_formats: %w[ruby_dsl] }
    )
    registry.register(
      id: 'board-agent-2', name: 'BoardAgent2',
      capabilities: { supported_actions: %w[chain_anchor], skill_formats: %w[yaml] }
    )
    board = Hestia::SkillBoard.new(registry: registry)

    # 2.1 Browse returns all entries
    result = board.browse
    assert("browse returns entries") { result[:entries].is_a?(Array) && result[:entries].size == 2 }
    assert("browse total_available matches") { result[:total_available] == 2 }

    # 2.2 Sampling mode
    assert("sampling is 'all_shuffled' when under limit") { result[:sampling] == 'all_shuffled' }

    # 2.3 Search filter
    search_result = board.browse(search: 'BoardAgent1')
    assert("search filter returns matching agent") { search_result[:total_available] == 1 }

    # 2.4 agents_contributing count
    assert("agents_contributing count is correct") { result[:agents_contributing] == 2 }

    # 2.5 No ranking: entries are shuffled (statistical test — run 5 times, check at least one different order)
    orders = 5.times.map { board.browse[:entries].map { |e| e[:agent_id] } }
    # With only 2 entries, probability of same order 5 times = (1/2)^4 = 6.25%
    # Accept even if all same (random can do that), just verify structure
    assert("browse always returns valid entries") { orders.all? { |o| o.size == 2 } }
  end
end

# ==========================================================================
# Section 3: HeartbeatManager
# ==========================================================================
section("3. HeartbeatManager") do
  Dir.mktmpdir do |dir|
    registry = Hestia::AgentRegistry.new(registry_path: File.join(dir, 'agents.json'))
    registry.register(id: 'hb-agent-1', name: 'HBAgent1')
    registry.register(id: 'hb-agent-2', name: 'HBAgent2')

    # Use 2-second TTL for testing
    hb = Hestia::HeartbeatManager.new(registry: registry, ttl_seconds: 2)

    # 3.1 touch extends TTL
    hb.touch('hb-agent-1')
    status = hb.ttl_status('hb-agent-1')
    assert("ttl_status returns agent info") { status && status[:agent_id] == 'hb-agent-1' }
    assert("ttl_status shows not expired after touch") { status[:expired] == false }

    # 3.2 check_all before expiry
    result_before = hb.check_all
    assert("check_all: no expired agents before TTL") { result_before[:expired_count] == 0 }

    # 3.3 Wait for TTL to expire, then check
    sleep 2.1
    result_after = hb.check_all
    assert("check_all: agents expired after TTL") { result_after[:expired_count] == 2 }
    assert("check_all: expired list contains agent IDs") { result_after[:expired].include?('hb-agent-1') }

    # 3.4 Registry cleaned up
    assert("registry empty after expiry") { registry.count == 0 }

    # 3.5 ttl_status for non-existent agent
    assert("ttl_status nil for unknown agent") { hb.ttl_status('no-such') == nil }
  end
end

# ==========================================================================
# Section 4: PlaceRouter (HTTP endpoint tests)
# ==========================================================================
section("4. PlaceRouter (HTTP endpoints)") do
  Dir.mktmpdir do |dir|
    config = {
      'meeting_place' => {
        'name' => 'Test Meeting Place',
        'max_agents' => 10,
        'session_timeout' => 3600,
        'registry_path' => File.join(dir, 'agents.json')
      }
    }

    router = Hestia::PlaceRouter.new(config: config)
    identity = mock_identity(name: 'TestPlace')
    session_store = MMP::MeetingSessionStore.new

    # 4.1 Not started → 503
    status, _headers, body = router.call(rack_env('GET', '/place/v1/info'))
    assert("returns 503 before start") { status == 503 }

    # 4.2 Start the PlaceRouter
    start_result = router.start(identity: identity, session_store: session_store)
    assert("start returns status 'started'") { start_result[:status] == 'started' }
    assert("start includes self_id (non-nil)") { !start_result[:self_id].nil? && !start_result[:self_id].empty? }
    assert("start registers self (count >= 1)") { start_result[:registered_agents] >= 1 }

    # 4.3 GET /place/v1/info (unauthenticated)
    status, _headers, body = router.call(rack_env('GET', '/place/v1/info'))
    info = JSON.parse(body.first, symbolize_names: true)
    assert("GET /place/v1/info returns 200") { status == 200 }
    assert("info includes place name") { info[:name] == 'Test Meeting Place' }
    assert("info includes registered_agents count") { info[:registered_agents] >= 1 }

    # 4.4 POST /place/v1/register (no RSA signature → registers but unverified)
    status, _headers, body = router.call(rack_env('POST', '/place/v1/register', body: {
      'id' => 'ext-agent-1',
      'name' => 'External Agent 1',
      'capabilities' => { 'supported_actions' => ['test'] }
    }))
    reg_result = JSON.parse(body.first, symbolize_names: true)
    assert("POST /place/v1/register returns 200") { status == 200 }
    assert("register returns agent_id") { reg_result[:agent_id] == 'ext-agent-1' }
    assert("register without sig: identity_verified = false") { reg_result[:identity_verified] == false }
    assert("register without sig: no session_token") { reg_result[:session_token].nil? }

    # 4.5 Authenticated endpoints without token → 401
    status, _headers, body = router.call(rack_env('GET', '/place/v1/agents'))
    assert("GET /agents without token returns 401") { status == 401 }

    # 4.6 Create a session token manually for testing
    token = session_store.create_session('ext-agent-1', nil)

    # 4.7 GET /place/v1/agents (with token)
    status, _headers, body = router.call(rack_env('GET', '/place/v1/agents', bearer_token: token))
    agents_result = JSON.parse(body.first, symbolize_names: true)
    assert("GET /agents with token returns 200") { status == 200 }
    assert("agents list includes self") { agents_result[:agents].any? { |a| a[:is_self] } }
    assert("agents list includes registered agent") { agents_result[:agents].any? { |a| a[:id] == 'ext-agent-1' } }

    # 4.8 GET /place/v1/board/browse
    status, _headers, body = router.call(rack_env('GET', '/place/v1/board/browse', bearer_token: token))
    browse_result = JSON.parse(body.first, symbolize_names: true)
    assert("GET /board/browse returns 200") { status == 200 }
    assert("board browse has entries") { browse_result[:entries].is_a?(Array) }

    # 4.9 GET /place/v1/keys/:id
    # Register an agent with a public key first
    router.call(rack_env('POST', '/place/v1/register', body: {
      'id' => 'key-holder',
      'name' => 'KeyHolder',
      'public_key' => 'RSA_PUB_KEY_DATA'
    }))
    status, _headers, body = router.call(rack_env('GET', '/place/v1/keys/key-holder', bearer_token: token))
    key_result = JSON.parse(body.first, symbolize_names: true)
    assert("GET /keys/:id returns 200") { status == 200 }
    assert("GET /keys/:id returns correct key") { key_result[:public_key] == 'RSA_PUB_KEY_DATA' }

    # 4.10 GET /keys for unknown agent → 404
    status, _headers, body = router.call(rack_env('GET', '/place/v1/keys/no-such', bearer_token: token))
    assert("GET /keys for unknown agent returns 404") { status == 404 }

    # 4.11 POST /place/v1/unregister
    status, _headers, body = router.call(rack_env('POST', '/place/v1/unregister',
      body: { 'agent_id' => 'ext-agent-1' }, bearer_token: token))
    unreg_result = JSON.parse(body.first, symbolize_names: true)
    assert("POST /unregister returns 200") { status == 200 }
    assert("unregister result status") { unreg_result[:status] == 'unregistered' }

    # 4.12 Unknown endpoint → 404
    status, _headers, _body = router.call(rack_env('GET', '/place/v1/unknown', bearer_token: token))
    assert("unknown endpoint returns 404") { status == 404 }

    # 4.13 Place is full → 503
    config_full = config.dup
    config_full['meeting_place'] = config_full['meeting_place'].merge('max_agents' => 3, 'registry_path' => File.join(dir, 'full.json'))
    full_router = Hestia::PlaceRouter.new(config: config_full)
    full_router.start(identity: identity, session_store: session_store)
    # Self + 2 more = 3 (max)
    full_router.call(rack_env('POST', '/place/v1/register', body: { 'id' => 'fill-1', 'name' => 'Fill1' }))
    full_router.call(rack_env('POST', '/place/v1/register', body: { 'id' => 'fill-2', 'name' => 'Fill2' }))
    status, _headers, body = full_router.call(rack_env('POST', '/place/v1/register', body: { 'id' => 'overflow', 'name' => 'Overflow' }))
    assert("register when full returns 503") { status == 503 }

    # 4.14 PlaceRouter#status
    place_status = router.status
    assert("status returns started: true") { place_status[:started] == true }
    assert("status includes place_name") { place_status[:place_name] == 'Test Meeting Place' }
    assert("status includes uptime_seconds") { place_status[:uptime_seconds].is_a?(Integer) }
  end
end

# ==========================================================================
# Section 5: MCP Tools & SkillSet Discovery
# ==========================================================================
section("5. MCP Tools & SkillSet Discovery") do
  # 5.1 skillset.json includes new tools
  skillset_path = File.join(__dir__, 'templates/skillsets/hestia/skillset.json')
  skillset = JSON.parse(File.read(skillset_path))
  assert("skillset.json has MeetingPlaceStart tool") {
    skillset['tool_classes'].include?('KairosMcp::SkillSets::Hestia::Tools::MeetingPlaceStart')
  }
  assert("skillset.json has MeetingPlaceStatus tool") {
    skillset['tool_classes'].include?('KairosMcp::SkillSets::Hestia::Tools::MeetingPlaceStatus')
  }
  assert("skillset.json has 6 total tool classes") { skillset['tool_classes'].size == 6 }

  # 5.2 Tool class loading
  require_relative 'lib/kairos_mcp/tools/base_tool'
  require_relative 'templates/skillsets/hestia/tools/meeting_place_start'
  require_relative 'templates/skillsets/hestia/tools/meeting_place_status'

  start_tool = KairosMcp::SkillSets::Hestia::Tools::MeetingPlaceStart.new
  status_tool = KairosMcp::SkillSets::Hestia::Tools::MeetingPlaceStatus.new

  assert("MeetingPlaceStart tool name") { start_tool.name == 'meeting_place_start' }
  assert("MeetingPlaceStatus tool name") { status_tool.name == 'meeting_place_status' }
  assert("MeetingPlaceStart has input_schema") { start_tool.input_schema.is_a?(Hash) }
  assert("MeetingPlaceStatus has input_schema") { status_tool.input_schema.is_a?(Hash) }

  # 5.3 MeetingPlaceStatus tool execution
  result = status_tool.call({})
  assert("MeetingPlaceStatus returns text content") { result.is_a?(Array) && result.first[:type] == 'text' }
  parsed = JSON.parse(result.first[:text])
  assert("MeetingPlaceStatus includes meeting_place config") { parsed['meeting_place'].is_a?(Hash) }

  # 5.4 Hestia module loads all Phase 4B classes
  assert("Hestia::AgentRegistry is defined") { defined?(Hestia::AgentRegistry) }
  assert("Hestia::SkillBoard is defined") { defined?(Hestia::SkillBoard) }
  assert("Hestia::HeartbeatManager is defined") { defined?(Hestia::HeartbeatManager) }
  assert("Hestia::PlaceRouter is defined") { defined?(Hestia::PlaceRouter) }
end

# ==========================================================================
# Summary
# ==========================================================================
puts "\n" + "=" * 60
puts "Phase 4B Results: #{$pass_count} passed, #{$fail_count} failed"
puts "=" * 60

exit($fail_count > 0 ? 1 : 0)
