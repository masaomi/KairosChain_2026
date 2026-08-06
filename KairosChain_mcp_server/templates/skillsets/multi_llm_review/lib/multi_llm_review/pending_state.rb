# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # File-backed pending state for two-phase delegation.
      #
      # Single-user, local-only. No auth — see design v0.3 §non-goals.
      # Tokens are UUID v4. State files live at .kairos/multi_llm_review/pending/.
      #
      # Two coexisting layouts:
      #   - v0.2.x legacy: .kairos/multi_llm_review/pending/<token>.json  (single file)
      #   - v0.3.0+ directory: .kairos/multi_llm_review/pending/<token>/*.json  (per-file)
      # load_state() tries dir first, falls back to legacy single-file (parallel=false).
      module PendingState
        TOKEN_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

        STALE_NO_DEADLINE_SECONDS = 86_400
        HEARTBEAT_STALE_DEFAULT   = 15     # §4.7 — worker.heartbeat freshness
        ORPHAN_TMP_STALE_DEFAULT  = 3600

        # Intra-process serialization of state.json RMW. PR3 will add the
        # worker-side callers; PR1 ships the mutex so update_state is safe
        # from day one.
        STATE_MUTEX = Mutex.new

        module_function

        def root_dir
          File.join(Dir.pwd, '.kairos', 'multi_llm_review', 'pending')
        end

        def generate_token
          SecureRandom.uuid
        end

        def valid_token?(token)
          token.is_a?(String) && TOKEN_RE.match?(token)
        end

        # ──────────────────────────────────────────────────────────────
        # v0.3.0 directory-based paths
        # ──────────────────────────────────────────────────────────────

        def token_dir(token)
          raise ArgumentError, "invalid token format: #{token.inspect}" unless valid_token?(token)
          File.join(root_dir, token)
        end

        def state_path(token);              File.join(token_dir(token), 'state.json'); end
        def collected_path(token);          File.join(token_dir(token), 'collected.json'); end
        # v0.7 INV-R4 — the run's existence mark, written at dispatch time on
        # every path (async, sync, single-phase), before any work that could
        # fail. The completed record (collected.json / completed.json)
        # supersedes it; for a run that never completes, the marker plus
        # whatever causes are known IS the minimal trace, and cleanup reduces
        # the directory to that trace instead of removing it.
        def marker_path(token);             File.join(token_dir(token), 'marker.json'); end
        # Single-phase runs have no collect; their final record lands here.
        def completed_path(token);          File.join(token_dir(token), 'completed.json'); end
        # INV-R1/R4 — refused persona submissions, appended by collect while
        # it holds collect.lock. Facts and causes only, never the refused body.
        def refusals_path(token);           File.join(token_dir(token), 'refusals.json'); end
        # What cleanup writes when it reduces an expired, never-completed run
        # to its minimal trace.
        def reaped_path(token);             File.join(token_dir(token), 'reaped.json'); end
        def gc_eligible_path(token);        File.join(token_dir(token), 'gc.eligible'); end
        def request_path(token);            File.join(token_dir(token), 'request.json'); end
        def subprocess_results_path(token); File.join(token_dir(token), 'subprocess_results.json'); end
        # Per-seat results written as each seat completes, so a worker that
        # dies with one seat stuck does not take the finished seats' replies
        # with it (R3 2026-08-06 lost three completed external seats to one
        # stale heartbeat). Superseded by subprocess_results.json on a clean
        # exit; read by collect's crash/timeout recovery path only.
        def partial_results_path(token);    File.join(token_dir(token), 'partial_results.json'); end
        def worker_pid_path(token);         File.join(token_dir(token), 'worker.pid'); end
        def worker_heartbeat_path(token);   File.join(token_dir(token), 'worker.heartbeat'); end
        def worker_tick_path(token);        File.join(token_dir(token), 'worker.tick'); end
        def worker_log_path(token);         File.join(token_dir(token), 'worker.log'); end
        def collect_lock_path(token);       File.join(token_dir(token), 'collect.lock'); end

        # Create the token directory. Uses Dir.mkdir (not mkdir_p) so a UUID v4
        # collision raises Errno::EEXIST; caller regenerates token. root_dir
        # itself is mkdir_p'd idempotently.
        def create_token_dir!(token)
          FileUtils.mkdir_p(root_dir)
          Dir.mkdir(token_dir(token))
        end

        # ──────────────────────────────────────────────────────────────
        # Atomic writers (tmp + rename); each file has a single writer per §6.3
        # ──────────────────────────────────────────────────────────────

        # write_state is STATE_MUTEX-guarded so concurrent in-process writers
        # (e.g., a stray caller outside update_state) cannot race an update_state
        # RMW. Internal _write_state_unlocked is called by update_state which
        # ALREADY holds the mutex (Ruby Mutex is not reentrant).
        def write_state(token, data)
          STATE_MUTEX.synchronize { _write_state_unlocked(token, data) }
        end

        def _write_state_unlocked(token, data)
          atomic_write_json(state_path(token), data)
        end

        def write_collected(token, data);          atomic_write_json(collected_path(token), data); end
        def write_request(token, data);            atomic_write_json(request_path(token), data); end
        def write_subprocess_results(token, data); atomic_write_json(subprocess_results_path(token), data); end
        def write_partial_results(token, data);    atomic_write_json(partial_results_path(token), data); end
        def write_worker_pid(token, data);         atomic_write_json(worker_pid_path(token), data); end
        def write_marker(token, data);             atomic_write_json(marker_path(token), data); end
        def write_completed(token, data);          atomic_write_json(completed_path(token), data); end

        # Append one refusal entry. Read-modify-write with no lock of its own:
        # the only caller is collect, which holds collect.lock (flock) for
        # call_locked whenever the token DIRECTORY exists. For a v0.2.x
        # legacy single-file token no directory exists on the first refusal,
        # so that append runs unlocked (measured 2026-08-02) — the write
        # itself is atomic (tmp+rename), so the exposure is a lost update
        # between two simultaneous refusals on a legacy token, not
        # corruption. Declared residual. A sidecar that fails to parse is
        # replaced rather than obeyed — losing a prior refusal entry to
        # corruption is recorded as its own entry.
        def append_refusal(token, entry)
          existing = load_json_transient(refusals_path(token))
          entries = existing.is_a?(Array) ? existing : []
          if existing && !existing.is_a?(Array)
            entries << { 'refused_at' => Time.now.iso8601,
                         'stage' => 'sidecar',
                         'reason' => 'refusals.json was not a list; prior entries lost' }
          end
          entries << entry
          atomic_write_json(refusals_path(token), entries)
        end

        def load_refusals(token)
          data = load_json_transient(refusals_path(token))
          data.is_a?(Array) ? data : []
        end

        # ──────────────────────────────────────────────────────────────
        # Loaders (transient error handling: ENOENT/ParserError → nil)
        # ──────────────────────────────────────────────────────────────

        def load_state(token)
          # Validate FIRST so an invalid token can never reach file ops and
          # can never escape root_dir via path-traversal.
          return nil unless valid_token?(token)

          # Try v0.3.0 directory layout first. load_json_transient handles
          # ENOENT / JSON::ParserError (nil); EACCES and other Errno bubble
          # up per R1 F-EACC. token_dir cannot raise here — valid_token?
          # already passed.
          data = load_json_transient(state_path(token))
          return data if data

          # Legacy v0.2.x single-file fallback. Bare rescue is narrow: only
          # the same transient set. EACCES still bubbles.
          legacy_path = File.join(root_dir, "#{token}.json")
          legacy = load_json_transient(legacy_path)
          if legacy.is_a?(Hash)
            # Missing 'parallel' key → false (synchronous legacy semantics,
            # v0.3 §5.5 R1-K). In-memory mutation only; never rewrites file.
            legacy['parallel'] = false unless legacy.key?('parallel')
            # Tag the in-memory hash so update_state can refuse to fork the
            # state by writing a v0.3 dir file alongside the v0.2 legacy
            # single-file (R3-impl P1 from cursor).
            legacy['_legacy_source'] = true
            return legacy
          end
          nil
        end

        def load_collected(token);          load_json_transient(collected_path(token)); end
        def load_request(token);            load_json_transient(request_path(token)); end
        def load_subprocess_results(token); load_json_transient(subprocess_results_path(token)); end
        def load_partial_results(token);    load_json_transient(partial_results_path(token)); end
        def load_worker_pid(token);         load_json_transient(worker_pid_path(token)); end

        # Mutate state.json under a read-modify-write block, serialized
        # intra-process by STATE_MUTEX. Cross-process single-writer invariant
        # (§3.3): state.json has exactly one OS-process writer (the worker),
        # so intra-process serialization is sufficient.
        def update_state(token)
          STATE_MUTEX.synchronize do
            s = load_state(token)
            return nil unless s
            # Refuse to update a v0.2.x legacy single-file state by writing
            # a v0.3 dir state — that would silently fork the record. v0.2.x
            # legacy states are read-only in v0.3 (collect reads, never
            # updates). R3-impl P1 from cursor.
            if s['_legacy_source']
              warn "[PendingState#update_state] refusing update on legacy single-file state for #{token}"
              return nil
            end
            new = yield(s)
            _write_state_unlocked(token, new) if new   # mutex already held
            new
          end
        end

        TERMINAL_STATUSES = %w[done crashed self_timed_out].freeze

        # Idempotent terminal-status transition (v0.3.2 C1a / C1b / P1-CONV).
        # Within the worker process, multiple writers (main loop, watchdog
        # thread, signal-trap polling, rescue path) may call this. The guard
        # + STATE_MUTEX guarantee the FIRST terminal write wins — all
        # subsequent calls short-circuit as no-ops.
        #
        # @param token [String]
        # @param new_status [String] one of TERMINAL_STATUSES
        # @param reason [String, nil] crash_reason (ignored for 'done')
        # @return [Hash, nil] the new state, or nil if no transition happened
        def transition_to_terminal!(token, new_status, reason: nil)
          raise ArgumentError, "unknown terminal status: #{new_status}" \
            unless TERMINAL_STATUSES.include?(new_status)

          update_state(token) do |s|
            next s if TERMINAL_STATUSES.include?(s['subprocess_status'])
            s['subprocess_status'] = new_status
            s['crash_reason']      = reason if reason
            s['crashed_at']        = Time.now.iso8601 if new_status != 'done'
            s
          end
        end

        # ──────────────────────────────────────────────────────────────
        # Legacy v0.2.x API (read-only in v0.3.0; kept for compat)
        # ──────────────────────────────────────────────────────────────

        def path_for(token)
          raise ArgumentError, "invalid token format: #{token.inspect}" unless valid_token?(token)
          File.join(root_dir, "#{token}.json")
        end

        # Legacy single-file write. v0.3.0+ SHOULD NOT call this; only kept
        # to support existing callers during the migration window.
        def write(token, data)
          FileUtils.mkdir_p(root_dir)
          path = path_for(token)
          tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
          File.write(tmp, JSON.pretty_generate(data))
          File.rename(tmp, path)
          path
        ensure
          begin
            File.unlink(tmp) if tmp && File.exist?(tmp)
          rescue Errno::ENOENT
            nil
          end
        end

        # Legacy single-file load. Returns parsed Hash or nil.
        def load(token)
          load_detailed(token)[:data]
        end

        # Legacy single-file load with tagged status.
        def load_detailed(token)
          unless valid_token?(token)
            return { status: :invalid_token, data: nil }
          end
          path = path_for(token)
          unless File.exist?(path)
            return { status: :missing, data: nil }
          end
          data = JSON.parse(File.read(path))
          { status: :ok, data: data }
        rescue JSON::ParserError => e
          warn "[multi_llm_review::PendingState#load] JSON parse error at #{path}: #{e.message}"
          { status: :corrupt, data: nil, error: e.message, path: path }
        rescue Errno::ENOENT
          { status: :missing, data: nil }
        end

        # Legacy single-file delete. v0.3.0+ should prefer directory removal.
        def delete(token)
          return false unless valid_token?(token)
          path = path_for(token)
          return false unless File.exist?(path)
          File.unlink(path)
          true
        rescue Errno::ENOENT
          false
        end

        # ──────────────────────────────────────────────────────────────
        # Internal helpers
        # ──────────────────────────────────────────────────────────────

        def atomic_write_json(path, data)
          FileUtils.mkdir_p(File.dirname(path))
          tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
          begin
            File.write(tmp, JSON.pretty_generate(data))
            File.rename(tmp, path)
          ensure
            begin
              File.unlink(tmp) if File.exist?(tmp)
            rescue Errno::ENOENT
              nil
            end
          end
          path
        end

        # Load+parse with ENOENT and JSON::ParserError treated as transient
        # (returns nil). EACCES and other Errno bubble up — per R1 F-EACC,
        # silent permission issues should not masquerade as "not written yet".
        def load_json_transient(path)
          return nil unless File.exist?(path)
          JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        rescue Errno::ENOENT
          nil
        end

        # ──────────────────────────────────────────────────────────────
        # Cleanup (walks both dir and legacy single-file layouts)
        # ──────────────────────────────────────────────────────────────

        # v0.7 INV-R4 — cleanup no longer erases the fact that a run happened.
        #
        # A directory holding a completed record (collected.json or
        # completed.json) is never reaped: the completed record is the run's
        # record, and R1–R4 of the very loop that froze this design lost their
        # records to the 3600-second retention this replaces.
        #
        # A directory that is reapable (past collect_deadline AND heartbeat
        # stale / gc.eligible / self_timed_out — unchanged criteria) is not
        # removed but REDUCED to its minimal trace: marker.json (synthesized
        # from state.json if the run predates markers) plus reaped.json naming
        # when and why. A directory already reduced is left alone.
        #
        # The legacy v0.2.x single-file layout keeps its old removal rules:
        # those are pre-v0.7 records, and the design does not reach back
        # (design §4, no retroactivity).
        def cleanup_expired!(now: Time.now,
                             retain_collected_seconds: 3600,
                             heartbeat_stale_threshold_seconds: HEARTBEAT_STALE_DEFAULT,
                             stale_no_deadline_seconds: STALE_NO_DEADLINE_SECONDS,
                             orphan_tmp_stale_seconds: ORPHAN_TMP_STALE_DEFAULT,
                             skip_token: nil)
          return { removed: 0, skipped_errors: 0 } unless Dir.exist?(root_dir)

          removed = 0
          skipped_errors = 0

          # ── v0.3.0 directory layout ──
          Dir.glob(File.join(root_dir, '*')).each do |path|
            next unless File.directory?(path)
            name = File.basename(path)
            next if skip_token && name == skip_token
            next unless valid_token?(name)

            begin
              if dir_reapable?(name, now, retain_collected_seconds,
                               heartbeat_stale_threshold_seconds,
                               stale_no_deadline_seconds)
                # TOCTOU re-check: a worker may have refreshed heartbeat
                # between our load and now. Re-verify heartbeat staleness
                # (the only criterion that can flip false→true→false mid-sweep).
                if dir_reapable?(name, Time.now, retain_collected_seconds,
                                 heartbeat_stale_threshold_seconds,
                                 stale_no_deadline_seconds)
                  reduce_to_trace!(name, now)
                  removed += 1
                end
              end
            rescue Errno::ENOENT
              next
            rescue StandardError => e
              skipped_errors += 1
              warn "[PendingState#cleanup_expired] skipping dir #{name}: #{e.class}: #{e.message}"
              warn e.backtrace.first(3).join("\n") if e.backtrace
            end
          end

          # ── v0.2.x legacy single-file layout ──
          # NB: does NOT filter by valid_token? — v0.2.3 behavior counted
          # garbage .json files as skipped_errors via the parse path.
          Dir.glob(File.join(root_dir, '*.json')).each do |path|
            begin
              basename = File.basename(path, '.json')
              next if skip_token && basename == skip_token

              data = begin
                JSON.parse(File.read(path))
              rescue JSON::ParserError => e
                skipped_errors += 1
                warn "[PendingState#cleanup_expired] legacy corrupt #{File.basename(path)}: #{e.message}"
                nil
              end

              deadline = data.is_a?(Hash) ? (Time.iso8601(data['collect_deadline']) rescue nil) : nil

              if deadline
                collected = data['collected'] == true
                cutoff = collected ? deadline + retain_collected_seconds : deadline
                if now > cutoff
                  File.unlink(path)
                  removed += 1
                end
              else
                mtime = File.mtime(path) rescue nil
                if mtime && now - mtime > stale_no_deadline_seconds
                  File.unlink(path)
                  removed += 1
                  warn "[PendingState#cleanup_expired] legacy stale no-deadline: #{File.basename(path)}"
                end
              end
            rescue Errno::ENOENT
              next
            rescue StandardError => e
              skipped_errors += 1
              warn "[PendingState#cleanup_expired] legacy skip #{File.basename(path)}: #{e.class}: #{e.message}"
              next
            end
          end

          # ── Orphan tmp files (interrupted atomic writes) ──
          Dir.glob(File.join(root_dir, '**', '*.tmp.*')).each do |path|
            begin
              mtime = File.mtime(path) rescue nil
              next unless mtime
              if now - mtime > orphan_tmp_stale_seconds
                File.unlink(path)
                removed += 1
              end
            rescue Errno::ENOENT
              next
            rescue StandardError => e
              skipped_errors += 1
              warn "[PendingState#cleanup_expired] tmp skip #{File.basename(path)}: #{e.class}: #{e.message}"
              next
            end
          end

          { removed: removed, skipped_errors: skipped_errors }
        end

        # What survives a reduction to trace: the existence mark, the terminal
        # note, and the refusal sidecar — a refusal is a cause the run already
        # knew and wrote, and INV-R4 keeps known causes readable after the
        # working files go.
        TRACE_KEEP_FILES = %w[marker.json reaped.json refusals.json].freeze

        # Reduce a reapable directory to its minimal trace (INV-R4). What
        # stays: marker.json — synthesized from state.json when the run
        # predates markers — reaped.json, naming when and what was known,
        # and refusals.json when refusals were recorded. Everything else
        # goes. Idempotent: a directory already reduced is detected in
        # dir_reapable? and never arrives here twice.
        def reduce_to_trace!(token, now)
          state = load_state(token)

          unless File.exist?(marker_path(token))
            write_marker(token, {
              'token' => token,
              'marked_at' => (state && state['created_at']) || now.iso8601,
              'marker_source' => 'synthesized_at_reap',
              'artifact_name' => state && state['artifact_name'],
              'review_type' => state && state['review_type'],
              'review_round' => state && state['review_round']
            }.compact)
          end

          refusal_count = load_refusals(token).size
          write_json = {
            'reaped_at' => now.iso8601,
            'reason' => 'expired_before_completion',
            'collect_deadline' => state && state['collect_deadline'],
            'subprocess_status' => state && state['subprocess_status'],
            'crash_reason' => state && state['crash_reason'],
            'refusal_count' => (refusal_count if refusal_count.positive?)
          }.compact
          # First terminal note wins on THIS side too. dir_reapable? already
          # refuses a noted directory, but a writer near the failure
          # (abandon_run) can land its specific cause between that check and
          # this write; the generic 'expired' must not overwrite it. A window
          # narrower than one File.exist? remains — closing it fully needs a
          # lock and is backlog, not a rule change.
          atomic_write_json(reaped_path(token), write_json) unless File.exist?(reaped_path(token))

          Dir.glob(File.join(token_dir(token), '*')).each do |f|
            next if TRACE_KEEP_FILES.include?(File.basename(f))

            FileUtils.rm_rf(f)
          end
        end

        # Decide whether a per-token dir is eligible for reap.
        def dir_reapable?(token, now, _retain_collected_seconds,
                          heartbeat_stale_threshold_seconds,
                          stale_no_deadline_seconds)
          # A completed record pins the directory outright (INV-R4): the
          # record of a run is not garbage at any age. A directory already
          # reduced to its trace is equally final.
          return false if File.exist?(collected_path(token))
          return false if File.exist?(completed_path(token))
          return false if File.exist?(reaped_path(token))

          state = load_state(token)

          # The pin is the FACT of completion, not a filename. A synchronous
          # collect (and every pre-v0.7 collect) caches its final record
          # inline in state.json; reaping such a directory would erase a
          # completed record and then assert it expired — the exact loss and
          # false cause this rule exists to prevent.
          if state && (state['collected'] == true || state['final_payload'])
            return false
          end

          # No state.json at all — treat as orphan past stale_no_deadline_seconds.
          unless state
            mtime = (File.mtime(token_dir(token)) rescue nil)
            return mtime && now - mtime > stale_no_deadline_seconds
          end

          deadline = Time.iso8601(state['collect_deadline']) rescue nil
          unless deadline
            # Malformed/missing collect_deadline — fall back to dir mtime
            # (matches the no-state-at-all branch). Prevents infinite pin
            # of a corrupted-but-parseable state.json.
            mtime = (File.mtime(token_dir(token)) rescue nil)
            return mtime && now - mtime > stale_no_deadline_seconds
          end
          return false unless now > deadline

          # Past deadline — reap if any of: heartbeat stale, gc.eligible, self_timed_out.
          heartbeat_mtime = (File.mtime(worker_heartbeat_path(token)) rescue nil)
          heartbeat_stale = heartbeat_mtime.nil? ||
                            (now - heartbeat_mtime > heartbeat_stale_threshold_seconds)

          gc_eligible   = File.exist?(gc_eligible_path(token))
          self_timed    = state['subprocess_status'] == 'self_timed_out'

          heartbeat_stale || gc_eligible || self_timed
        end
      end
    end
  end
end
