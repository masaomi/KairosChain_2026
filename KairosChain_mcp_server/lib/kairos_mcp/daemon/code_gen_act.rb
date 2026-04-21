# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'json'
require_relative 'edit_kernel'
require_relative 'scope_classifier'
require_relative 'policy_elevation'

module KairosMcp
  class Daemon
    # CodeGenAct — code generation pipeline for daemon ACT phase.
    #
    # Design (P3.2 v0.2 §9):
    #   1. plan_edit: LLM generates {old_string, new_string} via invoker
    #   2. simulate: EditKernel computes pre/post hash without I/O
    #   3. classify: ScopeClassifier determines scope
    #   4. gate: ApprovalGate stages proposal or auto-approves
    #   5. apply: CAS + EditKernel + atomic write (with elevation if L0/L1)
    #   6. record: chain_record for L0/L1
    class CodeGenAct
      class PauseForApproval     < StandardError
        attr_reader :proposal_id
        def initialize(id); super("awaiting approval: #{id}"); @proposal_id = id; end
      end
      class PreHashMismatch      < StandardError; end
      class PostHashMismatch     < StandardError; end
      class ScopeDrift           < StandardError; end
      class ProposalTampered     < StandardError; end
      class LlmContentPolicyViolation < StandardError; end

      # @param workspace_root [String]
      # @param safety [Object] Safety instance with push/pop_policy_override
      # @param invoker [#call] callable: (tool_name, args) → result Hash
      # @param approval_gate [ApprovalGate]
      # @param chain_recorder [#call, nil] callable: (payload) → tx_id
      # @param logger [Object, nil]
      def initialize(workspace_root:, safety:, invoker:,
                     approval_gate:, chain_recorder: nil, logger: nil)
        @ws       = workspace_root
        @safety   = safety
        @invoker  = invoker
        @gate     = approval_gate
        @chain    = chain_recorder
        @logger   = logger
      end

      # Run the code-gen pipeline for a single edit.
      #
      # @param decision [Hash] from DECIDE phase: { action:, target:, intent:, ... }
      # @param mandate [Hash] current mandate
      # @return [Hash] ACT result
      def run(decision, mandate)
        target_path = decision[:target] || decision['target']
        abs = File.expand_path(target_path, @ws)

        # Scope classification
        scope_info = ScopeClassifier.classify(abs, workspace_root: @ws)

        # LLM content policy check
        check_llm_content_policy!(scope_info, mandate)

        # Read file and simulate
        content = File.binread(abs)
        plan = extract_edit_plan(decision)
        result = EditKernel.compute(content,
                                    old_string:  plan[:old_string],
                                    new_string:  plan[:new_string],
                                    replace_all: plan[:replace_all])

        # Build proposal
        proposal_id = "prop_#{SecureRandom.hex(8)}"
        proposal = {
          proposal_id: proposal_id,
          mandate_id:  mandate[:id] || mandate['id'],
          target: {
            path:     target_path,
            pre_hash: result[:pre_hash]
          },
          edit: {
            old_string:         plan[:old_string],
            new_string:         plan[:new_string],
            replace_all:        plan[:replace_all],
            proposed_post_hash: result[:post_hash]
          },
          scope: scope_info
        }

        # Gate
        if scope_info[:auto_approve]
          @gate.auto_approve(proposal)
          grant = @gate.consume_grant(proposal_id)
          apply_with_grant(proposal, grant, abs)
        else
          @gate.stage(proposal)
          grant = @gate.consume_grant(proposal_id)
          raise PauseForApproval, proposal_id if grant.nil?
          apply_with_grant(proposal, grant, abs)
        end
      end

      # Re-entry after pause.
      # @return [Hash, :still_pending]
      def resume(proposal_id)
        status = @gate.status_of(proposal_id)
        return :rejected if status == :rejected
        return :expired  if status == :expired
        return :not_found if status == :not_found

        grant = @gate.consume_grant(proposal_id)
        return :still_pending if grant.nil?

        # Verify proposal integrity only after approval (decision exists)
        unless @gate.verify_proposal_integrity(proposal_id)
          raise ProposalTampered, "integrity check failed: #{proposal_id}"
        end

        proposal = symbolize_proposal(grant.proposal)
        abs = File.expand_path(proposal[:target][:path], @ws)
        apply_with_grant(proposal, grant, abs)
      end

      private

      def apply_with_grant(proposal, grant, abs)
        scope = proposal[:scope][:scope].to_sym

        if scope == :l2
          perform_apply(proposal, abs)
        else
          granted_by = grant.decision['reviewer']
          granted_by = granted_by.start_with?('policy:') ? granted_by : "human:#{granted_by}" rescue granted_by
          PolicyElevation.with_elevation(
            @safety, scope: scope,
            proposal_id: proposal[:proposal_id],
            granted_by: granted_by, logger: @logger
          ) do
            perform_apply(proposal, abs)
          end
        end
      end

      def perform_apply(proposal, abs)
        target = proposal[:target]
        edit   = proposal[:edit]

        # CAS: read + verify pre_hash BEFORE write.
        # NOTE: Single-threaded daemon assumption — no concurrent writer between
        # binread and atomic_write (rename). See policy_elevation.rb §Design.
        content = File.binread(abs)
        current_hash = EditKernel.hash_bytes(content)
        raise PreHashMismatch, "expected #{target[:pre_hash]}, got #{current_hash}" \
          unless current_hash == target[:pre_hash]

        # Compute via shared EditKernel
        result = EditKernel.compute(content,
                                    old_string:  edit[:old_string],
                                    new_string:  edit[:new_string],
                                    replace_all: edit[:replace_all])

        raise PostHashMismatch, "expected #{edit[:proposed_post_hash]}, got #{result[:post_hash]}" \
          unless result[:post_hash] == edit[:proposed_post_hash]

        # Re-classify scope to catch TOCTOU drift
        re_scope = ScopeClassifier.classify(abs, workspace_root: @ws)
        proposal_scope = proposal[:scope][:scope].to_sym
        raise ScopeDrift, "was #{proposal_scope}, now #{re_scope[:scope]}" \
          unless re_scope[:scope] == proposal_scope

        # Atomic write
        atomic_write(abs, result[:new_content])

        # Chain record for L0/L1
        chain_record_if_needed(proposal, result)

        {
          status: 'applied',
          proposal_id: proposal[:proposal_id],
          pre_hash: target[:pre_hash],
          post_hash: result[:post_hash],
          scope: proposal[:scope][:scope].to_sym
        }
      end

      def chain_record_if_needed(proposal, result)
        scope = proposal[:scope][:scope].to_sym
        return unless %i[l0 l1].include?(scope)
        return unless @chain

        @chain.call(
          type: 'code_edit',
          scope: scope.to_s,
          proposal_id: proposal[:proposal_id],
          target: { path: proposal[:target][:path] },
          pre_hash: proposal[:target][:pre_hash],
          post_hash: result[:post_hash]
        )
      end

      def check_llm_content_policy!(scope_info, mandate)
        allowed = Array(mandate[:allow_llm_upload] || mandate['allow_llm_upload'] || ['l2'])
        scope_str = scope_info[:scope].to_s
        return if allowed.include?(scope_str)

        raise LlmContentPolicyViolation,
              "scope #{scope_str} not in allow_llm_upload: #{allowed.inspect}"
      end

      def extract_edit_plan(decision)
        {
          old_string:  decision[:old_string]  || decision['old_string'],
          new_string:  decision[:new_string]  || decision['new_string'],
          replace_all: decision[:replace_all] || decision['replace_all'] || false
        }
      end

      def atomic_write(path, content)
        dir = File.dirname(path)
        tmp = File.join(dir, ".#{File.basename(path)}.tmp.#{SecureRandom.hex(8)}")
        File.open(tmp, 'wb') do |f|
          f.write(content)
          f.flush
          f.fsync rescue nil
        end
        begin
          File.chmod(File.stat(path).mode, tmp)
        rescue StandardError
          # best-effort
        end
        File.rename(tmp, path)
      ensure
        File.unlink(tmp) if tmp && File.exist?(tmp)
      end

      def symbolize_proposal(hash)
        return hash if hash.is_a?(Hash) && hash.keys.first.is_a?(Symbol)

        result = {}
        hash.each do |k, v|
          result[k.to_sym] = v.is_a?(Hash) ? symbolize_proposal(v) : v
        end
        result
      end
    end
  end
end
