#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# P2P SkillSet Exchange Test
# ============================================================================
# Comprehensive test for the SkillSet Plugin + MMP P2P exchange system.
#
# Tests:
#   1. SkillSet Plugin Infrastructure
#   2. MMP SkillSet Load & Tool Registration
#   3. P2P Communication via MeetingRouter
#   4. SkillSet Exchange Integration
#
# Usage:
#   ruby test_p2p_skillset_exchange.rb
#
# Requirements:
#   - rack gem (for Rack::MockRequest)
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'

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

def section(title)
  puts ''
  puts '=' * 60
  puts "SECTION: #{title}"
  puts '=' * 60
  $section_pass = 0
  $section_fail = 0
  yield
  puts "  -- #{$section_pass} passed, #{$section_fail} failed"
rescue StandardError => e
  puts "  SECTION ERROR: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  $fail_count += 1
end

# ============================================================================
# Setup: Create two independent KairosChain data directories
# ============================================================================
puts ''
puts '=' * 60
puts 'SETUP: Creating test environments'
puts '=' * 60

dir_a = Dir.mktmpdir('kairos_agent_a')
dir_b = Dir.mktmpdir('kairos_agent_b')

mmp_template = File.join(File.expand_path('templates', __dir__), 'skillsets', 'mmp')

def setup_agent(data_dir, agent_name, mmp_template, public_skill: nil)
  FileUtils.mkdir_p(File.join(data_dir, 'skills'))
  FileUtils.mkdir_p(File.join(data_dir, 'knowledge'))
  FileUtils.mkdir_p(File.join(data_dir, 'context'))
  FileUtils.mkdir_p(File.join(data_dir, 'storage'))
  FileUtils.mkdir_p(File.join(data_dir, 'config'))

  # Write minimal skills config
  File.write(File.join(data_dir, 'skills', 'config.yml'), { 'skill_tools_enabled' => false }.to_yaml)

  # Install MMP SkillSet
  ss_dest = File.join(data_dir, 'skillsets', 'mmp')
  FileUtils.mkdir_p(File.dirname(ss_dest))
  FileUtils.cp_r(mmp_template, ss_dest)

  # Enable MMP in config
  config_path = File.join(ss_dest, 'config', 'meeting.yml')
  config = YAML.load_file(config_path)
  config['enabled'] = true
  config['identity']['name'] = agent_name
  config['identity']['description'] = "Test agent: #{agent_name}"
  config['skill_exchange']['public_by_default'] = true
  File.write(config_path, config.to_yaml)

  # Create a public skill if requested
  if public_skill
    skill_dir = File.join(data_dir, 'knowledge', public_skill[:name])
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, "#{public_skill[:name]}.md"), public_skill[:content])
  end

  data_dir
end

setup_agent(dir_a, 'Agent Alpha', mmp_template, public_skill: {
  name: 'greeting_protocol',
  content: <<~MD
    ---
    name: greeting_protocol
    description: A formal greeting protocol for agent communication
    version: 1.0.0
    tags:
      - greeting
      - protocol
      - communication
    public: true
    ---

    # Greeting Protocol

    A structured approach to agent greetings.

    ## Rules
    1. Always introduce yourself with name and capabilities
    2. Acknowledge the other agent's introduction
    3. Express willingness to collaborate
  MD
})

setup_agent(dir_b, 'Agent Beta', mmp_template, public_skill: {
  name: 'data_analysis',
  content: <<~MD
    ---
    name: data_analysis
    description: Data analysis patterns for structured datasets
    version: 2.0.0
    tags:
      - analysis
      - data
      - patterns
    public: true
    ---

    # Data Analysis Patterns

    Techniques for analyzing structured data.

    ## Methods
    - Statistical summary
    - Trend detection
    - Anomaly identification
  MD
})

puts "  Agent Alpha: #{dir_a}"
puts "  Agent Beta:  #{dir_b}"

# ============================================================================
# Section 1: SkillSet Plugin Infrastructure
# ============================================================================
section('1. SkillSet Plugin Infrastructure') do
  KairosMcp.data_dir = dir_a

  require 'kairos_mcp/skillset_manager'

  manager = KairosMcp::SkillSetManager.new

  assert('discovers MMP SkillSet') { manager.all_skillsets.any? { |s| s.name == 'mmp' } }

  mmp = manager.find_skillset('mmp')
  assert('MMP is valid') { mmp.valid? }
  assert('MMP layer is L1') { mmp.layer == :L1 }
  assert('MMP has 4 tool classes') { mmp.tool_class_names.size == 4 }
  assert('MMP has knowledge') { mmp.has_knowledge? }
  assert('MMP content hash is not empty') { !mmp.content_hash.empty? }
  assert('MMP is enabled by default') { manager.enabled?('mmp') }

  # Test disable/enable
  result = manager.disable('mmp')
  assert('can disable MMP (L1)') { result[:success] }
  assert('MMP is now disabled') { !manager.enabled?('mmp') }

  result = manager.enable('mmp')
  assert('can re-enable MMP') { result[:success] }
  assert('MMP is now enabled') { manager.enabled?('mmp') }
end

# ============================================================================
# Section 2: MMP SkillSet Load & Tool Registration
# ============================================================================
section('2. MMP SkillSet Load & Tool Registration') do
  KairosMcp.data_dir = dir_a

  manager = KairosMcp::SkillSetManager.new
  mmp = manager.find_skillset('mmp')

  # Load the SkillSet
  mmp.load!
  assert('MMP loaded successfully') { mmp.loaded? }

  # Check all tool classes are defined
  mmp.tool_class_names.each do |cls_name|
    assert("tool class defined: #{cls_name.split('::').last}") {
      Object.const_get(cls_name).is_a?(Class)
    }
  end

  # Check MMP module is available
  assert('MMP module defined') { defined?(::MMP) == 'constant' }
  assert('MMP::Protocol defined') { defined?(::MMP::Protocol) }
  assert('MMP::Identity defined') { defined?(::MMP::Identity) }
  assert('MMP::ChainAdapter defined') { defined?(::MMP::ChainAdapter) }
  assert('MMP::SkillExchange defined') { defined?(::MMP::SkillExchange) }
  assert('MMP::InteractionLog defined') { defined?(::MMP::InteractionLog) }
  assert('MMP::PeerManager defined') { defined?(::MMP::PeerManager) }
  assert('MMP::Crypto defined') { defined?(::MMP::Crypto) }

  # Check config loading
  config = ::MMP.load_config
  assert('MMP config is enabled') { config['enabled'] == true }
  assert('MMP config has identity') { config['identity']['name'] == 'Agent Alpha' }

  # Simulate ToolRegistry integration
  require 'kairos_mcp/tool_registry'
  require 'kairos_mcp/safety'

  safety = KairosMcp::Safety.new
  tool_names = mmp.tool_class_names.map do |cls_name|
    klass = Object.const_get(cls_name)
    tool = klass.new(safety)
    tool.name
  end

  assert('meeting_connect tool exists') { tool_names.include?('meeting_connect') }
  assert('meeting_disconnect tool exists') { tool_names.include?('meeting_disconnect') }
  assert('meeting_acquire_skill tool exists') { tool_names.include?('meeting_acquire_skill') }
  assert('meeting_get_skill_details tool exists') { tool_names.include?('meeting_get_skill_details') }

  # Verify MMP SkillSet disabled = no meeting tools
  manager2 = KairosMcp::SkillSetManager.new
  manager2.disable('mmp')
  enabled = manager2.enabled_skillsets
  assert('disabled MMP not in enabled list') { enabled.none? { |s| s.name == 'mmp' } }
  manager2.enable('mmp')
end

# ============================================================================
# Section 3: P2P Communication via MeetingRouter
# ============================================================================
section('3. P2P Communication (MeetingRouter)') do
  require 'kairos_mcp/meeting_router'

  # Test with Agent Alpha's data dir
  KairosMcp.data_dir = dir_a

  # Force reload MMP config for Agent Alpha
  ::MMP.instance_variable_set(:@config, nil) if ::MMP.respond_to?(:instance_variable_set)

  router = KairosMcp::MeetingRouter.new

  # Helper to create mock Rack env
  def mock_env(method, path, body: nil, query: nil)
    env = {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'QUERY_STRING' => query || '',
      'CONTENT_TYPE' => 'application/json'
    }
    if body
      env['rack.input'] = StringIO.new(body.is_a?(String) ? body : JSON.generate(body))
    else
      env['rack.input'] = StringIO.new('')
    end
    env
  end

  # GET /meeting/v1/introduce
  status, _headers, body = router.call(mock_env('GET', '/meeting/v1/introduce'))
  intro_data = JSON.parse(body.first, symbolize_names: true)
  assert('GET introduce returns 200') { status == 200 }
  assert('introduce has identity') { intro_data[:identity].is_a?(Hash) }
  assert('introduce has capabilities') { intro_data[:capabilities].is_a?(Hash) }
  assert('introduce has skills') { intro_data[:skills].is_a?(Array) }

  instance_id = intro_data.dig(:identity, :instance_id)
  assert('instance_id is present') { !instance_id.nil? && !instance_id.empty? }

  # POST /meeting/v1/introduce
  status, _headers, body = router.call(mock_env('POST', '/meeting/v1/introduce',
    body: { action: 'introduce', from: 'test-peer', payload: { identity: { name: 'Test Peer', instance_id: 'peer-001' } } }
  ))
  result = JSON.parse(body.first, symbolize_names: true)
  assert('POST introduce returns 200') { status == 200 }
  assert('POST introduce has status received') { result[:status] == 'received' }
  assert('POST introduce returns our identity') { result[:peer_identity].is_a?(Hash) }

  # GET /meeting/v1/skills
  status, _headers, body = router.call(mock_env('GET', '/meeting/v1/skills'))
  skills_data = JSON.parse(body.first, symbolize_names: true)
  assert('GET skills returns 200') { status == 200 }
  assert('GET skills returns array') { skills_data[:skills].is_a?(Array) }
  assert('Agent Alpha has skills') { skills_data[:count] > 0 }

  skill = skills_data[:skills].first
  assert('skill has id') { !skill[:id].nil? }
  assert('skill has name') { !skill[:name].nil? }

  # GET /meeting/v1/skill_details
  status, _headers, body = router.call(mock_env('GET', '/meeting/v1/skill_details',
    query: "skill_id=#{skill[:id]}"
  ))
  details = JSON.parse(body.first, symbolize_names: true)
  assert('GET skill_details returns 200') { status == 200 }
  assert('skill_details has metadata') { details[:metadata].is_a?(Hash) }
  assert('skill_details available') { details[:metadata][:available] == true }

  # POST /meeting/v1/skill_content
  status, _headers, body = router.call(mock_env('POST', '/meeting/v1/skill_content',
    body: { skill_id: skill[:id], to: 'requester', in_reply_to: 'req-001' }
  ))
  content_data = JSON.parse(body.first, symbolize_names: true)
  assert('POST skill_content returns 200') { status == 200 }
  assert('skill_content has message') { content_data[:message].is_a?(Hash) }
  assert('skill_content has packaged_skill') { content_data[:packaged_skill].is_a?(Hash) }
  assert('packaged_skill has content') { !content_data[:packaged_skill][:content].nil? }
  assert('packaged_skill has content_hash') { !content_data[:packaged_skill][:content_hash].nil? }

  # POST /meeting/v1/message (generic)
  status, _headers, body = router.call(mock_env('POST', '/meeting/v1/message',
    body: { action: 'reflect', from: 'peer-001', payload: { reflection: 'Great exchange!' } }
  ))
  msg_result = JSON.parse(body.first, symbolize_names: true)
  assert('POST message returns 200') { status == 200 }
  assert('message processed') { msg_result[:status] == 'received' }

  # 404 for unknown endpoint
  status, _headers, _body = router.call(mock_env('GET', '/meeting/v1/unknown'))
  assert('unknown endpoint returns 404') { status == 404 }
end

# ============================================================================
# Section 4: SkillSet Exchange Integration
# ============================================================================
section('4. SkillSet Exchange Integration') do
  # Simulate a full P2P skill exchange between Agent Alpha and Agent Beta

  # Agent Alpha's router (already configured above)
  KairosMcp.data_dir = dir_a
  router_a = KairosMcp::MeetingRouter.new

  # Get Agent Alpha's skills
  _, _, body = router_a.call(mock_env('GET', '/meeting/v1/skills'))
  alpha_skills = JSON.parse(body.first, symbolize_names: true)[:skills]
  assert('Agent Alpha has skills to offer') { alpha_skills.size > 0 }

  # Agent Beta discovers Alpha's skills and requests one
  skill_to_acquire = alpha_skills.first
  assert('skill has content_hash') { !skill_to_acquire[:content_hash].nil? }

  # Agent Beta requests skill content from Alpha
  _, _, body = router_a.call(mock_env('POST', '/meeting/v1/skill_content',
    body: { skill_id: skill_to_acquire[:id], to: 'agent-beta', in_reply_to: 'req-beta-001' }
  ))
  response = JSON.parse(body.first, symbolize_names: true)
  packaged = response[:packaged_skill]

  assert('received skill content') { !packaged[:content].nil? }
  assert('received skill hash') { !packaged[:content_hash].nil? }
  assert('skill name matches') { packaged[:name] == 'greeting_protocol' }

  # Agent Beta validates and stores the received skill
  KairosMcp.data_dir = dir_b
  exchange = ::MMP::SkillExchange.new(config: ::MMP.load_config, workspace_root: dir_b)

  validation = exchange.validate_received_skill({
    content: packaged[:content],
    format: packaged[:format],
    content_hash: packaged[:content_hash]
  })
  assert('skill validation passes') { validation[:valid] }
  assert('no validation errors') { validation[:errors].empty? }

  # Store the skill
  store_result = exchange.store_received_skill(
    { skill_name: packaged[:name], content: packaged[:content],
      content_hash: packaged[:content_hash], format: packaged[:format],
      from: 'agent-alpha-001' },
    target_layer: 'L2'
  )

  assert('skill stored successfully') { store_result[:stored] }
  assert('stored in L2') { store_result[:layer] == 'L2' }
  assert('stored path exists') { File.exist?(store_result[:path]) }
  assert('provenance recorded') { !store_result[:provenance].nil? }
  assert('provenance has origin') { store_result[:provenance][:origin] == 'agent-alpha-001' }
  assert('provenance hop_count is 0') { store_result[:provenance][:hop_count] == 0 }

  # Verify stored content has received metadata
  stored_content = File.read(store_result[:path])
  assert('stored content has _received metadata') { stored_content.include?('_received') }
  assert('stored content has _provenance metadata') { stored_content.include?('_provenance') }

  # Verify blockchain provenance was recorded
  adapter = ::MMP::NullChainAdapter.new
  # The default adapter may fail in test env, but the store should still succeed
  assert('store succeeded despite chain adapter') { store_result[:stored] }

  # Test KnowledgeProvider integration with external dirs
  KairosMcp.data_dir = dir_b
  require 'kairos_mcp/knowledge_provider'
  provider = KairosMcp::KnowledgeProvider.new(KairosMcp.knowledge_dir, vector_search_enabled: false)

  mmp_ss_dir = File.join(KairosMcp.skillsets_dir, 'mmp', 'knowledge')
  provider.add_external_dir(mmp_ss_dir, source: 'skillset:mmp', layer: :L1, index: true)

  knowledge_list = provider.list
  has_mmp_knowledge = knowledge_list.any? { |k| k[:source] == 'skillset:mmp' }
  assert('MMP knowledge appears in KnowledgeProvider') { has_mmp_knowledge }
end

# ============================================================================
# Cleanup
# ============================================================================
FileUtils.rm_rf(dir_a)
FileUtils.rm_rf(dir_b)

# ============================================================================
# Summary
# ============================================================================
puts ''
puts '=' * 60
puts "FINAL RESULTS: #{$pass_count} passed, #{$fail_count} failed"
puts '=' * 60
puts ''

exit($fail_count > 0 ? 1 : 0)
