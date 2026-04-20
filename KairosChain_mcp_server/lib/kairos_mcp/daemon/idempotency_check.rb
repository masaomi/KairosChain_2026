# frozen_string_literal: true

require_relative 'wal'

module KairosMcp
  class Daemon
    # IdempotencyCheck — classify a WAL step for crash-recovery [FIX: CF-1, CF-7].
    #
    # Given a `WAL::StepEntry` that recovery rebuilt from the WAL, decide
    # whether the step:
    #
    #   :already_done   — side effects landed; treat as completed, do NOT retry.
    #   :safe_to_retry  — no side effects observable; retry is safe.
    #   :manual_review  — ambiguous; pause the mandate and ask a human.
    #
    # Decision inputs:
    #
    #   step_entry.pre_hash           : expected world state before exec (DECIDE)
    #   step_entry.expected_post_hash : expected world state after exec  (DECIDE)
    #   step_entry.observed_pre_hash  : world state at mark_executing    (ACT)
    #   step_entry.post_hash          : world state at mark_completed    (ACT)
    #   step_entry.status             : last transition status
    #   current_pre_hash (optional)   : world state *now*, at recovery time
    #   current_post_hash (optional)  : world state *now*, at recovery time
    #
    # Priority order (highest wins):
    #
    #   1. WAL already recorded `status == 'completed'` (post_hash present)
    #        → :already_done (evidence: wal_recorded_completion)
    #
    #   2. Current world state matches expected_post_hash
    #        → :already_done (evidence: current_state_matches_expected_post)
    #      [The step ran, its side effects landed, but the WAL transition
    #       didn't get flushed before crash.]
    #
    #   3. No executing transition was ever recorded (observed_pre_hash is nil)
    #      AND status is not 'executing' / 'completed'
    #        → :safe_to_retry (evidence: never_reached_executing)
    #
    #   4. Current world state matches the DECIDE-phase pre_hash (world is
    #      still what we expected before running)
    #        → :safe_to_retry (evidence: current_pre_matches_expected)
    #      [We know nothing changed; retry with the same idem_key is fine.]
    #
    #   5. Anything else — status 'executing' with divergent current state,
    #      post_hash absent, no way to tell whether side effects partially
    #      landed — :manual_review.
    #
    # The module deliberately does NOT touch the filesystem; callers supply
    # the current_* hashes (or pass nil and let the module decide from WAL
    # data alone).
    module IdempotencyCheck
      Verdict = Struct.new(:kind, :post_hash, :evidence, keyword_init: true)

      VALID_KINDS = %i[already_done safe_to_retry manual_review].freeze

      module_function

      # @param step_entry [WAL::StepEntry]
      # @param current_pre_hash  [String, nil] world state at recovery time
      # @param current_post_hash [String, nil] world state at recovery time
      # @return [Verdict]
      def verify(step_entry, current_pre_hash: nil, current_post_hash: nil)
        # 1. WAL says the step completed — trust it.
        if step_entry.post_hash && !step_entry.post_hash.to_s.empty?
          return Verdict.new(
            kind: :already_done,
            post_hash: step_entry.post_hash,
            evidence: { reason: 'wal_recorded_completion',
                        result_hash: step_entry.result_hash }
          )
        end

        # 2. Crash between side effect and WAL flush: world matches expected.
        if step_entry.expected_post_hash &&
           current_post_hash &&
           current_post_hash == step_entry.expected_post_hash
          return Verdict.new(
            kind: :already_done,
            post_hash: current_post_hash,
            evidence: { reason: 'current_state_matches_expected_post' }
          )
        end

        status = step_entry.status.to_s

        # R1-02 fix: steps explicitly marked needs_review must stay manual_review.
        if status == 'needs_review'
          return Verdict.new(
            kind: :manual_review,
            post_hash: nil,
            evidence: { reason: 'explicitly_marked_needs_review', status: status }
          )
        end

        # 3. Never reached executing — pending or failed — safe retry.
        if step_entry.observed_pre_hash.nil? &&
           status != 'executing' &&
           status != 'completed'
          return Verdict.new(
            kind: :safe_to_retry,
            post_hash: nil,
            evidence: { reason: 'never_reached_executing', status: status }
          )
        end

        # 4. World still matches the pre-state we expected.
        if step_entry.pre_hash &&
           current_pre_hash &&
           current_pre_hash == step_entry.pre_hash
          return Verdict.new(
            kind: :safe_to_retry,
            post_hash: nil,
            evidence: { reason: 'current_pre_matches_expected' }
          )
        end

        # 5. Ambiguous: executing started, state diverged, no post_hash.
        Verdict.new(
          kind: :manual_review,
          post_hash: nil,
          evidence: {
            reason: 'interrupted_during_execution',
            status: status,
            observed_pre_hash: step_entry.observed_pre_hash,
            expected_pre_hash: step_entry.pre_hash
          }
        )
      end
    end
  end
end
