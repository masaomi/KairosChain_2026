# frozen_string_literal: true

require_relative 'code_gen_act'

module KairosMcp
  class Daemon
    # CodeGenPhaseHandler — bridges CodeGenAct into the CognitiveLoop ACT phase.
    #
    # Design (P3.2 v0.2 §4.5, M6):
    #   When CognitiveLoop's DECIDE phase produces a code_edit decision,
    #   the ACT phase delegates to CodeGenAct. If PauseForApproval is raised,
    #   the handler catches it and returns a paused result so the WAL recorder
    #   can mark the step as paused (not failed, not completed).
    #
    #   On subsequent cycles, the handler's `resume_if_pending` is called
    #   before a new OODA cycle begins, checking whether any pending proposal
    #   has been approved.
    class CodeGenPhaseHandler
      PAUSED_STATUS = 'paused_awaiting_approval'

      attr_reader :pending_proposal_id

      def initialize(code_gen_act:, wal_phase_recorder: nil)
        @cga = code_gen_act
        @wpr = wal_phase_recorder
        @pending_proposal_id = nil
      end

      # Execute the ACT phase for a code_edit decision.
      #
      # @param decision [Hash] DECIDE output with action: 'code_edit'
      # @param mandate [Hash]
      # @return [Hash] { status: 'applied'|'paused_awaiting_approval'|... }
      def handle_act(decision, mandate)
        @cga.run(decision, mandate)
      rescue CodeGenAct::PauseForApproval => e
        @pending_proposal_id = e.proposal_id
        mark_wal_paused(e.proposal_id)
        { status: PAUSED_STATUS, proposal_id: e.proposal_id }
      end

      # Check if a pending proposal has been resolved. Call at cycle start.
      #
      # @return [Hash, :still_pending, :rejected, :expired, nil]
      #   nil if no pending proposal
      def resume_if_pending
        return nil unless @pending_proposal_id

        result = @cga.resume(@pending_proposal_id)
        case result
        when Hash
          # Applied successfully
          @pending_proposal_id = nil
          result
        when :rejected, :expired, :not_found
          pid = @pending_proposal_id
          @pending_proposal_id = nil
          { status: result.to_s, proposal_id: pid }
        when :still_pending
          :still_pending
        else
          result
        end
      end

      # True if there's a pending proposal awaiting human approval.
      def paused?
        !@pending_proposal_id.nil?
      end

      private

      def mark_wal_paused(proposal_id)
        return unless @wpr

        step_id = @wpr.step_id_for(:act)
        @wpr.instance_variable_get(:@wal)&.mark_paused(
          step_id,
          reason: 'awaiting_approval',
          proposal_id: proposal_id
        )
      rescue StandardError
        # WAL paused marker is best-effort — must not crash the cycle
      end
    end
  end
end
