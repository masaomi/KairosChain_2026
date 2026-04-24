# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Main-thread liveness state for the worker's pulse mechanism (v0.3 P0-3,
      # v0.3.2 C3b). Read by the pulse thread to decide whether worker.tick
      # should be touched; written by the main thread around each adapter.call.
      #
      # ORDERING INVARIANT (v0.3.2 C3b):
      #   exit_call! increments `counter` FIRST, clears `in_llm_call_since_mono`
      #   SECOND. A torn two-field read by the pulse thread therefore always
      #   lands in one of:
      #     (old_counter, old_ts)  — in-call, recent       → alive
      #     (new_counter, old_ts)  — counter advanced      → alive
      #     (new_counter, nil)     — exit complete         → alive via counter
      #   Never (old_counter, nil), which would look stalled.
      #
      # MRI atomicity note: integer accessor and flonum Float accessor reads
      # are each atomic via GVL-serialized method dispatch; the PAIR is not.
      # The invariant above makes pair torn reads benign.
      MAIN_STATE = Struct.new(:counter, :in_llm_call_since_mono).new(0, nil)

      module MainState
        module_function

        # Called immediately before adapter.call enters a blocking LLM syscall.
        def enter_call!
          MAIN_STATE.in_llm_call_since_mono =
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # Called in the `ensure` block around adapter.call. Must be idempotent:
        # if enter_call! never ran (e.g., exception before entry), clearing a
        # nil timestamp is a no-op and counter is still bumped so a pulse read
        # observes progress.
        def exit_call!
          MAIN_STATE.counter += 1                    # INVARIANT: counter first
          MAIN_STATE.in_llm_call_since_mono = nil    # then clear timestamp
        end

        # Read current state as a plain Array snapshot.
        #
        # READER ORDERING (mirrors writer's C3b invariant): read ts FIRST,
        # counter SECOND. If reader observes ts == nil, the writer MUST
        # already have completed counter+=1 (writer writes counter before ts).
        # Therefore (old_counter, nil) is unreachable by any reader using
        # this snapshot. The pulse thread uses this helper — do not change
        # the order without also changing the writer invariant.
        def snapshot
          ts = MAIN_STATE.in_llm_call_since_mono
          counter = MAIN_STATE.counter
          [counter, ts]
        end

        # Reset for tests. NOT safe for runtime use.
        def reset!
          MAIN_STATE.counter = 0
          MAIN_STATE.in_llm_call_since_mono = nil
        end
      end
    end
  end
end
