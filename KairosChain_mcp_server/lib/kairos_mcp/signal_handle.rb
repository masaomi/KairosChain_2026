# frozen_string_literal: true

module KairosMcp
  # Async-signal-safe signal flag bundle for the Bootstrap layer
  # (24/7 v0.4 §2.2). Carries three one-way signals (shutdown / reload /
  # diagnostic) across the signal-trap boundary.
  #
  # Async-signal safety:
  # - `shutdown` is a one-way latch — set in trap, never cleared.
  # - `reload` and `diagnostic` are edge-triggered. To avoid losing an
  #   edge when a signal arrives mid-consume, they are tracked with a
  #   ticket counter pattern (R2 Codex P1):
  #     • trap handler: `@reload_seen += 1` (increment-only)
  #     • consumer: diff = seen − consumed; consumed += diff
  #   A signal firing between the consumer's read of `seen` and its
  #   write to `consumed` is safely picked up on the next call because
  #   `consumed += diff` accumulates rather than overwriting.
  # - MRI serializes trap handlers and runs them at safepoints — no
  #   two handlers execute concurrently, and `@x += 1` in a trap is
  #   atomic with respect to the main thread (the main thread is
  #   paused while the trap runs). On JRuby/TruffleRuby, additional
  #   memory fences may be needed; this class targets MRI only for the
  #   Bootstrap layer. Richer SkillSet coordinators (see
  #   daemon_runtime §2.7 SignalCoordinator) use pipes + ConditionVariable
  #   and are runtime-portable.
  #
  # Single-consumer invariant (R3 P3, 4.6):
  # - `consume_reload!` and `consume_diagnostic!` must be called from
  #   EXACTLY ONE thread. Two concurrent consumers can both read
  #   `@reload_seen` and `@reload_consumed`, then each accumulate the
  #   same diff, double-consuming an edge or mis-ordering the `+=`. The
  #   Bootstrap layer honors this by having only MainLoop#forward_flags
  #   (a dedicated bridge thread) call these. Writers (trap handlers)
  #   may be concurrent with the consumer; that case is covered by the
  #   ticket accumulation semantics above.
  # - `shutdown_requested` is a one-way latch: trap sets true, nobody
  #   ever clears it. This asymmetry is deliberate — shutdown does not
  #   need edge semantics because it is terminal.
  class SignalHandle
    def initialize
      @shutdown_requested   = false
      @reload_seen          = 0
      @reload_consumed      = 0
      @diagnostic_seen      = 0
      @diagnostic_consumed  = 0
    end

    # --- setters (called from Signal.trap context) ---
    def request_shutdown;   @shutdown_requested = true; end
    def request_reload;     @reload_seen     += 1;      end
    def request_diagnostic; @diagnostic_seen += 1;      end

    # --- readers (non-consuming) ---
    def shutdown_requested?;   @shutdown_requested;                   end
    def reload_requested?;     @reload_seen     > @reload_consumed;   end
    def diagnostic_requested?; @diagnostic_seen > @diagnostic_consumed; end

    # Edge-safe consume: returns true if at least one signal arrived
    # since the last consume. Accumulates rather than overwrites, so a
    # trap firing mid-consume is never lost.
    def consume_reload!
      seen = @reload_seen
      diff = seen - @reload_consumed
      @reload_consumed += diff
      diff.positive?
    end

    def consume_diagnostic!
      seen = @diagnostic_seen
      diff = seen - @diagnostic_consumed
      @diagnostic_consumed += diff
      diff.positive?
    end
  end
end
