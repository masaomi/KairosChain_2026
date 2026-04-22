# frozen_string_literal: true

# frozen_string_literal requires are handled by the file header.
# Timeout is needed only for the Timeout::Error constant.
require 'timeout'

module KairosMcp
  module SkillSets
    module LlmClient
      # Subprocess runner with env sanitization and explicit PID tracking.
      # Uses Process.spawn(unsetenv_others: true) to prevent env leakage into
      # child processes and registers every live PID so they can be terminated
      # on dispatch cancellation or interpreter exit.
      module SafeSubprocess
        SAFE_ENV_KEYS = %w[PATH HOME USER LANG TERM SHELL TMPDIR].freeze
        GRACE_SECONDS = 5

        @in_flight = {}
        @pid_mutex = Mutex.new

        module_function

        # Run a subprocess and capture stdout/stderr with a hard timeout.
        # On timeout: SIGTERM -> GRACE_SECONDS wait -> SIGKILL -> waitpid.
        # Pipes are closed before joining reader threads to prevent hangs
        # when grandchild processes hold the write end.
        def safe_capture(args, stdin_data:, timeout_seconds:, env: {},
                         dispatch_id: nil, chdir: nil)
          # Snapshot ENV once to avoid TOCTOU races
          clean_env = sanitized_env(env)

          stdin_r, stdin_w = IO.pipe
          stdout_r, stdout_w = IO.pipe
          stderr_r, stderr_w = IO.pipe

          spawn_opts = { in: stdin_r, out: stdout_w, err: stderr_w,
                         unsetenv_others: true }
          spawn_opts[:chdir] = chdir if chdir

          pid = Process.spawn(clean_env, *args, **spawn_opts)

          stdin_r.close
          stdout_w.close
          stderr_w.close

          register_pid(pid, dispatch_id)

          out_buf = String.new
          err_buf = String.new
          out_thread = Thread.new { out_buf << stdout_r.read rescue nil }
          err_thread = Thread.new { err_buf << stderr_r.read rescue nil }

          begin
            stdin_w.write(stdin_data) if stdin_data && !stdin_data.empty?
          rescue Errno::EPIPE
            # child closed stdin early; continue
          ensure
            stdin_w.close unless stdin_w.closed?
          end

          # Wait for child with WNOHANG polling (avoids Timeout.timeout PID-reuse hazard)
          status = nil
          timed_out = false
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
          loop do
            reaped, status = begin
              Process.waitpid2(pid, Process::WNOHANG)
            rescue Errno::ECHILD
              # Concurrent reaper (kill_pids_for_dispatch) already reaped this child
              [pid, nil]
            end
            break if reaped
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              timed_out = true
              kill_gracefully(pid)
              break
            end
            sleep 0.1
          end

          # Close pipes BEFORE joining threads — unblocks readers even if
          # grandchild processes still hold the write end.
          [stdout_r, stderr_r].each { |io| io.close unless io.closed? }
          # Bounded join: 2s per thread (4s worst-case, not 10s)
          [out_thread, err_thread].each { |t| t.join(2) }

          if timed_out
            raise Timeout::Error, "subprocess timed out after #{timeout_seconds}s"
          end

          [out_buf, err_buf, status]
        ensure
          # Always unregister PID (handles ECHILD from concurrent reaping)
          unregister_pid(pid) if pid
          [stdin_r, stdin_w, stdout_r, stdout_w, stderr_r, stderr_w].each do |io|
            io.close if io && !io.closed?
          rescue StandardError
            nil
          end
        end

        def kill_pids_for_dispatch(dispatch_id)
          pids = @pid_mutex.synchronize do
            @in_flight.select { |_, v| v[:dispatch_id] == dispatch_id }.keys
          end
          pids.each { |pid| kill_gracefully(pid) }
          pids
        end

        def kill_all_in_flight
          pids = @pid_mutex.synchronize { @in_flight.keys }
          pids.each { |pid| kill_gracefully(pid) }
          pids
        end

        def in_flight_snapshot
          @pid_mutex.synchronize { @in_flight.dup }
        end

        def sanitized_env(env)
          # Snapshot ENV once to avoid TOCTOU races from concurrent threads
          env_snapshot = ENV.to_h
          result = {}
          SAFE_ENV_KEYS.each { |k| result[k] = env_snapshot[k] if env_snapshot[k] }

          auth_key = env['_auth_env_key'] || env[:_auth_env_key]
          if auth_key
            val = env_snapshot[auth_key.to_s]
            result[auth_key.to_s] = val if val && !val.empty?
          end

          env.each do |k, v|
            key = k.to_s
            next if key.start_with?('_')  # skip control keys (_auth_env_key, etc.)
            result[key] = v
          end
          result
        end

        def register_pid(pid, dispatch_id)
          @pid_mutex.synchronize do
            @in_flight[pid] = { dispatch_id: dispatch_id, registered_at: Time.now }
          end
        end

        def unregister_pid(pid)
          @pid_mutex.synchronize { @in_flight.delete(pid) }
        end

        def kill_gracefully(pid)
          Process.kill('TERM', pid)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GRACE_SECONDS
          loop do
            reaped, _status = Process.waitpid2(pid, Process::WNOHANG)
            return if reaped
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              begin
                Process.kill('KILL', pid)
              rescue Errno::ESRCH
                return
              end
              begin
                Process.waitpid(pid)
              rescue Errno::ECHILD
                nil
              end
              return
            end
            sleep 0.1
          end
        rescue Errno::ESRCH, Errno::ECHILD
          # process already exited or was reaped elsewhere
          nil
        end

        at_exit do
          pids = @pid_mutex.synchronize { @in_flight.keys }
          pids.each do |pid|
            begin
              Process.kill('TERM', pid)
            rescue Errno::ESRCH
              next
            end
          end
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GRACE_SECONDS
          pids.each do |pid|
            loop do
              reaped, _status = Process.waitpid2(pid, Process::WNOHANG) rescue [nil, nil]
              break if reaped
              if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                begin
                  Process.kill('KILL', pid)
                  Process.waitpid(pid)
                rescue Errno::ESRCH, Errno::ECHILD
                  nil
                end
                break
              end
              sleep 0.1
            end
          end
        end
      end
    end
  end
end
