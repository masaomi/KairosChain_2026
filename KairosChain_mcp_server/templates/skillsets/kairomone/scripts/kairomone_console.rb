#!/usr/bin/env ruby
# frozen_string_literal: true

# Kairomone console: a page in the owner's browser for talking to a Kairomone
# through one supervised Claude Code session, with each tool permission
# answered on the page. The owner starts it at a terminal, in the project
# folder:
#
#   ruby .kairos/skillsets/kairomone/scripts/kairomone_console.rb
#
# It prints a one-time URL. Enter prints a new one; Ctrl-C stops. The
# terminal shows fixed-format lines only, never what the stream said.
#
# With --open it hands that URL to the system browser instead and prints
# only that it opened; if the browser cannot be launched it stops and says
# so, still without the URL. --detach (only with --open) then keeps it
# running in the background, with its lines going to a log through a filter
# that drops any line holding the URL's secret or the session secret; a new
# URL means --stop and start again. --stop signals the console the lock of
# this folder names, only when that process is this script. From Claude Code
# the owner types (the assistant hands the line and never runs it):
#
#   ! ruby .kairos/skillsets/kairomone/scripts/kairomone.rb console --open --detach

require 'optparse'
require 'shellwords'
# Only the template inside a KairosChain checkout (templates/skillsets/kairomone)
# looks for its sibling core. An installed SkillSet uses the installed
# kairos-chain gem or an explicit -I: the same relative path from an installed
# copy is the project folder's own lib/, which the start check never sees.
package_root = File.expand_path('..', __dir__)
if File.basename(File.dirname(package_root)) == 'skillsets' && File.basename(File.dirname(package_root, 2)) == 'templates'
  source_core = File.expand_path('../../../lib', package_root)
  $LOAD_PATH.unshift(source_core) if File.file?(File.join(source_core, 'kairos_mcp.rb'))
end
begin
  require_relative '../lib/kairomone/console'
rescue LoadError => e
  warn "KairosChain core is unavailable: #{e.message}. Install kairos-chain >= 3.92.0, or pass -I /path/to/KairosChain_mcp_server/lib."
  exit 1
end

STOP_WAIT_SECONDS = 12
STDERR_NOTICE_LIMIT = 200
# Names the claude executable when --claude is not given; an empty value
# counts as unset. It selects no more than PATH, from the same environment.
CLAUDE_ENV = 'KAIROMONE_CONSOLE_CLAUDE'
# For tests only, the same way: names the program --open hands the URL to
# (its one argument) in place of the system's own (macOS open, else
# xdg-open), so a test can take the URL without a browser. An empty value
# counts as unset. It selects no more than PATH would, from the same
# environment; the owner has no reason to set it.
BROWSER_ENV = 'KAIROMONE_CONSOLE_BROWSER'

default_claude = ENV.fetch(CLAUDE_ENV, '')
options = { project: Dir.pwd, project_given: false, port: 0, resume: nil, claude: default_claude.empty? ? 'claude' : default_claude,
            open: false, detach: false, stop: false }
parser = OptionParser.new do |p|
  p.banner = 'Usage: kairomone_console.rb [--project DIR] [--port N] [--resume SESSION_ID] [--claude PATH] [--open [--detach] | --stop]'
  p.separator ''
  p.separator 'Serves the Kairomone console on 127.0.0.1 and supervises one Claude Code session for it.'
  p.separator 'Run it yourself at a terminal; it prints a one-time URL for your browser, or with --open hands it to the browser.'
  p.separator ''
  p.on('--project DIR', 'Project folder holding .mcp.json (default: the current folder)') do |v|
    options[:project] = v
    options[:project_given] = true
  end
  p.on('--port N', Integer, 'Port on 127.0.0.1 (default: chosen by the system)') { |v| options[:port] = v }
  p.on('--resume SESSION_ID', 'Resume this Claude Code session (it is brought back to asking mode first)') { |v| options[:resume] = v }
  p.on('--claude PATH', "The claude executable (default: $#{CLAUDE_ENV} if set, else claude on PATH)") { |v| options[:claude] = v }
  p.on('--open', 'Hand the one-time URL to your browser and print only that it opened; stop if the browser cannot be launched') { options[:open] = true }
  p.on('--detach', 'With --open: keep running in the background (stop it with --stop; a new URL means stop and start again)') { options[:detach] = true }
  p.on('--stop', 'Stop the console running for this folder (the process its lock names, only when that is this script)') { options[:stop] = true }
  p.on('-h', '--help', 'Show this help') do
    puts p
    exit
  end
end

begin
  parser.parse!(ARGV)
  raise OptionParser::NeedlessArgument, ARGV.join(' ') unless ARGV.empty?
  raise OptionParser::InvalidOption, '--detach is accepted only together with --open' if options[:detach] && !options[:open]
  if options[:stop] && (options[:open] || options[:detach] || options[:resume] || options[:port] != 0)
    raise OptionParser::InvalidOption, '--stop takes no other option but --project'
  end
rescue OptionParser::ParseError => e
  warn "Kairomone console: #{e.message}"
  warn parser.banner
  exit 1
end

# Every value the console's Secret issues is known to this filter. With
# --open, no line holding one reaches the terminal, a pipe or a log; the
# session log never holds one, however the console is started.
secret = Kairomone::Console::Secret.new
filter = Kairomone::Console::Launch::OutputFilter.new(secret)
out_lock = Mutex.new
say = lambda do |line|
  next if options[:open] && !filter.pass?(line)

  out_lock.synchronize { $stdout.puts(line); $stdout.flush }
end
# A refusal names paths; a control character in one (ESC, CR, BEL) is shown
# as its visible escape rather than reaching the terminal.
refuse = lambda do |message|
  line = "Kairomone console: #{message.gsub(/[[:cntrl:]]/) { |c| c.inspect[1..-2] }}"
  warn line if filter.pass?(line)
end

if options[:stop]
  begin
    project = Kairomone::Console::Project.load(options[:project])
    say.call(Kairomone::Console::Launch.stop(project))
    exit 0
  rescue Kairomone::Console::Refusal => e
    refuse.call(e.message)
    exit 1
  end
end

begin
  raise Kairomone::Console::Refusal, 'WEBrick is not installed for this Ruby; install it with: gem install webrick' unless defined?(::WEBrick::HTTPServer)
  project = Kairomone::Console::Project.load(options[:project])
  # Status reads use the same data directory the child's server writes.
  KairosMcp.data_dir = project.data_dir
  project.start_check!
  rules = project.restrictive_rules
  settings = Kairomone::Console::Gate.flag_settings(server: project.server_name, rules: rules)
  argv = Kairomone::Console::Child.argv(project: project, flag_settings: settings, resume: options[:resume], claude: options[:claude])
  lock = project.lock!
  log_io = begin
    File.open(project.log_path, File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600)
  rescue SystemCallError => e
    raise Kairomone::Console::Refusal, "Cannot open the console log #{project.log_path}: #{e.class}"
  end
rescue Kairomone::Console::Refusal => e
  refuse.call(e.message)
  exit 1
end

# --detach: the console carries on in a child of this process that leaves
# the terminal's session, keeps no descriptor of this one's output, and
# reports one line back; this process prints what that line says and ends.
# The lock and the log pass to the child.
report = nil
detached = nil
if options[:detach]
  reader, report = IO.pipe
  pid = fork
  if pid
    report.close
    lock.leave
    log_io.close
    script = File.join(project.package_root, 'scripts', 'kairomone.rb')
    script = script.delete_prefix("#{project.dir}/") if !options[:project_given] && script.start_with?("#{project.dir}/")
    hint = "ruby #{Shellwords.escape(script)} console --stop#{options[:project_given] ? " --project #{Shellwords.escape(project.dir)}" : ''}"
    exit Kairomone::Console::Launch.await_detached(reader, pid, out: say, err: refuse, stop_hint: hint)
  end
  reader.close
  Kairomone::Console::Launch.detach_self!
  begin
    detached = File.open(project.detached_log_path, File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600)
    detached.sync = true
  rescue SystemCallError => e
    report.puts("refused\tCannot open the detached console's log #{project.detached_log_path}: #{e.class}")
    exit 1
  end
  filter.capture!(detached)
end
# One line to the process that started a detached console, once.
tell = lambda do |line|
  next unless report && !report.closed?

  report.puts(filter.pass?(line) ? line : "error\tunreportable")
  report.close
rescue IOError, SystemCallError
  nil
end
lock.record_pid
log_io.sync = true
log_lock = Mutex.new
state = { stopping: false }

# The log takes the Session's records (tokens, booleans and numbers only);
# a few of them are also the terminal's fixed-format lines.
log = lambda do |entry|
  line = JSON.generate(entry)
  log_lock.synchronize { log_io.write(line + "\n") } if filter.pass?(line)
  case entry['event']
  when 'session_id'
    say.call("Session: #{entry['session_id']}") if entry['session_id']
  when 'mode'
    word = entry['word']
    say.call(word == 'default' ? 'Mode: default (asks before each tool use)' : "Mode: #{word || 'unrecognized'} (does not ask)")
  when 'child_exited'
    say.call("Claude Code exited (#{entry['status']}). The page shows what happened; press Ctrl-C here to close the console.") unless state[:stopping]
  end
end

outgoing = Queue.new
child = Kairomone::Console::ChildProcess.new(argv: argv, cwd: project.dir)
session = Kairomone::Console::Session.new(writer: ->(message) { outgoing << message }, log: log)
stops = Queue.new
status_reader = lambda do |kairomone = nil|
  Kairomone::Console::View.payload(project.data_dir, kairomone)
rescue StandardError => e
  # A failure for the one shown still returns the listing, so the page can switch away.
  listed = begin
    Kairomone::Host.new(host_root: project.data_dir).summaries.map { |s| s.transform_keys(&:to_s) }
  rescue StandardError
    []
  end
  { 'data_dir' => project.data_dir, 'kairomones' => listed, 'shown' => nil, 'status' => nil, 'error' => e.message }
end
art_reader = ->(kairomone) { Kairomone::Console::View.art_history(project.data_dir, kairomone) }
opener = Kairomone::Console::Launch::Opener.new(command: ENV.fetch(BROWSER_ENV, ''))

server = nil
writer = nil
stop = lambda do |by|
  next if state[:stopping]
  state[:stopping] = true
  # Deny what is pending and interrupt, let those reach the child, then
  # close the lifeline: the watchdog ends the child's session (Claude Code and
  # its MCP server; Bash commands run in sessions of their own).
  session.stop!(by: by)
  outgoing << nil
  writer&.join(2)
  child.close_lifeline
  server&.shutdown
  Thread.new { child.wait if child.pid }.join(STOP_WAIT_SECONDS)
  lock.release
  say.call("Kairomone console stopped (#{by}).")
end

# The one-time URL goes to the owner's terminal, or with --open only to the
# browser. => false when the browser could not be launched: the console
# then stops (0.9 Inv 10), and why — never the URL — is kept for the owner.
failure = nil
hand = lambda do |bootstrap|
  url = "#{server.origin}/##{bootstrap}"
  unless options[:open]
    say.call("Open in your browser (one use, within 10 minutes): #{url}")
    next true
  end
  why = opener.open(url)
  if why
    failure = why
    stops << 'browser'
    next false
  end
  say.call('Opened in your browser (one use, within 10 minutes).')
  true
end

begin
  server = Kairomone::Console::Server.new(session: session, secret: secret, status_reader: status_reader, art_reader: art_reader,
                                           page_path: File.join(project.package_root, 'assets', 'console.html'),
                                           port: options[:port], on_stop: ->(by) { stops << by.to_s }).start
  %w[INT TERM HUP].each { |signal| trap(signal) { stops << signal.downcase } }
  child.start
  writer = Thread.new do
    while (message = outgoing.pop)
      begin
        child.write(message)
      rescue IOError, SystemCallError
        nil # the child is gone; its exit reaches the page through the watchdog
      rescue StandardError => e
        # One message JSON cannot write must not end every later write
        # (answers, interrupts, the denials at stop).
        session.notice("The console could not write one message to Claude Code (#{e.class}); it was dropped.")
      end
    end
  end
  reader = Thread.new { child.each_line { |line| session.handle_line(line) } }
  Thread.new do
    count = 0
    child.stderr_lines do |line|
      count += 1
      session.notice("Claude Code (stderr): #{line.chomp[0, 2000]}") if count <= STDERR_NOTICE_LIMIT
      session.notice("Claude Code wrote more than #{STDERR_NOTICE_LIMIT} stderr lines; the rest are not shown.") if count == STDERR_NOTICE_LIMIT + 1
    end
  end
  Thread.new do
    status = child.wait
    reader.join(2)
    session.child_exited(status)
  end
  session.start!(resumed: !options[:resume].nil?, session_id: options[:resume])
  managed = project.managed_policy_paths
  unless managed.empty?
    session.notice("Organization-managed Claude Code settings are present (#{managed.join(', ')}). They bind this session whatever " \
                   'the console passes, may let tools run without asking, and are outside the console\'s reach.')
  end
  say.call("Kairomone console for #{project.dir}")
  say.call("Data directory: #{project.data_dir}")
  say.call("Resuming session #{options[:resume]}; earlier turns are not shown on the page.") if options[:resume]
  if hand.call(secret.issue_bootstrap)
    tell.call('opened')
    if options[:detach]
      say.call('Running in the background. A new URL means stopping (--stop) and starting again.')
    else
      say.call(options[:open] ? 'Enter: open a new one-time URL in your browser (the open page is signed out). Ctrl-C: stop.' :
                                'Enter: print a new URL (the open page is signed out). Ctrl-C: stop.')
      Thread.new do
        while $stdin.gets
          break unless hand.call(secret.issue_bootstrap)
        end
      rescue IOError, SystemCallError
        nil
      end
    end
  end
  by = stops.pop
  stop.call(by)
  if failure
    refuse.call("Your browser could not be opened (#{failure}), so the console stopped. Start it without --open to see its URL at your terminal.")
    tell.call("browser\t#{failure}")
    exit 1
  end
rescue Exception => e # rubocop:disable Lint/RescueException -- any end closes the lifeline
  stop.call(e.is_a?(Kairomone::Console::Refusal) ? 'refusal' : 'error')
  if e.is_a?(Kairomone::Console::Refusal)
    refuse.call(e.message)
    tell.call("refused\t#{e.message}")
  elsif !e.is_a?(SystemExit)
    warn "Kairomone console: stopped after an internal error (#{e.class})."
    tell.call("error\t#{e.class}")
  end
  tell.call("error\tended") # a detached console that ended before it reported
  exit(e.is_a?(SystemExit) ? e.status : 1)
ensure
  child.close_lifeline
  filter.finish if detached
end
