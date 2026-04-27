# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Phase 2's polling loop for the detached worker's subprocess_results.json.
      # Returns one of four outcomes:
      #   :ready       — subprocess_results.json parsed successfully
      #   :crashed     — state.subprocess_status == crashed/self_timed_out
      #                  OR state == done but results never parseable within
      #                     wall-clock budget (reason: done_but_no_results)
      #                  OR heartbeat stale (only while non-terminal state)
      #                  OR pid present but no heartbeat within grace OR
      #                  no pid/heartbeat within startup grace
      #   :timeout     — wall-clock max_wait exceeded with live worker
      #   (raises on unexpected errors from PendingState)
      #
      # v3.24.2: 'done' state now bypasses the heartbeat staleness check.
      # The heartbeat thread is killed in the worker's ensure block, so
      # mtime stops advancing the moment the worker transitions to 'done'.
      # Without this bypass, a transient parse-mid-rename of
      # subprocess_results.json combined with the killed heartbeat could
      # surface a false-positive 'heartbeat_stale' for a successfully
      # completed worker.
      module WaitForWorker
        STARTUP_GRACE_DEFAULT        = 30
        HEARTBEAT_STALE_DEFAULT      = 15
        POLL_INTERVAL_DEFAULT        = 0.5
        SUSPEND_JUMP_THRESHOLD       = 5.0

        # All possible :crashed outcome reasons. Single source of truth for
        # the crash-reason taxonomy; operators grep these in worker.log and
        # next_action redispatch hints. v3.24.3 declares the constant; usage
        # sites still use string literals (replacement scheduled for v3.24.4
        # to avoid bundling unrelated refactors).
        CRASH_REASONS = %w[
          heartbeat_stale
          heartbeat_never_started
          worker_never_started
          done_but_no_results
          crashed
          self_timed_out
          wait_exhausted
          internal_error
          malformed_state
        ].freeze

        module_function

        def wait(token, opts = {})
          max_wait       = opts[:max_wait_seconds] || 240
          poll_interval  = opts[:poll_interval_seconds] || POLL_INTERVAL_DEFAULT
          startup_grace  = opts[:startup_grace_seconds] || STARTUP_GRACE_DEFAULT
          hb_stale       = opts[:heartbeat_stale_threshold_seconds] || HEARTBEAT_STALE_DEFAULT

          mono = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          first_poll = mono.call
          deadline   = first_poll + max_wait
          last_poll  = first_poll

          loop do
            # Suspend detection (F-SUS): clock jump > threshold → reset first_poll
            now_mono = mono.call
            if now_mono - last_poll > SUSPEND_JUMP_THRESHOLD
              first_poll = now_mono
              # Also push deadline if reasonable — but clamp to original max_wait
              # from the new first_poll.
              deadline = first_poll + max_wait
            end
            last_poll = now_mono

            # 1. Happy path: subprocess_results.json exists
            if File.exist?(PendingState.subprocess_results_path(token))
              data = PendingState.load_subprocess_results(token)
              return { status: :ready, results: data['results'], elapsed: data['elapsed_seconds'] } if data
              # transient parse mid-rename — keep polling
            end

            # 2. Explicit terminal status from worker
            state = PendingState.load_state(token)
            if state
              status = state['subprocess_status']
              if status == 'crashed' || status == 'self_timed_out'
                return {
                  status: :crashed,
                  reason: state['crash_reason'] || status,
                  pid: read_pid(token),
                  pgid: read_pgid_from_file(token),
                  log_tail: tail_log(token)
                }
              end

              # Worker exited cleanly. subprocess_results.json should be (or
              # imminently become) loadable via step 1 on a subsequent poll.
              # The heartbeat thread is intentionally killed at worker exit
              # (dispatch_worker.rb ensure block), so the heartbeat-stale
              # check below would false-positive. Skip liveness checks while
              # 'done', and rely on step 1 retry until results parse or the
              # wall-clock budget exhausts.
              if status == 'done'
                if now_mono > deadline
                  return {
                    status: :crashed,
                    reason: 'done_but_no_results',
                    pid: read_pid(token),
                    pgid: read_pgid_from_file(token),
                    log_tail: tail_log(token)
                  }
                end
                sleep poll_interval
                next
              end
            end

            # 3. Heartbeat-based liveness checks
            pid_info = PendingState.load_worker_pid(token)
            heartbeat_mtime = begin
              File.mtime(PendingState.worker_heartbeat_path(token))
            rescue Errno::ENOENT
              nil
            end

            if pid_info.nil? && heartbeat_mtime.nil?
              if now_mono - first_poll > startup_grace
                return {
                  status: :crashed, reason: 'worker_never_started',
                  log_tail: tail_log(token)
                }
              end
            elsif pid_info && heartbeat_mtime.nil?
              # pid written but heartbeat thread hasn't touched yet
              if now_mono - first_poll > startup_grace
                return {
                  status: :crashed, reason: 'heartbeat_never_started',
                  pid: pid_info['pid'], pgid: pid_info['pgid'],
                  log_tail: tail_log(token)
                }
              end
            elsif heartbeat_mtime
              age = Time.now - heartbeat_mtime
              age = 0 if age < 0      # F-MTIME NTP clamp
              if age > hb_stale
                return {
                  status: :crashed, reason: 'heartbeat_stale',
                  pid: pid_info&.dig('pid'), pgid: live_pgid(pid_info),
                  heartbeat_age: age, log_tail: tail_log(token)
                }
              end
            end

            # 4. Wall-clock budget
            if now_mono > deadline
              return {
                status: :timeout,
                pid: pid_info&.dig('pid'),
                pgid: live_pgid(pid_info),
                waited_seconds: now_mono - first_poll,
                log_tail: tail_log(token)
              }
            end

            sleep poll_interval
          end
        end

        # Live Process.getpgid(pid) — makes the reaper's pid_info match
        # non-tautological (v0.3.2 C3c). Returns nil if pid gone.
        def live_pgid(pid_info)
          return nil unless pid_info && pid_info['pid']
          Process.getpgid(pid_info['pid'])
        rescue Errno::ESRCH, Errno::EPERM
          # Fall back to the file value; reaper will re-check.
          pid_info['pgid']
        end

        def read_pid(token)
          PendingState.load_worker_pid(token)&.dig('pid')
        end

        def read_pgid_from_file(token)
          PendingState.load_worker_pid(token)&.dig('pgid')
        end

        def tail_log(token, lines: 30)
          path = PendingState.worker_log_path(token)
          return '' unless File.exist?(path)
          File.foreach(path).to_a.last(lines).join
        rescue StandardError
          ''
        end
      end
    end
  end
end
