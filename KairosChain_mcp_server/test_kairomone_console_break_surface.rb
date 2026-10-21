#!/usr/bin/env ruby
# frozen_string_literal: true
# Kairomone console, adversarial pass, lens "local HTTP surface and the
# approval channel" (design log/kairomone_console_design_v0.3_20261021.md,
# plan log/kairomone_console_impl_plan_v0.2_20261021.md).
#
# Two kinds of test live here:
# - DEFECT tests (names start with test_defect_) fail against the
#   implementation as it was broken and pass once the named defect is fixed.
# - PIN tests keep the attacks that held from coming back unnoticed.
#
# The server tests drive Kairomone::Console::Server, Session and Secret
# in-process over 127.0.0.1, with raw sockets where Net::HTTP cannot write the
# request. The entry test installs the SkillSet into a temporary host, runs
# the real scripts/kairomone_console.rb under a pseudo-terminal with a fake
# `claude` (no model, no network) and inspects the child with lsof. Every
# process started here has the temporary root in its command line, and
# teardown kills only those.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require_relative 'templates/skillsets/kairomone/lib/kairomone/console'
require 'kairos_mcp/skillset_manager'
require 'tmpdir'
require 'open3'
require 'pty'
require 'socket'
require 'net/http'
require 'minitest/autorun'
require 'minitest/mock'

module BreakSurfaceLines
  SESSION_ID = '0b9f6c1e-5d1a-4c55-9f7e-1d2b3c4d5e6f'
  module_function

  def echo(request_id, word)
    { 'type' => 'control_response',
      'response' => { 'subtype' => 'success', 'request_id' => request_id, 'response' => { 'mode' => word } } }
  end

  def tool_use(id, name, input)
    { 'type' => 'assistant', 'session_id' => SESSION_ID,
      'message' => { 'role' => 'assistant', 'content' => [{ 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input }] } }
  end

  # Shape measured in log/kairomone_console_probes_20261021/m11 (Bash asks carry a description).
  def can_use_tool(request_id, tool_use_id, name, input)
    { 'type' => 'control_request', 'request_id' => request_id,
      'request' => { 'subtype' => 'can_use_tool', 'tool_name' => name, 'display_name' => name, 'input' => input,
                     'description' => input['description'], 'permission_suggestions' => [], 'tool_use_id' => tool_use_id } }
  end
end

module BreakSurfaceHttp
  CONTRACT = { 'x-frame-options' => 'DENY', 'x-content-type-options' => 'nosniff' }.freeze

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # One request over a fresh socket; returns [status code (String or nil), headers (lowercase => [values]), body].
  def raw(text, read_timeout: 5)
    socket = TCPSocket.new('127.0.0.1', @port)
    socket.write(text)
    buffer = +''
    deadline = monotonic + read_timeout
    while monotonic < deadline
      next unless socket.wait_readable(0.2)

      chunk = socket.read_nonblock(65_536, exception: false)
      break if chunk.nil?
      next if chunk == :wait_readable

      buffer << chunk
    end
    head, body = buffer.split("\r\n\r\n", 2)
    lines = head.to_s.split("\r\n")
    status = lines.shift.to_s[%r{\AHTTP/\d\.\d (\d{3})}, 1]
    headers = Hash.new { |h, k| h[k] = [] }
    lines.each do |line|
      name, value = line.split(':', 2)
      headers[name.to_s.downcase] << value.to_s.strip
    end
    [status, headers, body.to_s]
  rescue Errno::ECONNRESET, Errno::EPIPE
    [nil, {}, buffer.to_s]
  ensure
    socket&.close
  end

  def csp_directives(value)
    value.to_s.split(';').map(&:strip).reject(&:empty?).to_h do |directive|
      name, *rest = directive.split(/\s+/)
      [name, rest.join(' ')]
    end
  end

  # The contract headers of design v0.3 § Mechanism, as raw header lines.
  def contract_gaps(headers)
    gaps = []
    csp = csp_directives(headers['content-security-policy'].first)
    gaps << 'CSP default-src' unless csp['default-src'] == "'none'"
    gaps << 'CSP frame-ancestors' unless csp['frame-ancestors'] == "'none'"
    CONTRACT.each { |name, value| gaps << name unless headers[name] == [value] }
    gaps << 'cache-control' unless headers['cache-control'].join(',').split(',').map(&:strip).include?('no-store')
    gaps << 'set-cookie' if headers.key?('set-cookie') && !headers['set-cookie'].empty?
    gaps << 'access-control-*' unless headers.keys.grep(/\Aaccess-control-/).all? { |k| headers[k].empty? }
    gaps
  end
end

class KairomoneConsoleBreakSurfaceServerTest < Minitest::Test
  include BreakSurfaceHttp
  L = BreakSurfaceLines
  KC = Kairomone::Console
  HEX64 = /\A[0-9a-f]{64}\z/
  STYLE = "\n  main { color: #222; }\n"
  SCRIPT = "\n  document.documentElement.dataset.fixture = 'break-surface';\n"
  PAGE = "<!doctype html>\n<html lang=\"ja\"><head><meta charset=\"utf-8\"><title>fixture</title><style>#{STYLE}</style></head>\n" \
         "<body><main>fixture</main><script>#{SCRIPT}</script></body></html>\n"

  def setup
    @tmp = File.realpath(Dir.mktmpdir('kairomone-break-surface-'))
    page = File.join(@tmp, 'console.html')
    File.write(page, PAGE)
    @now = Time.utc(2031, 2, 3, 4, 5, 6)
    @writes = []
    @writes_lock = Mutex.new
    @session = KC::Session.new(writer: ->(hash) { @writes_lock.synchronize { @writes << JSON.parse(JSON.generate(hash)) } },
                               clock: -> { @now })
    @session.start!
    @secret = KC::Secret.new(clock: -> { @now })
    @server = KC::Server.new(session: @session, secret: @secret, status_reader: -> { { 'data_dir' => '/fixture' } },
                             page_path: page, port: 0).start
    @port = @server.port
    @host = "127.0.0.1:#{@port}"
    @origin = "http://#{@host}"
    @bootstrap = @secret.issue_bootstrap
  end

  def teardown
    @server&.shutdown
    FileUtils.remove_entry_secure(@tmp) if @tmp && File.directory?(@tmp)
  end

  def writes = @writes_lock.synchronize { @writes.dup }
  def feed(line) = @session.handle_line("#{JSON.generate(line)}\n")

  def mode_request_id
    writes.find { |w| w['type'] == 'control_request' && w.dig('request', 'subtype') == 'set_permission_mode' }['request_id']
  end

  def confirm_mode! = feed(L.echo(mode_request_id, 'default'))

  def answers_for(id)
    writes.select { |w| w['type'] == 'control_response' && w.dig('response', 'request_id') == id }
  end

  def allows = writes.select { |w| w['type'] == 'control_response' && w.dig('response', 'response', 'behavior') == 'allow' }

  def request(method, path, session: nil, origin: (method == :post ? :page : nil), host: nil, headers: {}, body: nil,
              read_timeout: 10)
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete,
              patch: Net::HTTP::Patch, head: Net::HTTP::Head, options: Net::HTTP::Options }.fetch(method)
    req = klass.new(path)
    req['Host'] = host if host
    req['Origin'] = origin == :page ? @origin : origin if origin
    req['X-Kairomone-Session'] = session if session
    headers.each { |name, value| req[name] = value }
    if body || %i[post put patch].include?(method)
      req.body = body.is_a?(String) ? body : JSON.generate(body || {})
      req['Content-Type'] ||= 'application/json'
    end
    Net::HTTP.start('127.0.0.1', @port, open_timeout: 5, read_timeout: read_timeout) { |http| http.request(req) }
  end

  def exchange(bootstrap = @bootstrap, **options)
    request(:post, '/session', headers: { 'X-Kairomone-Bootstrap' => bootstrap }, **options)
  end

  def session!(bootstrap = @bootstrap)
    res = exchange(bootstrap)
    assert_equal '200', res.code, res.body
    value = JSON.parse(res.body)['session']
    assert_match HEX64, value
    value
  end

  # Puts one Bash request in front of the owner, as the CLI does after a page message.
  def ask!(request_id, command, tool_use_id: "toolu_#{request_id.gsub(/[^A-Za-z0-9]/, '')}")
    input = { 'command' => command, 'description' => "Run #{command}" }
    feed(L.tool_use(tool_use_id, 'Bash', input))
    feed(L.can_use_tool(request_id, tool_use_id, 'Bash', input))
    input
  end

  # ---------------------------------------------------------------- defects

  # DEFECT (P2). The plan's contract says every response carries the CSP
  # (frame-ancestors 'none'), X-Frame-Options DENY, nosniff and no-store.
  # Requests WEBrick refuses before the servlet runs (a path that climbs above
  # the root after decoding, an over-long URI, oversized headers, a malformed
  # request line, `OPTIONS *`) are answered by WEBrick's own error page with
  # none of them; `/%2e%2e%2Fx` is reachable from any page (the browser does
  # not fold "%2e%2e%2F" into a dot segment), so the error page is frameable.
  def test_defect_responses_webrick_writes_itself_carry_the_contract_headers
    probes = {
      'path above the root after decoding' => "GET /%2e%2e%2Fx HTTP/1.1\r\nHost: #{@host}\r\nConnection: close\r\n\r\n",
      'URI longer than 2083 bytes' => "GET /#{'a' * 2100} HTTP/1.1\r\nHost: #{@host}\r\nConnection: close\r\n\r\n",
      'headers larger than 112 KiB' => "GET / HTTP/1.1\r\nHost: #{@host}\r\n#{"X-Pad: #{'p' * 4000}\r\n" * 30}\r\n",
      'malformed request line' => "NOT A REQUEST LINE\r\nHost: #{@host}\r\n\r\n",
      'OPTIONS *' => "OPTIONS * HTTP/1.1\r\nHost: #{@host}\r\nConnection: close\r\n\r\n"
    }
    gaps = probes.filter_map do |name, text|
      status, headers, = raw(text)
      missing = contract_gaps(headers)
      "#{name} (#{status.inspect}): #{missing.join(', ')}" unless status && missing.empty?
    end
    assert_empty gaps, 'every response, including the ones WEBrick writes itself, carries the contract headers'
  end

  # DEFECT (P2). "All requests need Host: 127.0.0.1:<port> (else 403). All
  # except GET / and POST /session need X-Kairomone-Session (else 403)."
  # WEBrick answers `OPTIONS *` itself, 200 with an Allow header, whatever the
  # Host and with no session.
  def test_defect_options_asterisk_follows_the_host_and_session_rules
    [["evil.example:#{@port}", 'a DNS-rebound Host'], [@host, 'the right Host and no session']].each do |host, what|
      status, = raw("OPTIONS * HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
      assert_equal '403', status, "OPTIONS * with #{what}"
    end
  end

  # DEFECT (P2). Pressing Enter (Secret#issue_bootstrap) "revokes the previous
  # session", but a long poll that passed the session check before the
  # revocation keeps waiting and then delivers events emitted after it: the
  # revoked holder keeps reading the conversation for up to 25 s.
  def test_defect_a_revoked_session_receives_nothing_emitted_after_the_revocation
    old = session!
    confirm_mode!
    after = @session.last_seq
    poll = Thread.new { request(:get, "/events?after=#{after}", session: old, read_timeout: 40) }
    sleep 0.4
    assert poll.alive?, 'fixture: the long poll passed the session check and is waiting'
    fresh = @secret.issue_bootstrap # what Enter at the console terminal does
    session!(fresh)
    @session.notice('EMITTED-AFTER-REVOCATION')
    res = poll.join(30)&.value
    refute_nil res, 'the long poll ended'
    leaked = res.code == '200' && JSON.parse(res.body)['events'].any? { |e| e['text'] == 'EMITTED-AFTER-REVOCATION' }
    refute leaked, "the revoked session's long poll delivered an event emitted after the revocation (#{res.code})"
  ensure
    poll&.kill
  end

  # DEFECT (P2). The route is matched on WEBrick's decoded and normalized path,
  # so the server's own `id.include?('/')` check runs too late: the page sends
  # '/permission/' + encodeURIComponent(id), and an id with "/" and dot
  # segments then addresses another pending request or another route. Here the
  # owner allows the card shown for "zz/../req-B" (a harmless `date`) and the
  # console allows req-B (`rm`) instead; an id "../stop" turns a Deny click
  # into a stop. The CLI's measured ids are UUIDs, hence P2.
  def test_defect_an_encoded_request_id_cannot_address_another_request_or_route
    session = session!
    confirm_mode!
    ask!('req-B', 'rm -rf ~/precious')
    ask!('zz/../req-B', 'date', tool_use_id: 'toolu_shown')
    ask!('../stop', 'true', tool_use_id: 'toolu_stop')
    # encodeURIComponent('zz/../req-B') == 'zz%2F..%2Freq-B'; encodeURIComponent('../stop') == '..%2Fstop'
    request(:post, '/permission/zz%2F..%2Freq-B', session: session, body: { 'decision' => 'allow' })
    assert_includes @session.pending_ids, 'req-B', 'an answer for another card never answers req-B'
    assert_empty answers_for('req-B'), 'nothing is written for req-B'
    request(:post, '/permission/..%2Fstop', session: session, body: { 'decision' => 'deny' })
    refute @session.stopped?, 'an answer for a permission card never stops the console'
  end

  # DEFECT (P2). The bootstrap "expires 10 minutes after it was printed", but
  # its age is measured on the wall clock (Time.now): a backward clock step
  # (NTP, manual) revives a URL whose real lifetime has passed. Shown with a
  # one-second lifetime and the wall clock stepped back to the issue time.
  def test_defect_the_bootstrap_lifetime_follows_elapsed_time_not_the_wall_clock
    secret = KC::Secret.new(bootstrap_ttl: 1)
    bootstrap = secret.issue_bootstrap
    issued = Time.now
    sleep 1.3
    got = Time.stub(:now, issued) { secret.exchange(bootstrap) }
    assert_nil got, 'a bootstrap older than its lifetime is refused even after the wall clock steps back'
  end

  # ------------------------------------------------------------------- pins

  def test_pin_every_host_but_the_exact_one_is_refused_and_spends_nothing
    hosts = ["localhost:#{@port}", '127.0.0.1', "127.0.0.1:#{@port + 1}", "127.0.0.1:#{@port}0", "evil.example:#{@port}",
             "127.0.0.1.nip.io:#{@port}", "127.0.0.1.:#{@port}", "0177.0.0.1:#{@port}", "[::1]:#{@port}", '']
    hosts.each do |host|
      status, = raw("POST /session HTTP/1.1\r\nHost: #{host}\r\nOrigin: #{@origin}\r\nX-Kairomone-Bootstrap: #{@bootstrap}\r\n" \
                    "Content-Length: 2\r\nConnection: close\r\n\r\n{}")
      assert_equal '403', status, "POST /session with Host #{host.inspect}"
      status, = raw("GET / HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
      assert_equal '403', status, "GET / with Host #{host.inspect}"
    end
    { 'the Host twice' => "Host: #{@host}\r\nHost: #{@host}\r\n",
      'the Host and a rebound Host' => "Host: #{@host}\r\nHost: evil.example:#{@port}\r\n",
      'a folded Host' => "Host: #{@host}\r\n evil\r\n",
      'no Host' => '' }.each do |what, lines|
      status, = raw("GET / HTTP/1.1\r\n#{lines}Connection: close\r\n\r\n")
      assert_equal '403', status, what
    end
    status, = raw("GET /events?after=0 HTTP/1.0\r\nConnection: close\r\n\r\n")
    assert_equal '403', status, 'HTTP/1.0 with no Host'
    session = session! # none of the refused exchanges spent the bootstrap
    status, = raw("GET /events?after=0 HTTP/1.1\r\nHost: #{@host}\r\nX-Forwarded-Host: evil.example\r\n" \
                  "X-Kairomone-Session: #{session}\r\nConnection: close\r\n\r\n")
    assert_equal '200', status, 'X-Forwarded-Host is not read as the host'
    status, = raw("GET /events?after=0 HTTP/1.1\r\nHost: evil.example:#{@port}\r\nX-Kairomone-Session: #{session}\r\nConnection: close\r\n\r\n")
    assert_equal '403', status, 'a valid session does not excuse a rebound Host'
    assert_equal 1, writes.length, 'only the start mode request was ever written'
  end

  def test_pin_every_post_needs_the_exact_origin_and_a_foreign_origin_is_refused_on_every_method
    session = session!
    confirm_mode!
    ask!('req-origin', 'echo hi')
    before = writes.length
    bad = [nil, 'null', 'file://', "http://127.0.0.1:#{@port + 1}", "HTTP://127.0.0.1:#{@port}", "http://127.0.0.1:#{@port}/",
           "http://localhost:#{@port}", "https://127.0.0.1:#{@port}", "http://127.0.0.1:#{@port}.evil.example"]
    posts = { '/message' => { 'text' => 'hello' }, '/permission/req-origin' => { 'decision' => 'allow' },
              '/mode' => { 'mode' => 'auto' }, '/interrupt' => {}, '/stop' => {} }
    bad.each do |origin|
      assert_equal '403', exchange(origin: origin).code, "POST /session Origin #{origin.inspect}"
      posts.each do |path, body|
        assert_equal '403', request(:post, path, session: session, origin: origin, body: body).code, "POST #{path} Origin #{origin.inspect}"
      end
    end
    status, = raw("POST /mode HTTP/1.1\r\nHost: #{@host}\r\nOrigin: #{@origin}\r\nOrigin: #{@origin}\r\n" \
                  "X-Kairomone-Session: #{session}\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"mode\":\"auto\"}")
    assert_equal '403', status, 'a duplicated Origin is refused'
    (bad - [nil]).each do |origin|
      %i[get head options put delete patch].each do |method|
        res = request(method, method == :get ? '/events?after=0' : '/message', session: session, origin: origin)
        assert_equal '403', res.code, "#{method.upcase} with Origin #{origin.inspect}"
      end
    end
    %i[put delete patch].each do |method|
      refute_match(/\A2/, request(method, '/permission/req-origin', session: session, body: { 'decision' => 'allow' }).code)
    end
    assert_equal before, writes.length, 'no refused request wrote anything to the child'
    assert_equal ['req-origin'], @session.pending_ids
    refute @session.stopped?
    assert_equal 'default', @session.mode_word
  end

  def test_pin_session_header_variants_are_refused_on_every_session_route
    session = session!
    routes = [[:get, '/events?after=0'], [:get, '/status'], [:post, '/message'], [:post, '/permission/req-x'],
              [:post, '/mode'], [:post, '/interrupt'], [:post, '/stop']]
    routes.each do |method, path|
      [nil, '', 'x', @bootstrap, '0' * 64, session.upcase, session[0, 63], "#{session}0"].each do |value|
        assert_equal '403', request(method, path, session: value, body: method == :post ? {} : nil).code,
                     "#{method} #{path} with session #{value.inspect}"
      end
      dup = method == :get ? '' : "Origin: #{@origin}\r\nContent-Length: 2\r\n"
      status, = raw("#{method.upcase} #{path} HTTP/1.1\r\nHost: #{@host}\r\n#{dup}X-Kairomone-Session: #{session}\r\n" \
                    "X-Kairomone-Session: #{session}\r\nConnection: close\r\n\r\n#{method == :post ? '{}' : ''}")
      assert_equal '403', status, "#{method} #{path} with the session header twice"
    end
    status, = raw("POST /interrupt HTTP/1.1\r\nHost: #{@host}\r\nOrigin: #{@origin}\r\nTransfer-Encoding: chunked\r\n" \
                  "Connection: close\r\n\r\n2\r\n{}\r\n0\r\nX-Kairomone-Session: #{session}\r\n\r\n")
    assert_equal '403', status, 'a session carried only in a chunked trailer is refused'
    assert_equal 1, writes.length, 'only the start mode request was written'
    refute @session.stopped?
  end

  def test_pin_the_bootstrap_is_spent_once_under_concurrency_and_a_reissue_kills_every_older_value
    10.times { assert_equal '403', exchange(SecureRandom.hex(32)).code, 'a wrong guess' }
    codes = Array.new(16) { Thread.new { exchange.code } }.map(&:value)
    assert_equal 1, codes.count('200'), "exactly one of 16 concurrent exchanges wins: #{codes.tally}"
    assert_equal '403', exchange.code, 'replay'
    unused = @secret.issue_bootstrap # printed, never opened
    second = @secret.issue_bootstrap
    assert_equal '403', exchange(unused).code, 'an unused bootstrap from before a reissue'
    old_session = session!(second)
    fresh = @secret.issue_bootstrap
    assert_equal '403', exchange(second).code, 'a spent bootstrap stays spent after a reissue'
    [[:get, '/events?after=0'], [:get, '/status'], [:post, '/interrupt'], [:post, '/stop']].each do |method, path|
      assert_equal '403', request(method, path, session: old_session).code, "revoked session on #{path}"
    end
    session = session!(fresh)
    assert_equal '403', exchange(fresh).code, 'the fresh bootstrap is single-use too'
    assert_equal '200', request(:get, '/events?after=0', session: session).code
    refute_equal old_session, session
    refute @session.stopped?
  end

  def test_pin_an_expired_bootstrap_is_spent_and_never_revived_by_the_injected_clock
    @now += 599
    assert_equal '403', exchange('f' * 64).code, 'a wrong value just before expiry'
    @now += 1 # exactly the lifetime
    assert_equal '403', exchange.code, 'expired at 600 s'
    @now -= 3600
    assert_equal '403', exchange.code, 'an expired bootstrap is spent; moving the injected clock back does not revive it'
    fresh = @secret.issue_bootstrap
    @now += 599
    assert_match HEX64, session!(fresh), 'a fresh bootstrap works within its lifetime'
  end

  def test_pin_a_permission_is_answered_once_unknown_ids_are_not_found_and_bad_decisions_change_nothing
    session = session!
    confirm_mode!
    ask!('req-once', 'echo once')
    ['allow ', 'ALLOW', 'approve', true, nil, ['allow'], { 'behavior' => 'allow' }].each do |decision|
      code = request(:post, '/permission/req-once', session: session, body: { 'decision' => decision }).code
      refute_match(/\A2/, code, "decision #{decision.inspect}")
    end
    assert_equal '404', request(:post, '/permission/req-unknown', session: session, body: { 'decision' => 'allow' }).code
    assert_equal '404', request(:post, '/permission/REQ-ONCE', session: session, body: { 'decision' => 'allow' }).code
    assert_empty answers_for('req-once'), 'no refused answer reached the child'
    codes = %w[allow deny allow deny].map do |decision|
      Thread.new { request(:post, '/permission/req-once', session: session, body: { 'decision' => decision }).code }
    end.map(&:value)
    assert_equal %w[200 409 409 409], codes.sort, 'one answer wins, the rest are told it was answered'
    assert_equal 1, answers_for('req-once').length, 'exactly one answer reached the child'
    assert_equal '409', request(:post, '/permission/req-once', session: session, body: { 'decision' => 'allow' }).code
  end

  def test_pin_a_request_pending_across_a_reissue_is_answered_only_by_the_new_session
    old = session!
    confirm_mode!
    ask!('req-across', 'echo across')
    fresh = @secret.issue_bootstrap
    assert_equal '403', request(:post, '/permission/req-across', session: old, body: { 'decision' => 'allow' }).code
    assert_equal ['req-across'], @session.pending_ids, 'a reissue neither answers nor drops a pending request'
    session = session!(fresh)
    replay = JSON.parse(request(:get, '/events?after=0', session: session).body)['events']
    assert(replay.any? { |e| e['kind'] == 'permission_request' && e['request_id'] == 'req-across' }, 'the new page is shown it')
    assert_equal '200', request(:post, '/permission/req-across', session: session, body: { 'decision' => 'deny' }).code
    assert_equal ['deny'], answers_for('req-across').map { |a| a.dig('response', 'response', 'behavior') }
  end

  def test_pin_after_stop_nothing_is_allowed_and_late_requests_are_denied
    session = session!
    confirm_mode!
    ask!('req-before-stop', 'echo before')
    assert_equal '202', request(:post, '/stop', session: session).code
    assert_equal '409', request(:post, '/permission/req-before-stop', session: session, body: { 'decision' => 'allow' }).code
    ask!('req-after-stop', 'echo after')
    assert_equal '409', request(:post, '/permission/req-after-stop', session: session, body: { 'decision' => 'allow' }).code
    assert_empty allows, 'no allow is ever written once the console stops'
    assert_equal %w[deny deny], (answers_for('req-before-stop') + answers_for('req-after-stop')).map { |a| a.dig('response', 'response', 'behavior') }
    assert_equal '409', request(:post, '/message', session: session, body: { 'text' => 'hello' }).code
    assert_equal '409', request(:post, '/mode', session: session, body: { 'mode' => 'auto' }).code
  end

  def test_pin_oversized_and_malformed_bodies_change_nothing
    session = session!
    confirm_mode!
    ask!('req-body', 'echo body')
    before = writes.length
    big = JSON.generate('decision' => 'allow', 'pad' => 'a' * 70_000)
    assert_equal '413', request(:post, '/permission/req-body', session: session, body: big).code
    chunks = [big[0, 40_000], big[40_000..]].map { |part| "#{part.bytesize.to_s(16)}\r\n#{part}\r\n" }.join
    status, = raw("POST /permission/req-body HTTP/1.1\r\nHost: #{@host}\r\nOrigin: #{@origin}\r\nX-Kairomone-Session: #{session}\r\n" \
                  "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n#{chunks}0\r\n\r\n")
    assert_equal '413', status, 'a chunked body over 64 KiB'
    ['', '[]', '"allow"', '{"decision":', "\xEF\xBB\xBF{\"decision\":\"allow\"}", '[' * 200 + ']' * 200,
     'decision=allow'].each do |body|
      code = request(:post, '/permission/req-body', session: session, body: body.b,
                                                    headers: { 'Content-Type' => body.include?('=') ? 'application/x-www-form-urlencoded' : 'application/json' }).code
      assert_equal '400', code, "body #{body[0, 20].inspect}"
    end
    status, = raw("POST /permission/req-body HTTP/1.1\r\nHost: #{@host}\r\nOrigin: #{@origin}\r\nX-Kairomone-Session: #{session}\r\n" \
                  "Content-Length: 20\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n14\r\n{\"decision\":\"allow\"}\r\n0\r\n\r\n")
    refute_match(/\A2/, status.to_s, 'Content-Length together with chunked is refused')
    status, = raw("POST /permission/req-body HTTP/1.1\r\nHost: #{@host}\r\nOrigin: #{@origin}\r\nX-Kairomone-Session: #{session}\r\n" \
                  "Transfer-Encoding: gzip\r\nConnection: close\r\n\r\n")
    refute_match(/\A2/, status.to_s, 'a transfer coding other than chunked is refused')
    assert_equal before, writes.length, 'no refused body wrote anything'
    assert_equal ['req-body'], @session.pending_ids
  end

  # Spellings of a session route (doubled slash, %-encoded letters, dot
  # segments) never get past the session check; with the session they reach
  # the route or are not found, depending on how strictly paths are matched.
  def test_pin_path_variants_reach_session_routes_only_with_the_session
    session = session!
    %w[//events?after=0 /%65vents?after=0 /x/../events?after=0 /./events?after=0 //status /%73tatus].each do |path|
      status, = raw("GET #{path} HTTP/1.1\r\nHost: #{@host}\r\nConnection: close\r\n\r\n")
      assert_equal '403', status, "#{path} without the session"
      status, = raw("GET #{path} HTTP/1.1\r\nHost: #{@host}\r\nX-Kairomone-Session: #{session}\r\nConnection: close\r\n\r\n")
      assert_includes %w[200 400 404], status, "#{path} with the session"
    end
    %w[/events/ /EVENTS /status/ /index.html /session].each do |path|
      refute_equal '200', request(:get, path, session: session).code, path
    end
    %w[-1 abc 0x1 1e3 0000000000000001].each do |after|
      assert_equal '400', request(:get, "/events?after=#{after}", session: session).code, "after=#{after} is refused at once"
    end
    status, = raw("GET /%2e%2e%2Fevents HTTP/1.1\r\nHost: #{@host}\r\nX-Kairomone-Session: #{session}\r\nConnection: close\r\n\r\n")
    refute_equal '200', status, 'a path that climbs above the root after decoding'
  end

  def test_pin_every_servlet_answer_carries_the_contract_headers
    session = session!
    confirm_mode!
    responses = {
      'page 200' => request(:get, '/'),
      'events 200' => request(:get, '/events?after=0', session: session),
      'message 202' => request(:post, '/message', session: session, body: { 'text' => 'hello' }),
      'bad request 400' => request(:post, '/mode', session: session, body: '['),
      'forbidden 403' => request(:get, '/status'),
      'not found 404' => request(:get, '/nope', session: session),
      'method 405' => request(:post, '/events', session: session),
      'conflict 409' => request(:post, '/message', session: session, body: { 'text' => 'again' }),
      'too large 413' => request(:post, '/mode', session: session, body: 'a' * 70_000),
      'preflight' => request(:options, '/message', origin: 'http://evil.example',
                                                   headers: { 'Access-Control-Request-Method' => 'POST',
                                                              'Access-Control-Request-Headers' => 'x-kairomone-session' })
    }
    responses.each do |name, res|
      headers = res.to_hash.transform_keys(&:downcase)
      headers.default_proc = ->(h, k) { h[k] = [] }
      assert_empty contract_gaps(headers), "#{name} (#{res.code})"
    end
  end

  def test_pin_two_pages_on_one_session_see_the_same_events_and_a_long_poll_ends_with_the_server
    session = session!
    after = @session.last_seq
    pages = Array.new(2) { Thread.new { request(:get, "/events?after=#{after}", session: session, read_timeout: 40) } }
    sleep 0.3
    confirm_mode!
    bodies = pages.map { |t| JSON.parse(t.join(10).value.body) }
    assert_equal bodies[0]['events'], bodies[1]['events'], 'both pages receive the same events'
    refute_empty bodies[0]['events']
    waiting = Thread.new do
      request(:get, "/events?after=#{@session.last_seq}", session: session, read_timeout: 40).code
    rescue StandardError => e
      e.class.name
    end
    sleep 0.3
    started = monotonic
    @server.shutdown
    refute_nil waiting.join(8), 'a waiting long poll ends when the console shuts its server down'
    assert_operator monotonic - started, :<, 8
  ensure
    pages&.each(&:kill)
    waiting&.kill
  end
end

# The real entry, with a fake `claude`, inspected from outside with lsof.
class KairomoneConsoleBreakSurfaceEntryTest < Minitest::Test
  include BreakSurfaceHttp
  CORE_LIB = File.expand_path('lib', __dir__)
  PACKAGE = File.expand_path('templates/skillsets/kairomone', __dir__)
  URL = %r{http://127\.0\.0\.1:(\d+)/#([0-9a-f]{64})}
  LSOF = %w[/usr/sbin/lsof /usr/bin/lsof].find { |path| File.executable?(path) }

  # Answers the mode handshake and plain turns in the measured stream-json
  # shapes, records its argv, environment and every line it reads, and waits
  # for the watchdog's TERM.
  FAKE_CLAUDE = <<~'RUBY'
    #!__RUBY__
    # frozen_string_literal: true
    require 'json'
    REPORTS = File.expand_path('../reports', __dir__)
    SESSION = '0b9f6c1e-5d1a-4c55-9f7e-1d2b3c4d5e6f'
    $stdout.sync = true
    $term = false
    trap('TERM') { $term = true }
    File.write(File.join(REPORTS, "report-#{Process.pid}.json"),
               JSON.generate('pid' => Process.pid, 'ppid' => Process.ppid, 'sid' => Process.getsid, 'argv' => ARGV, 'env' => ENV.to_h))
    def emit(hash)
      $stdout.puts(JSON.generate(hash))
    rescue IOError, SystemCallError
      nil
    end
    mode = 'default'
    pending = +''
    until $term
      next unless IO.select([$stdin], nil, nil, 0.1)

      chunk = $stdin.read_nonblock(65_536, exception: false)
      break if chunk.nil?
      next if chunk == :wait_readable

      pending << chunk
      while (newline = pending.index("\n"))
        line = pending.slice!(0, newline + 1)
        File.open(File.join(REPORTS, "stdin-#{Process.pid}.log"), 'a') { |f| f.write(line) }
        message = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        case message['type']
        when 'control_request'
          request = message['request'] || {}
          if request['subtype'] == 'set_permission_mode'
            word = request['mode'] == 'manual' ? 'default' : request['mode'].to_s
            changed = word != mode
            mode = word
            emit({ 'type' => 'control_response',
                   'response' => { 'subtype' => 'success', 'request_id' => message['request_id'], 'response' => { 'mode' => word } } })
            emit({ 'type' => 'system', 'subtype' => 'status', 'permissionMode' => word, 'session_id' => SESSION }) if changed
          else
            emit({ 'type' => 'control_response', 'response' => { 'subtype' => 'success', 'request_id' => message['request_id'] } })
          end
        when 'user'
          emit({ 'type' => 'system', 'subtype' => 'init', 'permissionMode' => mode, 'session_id' => SESSION })
          emit({ 'type' => 'user', 'message' => message['message'], 'session_id' => SESSION, 'isReplay' => true })
          emit({ 'type' => 'assistant', 'session_id' => SESSION,
                 'message' => { 'role' => 'assistant', 'content' => [{ 'type' => 'text', 'text' => 'fake reply' }] } })
          emit({ 'type' => 'result', 'subtype' => 'success', 'is_error' => false, 'session_id' => SESSION })
        end
      end
    end
    sleep 0.1 until $term
    exit!(0)
  RUBY

  def setup
    @root = File.realpath(Dir.mktmpdir('kairomone-break-entry-'))
    @project = File.join(@root, 'project')
    @data = File.join(@project, '.kairos')
    @home = File.join(@root, 'home')
    @bin = File.join(@root, 'bin')
    @reports = File.join(@root, 'reports')
    [@data, @home, @bin, @reports].each { |dir| FileUtils.mkdir_p(dir) }
    KairosMcp.data_dir = @data
    assert KairosMcp::SkillSetManager.new(skillsets_dir: File.join(@data, 'skillsets')).install(PACKAGE)[:success]
    Kairomone::Instance.new(host_root: @data).init(dot_id: 'break_dot', display_name: 'Break fixture')
    KairosMcp.reset_data_dir!
    File.write(File.join(@project, '.mcp.json'),
               JSON.generate('mcpServers' => { 'kairos-chain' => { 'command' => 'kairos-chain', 'args' => ['--data-dir', @data] } }))
    @fake = File.join(@bin, 'claude')
    File.write(@fake, FAKE_CLAUDE.sub('__RUBY__', RbConfig.ruby))
    File.chmod(0o755, @fake)
    @output = String.new(encoding: Encoding::BINARY)
    @output_lock = Mutex.new
  end

  def teardown
    if @pid
      begin
        Process.kill('KILL', @pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(@pid)
      rescue Errno::ECHILD
        nil
      end
    end
    deadline = monotonic + 7.5
    sleep 0.1 until our_processes.empty? || monotonic > deadline
    our_processes.each do |pid|
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    @reader_thread&.join(2)
    [@pty_reader, @pty_writer].each { |io| io.close if io && !io.closed? }
    KairosMcp.reset_data_dir!
    FileUtils.remove_entry_secure(@root) if @root && File.directory?(@root)
  end

  def our_processes
    out, = Open3.capture2('ps', '-A', '-ww', '-o', 'pid=,stat=,command=')
    out.each_line.filter_map do |line|
      pid, stat, command = line.strip.split(/\s+/, 3)
      pid.to_i if pid.to_i != Process.pid && !stat.to_s.start_with?('Z') && command.to_s.include?(@root)
    end
  end

  def output = @output_lock.synchronize { @output.dup }
  def urls = output.scan(URL)

  def wait_until(timeout, what)
    deadline = monotonic + timeout
    loop do
      value = yield
      return value if value

      flunk "timed out after #{timeout}s waiting for #{what}\n#{output}" if monotonic > deadline
      sleep 0.05
    end
  end

  def start_console
    env = ENV.to_h.merge('HOME' => @home, 'PATH' => "#{@bin}:#{ENV.fetch('PATH', '')}", 'KAIROMONE_CONSOLE_CLAUDE' => @fake,
                         'KAIROS_DATA_DIR' => nil)
    entry = File.join(@data, 'skillsets', 'kairomone', 'scripts', 'kairomone_console.rb')
    @pty_reader, @pty_writer, @pid = PTY.spawn(env, RbConfig.ruby, '-I', CORE_LIB, entry, chdir: @project)
    @reader_thread = Thread.new do
      loop do
        chunk = @pty_reader.readpartial(4096)
        @output_lock.synchronize { @output << chunk }
      end
    rescue EOFError, IOError, Errno::EIO
      nil
    end
    found = wait_until(40, 'the start URL') { urls.first }
    @port = Integer(found[0])
    found[1]
  end

  def http(method, path, session: nil, body: nil, headers: {})
    req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(path)
    req['Origin'] = "http://127.0.0.1:#{@port}" if method == :post
    req['X-Kairomone-Session'] = session if session
    headers.each { |name, value| req[name] = value }
    if method == :post
      req.body = JSON.generate(body || {})
      req['Content-Type'] = 'application/json'
    end
    Net::HTTP.start('127.0.0.1', @port, open_timeout: 5, read_timeout: 30) { |h| h.request(req) }
  end

  def take_session(bootstrap)
    res = http(:post, '/session', headers: { 'X-Kairomone-Bootstrap' => bootstrap })
    assert_equal '200', res.code, res.body
    JSON.parse(res.body).fetch('session')
  end

  def events(session) = JSON.parse(http(:get, '/events?after=0', session: session).body)['events']

  # lsof -F: one Hash per descriptor with 'fd', 'type', 'address' (the pipe end
  # or socket itself) and 'name' ("->peer" for a pipe end).
  def descriptors(pid)
    out, status = Open3.capture2(LSOF, '-n', '-P', '-a', '-p', pid.to_s, '-F', 'ftdn')
    assert status.success? || !out.empty?, "lsof could not list #{pid}"
    out.each_line.each_with_object([]) do |line, list|
      tag = line[0]
      value = line[1..].chomp
      case tag
      when 'f' then list << { 'fd' => value }
      when 't' then list.last['type'] = value if list.last
      when 'd' then list.last['address'] = value if list.last
      when 'n' then list.last['name'] = value if list.last
      end
    end
  end

  def pipe_ends(list) = list.select { |d| d['type'] == 'PIPE' }.to_h { |d| [d['address'], d] }
  def sockets(list) = list.select { |d| %w[IPv4 IPv6 unix systm].include?(d['type']) }

  # Invariant 3 and the lens request: the child holds no copy of the listening
  # socket, the lifeline's write end or any other pipe end the console holds,
  # and no argument, environment value or input line carries the secret, even
  # after a second URL was issued and used.
  def test_pin_the_child_and_its_watchdog_hold_no_socket_no_console_pipe_end_and_no_secret
    skip 'lsof is not available' unless LSOF
    first_bootstrap = start_console
    report = wait_until(30, 'the fake claude report') do
      path = Dir[File.join(@reports, 'report-*.json')].first
      path && JSON.parse(File.read(path))
    end
    first_session = take_session(first_bootstrap)
    wait_until(20, 'the box to open') { events(first_session).any? { |e| e['kind'] == 'accepting' && e['value'] == true } }
    assert_equal '202', http(:post, '/message', session: first_session, body: { 'text' => 'hello from the page' }).code
    wait_until(20, 'the turn to end') { events(first_session).any? { |e| e['kind'] == 'turn_end' } }
    @pty_writer.write("\n")
    second_bootstrap = wait_until(15, 'a second URL') { urls[1]&.last }
    second_session = take_session(second_bootstrap)
    assert_equal '200', http(:get, '/events?after=0', session: second_session).code

    child = report['pid']
    watchdog = report['ppid']
    console = descriptors(@pid)
    assert(sockets(console).any? { |d| d['name'] == "127.0.0.1:#{@port}" }, 'fixture: lsof sees the console listening')
    lifeline = descriptors(watchdog).find { |d| d['fd'] == '3' && d['type'] == 'PIPE' }
    refute_nil lifeline, 'fixture: the watchdog reads the lifeline on descriptor 3'
    lifeline_write = lifeline['name'].to_s.delete_prefix('->')
    assert_includes pipe_ends(console).keys, lifeline_write, 'fixture: the console holds the lifeline write end'

    # Descriptors each process may hold beyond pipe pairs it made for itself
    # (both ends in the same process, e.g. the Ruby VM's own): the three stdio
    # pipes, and for the watchdog the lifeline's read end on 3.
    { 'claude' => [child, %w[0 1 2]], 'watchdog' => [watchdog, %w[0 1 2 3]] }.each do |name, (pid, allowed)|
      list = descriptors(pid)
      refute_empty list, "fixture: lsof lists #{name}"
      assert_empty sockets(list), "#{name} holds no socket (the console's listener included)"
      shared = pipe_ends(list).keys & pipe_ends(console).keys
      assert_empty shared, "#{name} holds no pipe end the console holds (the lifeline write end, the child's stdin write end)"
      refute_includes pipe_ends(list).keys, lifeline_write
      own = pipe_ends(list)
      crossed = list.select do |d|
        d['type'] == 'PIPE' && !allowed.include?(d['fd']) && !own.key?(d['name'].to_s.delete_prefix('->'))
      end
      assert_empty crossed.map { |d| d['fd'] }, "#{name} inherited no pipe beyond its stdio#{name == 'watchdog' ? ' and the lifeline read end' : ''}"
    end

    secrets = [first_bootstrap, first_session, second_bootstrap, second_session]
    seen = [JSON.generate(report['argv']), JSON.generate(report['env']), File.read(Dir[File.join(@reports, 'stdin-*.log')].first)]
    secrets.each do |secret|
      seen.each { |text| refute_includes text, secret, 'the child never receives a secret' }
    end
    holding = Dir.glob(File.join(@root, '**', '*'), File::FNM_DOTMATCH).select do |path|
      File.file?(path) && secrets.any? { |secret| File.binread(path).include?(secret) }
    end
    assert_empty holding, 'no file holds a secret'
  end
end
