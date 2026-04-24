# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Reaps a detached worker when Phase 2 gives up waiting (worker_timeout).
      # Signals the worker's PROCESS GROUP (negative pgid) so adapter-spawned
      # descendants (F23) are also killed. Two-ESRCH fence confirms death
      # before success (F-RSUS), and a live-pgid check against the
      # orchestrator's pgid prevents self-kill (v0.3.2 P0-4 / C3c).
      module WorkerReaper
        ESRCH_CHECK_INTERVAL = 0.1

        module_function

        # @return [Symbol] one of :terminated, :killed, :already_dead,
        #                         :unreachable, :skipped, :error
        def terminate!(token, pid, pgid, config = {})
          return :skipped unless pid && pid > 1

          orch_pgid = (Process.getpgid(Process.pid) rescue nil)
          unless pgid && pgid > 1 && pgid != orch_pgid
            warn "[WorkerReaper] refused: invalid or self-pgid (pgid=#{pgid.inspect}, orch=#{orch_pgid.inspect})"
            return :unreachable
          end

          # Cross-check against the worker.pid file the worker itself wrote.
          pid_info = PendingState.load_worker_pid(token)
          unless pid_info && pid_info['pid'] == pid && pid_info['pgid'] == pgid
            warn "[WorkerReaper] refused: pid_info mismatch (want #{pid}/#{pgid}, have #{pid_info.inspect})"
            return :unreachable
          end

          # spawned_at freshness (defense against recycled pid file from a
          # long-gone prior token — v0.3.2 C3c).
          spawned_at = (Time.iso8601(pid_info['spawned_at']) rescue nil)
          if spawned_at.nil? || (Time.now - spawned_at) > 3600
            warn "[WorkerReaper] refused: spawned_at stale/invalid (#{pid_info['spawned_at'].inspect})"
            return :unreachable
          end

          target = -pgid      # pgroup-wide signal
          graceful = config[:graceful_wait_seconds] || 3

          begin
            Process.kill('TERM', target)
          rescue Errno::ESRCH
            return confirm_dead(pid) ? :already_dead : :unreachable
          rescue Errno::EPERM
            return :unreachable
          end

          # Phase 1: graceful
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + graceful
          loop do
            break if confirm_dead(pid)
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep ESRCH_CHECK_INTERVAL
          end
          return :terminated if confirm_dead(pid)

          # Phase 2: force
          Process.kill('KILL', target) rescue nil
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
          loop do
            break if confirm_dead(pid)
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep ESRCH_CHECK_INTERVAL
          end
          confirm_dead(pid) ? :killed : :error
        rescue StandardError => e
          warn "[WorkerReaper] #{e.class}: #{e.message}"
          :error
        end

        # Two consecutive ESRCH observations ≥ 100ms apart defeat the PID-
        # reuse window (R4 cluster C3c / F-RSUS).
        def confirm_dead(pid)
          seen = 0
          2.times do
            begin
              Process.kill(0, pid)
              return false
            rescue Errno::ESRCH
              seen += 1
            rescue Errno::EPERM
              return false
            end
            sleep ESRCH_CHECK_INTERVAL
          end
          seen == 2
        end
      end
    end
  end
end
