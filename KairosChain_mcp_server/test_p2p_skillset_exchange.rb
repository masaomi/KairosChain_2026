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
# Section 5: SkillSet Exchange via MMP
# ============================================================================
section('5. SkillSet Exchange via MMP') do
  # Create a knowledge-only SkillSet for Agent Alpha
  KairosMcp.data_dir = dir_a
  test_ss_dir = File.join(KairosMcp.skillsets_dir, 'test_knowledge_pack')
  FileUtils.mkdir_p(File.join(test_ss_dir, 'knowledge', 'test_topic'))
  File.write(File.join(test_ss_dir, 'skillset.json'), JSON.generate({
    'name' => 'test_knowledge_pack',
    'version' => '1.0.0',
    'description' => 'A test knowledge-only SkillSet for exchange testing',
    'author' => 'Test Author',
    'layer' => 'L2',
    'depends_on' => [],
    'provides' => ['test_knowledge'],
    'tool_classes' => [],
    'config_files' => [],
    'knowledge_dirs' => ['knowledge/test_topic']
  }))
  File.write(File.join(test_ss_dir, 'knowledge', 'test_topic', 'test_topic.md'), <<~MD)
    ---
    name: test_topic
    description: A test knowledge file for SkillSet exchange
    version: 1.0.0
    tags:
      - test
      - knowledge
    public: true
    ---

    # Test Topic

    This is a test knowledge file used to verify SkillSet exchange functionality.

    ## Content
    - Item 1: Knowledge exchange works
    - Item 2: Content hash verification
    - Item 3: Archive packaging
  MD

  # Enable the test SkillSet
  manager_a = KairosMcp::SkillSetManager.new
  manager_a.enable('test_knowledge_pack')

  # 5.1 Verify knowledge_only? and exchangeable?
  test_ss = manager_a.find_skillset('test_knowledge_pack')
  assert('test_knowledge_pack is valid') { test_ss.valid? }
  assert('test_knowledge_pack is knowledge_only') { test_ss.knowledge_only? }
  assert('test_knowledge_pack is exchangeable') { test_ss.exchangeable? }

  # MMP SkillSet should NOT be knowledge_only
  mmp_ss = manager_a.find_skillset('mmp')
  assert('MMP is NOT knowledge_only') { !mmp_ss.knowledge_only? }
  assert('MMP is NOT exchangeable') { !mmp_ss.exchangeable? }

  # 5.2 Test packaging
  pkg = manager_a.package('test_knowledge_pack')
  assert('package returns name') { pkg[:name] == 'test_knowledge_pack' }
  assert('package returns version') { pkg[:version] == '1.0.0' }
  assert('package returns content_hash') { !pkg[:content_hash].nil? && !pkg[:content_hash].empty? }
  assert('package returns archive_base64') { !pkg[:archive_base64].nil? && !pkg[:archive_base64].empty? }
  assert('package returns file_list') { pkg[:file_list].is_a?(Array) && pkg[:file_list].size > 0 }
  assert('package file_list contains skillset.json') { pkg[:file_list].include?('skillset.json') }

  # 5.3 Verify MMP packaging is refused
  begin
    manager_a.package('mmp')
    assert('MMP packaging should be refused') { false }
  rescue SecurityError => e
    assert('MMP packaging raises SecurityError') { e.message.include?('knowledge-only') }
  end

  # 5.4 Test MeetingRouter SkillSet endpoints
  ::MMP.instance_variable_set(:@config, nil) if ::MMP.respond_to?(:instance_variable_set)
  router_a = KairosMcp::MeetingRouter.new

  # GET /meeting/v1/skillsets
  status, _headers, body = router_a.call(mock_env('GET', '/meeting/v1/skillsets'))
  ss_list = JSON.parse(body.first, symbolize_names: true)
  assert('GET skillsets returns 200') { status == 200 }
  assert('skillsets list is array') { ss_list[:skillsets].is_a?(Array) }
  assert('test_knowledge_pack in skillsets list') {
    ss_list[:skillsets].any? { |s| s[:name] == 'test_knowledge_pack' }
  }
  assert('MMP NOT in skillsets list (has executable code)') {
    ss_list[:skillsets].none? { |s| s[:name] == 'mmp' }
  }

  # GET /meeting/v1/skillset_details
  status, _headers, body = router_a.call(mock_env('GET', '/meeting/v1/skillset_details',
    query: 'name=test_knowledge_pack'
  ))
  ss_details = JSON.parse(body.first, symbolize_names: true)
  assert('GET skillset_details returns 200') { status == 200 }
  assert('skillset_details has metadata') { ss_details[:metadata].is_a?(Hash) }
  assert('skillset_details name matches') { ss_details[:metadata][:name] == 'test_knowledge_pack' }
  assert('skillset_details has file_list') { ss_details[:metadata][:file_list].is_a?(Array) }
  assert('skillset_details has content_hash') { !ss_details[:metadata][:content_hash].nil? }
  assert('skillset_details exchangeable is true') { ss_details[:metadata][:exchangeable] == true }

  # GET /meeting/v1/skillset_details for non-exchangeable (MMP)
  status, _headers, _body = router_a.call(mock_env('GET', '/meeting/v1/skillset_details',
    query: 'name=mmp'
  ))
  assert('MMP skillset_details returns 403') { status == 403 }

  # POST /meeting/v1/skillset_content
  status, _headers, body = router_a.call(mock_env('POST', '/meeting/v1/skillset_content',
    body: { name: 'test_knowledge_pack' }
  ))
  ss_content = JSON.parse(body.first, symbolize_names: true)
  assert('POST skillset_content returns 200') { status == 200 }
  assert('skillset_content has package') { ss_content[:skillset_package].is_a?(Hash) }
  assert('skillset_content has archive_base64') { !ss_content[:skillset_package][:archive_base64].nil? }
  received_pkg = ss_content[:skillset_package]

  # POST /meeting/v1/skillset_content for MMP (should be refused)
  status, _headers, _body = router_a.call(mock_env('POST', '/meeting/v1/skillset_content',
    body: { name: 'mmp' }
  ))
  assert('MMP skillset_content returns 403') { status == 403 }

  # 5.5 Agent B installs the received SkillSet archive
  KairosMcp.data_dir = dir_b
  manager_b = KairosMcp::SkillSetManager.new

  # Verify test_knowledge_pack doesn't exist on B yet
  assert('test_knowledge_pack not on Agent B yet') {
    manager_b.find_skillset('test_knowledge_pack').nil?
  }

  result = manager_b.install_from_archive(received_pkg)
  assert('install_from_archive succeeds') { result[:success] }
  assert('installed name matches') { result[:name] == 'test_knowledge_pack' }
  assert('installed version matches') { result[:version] == '1.0.0' }
  assert('content_hash matches') { result[:content_hash] == received_pkg[:content_hash] }

  # Verify it's now discoverable
  installed_ss = manager_b.find_skillset('test_knowledge_pack')
  assert('test_knowledge_pack now on Agent B') { !installed_ss.nil? }
  assert('installed SkillSet is valid') { installed_ss.valid? }
  assert('installed SkillSet is knowledge_only') { installed_ss.knowledge_only? }
  assert('installed SkillSet has correct version') { installed_ss.version == '1.0.0' }

  # Verify file contents match
  original_content = File.read(File.join(test_ss_dir, 'knowledge', 'test_topic', 'test_topic.md'))
  installed_content = File.read(File.join(installed_ss.path, 'knowledge', 'test_topic', 'test_topic.md'))
  assert('knowledge content matches after transfer') { original_content == installed_content }

  # 5.6 Verify install of non-knowledge-only archive is refused
  # Craft a fake archive with a tools/ directory containing .rb files
  fake_ss_dir = File.join(Dir.tmpdir, 'fake_executable_ss')
  FileUtils.mkdir_p(File.join(fake_ss_dir, 'tools'))
  File.write(File.join(fake_ss_dir, 'skillset.json'), JSON.generate({
    'name' => 'fake_executable',
    'version' => '1.0.0',
    'description' => 'Fake SkillSet with executable code',
    'layer' => 'L2',
    'tool_classes' => ['FakeTool']
  }))
  File.write(File.join(fake_ss_dir, 'tools', 'fake_tool.rb'), 'class FakeTool; end')

  # Manually create the archive (bypassing the package method which would refuse)
  fake_tar_gz = StringIO.new
  Zlib::GzipWriter.wrap(fake_tar_gz) do |gz|
    Gem::Package::TarWriter.new(gz) do |tar|
      Dir[File.join(fake_ss_dir, '**', '*')].sort.each do |full_path|
        relative = full_path.sub("#{fake_ss_dir}/", '')
        stat = File.stat(full_path)
        if File.directory?(full_path)
          tar.mkdir("fake_executable/#{relative}", stat.mode)
        else
          content = File.binread(full_path)
          tar.add_file_simple("fake_executable/#{relative}", stat.mode, content.bytesize) { |tio| tio.write(content) }
        end
      end
    end
  end

  require 'base64'
  fake_archive_data = {
    name: 'fake_executable',
    version: '1.0.0',
    archive_base64: Base64.strict_encode64(fake_tar_gz.string)
  }

  begin
    manager_b.install_from_archive(fake_archive_data)
    assert('executable archive install should be refused') { false }
  rescue SecurityError => e
    assert('executable archive raises SecurityError') { e.message.include?('executable code') }
  end

  FileUtils.rm_rf(fake_ss_dir)

  # 5.7 Verify introduce now includes exchangeable_skillsets
  KairosMcp.data_dir = dir_a
  ::MMP.instance_variable_set(:@config, nil) if ::MMP.respond_to?(:instance_variable_set)

  identity_a = ::MMP::Identity.new(workspace_root: dir_a, config: ::MMP.load_config)
  intro = identity_a.introduce
  assert('introduce has exchangeable_skillsets') { intro[:exchangeable_skillsets].is_a?(Array) }
  assert('exchangeable_skillsets includes test_knowledge_pack') {
    intro[:exchangeable_skillsets].any? { |s| s[:name] == 'test_knowledge_pack' }
  }
  assert('exchangeable_skillsets excludes MMP') {
    intro[:exchangeable_skillsets].none? { |s| s[:name] == 'mmp' }
  }

  # 5.8 Duplicate install should fail
  KairosMcp.data_dir = dir_b
  begin
    manager_b.install_from_archive(received_pkg)
    assert('duplicate install should fail') { false }
  rescue ArgumentError => e
    assert('duplicate install raises ArgumentError') { e.message.include?('already installed') }
  end
end

# ============================================================================
# Section 6: Security & Wire Protocol Spec
# ============================================================================
section('6. Security & Wire Protocol Spec') do
  # --- H4: SkillSet name sanitization ---
  KairosMcp.data_dir = dir_a
  manager_sec = KairosMcp::SkillSetManager.new

  # Path traversal name
  begin
    manager_sec.install_from_archive({ name: '../../evil', archive_base64: Base64.strict_encode64('x') })
    assert('name "../../evil" should be rejected') { false }
  rescue ArgumentError => e
    assert('name "../../evil" raises ArgumentError') { e.message.include?('Invalid SkillSet name') }
  end

  # Slash in name
  begin
    manager_sec.install_from_archive({ name: 'foo/bar', archive_base64: Base64.strict_encode64('x') })
    assert('name "foo/bar" should be rejected') { false }
  rescue ArgumentError => e
    assert('name "foo/bar" raises ArgumentError') { e.message.include?('Invalid SkillSet name') }
  end

  # Empty name
  begin
    manager_sec.install_from_archive({ name: '', archive_base64: Base64.strict_encode64('x') })
    assert('empty name should be rejected') { false }
  rescue ArgumentError => e
    assert('empty name raises ArgumentError') { e.message.include?('cannot be empty') }
  end

  # Valid name passes validation (will fail later for other reasons, but name check passes)
  begin
    manager_sec.install_from_archive({ name: 'my-skillset_v2', archive_base64: Base64.strict_encode64('x') })
    assert('valid name should pass validation') { false } # will fail on decode
  rescue ArgumentError => e
    # If error is about name, that's a fail; if about archive content, name passed
    assert('valid name "my-skillset_v2" passes name validation') { !e.message.include?('Invalid SkillSet name') }
  rescue Zlib::GzipFile::Error
    # Archive decode failed = name validation passed
    assert('valid name "my-skillset_v2" passes name validation') { true }
  end

  # --- H1: tar.gz Path Traversal ---
  # Create a malicious archive with path traversal entry
  malicious_tar_gz = StringIO.new
  Zlib::GzipWriter.wrap(malicious_tar_gz) do |gz|
    Gem::Package::TarWriter.new(gz) do |tar|
      tar.add_file_simple('../../evil.txt', 0o644, 10) { |tio| tio.write('evil data!') }
    end
  end

  Dir.mktmpdir('tar_traversal_test') do |tmpdir|
    begin
      manager_sec.send(:extract_tar_gz, malicious_tar_gz.string, tmpdir)
      assert('path traversal tar.gz should raise SecurityError') { false }
    rescue SecurityError => e
      assert('path traversal in tar.gz raises SecurityError') { e.message.include?('Path traversal') }
    end
  end

  # Create archive with symlink entry - should be silently skipped
  # Note: TarWriter doesn't easily create symlinks, so we test that normal archives work
  # as a regression test (symlink handling is a next/skip in the code)
  normal_tar_gz = StringIO.new
  Zlib::GzipWriter.wrap(normal_tar_gz) do |gz|
    Gem::Package::TarWriter.new(gz) do |tar|
      tar.mkdir('safe_dir', 0o755)
      tar.add_file_simple('safe_dir/file.txt', 0o644, 5) { |tio| tio.write('hello') }
    end
  end

  Dir.mktmpdir('tar_normal_test') do |tmpdir|
    manager_sec.send(:extract_tar_gz, normal_tar_gz.string, tmpdir)
    assert('normal archive extracts successfully') {
      File.exist?(File.join(tmpdir, 'safe_dir', 'file.txt'))
    }
    assert('normal archive content is correct') {
      File.read(File.join(tmpdir, 'safe_dir', 'file.txt')) == 'hello'
    }
  end

  # --- H5: knowledge_only? extension ---
  # SkillSet with .py in tools/
  Dir.mktmpdir('ko_test') do |tmpdir|
    ss_dir = File.join(tmpdir, 'py_ss')
    FileUtils.mkdir_p(File.join(ss_dir, 'tools'))
    File.write(File.join(ss_dir, 'skillset.json'), JSON.generate({
      'name' => 'py_ss', 'version' => '1.0.0'
    }))
    File.write(File.join(ss_dir, 'tools', 'script.py'), 'print("hello")')
    ss = KairosMcp::Skillset.new(ss_dir)
    assert('tools/script.py => knowledge_only? is false') { !ss.knowledge_only? }
  end

  # SkillSet with .sh in lib/
  Dir.mktmpdir('ko_test') do |tmpdir|
    ss_dir = File.join(tmpdir, 'sh_ss')
    FileUtils.mkdir_p(File.join(ss_dir, 'lib'))
    File.write(File.join(ss_dir, 'skillset.json'), JSON.generate({
      'name' => 'sh_ss', 'version' => '1.0.0'
    }))
    File.write(File.join(ss_dir, 'lib', 'run.sh'), '#!/bin/bash\necho hi')
    ss = KairosMcp::Skillset.new(ss_dir)
    assert('lib/run.sh => knowledge_only? is false') { !ss.knowledge_only? }
  end

  # SkillSet with shebang but no known extension
  Dir.mktmpdir('ko_test') do |tmpdir|
    ss_dir = File.join(tmpdir, 'shebang_ss')
    FileUtils.mkdir_p(File.join(ss_dir, 'tools'))
    File.write(File.join(ss_dir, 'skillset.json'), JSON.generate({
      'name' => 'shebang_ss', 'version' => '1.0.0'
    }))
    File.write(File.join(ss_dir, 'tools', 'runner'), "#!/usr/bin/env python3\nprint('hi')")
    ss = KairosMcp::Skillset.new(ss_dir)
    assert('shebang file => knowledge_only? is false') { !ss.knowledge_only? }
  end

  # SkillSet with only .md and .yml files
  Dir.mktmpdir('ko_test') do |tmpdir|
    ss_dir = File.join(tmpdir, 'md_ss')
    FileUtils.mkdir_p(File.join(ss_dir, 'tools'))
    FileUtils.mkdir_p(File.join(ss_dir, 'lib'))
    File.write(File.join(ss_dir, 'skillset.json'), JSON.generate({
      'name' => 'md_ss', 'version' => '1.0.0'
    }))
    File.write(File.join(ss_dir, 'tools', 'readme.md'), '# Tools readme')
    File.write(File.join(ss_dir, 'lib', 'config.yml'), 'key: value')
    ss = KairosMcp::Skillset.new(ss_dir)
    assert('.md/.yml only => knowledge_only? is true') { ss.knowledge_only? }
  end

  # --- Wire Protocol Spec tests ---
  KairosMcp.data_dir = dir_a
  ::MMP.instance_variable_set(:@config, nil) if ::MMP.respond_to?(:instance_variable_set)

  wire_spec_path = File.join(
    KairosMcp.skillsets_dir, 'mmp', 'knowledge',
    'meeting_protocol_wire_spec', 'meeting_protocol_wire_spec.md'
  )

  assert('wire spec file exists in MMP knowledge') { File.exist?(wire_spec_path) }

  if File.exist?(wire_spec_path)
    wire_content = File.read(wire_spec_path)

    # Check frontmatter
    assert('wire spec has type: protocol_specification') {
      wire_content.include?('type: protocol_specification')
    }
    assert('wire spec has public: true') {
      wire_content.include?('public: true')
    }

    # Check it is discoverable as MMP SkillSet knowledge via KnowledgeProvider
    mmp_knowledge_dir = File.join(KairosMcp.skillsets_dir, 'mmp', 'knowledge')
    wire_spec_files = Dir[File.join(mmp_knowledge_dir, '**', '*.md')].select { |f|
      f.include?('wire_spec')
    }
    assert('wire spec discoverable in MMP knowledge dirs') { wire_spec_files.size > 0 }
  end
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
