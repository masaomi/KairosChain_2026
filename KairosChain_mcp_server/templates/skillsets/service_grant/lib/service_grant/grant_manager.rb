# frozen_string_literal: true

module ServiceGrant
  class GrantManager
    GRANT_CREATION_COOLDOWN = 300  # 5 minutes
    MAX_GRANTS_PER_IP_PER_HOUR = 5

    def initialize(pg_pool:, plan_registry:)
      @pg = pg_pool
      @plans = plan_registry
      @ip_tracker = IpRateTracker.new(max: MAX_GRANTS_PER_IP_PER_HOUR, window: 3600)
    end

    attr_reader :plan_registry

    def ensure_grant(pubkey_hash, service:, remote_ip: nil)
      # Atomic rate check + record BEFORE DB insert (FIX-10).
      # NOTE: Phase 2 must revise to count only newly_created grants.
      # Current pre-insert form will over-count when D-5 wires remote_ip,
      # because ensure_grant is called on every request (including refreshes).
      if remote_ip && !@ip_tracker.record_if_allowed(remote_ip)
        raise RateLimitError, "Too many new grants from this address"
      end

      result = @pg.exec_params(<<~SQL, [pubkey_hash, service])
        INSERT INTO service_grants (pubkey_hash, service)
        VALUES ($1, $2)
        ON CONFLICT (pubkey_hash, service)
        DO UPDATE SET last_active_at = NOW()
        RETURNING *, (xmax = 0) AS newly_created
      SQL

      row = result[0]
      grant = parse_grant_row(row)

      if grant[:newly_created]
        record_grant_event(pubkey_hash, service, 'created')
      end

      grant
    end

    def upgrade_plan(pubkey_hash, service:, new_plan:, plan_version: nil)
      raise PlanNotFoundError, "Plan '#{new_plan}' not found for service '#{service}'" unless @plans.plan_exists?(service, new_plan)

      version = plan_version || @plans.current_version(service, new_plan)
      @pg.exec_params(<<~SQL, [new_plan, version, pubkey_hash, service])
        UPDATE service_grants
        SET plan = $1, plan_version = $2, last_active_at = NOW()
        WHERE pubkey_hash = $3 AND service = $4
      SQL

      record_grant_event(pubkey_hash, service, 'plan_upgrade', { new_plan: new_plan })
    end

    def suspend_grant(pubkey_hash, service:, reason:)
      @pg.exec_params(<<~SQL, [reason, pubkey_hash, service])
        UPDATE service_grants
        SET suspended = true, suspended_reason = $1, last_active_at = NOW()
        WHERE pubkey_hash = $2 AND service = $3
      SQL

      record_grant_event(pubkey_hash, service, 'suspended', { reason: reason })
    end

    def unsuspend_grant(pubkey_hash, service:)
      @pg.exec_params(<<~SQL, [pubkey_hash, service])
        UPDATE service_grants
        SET suspended = false, suspended_reason = NULL, last_active_at = NOW()
        WHERE pubkey_hash = $1 AND service = $2
      SQL

      record_grant_event(pubkey_hash, service, 'unsuspended')
    end

    def get_grant(pubkey_hash, service:)
      result = @pg.exec_params(<<~SQL, [pubkey_hash, service])
        SELECT * FROM service_grants
        WHERE pubkey_hash = $1 AND service = $2
      SQL

      return nil if result.ntuples == 0
      parse_grant_row(result[0])
    end

    def in_cooldown?(grant)
      return false unless grant[:first_seen_at]
      (Time.now - grant[:first_seen_at]) < GRANT_CREATION_COOLDOWN
    end

    def grants_with_unknown_plans(plan_registry)
      results = []
      plan_registry.services.each do |service|
        known_plans = plan_registry.plans_for(service)
        grants = @pg.exec_params(<<~SQL, [service])
          SELECT pubkey_hash, service, plan FROM service_grants
          WHERE service = $1 AND suspended = false
        SQL

        grants.each do |row|
          unless known_plans.include?(row['plan'])
            results << { pubkey_hash: row['pubkey_hash'], service: row['service'], plan: row['plan'] }
          end
        end
      end
      results
    end

    private

    def parse_grant_row(row)
      {
        pubkey_hash: row['pubkey_hash'],
        service: row['service'],
        plan: row['plan'],
        plan_version: row['plan_version'],
        billing_model: row['billing_model'],
        trust_score: row['trust_score']&.to_f,
        suspended: row['suspended'] == 't',
        suspended_reason: row['suspended_reason'],
        first_seen_at: row['first_seen_at'] ? Time.parse(row['first_seen_at']) : nil,
        last_active_at: row['last_active_at'] ? Time.parse(row['last_active_at']) : nil,
        newly_created: row['newly_created'] == 't'
      }
    end

    def record_grant_event(pubkey_hash, service, action, details = {})
      require 'kairos_mcp/kairos_chain/chain'
      chain = KairosMcp::KairosChain::Chain.new
      chain.add_block([{
        type: 'service_grant_event',
        layer: 'L1',
        pubkey_hash: pubkey_hash,
        service: service,
        action: action,
        details: details,
        timestamp: Time.now.iso8601
      }.to_json])
    rescue StandardError => e
      warn "[ServiceGrant] Chain recording failed (non-fatal): #{e.message}"
    end
  end
end
