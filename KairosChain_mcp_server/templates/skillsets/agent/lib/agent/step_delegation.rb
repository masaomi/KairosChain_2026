# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'rbconfig'
require 'shellwords'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      # Interruption resilience Slice A-2 (design v0.3.1 FROZEN, INV-A1).
      #
      # StepDelegation carries the resumable handle for a step whose execution
      # continues under server-side ownership after the initiating call
      # returns. The delegated worker is a thin bootstrap that re-enters the
      # SAME gated agent_step path (AdvanceGate, Slice A-1), so every
      # correctness invariant — serialization, anchored at-most-once, intent
      # bracket — is inherited rather than re-implemented. This is the
      # delegate → wait → collect shape the review SkillSet already runs in
      # production, transplanted.
      #
      # Concurrency (impl review R1): delegation-start sits OUTSIDE the
      # AdvanceGate advance.lock, so it takes its OWN per-session lock
      # (delegation.lock) to serialize open/status-mutating operations. Two
      # locks never nest in the same thread — the tool holds delegation.lock
      # only to open the handle and returns; the detached worker separately
      # takes advance.lock inside its gated call. The recorded issue-anchor is
      # injected into the worker's call args so a re-entry is ALWAYS anchored:
      # even if two workers somehow coexist, the second replays the first's
      # committed outcome instead of double-executing.
      #
      # Files (in the session dir):
      #   delegation.lock       — flock serializing delegation-start
      #   delegation.json       — the handle: token, worker call args (anchor
      #                           injected), issue_anchor, spawn metadata
      #   delegation.heartbeat  — touched by the live worker every 2s
      #   delegation_result.json— the worker's final response, tagged with the
      #                           issue_anchor it belongs to
      #   worker_exit.json      — the worker's exit record (why it left), one
      #                           file overwritten per exit; readers match on
      #                           step_token, a fresh open_handle removes it
      class StepDelegation
        LOCK_FILE      = 'delegation.lock'
        PENDING_FILE   = 'delegation.json'
        HEARTBEAT_FILE = 'delegation.heartbeat'
        RESULT_FILE    = 'delegation_result.json'
        LOG_FILE       = 'delegation_worker.log'
        WORKER_EXIT_FILE = 'worker_exit.json'

        HEARTBEAT_INTERVAL_SECONDS        = 2
        HEARTBEAT_STALE_THRESHOLD_SECONDS = 15
        STARTUP_GRACE_SECONDS             = 30
        # Two-bound watchdog for the delegated worker (field defect D4,
        # 2026-08-26). The original single 1500 s wall clock assumed only a
        # hung call could reach it; a healthy cycle with several LLM
        # subprocess calls routinely runs past 25 minutes, so the clock killed
        # sound workers — silently, because its exit wrote nothing. The stall
        # bound frees a hung call's flock once the session dir has gone quiet
        # (heartbeats and locks excluded: the heartbeat thread outlives a hung
        # main thread, so it must not count as activity); the hard cap remains
        # the absolute ceiling. Both are env-overridable per run and both
        # record their firing in WORKER_EXIT_FILE before exiting.
        WORKER_STALL_SECONDS_DEFAULT      = 2700
        WORKER_HARD_CAP_SECONDS_DEFAULT   = 10800
        # How often the watchdog re-evaluates the two bounds. Env-overridable
        # (floor 1 s) so a real-process test can drive both firings in seconds
        # instead of minutes; the default is unchanged from the D4 fix.
        WORKER_WATCHDOG_TICK_SECONDS_DEFAULT = 30

        WORKER_SCRIPT = File.expand_path('../../bin/agent_step_worker.rb', __dir__)

        def initialize(session_dir)
          @dir = session_dir
          FileUtils.mkdir_p(@dir)
        end

        def pending
          JSON.parse(File.read(pending_path))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        def result
          JSON.parse(File.read(result_path))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        # 'ready' | 'still_pending' | 'crashed' | 'none'
        #
        # Teardown is owned by the COLLECTOR, not the worker: the worker only
        # ever writes a result and leaves the pending handle in place, so a
        # result and its pending handle always coexist until agent_wait
        # collects both atomically. Therefore a result is 'ready' only when it
        # matches the current pending handle (same issue_anchor + action_key);
        # once the collector has cleared the handle, status is 'none'. This
        # removes the stale-result-with-nil-pending window.
        def status
          cur = pending
          return 'none' unless cur

          res = result
          if res && res['issue_anchor'] == cur['issue_anchor'] &&
             res['action_key'] == cur['action_key'] &&
             res['step_token'] == cur['step_token']
            return 'ready'
          end

          # Liveness is judged by the CURRENT pending handle's OWN heartbeat
          # file (per step_token), never a shared one: an orphaned older worker
          # that is still alive touches its own now-ignored heartbeat, so it can
          # no longer mask a newer worker's crash.
          hb = heartbeat_path(cur['step_token'])
          if File.exist?(hb)
            age = Time.now - File.mtime(hb)
            return age <= HEARTBEAT_STALE_THRESHOLD_SECONDS ? 'still_pending' : 'crashed'
          end

          spawned = begin
            Time.parse(cur['spawned_at'])
          rescue StandardError
            nil
          end
          return 'crashed' unless spawned

          (Time.now - spawned) <= STARTUP_GRACE_SECONDS ? 'still_pending' : 'crashed'
        end

        # Opens (or re-joins) the handle for one delegated step, serialized
        # under delegation.lock. A delegation is identified by BOTH its
        # issue_anchor (the AdvanceGate current_anchor at delegation time) AND
        # its action_key (the replay identity: "approve" / "adjudicate:<res>" /
        # "revise:<digest>"), so a DIFFERENT judgment at the same anchor is a
        # DIFFERENT delegation, never a reuse of the prior worker. The
        # issue_anchor is injected into the worker's call args so the re-entry
        # is anchored.
        #
        # Returns one of:
        #   [:ready, token]    — a finished, uncollected result for this exact
        #                        (anchor, action_key) already exists
        #   [:existing, token] — a live worker for this (anchor, action_key) is
        #                        already running; no second spawn
        #   [:opened, token]   — a fresh handle was written; caller spawns
        def open_handle(recorded_args, issue_anchor, action_key)
          with_lock do
            # Pending-centric: only the CURRENT pending handle for this exact
            # (anchor, action_key) can be :ready or :existing. A result whose
            # token does not match the current pending is a superseded worker's
            # leftover, never treated as this delegation's ready outcome.
            cur = pending
            if cur && cur['issue_anchor'] == issue_anchor && cur['action_key'] == action_key
              res = result
              if res && res['step_token'] == cur['step_token'] &&
                 res['issue_anchor'] == issue_anchor && res['action_key'] == action_key
                return [:ready, cur['step_token']]
              end
              return [:existing, cur['step_token']] if live_pending?(cur)
              # cur matches this judgment but is neither ready nor live
              # (crashed) — fall through to open a fresh handle below.
            end

            # Fresh delegation: clear any stale result, ALL prior per-token
            # heartbeats (a superseded worker's heartbeat must not count toward
            # this handle's liveness) and the previous worker's exit record
            # (it belongs to a token that is stale by construction once a new
            # token is minted; crash_detail already filters by token, so this
            # is housekeeping — the record would otherwise linger until the
            # session dir is removed), then write the new handle. The
            # issue_anchor is injected into the worker args.
            FileUtils.rm_f(result_path)
            FileUtils.rm_f(worker_exit_path)
            clear_all_heartbeats
            token = SecureRandom.uuid
            worker_args = recorded_args.merge('anchor' => issue_anchor)
            atomic_write(pending_path, JSON.pretty_generate(
              'step_token'   => token,
              'arguments'    => worker_args,
              'issue_anchor' => issue_anchor,
              'action_key'   => action_key,
              'spawned_at'   => Time.now.utc.iso8601
            ))
            [:opened, token]
          end
        end

        # ---- worker side ----

        # The worker touches its OWN per-token heartbeat (it knows its token
        # from the handle it read at startup), so liveness is scoped to that
        # specific worker.
        def touch_heartbeat(token)
          return unless token
          FileUtils.touch(heartbeat_path(token))
        end

        # Tags the result with the issue_anchor / action_key / step_token of the
        # handle it completes, so status/open_handle/collect can tell a fresh
        # result from a stale one. The worker calls this and NOTHING else on
        # success — teardown is the collector's responsibility (see collect).
        #
        # identity: the worker passes the handle identity it read at STARTUP so
        # a finishing worker tags its result with its OWN delegation, not
        # whatever a fresh open_handle may have written into pending in the
        # meantime — otherwise a completing old worker could mislabel its
        # outcome as the new delegation's. When identity is omitted (early
        # setsid/bootstrap failures with no handle context), it falls back to
        # the current pending.
        def write_result(response_hash, identity: nil)
          id = identity || pending || {}
          payload = { 'issue_anchor' => id['issue_anchor'],
                      'action_key'   => id['action_key'],
                      'step_token'   => id['step_token'],
                      'outcome'      => response_hash }
          atomic_write(result_path, JSON.pretty_generate(payload))
        end

        # ---- worker exit record (field defect D4) ----

        # One line, written by the worker at every exit it can see coming
        # (self-timeout, supersession, trapped signal, setsid/bootstrap
        # failure, uncaught error, normal completion). Deliberately NOT the
        # result file: the collector's crash path must stay the crash path, so
        # a committed advance is still recovered from the gate log and never
        # masked by an error result. Overwrites are fine — readers match on
        # step_token, so a stale record for an older worker is ignored.
        def write_worker_exit(identity, exit_class, detail = {})
          payload = {
            'timestamp'    => Time.now.utc.iso8601,
            'pid'          => Process.pid,
            'exit_class'   => exit_class.to_s,
            'step_token'   => identity && identity['step_token'],
            'issue_anchor' => identity && identity['issue_anchor']
          }.merge(detail)
          atomic_write(worker_exit_path, JSON.generate(payload))
          payload
        rescue StandardError
          nil
        end

        def worker_exit
          JSON.parse(File.read(worker_exit_path))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        # The exit record for THIS token, or a positive "no record" marker —
        # so a 'crashed' report can say WHY (e.g. self_timeout_stalled after
        # N s of silence) or say explicitly that the process vanished without
        # writing anything (SIGKILL and kin, or a pre-3.78 worker).
        def crash_detail(token)
          rec = worker_exit
          if rec && rec['step_token'] == token
            rec
          else
            { 'exit_class' => 'no_record',
              'note' => 'process gone without an exit record (killed, or a pre-3.78 worker)' }
          end
        end

        # Most recent write anywhere in the session dir EXCLUDING liveness and
        # locking artifacts: heartbeats tick every 2 s even when the main
        # thread hangs, so counting them would blind the stall bound. The
        # worker's own exit record (and its atomic-write temp file) is excluded
        # too: the D6 interim record is written by a TERM to a possibly HUNG
        # worker, and counting it pushed the stall bound out by a whole stall
        # window for exactly the worker the operator had asked to stop.
        def last_activity_time
          newest = nil
          Dir.glob(File.join(@dir, '*')).each do |f|
            base = File.basename(f)
            next if base.start_with?(HEARTBEAT_FILE)
            next if base == LOCK_FILE || base.end_with?('.lock')
            next if base == WORKER_EXIT_FILE || base.start_with?("#{WORKER_EXIT_FILE}.tmp.")
            t = begin
              File.mtime(f)
            rescue StandardError
              next
            end
            newest = t if newest.nil? || t > newest
          end
          newest || Time.now
        end

        # Collect-once, atomically and self-contained: under the lock, consume
        # the result ONLY if it belongs to the CURRENT pending handle (same
        # issue_anchor + action_key + step_token), clearing both the result and
        # the handle together. Returns the result, or nil when there is no
        # result, no pending, or the result belongs to a different (superseded)
        # worker — in which case nothing is touched. Deciding readiness against
        # the live pending under the lock (rather than trusting the result's
        # own tags) is what makes a superseded worker's stale result
        # uncollectable and closes the status/collect race.
        def collect
          with_lock do
            cur = pending
            res = result
            return nil unless cur && res &&
                              res['issue_anchor'] == cur['issue_anchor'] &&
                              res['action_key'] == cur['action_key'] &&
                              res['step_token'] == cur['step_token']

            FileUtils.rm_f(result_path)
            FileUtils.rm_f(pending_path)
            clear_all_heartbeats
            res
          end
        end

        # Clear a pending handle only if it still belongs to expected_token
        # (identity-checked, under the lock) — used by spawn rollback and
        # committed-crash recovery so a concurrent fresh open is never clobbered.
        # Returns true when the caller still owns the handle (pending was nil or
        # matched expected_token) and false when a DIFFERENT (superseding) token
        # now holds it — so a caller that recovered against a stale generation
        # can detect the supersession and decline to act on it.
        def clear_pending_if(expected_token)
          with_lock do
            cur = pending
            if cur.nil? || cur['step_token'] == expected_token
              FileUtils.rm_f(pending_path)
              clear_all_heartbeats
              true
            else
              false
            end
          end
        end

        # ---- spawn ----

        # Spawns the detached worker (same discipline as the review SkillSet's
        # WorkerSpawner: no pgroup here — the worker calls setsid itself; MCP
        # FDs closed; the server's effective data_dir is propagated so the
        # worker resolves the SAME .kairos even under `--data-dir`).
        # On spawn failure the handle is rolled back so it does not linger as
        # a phantom still_pending. KAIROS_AGENT_WORKER_CMD overrides argv for
        # tests. Returns the pid, or raises after rolling back.
        def spawn_worker(session_id)
          log = File.join(@dir, LOG_FILE)
          File.write(log, '')

          env = {
            'KAIROS_PROJECT_ROOT' => Dir.pwd,
            'KAIROS_SERVER_LIB'   => server_lib_dir,
            'KAIROS_DATA_DIR'     => resolved_data_dir,
            'BUNDLE_GEMFILE'      => ENV['BUNDLE_GEMFILE']
          }.compact

          argv = if ENV['KAIROS_AGENT_WORKER_CMD']
                   Shellwords.split(ENV['KAIROS_AGENT_WORKER_CMD']) + [session_id, @dir]
                 else
                   [RbConfig.ruby, WORKER_SCRIPT, session_id, @dir]
                 end

          pid = Process.spawn(env, *argv,
                              chdir: Dir.pwd,
                              in: :close, out: log, err: log,
                              close_others: true)
          Process.detach(pid)
          pid
        end

        def self.worker_stall_seconds
          (ENV['KAIROS_WORKER_STALL_SECONDS'] || WORKER_STALL_SECONDS_DEFAULT).to_i
        end

        def self.worker_hard_cap_seconds
          (ENV['KAIROS_WORKER_TIMEOUT_SECONDS'] || WORKER_HARD_CAP_SECONDS_DEFAULT).to_i
        end

        def self.worker_watchdog_tick_seconds
          [(ENV['KAIROS_WORKER_WATCHDOG_TICK_SECONDS'] || WORKER_WATCHDOG_TICK_SECONDS_DEFAULT).to_i, 1].max
        end

        private

        # A pending handle whose worker is not (yet) declared crashed.
        def live_pending?(_cur)
          %w[still_pending].include?(status)
        end

        def with_lock
          File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
            f.flock(File::LOCK_EX)
            begin
              yield
            ensure
              f.flock(File::LOCK_UN)
            end
          end
        end

        # The server's effective data dir, so the worker resolves the SAME
        # .kairos even when the server was launched with --data-dir (which sets
        # KairosMcp.data_dir programmatically without exporting an env var).
        def resolved_data_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir)
            KairosMcp.data_dir
          else
            ENV['KAIROS_DATA_DIR']
          end
        rescue StandardError
          ENV['KAIROS_DATA_DIR']
        end

        # The lib dir the running server loaded kairos_mcp from, so the worker
        # bootstraps against the same code regardless of install shape.
        def server_lib_dir
          feature = $LOADED_FEATURES.grep(%r{/kairos_mcp/tool_registry\.rb\z}).first ||
                    $LOADED_FEATURES.grep(%r{/kairos_mcp/tools/base_tool\.rb\z}).first
          return File.expand_path('../..', feature) if feature

          # Repo/template fallback: templates/skillsets/agent/lib/agent -> up to
          # KairosChain_mcp_server/lib. Unreached in a live server (the grep
          # succeeds); harmless for the gem case where the worker's own
          # require resolves kairos_mcp from the gem load path.
          File.expand_path('../../../../../lib', __dir__)
        end

        def atomic_write(path, content)
          tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
          File.write(tmp, content)
          File.rename(tmp, path)
        end

        def clear_all_heartbeats
          Dir.glob(File.join(@dir, "#{HEARTBEAT_FILE}.*")).each { |f| FileUtils.rm_f(f) }
          FileUtils.rm_f(File.join(@dir, HEARTBEAT_FILE)) # legacy unscoped, if any
        end

        def lock_path      = File.join(@dir, LOCK_FILE)
        def pending_path   = File.join(@dir, PENDING_FILE)
        def heartbeat_path(token) = File.join(@dir, "#{HEARTBEAT_FILE}.#{token}")
        def result_path    = File.join(@dir, RESULT_FILE)
        def worker_exit_path = File.join(@dir, WORKER_EXIT_FILE)
      end
    end
  end
end
