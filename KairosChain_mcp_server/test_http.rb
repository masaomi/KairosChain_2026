#!/usr/bin/env ruby
# frozen_string_literal: true

# HTTP Transport Test Script for KairosChain MCP Server
#
# Tests the Streamable HTTP transport components WITHOUT requiring
# puma/rack gems (tests the auth and protocol layers directly).
#
# Usage:
#   ruby test_http.rb
#
# For full HTTP integration testing with Puma:
#   bundle install --with http
#   ruby test_http.rb --integration

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'tmpdir'
require 'fileutils'

# Core modules (no external gems needed)
require 'kairos_mcp/auth/token_store'
require 'kairos_mcp/auth/authenticator'
require 'kairos_mcp/protocol'
require 'kairos_mcp/version'

INTEGRATION_MODE = ARGV.include?('--integration')

def separator
  puts "\n#{'=' * 60}\n"
end

def test_section(title)
  separator
  puts "TEST: #{title}"
  separator
  yield
  puts "  PASSED"
rescue StandardError => e
  puts "  FAILED: #{e.message}"
  puts e.backtrace.first(3).map { |l| "    #{l}" }.join("\n")
end

def assert(condition, message = 'Assertion failed')
  raise message unless condition
end

def assert_equal(expected, actual, message = nil)
  msg = message || "Expected #{expected.inspect}, got #{actual.inspect}"
  raise msg unless expected == actual
end

def assert_nil(value, message = nil)
  msg = message || "Expected nil, got #{value.inspect}"
  raise msg unless value.nil?
end

def assert_not_nil(value, message = nil)
  msg = message || "Expected non-nil value"
  raise msg if value.nil?
end

puts "KairosChain MCP Server - HTTP Transport Tests"
puts "Ruby version: #{RUBY_VERSION}"
puts "Version: #{KairosMcp::VERSION}"
puts "Mode: #{INTEGRATION_MODE ? 'Integration (with Puma)' : 'Unit (no external gems)'}"

# Create temp directory for test tokens
test_dir = Dir.mktmpdir('kairos_test_')
test_token_path = File.join(test_dir, 'tokens.json')

begin

  # =========================================================================
  # Token Store Tests
  # =========================================================================

  test_section("TokenStore: Create token") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)

    result = store.create(user: 'alice', role: 'owner', issued_by: 'system')

    assert_not_nil result['raw_token'], "raw_token should be present"
    assert_not_nil result['token_hash'], "token_hash should be present"
    assert_equal 'alice', result['user']
    assert_equal 'owner', result['role']
    assert_equal 'active', result['status']
    assert result['raw_token'].start_with?('kc_'), "Token should start with kc_ prefix"
    puts "  Token: #{result['raw_token'][0, 20]}..."
  end

  test_section("TokenStore: Verify valid token") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)
    result = store.create(user: 'bob', role: 'member', issued_by: 'alice')

    user_info = store.verify(result['raw_token'])
    assert_not_nil user_info, "Should verify valid token"
    assert_equal 'bob', user_info[:user]
    assert_equal 'member', user_info[:role]
  end

  test_section("TokenStore: Reject invalid token") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)

    user_info = store.verify('kc_invalid_token_12345')
    assert_nil user_info, "Should reject invalid token"
  end

  test_section("TokenStore: Reject expired token") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)

    # Create a token that expires immediately
    result = store.create(user: 'expired_user', role: 'guest', issued_by: 'system', expires_in: '0m')

    # Should be expired immediately (0 minutes)
    user_info = store.verify(result['raw_token'])
    assert_nil user_info, "Should reject expired token"
  end

  test_section("TokenStore: Revoke token") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)
    result = store.create(user: 'charlie', role: 'member', issued_by: 'system')

    count = store.revoke(user: 'charlie')
    assert count > 0, "Should revoke at least one token"

    user_info = store.verify(result['raw_token'])
    assert_nil user_info, "Should reject revoked token"
  end

  test_section("TokenStore: Rotate token") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)
    old_result = store.create(user: 'dave', role: 'member', issued_by: 'system')

    new_result = store.rotate(user: 'dave', issued_by: 'admin')
    assert_not_nil new_result['raw_token']
    assert new_result['raw_token'] != old_result['raw_token'], "New token should differ"

    # Old token should be revoked
    old_info = store.verify(old_result['raw_token'])
    assert_nil old_info, "Old token should be revoked"

    # New token should work
    new_info = store.verify(new_result['raw_token'])
    assert_not_nil new_info, "New token should be valid"
    assert_equal 'dave', new_info[:user]
  end

  test_section("TokenStore: List tokens") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)
    tokens = store.list
    assert tokens.is_a?(Array), "Should return array"
    assert tokens.size > 0, "Should have tokens"
    puts "  Active tokens: #{tokens.size}"
    tokens.each { |t| puts "    - #{t[:user]} (#{t[:role]})" }
  end

  test_section("TokenStore: Validate user format") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)

    begin
      store.create(user: '', role: 'member', issued_by: 'system')
      raise "Should have raised ArgumentError for blank user"
    rescue ArgumentError => e
      assert e.message.include?('blank'), "Error should mention blank"
    end

    begin
      store.create(user: 'invalid user!', role: 'member', issued_by: 'system')
      raise "Should have raised ArgumentError for invalid characters"
    rescue ArgumentError => e
      assert e.message.include?('alphanumeric'), "Error should mention alphanumeric"
    end
  end

  test_section("TokenStore: Validate role") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)

    begin
      store.create(user: 'test', role: 'superadmin', issued_by: 'system')
      raise "Should have raised ArgumentError for invalid role"
    rescue ArgumentError => e
      assert e.message.include?('Invalid role'), "Error should mention invalid role"
    end
  end

  # =========================================================================
  # Authenticator Tests
  # =========================================================================

  test_section("Authenticator: Authenticate valid request") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)
    result = store.create(user: 'auth_test', role: 'owner', issued_by: 'system')
    auth = KairosMcp::Auth::Authenticator.new(store)

    env = { 'HTTP_AUTHORIZATION' => "Bearer #{result['raw_token']}" }
    user_context = auth.authenticate(env)

    assert_not_nil user_context, "Should authenticate valid token"
    assert_equal 'auth_test', user_context[:user]
  end

  test_section("Authenticator: Reject missing Authorization header") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)
    auth = KairosMcp::Auth::Authenticator.new(store)

    env = {}
    result = auth.authenticate!(env)

    assert result.failed?, "Should fail without Authorization header"
    assert_equal 'missing_token', result.error
  end

  test_section("Authenticator: Reject invalid token") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)
    auth = KairosMcp::Auth::Authenticator.new(store)

    env = { 'HTTP_AUTHORIZATION' => 'Bearer kc_fake_token_xyz' }
    result = auth.authenticate!(env)

    assert result.failed?, "Should fail with invalid token"
    assert_equal 'invalid_token', result.error
  end

  test_section("Authenticator: Reject non-Bearer auth") do
    store = KairosMcp::Auth::TokenStore.new(test_token_path)
    auth = KairosMcp::Auth::Authenticator.new(store)

    env = { 'HTTP_AUTHORIZATION' => 'Basic dXNlcjpwYXNz' }
    user_context = auth.authenticate(env)

    assert_nil user_context, "Should reject non-Bearer auth"
  end

  # =========================================================================
  # Protocol Tests (with user context)
  # =========================================================================

  test_section("Protocol: Initialize with user context") do
    user_ctx = { user: 'masa', role: 'owner' }
    protocol = KairosMcp::Protocol.new(user_context: user_ctx)

    request = {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {}
    }

    response = protocol.handle_message(request.to_json)
    assert_not_nil response
    assert_equal '2025-03-26', response[:result][:protocolVersion],
                 "HTTP mode should use 2025-03-26 protocol version"
    assert_equal false, response[:result][:capabilities][:tools][:listChanged]
    puts "  Protocol version: #{response[:result][:protocolVersion]}"
  end

  test_section("Protocol: Initialize without user context (stdio)") do
    protocol = KairosMcp::Protocol.new

    request = {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {}
    }

    response = protocol.handle_message(request.to_json)
    assert_not_nil response
    assert_equal '2024-11-05', response[:result][:protocolVersion],
                 "stdio mode should use 2024-11-05 protocol version"
    puts "  Protocol version: #{response[:result][:protocolVersion]}"
  end

  test_section("Protocol: tools/list includes token_manage") do
    protocol = KairosMcp::Protocol.new

    request = {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/list'
    }

    response = protocol.handle_message(request.to_json)
    tools = response[:result][:tools]
    tool_names = tools.map { |t| t[:name] }

    assert tool_names.include?('token_manage'), "tools/list should include token_manage"
    puts "  Total tools: #{tools.size}"
    puts "  token_manage found: yes"
  end

  # =========================================================================
  # Safety Tests (user context)
  # =========================================================================

  test_section("Safety: User context") do
    require 'kairos_mcp/safety'
    safety = KairosMcp::Safety.new

    assert_nil safety.current_user, "Should start with nil user"

    safety.set_user({ user: 'test', role: 'member' })
    assert_not_nil safety.current_user
    assert_equal 'test', safety.current_user[:user]

    # Phase 1: all authorization checks return true
    assert safety.can_modify_l0?, "Phase 1: should allow L0 modification"
    assert safety.can_modify_l1?, "Phase 1: should allow L1 modification"
    assert safety.can_modify_l2?, "Phase 1: should allow L2 modification"
    assert safety.can_manage_tokens?, "Phase 1: should allow token management"
  end

  # =========================================================================
  # Integration Tests (requires puma + rack gems)
  # =========================================================================

  if INTEGRATION_MODE
    test_section("Integration: HTTP Server builds Rack app") do
      require 'kairos_mcp/http_server'

      app = KairosMcp::HttpServer.build_app(token_store_path: test_token_path)
      assert app.respond_to?(:call), "Rack app should respond to :call"
      puts "  Rack app built successfully"
    end

    test_section("Integration: Health endpoint") do
      require 'kairos_mcp/http_server'

      app = KairosMcp::HttpServer.build_app(token_store_path: test_token_path)

      env = {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/health'
      }

      status, headers, body = app.call(env)
      assert_equal 200, status
      response = JSON.parse(body.first)
      assert_equal 'ok', response['status']
      assert_equal 'streamable-http', response['transport']
      puts "  Health response: #{response['status']}"
    end

    test_section("Integration: MCP endpoint without auth") do
      require 'kairos_mcp/http_server'
      require 'stringio'

      app = KairosMcp::HttpServer.build_app(token_store_path: test_token_path)

      env = {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/mcp',
        'rack.input' => StringIO.new('{}')
      }

      status, _headers, body = app.call(env)
      assert_equal 401, status, "Should return 401 without auth"
      puts "  Correctly returned 401 Unauthorized"
    end
  else
    separator
    puts "Skipping integration tests (run with --integration flag)"
    puts "Requires: bundle install --with http"
  end

  separator
  puts "All tests completed!"

ensure
  # Clean up temp files
  FileUtils.rm_rf(test_dir)
  puts "\nCleaned up test directory: #{test_dir}"
end
