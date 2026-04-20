# frozen_string_literal: true

require 'fileutils'

module KairosMcp
  class Daemon
    # PID lock using flock(LOCK_EX|LOCK_NB).
    #
    # Design rationale (see design v0.2 §3.1):
    # - flock is atomic and OS-managed; no stale PID file detection required.
    # - If the daemon process dies, the OS releases the lock automatically.
    # - On acquisition we write our PID for operational visibility, but the
    #   lock itself — not the file contents — is the source of truth.
    module PidLock
      # Raised when another process already holds the lock.
      class AlreadyLocked < StandardError
        attr_reader :path, :holder_pid

        def initialize(path, holder_pid)
          @path = path
          @holder_pid = holder_pid
          super("Daemon already running (pid=#{holder_pid || 'unknown'}, lock=#{path})")
        end
      end

      # Acquire an exclusive, non-blocking flock on `path`.
      # Returns the opened File handle (caller must keep a reference for the
      # duration of the lock — GC-closing the file releases the lock).
      #
      # @param path [String] absolute path to the pid file
      # @return [File] the locked file handle (pid already written)
      # @raise [AlreadyLocked] if another process holds the lock
      def self.acquire!(path)
        FileUtils.mkdir_p(File.dirname(path))

        # Open rw + create. We deliberately do NOT truncate before the flock,
        # so a failing acquisition does not wipe the holder's pid.
        file = File.open(path, File::RDWR | File::CREAT, 0o644)

        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          holder = read_pid(file)
          file.close
          raise AlreadyLocked.new(path, holder)
        end

        # We own the lock — rewrite pid file
        file.truncate(0)
        file.rewind
        file.write("#{Process.pid}\n")
        file.flush
        file
      end

      # Release and remove the pid file.
      # CF-1 fix: delete WHILE holding the lock to prevent unlink race.
      # Safe to call with nil or an already-closed file.
      def self.release(file, path)
        return if file.nil?

        begin
          # Delete while still holding the lock — prevents a replacement
          # daemon from acquiring the same path before we unlink it.
          File.delete(path) if File.exist?(path)
        rescue Errno::ENOENT
          # Already gone — fine.
        end

        begin
          file.flock(File::LOCK_UN)
        rescue StandardError
          # Already unlocked or closed — ignore
        end

        begin
          file.close unless file.closed?
        rescue StandardError
          # ignore
        end
      end

      # Read the pid written in the (already-opened) file, if any.
      # Used only for diagnostics in AlreadyLocked.
      def self.read_pid(file)
        file.rewind
        contents = file.read
        pid = contents.to_s.strip.to_i
        pid.positive? ? pid : nil
      rescue StandardError
        nil
      end

      # Read the pid directly from disk (used when we don't hold the file).
      def self.read_pid_from(path)
        return nil unless File.exist?(path)

        pid = File.read(path).to_s.strip.to_i
        pid.positive? ? pid : nil
      rescue StandardError
        nil
      end
    end
  end
end
