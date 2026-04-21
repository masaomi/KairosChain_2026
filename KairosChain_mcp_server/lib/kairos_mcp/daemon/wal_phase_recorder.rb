# frozen_string_literal: true

require_relative 'canonical'

module KairosMcp
  class Daemon
    # WalPhaseRecorder — around_phase callback for CognitiveLoop.
    #
    # Design (v0.2 P3.0):
    #   CognitiveLoop exposes an `around_phase` callback hook. This
    #   recorder records the executing→completed transition in the WAL
    #   around each phase, so a crash anywhere inside the phase leaves
    #   the WAL with a recoverable "executing" marker.
    #
    # Ordering invariant:
    #   wal.mark_executing(step_id, pre_hash:)        # before phase body
    #   result = yield                                # phase body
    #   wal.mark_completed(step_id, post_hash:,       # after phase body
    #                      result_hash:)
    #
    # On exception, the phase is recorded as failed (error_class,
    # error_msg), and the exception is re-raised. Recovery treats failed
    # steps as final (no retry) — a higher-level retry policy is
    # CognitiveLoop's concern, not the recorder's.
    #
    # Step id derivation:
    #   format('%s_%03d', phase, cycle)  — mirrors Planner.step_id_for.
    #   Kept duplicated here (not require'd from Planner) to avoid a
    #   runtime dep between recorder and planner: each can be exercised
    #   alone in tests.
    class WalPhaseRecorder
      def initialize(wal:, cycle: 1)
        raise ArgumentError, 'wal is required' if wal.nil?

        @wal   = wal
        @cycle = Integer(cycle)
      end

      attr_reader :cycle

      # Wrap a phase body. `phase` is a Symbol or String
      # (:observe/:orient/:decide/:act/:reflect). Returns the block's
      # return value on success; re-raises on failure.
      def around_phase(phase)
        step_id  = step_id_for(phase)
        pre_hash = Canonical.sha256_json(marker(phase, 'pre'))
        @wal.mark_executing(step_id, pre_hash: pre_hash)

        begin
          result = block_given? ? yield : nil
        rescue StandardError => e
          @wal.mark_failed(step_id,
                           error_class: e.class.name,
                           error_msg:   e.message.to_s)
          raise
        end

        post_hash   = Canonical.sha256_json(marker(phase, 'post'))
        result_hash = Canonical.sha256_json(safe_result(result))
        @wal.mark_completed(step_id,
                            post_hash:   post_hash,
                            result_hash: result_hash)
        result
      end

      # Expose step-id derivation so tests can verify recorded ids.
      def step_id_for(phase)
        format('%s_%03d', phase.to_s, @cycle)
      end

      private

      def marker(phase, state)
        { phase: phase.to_s, cycle: @cycle, state: state }
      end

      # Canonicalize a phase result for hashing. We accept only
      # JSON-representable types directly; anything else is summarized so
      # Canonical doesn't raise on opaque objects.
      def safe_result(result)
        case result
        when Hash, Array, String, Numeric, TrueClass, FalseClass, NilClass
          result
        else
          { class: result.class.name, to_s: result.to_s[0, 200] }
        end
      end
    end
  end
end
