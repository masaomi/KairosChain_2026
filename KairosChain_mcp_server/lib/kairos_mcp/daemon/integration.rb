# frozen_string_literal: true

require_relative 'heartbeat'
require_relative 'budget'

module KairosMcp
  class Daemon
    # Integration — the glue that turns the P2.1 Daemon skeleton into a
    # fully-wired P2.8 daemon.
    #
    # This module does NOT modify Daemon source. Instead it uses
    # `define_singleton_method` on a daemon instance to replace the
    # `chronos_tick` and `run_one_ooda_cycle` stubs with real behavior,
    # and to attach a handful of accessor methods used by Heartbeat.
    #
    # Design (v0.2 P2.8 §7):
    #   chronos_tick (wired)
    #     → chronos.tick(now) → enqueue_mandate for each FiredEvent
    #       (records rejections + missed in the chronos object itself).
    #
    #   run_one_ooda_cycle (wired)
    #     1. budget.reset_if_new_day!
    #     2. if budget.exceeded? → log + return (mandate stays queued)
    #     3. pop a mandate from chronos.queue
    #     4. register_running + open WAL (if wal_dir) + call cycle_runner
    #     5. record LLM usage reported by cycle_runner into budget + save
    #     6. emit heartbeat (rate-limited)
    #     7. unregister_running
    #
    #   AttachServer is started on wire! (if provided) and stopped when
    #   the daemon stops. AttachServer's :shutdown command flows through
    #   daemon.mailbox → dispatch_command → request_shutdown! — no new
    #   plumbing needed.
    #
    # The `cycle_runner` is a callable that takes a mandate hash and
    # returns a Hash like:
    #   { status: 'ok'|'paused'|'error',
    #     llm_calls: 1, input_tokens: 123, output_tokens: 456 }
    # Real wiring points at CognitiveLoop; tests inject a stub.
    module Integration
      module_function

      # Wire components onto a Daemon instance. Returns the daemon.
      #
      # Required:
      #   daemon    — a KairosMcp::Daemon (or duck-typed equivalent)
      #   chronos   — Chronos instance
      #
      # Optional:
      #   budget         — Budget instance (a disabled stub is used if nil)
      #   heartbeat      — Heartbeat instance (also optional)
      #   attach_server  — AttachServer instance; started on wire!
      #   wal_dir        — directory for per-mandate WAL files
      #   cycle_runner   — ->(mandate) { ... } — stubbable cycle executor
      #   clock          — ->{ Time } — injected clock for heartbeat cadence
      #   heartbeat_interval — seconds between heartbeats (default 10)
      def wire!(daemon,
                chronos:,
                budget: nil,
                heartbeat: nil,
                attach_server: nil,
                wal_dir: nil,
                cycle_runner: nil,
                usage_accumulator: nil,
                clock: nil,
                heartbeat_interval: Heartbeat::DEFAULT_INTERVAL)
        clock ||= -> { Time.now.utc }

        state = State.new(
          chronos: chronos,
          budget: budget,
          heartbeat: heartbeat,
          attach_server: attach_server,
          wal_dir: wal_dir,
          cycle_runner: cycle_runner,
          usage_accumulator: usage_accumulator,
          clock: clock,
          heartbeat_interval: heartbeat_interval
        )

        attach_accessors!(daemon, state)
        override_chronos_tick!(daemon, state)
        override_run_one_ooda_cycle!(daemon, state)

        # Start attach server after the daemon is in :running state.
        # Caller decides when to call wire! — it's expected AFTER daemon.start!
        attach_server&.start if attach_server && !attach_server_started?(attach_server)

        daemon
      end

      # Tear down integration resources. Safe to call during stop!.
      def unwire!(daemon)
        state = daemon.instance_variable_get(:@integration_state)
        return unless state

        state.attach_server&.stop if state.attach_server
        state.current_wal&.close if state.current_wal.respond_to?(:close)
        daemon.remove_instance_variable(:@integration_state)
      rescue StandardError
        # Teardown must not raise.
      end

      # --------------------------------------------------------------- internals

      # All wiring state lives on this Struct so tests can introspect.
      State = Struct.new(
        :chronos, :budget, :heartbeat, :attach_server,
        :wal_dir, :cycle_runner, :clock, :heartbeat_interval,
        :active_mandate_id, :last_cycle_at, :last_heartbeat_at,
        :current_wal,
        :usage_accumulator,  # P4.1: shared UsageAccumulator for partial-usage recovery
        keyword_init: true
      )

      def self.attach_accessors!(daemon, state)
        daemon.instance_variable_set(:@integration_state, state)

        daemon.define_singleton_method(:integration_state) { @integration_state }

        daemon.define_singleton_method(:active_mandate_id) do
          @integration_state&.active_mandate_id
        end

        daemon.define_singleton_method(:last_cycle_at) do
          @integration_state&.last_cycle_at
        end

        daemon.define_singleton_method(:queue_depth) do
          s = @integration_state
          s && s.chronos ? s.chronos.queue.size : 0
        end
      end

      def self.override_chronos_tick!(daemon, state)
        daemon.define_singleton_method(:chronos_tick) do
          s = @integration_state
          return unless s && s.chronos

          now = s.clock.call
          events = s.chronos.tick(now)
          events.each do |ev|
            # Chronos#enqueue_mandate takes a positional Hash.
            result = s.chronos.enqueue_mandate(
              { schedule: ev.schedule, mandate: ev.mandate }
            )
            if result == :rejected && s.chronos.respond_to?(:rollback_fire)
              s.chronos.rollback_fire(ev.name)
            end
          end
        end
      end

      def self.override_run_one_ooda_cycle!(daemon, state)
        daemon.define_singleton_method(:run_one_ooda_cycle) do
          s = @integration_state
          return unless s

          # 1. Roll the budget over if the day changed.
          s.budget&.reset_if_new_day!

          # 2. Budget gate — pause rather than pop the mandate.
          if s.budget&.exceeded?
            @logger&.warn('daemon_budget_exceeded',
                          source: 'daemon',
                          details: { limit: s.budget.limit,
                                     calls: s.budget.llm_calls })
            KairosMcp::Daemon::Integration.emit_heartbeat(self, s)
            return
          end

          mandate = s.chronos&.pop_queued
          unless mandate
            KairosMcp::Daemon::Integration.emit_heartbeat(self, s)
            return
          end

          mandate_id = mandate[:id] || mandate[:name]
          # Chronos#unregister_running filters by :id — make sure it's set.
          mandate[:id] ||= mandate_id
          s.active_mandate_id = mandate_id
          s.chronos.register_running(mandate) if s.chronos.respond_to?(:register_running)

          wal = KairosMcp::Daemon::Integration.maybe_open_wal(s, mandate_id)
          s.current_wal = wal

          begin
            result = KairosMcp::Daemon::Integration.invoke_cycle_runner(s, mandate)
            KairosMcp::Daemon::Integration.apply_usage(s, result)
          rescue StandardError => e
            partial = KairosMcp::Daemon::Integration.partial_usage_from_accumulator(s)

            if KairosMcp::Daemon::Integration.shutdown_error?(e)
              # P4.1: Shutdown mid-cycle — apply partial usage, don't log as error
              partial[:status] = 'interrupted'
              @logger&.info('daemon_cycle_interrupted',
                            source: 'daemon',
                            details: { mandate: mandate_id, usage: partial })
            else
              # P4.1: Recover partial usage even on failure
              partial[:status] = 'error'
              @logger&.error('daemon_cycle_runner_failed',
                             source: 'daemon',
                             details: { mandate: mandate_id,
                                        error: "#{e.class}: #{e.message}" })
            end
            KairosMcp::Daemon::Integration.apply_usage(s, partial)
          ensure
            s.current_wal = nil
            s.last_cycle_at = s.clock.call
            s.active_mandate_id = nil
            if s.chronos.respond_to?(:unregister_running)
              s.chronos.unregister_running(mandate_id)
            end
            KairosMcp::Daemon::Integration.emit_heartbeat(self, s)
          end
        end
      end

      # Called from the overridden methods — keep them small and delegate here.

      def self.maybe_open_wal(state, mandate_id)
        return nil unless state.wal_dir && mandate_id

        # Lazy-require WAL so unit tests that don't exercise WAL don't pay
        # the cost of loading Zlib / Canonical.
        require_relative 'wal' unless defined?(KairosMcp::Daemon::WAL)
        path = File.join(state.wal_dir, "#{mandate_id}.wal.jsonl")
        KairosMcp::Daemon::WAL.open(path: path)
      rescue StandardError
        nil
      end

      def self.invoke_cycle_runner(state, mandate)
        return default_cycle_result unless state.cycle_runner

        r = state.cycle_runner.call(mandate)
        r.is_a?(Hash) ? r : default_cycle_result
      end

      def self.default_cycle_result
        { status: 'ok', llm_calls: 0, input_tokens: 0, output_tokens: 0 }
      end

      # P4.1: Check if an error is a shutdown request without hard-coupling
      # to DaemonLlmCaller (which may not be loaded in test environments).
      def self.shutdown_error?(error)
        return true if defined?(KairosMcp::Daemon::DaemonLlmCaller::ShutdownRequested) &&
                        error.is_a?(KairosMcp::Daemon::DaemonLlmCaller::ShutdownRequested)
        false
      end

      # P4.1: Extract partial usage from the shared UsageAccumulator.
      # Used on exception paths (ShutdownRequested, LlmCallError) to ensure
      # partial LLM spend is still recorded into Budget.
      def self.partial_usage_from_accumulator(state)
        ua = state.usage_accumulator
        if ua && ua.respond_to?(:to_h)
          ua.to_h  # { llm_calls:, input_tokens:, output_tokens: }
        else
          { llm_calls: 0, input_tokens: 0, output_tokens: 0 }
        end
      end

      def self.apply_usage(state, result)
        return unless state.budget && result

        state.budget.record_usage(
          input_tokens:  Integer(result[:input_tokens]  || result['input_tokens']  || 0),
          output_tokens: Integer(result[:output_tokens] || result['output_tokens'] || 0),
          calls:         Integer(result[:llm_calls]     || result['llm_calls']     || 0)
        )
        state.budget.save
      end

      def self.emit_heartbeat(daemon, state)
        return unless state.heartbeat

        state.last_heartbeat_at = state.heartbeat.emit_if_due(
          daemon,
          state.last_heartbeat_at,
          interval: state.heartbeat_interval
        )
      end

      def self.attach_server_started?(attach_server)
        attach_server.respond_to?(:port) && !attach_server.port.nil?
      rescue StandardError
        false
      end
    end
  end
end
