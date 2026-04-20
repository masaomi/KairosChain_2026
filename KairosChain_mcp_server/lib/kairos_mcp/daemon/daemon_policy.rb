# frozen_string_literal: true

require_relative '../safety'

module KairosMcp
  class Daemon
    # DaemonPolicy — Default-deny authorization policy for daemon-mode execution.
    #
    # Design (v0.2 §3.1.x / CF-4):
    #   When the Kairos daemon runs in the background, it must not be able to
    #   silently modify L0 (framework) or L1 (knowledge) state, mint/burn
    #   tokens, or administer service grants. Those operations require a live
    #   human owner session.  Only L2 (context / workspace) operations are
    #   permitted by default — L2 is the daemon's natural scratch space.
    #
    # Mechanism:
    #   Safety exposes a class-level policy registry (Safety.register_policy).
    #   Each capability method (can_modify_l0?, can_manage_tokens?, …) looks
    #   up a block keyed by its name and calls it with the current_user hash.
    #   When no policy is registered, most capabilities default-allow — we
    #   therefore register explicit deny blocks for the daemon user and set
    #   a synthetic `{ role: 'daemon' }` user context so the blocks fire.
    #
    # Escape hatch:
    #   A command explicitly run by the human owner (e.g. an interactive MCP
    #   session attached to the daemon) can still use a fresh Safety instance
    #   without the daemon user context; that path is unaffected.
    module DaemonPolicy
      # Synthetic user context used when the daemon acts on its own behalf.
      DAEMON_USER = { user: 'kairos_daemon', role: 'daemon' }.freeze

      # Capability keys this module controls.
      DENIED_CAPABILITIES = %i[
        can_modify_l0
        can_modify_l1
        can_manage_tokens
        can_manage_grants
      ].freeze

      ALLOWED_CAPABILITIES = %i[
        can_modify_l2
      ].freeze

      # Register deny policies on the Safety class and stamp the given
      # Safety *instance* with the daemon user context so the policies fire.
      #
      # Codex-R1 fix: policies compose with existing RBAC by saving prior
      # policies and delegating for non-daemon users. This prevents
      # overwriting owner/member restrictions with the daemon's blanket rules.
      #
      # @param safety [KairosMcp::Safety, nil]
      # @return [KairosMcp::Safety, nil] the same instance (for chaining)
      def self.apply!(safety = nil)
        @prior_policies = {}

        DENIED_CAPABILITIES.each do |cap|
          @prior_policies[cap] = KairosMcp::Safety.policy_for(cap)
          prior = @prior_policies[cap]
          KairosMcp::Safety.register_policy(cap) do |user|
            if daemon_user?(user)
              false  # daemon always denied
            elsif prior
              prior.call(user)  # delegate to existing RBAC
            else
              true  # no prior policy → default allow (STDIO mode)
            end
          end
        end

        ALLOWED_CAPABILITIES.each do |cap|
          @prior_policies[cap] = KairosMcp::Safety.policy_for(cap)
          prior = @prior_policies[cap]
          KairosMcp::Safety.register_policy(cap) do |user|
            if daemon_user?(user)
              true  # daemon allowed for L2
            elsif prior
              prior.call(user)  # delegate to existing RBAC
            else
              true
            end
          end
        end

        safety&.set_user(DAEMON_USER.dup)
        safety
      end

      # Remove all policies this module registers and restore prior ones.
      # Intended for tests and for clean shutdown.
      def self.remove!
        (DENIED_CAPABILITIES + ALLOWED_CAPABILITIES).each do |cap|
          prior = @prior_policies&.dig(cap)
          if prior
            KairosMcp::Safety.register_policy(cap, &prior)
          else
            KairosMcp::Safety.unregister_policy(cap)
          end
        end
        @prior_policies = nil
      end

      # Is the user context a daemon-owned one?
      # Accepts both symbol and string key hashes because different callers
      # (HTTP auth, internal stamping) produce different shapes.
      def self.daemon_user?(user)
        return false unless user.is_a?(Hash)
        role = user[:role] || user['role']
        role.to_s == 'daemon'
      end
    end
  end
end
