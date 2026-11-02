#!/usr/bin/env ruby
# frozen_string_literal: true

# Kairomone 0.9, opening the console from the CLI and Claude Code (design
# log/kairomone_0_9_screens_and_generated_growth_design_v0.2_20261102.md,
# Inv 10, N8): `console [--open [--detach] | --stop]`. With --open the
# one-time URL goes only to the browser: no start URL or session secret
# reaches stdout, stderr, a log or a pipe, with or without --detach; a
# browser that cannot be launched stops the console, which says so without
# the URL; --detach alone is refused; --stop signals the PID the console lock
# names only when that process is the console script.
#
# The installed copy of the SkillSet runs in a temporary project with its
# output on pipes (as `!` in Claude Code reads it). A fake `claude` answers
# the mode handshake and stays alive until signalled; a fake browser opener
# (named by KAIROMONE_CONSOLE_BROWSER, the test hook beside
# KAIROMONE_CONSOLE_CLAUDE) records the URL it is handed in the test's
# reports folder, so that file is the one place the URL may be. No model, no
# network, no real browser. Every process started here has the temporary root
# in its command line, and teardown kills only those.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require_relative 'templates/skillsets/kairomone/lib/kairomone/console'
require 'kairos_mcp/skillset_manager'
require 'tmpdir'
require 'open3'
require 'net/http'
require 'minitest/autorun'

class Kairomone09ConsoleCliTest < Minitest::Test
  CORE_LIB = File.expand_path('lib', __dir__)
  PACKAGE = File.expand_path('templates/skillsets/kairomone', __dir__)
  URL = %r{\Ahttp://127\.0\.0\.1:(\d+)/#([0-9a-f]{64})\z}
  SECRET_SHAPES = [%r{127\.0\.0\.1:\d+/#}, /[0-9a-f]{64}/].freeze

  FAKE_CLAUDE = <<~'RUBY'
    #!__RUBY__
    # frozen_string_literal: true
    # Fake `claude`: answers the console's mode request as the CLI does
    # (manual is echoed as default), answers other control requests with
    # success, and stays alive until it is signalled. No model, no network.
    require 'json'
    REPORTS = File.expand_path('../reports', __dir__)
    $stdout.sync = true
    $term = false
    trap('TERM') { $term = true }
    File.write(File.join(REPORTS, "claude-#{Process.pid}.json"), JSON.generate('pid' => Process.pid))
    buffer = +''
    until $term
      next unless IO.select([$stdin], nil, nil, 0.1)

      chunk = $stdin.read_nonblock(65_536, exception: false)
      if chunk.nil?
        sleep 0.1 until $term
        break
      end
      next if chunk == :wait_readable

      buffer << chunk
      while (newline = buffer.index("\n"))
        message = (JSON.parse(buffer.slice!(0, newline + 1)) rescue nil)
        next unless message.is_a?(Hash) && message['type'] == 'control_request'

        request = message['request'] || {}
        response = { 'subtype' => 'success', 'request_id' => message['request_id'] }
        response['response'] = { 'mode' => request['mode'] == 'manual' ? 'default' : request['mode'] } if request['subtype'] == 'set_permission_mode'
        $stdout.puts(JSON.generate('type' => 'control_response', 'response' => response))
      end
    end
    exit!(0)
  RUBY

  # Fake browser opener: records the URL it is handed, prints nothing, and
  # fails when the test asks it to.
  FAKE_BROWSER = <<~'RUBY'
    #!__RUBY__
    reports = File.expand_path('../reports', __dir__)
    File.write(File.join(reports, "browser-#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}.url"), ARGV.join("\n"))
    exit(File.exist?(File.join(reports, 'browser_fail')) ? 3 : 0)
  RUBY

  # A command on pipes, as Claude Code's ! or a shell pipe reads it.
  class Run
    attr_reader :pid

    def initialize(env, argv, chdir)
      @stdin, @stdout, @stderr, @thread = Open3.popen3(env, *argv, chdir: chdir)
      @pid = @thread.pid
      @out = +''
      @err = +''
      @readers = [[@stdout, @out], [@stderr, @err]].map do |io, buffer|
        Thread.new do
          loop { buffer << io.readpartial(4096) }
        rescue EOFError, IOError
          nil
        end
      end
    end

    def out = @out.dup
    def err = @err.dup
    def both = out + err
    def press_enter = @stdin.write("\n")

    # The exit status once the process ended and both pipes closed, or nil.
    def finish(timeout)
      return nil unless @thread.join(timeout)

      @readers.each { |t| t.join(timeout) }
      @readers.all? { |t| !t.alive? } ? @thread.value : nil
    end

    def close
      begin
        Process.kill('KILL', @pid) if @thread.alive?
      rescue Errno::ESRCH
        nil
      end
      @thread.join(5)
      [@stdin, @stdout, @stderr].each { |io| io.close unless io.closed? }
    end
  end

  def setup
    @root = File.realpath(Dir.mktmpdir('kairomone-console-cli-'))
    @project = File.join(@root, 'project')
    @data = File.join(@project, '.kairos')
    @home = File.join(@root, 'home')
    @bin = File.join(@root, 'bin')
    @reports = File.join(@root, 'reports')
    [@data, @home, @bin, @reports].each { |dir| FileUtils.mkdir_p(dir) }
    KairosMcp.data_dir = @data
    assert KairosMcp::SkillSetManager.new(skillsets_dir: File.join(@data, 'skillsets')).install(PACKAGE)[:success]
    Kairomone::Instance.new(host_root: @data).init(dot_id: 'console_dot', display_name: 'Console fixture')
    KairosMcp.reset_data_dir!
    File.write(File.join(@project, '.mcp.json'),
               JSON.generate('mcpServers' => { 'kairos-chain' => { 'command' => 'kairos-chain', 'args' => ['--data-dir', @data] } }))
    @claude = File.join(@bin, 'claude')
    @browser = File.join(@bin, 'claude-browser')
    { @claude => FAKE_CLAUDE, @browser => FAKE_BROWSER }.each do |path, body|
      File.write(path, body.sub('__RUBY__', RbConfig.ruby))
      File.chmod(0o755, path)
    end
    @runs = []
  end

  def teardown
    @runs.each(&:close)
    sweep_processes
    FileUtils.remove_entry_secure(@root) if @root && File.directory?(@root)
  end

  def env(browser: @browser)
    ENV.to_h.merge('HOME' => @home, 'PATH' => "#{@bin}:#{ENV.fetch('PATH', '')}", 'KAIROMONE_CONSOLE_CLAUDE' => @claude,
                   'KAIROMONE_CONSOLE_BROWSER' => browser, 'KAIROS_DATA_DIR' => nil)
  end

  def script(name) = File.join(@data, 'skillsets', 'kairomone', 'scripts', name)

  def run_console(*args, browser: @browser)
    run = Run.new(env(browser: browser), [RbConfig.ruby, '-I', CORE_LIB, script('kairomone_console.rb'), *args], @project)
    @runs << run
    run
  end

  # Through the CLI's console subcommand, as the owner types it from Claude Code.
  def run_cli(*args, browser: @browser)
    run = Run.new(env(browser: browser), [RbConfig.ruby, '-I', CORE_LIB, script('kairomone.rb'), 'console', *args], @project)
    @runs << run
    run
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

  def browser_files = Dir[File.join(@reports, 'browser-*.url')].sort
  def claude_pids = Dir[File.join(@reports, 'claude-*.json')].map { |path| JSON.parse(File.read(path))['pid'] }

  # The URLs the fake browser was handed: [[port, bootstrap], ...].
  def handed(count)
    wait_until(60, "#{count} URL(s) handed to the browser") { browser_files.length >= count && browser_files }
    browser_files.map do |path|
      match = URL.match(File.read(path)) or flunk "the browser was handed something else: #{File.read(path).inspect}"
      [Integer(match[1]), match[2]]
    end
  end

  def http(method, port, path, session: nil, headers: {})
    req = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method).new(path)
    req['Origin'] = "http://127.0.0.1:#{port}" if method == :post
    req['X-Kairomone-Session'] = session if session
    headers.each { |name, value| req[name] = value }
    if method == :post
      req.body = '{}'
      req['Content-Type'] = 'application/json'
    end
    Net::HTTP.start('127.0.0.1', port, open_timeout: 5, read_timeout: 30) { |h| h.request(req) }
  end

  def take_session(port, bootstrap)
    res = http(:post, port, '/session', headers: { 'X-Kairomone-Bootstrap' => bootstrap })
    assert_equal '200', res.code, res.body
    JSON.parse(res.body).fetch('session')
  end

  def files_holding(*secrets)
    Dir.glob(File.join(@root, '**', '*'), File::FNM_DOTMATCH).select do |path|
      File.file?(path) && secrets.any? { |secret| File.binread(path).include?(secret) }
    end
  end

  def run_dir_files = Dir[File.join(@data, 'run', '*')].reject { |path| path.end_with?('.lock') }

  def assert_no_secret_in(text, *secrets, where)
    secrets.each { |secret| refute_includes text, secret, "#{where} holds a secret" }
    SECRET_SHAPES.each { |shape| refute_match shape, text, "#{where} holds something shaped like the URL or a secret" }
  end

  def alive?(pid)
    out, status = Open3.capture2('ps', '-o', 'stat=', '-p', pid.to_s)
    status.success? && !out.strip.empty? && !out.strip.start_with?('Z')
  end

  def lock_path = File.join(@data, 'run', 'kairomone_console.lock')

  def our_processes
    out, = Open3.capture2('ps', '-A', '-ww', '-o', 'pid=,stat=,command=')
    out.each_line.filter_map do |line|
      pid, stat, command = line.strip.split(/\s+/, 3)
      pid.to_i if pid.to_i != Process.pid && !stat.to_s.start_with?('Z') && command.to_s.include?(@root)
    end
  end

  def sweep_processes
    deadline = monotonic + 7.5
    sleep 0.1 until our_processes.empty? || monotonic > deadline
    our_processes.each do |pid|
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  def test_open_hands_the_url_only_to_the_browser_and_enter_hands_a_new_one
    run = run_console('--open')
    (port, bootstrap), = handed(1)
    wait_until(20, 'the opened line') { run.out.include?('Opened in your browser') }
    session = take_session(port, bootstrap)
    status = http(:get, port, '/status', session: session)
    assert_equal '200', status.code
    assert_equal 'console_dot', JSON.parse(status.body)['shown']
    assert_equal '200', http(:get, port, '/art-history?kairomone=console_dot', session: session).code

    run.press_enter
    (_, fresh), = handed(2).drop(1)
    refute_equal bootstrap, fresh
    wait_until(10, 'the previous session to be revoked') { http(:get, port, '/status', session: session).code == '403' }
    newer = take_session(port, fresh)

    assert_equal '202', http(:post, port, '/stop', session: newer).code
    refute_nil run.finish(30), 'POST /stop ends the console'
    output = run.both
    assert_includes run.out, 'Opened in your browser (one use, within 10 minutes).'
    assert_includes run.out, 'Enter: open a new one-time URL in your browser'
    assert_no_secret_in(output, bootstrap, session, fresh, newer, 'stdout and stderr')
    run_dir_files.each { |path| assert_no_secret_in(File.read(path), bootstrap, session, fresh, newer, path) }
    assert_equal browser_files.sort, files_holding(bootstrap, session, fresh, newer).sort, 'the URL is only in what the browser was handed'
    wait_until(10, 'the child to be gone') { claude_pids.none? { |pid| alive?(pid) } }
  end

  def test_open_detach_runs_in_the_background_prints_no_url_and_stops_by_its_lock
    run = run_cli('--open', '--detach')
    status = run.finish(90)
    refute_nil status, "the starting process ends, and keeps no pipe of its caller open:\n#{run.both}"
    assert status.success?, run.both
    hint = 'ruby .kairos/skillsets/kairomone/scripts/kairomone.rb console --stop'
    assert_equal "Opened in your browser. The console runs in the background; stop it with: #{hint}\n", run.out
    assert_equal '', run.err
    (port, bootstrap), = handed(1)
    session = take_session(port, bootstrap)
    assert_equal '200', http(:get, port, '/status', session: session).code

    pid = Integer(File.read(lock_path).strip)
    refute_equal run.pid, pid, 'the console runs in a process of its own'
    command, = Open3.capture2('ps', '-ww', '-o', 'command=', '-p', pid.to_s)
    assert_match(%r{/kairomone_console\.rb --open --detach}, command, 'the lock names the console script')
    sid, = Open3.capture2('ps', '-o', 'sess=', '-p', pid.to_s) if RUBY_PLATFORM.include?('linux')
    refute_nil sid if RUBY_PLATFORM.include?('linux')
    assert_equal pid, Process.getsid(pid), 'it left the terminal\'s session'

    stop = run_cli('--stop')
    stopped = stop.finish(60)
    assert stopped&.success?, stop.both
    assert_equal "Kairomone console stopped (PID #{pid}).\n", stop.out
    refute alive?(pid)
    wait_until(10, 'the child to be gone') { claude_pids.none? { |p| alive?(p) } }
    again = run_cli('--stop')
    refute again.finish(60).success?
    assert_includes again.err, 'No Kairomone console is running for this folder'

    detached_log = File.join(@data, 'run', 'kairomone_console_detached.log')
    assert File.file?(detached_log), 'the detached console wrote its lines to its log'
    assert_includes File.read(detached_log), 'Opened in your browser'
    assert_includes File.read(detached_log), 'Kairomone console stopped (term).'
    [run, stop, again].each { |r| assert_no_secret_in(r.both, bootstrap, session, 'the starting and stopping processes\' output') }
    run_dir_files.each { |path| assert_no_secret_in(File.read(path), bootstrap, session, path) }
    assert_equal browser_files, files_holding(bootstrap, session), 'the URL is only in what the browser was handed'
  end

  def test_detach_alone_and_stop_with_other_options_are_refused
    [run_console('--detach'), run_cli('--detach')].each do |run|
      status = run.finish(30)
      refute status.success?
      assert_includes run.err, '--detach is accepted only together with --open'
    end
    stop = run_console('--stop', '--open')
    refute stop.finish(30).success?
    assert_includes stop.err, '--stop takes no other option but --project'
    assert_empty claude_pids, 'nothing was started'
    assert_empty browser_files, 'no URL was made'
    refute File.exist?(lock_path)
  end

  def test_a_browser_that_cannot_be_launched_stops_the_console_without_printing_the_url
    File.write(File.join(@reports, 'browser_fail'), '')
    run = run_console('--open')
    status = run.finish(60)
    refute_nil status, run.both
    refute status.success?
    assert_includes run.err, 'Your browser could not be opened (claude-browser ended with status 3), so the console stopped.'
    (_, bootstrap), = handed(1)
    assert_no_secret_in(run.both, bootstrap, 'stdout and stderr')
    wait_until(10, 'the child to be gone') { claude_pids.none? { |pid| alive?(pid) } }

    detached = run_cli('--open', '--detach')
    status = detached.finish(90)
    refute_nil status, detached.both
    refute status.success?
    assert_includes detached.err, 'Your browser could not be opened (claude-browser ended with status 3), so the console stopped.'
    assert_equal '', detached.out
    wait_until(20, 'the detached console to release its lock') { our_processes.none? { |pid| command_of(pid).include?('kairomone_console.rb') } }

    missing = run_console('--open', browser: File.join(@bin, 'no-such-browser'))
    refute missing.finish(60).success?
    assert_includes missing.err, 'Your browser could not be opened (no-such-browser could not be started (ENOENT)), so the console stopped.'
    handed(2).each { |(_, secret)| assert_no_secret_in(detached.both + missing.both, secret, 'output') }
    run_dir_files.each { |path| handed(2).each { |(_, secret)| refute_includes File.read(path), secret, path } }
    wait_until(10, 'every child to be gone') { claude_pids.none? { |pid| alive?(pid) } }
    refute File.read(lock_path).match?(/\d/), 'the lock names no process once the console stopped'
  end

  def command_of(pid)
    out, = Open3.capture2('ps', '-ww', '-o', 'command=', '-p', pid.to_s)
    out.strip
  end

  def test_stop_refuses_a_pid_that_is_not_the_console
    FileUtils.mkdir_p(File.dirname(lock_path), mode: 0o700)
    other = Process.spawn(RbConfig.ruby, '-e', 'sleep 60', @root, out: File::NULL, err: File::NULL)
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.write('')
      lock.flush
      held = run_cli('--stop')
      refute held.finish(30).success?
      assert_includes held.err, 'The console lock is held but names no process yet'
      lock.truncate(0)
      lock.rewind
      lock.write("#{other}\n")
      lock.flush
      stop = run_cli('--stop')
      refute stop.finish(30).success?
      assert_includes stop.err, "The process the console lock names (PID #{other}) is not the Kairomone console script; nothing was signalled"
      sleep 0.3
      assert alive?(other), 'the other process was not signalled'
    end
    free = run_cli('--stop')
    refute free.finish(30).success?
    assert_includes free.err, 'No Kairomone console is running for this folder', 'a PID in a lock nobody holds is never read'
    assert alive?(other)
  ensure
    begin
      Process.kill('KILL', other) if other
      Process.wait(other) if other
    rescue SystemCallError
      nil
    end
  end

  def test_the_stop_check_and_the_output_filter
    launch = Kairomone::Console::Launch
    assert launch.console_command?("#{RbConfig.ruby} -I /x/lib /p/.kairos/skillsets/kairomone/scripts/kairomone_console.rb --open --detach")
    assert launch.console_command?('ruby .kairos/skillsets/kairomone/scripts/kairomone_console.rb')
    assert launch.console_command?('/usr/bin/ruby3.3 kairomone_console.rb --open')
    ['ruby -e sleep', '/bin/sleep 60', 'python kairomone_console.rb', 'ruby /x/not_kairomone_console.rb', 'ruby /x/kairomone_console.rb.bak',
     'ruby /x/kairomone.rb console --open', '', nil].each { |command| refute launch.console_command?(command), command.inspect }

    secret = Kairomone::Console::Secret.new
    filter = launch::OutputFilter.new(secret)
    bootstrap = secret.issue_bootstrap
    session = secret.exchange(bootstrap)
    assert filter.pass?('Kairomone console for /p')
    [bootstrap, session, "x#{bootstrap[0, 64]}y", 'Open: http://127.0.0.1:5/#abc'].each { |line| refute filter.pass?(line), line }
    secret.issue_bootstrap
    refute filter.pass?("an old one: #{session}"), 'a revoked value is still dropped'
    assert filter.pass?("\xFF binary".b)
  end

  def test_the_detached_output_filter_catches_whatever_writes_to_stdout_and_stderr
    log = File.join(@root, 'filtered.log')
    code = <<~'RUBY'
      require 'kairomone/console'
      secret = Kairomone::Console::Secret.new
      filter = Kairomone::Console::Launch::OutputFilter.new(secret)
      bootstrap = secret.issue_bootstrap
      filter.capture!(File.open(ARGV[0], 'a'))
      puts 'kept line'
      puts "dropped #{bootstrap}"
      warn "dropped too #{bootstrap}"
      $stderr.syswrite("kept from stderr\n")
      system('echo', "from a child #{bootstrap}")
      system('echo', 'child line kept')
      filter.finish
      File.write(ARGV[1], bootstrap)
    RUBY
    secret_file = File.join(@root, 'secret.txt')
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', CORE_LIB, '-I', File.join(PACKAGE, 'lib'), '-e', code, log, secret_file)
    assert status.success?, err
    assert_equal ['', ''], [out, err], 'nothing reached the pipes'
    lines = File.read(log).lines.map(&:chomp)
    assert_equal ['kept line', 'kept from stderr', 'child line kept'], lines
    refute_includes File.read(log), File.read(secret_file)
  end
end
