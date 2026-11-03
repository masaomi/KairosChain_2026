# frozen_string_literal: true

# The mod's one window onto L2 (design v0.4, INV-14). The Claude Code mod runs
#   ruby probe.rb --session <id> [--since <iso8601>]
# and reads one JSON object from stdout: the config figures, the wording of
# the request, the compaction instructions and the read-back, and this
# session's latest handoff with whether it was written at or after --since.
# Read only: it writes no state and no L2 entry, so the v0.3 hooks' cycle is
# left to the hooks. On failure it prints {"ok":false,"error":...} and exits 1.
require 'optparse'
require_relative 'common'

H = CompactionHandoffHook

module CompactionHandoffProbe
  # Names put into a prompt the session reads as the operator's: only plain
  # names; anything else is withheld (an L2 writer chooses its entry's name).
  PLAIN_NAME = /\A[A-Za-z0-9_.\-]{1,160}\z/

  module_function

  def shown(name)
    PLAIN_NAME.match?(name.to_s) ? name.to_s : '(an entry whose name has unusual characters)'
  end

  def entry_json(entry)
    entry && { 'name' => entry[:name], 'session' => entry[:session], 'written_at' => entry[:written_at].iso8601(3) }
  end

  def request_text(cfg, sid, near)
    lines = ['This session has passed its compaction request point. Write your handoff to L2 now with ' \
             'context_save, in your own words:']
    lines.concat(H.handoff_rules(cfg[:tag], sid))
    unless near.empty?
      lines << "Not counted: #{shown(near.first[:name])} has the name but its frontmatter does not carry " \
               "`#{H::FRONTMATTER_KEY}: #{sid}`."
    end
    lines << 'Write only the handoff in this turn, then end the turn. The session is compacted right after ' \
             'it, and the next turn tells you which entry to read back.'
    lines.join("\n")
  end

  # An entry named like a handoff but without the session frontmatter may still
  # hold the agent's notes; name it rather than say nothing exists.
  def near_note(near)
    return '' if near.empty?

    " An entry named like a handoff but without the session frontmatter exists: #{shown(near.first[:name])} " \
      "(L2 session #{shown(near.first[:session])}); it may hold your notes."
  end

  def compact_instructions(handoff, near = [])
    unless handoff
      return 'No handoff was written before this compaction; keep in the summary what is in progress and the ' \
             "next step.#{near_note(near)}"
    end

    "The agent wrote its handoff to L2 as #{shown(handoff[:name])} (L2 session #{shown(handoff[:session])}) " \
      'just before ' \
      'this compaction. Keep that name in the summary; the next turn reads the handoff back.'
  end

  def readback_text(cfg, sid, handoff, near = [])
    if handoff
      "This session (#{sid}) was compacted right after your handoff. Read it first: #{shown(handoff[:name])} " \
        "(L2 session #{shown(handoff[:session])}). #{H::NOTES_FRAME} Then decide from those notes how to " \
        'continue. ' \
        'Background work it mentions, such as a peer_message watch, may still be running: check before ' \
        'starting it again.'
    else
      "This session (#{sid}) was compacted, but no handoff of this session written since the request was " \
        "found under #{H.handoff_prefix(cfg[:tag], sid)}*.#{near_note(near)} Rely on the summary above; " \
        'background work, such as a peer_message watch, may still be running: check before starting it again.'
    end
  end

  def run(argv)
    opts = {}
    OptionParser.new do |o|
      o.on('--session ID') { |v| opts[:session] = v }
      o.on('--since TIME') { |v| opts[:since] = v }
    end.parse!(argv)
    sid = H.session_id({ 'session_id' => opts[:session] })
    since = opts[:since] && Time.iso8601(opts[:since])
    dir = H.data_dir
    cfg = H.config
    found, near = H.handoffs(H.l2(dir), dir, cfg[:tag], sid)
    latest = found.first
    fresh = !!(latest && since && latest[:written_at] >= since)
    current = fresh ? latest : nil
    {
      'ok' => true,
      'session' => sid,
      'compact_at_tokens' => cfg[:compact_at_tokens],
      'request_ratio' => cfg[:request_ratio],
      'request_point' => cfg[:request_point],
      'handoff' => entry_json(latest),
      'fresh' => fresh,
      'request_text' => request_text(cfg, sid, near),
      'compact_instructions' => compact_instructions(current, near),
      'readback_text' => readback_text(cfg, sid, current, near)
    }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    $stdout.write(JSON.generate(CompactionHandoffProbe.run(ARGV.dup)) + "\n")
  rescue H::Unreadable, OptionParser::ParseError, ArgumentError => e
    $stdout.write(JSON.generate({ 'ok' => false, 'error' => e.message[0, 200] }) + "\n")
    exit 1
  rescue StandardError, LoadError => e
    $stdout.write(JSON.generate({ 'ok' => false, 'error' => "#{e.class}: #{e.message[0, 200]}" }) + "\n")
    exit 1
  end
end
