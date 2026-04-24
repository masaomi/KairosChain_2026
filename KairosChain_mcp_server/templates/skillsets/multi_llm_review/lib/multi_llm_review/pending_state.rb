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
        def gc_eligible_path(token);        File.join(token_dir(token), 'gc.eligible'); end
        def request_path(token);            File.join(token_dir(token), 'request.json'); end
        def subprocess_results_path(token); File.join(token_dir(token), 'subprocess_results.json'); end
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
        def write_worker_pid(token, data);         atomic_write_json(worker_pid_path(token), data); end

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

        # A directory is reapable iff:
        #   - past collect_deadline AND
        #     (heartbeat stale > heartbeat_stale_threshold_seconds
        #      OR gc.eligible exists
        #      OR state.subprocess_status == 'self_timed_out')
        # collected.json presence pins retention until collected_at + retain_collected_seconds.
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
                  FileUtils.rm_rf(path)
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

        # Decide whether a per-token dir is eligible for reap.
        def dir_reapable?(token, now, retain_collected_seconds,
                          heartbeat_stale_threshold_seconds,
                          stale_no_deadline_seconds)
          state = load_state(token)

          # No state.json at all — treat as orphan past stale_no_deadline_seconds.
          unless state
            mtime = (File.mtime(token_dir(token)) rescue nil)
            return mtime && now - mtime > stale_no_deadline_seconds
          end

          # collected.json presence pins to collected_at + retain.
          if File.exist?(collected_path(token))
            collected = load_collected(token)
            collected_at = (Time.iso8601(collected['collected_at']) rescue nil) if collected
            retain_until = collected_at ? collected_at + retain_collected_seconds : nil
            return retain_until ? now > retain_until : false
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
