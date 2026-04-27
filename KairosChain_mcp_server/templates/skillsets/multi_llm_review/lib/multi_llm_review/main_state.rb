# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # ──────────────────────────────────────────────────────────────────
      # MainState — main-thread liveness state for the worker pulse
      # ──────────────────────────────────────────────────────────────────
      #
      # Tracks per-thread enter/exit timestamps so the pulse thread can tell
      # whether the worker's main path is still progressing through LLM calls.
      # Replaces the v0.3.2 process-global single-ts design which raced under
      # parallel reviewer threads (incident token 5b75ff8c-..., 2026-04-27).
      #
      # ORDERING / ATOMICITY INVARIANTS (v3.24.3):
      #
      # 1. counter and ts_by_thread mutations AND reads are bracketed by a
      #    single Mutex (MUTEX). Readers (snapshot) take the same mutex, so
      #    they never observe a torn (counter, ts_by_thread) pair.
      #    Replaces the v0.3.2 "ts-first/counter-second" ordering invariant
      #    which assumed single-threaded callers.
      #
      # 2. with_call { ... } is the ONLY supported call-bracketing pattern.
      #    Direct enter_call!/exit_call! calls are private (see
      #    private_class_method below). This guarantees that any exception
      #    from the LLM call propagates AFTER ts_by_thread has been cleaned
      #    up (via `ensure exit_call!`), preventing per-thread entry leaks.
      #
      # 3. Thread.current.object_id is used as the per-thread key. MRI's
      #    object_id stays stable for the lifetime of a Thread object;
      #    reuse only happens after the Thread has been GC'd. Within a
      #    single with_call invocation, the Thread is on-stack and therefore
      #    not GC-eligible, so the key is unique.
      #
      # 4. Mutex#synchronize is Thread.kill-safe under MRI (Ruby's internal
      #    `ensure unlock`). The `ensure exit_call!` inside with_call also
      #    runs under Thread.kill, so cleanup is guaranteed even if the
      #    dispatch thread is forcibly terminated.
      #
      # 5. NON-REENTRANT: nested with_call on the same thread is NOT
      #    supported. The inner enter_call! would overwrite the outer
      #    ts_by_thread[tid], and the outer ensure exit_call! would delete
      #    the entry while the inner call is still tracked. Current
      #    multi_llm_review code paths never nest LLM calls; if a future
      #    adapter calls another LLM, this contract must be revisited.
      MAIN_STATE = Struct.new(:counter, :ts_by_thread).new(0, {})
      MUTEX = Mutex.new

      module MainState
        module_function

        # PUBLIC: bracket an LLM call. The block runs between enter_call!
        # and exit_call!; ensure guarantees exit_call! even on exception or
        # Thread.kill. Returns the value of the block.
        def with_call
          enter_call!
          yield
        ensure
          exit_call!
        end

        # PUBLIC: counter-only progress signal. Used by dispatcher's join
        # cleanup loop where there is no LLM call in flight but the main
        # thread is still doing useful work (joining worker threads). Does
        # NOT touch ts_by_thread.
        def bump_counter!
          MUTEX.synchronize { MAIN_STATE.counter += 1 }
        end

        # PUBLIC: snapshot of current state. Returns (counter, in_flight,
        # oldest_ts). in_flight = ts_by_thread.size; oldest_ts = min of
        # in-flight ts (nil if idle). Always atomic via MUTEX.
        def snapshot
          MUTEX.synchronize do
            ts_values = MAIN_STATE.ts_by_thread.values
            [MAIN_STATE.counter, ts_values.size, ts_values.min]
          end
        end

        # PUBLIC PURE FUNCTION: determine alive state from a snapshot
        # tuple. Extracted so unit tests can table-drive the four branches
        # without forking a worker. The pulse thread calls this with the
        # result of snapshot().
        def compute_alive(counter, last_counter, in_flight, oldest_ts, now_mono, threshold_seconds)
          if counter != last_counter
            true                                                  # progress observed
          elsif in_flight > 0 && oldest_ts
            (now_mono - oldest_ts) < threshold_seconds            # in-call, recent
          elsif in_flight > 0
            true                                                  # in-call but ts not visible (transient)
          else
            false                                                 # idle, no progress
          end
        end

        # TEST API: clear all state. NOT safe for runtime use.
        def reset!
          MUTEX.synchronize do
            MAIN_STATE.counter = 0
            MAIN_STATE.ts_by_thread.clear
          end
        end

        # ── private (do not call from outside MainState; use with_call) ──

        def enter_call!
          tid = Thread.current.object_id
          MUTEX.synchronize do
            MAIN_STATE.ts_by_thread[tid] =
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
        private_class_method :enter_call!

        def exit_call!
          tid = Thread.current.object_id
          MUTEX.synchronize do
            MAIN_STATE.counter += 1
            MAIN_STATE.ts_by_thread.delete(tid)
          end
        end
        private_class_method :exit_call!
      end
    end
  end
end
