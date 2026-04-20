#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for P2.5b: HTTP typed tools (safe_http_get + safe_http_post).
#
# Usage:
#   ruby templates/skillsets/external_tools/test/test_http_tools.rb
#
# Mocking strategy:
#   HttpSupport.execute is the single seam where a real network call would
#   happen. We override it on a per-test basis to return a FakeResponse and
#   capture the outgoing Net::HTTP::Request so we can assert on headers /
#   body / url — no real sockets are opened.

$LOAD_PATH.unshift File.expand_path('../../../../KairosChain_mcp_server/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('..', __dir__)

require 'json'
require 'digest'
require 'securerandom'
require 'uri'

require 'kairos_mcp/tools/base_tool'
require 'external_tools'

require_relative '../tools/safe_http_get'
require_relative '../tools/safe_http_post'

HS = ::KairosMcp::SkillSets::ExternalTools::HttpSupport
T  = ::KairosMcp::SkillSets::ExternalTools::Tools

# -----------------------------------------------------------------------------
# Test harness (mirrors test_external_tools.rb conventions)
# -----------------------------------------------------------------------------

$pass = 0
$fail = 0
$failed = []

def assert(desc)
  ok = yield
  if ok
    $pass += 1
    puts "  PASS: #{desc}"
  else
    $fail += 1
    $failed << desc
    puts "  FAIL: #{desc}"
  end
rescue StandardError => e
  $fail += 1
  $failed << desc
  puts "  FAIL: #{desc} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}\nTEST: #{title}\n#{'=' * 60}"
end

def decode(result)
  JSON.parse(result.first[:text])
end

# -----------------------------------------------------------------------------
# Fake HTTP response + execute stub
# -----------------------------------------------------------------------------

class FakeResponse
  def initialize(code: 200, body: '', headers: {})
    @code = code
    @body = body
    # Net::HTTPResponse#[] is case-insensitive; simulate that.
    @headers = {}
    headers.each { |k, v| @headers[k.to_s.downcase] = v.to_s }
  end

  attr_reader :body

  def code
    @code.to_s
  end

  def [](key)
    @headers[key.to_s.downcase]
  end
end

module StubHttp
  class << self
    attr_accessor :response, :last_uri, :last_request, :last_timeout, :raise_error
  end
  self.response    = nil
  self.last_uri    = nil
  self.last_request = nil
  self.last_timeout = nil
  self.raise_error = nil
end

# Override HttpSupport.execute so no real socket is ever opened.
module ::KairosMcp
  module SkillSets
    module ExternalTools
      module HttpSupport
        def self.execute(uri, req, timeout: 30)
          StubHttp.last_uri     = uri
          StubHttp.last_request = req
          StubHttp.last_timeout = timeout
          raise StubHttp.raise_error if StubHttp.raise_error
          StubHttp.response || FakeResponse.new(code: 200, body: '')
        end
      end
    end
  end
end

def reset_stub
  StubHttp.response     = nil
  StubHttp.last_uri     = nil
  StubHttp.last_request = nil
  StubHttp.last_timeout = nil
  StubHttp.raise_error  = nil
end

# Stand-in for daemon @safety exposing credentials.fetch_for + idem_key.
class FakeSafety
  attr_reader :credentials, :invocation_context

  def initialize(creds: {}, idem_key: nil)
    @credentials = FakeCredentials.new(creds)
    @invocation_context = FakeCtx.new(idem_key)
  end
end

class FakeCredentials
  def initialize(map) = @map = map
  def fetch_for(_tool_name) = @map
end

class FakeCtx
  def initialize(idem_key) = @idem_key = idem_key
  attr_reader :idem_key
end

# -----------------------------------------------------------------------------
# url_allowed?
# -----------------------------------------------------------------------------

section 'HttpSupport.url_allowed?'

assert('https URL matches default https://* pattern') do
  HS.url_allowed?('https://api.example.com/v1/foo', ['https://*'])
end

assert('http URL rejected by default https-only allowlist') do
  !HS.url_allowed?('http://api.example.com/v1/foo', ['https://*'])
end

assert('http URL accepted when explicit http:// pattern is supplied') do
  HS.url_allowed?('http://localhost:8080/health', ['http://localhost:*'])
end

assert('empty allowlist denies everything') do
  !HS.url_allowed?('https://api.example.com', [])
end

assert('specific host pattern matches') do
  HS.url_allowed?('https://api.github.com/repos', ['https://api.github.com/*'])
end

assert('specific host pattern rejects other host') do
  !HS.url_allowed?('https://evil.example.com/repos', ['https://api.github.com/*'])
end

assert('case-insensitive scheme match') do
  HS.url_allowed?('HTTPS://api.example.com', ['https://*'])
end

# -----------------------------------------------------------------------------
# HttpSupport.merge_headers
# -----------------------------------------------------------------------------

section 'HttpSupport.merge_headers'

assert('user headers are applied') do
  req = Net::HTTP::Get.new('/')
  HS.merge_headers(req, { 'X-Trace' => 'abc' }, {})
  req['X-Trace'] == 'abc'
end

assert('credentials injected when user did not set that key') do
  req = Net::HTTP::Get.new('/')
  HS.merge_headers(req, { 'X-Trace' => 'abc' }, { 'Authorization' => 'Bearer xyz' })
  req['Authorization'] == 'Bearer xyz' && req['X-Trace'] == 'abc'
end

assert('user header overrides credential with same key (case-insensitive)') do
  req = Net::HTTP::Get.new('/')
  HS.merge_headers(req, { 'authorization' => 'Bearer USER' }, { 'Authorization' => 'Bearer CRED' })
  req['Authorization'] == 'Bearer USER'
end

assert('empty credential values are skipped') do
  req = Net::HTTP::Get.new('/')
  HS.merge_headers(req, {}, { 'X-Empty' => '', 'X-Present' => 'v' })
  req['X-Empty'].nil? && req['X-Present'] == 'v'
end

# -----------------------------------------------------------------------------
# HttpSupport.select_headers
# -----------------------------------------------------------------------------

section 'HttpSupport.select_headers'

assert('only whitelisted response headers are surfaced') do
  resp = FakeResponse.new(body: '', headers: {
    'Content-Type'  => 'application/json',
    'Set-Cookie'    => 'session=leak',
    'Authorization' => 'should-not-surface',
    'ETag'          => 'W/"abc"'
  })
  picked = HS.select_headers(resp)
  picked['content-type'] == 'application/json' &&
    picked['etag'] == 'W/"abc"' &&
    !picked.key?('set-cookie') &&
    !picked.key?('authorization')
end

# -----------------------------------------------------------------------------
# SafeHttpGet
# -----------------------------------------------------------------------------

section 'SafeHttpGet'

assert('rejects missing url') do
  reset_stub
  out = decode(T::SafeHttpGet.new.call({}))
  out['ok'] == false && out['error'].include?('url')
end

assert('rejects url outside default allowlist (http://)') do
  reset_stub
  out = decode(T::SafeHttpGet.new.call('url' => 'http://api.example.com/foo'))
  out['ok'] == false && out['error'].include?('allowlist')
end

assert('rejects unsupported scheme (ftp://) even if allowed by pattern') do
  reset_stub
  out = decode(T::SafeHttpGet.new.call(
    'url' => 'ftp://files.example.com/pub/a.txt',
    'allowed_urls' => ['ftp://*']
  ))
  out['ok'] == false && out['error'].include?('scheme')
end

assert('returns body and sha256 post_hash for successful GET') do
  reset_stub
  body = 'hello-world'
  StubHttp.response = FakeResponse.new(code: 200, body: body, headers: { 'Content-Type' => 'text/plain' })
  out = decode(T::SafeHttpGet.new.call('url' => 'https://api.example.com/ping'))
  out['ok'] == true &&
    out['status_code'] == 200 &&
    out['body'] == body &&
    out['post_hash'] == Digest::SHA256.hexdigest(body) &&
    out['pre_hash'].nil? &&
    out['truncated'] == false
end

assert('truncates body at max_bytes and marks truncated=true') do
  reset_stub
  big = 'x' * 4096
  StubHttp.response = FakeResponse.new(code: 200, body: big)
  out = decode(T::SafeHttpGet.new.call('url' => 'https://api.example.com/big', 'max_bytes' => 128))
  out['ok'] == true &&
    out['truncated'] == true &&
    out['body_bytes'] == 128 &&
    out['post_hash'] == Digest::SHA256.hexdigest(big.byteslice(0, 128))
end

assert('credentials from @safety are injected as headers') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: 'ok')
  safety = FakeSafety.new(creds: { 'Authorization' => 'Bearer SECRET' })
  tool = T::SafeHttpGet.new(safety)
  decode(tool.call('url' => 'https://api.example.com/me'))
  StubHttp.last_request['Authorization'] == 'Bearer SECRET'
end

assert('GET with bad URL returns error, not crash') do
  reset_stub
  out = decode(T::SafeHttpGet.new.call('url' => 'https://exa mple.com/ bad', 'allowed_urls' => ['https://*']))
  # URI.parse rejects spaces → either "invalid url" or allowlist — either is non-crash
  out['ok'] == false
end

# -----------------------------------------------------------------------------
# SafeHttpPost — body serialization
# -----------------------------------------------------------------------------

section 'SafeHttpPost body serialization'

assert('json body serializes with application/json content-type') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 201, body: '{}')
  out = decode(T::SafeHttpPost.new.call(
    'url' => 'https://api.example.com/things',
    'body' => { 'name' => 'alice', 'n' => 3 }
  ))
  out['ok'] == true &&
    StubHttp.last_request['Content-Type'] == 'application/json' &&
    JSON.parse(StubHttp.last_request.body) == { 'name' => 'alice', 'n' => 3 }
end

assert('form body URL-encodes and sets application/x-www-form-urlencoded') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: 'ok')
  decode(T::SafeHttpPost.new.call(
    'url' => 'https://api.example.com/login',
    'body_format' => 'form',
    'body' => { 'user' => 'a b', 'pw' => 'x&y' }
  ))
  StubHttp.last_request['Content-Type'] == 'application/x-www-form-urlencoded' &&
    StubHttp.last_request.body == 'user=a+b&pw=x%26y'
end

assert('raw body is sent unchanged with no default content-type') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: 'ok')
  decode(T::SafeHttpPost.new.call(
    'url' => 'https://api.example.com/blob',
    'body_format' => 'raw',
    'body' => '<xml>hi</xml>'
  ))
  StubHttp.last_request.body == '<xml>hi</xml>' && StubHttp.last_request['Content-Type'].nil?
end

assert('form body_format with non-hash body returns error') do
  reset_stub
  out = decode(T::SafeHttpPost.new.call(
    'url' => 'https://api.example.com/x',
    'body_format' => 'form',
    'body' => 'already-encoded'
  ))
  out['ok'] == false && out['error'].include?('form')
end

# -----------------------------------------------------------------------------
# SafeHttpPost — Idempotency-Key
# -----------------------------------------------------------------------------

section 'SafeHttpPost idempotency'

assert('Idempotency-Key header is always present on POST') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: '{}')
  out = decode(T::SafeHttpPost.new.call('url' => 'https://api.example.com/v1/jobs'))
  key = StubHttp.last_request['Idempotency-Key']
  !key.nil? && !key.empty? && out['idempotency_key'] == key
end

assert('explicit idempotency_key argument is used verbatim') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: '{}')
  out = decode(T::SafeHttpPost.new.call(
    'url' => 'https://api.example.com/v1/jobs',
    'idempotency_key' => 'user-key-42'
  ))
  StubHttp.last_request['Idempotency-Key'] == 'user-key-42' &&
    out['idempotency_key'] == 'user-key-42'
end

assert('invocation context idem_key is used when argument missing') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: '{}')
  safety = FakeSafety.new(idem_key: 'ctx-key-7')
  tool = T::SafeHttpPost.new(safety)
  out = decode(tool.call('url' => 'https://api.example.com/v1/jobs'))
  StubHttp.last_request['Idempotency-Key'] == 'ctx-key-7' &&
    out['idempotency_key'] == 'ctx-key-7'
end

assert('generated idempotency_key looks like a UUID when no source provided') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: '{}')
  out = decode(T::SafeHttpPost.new.call('url' => 'https://api.example.com/v1/jobs'))
  out['idempotency_key'].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
end

assert('user cannot suppress Idempotency-Key via headers argument') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: '{}')
  decode(T::SafeHttpPost.new.call(
    'url'     => 'https://api.example.com/v1/jobs',
    'headers' => { 'Idempotency-Key' => '' },
    'idempotency_key' => 'enforced-key'
  ))
  StubHttp.last_request['Idempotency-Key'] == 'enforced-key'
end

# -----------------------------------------------------------------------------
# SafeHttpPost — allowlist & response handling
# -----------------------------------------------------------------------------

section 'SafeHttpPost allowlist & response'

assert('rejects url outside allowlist') do
  reset_stub
  out = decode(T::SafeHttpPost.new.call('url' => 'http://internal/x'))
  out['ok'] == false && out['error'].include?('allowlist')
end

assert('POST returns post_hash of response body + pre_hash nil') do
  reset_stub
  resp_body = '{"id":"job_1"}'
  StubHttp.response = FakeResponse.new(code: 201, body: resp_body, headers: { 'Content-Type' => 'application/json' })
  out = decode(T::SafeHttpPost.new.call('url' => 'https://api.example.com/v1/jobs', 'body' => { 'x' => 1 }))
  out['ok'] == true &&
    out['status_code'] == 201 &&
    out['pre_hash'].nil? &&
    out['post_hash'] == Digest::SHA256.hexdigest(resp_body) &&
    out['headers']['content-type'] == 'application/json'
end

assert('POST response body is truncated at max_bytes') do
  reset_stub
  huge = 'y' * 8000
  StubHttp.response = FakeResponse.new(code: 200, body: huge)
  out = decode(T::SafeHttpPost.new.call('url' => 'https://api.example.com/v1/jobs', 'max_bytes' => 100))
  out['truncated'] == true && out['body_bytes'] == 100
end

assert('timeout argument propagates to HttpSupport.execute') do
  reset_stub
  StubHttp.response = FakeResponse.new(code: 200, body: 'ok')
  decode(T::SafeHttpPost.new.call('url' => 'https://api.example.com/x', 'timeout' => 7))
  StubHttp.last_timeout == 7
end

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

puts "\n#{'=' * 60}"
puts "RESULT: #{$pass} passed, #{$fail} failed"
puts "#{'=' * 60}"
unless $failed.empty?
  puts "\nFailed:"
  $failed.each { |d| puts "  - #{d}" }
end
exit($fail.zero? ? 0 : 1)
