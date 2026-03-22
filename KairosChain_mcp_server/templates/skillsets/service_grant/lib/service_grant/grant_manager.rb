# frozen_string_literal: true

require 'time'

module ServiceGrant
  class GrantManager
    GRANT_CREATION_COOLDOWN = 300  # 5 minutes
    MAX_GRANTS_PER_IP_PER_HOUR = 5

    def initialize(pg_pool:, plan_registry:)
      @pg = pg_pool
      @plans = plan_registry
      @ip_tracker = IpRateTracker.new(
        max: MAX_GRANTS_PER_IP_PER_HOUR, window: 3600, pg_pool: pg_pool
      )
    end

    attr_reader :plan_registry

    def ensure_grant(pubkey_hash, service:, remote_ip: nil)
      @pg.with_connection do |conn|
        conn.exec("BEGIN")

        result = conn.exec_params(<<~SQL, [pubkey_hash, service])
          INSERT INTO service_grants (pubkey_hash, service)
          VALUES ($1, $2)
          ON CONFLICT (pubkey_hash, service)
          DO UPDATE SET last_active_at = NOW()
          RETURNING *, (xmax = 0) AS newly_created
        SQL

        grant = parse_grant_row(result[0])

        # IP rate check only for truly new grants (Phase 2 revision of FIX-10).
        # record_if_allowed operates on a separate connection/store — this is
        # intentional: IP events persist even on ROLLBACK to prevent attackers
        # from triggering rollbacks to avoid rate limiting.
        if grant[:newly_created] && remote_ip
          unless @ip_tracker.record_if_allowed(remote_ip)
            conn.exec("ROLLBACK")
            raise RateLimitError, "Too many new grants from this address"
          end
        end

        conn.exec("COMMIT")
        record_grant_event(pubkey_hash, service, 'created') if grant[:newly_created]
        grant
      end
    end

    def upgrade_plan(pubkey_hash, service:, new_plan:, plan_version: nil)
      apply_plan_upgrade(@pg, pubkey_hash, service: service, new_plan: new_plan, plan_version: plan_version)
      record_plan_upgrade(pubkey_hash, service: service, new_plan: new_plan)
    end

    # SQL-only plan upgrade for use within external transactions.
    # Caller is responsible for BEGIN/COMMIT and event recording.
    def apply_plan_upgrade(conn, pubkey_hash, service:, new_plan:, plan_version: nil)
      raise PlanNotFoundError, "Plan '#{new_plan}' not found for service '#{service}'" unless @plans.plan_exists?(service, new_plan)

      version = plan_version || @plans.current_version(service, new_plan)
      duration = @plans.subscription_duration(service, new_plan)
      if duration
        conn.exec_params(<<~SQL, [new_plan, version, duration, pubkey_hash, service])
          UPDATE service_grants
          SET plan = $1, plan_version = $2,
              subscription_expires_at = NOW() + INTERVAL '1 day' * $3,
              last_active_at = NOW()
          WHERE pubkey_hash = $4 AND service = $5
        SQL
      else
        conn.exec_params(<<~SQL, [new_plan, version, pubkey_hash, service])
          UPDATE service_grants
          SET plan = $1, plan_version = $2,
              subscription_expires_at = NULL, last_active_at = NOW()
          WHERE pubkey_hash = $3 AND service = $4
        SQL
      end
    end

    # Record plan upgrade event. Call after successful COMMIT.
    def record_plan_upgrade(pubkey_hash, service:, new_plan:)
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

    def downgrade_to_free(pubkey_hash, service:)
      version = @plans.current_version(service, 'free')
      result = @pg.exec_params(<<~SQL, [version, pubkey_hash, service])
        UPDATE service_grants
        SET plan = 'free', plan_version = $1, subscription_expires_at = NULL, last_active_at = NOW()
        WHERE pubkey_hash = $2 AND service = $3
          AND subscription_expires_at IS NOT NULL
          AND subscription_expires_at < NOW()
        RETURNING id
      SQL

      if result.ntuples > 0
        record_grant_event(pubkey_hash, service, 'subscription_expired')
        true
      else
        false
      end
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
        subscription_expires_at: row['subscription_expires_at'] ? Time.parse(row['subscription_expires_at']) : nil,
        newly_created: row['newly_created'] == 't'
      }
    end

    MAX_RECORDING_RETRIES = 3

    def record_grant_event(pubkey_hash, service, action, details = {})
      record_with_retry({
        type: 'service_grant_event', layer: 'L1',
        pubkey_hash: pubkey_hash, service: service,
        action: action, details: details, timestamp: Time.now.iso8601
      })
    end

    # Record with retry (non-blocking, up to MAX_RECORDING_RETRIES attempts).
    # Phase 2 pragmatic choice: in-memory retry queue.
    # Phase 3 should consider WAL-backed queue for true constitutive guarantee.
    def record_with_retry(event, attempt: 0)
      require 'kairos_mcp/kairos_chain/chain'
      chain = KairosMcp::KairosChain::Chain.new
      chain.add_block([event.to_json])
    rescue StandardError => e
      if attempt < MAX_RECORDING_RETRIES
        sleep_time = 0.1 * (2 ** attempt)  # exponential backoff: 0.1, 0.2, 0.4s
        Thread.new do
          sleep sleep_time
          record_with_retry(event, attempt: attempt + 1)
        end
      else
        warn "[ServiceGrant] Chain recording failed after #{MAX_RECORDING_RETRIES} retries: #{e.message}"
        # Persist to local file for manual recovery
        begin
          File.open('storage/failed_recordings.jsonl', 'a') { |f| f.puts(event.to_json) }
        rescue StandardError
          # Last resort: stderr only
        end
      end
    end
  end
end
