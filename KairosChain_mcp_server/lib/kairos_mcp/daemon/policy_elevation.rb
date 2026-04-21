# frozen_string_literal: true

require_relative 'elevation_token'
require_relative 'execution_context'

module KairosMcp
  class Daemon
    # PolicyElevation — temporary, single-shot policy override for daemon code-gen.
    #
    # Design (P3.2 v0.2 §5, MF2+MF5 fix):
    #   - Nest check BEFORE push (R2 residual: prevent override leak on ElevationNestError)
    #   - Opaque ElevationToken with object identity comparison
    #   - Single-threaded daemon assumption (documented)
    #
    # NOTE: This module operates on a Safety-like object that supports
    # push_policy_override / pop_policy_override. In the daemon context,
    # DaemonPolicy installs deny-by-default policies on Safety. PolicyElevation
    # temporarily overrides them for a single approved proposal.
    module PolicyElevation
      class ElevationNestError < StandardError; end

      CAPABILITY_MAP = {
        l0: :can_modify_l0,
        l1: :can_modify_l1
      }.freeze

      # @param safety [Object] must respond to push_policy_override(cap, &block) / pop_policy_override(cap)
      # @param scope [Symbol] :l0 or :l1
      # @param proposal_id [String]
      # @param granted_by [String] e.g. 'human:masa' or 'policy:auto_approve'
      # @param logger [Object, nil]
      # @yield [ElevationToken] the opaque grant
      # @return [Object] block's return value
      def self.with_elevation(safety, scope:, proposal_id:, granted_by:, logger: nil)
        cap = CAPABILITY_MAP[scope]
        raise ArgumentError, "scope #{scope} does not require elevation" unless cap

        # R2 fix: nest check BEFORE push to prevent override leak
        if ExecutionContext.current_elevation_token
          raise ElevationNestError, 'nested elevation forbidden'
        end

        token = ElevationToken.new(
          proposal_id: proposal_id,
          scope: scope,
          granted_by: granted_by
        )

        safety.push_policy_override(cap) do |_user|
          active = ExecutionContext.current_elevation_token
          active&.matches?(token) || false
        end

        ExecutionContext.current_elevation_token = token
        log(logger, :info, "elevation_granted proposal=#{proposal_id} scope=#{scope} by=#{granted_by}")

        begin
          yield token
        ensure
          ExecutionContext.current_elevation_token = nil
          safety.pop_policy_override(cap)
          log(logger, :info, "elevation_revoked proposal=#{proposal_id}")
        end
      end

      def self.log(logger, level, msg)
        return unless logger
        logger.respond_to?(level) ? logger.public_send(level, msg) : nil
      rescue StandardError
        # never let logger crash mask elevation lifecycle
      end
    end
  end
end
