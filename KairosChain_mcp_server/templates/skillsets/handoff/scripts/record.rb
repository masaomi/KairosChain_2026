# frozen_string_literal: true

# Ties a handoff the session has just saved to L2 to the Claude Code session
# that saved it, and appends a block to the instance's log file when one is
# configured. Run by the session after context_save (see plugin/SKILL.md):
#   ruby record.rb --name <L2 name> [--session <L2 session id>] [--claude-session <uuid>]
# Fails (exit 1, one line on stderr) and records nothing when the named handoff
# is not in L2, when a value is not in its form, or when the log file cannot be
# written.
require 'optparse'
require_relative '../hooks/common'

begin
  opts = {}
  OptionParser.new do |o|
    o.banner = 'Usage: record.rb --name NAME [--session L2_SESSION] [--claude-session UUID]'
    o.on('--name NAME') { |v| opts[:name] = HandoffHook.utf8(v) }
    o.on('--session L2_SESSION') { |v| opts[:session] = HandoffHook.utf8(v) }
    o.on('--claude-session UUID') { |v| opts[:sid] = HandoffHook.utf8(v) }
  end.parse!

  name = opts[:name].to_s
  raise HandoffHook::Unreadable, '--name is required' if name.empty?
  raise HandoffHook::Unreadable, "not an L2 name: #{name.inspect}" unless HandoffHook::L2_NAME.match?(name)

  l2_session = opts[:session].to_s
  unless l2_session.empty? || HandoffHook::L2_NAME.match?(l2_session)
    raise HandoffHook::Unreadable, "not an L2 session id: #{l2_session.inspect}"
  end

  # The Claude Code session: named on the command line, or the one this
  # process runs in. A value given and not in form is an error; none at all
  # is allowed (another host), and then no resume command is written.
  sid = opts.key?(:sid) ? opts[:sid] : HandoffHook.utf8(ENV['CLAUDE_CODE_SESSION_ID'])
  sid = nil if sid.empty? && !opts.key?(:sid)
  raise HandoffHook::Unreadable, "not a Claude Code session id: #{sid.inspect}" if sid && !HandoffHook::SESSION_ID.match?(sid)

  # A regular file, in a session directory whose name is a name, that is really
  # inside the context directory (a link out of it does not count). The
  # pattern is relative to the context directory, so no character of the path
  # that leads there is read as a pattern.
  context = File.join(HandoffHook.data_dir, 'context')
  pattern = File.join(l2_session.empty? ? '*' : l2_session, name, "#{name}.md")
  inside = File.directory?(context) ? File.join(File.realpath(context), '') : nil
  file = Dir.glob(pattern, base: context).map { |rel| File.join(context, rel) }.select do |p|
    File.file?(p) && HandoffHook::L2_NAME.match?(File.basename(File.dirname(File.dirname(p)))) &&
      inside && File.realpath(p).start_with?(inside)
  end.max_by { |p| File.mtime(p) }
  raise HandoffHook::Unreadable, "no such handoff in L2: #{File.join(context, pattern)}" unless file

  l2_session = File.basename(File.dirname(File.dirname(file)))
  cfg = HandoffHook.config
  log = HandoffHook.log_path(cfg)
  entry = { 'name' => name, 'l2_session' => l2_session, 'at' => HandoffHook.stamp(Time.now) }
            .merge(HandoffHook.priority(file))
  title = sid && HandoffHook.title(HandoffHook.read_rows(HandoffHook.find_transcript(sid)))

  # The log first, the state second, both under the state's lock: when the log
  # cannot be written nothing is recorded, and a session end that runs at the
  # same moment sees either neither or both.
  write = lambda do |state|
    HandoffHook.append(log, HandoffHook.handoff_block(entry, sid, title)) if log
    next unless state

    state['handoffs'].reject! { |h| h['name'] == name && h['l2_session'] == l2_session }
    state['handoffs'] << entry
  end
  sid ? HandoffHook.with_state(sid, &write) : write.call(nil)

  puts(sid || log ? "handoff recorded: #{name} (L2 session #{l2_session})" : "handoff found, nothing recorded: #{name} (L2 session #{l2_session})")
  puts "priority: #{HandoffHook.priority_text(entry) || 'none read (importance and urgency, integers 1 to 5, go in the frontmatter)'}"
  puts(sid ? "Claude Code session: #{sid}#{title.to_s.empty? ? '' : " (#{title})"}" : 'Claude Code session: unknown (no --claude-session and CLAUDE_CODE_SESSION_ID is not set), so no resume command is written and the session-end block will not list this handoff')
  puts(log ? "log file: block appended to #{log}" : 'log file: off (log_file is empty in config/handoff.yml)')
rescue HandoffHook::Unreadable, SystemCallError, OptionParser::ParseError => e
  warn "handoff: #{e.message}"
  exit 1
rescue StandardError => e
  warn "handoff: #{e.class}: #{HandoffHook.utf8(e.message).lines.first.to_s.strip}"
  exit 1
end
