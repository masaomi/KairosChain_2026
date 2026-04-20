# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'time'

require_relative 'logger'
require_relative 'daemon/pid_lock'
require_relative 'daemon/signal_handler'
require_relative 'daemon/command_mailbox'

module KairosMcp
  # KairosChain long-running daemon (Phase 2 P2.1 skeleton).
  #
  # Responsibilities (design v0.2 §3.1):
  #   1. Acquire a single-instance PID lock (flock) at .kairos/run/daemon.pid.
  #   2. Install signal handlers (TERM/INT/HUP/USR1).
  #   3. Load config and initialize the logger.
  #   4. Build Safety in :daemon mode (DaemonPolicy — see §3.1.x / CF-4).
  #   5. Run a single-threaded event loop that:
  #        drain_mailbox → chronos.tick → mandate queue → OODA cycle → heartbeat → sleep
  #   6. Handle graceful shutdown within `graceful_timeout` seconds.
  #
  # For P2.1, Chronos and OODA integration points are stubs — the loop just
  # logs a `no_mandates` heartbeat. Real integration lands in later P2 tickets.
  class Daemon
    DEFAULT_CONFIG_PATH = '.kairos/config/daemon.yml'
    DEFAULT_PID_PATH    = '.kairos/run/daemon.pid'
    DEFAULT_TICK_INTERVAL = 10       # seconds (design §3.2)
    DEFAULT_GRACEFUL_TIMEOUT = 120   # seconds (design §3.4)

    # Lifecycle states — mostly used by tests and status dumps.
    STATES = %i[initialized starting running draining stopped error].freeze

    attr_reader :config, :logger, :mailbox, :state, :tick_count, :started_at

    # @param config_path [String, nil] path to daemon.yml (optional)
    # @param root [String] working directory to resolve relative paths against
    # @param logger [KairosMcp::Logger, nil] override logger (tests)
    # @param sleeper [#call] callable invoked with a Float seconds count
    #                        (injected so tests don't actually sleep)
    # @param clock [#call] callable returning the current Time (tests)
    def initialize(config_path: nil, root: Dir.pwd, logger: nil,
                   sleeper: nil, clock: nil)
      @root = root
      @config_path = config_path || File.join(@root, DEFAULT_CONFIG_PATH)
      @config = load_config(@config_path)
      @logger = logger || KairosMcp.logger
      @mailbox = CommandMailbox.new
      @sleeper = sleeper || ->(s) { sleep(s) }
      @clock = clock || -> { Time.now.utc }

      @pid_file = nil
      @pid_path = resolve_path(@config['pid_path'] || DEFAULT_PID_PATH)
      @tick_interval = Float(@config['tick_interval'] || DEFAULT_TICK_INTERVAL)
      @graceful_timeout = Float(@config['graceful_timeout'] || DEFAULT_GRACEFUL_TIMEOUT)

      @shutdown_requested = false
      @shutdown_signal = nil
      @reload_requested = false
      @status_dump_requested = false
      @state = :initialized
      @tick_count = 0
      @started_at = nil
      @safety = nil
    end

    # ------------------------------------------------------------------ lifecycle

    # Start the daemon: acquire lock, install signals, enter event loop.
    # This is the method `bin/kairos-daemon` invokes.
    def run
      start!
      event_loop
    ensure
      stop!
    end

    # Initialize but do NOT enter the event loop — useful for tests that
    # want to drive `tick_once` manually.
    def start!
      return if @state == :running

      @state = :starting
      @pid_file = PidLock.acquire!(@pid_path)
      SignalHandler.install(self)
      @safety = build_safety
      @started_at = @clock.call
      @state = :running
      @logger.info('daemon_started',
                   source: 'daemon',
                   details: {
                     pid: Process.pid,
                     pid_path: @pid_path,
                     tick_interval: @tick_interval,
                     graceful_timeout: @graceful_timeout
                   })
    end

    # Release lock and uninstall signal handlers. Safe to call twice.
    def stop!
      return if @state == :stopped

      previous_state = @state
      @state = :draining

      # Release PID lock FIRST so a restart isn't blocked by our cleanup.
      PidLock.release(@pid_file, @pid_path)
      @pid_file = nil

      SignalHandler.uninstall

      @state = :stopped
      # Avoid noise if we never successfully started.
      return if previous_state == :initialized

      @logger.info('daemon_stopped',
                   source: 'daemon',
                   details: { signal: @shutdown_signal, tick_count: @tick_count })
    rescue StandardError => e
      @state = :error
      # Logging errors must not crash shutdown.
      warn "[kairos-daemon] stop! failed: #{e.class}: #{e.message}"
    end

    # ------------------------------------------------------------------ signals

    # Called from SignalHandler.handle — must be async-signal-safe.
    # CF-2 fix: only set simple flags, no allocations in signal context.
    def request_shutdown!(signal = nil)
      @shutdown_requested = true
      @shutdown_signal = signal
    end

    def request_reload!
      @reload_requested = true
    end

    def request_status_dump!
      @status_dump_requested = true
    end

    def shutdown_requested?
      @shutdown_requested
    end

    # ------------------------------------------------------------------ event loop

    def event_loop
      shutdown_deadline = nil

      until @state == :stopped
        if @shutdown_requested && shutdown_deadline.nil?
          shutdown_deadline = @clock.call + @graceful_timeout
          @logger.info('daemon_shutdown_begin',
                       source: 'daemon',
                       details: { signal: @shutdown_signal,
                                  deadline: shutdown_deadline.iso8601 })
        end

        if shutdown_deadline && @clock.call >= shutdown_deadline
          @logger.warn('daemon_graceful_timeout_exceeded',
                       source: 'daemon',
                       details: { timeout: @graceful_timeout })
          break
        end

        tick_once

        # If shutdown was requested, there's nothing useful left to do once
        # the mailbox has been drained.
        break if @shutdown_requested && @mailbox.empty?

        @sleeper.call(@tick_interval)
      end
    end

    # One iteration of the event loop.  Exposed for tests.
    def tick_once
      @tick_count += 1

      # CF-2 fix: translate signal flags into mailbox commands (no allocations in trap).
      if @reload_requested
        @reload_requested = false
        @mailbox.enqueue(:reload, signal: 'HUP')
      end
      if @status_dump_requested
        @status_dump_requested = false
        @mailbox.enqueue(:status_dump, signal: 'USR1')
      end

      # 1. Drain the command mailbox BEFORE doing work (design §CF-2).
      drained = @mailbox.drain
      drained.each { |cmd| dispatch_command(cmd) }

      # CF-5 fix: error boundary around each work phase.
      # Exceptions in one phase must not kill the daemon.
      begin
        # 2. Chronos tick (stub in P2.1).
        chronos_tick
      rescue StandardError => e
        @logger.error('daemon_chronos_tick_failed', source: 'daemon',
                      details: { error: "#{e.class}: #{e.message}" })
      end

      begin
        # 3. Mandate queue → OODA cycle (stub in P2.1).
        run_one_ooda_cycle
      rescue StandardError => e
        @logger.error('daemon_ooda_cycle_failed', source: 'daemon',
                      details: { error: "#{e.class}: #{e.message}" })
      end

      # 4. Heartbeat.
      @logger.debug('daemon_heartbeat',
                    source: 'daemon',
                    details: { tick: @tick_count,
                               mailbox_size: @mailbox.size,
                               state: @state.to_s })
    end

    # ------------------------------------------------------------------ commands

    def dispatch_command(cmd)
      case cmd[:type]
      when :shutdown
        request_shutdown!('mailbox')
      when :reload
        handle_reload(cmd)
      when :status_dump
        handle_status_dump(cmd)
      else
        @logger.debug('daemon_command_unknown',
                      source: 'daemon',
                      details: { type: cmd[:type].to_s, id: cmd[:id] })
      end
    rescue StandardError => e
      @logger.error('daemon_command_failed',
                    source: 'daemon',
                    details: { type: cmd[:type].to_s, error: e.message })
    end

    # CF-7 fix: keep old config on reload failure instead of falling back to defaults.
    def handle_reload(_cmd)
      new_config = safe_load_config(@config_path)
      if new_config
        @config = new_config
        @tick_interval = Float(@config['tick_interval'] || DEFAULT_TICK_INTERVAL)
        @graceful_timeout = Float(@config['graceful_timeout'] || DEFAULT_GRACEFUL_TIMEOUT)
        @logger.info('daemon_config_reloaded',
                     source: 'daemon',
                     details: { tick_interval: @tick_interval })
      else
        @logger.error('daemon_config_reload_failed',
                      source: 'daemon',
                      details: { note: 'keeping previous config' })
      end
    end

    def handle_status_dump(_cmd)
      @logger.info('daemon_status',
                   source: 'daemon',
                   details: status_snapshot)
    end

    # ------------------------------------------------------------------ stubs (P2.1)

    # Chronos tick — real implementation lands in a later P2 ticket.
    # For P2.1 this is a no-op logged at debug level.
    def chronos_tick
      @logger.debug('daemon_chronos_stub', source: 'daemon')
    end

    # Mandate queue → OODA — stub for P2.1.
    def run_one_ooda_cycle
      @logger.debug('daemon_ooda_stub',
                    source: 'daemon',
                    details: { note: 'no mandates' })
    end

    # ------------------------------------------------------------------ helpers

    def status_snapshot
      {
        state: @state.to_s,
        pid: Process.pid,
        tick_count: @tick_count,
        mailbox_size: @mailbox.size,
        started_at: @started_at&.iso8601,
        shutdown_requested: @shutdown_requested,
        tick_interval: @tick_interval,
        graceful_timeout: @graceful_timeout
      }
    end

    private

    def load_config(path)
      return default_config unless File.exist?(path)

      raw = YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
      default_config.merge(raw)
    rescue StandardError => e
      warn "[kairos-daemon] Failed to load config #{path}: #{e.message}; using defaults"
      default_config
    end

    # Returns parsed config or nil on any error (for reload safety).
    def safe_load_config(path)
      return nil unless File.exist?(path)

      raw = YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
      default_config.merge(raw)
    rescue StandardError
      nil
    end

    def default_config
      {
        'tick_interval'    => DEFAULT_TICK_INTERVAL,
        'graceful_timeout' => DEFAULT_GRACEFUL_TIMEOUT,
        'pid_path'         => DEFAULT_PID_PATH,
        'mode'             => 'daemon'
      }
    end

    def resolve_path(path)
      return path if File.absolute_path?(path)

      File.expand_path(path, @root)
    end

    # CF-3 fix: Attempt Safety.build(mode: :daemon). If Safety is not
    # available or build fails, log a warning and keep @safety = nil.
    # Nil safety means deny-by-default — callers must check before use.
    def build_safety
      # Try loading safety if not already available
      require_relative 'safety' unless defined?(KairosMcp::Safety)

      if KairosMcp::Safety.respond_to?(:build)
        KairosMcp::Safety.build(mode: :daemon)
      else
        KairosMcp::Safety.new
      end
    rescue StandardError => e
      @logger.warn('daemon_safety_init_deferred',
                   source: 'daemon',
                   details: { error: e.message,
                              note: 'safety=nil means deny-by-default' })
      nil
    end
  end
end
