# frozen_string_literal: true

module KairosMcp
  class Daemon
    # Signal handling for the daemon (design v0.2 §3.1).
    #
    # Signal → action mapping:
    #   SIGTERM  → graceful shutdown (sets @shutdown_requested)
    #   SIGINT   → graceful shutdown (same as TERM, for `Ctrl-C` during foreground runs)
    #   SIGHUP   → reload config      (enqueues :reload command)
    #   SIGUSR1  → status dump        (enqueues :status_dump command)
    #
    # Signal handlers run in the VM's signal-handling context, where only a
    # narrow subset of operations is safe. We therefore do as little work as
    # possible inside the trap block — just flip a flag or push onto the
    # thread-safe CommandMailbox — and let the main event loop do the work.
    module SignalHandler
      SUPPORTED_SIGNALS = %w[TERM INT HUP USR1].freeze

      # Install handlers on the given daemon instance.
      #
      # The daemon must respond to:
      #   - #request_shutdown!(signal)
      #   - #mailbox  (returns a CommandMailbox)
      #   - #logger   (returns a KairosMcp::Logger or duck-equivalent)
      #
      # @param daemon [Daemon] the daemon to wire signals into
      # @return [Array<String>] list of signals successfully installed
      def self.install(daemon)
        installed = []
        SUPPORTED_SIGNALS.each do |sig|
          next unless signal_supported?(sig)

          begin
            Signal.trap(sig) { handle(daemon, sig) }
            installed << sig
          rescue ArgumentError, Errno::EINVAL
            # Platform doesn't support this signal — skip silently.
          end
        end
        installed
      end

      # Remove any handlers we installed (mainly for tests).
      def self.uninstall
        SUPPORTED_SIGNALS.each do |sig|
          next unless signal_supported?(sig)

          begin
            Signal.trap(sig, 'DEFAULT')
          rescue ArgumentError, Errno::EINVAL
            # ignore
          end
        end
      end

      # Dispatch a signal to the daemon. Kept public for tests that want
      # to simulate signal delivery without actually raising signals.
      #
      # CF-2 fix: only set atomic flags in signal context. The event loop
      # translates flags into mailbox commands on the next tick.
      def self.handle(daemon, sig)
        case sig
        when 'TERM', 'INT'
          daemon.request_shutdown!(sig)
        when 'HUP'
          daemon.request_reload!
        when 'USR1'
          daemon.request_status_dump!
        end
      rescue StandardError
        # Signal handlers must never raise — swallow everything.
      end

      def self.signal_supported?(sig)
        Signal.list.key?(sig)
      end
    end
  end
end
