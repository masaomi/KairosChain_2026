# frozen_string_literal: true

require 'kairos_mcp/lifecycle_hook'

module KairosMcp
  module SkillSets
    module DaemonRuntime
      # LifecycleHook implementation for `daemon_main` (24/7 v0.4 §2.2).
      #
      # Bridges the Bootstrap `SignalHandle` flags (scalar booleans set in
      # trap context) to the SkillSet-internal `SignalCoordinator` (which
      # provides the pump-thread + ConditionVariable wait semantics the
      # supervise loop needs).
      #
      # R1 fixes applied:
      # - P1: bridge no longer spins on `sleep 0.05`. It wakes on the
      #   coordinator's own interval (tick_interval, defaults to 1s but
      #   overridable in tests), forwards any raised SignalHandle flags,
      #   and exits promptly on shutdown.
      # - P2: supervise errors rescued and logged; bridge thread is
      #   joined (no Thread#kill) via an atomic stop flag.
      class MainLoop
        include KairosMcp::LifecycleHook

        BRIDGE_POLL_SEC = 0.2

        def run_main_loop(registry:, signal:, tick_interval: nil, logger: nil)
          coordinator = SignalCoordinator.new(logger: logger)
          supervisor_args = { logger: logger }
          supervisor_args[:tick_interval] = tick_interval if tick_interval
          supervisor = MainLoopSupervisor.new(**supervisor_args)

          bridge_stop = BridgeStopFlag.new
          bridge_thread = Thread.new do
            Thread.current.name = 'bootstrap-signal-bridge'
            until bridge_stop.raised?
              forward_flags(signal, coordinator)
              break if signal.shutdown_requested?
              sleep BRIDGE_POLL_SEC
            end
            # R3→R4 (Codex P1 / 4.6 P2 / 4.7 P2): ALWAYS re-check shutdown
            # after the loop and forward again. A SIGTERM firing between
            # forward_flags() returning and `break if shutdown_requested?`
            # would otherwise never reach the coordinator. trap_signal is
            # idempotent — forwarding twice is harmless.
            coordinator.trap_signal('TERM') if signal.shutdown_requested?
          end

          begin
            supervisor.supervise(signal: coordinator,
                                 context: { registry: registry })
          rescue => e
            logger&.error("main_loop_supervise_error #{e.class}: #{e.message}")
            raise
          ensure
            bridge_stop.raise!
            bridge_thread&.join(3)  # give bridge a chance to exit cleanly
            coordinator.stop
          end

          {
            iterations:  supervisor.iterations,
            reloads:     supervisor.reloads,
            diagnostics: supervisor.diagnostics
          }
        end

        private

        def forward_flags(signal, coordinator)
          coordinator.trap_signal('HUP')  if signal.consume_reload!
          coordinator.trap_signal('USR2') if signal.consume_diagnostic!
          # Shutdown is one-way; forward on every observation so a missed
          # pipe write is still delivered on the next iteration.
          coordinator.trap_signal('TERM') if signal.shutdown_requested?
        end
      end

      # Tiny one-way flag for bridge-thread termination.
      class BridgeStopFlag
        def initialize; @raised = false; end
        def raise!; @raised = true; end
        def raised?; @raised; end
      end
    end
  end
end
