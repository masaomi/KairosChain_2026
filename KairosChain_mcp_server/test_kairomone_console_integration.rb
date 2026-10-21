#!/usr/bin/env ruby
# frozen_string_literal: true
# Kairomone console end to end, written from design v0.3 and implementation plan
# v0.2 without reading the implementation. A fake `claude` (a Ruby script in
# each test's temporary root) speaks the stream-json measured in
# log/kairomone_console_probes_20261021/, calls no model and no network, and
# stays alive until signalled. The console entry of an installed copy runs under
# a pseudo-terminal in a temporary project and is driven over HTTP on 127.0.0.1.
# Every process started here has the temporary root in its command line, and
# teardown kills only those.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require_relative 'templates/skillsets/kairomone/lib/kairomone/console'
require 'kairos_mcp/skillset_manager'
require 'tmpdir'
require 'open3'
require 'pty'
require 'net/http'
require 'minitest/autorun'

class KairomoneConsoleIntegrationTest < Minitest::Test
  CORE_LIB = File.expand_path('lib', __dir__)
  PACKAGE = File.expand_path('templates/skillsets/kairomone', __dir__)
  URL = %r{http://127\.0\.0\.1:(\d+)/#([0-9a-f]{64})}
  HEX64 = /\A[0-9a-f]{64}\z/
  RESUME_ID = '6d0f58d6-4b24-46ac-a462-4e71b852e9cb'
  MARKERS = %w[OWNER-MARKER ASSISTANT-MARKER TOOL-INPUT-MARKER DESCRIPTION-MARKER TOOL-RESULT-MARKER
               FOREIGN-TEXT-MARKER].freeze

  FAKE_CLAUDE = <<~'RUBY'
    #!__RUBY__
    # frozen_string_literal: true
    # Fake `claude` for the Kairomone console tests. It speaks the stream-json
    # measured on 2026-10-21, calls no model and no network, records what it sees
    # under ../reports, and stays alive until it is signalled.
    OPEN_FDS = (3..64).select do |fd|
      IO.for_fd(fd, autoclose: false)
      true
    rescue StandardError
      false
    end
    require 'json'
    require 'time'
    require 'securerandom'
    require 'rbconfig'

    REPORTS = File.expand_path('../reports', __dir__)
    PID = Process.pid
    $stdout.sync = true
    # TERM only raises a flag, so a line is never cut off half handled.
    $term = false
    trap('TERM') { $term = true }

    def report(name) = File.join(REPORTS, name)

    def write_json(name, value)
      File.write("#{report(name)}.tmp", JSON.generate(value))
      File.rename("#{report(name)}.tmp", report(name))
    end

    def append(name, value)
      File.open(report(name), 'a') { |f| f.puts(JSON.generate(value)) }
    end

    class Fake
      def initialize
        @mode = 'default'
        @in_turn = false
        @foreign = false
        @first_mode = true
        @n = 0
        @waiting = {}
      end

      def run
        pending = +''
        until $term
          next unless IO.select([$stdin], nil, nil, 0.1)

          chunk = $stdin.read_nonblock(65_536, exception: false)
          if chunk.nil? # the console is gone; wait for the watchdog's signal
            sleep 0.1 until $term
            break
          end
          next if chunk == :wait_readable

          pending << chunk
          while (newline = pending.index("\n"))
            handle(pending.slice!(0, newline + 1))
          end
        end
        drain(pending)
      end

      # A stopping console writes its last answers just before the watchdog's TERM.
      def drain(pending)
        loop do
          chunk = $stdin.read_nonblock(65_536, exception: false)
          break unless chunk.is_a?(String)

          pending << chunk
        end
        pending.each_line { |line| record(line) }
      rescue IOError, SystemCallError
        nil
      end

      def record(line)
        append("stdin-#{PID}.jsonl", JSON.parse(line))
      rescue JSON::ParserError
        append("stdin-#{PID}.jsonl", { 'unparsed' => line })
      end

      def handle(line)
        record(line)
        message = JSON.parse(line)
        case message['type']
        when 'control_request' then control(message)
        when 'control_response' then answered(message)
        when 'user' then turn(message)
        end
      rescue JSON::ParserError
        nil
      end

      def uuid = SecureRandom.uuid

      def emit(hash)
        $stdout.puts(JSON.generate(hash))
      rescue Errno::EPIPE, IOError
        nil
      end

      def success(request_id, body = nil)
        response = { 'subtype' => 'success', 'request_id' => request_id }
        response['response'] = body if body
        emit({ 'type' => 'control_response', 'response' => response })
      end

      def control(message)
        request = message['request'] || {}
        case request['subtype']
        when 'set_permission_mode'
          set_mode(message['request_id'], request['mode'])
        when 'interrupt'
          append('interrupts.jsonl', { 'in_turn' => @in_turn, 'foreign_active' => @foreign })
          success(message['request_id'])
          finish('error_during_execution', true) if @in_turn
          @foreign = false
        else
          success(message['request_id'])
        end
      end

      # manual is echoed as default, and a change is followed by system/status (m8, m9).
      def set_mode(request_id, requested)
        append('modes.jsonl', requested)
        hold_first_echo if @first_mode
        @first_mode = false
        word = requested == 'manual' ? 'default' : requested.to_s
        changed = word != @mode
        @mode = word
        success(request_id, { 'mode' => word })
        return unless changed

        emit({ 'type' => 'system', 'subtype' => 'status', 'status' => nil, 'permissionMode' => word, 'uuid' => uuid,
               'session_id' => SESSION })
      end

      def hold_first_echo
        return unless File.exist?(report('hold_first_echo'))

        append('held.jsonl', { 'held' => true })
        sleep 0.05 until File.exist?(report('release_first_echo')) || $term
      end

      def turn(message)
        text = text_of(message.dig('message', 'content'))
        @n += 1
        @in_turn = true
        emit(init_line)
        emit(replay(message['message']))
        command, argument = text.split(' ', 2)
        case command
        when 'PLAIN'
          say("ASSISTANT-MARKER-#{@n}")
          emit({ 'type' => 'rate_limit_event', 'rate_limit_info' => { 'status' => 'allowed' }, 'uuid' => uuid,
                 'session_id' => SESSION })
          finish
        when 'ASK'
          ask('Bash', 'Bash', { 'command' => "echo TOOL-INPUT-MARKER-#{@n}", 'description' => "DESCRIPTION-MARKER-#{@n}" })
        when 'ASKGROWTH'
          ask('mcp__kairos-chain__kairomone_growth', 'Kairomone Growth', { 'command' => 'claim', 'worker_id' => "console-#{@n}" })
        when 'HOLD'
          say("ASSISTANT-MARKER-holding-#{@n}")
        when 'FOREIGN'
          say("ASSISTANT-MARKER-before-foreign-#{@n}")
          finish
          foreign_turn
        when 'GRANDCHILD'
          grandchild
          say("ASSISTANT-MARKER-grandchild-#{@n}")
          finish
        when 'EXIT'
          append('exiting.jsonl', { 'code' => Integer(argument) })
          exit!(Integer(argument))
        else
          say("ASSISTANT-MARKER-unknown-#{@n}")
          finish
        end
      end

      def ask(name, display_name, input)
        tool_use_id = "toolu_fake_#{@n}"
        request_id = uuid
        emit(assistant([{ 'type' => 'tool_use', 'id' => tool_use_id, 'name' => name, 'input' => input,
                          'caller' => { 'type' => 'direct' } }]))
        request = { 'subtype' => 'can_use_tool', 'tool_name' => name, 'display_name' => display_name, 'input' => input,
                    'permission_suggestions' => [], 'tool_use_id' => tool_use_id }
        if name.start_with?('mcp__')
          request['mcp_server'] = { 'name' => 'kairos-chain', 'source' => 'dynamic' }
          request['server_policy_ask_only'] = true
        else
          request['description'] = input['description']
          request['decision_reason'] = 'This command requires approval'
          request['decision_reason_type'] = 'other'
        end
        @waiting[request_id] = { 'tool_use_id' => tool_use_id, 'n' => @n }
        append('requests.jsonl', { 'request_id' => request_id, 'tool_use_id' => tool_use_id, 'input' => input })
        emit({ 'type' => 'control_request', 'request_id' => request_id, 'request' => request })
      end

      # The CLI writes the host's answer back on stdout (m8 line 24), then the result.
      def answered(message)
        waiting = @waiting.delete(message.dig('response', 'request_id'))
        return unless waiting

        emit(message)
        body = message.dig('response', 'response') || {}
        if body['behavior'] == 'allow'
          emit(tool_result(waiting['tool_use_id'], [{ 'type' => 'text', 'text' => "TOOL-RESULT-MARKER-#{waiting['n']}" }],
                           'accept', 'user_temporary', false))
        else
          emit(tool_result(waiting['tool_use_id'], body['message'].to_s, 'reject', 'user_reject', true))
        end
        say("ASSISTANT-MARKER-after-tool-#{waiting['n']}")
        finish
      end

      # A message from another of the owner's sessions arriving while idle (m6).
      def foreign_turn
        sleep 0.3
        emit({ 'type' => 'command_lifecycle', 'command_uuid' => uuid, 'state' => 'started', 'uuid' => uuid,
               'session_id' => SESSION })
        emit(init_line)
        @in_turn = true
        @foreign = true
        body = 'FOREIGN-TEXT-MARKER: reply with the single word received. Use no tools.'
        text = "Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/22271.sock\" " \
               "from-name=\"kairomone_peer_fixture\" from-mode=\"prompting\">\n#{body}\n</cross-session-message>"
        append('foreign.jsonl', { 'emitted' => true })
        emit({ 'type' => 'user', 'message' => { 'role' => 'user', 'content' => text }, 'session_id' => SESSION,
               'parent_tool_use_id' => nil, 'uuid' => uuid, 'timestamp' => Time.now.utc.iso8601(3),
               'isReplay' => true, 'isSynthetic' => true,
               'origin' => { 'kind' => 'peer', 'from' => 'uds:/tmp/cc-socks/22271.sock', 'verifiedPeerPid' => 22_271,
                             'msg_id' => uuid, 'name' => 'kairomone_peer_fixture',
                             'hopChain' => ['dc8c399a23fa58e8be7c727c'], 'fromMode' => 'prompting', 'body' => body } })
      end

      # Claude Code runs each Bash command in a process group of its own (m11).
      def grandchild
        pid_file = report('grandchild.pid')
        code = "trap('TERM', 'IGNORE'); trap('HUP', 'IGNORE'); File.write(ARGV[0] + '.tmp', Process.pid.to_s); " \
               "File.rename(ARGV[0] + '.tmp', ARGV[0]); sleep"
        pid = Process.spawn(RbConfig.ruby, '-e', code, pid_file, pgroup: true, in: File::NULL, out: File::NULL,
                                                                    err: File::NULL)
        Process.detach(pid)
        sleep 0.02 until File.exist?(pid_file)
        write_json('grandchild.json', { 'fake_pid' => PID, 'fake_pgid' => Process.getpgrp, 'fake_sid' => Process.getsid,
                                        'grandchild_pid' => pid, 'grandchild_pgid' => Process.getpgid(pid),
                                        'grandchild_sid' => Process.getsid(pid) })
      end

      def init_line
        { 'type' => 'system', 'subtype' => 'init', 'cwd' => Dir.pwd, 'session_id' => SESSION,
          'tools' => %w[Bash Glob Grep Read ToolSearch],
          'mcp_servers' => [{ 'name' => 'kairos-chain', 'status' => 'connected', 'source' => 'dynamic' }],
          'model' => 'claude-haiku-5-5', 'permissionMode' => @mode, 'slash_commands' => [], 'apiKeySource' => 'none',
          'claude_code_version' => '2.1.303', 'output_style' => 'default', 'uuid' => uuid }
      end

      def replay(message)
        { 'type' => 'user', 'message' => message, 'session_id' => SESSION, 'parent_tool_use_id' => nil, 'uuid' => uuid,
          'timestamp' => Time.now.utc.iso8601(3), 'isReplay' => true }
      end

      def assistant(blocks)
        { 'type' => 'assistant',
          'message' => { 'model' => 'claude-haiku-5-5', 'id' => "msg_#{uuid.delete('-')}", 'type' => 'message',
                         'role' => 'assistant', 'content' => blocks, 'stop_reason' => nil },
          'parent_tool_use_id' => nil, 'session_id' => SESSION, 'uuid' => uuid }
      end

      def say(text) = emit(assistant([{ 'type' => 'text', 'text' => text }]))

      def tool_result(tool_use_id, content, decision, source, is_error)
        meta = { 'id' => tool_use_id, 'permission_decision' => { 'decision' => decision, 'source' => source } }
        meta['non_execution_kind'] = 'permission-rule' if decision == 'reject'
        { 'type' => 'user',
          'message' => { 'role' => 'user', 'content' => [{ 'tool_use_id' => tool_use_id, 'type' => 'tool_result',
                                                           'content' => content, 'is_error' => is_error }] },
          'parent_tool_use_id' => nil, 'session_id' => SESSION, 'uuid' => uuid, 'timestamp' => Time.now.utc.iso8601(3),
          'tool_use_result' => 'fake', 'tool_result_meta' => [meta] }
      end

      def finish(subtype = 'success', is_error = false)
        emit({ 'type' => 'result', 'subtype' => subtype, 'is_error' => is_error, 'duration_ms' => 12, 'num_turns' => 1,
               'result' => 'fake', 'session_id' => SESSION, 'permission_denials' => [], 'terminal_reason' => 'completed',
               'uuid' => uuid })
        @in_turn = false
      end

      def text_of(content)
        return content.to_s unless content.is_a?(Array)

        content.select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'] }.join
      end
    end

    resume = ARGV.index('--resume')
    SESSION = resume ? ARGV[resume + 1] : SecureRandom.uuid
    TTY = begin
      File.open('/dev/tty', 'r+') { nil }
      'open'
    rescue SystemCallError => e
      e.class.name
    end
    write_json("report-#{PID}.json", { 'pid' => PID, 'ppid' => Process.ppid, 'pgid' => Process.getpgrp,
                                       'sid' => Process.getsid, 'argv' => ARGV, 'env' => ENV.to_h, 'cwd' => Dir.pwd,
                                       'tty' => TTY, 'fds' => OPEN_FDS })
    Fake.new.run
    exit!(0)
  RUBY

  # Runs ChildProcess inside a session of its own, so that a sweep gone wrong
  # could reach only this helper and what it started.
  CHILD_PROCESS_HELPER = <<~'RUBY'
    Process.setsid
    core, lib, fake, cwd, mode = ARGV
    $LOAD_PATH.unshift(core)
    $LOAD_PATH.unshift(lib)
    require 'json'
    require 'kairomone'
    require File.join(lib, 'kairomone', 'console')
    clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    child = Kairomone::Console::ChildProcess.new(argv: [fake, '-p'], cwd: cwd, env: ENV.to_h).start
    lines = Queue.new
    Thread.new { child.each_line { |line| lines << line } }
    Thread.new { child.stderr_lines { |_line| nil } }
    out = {}
    if mode == 'exit'
      child.write({ 'type' => 'user', 'message' => { 'role' => 'user', 'content' => 'EXIT 7' } })
      out['exitstatus'] = child.wait.exitstatus
    else
      child.write({ 'type' => 'user', 'message' => { 'role' => 'user', 'content' => 'GRANDCHILD' } })
      seen = []
      deadline = clock.call + 20
      until seen.include?('result') || clock.call > deadline
        line = lines.pop(timeout: 1)
        seen << JSON.parse(line)['type'] if line
      end
      out['types'] = seen
      started = clock.call
      child.close_lifeline
      out['exitstatus'] = child.wait.exitstatus
      out['wait_seconds'] = clock.call - started
    end
    puts JSON.generate(out)
  RUBY

  # The console entry under a pseudo-terminal, as the owner starts it.
  class ConsoleRun
    attr_reader :pid

    def initialize(env, argv, chdir)
      @reader, @writer, @pid = PTY.spawn(env, *argv, chdir: chdir)
      @output = String.new(encoding: Encoding::BINARY)
      @mutex = Mutex.new
      @status = nil
      @thread = Thread.new do
        loop do
          chunk = @reader.readpartial(4096)
          @mutex.synchronize { @output << chunk }
        end
      rescue EOFError, IOError, Errno::EIO
        nil
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def output = @mutex.synchronize { @output.dup }
    def urls = output.scan(URL)
    def press_enter = @writer.write("\n")

    def wait_for_urls(count, timeout:)
      deadline = monotonic + timeout
      sleep 0.05 until urls.length >= count || monotonic > deadline || exited?
      urls
    end

    def exited?
      @status ||= Process.wait2(@pid, Process::WNOHANG)&.last
      !@status.nil?
    rescue Errno::ECHILD
      true
    end

    def wait_exit(timeout)
      deadline = monotonic + timeout
      sleep 0.05 until exited? || monotonic > deadline
      @status
    end

    def drain = @thread.join(2)

    def close
      begin
        Process.kill('KILL', @pid) unless exited?
      rescue Errno::ESRCH
        nil
      end
      wait_exit(5)
      drain
      [@reader, @writer].each { |io| io.close unless io.closed? }
    end
  end

  def setup
    @root = File.realpath(Dir.mktmpdir('kairomone-console-it-'))
    @project = File.join(@root, 'project')
    @data = File.join(@project, '.kairos')
    @home = File.join(@root, 'home')
    @bin = File.join(@root, 'bin')
    @reports = File.join(@root, 'reports')
    [@data, @home, @bin, @reports].each { |dir| FileUtils.mkdir_p(dir) }
    install_package
    File.write(File.join(@project, '.mcp.json'),
               JSON.generate('mcpServers' => { 'kairos-chain' => { 'command' => 'kairos-chain', 'args' => ['--data-dir', @data] } }))
    settings_file(File.join(@home, '.claude', 'settings.json'),
                  'permissions' => { 'deny' => ['Bash(rm:*)'], 'ask' => ['Bash(git push:*)'], 'allow' => ['Write'] })
    settings_file(File.join(@project, '.claude', 'settings.json'), 'permissions' => { 'deny' => ['Read(./secrets/**)'] })
    settings_file(File.join(@project, '.claude', 'settings.local.json'),
                  'permissions' => { 'ask' => ['mcp__kairos-chain__kairomone_growth'], 'allow' => ['Bash(curl:*)'] })
    @fake = File.join(@bin, 'claude')
    File.write(@fake, FAKE_CLAUDE.sub('__RUBY__', RbConfig.ruby))
    File.chmod(0o755, @fake)
    @consoles = []
    @events = []
    @last = 0
  end

  def teardown
    @consoles.each(&:close)
    sweep_processes
    FileUtils.remove_entry_secure(@root) if @root && File.directory?(@root)
  end

  # Installs through the core's SkillSet lifecycle, recording to this data dir's chain.
  def install_package
    KairosMcp.data_dir = @data
    assert KairosMcp::SkillSetManager.new(skillsets_dir: File.join(@data, 'skillsets')).install(PACKAGE)[:success]
    Kairomone::Instance.new(host_root: @data).init(dot_id: 'console_dot', display_name: 'Console fixture')
  ensure
    KairosMcp.reset_data_dir!
  end

  def settings_file(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(value))
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def wait_until(timeout, what)
    deadline = monotonic + timeout
    loop do
      value = yield
      return value if value

      flunk "timed out after #{timeout}s waiting for #{what}" if monotonic > deadline
      sleep 0.05
    end
  end

  # The fake is found by the PATH as `claude` and named by KAIROMONE_CONSOLE_CLAUDE.
  def start_console(*args)
    env = ENV.to_h.merge('HOME' => @home, 'PATH' => "#{@bin}:#{ENV.fetch('PATH', '')}",
                         'KAIROMONE_CONSOLE_CLAUDE' => @fake, 'KAIROS_DATA_DIR' => nil)
    @console_env = env.compact
    entry = File.join(@data, 'skillsets', 'kairomone', 'scripts', 'kairomone_console.rb')
    console = ConsoleRun.new(env, [RbConfig.ruby, '-I', CORE_LIB, entry, *args], @project)
    @consoles << console
    console
  end

  def open_console(*args, hold: false)
    hold_first_echo! if hold
    console = start_console(*args)
    urls = console.wait_for_urls(1, timeout: hold ? 25 : 40)
    if urls.empty? && hold
      release_first_echo!
      later = console.wait_for_urls(1, timeout: 15)
      flunk "the URL appeared only after the first mode echo, so a closed box cannot be shown:\n#{console.output}" unless later.empty?
    end
    flunk "the console printed no start URL:\n#{console.output}" if urls.empty?
    @port = Integer(urls.first[0])
    @bootstrap = urls.first[1]
    console
  end

  def hold_first_echo! = File.write(File.join(@reports, 'hold_first_echo'), '')
  def release_first_echo! = File.write(File.join(@reports, 'release_first_echo'), '')
  def fake_reports = Dir[File.join(@reports, 'report-*.json')].map { |path| JSON.parse(File.read(path)) }
  def wait_for_fake = wait_until(30, 'the fake claude to start') { fake_reports.first }

  def jsonl(name)
    path = File.join(@reports, name)
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def read_json(name)
    path = File.join(@reports, name)
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  end

  def fake_stdin(fake) = jsonl("stdin-#{fake['pid']}.jsonl")

  def answers_for(fake, request_id)
    fake_stdin(fake).select { |line| line['type'] == 'control_response' && line.dig('response', 'request_id') == request_id }
  end

  def text_of(content)
    return content.to_s unless content.is_a?(Array)

    content.select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'] }.join
  end

  def value_after(argv, flag)
    index = argv.index(flag)
    index && argv[index + 1]
  end

  def hook_input(tool_name, tool_input)
    { 'session_id' => RESUME_ID, 'transcript_path' => File.join(@root, 'transcript.jsonl'), 'cwd' => @project,
      'permission_mode' => 'default', 'hook_event_name' => 'PreToolUse', 'tool_name' => tool_name,
      'tool_input' => tool_input, 'tool_use_id' => 'toolu_01TLzDjBNz1GNFCdTbuvmurc' }
  end

  def alive?(pid)
    out, status = Open3.capture2('ps', '-o', 'stat=', '-p', pid.to_s)
    status.success? && !out.strip.empty? && !out.strip.start_with?('Z')
  end

  def command_of(pid)
    out, status = Open3.capture2('ps', '-ww', '-o', 'command=', '-p', pid.to_s)
    status.success? ? out.strip : nil
  end

  def our_processes
    out, = Open3.capture2('ps', '-A', '-ww', '-o', 'pid=,stat=,command=')
    out.each_line.filter_map do |line|
      pid, stat, command = line.strip.split(/\s+/, 3)
      pid.to_i if pid.to_i != Process.pid && !stat.to_s.start_with?('Z') && command.to_s.include?(@root)
    end
  end

  # Gives the watchdog its grace period, then kills whatever a failure left behind.
  def sweep_processes
    deadline = monotonic + 7.5
    sleep 0.1 until our_processes.empty? || monotonic > deadline
    our_processes.each do |pid|
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  def directives(header)
    header.to_s.split(';').map(&:strip).reject(&:empty?).to_h do |directive|
      name, *values = directive.split(/\s+/)
      [name, values.join(' ')]
    end
  end

  def csp_for(html)
    script = html[%r{<script\b[^>]*>(.*?)</script>}mi, 1].to_s
    style = html[%r{<style\b[^>]*>(.*?)</style>}mi, 1].to_s
    { 'default-src' => "'none'", 'script-src' => "'sha256-#{Base64.strict_encode64(Digest::SHA256.digest(script))}'",
      'style-src' => "'sha256-#{Base64.strict_encode64(Digest::SHA256.digest(style))}'", 'connect-src' => "'self'",
      'img-src' => "'self' data:", 'frame-ancestors' => "'none'", 'base-uri' => "'none'", 'form-action' => "'none'" }
  end

  def assert_contract_headers(res)
    assert_nil res['Set-Cookie'], 'no cookie is ever set'
    assert_empty res.to_hash.keys.grep(/\Aaccess-control-/), 'no CORS headers'
    csp = directives(res['Content-Security-Policy'])
    assert_equal @expected_csp, csp if @expected_csp
    assert_equal ["'none'", "'none'"], csp.values_at('default-src', 'frame-ancestors')
    assert_equal 'DENY', res['X-Frame-Options']
    assert_equal 'no-referrer', res['Referrer-Policy']
    assert_includes res['Cache-Control'].to_s.split(',').map(&:strip), 'no-store'
    assert_equal 'nosniff', res['X-Content-Type-Options']
  end

  def request(method, path, session: :current, origin: (method == :post ? :page : nil), host: nil, headers: {},
              body: nil, read_timeout: 10, check: true)
    req = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method).new(path)
    req['Host'] = host if host
    req['Origin'] = origin == :page ? "http://127.0.0.1:#{@port}" : origin if origin
    session = @session if session == :current
    req['X-Kairomone-Session'] = session if session
    headers.each { |name, value| req[name] = value }
    if method == :post
      req.body = body.is_a?(String) ? body : JSON.generate(body || {})
      req['Content-Type'] = 'application/json'
    end
    res = Net::HTTP.start('127.0.0.1', @port, open_timeout: 5, read_timeout: read_timeout) { |http| http.request(req) }
    assert_contract_headers(res) if check
    res
  end

  def exchange(bootstrap, **options)
    request(:post, '/session', session: nil, headers: { 'X-Kairomone-Bootstrap' => bootstrap }, **options)
  end

  def take_session!(bootstrap = @bootstrap)
    res = exchange(bootstrap)
    assert_equal '200', res.code, res.body
    @session = JSON.parse(res.body).fetch('session')
    assert_match HEX64, @session
    @session
  end

  def fetch_events(read_timeout)
    res = request(:get, "/events?after=#{@last}", read_timeout: read_timeout)
    return unless res.code == '200'

    body = JSON.parse(res.body)
    body['events'].each { |event| @events << event unless @events.any? { |e| e['seq'] == event['seq'] } }
    @last = [@last, body['last'].to_i, *body['events'].map { |e| e['seq'] }].max
  rescue Net::ReadTimeout, Net::OpenTimeout, EOFError, IOError, SystemCallError
    nil
  end

  def wait_event(timeout: 20, &match)
    deadline = monotonic + timeout
    loop do
      found = @events.find(&match)
      return found if found

      remaining = deadline - monotonic
      flunk "no matching event within #{timeout}s; kinds so far: #{@events.map { |e| e['kind'] }.inspect}" if remaining <= 0
      fetch_events([remaining, 1].max)
    end
  end

  # Catches up with what the console already has, then returns the last sequence number.
  def mark!
    fetch_events(0.3)
    @last
  end

  def events_of(kind) = @events.select { |e| e['kind'] == kind }

  def wait_accepting(after = 0)
    wait_event { |e| e['kind'] == 'accepting' && e['value'] == true && e['seq'] > after }
  end

  def files_holding(*secrets)
    Dir.glob(File.join(@root, '**', '*'), File::FNM_DOTMATCH).select do |path|
      next false unless File.file?(path)

      content = File.binread(path)
      secrets.any? { |secret| content.include?(secret) }
    end
  end

  def assert_page_contract(html)
    html = html.dup.force_encoding(Encoding::UTF_8)
    scripts = html.scan(%r{<script\b([^>]*)>(.*?)</script>}mi)
    assert_equal 1, scripts.length, 'one script'
    assert_equal 1, html.scan(%r{<style\b[^>]*>.*?</style>}mi).length, 'one style'
    refute_match(/\bsrc\s*=/i, scripts[0][0], 'the script is inline')
    markup = html.gsub(%r{<script\b[^>]*>.*?</script>}mi, '').gsub(%r{<style\b[^>]*>.*?</style>}mi, '')
    refute_match(/<[a-z][^>]*\son[a-z]+\s*=/i, markup, 'no inline event handler')
    refute_match(/<(?:iframe|object|embed|base)\b/i, markup)
    refute_match(%r{\b(?:src|href)\s*=\s*["']?(?:https?:)?//}i, markup, 'no external resource')
    code = scripts[0][1]
    refute_match(/\.(?:inner|outer)HTML\s*=|insertAdjacentHTML|document\.write/, code, 'dynamic text is never markup')
    %w[textContent sessionStorage history.replaceState X-Kairomone-Session X-Kairomone-Bootstrap].each do |word|
      assert_includes code, word
    end
    %w[localStorage document.cookie].each { |word| refute_includes code, word }
    ['いまの状態を教えて', '最近覚えたことを見せて', '〈話題〉について 1 回学習して', 'バックアップを取って、検証して',
     'l0 rebaseline'].each { |text| assert_includes html, text }
  end

  def assert_tty_control_works
    reader, _writer, pid = PTY.spawn(RbConfig.ruby, '-e', "File.open('/dev/tty', 'r+') { nil }; print 'TTY-OPEN'")
    out = +''
    begin
      loop { out << reader.readpartial(1024) }
    rescue EOFError, Errno::EIO
      nil
    end
    Process.wait(pid)
    assert_includes out, 'TTY-OPEN', 'control: a process in a terminal session can open /dev/tty'
  end

  def assert_hook(command, tool, input, code)
    out, err, status = Open3.capture3('/bin/sh', '-c', command, stdin_data: JSON.generate(hook_input(tool, input)))
    assert_equal code, status.exitstatus, "#{tool}: #{err}"
    assert_equal '', out, "#{tool}: the gate prints no decision"
  end

  def assert_child_argv(argv)
    %w[-p --verbose --replay-user-messages --disable-slash-commands --strict-mcp-config].each { |flag| assert_includes argv, flag }
    { '--input-format' => 'stream-json', '--output-format' => 'stream-json', '--permission-prompts' => 'host',
      '--permission-prompt-tool' => 'stdio', '--permission-mode' => 'manual', '--setting-sources' => '',
      '--mcp-config' => File.join(@project, '.mcp.json') }.each { |flag, value| assert_equal value, value_after(argv, flag), flag }
    assert_equal File.realpath(File.join(@data, 'skillsets', 'kairomone', 'plugin', 'SKILL.md')),
                 File.realpath(value_after(argv, '--append-system-prompt-file')), 'the installed standing rules'
    assert_equal Kairomone::Console::Gate::BUILTINS.sort, value_after(argv, '--tools').split(',').sort
    %w[--resume --dangerously-skip-permissions --allowedTools --allowed-tools --add-dir].each { |flag| refute_includes argv, flag }
    settings = JSON.parse(value_after(argv, '--settings'))
    assert_equal %w[autoMemoryEnabled crossSessionInbound hooks permissions], settings.keys.sort
    assert_equal ['refuse', false], settings.values_at('crossSessionInbound', 'autoMemoryEnabled')
    assert_equal({ 'deny' => ['Bash(rm:*)', 'Read(./secrets/**)'],
                   'ask' => ['Bash(git push:*)', 'mcp__kairos-chain__kairomone_growth'] }, settings['permissions'],
                 'the saved deny and ask rules of this folder, and no allow rule')
    gate = settings.dig('hooks', 'PreToolUse')
    assert_equal [1, '.*', 'command'], [gate.length, gate[0]['matcher'], gate[0].dig('hooks', 0, 'type')]
    command = gate[0].dig('hooks', 0, 'command')
    assert_hook(command, 'Read', { 'file_path' => File.join(@project, 'a.txt') }, 0)
    assert_hook(command, 'mcp__kairos-chain__kairomone_status', {}, 0)
    assert_hook(command, 'Write', { 'file_path' => File.join(@project, 'b.txt'), 'content' => 'x' }, 2)
    assert_hook(command, 'mcp__kairos-chain__chain_status', {}, 2)
    assert_hook(command, 'Bash', { 'command' => 'sleep 600', 'run_in_background' => true }, 2)
    assert_hook(command, 'mcp__kairos-chain__kairomone_backup', { 'command' => 'restore', 'file' => 'a.kairomone.json' }, 2)
  end

  def run_helper(mode)
    helper = File.join(@root, 'child_process_helper.rb')
    File.write(helper, CHILD_PROCESS_HELPER)
    command = [RbConfig.ruby, helper, CORE_LIB, File.join(PACKAGE, 'lib'), @fake, @project, mode]
    Open3.popen3(*command) do |stdin, stdout, stderr, thread|
      stdin.close
      out = Thread.new { stdout.read }
      err = Thread.new { stderr.read }
      unless thread.join(40)
        [-thread.pid, thread.pid].each do |target|
          Process.kill('KILL', target)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
        flunk "the ChildProcess helper (#{mode}) did not finish within 40 s"
      end
      assert thread.value.success?, "helper (#{mode}) failed: #{err.value}"
      JSON.parse(out.value.lines.last)
    end
  end

  def test_mode_handshake_permissions_and_http_contract
    console = open_console(hold: true)
    fake = wait_for_fake
    first = wait_until(20, 'the first line written to the child') { fake_stdin(fake).first }
    assert_equal 'control_request', first['type']
    assert_equal({ 'subtype' => 'set_permission_mode', 'mode' => 'manual' }, first['request'],
                 'the mode request is the first thing the child reads')

    page = request(:get, '/', session: nil, check: false)
    assert_equal '200', page.code
    assert_match(%r{\Atext/html}, page['Content-Type'])
    @expected_csp = csp_for(page.body)
    assert_contract_headers(page)
    assert_page_contract(page.body)

    ["localhost:#{@port}", '127.0.0.1', "127.0.0.1:#{@port}0", "evil.example:#{@port}"].each do |host|
      assert_equal '403', request(:get, '/', session: nil, host: host).code, host
    end
    [nil, "http://localhost:#{@port}", "http://127.0.0.1:#{@port}0", 'null'].each do |origin|
      assert_equal '403', exchange(@bootstrap, origin: origin).code, origin.inspect
    end
    assert_equal '403', request(:post, '/session', session: nil).code, 'no bootstrap'
    assert_equal '403', exchange('0' * 64).code
    take_session!
    assert_equal '403', exchange(@bootstrap).code, 'the printed bootstrap is spent on first use'
    assert_equal '403', request(:get, '/events?after=0', session: nil).code
    assert_equal '403', request(:get, '/events?after=0', session: @bootstrap).code

    started = wait_event { |e| e['kind'] == 'child_started' }
    assert_equal false, started['resumed']
    res = request(:post, '/message', body: { 'text' => 'PLAIN OWNER-MARKER-0' })
    assert_equal ['409', { 'error' => 'not_accepting', 'reason' => 'mode_unconfirmed' }], [res.code, JSON.parse(res.body)]
    release_first_echo!
    wait_accepting
    assert_equal %w[default echo], events_of('mode').last.values_at('word', 'source')
    assert_equal true, events_of('mode').last['asking']

    status = JSON.parse(request(:get, '/status').body)
    assert_equal @data, status['data_dir']
    assert_equal 'console_dot', status.dig('status', 'profile', 'dot_id')
    assert_equal '403', request(:post, '/message', session: nil, body: { 'text' => 'PLAIN x' }).code
    assert_equal '403', request(:post, '/message', origin: nil, body: { 'text' => 'PLAIN x' }).code
    assert_equal '413', request(:post, '/message', body: JSON.generate('text' => 'a' * 70_000)).code

    mark = mark!
    res = request(:post, '/message', body: { 'text' => 'PLAIN OWNER-MARKER-1' })
    assert_equal ['202', { 'accepted' => true }], [res.code, JSON.parse(res.body)]
    wait_event { |e| e['kind'] == 'turn_end' && e['seq'] > mark }
    assert(events_of('owner_message').any? { |e| e['text'] == 'PLAIN OWNER-MARKER-1' })
    assert(events_of('assistant_text').any? { |e| e['text'].to_s.include?('ASSISTANT-MARKER-1') })
    assert_empty events_of('foreign_turn'), 'the replay of the page message is not foreign'
    sent = fake_stdin(fake).select { |line| line['type'] == 'user' }.map { |line| text_of(line.dig('message', 'content')) }
    assert_equal ['PLAIN OWNER-MARKER-1'], sent, 'a refused message never reaches the child'

    mark = mark!
    assert_equal '202', request(:post, '/message', body: { 'text' => 'ASK OWNER-MARKER-2' }).code
    asked = wait_event { |e| e['kind'] == 'permission_request' && e['seq'] > mark }
    record = wait_until(10, 'the request record') { jsonl('requests.jsonl').find { |r| r['request_id'] == asked['request_id'] } }
    assert_equal ['Bash', record['input']], asked.values_at('tool_name', 'input'), 'the page shows the input verbatim'
    assert_equal '404', request(:post, '/permission/no-such-request', body: { 'decision' => 'allow' }).code
    res = request(:post, "/permission/#{asked['request_id']}",
                  body: { 'decision' => 'allow', 'updatedInput' => { 'command' => 'echo replaced' } })
    unless res.code == '200'
      assert_empty answers_for(fake, asked['request_id']), 'a refused answer writes nothing'
      res = request(:post, "/permission/#{asked['request_id']}", body: { 'decision' => 'allow' })
    end
    assert_equal '200', res.code
    answer = wait_until(10, 'the allow to reach the child') { answers_for(fake, asked['request_id']).first }
    assert_equal ['allow', record['input']], answer.dig('response', 'response').values_at('behavior', 'updatedInput')
    done = wait_event { |e| e['kind'] == 'tool_result' && e['tool_use_id'] == asked['tool_use_id'] }
    assert_equal [true, 'user_temporary', 'accept'], done.values_at('decided_by_page', 'decision_source', 'decision')
    assert_equal '409', request(:post, "/permission/#{asked['request_id']}", body: { 'decision' => 'deny' }).code
    assert_equal 1, answers_for(fake, asked['request_id']).length
    wait_event { |e| e['kind'] == 'turn_end' && e['seq'] > done['seq'] }

    mark = mark!
    assert_equal '202', request(:post, '/message', body: { 'text' => 'ASKGROWTH OWNER-MARKER-3' }).code
    growth = wait_event { |e| e['kind'] == 'permission_request' && e['seq'] > mark }
    assert_equal 'mcp__kairos-chain__kairomone_growth', growth['tool_name']
    assert_equal '200', request(:post, "/permission/#{growth['request_id']}", body: { 'decision' => 'deny' }).code
    answer = wait_until(10, 'the deny to reach the child') { answers_for(fake, growth['request_id']).first }
    assert_equal 'deny', answer.dig('response', 'response', 'behavior')
    denied = wait_event { |e| e['kind'] == 'tool_result' && e['tool_use_id'] == growth['tool_use_id'] }
    assert_equal [true, 'user_reject', 'reject'], denied.values_at('decided_by_page', 'decision_source', 'decision')
    wait_event { |e| e['kind'] == 'turn_end' && e['seq'] > denied['seq'] }

    assert_equal '202', request(:post, '/stop', body: {}).code
    refute_nil console.wait_exit(15), 'POST /stop ends the console'
    wait_until(7.5, 'the child to be gone after stop') { !alive?(fake['pid']) }
    console.drain
    log = File.read(File.join(@data, 'run', 'kairomone_console.log'))
    [asked['request_id'], growth['request_id'], 'user_temporary', 'user_reject'].each { |text| assert_includes log, text }
    MARKERS.each do |marker|
      refute_includes log, marker, 'the console log holds no tool input or message text'
      refute_includes console.output, marker, 'the console terminal shows no stream text'
    end
    assert_empty files_holding(@bootstrap, @session), 'no secret is written to any file'
  end

  def test_mode_switch_both_ways_interrupt_and_foreign_turn
    open_console
    fake = wait_for_fake
    take_session!
    wait_accepting

    mark = mark!
    assert_equal '202', request(:post, '/mode', body: { 'mode' => 'auto' }).code
    auto = wait_event { |e| e['kind'] == 'mode' && e['word'] == 'auto' && e['source'] == 'status' && e['seq'] > mark }
    assert_equal false, auto['asking']
    assert_equal '409', request(:post, '/mode', body: { 'mode' => 'bypassPermissions' }).code
    mark = mark!
    assert_equal '202', request(:post, '/message', body: { 'text' => 'PLAIN OWNER-MARKER-4' }).code
    wait_event { |e| e['kind'] == 'turn_end' && e['seq'] > mark }
    assert_empty events_of('mode_mismatch'), 'a turn reporting the confirmed auto is no mismatch'

    mark = mark!
    assert_equal '202', request(:post, '/mode', body: { 'mode' => 'ask' }).code
    wait_event { |e| e['kind'] == 'mode' && e['word'] == 'default' && e['source'] == 'status' && e['seq'] > mark }
    wait_accepting(mark)
    assert_equal %w[manual auto manual], jsonl('modes.jsonl'), 'the child is only ever asked for manual or auto'

    mark = mark!
    assert_equal '202', request(:post, '/message', body: { 'text' => 'HOLD OWNER-MARKER-5' }).code
    wait_event { |e| e['kind'] == 'assistant_text' && e['seq'] > mark }
    res = request(:post, '/message', body: { 'text' => 'PLAIN OWNER-MARKER-6' })
    assert_equal ['409', 'turn_in_progress'], [res.code, JSON.parse(res.body)['reason']]
    assert_equal '202', request(:post, '/interrupt', body: {}).code
    wait_until(10, 'the interrupt to reach the child') { jsonl('interrupts.jsonl').any? { |i| i['in_turn'] } }
    wait_event { |e| e['kind'] == 'turn_end' && e['seq'] > mark }

    mark = mark!
    assert_equal '202', request(:post, '/message', body: { 'text' => 'FOREIGN OWNER-MARKER-7' }).code
    foreign = wait_event { |e| e['kind'] == 'foreign_turn' && e['seq'] > mark }
    assert_equal 'kairomone_peer_fixture', foreign.dig('origin', 'name')
    assert_includes foreign['text'], 'FOREIGN-TEXT-MARKER'
    wait_until(10, 'the console to interrupt the foreign turn') { jsonl('interrupts.jsonl').any? { |i| i['foreign_active'] } }
    assert_empty(fake_stdin(fake).select { |line| line['type'] == 'user' && text_of(line.dig('message', 'content')).include?('FOREIGN-TEXT') },
                 'the console never sends the foreign text back')
  end

  def test_enter_reissues_the_url_and_a_second_console_is_refused
    console = open_console
    wait_for_fake
    first_session = take_session!
    console.press_enter
    urls = console.wait_for_urls(2, timeout: 15)
    assert_operator urls.length, :>=, 2, 'Enter at the console terminal prints a fresh URL'
    fresh = urls.last[1]
    refute_equal @bootstrap, fresh
    assert_equal '403', request(:get, '/events?after=0', session: first_session).code, 'the previous session is revoked'
    take_session!(fresh)
    assert_equal '200', request(:get, '/events?after=0').code

    second = start_console
    status = second.wait_exit(30)
    refute_nil status, 'a second console on the same folder ends by itself'
    refute status.success?
    assert_equal 1, fake_reports.length, 'the refused console started no child'
    assert_equal '200', request(:get, '/events?after=0').code, 'the first console still serves'
  end

  def test_child_contract_and_sigkill_leave_no_child_grandchild_or_watchdog
    console = open_console
    fake = wait_for_fake
    take_session!
    wait_accepting
    assert_equal '202', request(:post, '/message', body: { 'text' => 'GRANDCHILD OWNER-MARKER-8' }).code
    grandchild = wait_until(20, 'the grandchild') { read_json('grandchild.json') }

    assert_child_argv(fake['argv'])
    assert_equal @console_env, fake['env'], 'the child gets the console environment with nothing added'
    assert_empty files_holding(@bootstrap, @session), 'no secret in the child argv, env, input or any file'
    assert_equal [], fake['fds'], 'no descriptor beyond stdio reaches the child'
    assert_equal File.realpath(@project), File.realpath(fake['cwd'])
    assert_tty_control_works
    refute_equal 'open', fake['tty'], 'the child has no controlling terminal'
    watchdog = fake['ppid']
    assert_equal watchdog, fake['sid'], 'the child runs in the session its watchdog created'
    refute_equal Process.getsid(console.pid), fake['sid']
    assert_includes command_of(watchdog).to_s, 'kairomone_console_watchdog.rb'
    assert_equal fake['sid'], grandchild['grandchild_sid']
    refute_equal fake['pgid'], grandchild['grandchild_pgid'], 'fixture: the grandchild leads a process group of its own'

    pids = { 'claude' => fake['pid'], 'grandchild' => grandchild['grandchild_pid'], 'watchdog' => watchdog }
    pids.each { |name, pid| assert alive?(pid), "#{name} runs before the kill" }
    started = monotonic
    Process.kill('KILL', console.pid)
    left = pids
    until (left = pids.select { |_, pid| alive?(pid) }).empty? || monotonic - started > 7.5
      sleep 0.1
    end
    assert_empty left, "alive #{(monotonic - started).round(1)} s after SIGKILL: #{left.keys.join(', ')}"
  end

  def test_resume_repeats_the_handshake_and_stop_denies_what_is_pending
    console = open_console('--resume', RESUME_ID, hold: true)
    fake = wait_for_fake
    assert_equal RESUME_ID, value_after(fake['argv'], '--resume')
    first = wait_until(20, 'the first line written to the child') { fake_stdin(fake).first }
    assert_equal({ 'subtype' => 'set_permission_mode', 'mode' => 'manual' }, first['request'])
    take_session!
    started = wait_event { |e| e['kind'] == 'child_started' }
    assert_equal [true, RESUME_ID], started.values_at('resumed', 'session_id')
    res = request(:post, '/message', body: { 'text' => 'PLAIN OWNER-MARKER-9' })
    assert_equal ['409', 'mode_unconfirmed'], [res.code, JSON.parse(res.body)['reason']]
    release_first_echo!
    wait_accepting

    mark = mark!
    assert_equal '202', request(:post, '/message', body: { 'text' => 'ASK OWNER-MARKER-10' }).code
    asked = wait_event { |e| e['kind'] == 'permission_request' && e['seq'] > mark }
    assert_equal '202', request(:post, '/stop', body: {}).code
    refute_nil console.wait_exit(15), 'POST /stop ends the console'
    answer = wait_until(10, 'the pending request to be denied') { answers_for(fake, asked['request_id']).first }
    assert_equal ['deny'], answers_for(fake, asked['request_id']).map { |a| a.dig('response', 'response', 'behavior') }
    assert_equal 'deny', answer.dig('response', 'response', 'behavior')
    wait_until(7.5, 'the child to be gone after stop') { !alive?(fake['pid']) }
    console.drain
    assert_includes console.output, RESUME_ID, 'the terminal names the resumed session'
    assert_includes File.read(File.join(@data, 'run', 'kairomone_console.log')), RESUME_ID
  end

  def test_child_exit_is_shown_on_the_page
    open_console
    wait_for_fake
    take_session!
    wait_accepting
    assert_equal '202', request(:post, '/message', body: { 'text' => 'EXIT 7' }).code
    wait_event { |e| e['kind'] == 'child_exited' }
    assert_equal '409', request(:post, '/message', body: { 'text' => 'PLAIN OWNER-MARKER-11' }).code
  end

  def test_an_install_edited_after_recording_refuses_to_start
    File.open(File.join(@data, 'skillsets', 'kairomone', 'plugin', 'SKILL.md'), 'a') { |f| f.puts('<!-- edited after install -->') }
    console = start_console
    status = console.wait_exit(40)
    refute_nil status, 'the console refuses and ends'
    refute status.success?
    console.drain
    assert_match(/kairos-chain skillset\b.*\binstall\b/, console.output, 'the refusal names the core reinstall command')
    assert_empty console.urls
    assert_empty fake_reports, 'no child is started'
  end

  def test_child_process_lifeline_sweeps_the_session_and_passes_the_exit_status
    out = run_helper('lifeline')
    assert_includes out['types'], 'result', 'lines written to the child are answered on each_line'
    assert_operator out['wait_seconds'], :<=, 7.5, 'TERM, then KILL after the grace period'
    fake = fake_reports.first
    grandchild = read_json('grandchild.json')
    assert_equal [], fake['fds'], 'the lifeline descriptor is close-on-exec'
    assert_equal fake['ppid'], fake['sid'], 'the watchdog calls setsid and spawns the child in that session'
    assert_equal ENV.to_h, fake['env'], 'nothing is added to the environment'
    assert_equal File.realpath(@project), File.realpath(fake['cwd'])
    { 'claude' => fake['pid'], 'grandchild' => grandchild['grandchild_pid'], 'watchdog' => fake['ppid'] }.each do |name, pid|
      refute alive?(pid), "#{name} is gone once wait returns"
    end
    Dir[File.join(@reports, '*')].each { |path| File.delete(path) }
    assert_equal 7, run_helper('exit')['exitstatus'], 'the watchdog exits with the child status'
  end
end
