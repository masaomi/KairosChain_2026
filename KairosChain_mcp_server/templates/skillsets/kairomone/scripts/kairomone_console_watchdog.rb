#!/usr/bin/env ruby
# frozen_string_literal: true

# Kairomone console watchdog. The console starts it with the read end of a
# lifeline pipe as descriptor 3 and the child's command after "--". It leaves
# the console's session (so nothing it starts has a controlling terminal),
# runs the child in that new session, and ends the whole session when the
# lifeline reads end-of-file — the console ended, in any way, SIGKILL
# included — or when the child exits by itself. Claude Code runs each shell
# command in a process group of its own, so the session, not a group, is the
# unit. A process that has left this session (setsid, a daemonizing
# interpreter) is outside its reach; so is the watchdog being killed with
# SIGKILL itself.
#
# It writes nothing to stdout, which is the child's stream to the console.

GRACE_SECONDS = 5
PS = File.executable?('/bin/ps') ? '/bin/ps' : 'ps'

def note(text)
  $stderr.write("kairomone console watchdog: #{text}\n")
rescue StandardError
  nil
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Every live process whose session is ours. Zombies are skipped: they hold no
# resources and cannot be signalled away.
def session_members(sid)
  listing = IO.popen([PS, '-A', '-o', 'pid=,stat='], err: File::NULL, &:read)
  listing.each_line.filter_map do |line|
    pid, stat = line.split
    pid = Integer(pid, exception: false)
    next if pid.nil? || pid == Process.pid || stat.to_s.start_with?('Z')
    begin
      pid if Process.getsid(pid) == sid
    rescue SystemCallError
      nil
    end
  end
rescue SystemCallError, IOError
  []
end

def signal_all(signal, pids)
  pids.each do |pid|
    Process.kill(signal, pid)
  rescue SystemCallError
    nil
  end
end

# TERM to every member, KILL to any still alive after the grace period. The
# child's own group is signalled too, in case ps cannot be run — but only
# while the child is unreaped, because only then can its id not be reused.
def sweep(sid, child, waiter)
  own_group = -> { waiter.alive? ? [-child] : [] }
  members = session_members(sid)
  signal_all('TERM', members + own_group.call)
  deadline = now + GRACE_SECONDS
  sleep 0.05 until (members = session_members(sid)).empty? || now >= deadline
  3.times do
    break if members.empty?
    signal_all('KILL', members)
    sleep 0.05
    members = session_members(sid)
  end
  signal_all('KILL', own_group.call)
end

begin
  lifeline = IO.new(3, 'r')
rescue SystemCallError, ArgumentError
  note('no lifeline on descriptor 3; refusing to start a child that could outlive the console')
  exit 2
end
lifeline.close_on_exec = true
separator = ARGV.index('--')
command = separator ? ARGV[(separator + 1)..] : []
if command.empty?
  note('no child command after "--"')
  exit 2
end
begin
  Process.setsid
rescue SystemCallError => e
  note("cannot start a new session (#{e.class}); refusing to start the child")
  exit 2
end
sid = Process.getsid
events = Queue.new
%w[TERM INT HUP].each { |signal| trap(signal) { events << :signal } }
begin
  # The [path, argv0] form never goes through a shell.
  child = Process.spawn([command[0], command[0]], *command[1..], pgroup: true, close_others: true)
rescue SystemCallError => e
  note("could not start #{File.basename(command[0])}: #{e.class}")
  exit 127
end
Thread.new do
  lifeline.read
rescue IOError, SystemCallError
  nil
ensure
  events << :lifeline
end
waiter = Thread.new do
  Process.wait2(child)[1]
ensure
  events << :exited
end
events.pop
sweep(sid, child, waiter)
status = begin
  waiter.join(GRACE_SECONDS + 5) ? waiter.value : nil
rescue StandardError
  nil
end
exit(status&.exitstatus || 1)
