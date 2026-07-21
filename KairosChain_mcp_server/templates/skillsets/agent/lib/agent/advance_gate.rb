# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'digest'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      # Interruption resilience Slice A (design v0.3.1 FROZEN).
      #
      # AdvanceGate is the single entry point through which every
      # state-advancing operation on an agent session must pass. It carries
      # three of the frozen invariants:
      #
      #   INV-A2 (serialized atomic advance): a non-blocking per-session file
      #     lock serializes advances; a concurrent caller is refused with
      #     'busy', never interleaved. Every gate file is committed via
      #     tmp-write + atomic rename, so a resumed driver observes a
      #     transition in full or not at all.
      #
      #   INV-A3 (anchored at-most-once): each advance is bound to the anchor
      #     of the state it was issued against. A re-issue whose anchor (and
      #     action) match an already-committed advance replays the recorded
      #     outcome without re-executing. A stale anchor is rejected with the
      #     current state. The side-effect intent bracket (open_intent /
      #     close_intent) makes a crash between executing an external effect
      #     and recording it detectable: the orphan intent surfaces as an
      #     unresolved point instead of being silently dropped or re-run.
      #
      #   INV-A4 (monotone derivable recovery): current_anchor and the
      #     committed advance log are derived from persisted state alone, so
      #     a fresh driver needs no memory of the interrupted one.
      #
      # The anchor is a monotonic sequence number combined with the session
      # state name and cycle ("<seq>:<state>:<cycle>"): the sequence carries
      # uniqueness, the state/cycle carry readability. Anchors are optional on
      # the wire for compatibility (§7): an anchorless call is treated as
      # issued against the current state, and every response carries the new
      # anchor so the caller can join the regime on its next call.
      class AdvanceGate
        LOCK_FILE   = 'advance.lock'
        STATE_FILE  = 'advance.json'
        LOG_FILE    = 'advance_log.jsonl'
        INTENT_FILE = 'act_intent.json'

        # Raised never; results are communicated as Hashes so the tool layer
        # can render them without exception plumbing.

        def initialize(session_dir)
          @dir = session_dir
          FileUtils.mkdir_p(@dir)
        end

        # ---- anchor -------------------------------------------------------

        def seq
          gate_state['seq']
        end

        def current_anchor(session)
          "#{gate_state['seq']}:#{session.state}:#{session.cycle_number}"
        end

        # ---- serialized advance (INV-A2) ---------------------------------

        # Runs the block under the per-session advance lock.
        # Returns the block's value, or { 'status' => 'busy' } if another
        # advance holds the lock. The lock spans anchor validation, phase
        # execution, and outcome commit, so no two advances interleave.
        def with_lock
          File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
            unless f.flock(File::LOCK_EX | File::LOCK_NB)
              return { 'status' => 'busy',
                       'error' => 'another advance is in progress on this session' }
            end
            begin
              # Any memoized gate state predates the lock; drop it so every
              # read inside the critical section reflects the persisted truth
              # (a gate instance that outlives a lock window must not serve a
              # stale seq).
              @gate_state = nil
              yield
            ensure
              f.flock(File::LOCK_UN)
            end
          end
        end

        # True while another advance holds the lock. Read-only probes (the
        # status surface) use this to distinguish "an advance is in flight"
        # from "an advance died mid-effect" — an open intent plus a held lock
        # is normal execution, not an unresolved point.
        # Probes with a shared lock so concurrent probes never serialize each
        # other and the window in which a probe could make a real advance's
        # LOCK_EX attempt fail spuriously is minimal (a spurious 'busy' is
        # safe: the caller retries).
        def busy?
          File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
            if f.flock(File::LOCK_SH | File::LOCK_NB)
              f.flock(File::LOCK_UN)
              false
            else
              true
            end
          end
        end

        # ---- anchored at-most-once (INV-A3) ------------------------------

        # Checks a provided anchor against the current state and the committed
        # log. Returns:
        #   { 'disposition' => 'proceed' }                     — execute normally
        #   { 'disposition' => 'replay', 'outcome' => {...} }  — committed already
        #   { 'disposition' => 'rejected', ... }               — stale/unknown anchor
        # A nil anchor proceeds (compatibility path, §7: the first advance
        # establishes the anchor from the state it reads).
        def check(anchor, action, session)
          return { 'disposition' => 'proceed' } if anchor.nil? || anchor.to_s.empty?
          return { 'disposition' => 'proceed' } if anchor == current_anchor(session)

          committed = find_committed(anchor)
          if committed
            if committed['action'] == action
              return { 'disposition' => 'replay', 'outcome' => committed['outcome'] }
            end
            return { 'disposition' => 'rejected',
                     'reason' => 'anchor was consumed by a different action',
                     'consumed_by' => committed['action'] }
          end

          { 'disposition' => 'rejected',
            'reason' => 'anchor does not match current session state' }
        end

        # Commits an advance: appends the outcome record and bumps the
        # sequence, both atomically. Called with the lock held, after the
        # session's own state has been persisted, so a crash before this call
        # leaves the old anchor valid (the advance never happened) and a crash
        # after leaves it replayable (the advance fully happened).
        def commit(anchor_at_issue, action, outcome)
          entry = {
            'seq'       => gate_state['seq'],
            'anchor'    => anchor_at_issue,
            'action'    => action,
            'outcome'   => outcome,
            'timestamp' => Time.now.utc.iso8601
          }
          repair_log_tail
          File.open(log_path, 'a') { |f| f.puts(JSON.generate(entry)) }
          atomic_write(state_path, JSON.pretty_generate('seq' => gate_state['seq'] + 1))
          @gate_state = nil
        end

        # ---- side-effect intent bracket (INV-A3, no silent drop) ---------

        # Persisted before an external side effect begins.
        def open_intent(anchor, decision_payload)
          digest = Digest::SHA256.hexdigest(JSON.generate(decision_payload || {}))[0, 16]
          atomic_write(intent_path, JSON.pretty_generate(
            'anchor' => anchor, 'decision_digest' => digest,
            'opened_at' => Time.now.utc.iso8601
          ))
        end

        # Removed only after the advance carrying the effect has committed.
        def close_intent
          File.delete(intent_path) if File.exist?(intent_path)
        end

        # An intent whose advance never committed. Its outcome is unknowable
        # from here: it is surfaced, never resolved silently (INV-A3), and its
        # adjudication is a gated human judgment (INV-A5).
        #
        # cleanup: deleting a stale intent is a write, so it happens only when
        # the caller holds the advance lock (cleanup: true from the gated step
        # path). Read-only probes (status/next_move) must not delete: an
        # unlocked delayed delete could race a fresh open_intent and remove a
        # LIVE intent.
        def unresolved_intent(cleanup: false)
          raw = begin
            File.read(intent_path)
          rescue Errno::ENOENT
            return nil
          end

          intent = JSON.parse(raw)
          # If the log contains a committed advance for the intent's anchor,
          # the effect was recorded — the intent file is a stale leftover.
          # Exception: a stop committed at the same anchor with the intent
          # still unresolved did NOT record the effect (it recorded the
          # ambiguity); such a commit must not make the audit trace look
          # stale, or cleanup would silently erase it.
          committed = find_committed(intent['anchor'])
          if committed && !committed.dig('outcome', 'unresolved_intent_at_stop')
            File.delete(intent_path) if cleanup && File.exist?(intent_path)
            return nil
          end
          intent
        rescue JSON::ParserError
          # A torn intent file is itself an unresolved point; report it.
          { 'anchor' => nil, 'corrupt' => true }
        end

        # ---- derivable next move (INV-A4) --------------------------------

        # From persisted state alone: the single next move a fresh driver
        # should issue. An unresolved side-effect point takes precedence over
        # every other pending advance (v0.3.1 uniqueness clause).
        def next_move(session)
          intent = unresolved_intent
          # A terminated session has no next move; a kept intent is an audit
          # record of the ambiguity, not a pending adjudication (the step
          # tool refuses post-termination adjudication, so recommending it
          # would loop forever).
          if session.state == 'terminated'
            move = { 'tool' => nil,
                     'reason' => 'session is terminated; no further moves' }
            move['audit_intent'] = intent if intent
            return move
          end

          if intent
            return {
              'tool' => 'agent_step',
              'args' => { 'session_id' => session.session_id, 'action' => 'adjudicate',
                          'anchor' => current_anchor(session) },
              'reason' => 'unresolved side-effect: an act was started but its outcome ' \
                          'was never recorded; adjudicate with resolution ' \
                          '"reattempt" or "already_done"',
              'unresolved_intent' => intent
            }
          end

          action, reason = case effective_state(session)
                           when 'observed', 'autonomous_cycling'
                             ['approve', 'run Orient+Decide']
                           when 'proposed'
                             ['approve', 'run Act+Reflect (or "revise"/"skip")']
                           when 'checkpoint'
                             ['approve', 'start next cycle']
                           when 'paused_risk', 'paused_error'
                             ['approve', 'resume from pause (or "skip"/"stop")']
                           else
                             [nil, "unrecognized state #{session.state}"]
                           end
          return { 'tool' => nil, 'reason' => reason } unless action

          {
            'tool' => 'agent_step',
            'args' => { 'session_id' => session.session_id, 'action' => action,
                        'anchor' => current_anchor(session) },
            'reason' => reason
          }
        end

        # A transient phase state persisted by an interrupted call maps to the
        # stable state it is recoverable from. Phases before ACT are
        # side-effect free (their re-run is safe); the ACT window is governed
        # by the intent bracket, not by this mapping.
        def effective_state(session)
          case session.state
          when 'orienting', 'deciding' then 'observed'
          when 'acting', 'reflecting'  then 'proposed'
          else session.state
          end
        end

        private

        def find_committed(anchor)
          return nil unless File.exist?(log_path)

          found = nil
          File.foreach(log_path) do |line|
            entry = JSON.parse(line.strip) rescue nil
            found = entry if entry && entry['anchor'] == anchor
          end
          found
        end

        # The effective sequence fails closed: it is reconciled against the
        # committed log's highest recorded seq, so a lost or corrupt
        # advance.json can never regress the sequence and let an
        # already-consumed anchor match the current one again (at-most-once
        # would silently break on exactly the anchors whose state component
        # did not change, e.g. revise at proposed).
        def gate_state
          @gate_state ||= begin
            file_seq = begin
              File.exist?(state_path) ? (JSON.parse(File.read(state_path))['seq'] || 0) : 0
            rescue JSON::ParserError
              0
            end
            { 'seq' => [file_seq, log_max_seq + 1].max }
          end
        end

        # Highest committed seq in the log, or -1 when no advance committed.
        def log_max_seq
          return -1 unless File.exist?(log_path)

          max = -1
          File.foreach(log_path) do |line|
            entry = JSON.parse(line.strip) rescue nil
            s = entry && entry['seq']
            max = s if s.is_a?(Integer) && s > max
          end
          max
        end

        # A crash mid-append can leave a torn tail line; without repair the
        # next append would concatenate onto it and corrupt BOTH records.
        # Terminating the torn tail confines the damage to the already-lost
        # entry.
        def repair_log_tail
          return unless File.exist?(log_path) && File.size(log_path).positive?

          last = File.open(log_path, 'rb') do |f|
            f.seek(-1, IO::SEEK_END)
            f.read(1)
          end
          File.open(log_path, 'a') { |f| f.write("\n") } unless last == "\n"
        end

        # INV-A2: no partial-write window. Content lands under a temp name and
        # is renamed into place; rename is atomic on POSIX filesystems. The
        # temp name carries pid + thread id so two writers in one process
        # cannot collide on the temp file.
        def atomic_write(path, content)
          tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
          File.write(tmp, content)
          File.rename(tmp, path)
        end

        def lock_path   = File.join(@dir, LOCK_FILE)
        def state_path  = File.join(@dir, STATE_FILE)
        def log_path    = File.join(@dir, LOG_FILE)
        def intent_path = File.join(@dir, INTENT_FILE)
      end
    end
  end
end
