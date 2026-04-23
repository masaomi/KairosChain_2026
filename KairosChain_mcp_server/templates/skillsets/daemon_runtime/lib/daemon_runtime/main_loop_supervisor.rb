# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module DaemonRuntime
      # 24/7 v0.4 §2.4 — outer supervise loop.
      #
      # Step 1.2 scaffold: the loop shape + signal/reload handling are
      # wired. `enter_safe_mode`, `graceful_shutdown`, and the OODA hook
      # chain invocation are intentionally stubbed for this step — later
      # Phase 1 steps land the full implementations. Keeping the scaffold
      # observable lets us test the supervise loop's signal dispatch in
      # isolation before those subsystems exist.
      class MainLoopSupervisor
        DEFAULT_TICK_INTERVAL_SEC = 1.0

        def initialize(tick_interval: DEFAULT_TICK_INTERVAL_SEC, logger: nil)
          @tick_interval = tick_interval
          @logger = logger
          @iterations = 0
          @reloads = 0
          @diagnostics = 0
        end

        attr_reader :iterations, :reloads, :diagnostics

        # Block until `signal.shutdown_requested?` is true.
        # Cooperative: respects reload (HUP) and diagnostic (USR2) signals
        # even while the iteration body is a no-op scaffold.
        #
        # `hook_chain` is opaque to the supervisor — the SkillSet layer
        # decides what one iteration means. In scaffold, `hook_chain` is
        # nilable and the iteration is a log tick.
        def supervise(signal:, hook_chain: nil, context: nil)
          loop do
            break if signal.shutdown_requested?

            if signal.reload_requested?
              signal.clear_reload!
              @reloads += 1
              log(:info, 'config_reload_requested')
              # Step 1.3+ will rehydrate config here.
            end

            if signal.respond_to?(:diagnostic_requested?) && signal.diagnostic_requested?
              signal.clear_diagnostic!
              @diagnostics += 1
              log(:info, 'diagnostic_snapshot_requested')
              # Step 1.3+ will dump state here.
            end

            run_iteration(hook_chain, context)
            @iterations += 1

            signal.wait_or_tick(@tick_interval)
          end

          graceful_shutdown_stub(context)
        end

        private

        # Scaffold iteration — a later step replaces this with the full
        # OODA cycle + cycle-deadline + consecutive_failures → enter_safe_mode
        # branch documented in v0.4 §2.4.
        def run_iteration(hook_chain, _context)
          hook_chain&.call  # opt-in: test injection
        end

        def graceful_shutdown_stub(_context)
          log(:info, 'graceful_shutdown_stub',
              iterations: @iterations, reloads: @reloads)
        end

        def log(level, event, **fields)
          return unless @logger
          if @logger.respond_to?(level)
            @logger.public_send(level, "#{event} #{fields.inspect}")
          end
        end
      end
    end
  end
end
