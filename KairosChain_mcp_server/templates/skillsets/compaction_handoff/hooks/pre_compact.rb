# frozen_string_literal: true

# PreCompact hook (design INV-1, INV-2, INV-3). Decides first, records a block
# durably before giving it, writes the fallback record stating the answer,
# then answers. Only trigger exactly "auto" can be blocked, at most once per
# cycle, and only when the cycle has no fresh save. A subagent's compaction is
# left alone. Any failure to read leads to no block (INV-8): exit 0 to let the
# compaction proceed, the cause on stderr.

require_relative 'common'
require_relative 'usage_reader'

H = CompactionHandoffHook

def fallback_content(name, sid, input, usage, answer, handoff)
  size = File.size?(input['transcript_path'].to_s)
  fm = {
    'name' => name,
    'description' => "compaction_handoff fallback record for session #{sid[0, 8]} (no conversation text)",
    'tags' => %w[compaction_handoff fallback],
    H::FRONTMATTER_KEY => sid,
    'kind' => 'fallback',
    'trigger' => input['trigger'].to_s[0, 16],
    'written_at' => H.now,
    'usage_tokens' => usage && usage[:tokens],
    'usage_source' => usage ? usage[:source] : 'unavailable',
    'answer' => answer,
    'transcript_bytes' => size,
    'latest_handoff' => handoff && handoff[:name],
    'latest_handoff_written_at' => handoff && handoff[:written_at].iso8601
  }
  <<~MD
    #{YAML.dump(fm).chomp}
    ---

    # Fallback record (compaction_handoff)

    Written by the PreCompact hook without a model. It holds no conversation text: only the figures in the
    frontmatter. The agent's own handoff, if one was written, is named in `latest_handoff`.
  MD
end

answer = 'proceed'
begin
  input = H.read_input
  sid = H.session_id(input)
  exit 0 if H.subagent?(input)

  raise H::Unreadable, 'transcript unreadable' unless File.readable?(input['transcript_path'].to_s)

  dir = H.data_dir
  cfg = H.config
  state = H.load_state(dir, sid)
  usage = H::UsageReader.read(input['transcript_path'], from: state['cycle_offset'])
  H.observe_usage!(state, usage)
  manager = H.l2(dir)
  found, = H.handoffs(manager, dir, cfg[:tag], sid)
  latest = found.first

  if input['trigger'] == 'auto' && !state['blocked'] && !H.fresh?(latest, state)
    state['blocked'] = true
    state['urgent'] = true
    state['first_request_at'] ||= H.now
    answer = 'block' if H.save_state(dir, sid, state)
  end

  t = Time.now.utc
  name = "#{H.fallback_prefix(cfg[:tag], sid)}#{t.strftime('%Y%m%d%H%M%S')}_#{format('%06d', t.usec)}_#{Process.pid}"
  session = "compaction_handoff_#{Time.now.utc.strftime('%Y%m%d')}"
  result = manager.save_context(session, name, fallback_content(name, sid, input, usage, answer, latest))
  warn "compaction_handoff: fallback record not written (#{result[:error]})" unless result[:success]
rescue H::Unreadable => e
  warn "compaction_handoff: #{e.message}; not blocking"
rescue StandardError, LoadError => e
  warn "compaction_handoff: #{e.class}: #{e.message[0, 200]}#{answer == 'block' ? '' : '; not blocking'}"
end

if answer == 'block'
  warn 'compaction_handoff: auto-compaction held off once so this session can write its handoff to L2; ' \
       'the next attempt will proceed.'
  exit 2
end
exit 0
