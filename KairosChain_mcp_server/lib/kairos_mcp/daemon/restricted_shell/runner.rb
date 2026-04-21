# frozen_string_literal: true

require 'digest'
require 'json'

module KairosMcp
  class Daemon
    class RestrictedShell
      # Runner — Process.spawn with timeout, process-group kill, output capture.
      # Single-threaded daemon assumption: synchronous blocking is acceptable.
      module Runner
        GRACE_PERIOD = 3  # seconds between SIGTERM and SIGKILL

        def self.run_with_timeout(wrapped_cmd:, env:, cwd:, timeout:,
                                  stdin_data: nil, max_output_bytes:,
                                  cmd_for_hash: nil)
          r_out, w_out = IO.pipe
          r_err, w_err = IO.pipe
          r_in, w_in = stdin_data ? IO.pipe : [nil, nil]

          pid = Process.spawn(
            env, *wrapped_cmd,
            chdir: cwd,
            in: r_in || :close,
            out: w_out, err: w_err,
            pgroup: true,
            unsetenv_others: true
          )

          w_out.close; w_err.close
          r_in&.close

          if w_in && stdin_data
            w_in.write(stdin_data)
            w_in.close
            w_in = nil
          end

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          deadline = start + timeout

          stdout_buf = ''.dup
          stderr_buf = ''.dup
          stdout_trunc = false
          stderr_trunc = false
          status = nil

          begin
            readers = [r_out, r_err].compact

            loop do
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if remaining <= 0
                kill_tree!(pid)
                elapsed = (timeout * 1000).to_i
                raise TimeoutError.new("timeout after #{timeout}s", elapsed_ms: elapsed, pid: pid)
              end

              break if readers.empty?

              ready = IO.select(readers, nil, nil, [remaining, 0.1].min)
              if ready
                ready[0].each do |io|
                  chunk = io.read_nonblock(16_384, exception: false)
                  case chunk
                  when :wait_readable
                    next
                  when nil
                    io.close rescue nil
                    readers.delete(io)
                  else
                    if io == r_out
                      stdout_buf << chunk
                      if stdout_buf.bytesize > max_output_bytes
                        stdout_trunc = true
                        kill_tree!(pid)
                        raise OutputTruncated.new(:stdout, max_output_bytes)
                      end
                    else
                      stderr_buf << chunk
                      if stderr_buf.bytesize > max_output_bytes
                        stderr_trunc = true
                        kill_tree!(pid)
                        raise OutputTruncated.new(:stderr, max_output_bytes)
                      end
                    end
                  end
                end
              end

              # R2 residual: only check exit AFTER draining pipes
              if readers.empty?
                _, status = Process.waitpid2(pid, 0)
                break
              end

              # Non-blocking check if child exited but pipes still have data
              _, s = Process.waitpid2(pid, Process::WNOHANG)
              if s
                # Child exited — drain remaining pipe data
                readers.each do |io|
                  loop do
                    chunk = io.read_nonblock(16_384, exception: false)
                    break if chunk.nil? || chunk == :wait_readable
                    if io == r_out
                      stdout_buf << chunk
                    else
                      stderr_buf << chunk
                    end
                  end
                  io.close rescue nil
                end
                status = s
                break
              end
            end
          rescue OutputTruncated, TimeoutError
            Process.waitpid2(pid, Process::WNOHANG) rescue nil
            raise
          ensure
            [r_out, r_err, w_in].compact.each { |io| io.close rescue nil }
          end

          _, status = Process.waitpid2(pid, 0) unless status
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).to_i

          cmd_hash = cmd_for_hash ? compute_hash(cmd_for_hash, cwd) : nil

          Result.new(
            status: status&.exitstatus,
            signal: status&.signaled? ? Signal.signame(status.termsig) : nil,
            stdout: stdout_buf, stderr: stderr_buf,
            duration_ms: elapsed,
            stdout_truncated: stdout_trunc, stderr_truncated: stderr_trunc,
            sandbox_driver: :sandbox_exec,
            cmd_hash: cmd_hash
          )
        end

        def self.kill_tree!(pid)
          Process.kill('-TERM', pid) rescue nil
          sleep GRACE_PERIOD
          Process.kill('-KILL', pid) rescue nil
          Process.waitpid2(pid, Process::WNOHANG) rescue nil
        end

        def self.compute_hash(cmd, cwd)
          "sha256:#{Digest::SHA256.hexdigest(JSON.generate({ cmd: cmd, cwd: cwd }))}"
        end
      end
    end
  end
end
