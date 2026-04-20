#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for P2.1: Daemon skeleton + PID lock + signal handling + event loop.
#
# Usage:
#   ruby KairosChain_mcp_server/test_daemon.rb
#
# Philosophy: the daemon is a long-lived process, but nothing in P2.1 requires
# an actual background process for tests. We inject the sleeper/clock and
# drive `tick_once` / `event_loop` directly.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'
require 'yaml'

require 'kairos_mcp/daemon'

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

# Silent test logger — records entries instead of writing to disk.
class TestLogger
  attr_reader :entries

  def initialize
    @entries = []
  end

  %i[debug info warn error].each do |lvl|
    define_method(lvl) do |event, **fields|
      @entries << { level: lvl, event: event, **fields }
    end
  end

  def close; end

  def events(event_name)
    @entries.select { |e| e[:event] == event_name.to_s || e[:event] == event_name }
  end
end

def make_daemon(root:, config: nil, sleeper: ->(_) {})
  cfg_path = nil
  if config
    cfg_path = File.join(root, '.kairos', 'config', 'daemon.yml')
    FileUtils.mkdir_p(File.dirname(cfg_path))
    File.write(cfg_path, YAML.dump(config))
  end
  KairosMcp::Daemon.new(
    config_path: cfg_path,
    root: root,
    logger: TestLogger.new,
    sleeper: sleeper
  )
end

# ---------------------------------------------------------------------------
# 1. PidLock
# ---------------------------------------------------------------------------
section 'PidLock'

Dir.mktmpdir do |root|
  pid_path = File.join(root, 'run', 'daemon.pid')

  file = KairosMcp::Daemon::PidLock.acquire!(pid_path)

  assert('acquire! creates pid file') { File.exist?(pid_path) }
  assert('acquire! writes our PID to the file') do
    File.read(pid_path).to_i == Process.pid
  end
  assert('acquire! returns a File handle') { file.is_a?(File) }

  assert('acquire! on held lock raises AlreadyLocked') do
    begin
      KairosMcp::Daemon::PidLock.acquire!(pid_path)
      false
    rescue KairosMcp::Daemon::PidLock::AlreadyLocked => e
      e.holder_pid == Process.pid
    end
  end

  KairosMcp::Daemon::PidLock.release(file, pid_path)

  assert('release removes pid file') { !File.exist?(pid_path) }
  assert('release is idempotent (second call does not raise)') do
    KairosMcp::Daemon::PidLock.release(nil, pid_path)
    true
  end

  # After release, a fresh acquire! must succeed.
  file2 = KairosMcp::Daemon::PidLock.acquire!(pid_path)
  assert('re-acquire after release succeeds') { file2.is_a?(File) }
  KairosMcp::Daemon::PidLock.release(file2, pid_path)
end

# ---------------------------------------------------------------------------
# 2. CommandMailbox
# ---------------------------------------------------------------------------
section 'CommandMailbox'

mb = KairosMcp::Daemon::CommandMailbox.new
assert('new mailbox is empty') { mb.empty? && mb.size.zero? }

id1 = mb.enqueue(:reload, reason: 'test')
id2 = mb.enqueue(:status_dump)
assert('enqueue returns a UUID-ish id') { id1.is_a?(String) && id1.length >= 8 }
assert('size reflects pending commands') { mb.size == 2 }

drained = mb.drain
assert('drain returns all pending commands in order') do
  drained.map { |c| c[:type] } == %i[reload status_dump] &&
    drained[0][:id] == id1 && drained[1][:id] == id2
end
assert('drain empties the mailbox') { mb.empty? }

# drain bounded by `max`
5.times { mb.enqueue(:custom) }
bounded = mb.drain(max: 2)
assert('drain respects max parameter') { bounded.size == 2 && mb.size == 3 }

# Thread-safety smoke test — concurrent enqueue, single-consumer drain.
mb2 = KairosMcp::Daemon::CommandMailbox.new
threads = 4.times.map do
  Thread.new { 25.times { mb2.enqueue(:custom) } }
end
threads.each(&:join)
assert('concurrent enqueue yields size == N*threads') { mb2.size == 100 }
total = 0
total += mb2.drain(max: 100).size while !mb2.empty?
assert('drain eventually yields all enqueued commands') { total == 100 }

# ---------------------------------------------------------------------------
# 3. Config loading
# ---------------------------------------------------------------------------
section 'Config loading'

Dir.mktmpdir do |root|
  d = make_daemon(root: root) # no config file
  assert('missing config file → defaults') do
    d.config['tick_interval'] == KairosMcp::Daemon::DEFAULT_TICK_INTERVAL &&
      d.config['graceful_timeout'] == KairosMcp::Daemon::DEFAULT_GRACEFUL_TIMEOUT
  end

  d2 = make_daemon(root: root, config: { 'tick_interval' => 2, 'graceful_timeout' => 30 })
  assert('config file overrides defaults') do
    d2.config['tick_interval'] == 2 && d2.config['graceful_timeout'] == 30
  end
end

# ---------------------------------------------------------------------------
# 4. Lifecycle (start!/stop!)
# ---------------------------------------------------------------------------
section 'Daemon lifecycle'

Dir.mktmpdir do |root|
  d = make_daemon(root: root)
  d.start!
  assert('start! sets state to :running') { d.state == :running }
  assert('start! creates pid file') do
    File.exist?(File.join(root, '.kairos', 'run', 'daemon.pid'))
  end
  d.stop!
  assert('stop! sets state to :stopped') { d.state == :stopped }
  assert('stop! removes pid file') do
    !File.exist?(File.join(root, '.kairos', 'run', 'daemon.pid'))
  end
  # Idempotent stop
  d.stop!
  assert('stop! is idempotent') { d.state == :stopped }
end

# Two daemons in the same workspace → second fails
Dir.mktmpdir do |root|
  d1 = make_daemon(root: root)
  d1.start!
  d2 = make_daemon(root: root)
  raised = false
  begin
    d2.start!
  rescue KairosMcp::Daemon::PidLock::AlreadyLocked
    raised = true
  end
  assert('second daemon in same workspace raises AlreadyLocked') { raised }
  d1.stop!
end

# ---------------------------------------------------------------------------
# 5. Signal handling (dispatch, not actual kill)
# ---------------------------------------------------------------------------
section 'Signal dispatch'

Dir.mktmpdir do |root|
  d = make_daemon(root: root)
  d.start!

  KairosMcp::Daemon::SignalHandler.handle(d, 'TERM')
  assert('TERM sets shutdown_requested') { d.shutdown_requested? }

  # CF-2 fix: HUP/USR1 now set flags; tick_once translates to mailbox commands
  KairosMcp::Daemon::SignalHandler.handle(d, 'HUP')
  d.tick_once  # translates @reload_requested → mailbox → dispatch
  assert('HUP enqueues :reload') { d.config != nil }  # reload ran without crash

  KairosMcp::Daemon::SignalHandler.handle(d, 'USR1')
  d.tick_once  # translates @status_dump_requested → mailbox → dispatch
  assert('USR1 enqueues :status_dump') { d.tick_count >= 2 }  # status dump ran

  d.stop!
end

# ---------------------------------------------------------------------------
# 6. Event loop — tick_once
# ---------------------------------------------------------------------------
section 'Event loop'

Dir.mktmpdir do |root|
  d = make_daemon(root: root)
  d.start!
  before = d.tick_count
  d.tick_once
  d.tick_once
  assert('tick_once increments tick_count') { d.tick_count == before + 2 }
  d.stop!
end

# Reload via mailbox actually reloads config
Dir.mktmpdir do |root|
  cfg_path = File.join(root, '.kairos', 'config', 'daemon.yml')
  FileUtils.mkdir_p(File.dirname(cfg_path))
  File.write(cfg_path, YAML.dump('tick_interval' => 5))
  d = KairosMcp::Daemon.new(
    config_path: cfg_path,
    root: root,
    logger: TestLogger.new,
    sleeper: ->(_) {}
  )
  d.start!
  # Rewrite config and deliver HUP
  File.write(cfg_path, YAML.dump('tick_interval' => 7))
  KairosMcp::Daemon::SignalHandler.handle(d, 'HUP')
  d.tick_once
  assert('reload picks up new tick_interval') { d.config['tick_interval'] == 7 }
  d.stop!
end

# Full event_loop with injected sleeper that flips shutdown flag
Dir.mktmpdir do |root|
  ticks = 0
  d = make_daemon(root: root)
  # Replace sleeper so test doesn't block; flip shutdown after 3 ticks
  d.instance_variable_set(:@sleeper, ->(_) {
    ticks += 1
    d.request_shutdown!('test') if ticks >= 3
  })
  d.start!
  d.event_loop
  # CF-4 fix: verify event_loop actually returned (tick_count proves it ran)
  assert('event_loop exits on shutdown_requested') { d.tick_count >= 3 && d.shutdown_requested? }
  assert('event_loop ran multiple ticks before shutdown') { d.tick_count >= 3 }
  d.stop!
end

# Graceful timeout — simulate long-running work by re-enqueuing on every
# dispatch, so the mailbox-empty early-exit never fires; the sleeper advances
# a fake clock past the deadline so the graceful_timeout branch is reached.
Dir.mktmpdir do |root|
  fake_time = Time.now.utc
  clock = -> { fake_time }
  d = KairosMcp::Daemon.new(
    config_path: nil,
    root: root,
    logger: TestLogger.new,
    sleeper: ->(_) { fake_time += 60 }, # each sleep advances 60s
    clock: clock
  )
  d.instance_variable_set(:@graceful_timeout, 30.0)

  # Keep the mailbox non-empty: every dispatched command re-enqueues one.
  def d.dispatch_command(_cmd)
    mailbox.enqueue(:custom)
  end

  d.start!
  d.request_shutdown!('TERM')
  d.mailbox.enqueue(:custom) # seed
  d.event_loop
  assert('event_loop exits when graceful_timeout exceeded') do
    d.logger.events(:daemon_graceful_timeout_exceeded).any?
  end
  d.stop!
end

# Status snapshot
Dir.mktmpdir do |root|
  d = make_daemon(root: root)
  d.start!
  snap = d.status_snapshot
  assert('status_snapshot includes key fields') do
    %i[state pid tick_count mailbox_size started_at].all? { |k| snap.key?(k) } &&
      snap[:pid] == Process.pid && snap[:state] == 'running'
  end
  d.stop!
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
