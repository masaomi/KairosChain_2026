#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for P2.7: AttachServer — HTTP/SSE control plane for the daemon.
#
# Usage:
#   ruby KairosChain_mcp_server/test_attach_server.rb
#
# Philosophy: the attach server is a thin HTTP shell that ONLY enqueues
# commands into daemon.mailbox. We test it against a fake daemon that
# exposes just `mailbox` + `status_snapshot` + `list_mandates` — so the
# tests stay focused on the HTTP boundary, auth, and CommandMailbox
# contract without dragging in the full daemon lifecycle.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'net/http'
require 'uri'
require 'json'
require 'socket'
require 'time'

require 'kairos_mcp/daemon/command_mailbox'
require 'kairos_mcp/daemon/attach_server'

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

$pass = 0
$fail = 0
$failed_names = []

def assert(description, &block)
  result = block.call
  if result
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    $failed_names << description
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  $failed_names << description
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

# Fake daemon exposing just the surface AttachServer needs.
class FakeDaemon
  attr_reader :mailbox

  def initialize(snapshot: nil, mandates: nil)
    @mailbox = KairosMcp::Daemon::CommandMailbox.new
    @snapshot = snapshot || {
      state: 'running', pid: Process.pid, tick_count: 0,
      mailbox_size: 0, started_at: Time.now.utc.iso8601
    }
    @mandates = mandates || { active: [], queued: [] }
  end

  def status_snapshot
    @snapshot.merge(mailbox_size: @mailbox.size)
  end

  def list_mandates
    @mandates
  end
end

def pick_free_port
  srv = TCPServer.new('127.0.0.1', 0)
  port = srv.addr[1]
  srv.close
  port
end

def http_get(port, path, token: nil, host: '127.0.0.1')
  uri = URI("http://#{host}:#{port}#{path}")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{token}" if token
  Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) do |h|
    h.request(req)
  end
end

def http_post(port, path, body: nil, token: nil, host: '127.0.0.1')
  uri = URI("http://#{host}:#{port}#{path}")
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{token}" if token
  req['Content-Type'] = 'application/json'
  req.body = body ? JSON.generate(body) : ''
  Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) do |h|
    h.request(req)
  end
end

def start_server(root, port: nil, **opts)
  daemon = opts.delete(:daemon) || FakeDaemon.new
  srv = KairosMcp::Daemon::AttachServer.new(daemon: daemon, root: root, **opts)
  srv.start(port: port || pick_free_port)
  [srv, daemon]
end

# ---------------------------------------------------------------------------
# 1. Lifecycle / binding
# ---------------------------------------------------------------------------
section 'Lifecycle and binding'

Dir.mktmpdir do |root|
  srv, _d = start_server(root)
  assert('start populates port attr') { srv.port && srv.port > 0 }
  assert('start binds to 127.0.0.1 (loopback only)') { srv.host == '127.0.0.1' }
  assert('start writes token file') { File.exist?(srv.token_path) }

  # Sanity: server really is listening
  res = http_get(srv.port, '/v1/status', token: srv.current_token)
  assert('GET /v1/status responds 200 with valid token') { res.code == '200' }

  srv.stop
  assert('stop succeeds') { true }

  # After stop the port should no longer accept connections.
  port = srv.port
  rejected = false
  begin
    http_get(port, '/v1/status', token: 'whatever')
  rescue StandardError
    rejected = true
  end
  assert('stop closes the listener') { rejected }
end

# Non-loopback host must be refused.
Dir.mktmpdir do |root|
  refused = false
  daemon = FakeDaemon.new
  srv = KairosMcp::Daemon::AttachServer.new(daemon: daemon, root: root)
  begin
    srv.start(port: pick_free_port, host: '0.0.0.0')
  rescue ArgumentError
    refused = true
  end
  assert('binding to 0.0.0.0 is refused') { refused }
end

# ---------------------------------------------------------------------------
# 2. Token file permissions
# ---------------------------------------------------------------------------
section 'Token file permissions'

Dir.mktmpdir do |root|
  srv, _d = start_server(root)
  begin
    mode = File.stat(srv.token_path).mode & 0o777
    assert('token file has 0600 permissions') { mode == 0o600 }
    assert('token file contains hex token') do
      File.read(srv.token_path).match?(/\A[0-9a-f]{64}\z/)
    end
    assert('current_token matches token file on disk') do
      File.read(srv.token_path) == srv.current_token
    end
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 3. Auth — 401 without token, 200 with valid token
# ---------------------------------------------------------------------------
section 'Authentication'

Dir.mktmpdir do |root|
  srv, _d = start_server(root)
  begin
    res = http_get(srv.port, '/v1/status') # no auth header
    assert('GET /v1/status without token → 401') { res.code == '401' }
    assert('401 body is JSON with error field') do
      body = JSON.parse(res.body) rescue nil
      body && body['error'] == 'unauthorized'
    end

    res = http_get(srv.port, '/v1/status', token: 'wrong-token')
    assert('GET /v1/status with invalid token → 401') { res.code == '401' }

    res = http_get(srv.port, '/v1/status', token: srv.current_token)
    assert('GET /v1/status with valid token → 200') { res.code == '200' }
    assert('valid /v1/status returns JSON snapshot') do
      body = JSON.parse(res.body) rescue nil
      body && body['state'] == 'running'
    end
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 4. POST /v1/admin/shutdown → enqueues :shutdown
# ---------------------------------------------------------------------------
section 'POST /v1/admin/shutdown'

Dir.mktmpdir do |root|
  srv, daemon = start_server(root)
  begin
    res = http_post(srv.port, '/v1/admin/shutdown', token: srv.current_token)
    assert('shutdown endpoint returns 200') { res.code == '200' }
    body = JSON.parse(res.body)
    assert('shutdown response has command_id') { body['command_id'].is_a?(String) }

    drained = daemon.mailbox.drain
    assert('shutdown enqueued :shutdown into mailbox') do
      drained.size == 1 && drained[0][:type] == :shutdown
    end

    # GET should be rejected with 405
    res = http_get(srv.port, '/v1/admin/shutdown', token: srv.current_token)
    assert('GET /v1/admin/shutdown → 405') { res.code == '405' }
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 5. POST /v1/admin/reload → enqueues :reload
# ---------------------------------------------------------------------------
section 'POST /v1/admin/reload'

Dir.mktmpdir do |root|
  srv, daemon = start_server(root)
  begin
    res = http_post(srv.port, '/v1/admin/reload', token: srv.current_token)
    assert('reload endpoint returns 200') { res.code == '200' }

    drained = daemon.mailbox.drain
    assert('reload enqueued :reload into mailbox') do
      drained.size == 1 && drained[0][:type] == :reload
    end
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 6. POST /v1/mandates → enqueues :create_mandate
# ---------------------------------------------------------------------------
section 'POST /v1/mandates'

Dir.mktmpdir do |root|
  srv, daemon = start_server(root)
  begin
    payload = { 'goal' => 'test goal', 'priority' => 5 }
    res = http_post(srv.port, '/v1/mandates', body: payload,
                                              token: srv.current_token)
    assert('create mandate returns 200') { res.code == '200' }

    drained = daemon.mailbox.drain
    assert('create enqueued :create_mandate') do
      drained.size == 1 && drained[0][:type] == :create_mandate
    end
    assert('create_mandate payload preserves goal') do
      drained[0][:payload]['goal'] == 'test goal'
    end
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 7. POST /v1/mandates/:id/stop → enqueues :stop_mandate
# ---------------------------------------------------------------------------
section 'POST /v1/mandates/:id/stop'

Dir.mktmpdir do |root|
  srv, daemon = start_server(root)
  begin
    res = http_post(srv.port, '/v1/mandates/abc-123/stop',
                    token: srv.current_token)
    assert('stop mandate returns 200') { res.code == '200' }

    drained = daemon.mailbox.drain
    assert('stop enqueued :stop_mandate with correct id') do
      drained.size == 1 && drained[0][:type] == :stop_mandate &&
        drained[0][:payload][:mandate_id] == 'abc-123'
    end
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 8. GET /v1/mandates → read-only list
# ---------------------------------------------------------------------------
section 'GET /v1/mandates'

Dir.mktmpdir do |root|
  daemon = FakeDaemon.new(
    mandates: { active: [{ id: 'a1', goal: 'x' }], queued: [] }
  )
  srv, _d = start_server(root, daemon: daemon)
  begin
    res = http_get(srv.port, '/v1/mandates', token: srv.current_token)
    assert('GET /v1/mandates returns 200') { res.code == '200' }
    body = JSON.parse(res.body)
    assert('GET /v1/mandates returns active+queued fields') do
      body['active'].is_a?(Array) && body['queued'].is_a?(Array) &&
        body['active'].first['id'] == 'a1'
    end
    assert('GET /v1/mandates did NOT touch the mailbox') do
      daemon.mailbox.empty?
    end
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 9. GET /v1/events → SSE stub responds with text/event-stream
# ---------------------------------------------------------------------------
section 'GET /v1/events (SSE stub)'

Dir.mktmpdir do |root|
  srv, _d = start_server(root)
  begin
    res = http_get(srv.port, '/v1/events', token: srv.current_token)
    assert('events endpoint returns 200') { res.code == '200' }
    assert('events Content-Type is text/event-stream') do
      (res['Content-Type'] || '').start_with?('text/event-stream')
    end

    res2 = http_get(srv.port, '/v1/events') # no auth
    assert('events endpoint requires auth') { res2.code == '401' }
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 10. Token rotation — old token valid during grace period
# ---------------------------------------------------------------------------
section 'Token rotation with grace period'

Dir.mktmpdir do |root|
  fake_time = Time.now.utc
  clock = -> { fake_time }
  daemon = FakeDaemon.new
  srv = KairosMcp::Daemon::AttachServer.new(
    daemon: daemon, root: root, grace_period: 60, clock: clock
  )
  srv.start(port: pick_free_port)
  begin
    old_token = srv.current_token
    srv.generate_token!
    new_token = srv.current_token

    assert('rotation produces a different token') { old_token != new_token }
    assert('token file updated to new token') do
      File.read(srv.token_path) == new_token
    end

    res_new = http_get(srv.port, '/v1/status', token: new_token)
    assert('new token works after rotation') { res_new.code == '200' }

    res_old = http_get(srv.port, '/v1/status', token: old_token)
    assert('old token still works during grace period') { res_old.code == '200' }

    # Advance past the grace period.
    fake_time += 61
    res_old2 = http_get(srv.port, '/v1/status', token: old_token)
    assert('old token rejected after grace period expires') do
      res_old2.code == '401'
    end
    res_new2 = http_get(srv.port, '/v1/status', token: new_token)
    assert('new token still valid after grace period expires') do
      res_new2.code == '200'
    end
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# 11. Mailbox-full → 503
# ---------------------------------------------------------------------------
section 'Mailbox full → 503'

Dir.mktmpdir do |root|
  daemon = FakeDaemon.new
  # Force tiny mailbox.
  mb = KairosMcp::Daemon::CommandMailbox.new(max_size: 1)
  daemon.instance_variable_set(:@mailbox, mb)

  srv = KairosMcp::Daemon::AttachServer.new(daemon: daemon, root: root)
  srv.start(port: pick_free_port)
  begin
    mb.enqueue(:reload) # fill it
    res = http_post(srv.port, '/v1/admin/reload', token: srv.current_token)
    assert('mailbox-full returns 503') { res.code == '503' }
    body = JSON.parse(res.body) rescue {}
    assert('mailbox-full body has error=mailbox_full') do
      body['error'] == 'mailbox_full'
    end
  ensure
    srv.stop
  end
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts "\n#{'=' * 60}"
puts "RESULT: #{$pass} passed, #{$fail} failed"
puts '=' * 60
unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end

exit($fail.zero? ? 0 : 1)
