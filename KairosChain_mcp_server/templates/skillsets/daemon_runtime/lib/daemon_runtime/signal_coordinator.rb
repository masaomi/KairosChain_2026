# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module DaemonRuntime
      # Signal-safe shutdown / reload / diagnostic channel (24/7 v0.4 §2.7).
      #
      # Design:
      # - The trap handler does exactly one async-signal-safe operation:
      #   a non-blocking write of a single tagged byte to a self-pipe.
      #   No mutex, no logger, no @flags mutation.
      # - A dedicated non-trap pump thread drains the pipe and translates
      #   bytes into mutex-protected state changes. This is the ONLY place
      #   outside clear_* methods where @flags is written.
      # - Readers (`shutdown_requested?` etc.) and waiters (`wait_or_tick`)
      #   observe state under the same mutex as the pump thread's writes.
      #   No reader/writer asymmetry (R4 P1 fix retained from v0.3.4).
      #
      # This scaffold exposes the full state machine; an embedding daemon
      # binds OS signals to `trap_signal` via Signal.trap externally.
      class SignalCoordinator
        SIG_BYTES = {
          'TERM' => 'T'.b, 'INT'  => 'I'.b,
          'USR2' => 'U'.b, 'HUP'  => 'H'.b
        }.freeze

        def initialize(logger: nil)
          @logger = logger
          @reader, @writer = IO.pipe
          @writer.binmode
          @reader.binmode
          @state_mutex = Mutex.new
          @flags = { shutdown: false, diagnostic: false, reload: false }
          @cond = ConditionVariable.new
          @stop_mutex = Mutex.new
          @stopped = false
          # R1 P1 (Codex): latch for bytes dropped under pipe-full / EINTR.
          # Signal trap just flips scalar booleans (async-signal-safe); the
          # pump re-reads these on every wake so no shutdown request is lost
          # even if the pipe write was dropped.
          @pending_latch = { shutdown: false, diagnostic: false, reload: false }
          @pump_thread = start_pump_thread
        end

        # Called ONLY from a signal trap context. Must be async-signal-safe:
        # scalar assignment to @pending_latch + one non-blocking pipe write.
        # No mutex, no logger.
        def trap_signal(sig)
          key = case sig.to_s
                when 'TERM', 'INT' then :shutdown
                when 'USR2'        then :diagnostic
                when 'HUP'         then :reload
                else                    return
                end
          # Scalar store first — if the pipe write is dropped, the pump
          # still observes the latch on its next wake.
          @pending_latch[key] = true
          byte = SIG_BYTES[sig.to_s] or return
          begin
            @writer.write_nonblock(byte)
          rescue IO::WaitWritable, Errno::EINTR, IOError
            # Pipe full / writer closed — latch above will be consumed by
            # the pump on any subsequent wake.
          end
        end

        def shutdown_requested?;   @state_mutex.synchronize { @flags[:shutdown]   }; end
        def diagnostic_requested?; @state_mutex.synchronize { @flags[:diagnostic] }; end
        def reload_requested?;     @state_mutex.synchronize { @flags[:reload]     }; end

        def clear_reload!;     @state_mutex.synchronize { @flags[:reload]     = false }; end
        def clear_diagnostic!; @state_mutex.synchronize { @flags[:diagnostic] = false }; end

        # Block up to `seconds`. Returns immediately if any flag is set.
        # Woken by (a) timeout, (b) pump-thread broadcast after state change.
        def wait_or_tick(seconds)
          deadline = Time.now + seconds
          @state_mutex.synchronize do
            loop do
              return if @flags[:shutdown] || @flags[:diagnostic] || @flags[:reload]
              remaining = deadline - Time.now
              return if remaining <= 0
              @cond.wait(@state_mutex, remaining)
            end
          end
        end

        # Graceful pump shutdown. Closes the writer so the pump's IO.select
        # unblocks, lets the pump exit on EOF, and joins it with a short
        # deadline. Safe to call multiple times.
        # R1 P2 (4.7): @stopped guarded under mutex; prior version allowed
        # two stop() callers to both pass the guard and double-close.
        def stop
          @stop_mutex.synchronize do
            return if @stopped
            @stopped = true
          end
          begin
            @writer.close unless @writer.closed?
          rescue IOError
          end
          @pump_thread&.join(2)
          begin
            @reader.close unless @reader.closed?
          rescue IOError
          end
        end

        private

        def start_pump_thread
          Thread.new do
            Thread.current.name = 'kairos-signal-pump'
            buf = String.new(capacity: 64)
            loop do
              begin
                IO.select([@reader])
              rescue IOError, Errno::EBADF
                break  # reader closed → shutdown (EBADF on some platforms)
              end
              begin
                loop do
                  chunk = @reader.read_nonblock(64, buf)
                  apply_bytes(chunk)
                end
              rescue IO::WaitReadable
                # drained — fall through to latch drain
              rescue EOFError, IOError, Errno::EBADF
                drain_latches  # last chance to pick up any dropped-byte latches
                break
              end
              # R1 P1 (Codex): consume dropped-byte latches even when the
              # pipe read succeeded, so a byte dropped under pipe-full still
              # surfaces on this wake.
              drain_latches
            end
          end
        end

        def apply_bytes(chunk)
          updated = false
          chunk.each_byte do |b|
            case b.chr
            when 'T', 'I' then updated = set_flag(:shutdown,   true) || updated
            when 'U'      then updated = set_flag(:diagnostic, true) || updated
            when 'H'      then updated = set_flag(:reload,     true) || updated
            end
          end
          broadcast if updated
        end

        def drain_latches
          updated = false
          %i[shutdown diagnostic reload].each do |key|
            next unless @pending_latch[key]
            @pending_latch[key] = false
            updated = set_flag(key, true) || updated
          end
          broadcast if updated
        end

        def set_flag(key, value)
          @state_mutex.synchronize do
            return false if @flags[key] == value
            @flags[key] = value
            true
          end
        end

        def broadcast
          @state_mutex.synchronize { @cond.broadcast }
        end
      end
    end
  end
end
