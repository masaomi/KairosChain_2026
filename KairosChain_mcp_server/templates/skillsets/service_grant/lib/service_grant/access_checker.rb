# frozen_string_literal: true

module ServiceGrant
  class AccessChecker
    def initialize(grant_manager:, usage_tracker:, plan_registry:,
                   cycle_manager:, trust_scorer: nil)
      @grant_manager = grant_manager
      @usage_tracker = usage_tracker
      @plan_registry = plan_registry
      @cycle_manager = cycle_manager
      @trust_scorer = trust_scorer
    end

    attr_reader :plan_registry

    # @raise [AccessDeniedError] if denied
    def check_access(pubkey_hash:, action:, service:, remote_ip: nil)
      return unless @plan_registry.gated_action?(service, action)

      grant = @grant_manager.ensure_grant(pubkey_hash, service: service,
                                           remote_ip: remote_ip)

      # 1. Suspension check
      if grant[:suspended]
        raise AccessDeniedError.new(:suspended, service: service, action: action,
          message: "Grant suspended: #{grant[:suspended_reason]}")
      end

      # 1.5 Subscription expiry check (lazy downgrade)
      if grant[:subscription_expires_at] && Time.now > grant[:subscription_expires_at]
        downgraded = @grant_manager.downgrade_to_free(pubkey_hash, service: service)
        if downgraded
          grant[:plan] = 'free'
        else
          # DB says subscription is still active (concurrent renewal or clock skew)
          grant = @grant_manager.get_grant(pubkey_hash, service: service) || grant
        end
      end

      plan = grant[:plan]

      # 2. Delayed activation check (Sybil mitigation)
      if @grant_manager.in_cooldown?(grant) && write_action?(service, action)
        raise AccessDeniedError.new(:cooldown, service: service, action: action,
          message: "New grant in cooldown period. Read-only actions only.",
          cooldown_remaining: @grant_manager.cooldown -
                              (Time.now - grant[:first_seen_at]).to_i)
      end

      # 3. Trust Score check BEFORE quota consumption
      if @trust_scorer
        score = @trust_scorer.call(pubkey_hash)
        min_score = @plan_registry.trust_requirement(service, plan, action)
        if min_score && score < min_score
          raise AccessDeniedError.new(:insufficient_trust, score: score, required: min_score)
        end
      end

      # 4. Atomic quota check-and-consume
      # IMPORTANT: :plan_unavailable is truthy in Ruby.
      # Must check explicitly before the boolean false check.
      result = @usage_tracker.try_consume(pubkey_hash,
                 service: service, action: action, plan: plan)

      if result == :plan_unavailable
        raise AccessDeniedError.new(:plan_unavailable, service: service, action: action,
          plan: plan, message: "Plan '#{plan}' is not in current config. Run service_grant_migrate.")
      end

      unless result
        cycle_end = @cycle_manager.current_cycle_end(service)
        raise AccessDeniedError.new(:quota_exceeded, service: service, action: action,
          plan: plan, cycle_resets_at: cycle_end)
      end

      nil
    end

    def resolve_action(service, tool_name)
      @plan_registry.action_for_tool(service, tool_name) || tool_name
    end

    private

    def write_action?(service, action)
      @plan_registry.write_action?(service, action)
    end
  end
end
