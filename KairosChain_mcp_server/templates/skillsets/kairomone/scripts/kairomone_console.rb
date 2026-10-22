#!/usr/bin/env ruby
# frozen_string_literal: true

# Kairomone console: a page in the owner's browser for talking to the dot
# through one supervised Claude Code session, with each tool permission
# answered on the page. The owner starts it at a terminal, in the project
# folder:
#
#   ruby .kairos/skillsets/kairomone/scripts/kairomone_console.rb
#
# It prints a one-time URL. Enter prints a new one; Ctrl-C stops. The
# terminal shows fixed-format lines only, never what the stream said.

require 'optparse'
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

default_claude = ENV.fetch(CLAUDE_ENV, '')
options = { project: Dir.pwd, port: 0, resume: nil, claude: default_claude.empty? ? 'claude' : default_claude }
parser = OptionParser.new do |p|
  p.banner = 'Usage: kairomone_console.rb [--project DIR] [--port N] [--resume SESSION_ID] [--claude PATH]'
  p.separator ''
  p.separator 'Serves the Kairomone console on 127.0.0.1 and supervises one Claude Code session for it.'
  p.separator 'Run it yourself at a terminal; it prints a one-time URL for your browser.'
  p.separator ''
  p.on('--project DIR', 'Project folder holding .mcp.json (default: the current folder)') { |v| options[:project] = v }
  p.on('--port N', Integer, 'Port on 127.0.0.1 (default: chosen by the system)') { |v| options[:port] = v }
  p.on('--resume SESSION_ID', 'Resume this Claude Code session (it is brought back to asking mode first)') { |v| options[:resume] = v }
  p.on('--claude PATH', "The claude executable (default: $#{CLAUDE_ENV} if set, else claude on PATH)") { |v| options[:claude] = v }
  p.on('-h', '--help', 'Show this help') do
    puts p
    exit
  end
end

begin
  parser.parse!(ARGV)
  raise OptionParser::NeedlessArgument, ARGV.join(' ') unless ARGV.empty?
rescue OptionParser::ParseError => e
  warn "Kairomone console: #{e.message}"
  warn parser.banner
  exit 1
end

out_lock = Mutex.new
say = ->(line) { out_lock.synchronize { $stdout.puts(line); $stdout.flush } }
# A refusal names paths; a control character in one (ESC, CR, BEL) is shown
# as its visible escape rather than reaching the terminal.
refuse = ->(message) { warn "Kairomone console: #{message.gsub(/[[:cntrl:]]/) { |c| c.inspect[1..-2] }}" }

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
log_io.sync = true
log_lock = Mutex.new
state = { stopping: false }

# The log takes the Session's records (tokens, booleans and numbers only);
# a few of them are also the terminal's fixed-format lines.
log = lambda do |entry|
  log_lock.synchronize { log_io.write(JSON.generate(entry) + "\n") }
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
secret = Kairomone::Console::Secret.new
stops = Queue.new
status_reader = lambda do
  { 'data_dir' => project.data_dir, 'status' => Kairomone::Instance.new(host_root: project.data_dir).status }
rescue StandardError => e
  { 'data_dir' => project.data_dir, 'status' => nil, 'error' => e.message }
end

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

begin
  server = Kairomone::Console::Server.new(session: session, secret: secret, status_reader: status_reader,
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
  url = ->(bootstrap) { "Open in your browser (one use, within 10 minutes): #{server.origin}/##{bootstrap}" }
  say.call(url.call(secret.issue_bootstrap))
  say.call('Enter: print a new URL (the open page is signed out). Ctrl-C: stop.')
  Thread.new do
    say.call(url.call(secret.issue_bootstrap)) while $stdin.gets
  rescue IOError, SystemCallError
    nil
  end
  by = stops.pop
  stop.call(by)
rescue Exception => e # rubocop:disable Lint/RescueException -- any end closes the lifeline
  stop.call(e.is_a?(Kairomone::Console::Refusal) ? 'refusal' : 'error')
  refuse.call(e.message) if e.is_a?(Kairomone::Console::Refusal)
  warn "Kairomone console: stopped after an internal error (#{e.class})." unless e.is_a?(Kairomone::Console::Refusal) || e.is_a?(SystemExit)
  exit(e.is_a?(SystemExit) ? e.status : 1)
ensure
  child.close_lifeline
end
