#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for Meeting Discovery Extension
# Tests: Protocol extension, HTTP endpoints (skill_details, skill_preview),
# and high-level MCP tools

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'yaml'

puts "=" * 60
puts "Meeting Discovery Extension Tests"
puts "=" * 60
puts

# Temporarily enable Meeting Protocol for tests
def with_meeting_enabled
  config_path = File.join(__dir__, 'config', 'meeting.yml')
  original = File.read(config_path)
  
  config = YAML.load_file(config_path)
  config['enabled'] = true
  config['discovery'] = {
    'enabled' => true,
    'allow_preview' => true,
    'max_preview_lines' => 20
  }
  File.write(config_path, YAML.dump(config))
  
  yield
ensure
  File.write(config_path, original)
end

def test(name)
  print "Testing: #{name}... "
  begin
    result = yield
    if result
      puts "✓ PASS"
      true
    else
      puts "✗ FAIL"
      false
    end
  rescue StandardError => e
    puts "✗ ERROR: #{e.message}"
    puts e.backtrace.first(3).map { |l| "  #{l}" }.join("\n")
    false
  end
end

results = []

with_meeting_enabled do
  # Test 1: Protocol Extension exists
  results << test("Protocol extension file exists") do
    File.exist?(File.join(__dir__, 'knowledge/meeting_protocol_discovery/meeting_protocol_discovery.md'))
  end

  # Test 2: Protocol Extension has correct YAML frontmatter
  results << test("Protocol extension has valid frontmatter") do
    content = File.read(File.join(__dir__, 'knowledge/meeting_protocol_discovery/meeting_protocol_discovery.md'))
    content.start_with?('---') &&
      content.include?('name: meeting_protocol_discovery') &&
      content.include?('layer: L1') &&
      content.include?('- list_peers') &&
      content.include?('- skill_details') &&
      content.include?('- skill_preview')
  end

  # Test 3: MeetingConnect tool loads
  results << test("MeetingConnect tool loads") do
    require 'kairos_mcp/tools/meeting_connect'
    defined?(KairosMcp::Tools::MeetingConnect)
  end

  # Test 4: MeetingGetSkillDetails tool loads
  results << test("MeetingGetSkillDetails tool loads") do
    require 'kairos_mcp/tools/meeting_get_skill_details'
    defined?(KairosMcp::Tools::MeetingGetSkillDetails)
  end

  # Test 5: MeetingAcquireSkill tool loads
  results << test("MeetingAcquireSkill tool loads") do
    require 'kairos_mcp/tools/meeting_acquire_skill'
    defined?(KairosMcp::Tools::MeetingAcquireSkill)
  end

  # Test 6: MeetingDisconnect tool loads
  results << test("MeetingDisconnect tool loads") do
    require 'kairos_mcp/tools/meeting_disconnect'
    defined?(KairosMcp::Tools::MeetingDisconnect)
  end

  # Test 7: ToolRegistry includes meeting tools when enabled
  results << test("ToolRegistry includes meeting tools when enabled") do
    require 'kairos_mcp/tool_registry'
    registry = KairosMcp::ToolRegistry.new
    tools = registry.list_tools
    tool_names = tools.map { |t| t[:name] }
    
    tool_names.include?('meeting_connect') &&
      tool_names.include?('meeting_get_skill_details') &&
      tool_names.include?('meeting_acquire_skill') &&
      tool_names.include?('meeting_disconnect')
  end

  # Test 8: MeetingConnect tool schema
  results << test("MeetingConnect has correct schema") do
    require 'kairos_mcp/tools/meeting_connect'
    tool = KairosMcp::Tools::MeetingConnect.new
    
    tool.name == 'meeting_connect' &&
      tool.category == :meeting &&
      tool.input_schema[:properties].key?(:url) &&
      tool.input_schema[:required].include?('url')
  end

  # Test 9: MeetingGetSkillDetails tool schema
  results << test("MeetingGetSkillDetails has correct schema") do
    require 'kairos_mcp/tools/meeting_get_skill_details'
    tool = KairosMcp::Tools::MeetingGetSkillDetails.new
    
    tool.name == 'meeting_get_skill_details' &&
      tool.input_schema[:properties].key?(:peer_id) &&
      tool.input_schema[:properties].key?(:skill_id) &&
      tool.input_schema[:required].include?('peer_id') &&
      tool.input_schema[:required].include?('skill_id')
  end

  # Test 10: MeetingAcquireSkill tool schema
  results << test("MeetingAcquireSkill has correct schema") do
    require 'kairos_mcp/tools/meeting_acquire_skill'
    tool = KairosMcp::Tools::MeetingAcquireSkill.new
    
    tool.name == 'meeting_acquire_skill' &&
      tool.input_schema[:properties].key?(:peer_id) &&
      tool.input_schema[:properties].key?(:skill_id) &&
      tool.input_schema[:properties].key?(:save_to_layer)
  end

  # Test 11: MeetingDisconnect tool schema
  results << test("MeetingDisconnect has correct schema") do
    require 'kairos_mcp/tools/meeting_disconnect'
    tool = KairosMcp::Tools::MeetingDisconnect.new
    
    tool.name == 'meeting_disconnect' &&
      tool.input_schema[:properties].empty?
  end

  # Test 12: HTTP Server has skill_details endpoint
  results << test("HTTP Server handles skill_details endpoint") do
    require 'kairos_mcp/transport/http_server'
    require 'rack/test'
    
    app = KairosMcp::Transport::MeetingApp.new(workspace_root: __dir__)
    
    # Create a mock request environment
    env = Rack::MockRequest.env_for('/meeting/v1/skill_details?skill_id=test')
    status, headers, body = app.call(env)
    
    # Should return 200 (even if skill not found, it returns JSON response)
    status == 200
  end

  # Test 13: HTTP Server has skill_preview endpoint
  results << test("HTTP Server handles skill_preview endpoint") do
    require 'kairos_mcp/transport/http_server'
    require 'rack/test'
    
    app = KairosMcp::Transport::MeetingApp.new(workspace_root: __dir__)
    
    env = Rack::MockRequest.env_for('/meeting/v1/skill_preview?skill_id=test')
    status, headers, body = app.call(env)
    
    status == 200
  end

  # Test 14: Tool related_tools are correct
  results << test("Tools have correct related_tools") do
    require 'kairos_mcp/tools/meeting_connect'
    require 'kairos_mcp/tools/meeting_disconnect'
    
    connect = KairosMcp::Tools::MeetingConnect.new
    disconnect = KairosMcp::Tools::MeetingDisconnect.new
    
    connect.related_tools.include?('meeting_disconnect') &&
      disconnect.related_tools.include?('meeting_connect')
  end

  # Test 15: Tool usecase_tags are set
  results << test("Tools have usecase tags") do
    require 'kairos_mcp/tools/meeting_connect'
    tool = KairosMcp::Tools::MeetingConnect.new
    
    !tool.usecase_tags.empty? &&
      tool.usecase_tags.include?('meeting') &&
      tool.usecase_tags.include?('connect')
  end
end

# Summary
puts
puts "=" * 60
passed = results.count(true)
failed = results.count(false)
puts "Results: #{passed} passed, #{failed} failed"
puts "=" * 60

exit(failed > 0 ? 1 : 0)
