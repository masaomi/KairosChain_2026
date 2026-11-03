# frozen_string_literal: true

# UserPromptSubmit hook (design INV-5): at each turn start, when the usage
# figure has reached the request point, or right after a block, and the cycle
# has no fresh save, asks the agent to write its handoff. Never blocks a
# prompt: nothing to say prints nothing and exits 0; a failure writes the
# cause to stderr and exits 1, which the host shows as a non-blocking error.

require_relative 'common'
require_relative 'usage_reader'

H = CompactionHandoffHook

def request_text(cfg, sid, state, usage, near)
  urgent = state['urgent']
  lines = []
  lines << (urgent ? '[compaction_handoff] URGENT: an auto-compaction of this session was just held off once; ' \
                     'the next one will proceed.' : '[compaction_handoff] This session is nearing auto-compaction.')
  figure = usage ? "#{usage[:tokens]} of about #{cfg[:compact_at_tokens]} tokens" : 'usage unknown'
  lines << "Context: #{figure}. Before it is compacted, write a handoff to L2 with context_save, in your own words:"
  lines << '- what is in progress, the next step, open items and where the work lives (files, branches, L2 names);'
  lines << '- no credentials or secrets, and no verbatim text a peer sent you; mark items that came from a peer.'
  lines << "Name the entry #{H.handoff_prefix(cfg[:tag], sid)}<YYYYMMDDHHMM> and put " \
           "`#{H::FRONTMATTER_KEY}: #{sid}` in its frontmatter; that is how the save is recognised " \
           "(knowledge #{H.guide_name})."
  unless near.empty?
    lines << "Not counted: #{near.first[:name]} has the name but its frontmatter does not carry " \
             "`#{H::FRONTMATTER_KEY}: #{sid}`."
  end
  lines.join("\n")
end

begin
  input = H.read_input
  sid = H.session_id(input)
  dir = H.data_dir
  cfg = H.config
  state = H.load_state(dir, sid)
  usage = H::UsageReader.read(input['transcript_path'], from: state['cycle_offset'])
  H.observe_usage!(state, usage)

  # A block sets first_request_at as well as urgent, so the request also
  # follows a block whatever the usage figure says.
  wanted = state['first_request_at'] || (usage && usage[:tokens] >= cfg[:request_point])
  # Once a fresh save was seen in this cycle, L2 is not searched again.
  if wanted && !state['saved_at']
    state['first_request_at'] ||= H.now
    manager = H.l2(dir)
    found, near = H.handoffs(manager, dir, cfg[:tag], sid)
    if H.fresh?(found.first, state)
      state['urgent'] = false
      state['saved_at'] = found.first[:written_at].iso8601
    else
      H.emit('UserPromptSubmit', request_text(cfg, sid, state, usage, near))
    end
  end
  H.save_state(dir, sid, state) or warn 'compaction_handoff: state could not be written'
rescue H::Unreadable => e
  warn "compaction_handoff: #{e.message}"
  exit 1
rescue StandardError, LoadError => e
  warn "compaction_handoff: #{e.class}: #{e.message[0, 200]}"
  exit 1
end
