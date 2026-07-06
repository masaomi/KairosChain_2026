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
  # TLS Tests (no external gems — TlsConfig + OpenSSL stdlib)
  # =========================================================================

  require 'kairos_mcp/tls_config'
  require 'kairos_mcp/tls_cert_generator'
  require 'openssl'

  test_section("TlsConfig: disabled by default → plain HTTP bind") do
    tls = KairosMcp::TlsConfig.new({}, data_dir: test_dir)
    assert_equal false, tls.enabled?, "TLS should be off when unconfigured"
    assert_equal 'http', tls.scheme
    assert_equal "tcp://0.0.0.0:8080", tls.bind_uri('0.0.0.0', 8080)
  end

  test_section("TlsConfig: enabled → ssl:// bind with cert/key query") do
    cfg = { 'tls' => { 'enabled' => true, 'cert' => 'c.pem', 'key' => 'k.pem' } }
    tls = KairosMcp::TlsConfig.new(cfg, data_dir: test_dir)
    assert tls.enabled?, "TLS should be enabled"
    assert_equal 'https', tls.scheme
    uri = tls.bind_uri('127.0.0.1', 8443)
    assert uri.start_with?('ssl://127.0.0.1:8443?'), "Should be ssl:// bind, got #{uri}"
    assert uri.include?('cert='), "Bind URI should carry cert param"
    assert uri.include?('key='), "Bind URI should carry key param"
    assert uri.include?(File.join(test_dir, 'c.pem').gsub('/', '%2F')) ||
           uri.include?(File.join(test_dir, 'c.pem')),
           "cert path should be resolved under data_dir"
  end

  test_section("TlsConfig: force_enabled overrides config") do
    tls = KairosMcp::TlsConfig.new({ 'tls' => { 'enabled' => false } },
                                   data_dir: test_dir, force_enabled: true)
    assert tls.enabled?, "force_enabled:true should override config false (--tls flag)"
  end

  test_section("TlsConfig: validate! fails closed when cert missing") do
    cfg = { 'tls' => { 'enabled' => true, 'cert' => 'nope.pem', 'key' => 'nope.key' } }
    tls = KairosMcp::TlsConfig.new(cfg, data_dir: test_dir)
    begin
      tls.validate!
      raise "Should have raised TlsConfigError for missing cert/key"
    rescue KairosMcp::TlsConfigError => e
      assert e.message.include?('missing'), "Error should explain what is missing"
      assert e.message.include?('--gen-cert'), "Error should suggest --gen-cert"
    end
  end

  test_section("TlsCertGenerator: produces usable cert + key") do
    cert_path = File.join(test_dir, 'tls', 'cert.pem')
    key_path  = File.join(test_dir, 'tls', 'key.pem')

    result = KairosMcp::TlsCertGenerator.generate(
      cert_path: cert_path, key_path: key_path, hosts: ['localhost', '127.0.0.1', 'example.test']
    )

    assert File.exist?(cert_path), "cert file should exist"
    assert File.exist?(key_path), "key file should exist"

    # Files must parse as real OpenSSL material (crypto delegated to stdlib)
    cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
    key  = OpenSSL::PKey::RSA.new(File.read(key_path))
    assert cert.public_key.to_pem == key.public_key.to_pem, "cert/key must be a matching pair"
    assert cert.not_after > Time.now, "cert must not be already expired"
    assert cert.serial > 0, "serial must be a positive integer (RFC 5280)"

    exts = cert.extensions.each_with_object({}) { |e, h| h[e.oid] = e.value }
    # Leaf server cert: must NOT be a CA, must be scoped to serverAuth
    assert exts['basicConstraints'].include?('CA:FALSE'), "cert must be CA:FALSE, got #{exts['basicConstraints']}"
    assert exts['extendedKeyUsage']&.include?('TLS Web Server Authentication'),
           "cert must have extendedKeyUsage serverAuth, got #{exts['extendedKeyUsage']}"
    # SAN must cover the requested hosts so remote clients verify
    assert exts['subjectAltName'].include?('DNS:example.test'), "SAN must include requested host, got #{exts['subjectAltName']}"
    assert exts['subjectAltName'].include?('IP Address:127.0.0.1'), "SAN must include loopback IP, got #{exts['subjectAltName']}"

    # Key must be private-only readable (0600)
    mode = File.stat(key_path).mode & 0o777
    assert_equal 0o600, mode, "private key must be chmod 0600, got #{mode.to_s(8)}"
    puts "  cert expires: #{result[:not_after]}"
    puts "  SAN: #{result[:san]}"
  end

  test_section("TlsCertGenerator: SAN auto-classifies IP vs DNS") do
    san = KairosMcp::TlsCertGenerator.san_value('kairos-chain', ['localhost', '10.0.0.5', '::1', 'host.example'])
    assert san.include?('DNS:kairos-chain'), "CN should be in SAN: #{san}"
    assert san.include?('DNS:localhost'), "localhost -> DNS: #{san}"
    assert san.include?('IP:10.0.0.5'), "IPv4 -> IP: #{san}"
    assert san.include?('IP:::1'), "IPv6 -> IP: #{san}"
    assert san.include?('DNS:host.example'), "hostname -> DNS: #{san}"
  end

  test_section("TlsConfig: validate! passes after cert generation") do
    cert_path = File.join(test_dir, 'tls2', 'cert.pem')
    key_path  = File.join(test_dir, 'tls2', 'key.pem')
    KairosMcp::TlsCertGenerator.generate(cert_path: cert_path, key_path: key_path)

    cfg = { 'tls' => { 'enabled' => true, 'cert' => cert_path, 'key' => key_path } }
    tls = KairosMcp::TlsConfig.new(cfg, data_dir: test_dir)
    tls.validate! # should not raise
    puts "  validate! passed with generated cert"
  end

  test_section("TlsConfig: force_enabled:false overrides config enabled:true") do
    tls = KairosMcp::TlsConfig.new({ 'tls' => { 'enabled' => true } },
                                   data_dir: test_dir, force_enabled: false)
    assert_equal false, tls.enabled?, "explicit force_enabled:false must win over config true"
    assert_equal 'http', tls.scheme
  end

  test_section("TlsConfig: empty-string path falls back to default (no nil)") do
    tls = KairosMcp::TlsConfig.new({ 'tls' => { 'enabled' => false, 'cert' => '', 'key' => '' } },
                                   data_dir: test_dir)
    assert tls.cert_path.to_s.end_with?('storage/tls/cert.pem'), "empty cert -> default, got #{tls.cert_path}"
    assert tls.key_path.to_s.end_with?('storage/tls/key.pem'), "empty key -> default, got #{tls.key_path}"
    assert !tls.cert_path.nil?, "cert_path must never be nil (would crash --gen-cert)"
  end

  test_section("TlsConfig: bind_uri round-trips paths via URI.decode_www_form (Puma parity)") do
    # Puma's binder decodes the ssl:// query with URI.decode_www_form. Assert
    # our encode is its exact inverse for the hostile cases (space, literal +).
    cfg = { 'tls' => { 'enabled' => true, 'cert' => '/Users/My Name/c.pem', 'key' => '/tmp/a+b/k.pem' } }
    tls = KairosMcp::TlsConfig.new(cfg, data_dir: test_dir)
    uri = tls.bind_uri('127.0.0.1', 8443)
    params = URI.decode_www_form(URI(uri).query).to_h
    assert_equal '/Users/My Name/c.pem', params['cert'], "cert path must survive encode/decode"
    assert_equal '/tmp/a+b/k.pem', params['key'], "key path with literal + must survive"
  end

  test_section("TlsConfig: validate! rejects unreadable/invalid PEM") do
    bad_cert = File.join(test_dir, 'bad', 'cert.pem')
    bad_key  = File.join(test_dir, 'bad', 'key.pem')
    FileUtils.mkdir_p(File.dirname(bad_cert))
    File.write(bad_cert, "not a certificate")
    File.write(bad_key, "not a key")
    cfg = { 'tls' => { 'enabled' => true, 'cert' => bad_cert, 'key' => bad_key } }
    tls = KairosMcp::TlsConfig.new(cfg, data_dir: test_dir)
    begin
      tls.validate!
      raise "Should have raised TlsConfigError for invalid PEM"
    rescue KairosMcp::TlsConfigError => e
      assert e.message.include?('not valid'), "error should flag invalid material: #{e.message}"
    end
  end

  test_section("TlsConfig: certificate_not_after reads the cert expiry") do
    cert_path = File.join(test_dir, 'exp', 'cert.pem')
    key_path  = File.join(test_dir, 'exp', 'key.pem')
    KairosMcp::TlsCertGenerator.generate(cert_path: cert_path, key_path: key_path)
    tls = KairosMcp::TlsConfig.new({ 'tls' => { 'enabled' => true, 'cert' => cert_path, 'key' => key_path } },
                                   data_dir: test_dir)
    na = tls.certificate_not_after
    assert_not_nil na, "should return the cert not_after"
    assert na > Time.now, "cert should expire in the future"
    # Disabled/missing cert returns nil rather than raising
    assert_nil KairosMcp::TlsConfig.new({}, data_dir: test_dir).certificate_not_after
  end

  test_section("TlsCertGenerator: overwrite guard refuses non-interactive clobber") do
    g = KairosMcp::TlsCertGenerator
    assert_equal true,  g.overwrite_refused_noninteractive?(exists: true,  tty: false), "existing + non-tty => refuse"
    assert_equal false, g.overwrite_refused_noninteractive?(exists: true,  tty: true),  "existing + tty => prompt (not auto-refuse)"
    assert_equal false, g.overwrite_refused_noninteractive?(exists: false, tty: false), "no files => generate"
  end

  test_section("TlsCertGenerator: add_san rejects comma/prefix injection") do
    [['a,DNS:evil.example'], ['DNS:already.prefixed'], ['IP:1.2.3.4']].each do |bad|
      begin
        KairosMcp::TlsCertGenerator.san_value('cn', bad)
        raise "Should have raised ArgumentError for #{bad.inspect}"
      rescue ArgumentError => e
        assert e.message.include?('invalid SAN host'), "clear error: #{e.message}"
      end
    end
    # a clean host still works
    assert KairosMcp::TlsCertGenerator.san_value('cn', ['ok.example']).include?('DNS:ok.example')
  end

  test_section("TlsCertGenerator: overwrite of a 0644 key ends at 0600 (no window)") do
    key_path  = File.join(test_dir, 'ow', 'key.pem')
    cert_path = File.join(test_dir, 'ow', 'cert.pem')
    FileUtils.mkdir_p(File.dirname(key_path))
    File.write(key_path, "stale")
    File.chmod(0o644, key_path) # simulate a pre-existing world-readable key
    KairosMcp::TlsCertGenerator.generate(cert_path: cert_path, key_path: key_path)
    mode = File.stat(key_path).mode & 0o777
    assert_equal 0o600, mode, "overwritten key must end at 0600, got #{mode.to_s(8)}"
  end

  test_section("TlsConfig: validate! rejects a mismatched cert/key pair") do
    a_cert = File.join(test_dir, 'pairA', 'cert.pem'); a_key = File.join(test_dir, 'pairA', 'key.pem')
    b_cert = File.join(test_dir, 'pairB', 'cert.pem'); b_key = File.join(test_dir, 'pairB', 'key.pem')
    KairosMcp::TlsCertGenerator.generate(cert_path: a_cert, key_path: a_key)
    KairosMcp::TlsCertGenerator.generate(cert_path: b_cert, key_path: b_key)
    # A's cert with B's key => not a pair
    cfg = { 'tls' => { 'enabled' => true, 'cert' => a_cert, 'key' => b_key } }
    tls = KairosMcp::TlsConfig.new(cfg, data_dir: test_dir)
    begin
      tls.validate!
      raise "Should have raised for mismatched cert/key"
    rescue KairosMcp::TlsConfigError => e
      assert e.message.include?('do not match'), "should flag pair mismatch: #{e.message}"
    end
  end

  test_section("TlsConfig: bind_uri brackets IPv6 host") do
    tls_off = KairosMcp::TlsConfig.new({}, data_dir: test_dir)
    assert_equal 'tcp://[::1]:8080', tls_off.bind_uri('::1', 8080), "IPv6 must be bracketed"
    assert_equal 'tcp://127.0.0.1:8080', tls_off.bind_uri('127.0.0.1', 8080), "IPv4 unchanged"
    tls_on = KairosMcp::TlsConfig.new({ 'tls' => { 'enabled' => true, 'cert' => '/c', 'key' => '/k' } }, data_dir: test_dir)
    assert tls_on.bind_uri('::1', 8443).start_with?('ssl://[::1]:8443?'), "IPv6 ssl bracketed"
  end

  test_section("TlsConfig: days_until_expiry (near vs far)") do
    near_c = File.join(test_dir, 'near', 'c.pem'); near_k = File.join(test_dir, 'near', 'k.pem')
    far_c  = File.join(test_dir, 'far', 'c.pem');  far_k  = File.join(test_dir, 'far', 'k.pem')
    KairosMcp::TlsCertGenerator.generate(cert_path: near_c, key_path: near_k, days: 10)
    KairosMcp::TlsCertGenerator.generate(cert_path: far_c,  key_path: far_k,  days: 825)
    near = KairosMcp::TlsConfig.new({ 'tls' => { 'enabled' => true, 'cert' => near_c, 'key' => near_k } }, data_dir: test_dir)
    far  = KairosMcp::TlsConfig.new({ 'tls' => { 'enabled' => true, 'cert' => far_c,  'key' => far_k  } }, data_dir: test_dir)
    assert near.days_until_expiry <= 30, "near cert should be within warn window: #{near.days_until_expiry}"
    assert far.days_until_expiry > 30, "far cert should be outside warn window: #{far.days_until_expiry}"
  end

  test_section("HttpServer.exposed_without_auth? predicate matrix") do
    require 'kairos_mcp/http_server'
    h = KairosMcp::HttpServer
    # empty store + loopback + no TLS => local dev, NOT exposed
    assert_equal false, h.exposed_without_auth?(token_store_empty: true, loopback: true, tls_enabled: false)
    # empty store + loopback + TLS => remote intent => exposed
    assert_equal true,  h.exposed_without_auth?(token_store_empty: true, loopback: true, tls_enabled: true)
    # empty store + non-loopback => exposed
    assert_equal true,  h.exposed_without_auth?(token_store_empty: true, loopback: false, tls_enabled: false)
    # tokens present => never exposed
    assert_equal false, h.exposed_without_auth?(token_store_empty: false, loopback: false, tls_enabled: true)
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
      assert_equal false, response['tls'], "default build should report tls:false in health"
      puts "  Health response: #{response['status']} (tls=#{response['tls']})"
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
