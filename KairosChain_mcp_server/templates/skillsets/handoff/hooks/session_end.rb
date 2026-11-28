# frozen_string_literal: true

# SessionEnd hook: appends one block to the instance's log file. Never blocks
# (SessionEnd cannot). Input it cannot read is taken as another host's call
# (the projector can deliver this hook to hosts other than Claude Code) and
# ends quietly, exit 0. A fault of this instance (config, log file, state) is
# exit 1 with the cause in one line on stderr.
require_relative 'common'

begin
  begin
    input = HandoffHook.read_input
    sid = HandoffHook.session_id(input)
  rescue HandoffHook::Unreadable
    exit 0
  end
  exit 0 if HandoffHook.subagent?(input)

  cfg = HandoffHook.config
  log = HandoffHook.log_path(cfg)
  exit 0 unless log
  reason = input['reason']
  exit 0 unless reason.is_a?(String) && cfg.end_reasons.include?(reason)

  rows = HandoffHook.read_rows(input['transcript_path'])
  turn = HandoffHook.last_turn(rows)
  # A session in which the model answered nothing leaves nothing to come back to.
  exit 0 unless turn[:reply]

  HandoffHook.with_state(sid) do |state|
    # The same final reply was already logged: the hook ran twice for one end,
    # or the session was resumed and left again without a new answer.
    next if state['ends'].any? { |e| e['mark'] == turn[:mark] }

    block = HandoffHook.session_end_block(sid: sid, title: HandoffHook.title(rows), reason: reason, turn: turn,
                                          handoffs: state['handoffs'], cfg: cfg)
    # The block first, the mark second: a run cut between the two repeats the
    # block at the next end; the other order would lose it.
    HandoffHook.append(log, block)
    state['ends'] = (state['ends'] + [{ 'mark' => turn[:mark], 'at' => Time.now.iso8601 }]).last(HandoffHook::KEPT_ENDS)
  end
rescue HandoffHook::Unreadable, SystemCallError => e
  warn "handoff: #{e.message}"
  exit 1
rescue StandardError => e
  warn "handoff: #{e.class}: #{HandoffHook.utf8(e.message).lines.first.to_s.strip}"
  exit 1
end
