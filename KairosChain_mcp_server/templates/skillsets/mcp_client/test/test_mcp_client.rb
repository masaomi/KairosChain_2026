#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Phase 4: mcp_client SkillSet (M1+M2)
# Usage: ruby test_mcp_client.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'socket'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tool_registry'
require_relative '../lib/mcp_client'
require_relative '../tools/mcp_connect'
require_relative '../tools/mcp_disconnect'
require_relative '../tools/mcp_list_remote'

$pass = 0
$fail = 0

def assert(description, &block)
  result = block.call
  if result
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "        #{e.backtrace.first(3).join("\n        ")}"
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

# ---- Mock MCP Server ----

MOCK_TOOLS = [
  { 'name' => 'remote_echo', 'description' => 'Echo input',
    'inputSchema' => { 'type' => 'object', 'properties' => { 'text' => { 'type' => 'string' } } } },
  { 'name' => 'remote_add', 'description' => 'Add numbers',
    'inputSchema' => { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'integer' }, 'b' => { 'type' => 'integer' } } } }
].freeze

def start_mock_server
  tcp_server = TCPServer.new('127.0.0.1', 0)
  port = tcp_server.addr[1]

  thread = Thread.new do
    loop do
      client = tcp_server.accept rescue break
      Thread.new(client) do |sock|
        begin
          # Read HTTP request
          request_line = sock.gets || ''
          path = request_line.split(' ')[1] || ''
          headers = {}
          while (line = sock.gets) && line.strip != ''
            key, val = line.split(':', 2)
            headers[key.strip.downcase] = val.strip if key
          end
          content_length = headers['content-length'].to_i
          body_str = sock.read(content_length) if content_length > 0

          # Return 404 for non-/mcp paths
          unless path == '/mcp'
            sock.print "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            next
          end

          # Parse JSON-RPC
          body = JSON.parse(body_str || '{}')
          method = body['method']
          id = body['id']

          result = case method
                   when 'initialize'
                     { protocolVersion: '2025-03-26', capabilities: { tools: {} },
                       serverInfo: { name: 'mock-mcp', version: '1.0.0' } }
                   when 'initialized'
                     {}
                   when 'tools/list'
                     { tools: MOCK_TOOLS }
                   when 'tools/call'
                     tool_name = body.dig('params', 'name')
                     args = body.dig('params', 'arguments') || {}
                     case tool_name
                     when 'remote_echo'
                       { content: [{ type: 'text', text: args['text'] || 'no input' }] }
                     when 'remote_add'
                       { content: [{ type: 'text', text: ((args['a'] || 0) + (args['b'] || 0)).to_s }] }
                     else
                       {}
                     end
                   else
                     {}
                   end

          response_body = JSON.generate({ jsonrpc: '2.0', id: id, result: result })
          sock.print "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}"
        rescue StandardError
          sock.print "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" rescue nil
        ensure
          sock.close rescue nil
        end
      end
    end
  end

  [tcp_server, port, thread]
end

# ---- Test setup ----

TMPDIR = Dir.mktmpdir('mcp_client_test')

module Autonomos
  @storage_base = TMPDIR
  def self.storage_path(subpath)
    path = File.join(@storage_base, subpath)
    FileUtils.mkdir_p(path)
    path
  end
end

Client = KairosMcp::SkillSets::McpClient::Client
ConnectionManager = KairosMcp::SkillSets::McpClient::ConnectionManager
ProxyTool = KairosMcp::SkillSets::McpClient::ProxyTool

def build_registry
  registry = KairosMcp::ToolRegistry.allocate
  registry.instance_variable_set(:@safety, KairosMcp::Safety.new)
  registry.instance_variable_set(:@tools, {})
  KairosMcp::ToolRegistry.clear_gates!
  tools = {
    'mcp_connect' => KairosMcp::SkillSets::McpClient::Tools::McpConnect.new(nil, registry: registry),
    'mcp_disconnect' => KairosMcp::SkillSets::McpClient::Tools::McpDisconnect.new(nil, registry: registry),
    'mcp_list_remote' => KairosMcp::SkillSets::McpClient::Tools::McpListRemote.new(nil, registry: registry)
  }
  registry.instance_variable_set(:@tools, tools)
  registry
end

# Start mock server
server, port, thread = start_mock_server
MOCK_URL = "http://localhost:#{port}/mcp"

# Reset singleton between tests
ConnectionManager.instance.reset!

# =========================================================================
# 1. Client basics
# =========================================================================

section "Client (M1)"

assert("initialize_session succeeds") do
  client = Client.new(url: MOCK_URL, token: 'test-token')
  result = client.initialize_session
  client.connected? && result['protocolVersion']
end

assert("list_tools returns remote tools") do
  client = Client.new(url: MOCK_URL)
  client.initialize_session
  tools = client.list_tools
  tools.length == 2 && tools[0]['name'] == 'remote_echo'
end

assert("call_tool returns result") do
  client = Client.new(url: MOCK_URL)
  client.initialize_session
  result = client.call_tool('remote_echo', { 'text' => 'hello' })
  result['content'][0]['text'] == 'hello'
end

assert("call_tool with computation") do
  client = Client.new(url: MOCK_URL)
  client.initialize_session
  result = client.call_tool('remote_add', { 'a' => 3, 'b' => 7 })
  result['content'][0]['text'] == '10'
end

assert("HTTP error raises RemoteToolError") do
  client = Client.new(url: "http://localhost:#{port}/nonexistent")
  begin
    client.initialize_session
    false  # should have raised
  rescue KairosMcp::SkillSets::McpClient::RemoteToolError => e
    e.message.include?('HTTP')
  end
end

assert("connection refused raises error") do
  client = Client.new(url: 'http://localhost:1/mcp', timeout: 1)
  begin
    client.initialize_session
    false
  rescue StandardError
    true
  end
end

# =========================================================================
# 2. ConnectionManager
# =========================================================================

section "ConnectionManager (M1)"

assert("connect registers connection") do
  ConnectionManager.instance.reset!
  conn = ConnectionManager.instance.connect(
    server_id: 'test1', url: MOCK_URL, token: 'tok',
    config: { 'max_connections' => 5 }
  )
  conn[:status] == 'connected' && conn[:tools].length == 2
end

assert("client_for returns connected client") do
  client = ConnectionManager.instance.client_for('test1')
  client&.connected?
end

assert("all_connections lists connections") do
  conns = ConnectionManager.instance.all_connections
  conns.key?('test1') && conns['test1'][:status] == 'connected'
end

assert("all_remote_tools lists tools with server_id") do
  tools = ConnectionManager.instance.all_remote_tools
  tools.length == 2 && tools.all? { |t| t['server_id'] == 'test1' }
end

assert("disconnect removes connection") do
  ConnectionManager.instance.disconnect('test1')
  ConnectionManager.instance.client_for('test1').nil?
end

assert("max_connections enforced") do
  ConnectionManager.instance.reset!
  config = { 'max_connections' => 1 }
  ConnectionManager.instance.connect(server_id: 's1', url: MOCK_URL, config: config)
  begin
    ConnectionManager.instance.connect(server_id: 's2', url: MOCK_URL, config: config)
    false
  rescue KairosMcp::SkillSets::McpClient::RemoteToolError => e
    e.message.include?('Max connections')
  end
end

assert("reconnect same server_id replaces old connection") do
  ConnectionManager.instance.reset!
  ConnectionManager.instance.connect(server_id: 'r1', url: MOCK_URL,
                                     config: { 'max_connections' => 5 })
  ConnectionManager.instance.connect(server_id: 'r1', url: MOCK_URL,
                                     config: { 'max_connections' => 5 })
  ConnectionManager.instance.all_connections.size == 1
end

# =========================================================================
# 3. ProxyTool
# =========================================================================

section "ProxyTool (M2)"

assert("ProxyTool has namespaced name") do
  ConnectionManager.instance.reset!
  ConnectionManager.instance.connect(server_id: 'peer1', url: MOCK_URL,
                                     config: { 'max_connections' => 5 })
  proxy = ProxyTool.new(
    nil, registry: build_registry,
    server_id: 'peer1', remote_name: 'remote_echo',
    remote_description: 'Echo', remote_schema: {},
    connection_manager: ConnectionManager.instance
  )
  proxy.name == 'peer1/remote_echo' && proxy.remote_name == 'remote_echo'
end

assert("ProxyTool#call forwards to remote and returns result") do
  proxy = ProxyTool.new(
    nil, registry: build_registry,
    server_id: 'peer1', remote_name: 'remote_echo',
    remote_description: 'Echo', remote_schema: {},
    connection_manager: ConnectionManager.instance
  )
  result = proxy.call({ 'text' => 'proxy test' })
  result[0][:text] == 'proxy test' || result[0]['text'] == 'proxy test'
end

assert("ProxyTool returns error when not connected") do
  proxy = ProxyTool.new(
    nil, registry: build_registry,
    server_id: 'nonexistent', remote_name: 'tool',
    remote_description: '', remote_schema: {},
    connection_manager: ConnectionManager.instance
  )
  result = proxy.call({})
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'error' && parsed['error'].include?('Not connected')
end

assert("ProxyTool category is :remote") do
  proxy = ProxyTool.new(
    nil, registry: build_registry,
    server_id: 'x', remote_name: 'y',
    remote_description: '', remote_schema: {},
    connection_manager: ConnectionManager.instance
  )
  proxy.category == :remote
end

# =========================================================================
# 4. ToolRegistry dynamic registration
# =========================================================================

section "ToolRegistry dynamic registration (M0+M2)"

assert("register_dynamic_tool adds proxy to registry") do
  registry = build_registry
  ConnectionManager.instance.reset!
  ConnectionManager.instance.connect(server_id: 'dr1', url: MOCK_URL,
                                     config: { 'max_connections' => 5 })
  proxy = ProxyTool.new(
    nil, registry: registry,
    server_id: 'dr1', remote_name: 'remote_echo',
    remote_description: 'Echo', remote_schema: {},
    connection_manager: ConnectionManager.instance
  )
  registry.register_dynamic_tool(proxy)
  registry.instance_variable_get(:@tools).key?('dr1/remote_echo')
end

assert("unregister_tool removes proxy") do
  registry = build_registry
  proxy = ProxyTool.new(
    nil, registry: registry,
    server_id: 'dr2', remote_name: 'tool',
    remote_description: '', remote_schema: {},
    connection_manager: ConnectionManager.instance
  )
  registry.register_dynamic_tool(proxy)
  registry.unregister_tool('dr2/tool')
  !registry.instance_variable_get(:@tools).key?('dr2/tool')
end

assert("register_dynamic_tool rejects overwriting local tool") do
  registry = build_registry
  # 'mcp_connect' is a local tool
  proxy = ProxyTool.new(
    nil, registry: registry,
    server_id: '', remote_name: 'mcp_connect',
    remote_description: '', remote_schema: {},
    connection_manager: ConnectionManager.instance
  )
  # Change name to match local tool
  proxy.instance_variable_set(:@server_id, '')
  # This would try to register as '/mcp_connect', not 'mcp_connect'
  # Test the actual collision path with a mock non-proxy tool
  begin
    registry.register_dynamic_tool(
      Class.new {
        def name; 'mcp_connect'; end
      }.new
    )
    false  # should have raised
  rescue RuntimeError => e
    e.message.include?('Cannot override local tool')
  end
end

# =========================================================================
# 5. mcp_connect / mcp_disconnect / mcp_list_remote (E2E)
# =========================================================================

section "User-facing tools (M2 E2E)"

assert("mcp_connect registers proxy tools") do
  ConnectionManager.instance.reset!
  registry = build_registry

  # Override config to allow_untrusted
  connect_tool = registry.instance_variable_get(:@tools)['mcp_connect']
  allow_any_config = { 'allow_untrusted' => true, 'max_connections' => 5 }
  connect_tool.define_singleton_method(:load_config) { allow_any_config }

  result = connect_tool.call({ 'url' => MOCK_URL, 'server_id' => 'e2e1' })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' &&
    parsed['tools_registered'] == 2 &&
    parsed['tools'].include?('e2e1/remote_echo') &&
    registry.instance_variable_get(:@tools).key?('e2e1/remote_echo')
end

assert("proxy tool callable via registry after mcp_connect") do
  registry = build_registry
  ConnectionManager.instance.reset!

  connect_tool = registry.instance_variable_get(:@tools)['mcp_connect']
  connect_tool.define_singleton_method(:load_config) {
    { 'allow_untrusted' => true, 'max_connections' => 5 }
  }
  connect_tool.call({ 'url' => MOCK_URL, 'server_id' => 'e2e2' })

  proxy = registry.instance_variable_get(:@tools)['e2e2/remote_echo']
  result = proxy.call({ 'text' => 'e2e test' })
  result[0][:text] == 'e2e test' || result[0]['text'] == 'e2e test'
end

assert("mcp_list_remote shows connections and tool names") do
  registry = build_registry
  ConnectionManager.instance.reset!

  connect_tool = registry.instance_variable_get(:@tools)['mcp_connect']
  connect_tool.define_singleton_method(:load_config) {
    { 'allow_untrusted' => true, 'max_connections' => 5 }
  }
  connect_tool.call({ 'url' => MOCK_URL, 'server_id' => 'list1' })

  list_tool = registry.instance_variable_get(:@tools)['mcp_list_remote']
  result = list_tool.call({})
  parsed = JSON.parse(result[0][:text])
  conn = parsed['connections'][0]
  conn['server_id'] == 'list1' &&
    conn['tools'].any? { |t| t['name'] == 'list1/remote_echo' } &&
    parsed['total_remote_tools'] == 2
end

assert("mcp_disconnect removes proxy tools from registry") do
  registry = build_registry
  ConnectionManager.instance.reset!

  connect_tool = registry.instance_variable_get(:@tools)['mcp_connect']
  connect_tool.define_singleton_method(:load_config) {
    { 'allow_untrusted' => true, 'max_connections' => 5 }
  }
  connect_tool.call({ 'url' => MOCK_URL, 'server_id' => 'dc1' })

  # Verify proxy exists
  has_proxy = registry.instance_variable_get(:@tools).key?('dc1/remote_echo')

  disconnect_tool = registry.instance_variable_get(:@tools)['mcp_disconnect']
  result = disconnect_tool.call({ 'server_id' => 'dc1' })
  parsed = JSON.parse(result[0][:text])

  has_proxy &&
    parsed['status'] == 'ok' &&
    !registry.instance_variable_get(:@tools).key?('dc1/remote_echo')
end

assert("mcp_connect rejects untrusted server by default") do
  ConnectionManager.instance.reset!
  registry = build_registry
  connect_tool = registry.instance_variable_get(:@tools)['mcp_connect']
  # Default config: allow_untrusted: false, trusted_servers: []
  connect_tool.define_singleton_method(:load_config) {
    { 'allow_untrusted' => false, 'trusted_servers' => [] }
  }
  result = connect_tool.call({ 'url' => MOCK_URL })
  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'error' && parsed['error'].include?('not in trusted_servers')
end

# =========================================================================
# Cleanup
# =========================================================================

ConnectionManager.instance.reset!
server.close rescue nil
thread.kill rescue nil
FileUtils.rm_rf(TMPDIR)

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
