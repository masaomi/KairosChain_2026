# frozen_string_literal: true

module ServiceGrant
  class UsageTracker
    def initialize(pg_pool:, plan_registry:, cycle_manager:)
      @pg = pg_pool
      @plans = plan_registry
      @cycles = cycle_manager
    end

    # Atomic check-and-consume.
    # @return [true] consumed successfully
    # @return [false] quota exceeded (count >= limit)
    # @return [:plan_unavailable] plan/action not in config (caller should deny)
    def try_consume(pubkey_hash, service:, action:, plan:)
      limit = @plans.limit_for(service, plan, action)
      return :plan_unavailable if limit.nil?  # plan not in config = denied
      return true if limit == -1              # explicitly unlimited

      cycle_start, cycle_end = @cycles.current_cycle(service)

      ensure_cycle_row(pubkey_hash, service: service, action: action,
                       cycle_start: cycle_start, cycle_end: cycle_end)

      affected = @pg.exec_params(<<~SQL, [pubkey_hash, service, action, cycle_start, limit])
        UPDATE usage_counts
        SET count = count + 1
        WHERE pubkey_hash = $1 AND service = $2 AND action = $3
          AND cycle_start = $4 AND count < $5
      SQL

      affected.cmd_tuples > 0
    end

    # Metered usage recording (called by service SkillSets directly)
    def record_metered(pubkey_hash, service:, metric:, amount:)
      cycle_start, cycle_end = @cycles.current_cycle(service)
      ensure_metered_row(pubkey_hash, service: service, metric: metric,
                         cycle_start: cycle_start, cycle_end: cycle_end)

      @pg.exec_params(<<~SQL, [amount, pubkey_hash, service, metric, cycle_start])
        UPDATE metered_usage SET cumulative = cumulative + $1
        WHERE pubkey_hash = $2 AND service = $3 AND metric = $4 AND cycle_start = $5
      SQL

      record_usage_log(pubkey_hash, service: service, action: "metered:#{metric}",
                       metadata: { metric: metric, amount: amount })
    end

    def remaining(pubkey_hash, service:, action:, plan:)
      limit = @plans.limit_for(service, plan, action)
      return 0 if limit.nil?     # unknown plan = no remaining
      return -1 if limit == -1   # unlimited

      cycle_start, _ = @cycles.current_cycle(service)
      current = current_count(pubkey_hash, service: service, action: action,
                              cycle_start: cycle_start)
      [limit - current, 0].max
    end

    def usage_summary(pubkey_hash, service:)
      cycle_start, cycle_end = @cycles.current_cycle(service)

      counts = @pg.exec_params(<<~SQL, [pubkey_hash, service, cycle_start])
        SELECT action, count FROM usage_counts
        WHERE pubkey_hash = $1 AND service = $2 AND cycle_start = $3
      SQL

      metered = @pg.exec_params(<<~SQL, [pubkey_hash, service, cycle_start])
        SELECT metric, cumulative FROM metered_usage
        WHERE pubkey_hash = $1 AND service = $2 AND cycle_start = $3
      SQL

      {
        cycle_start: cycle_start.iso8601,
        cycle_end: cycle_end.iso8601,
        counts: counts.map { |r| { action: r['action'], count: r['count'].to_i } },
        metered: metered.map { |r| { metric: r['metric'], cumulative: r['cumulative'].to_f } }
      }
    end

    private

    def ensure_cycle_row(pubkey_hash, service:, action:, cycle_start:, cycle_end:)
      @pg.exec_params(<<~SQL, [pubkey_hash, service, action, cycle_start, cycle_end])
        INSERT INTO usage_counts (pubkey_hash, service, action, count, cycle_start, cycle_end)
        VALUES ($1, $2, $3, 0, $4, $5)
        ON CONFLICT (pubkey_hash, service, action, cycle_start) DO NOTHING
      SQL
    end

    def ensure_metered_row(pubkey_hash, service:, metric:, cycle_start:, cycle_end:)
      @pg.exec_params(<<~SQL, [pubkey_hash, service, metric, cycle_start, cycle_end])
        INSERT INTO metered_usage (pubkey_hash, service, metric, cumulative, cycle_start, cycle_end)
        VALUES ($1, $2, $3, 0, $4, $5)
        ON CONFLICT (pubkey_hash, service, metric, cycle_start) DO NOTHING
      SQL
    end

    def current_count(pubkey_hash, service:, action:, cycle_start:)
      result = @pg.exec_params(<<~SQL, [pubkey_hash, service, action, cycle_start])
        SELECT count FROM usage_counts
        WHERE pubkey_hash = $1 AND service = $2 AND action = $3 AND cycle_start = $4
      SQL

      result.ntuples > 0 ? result[0]['count'].to_i : 0
    end

    def record_usage_log(pubkey_hash, service:, action:, metadata: {})
      @pg.exec_params(<<~SQL, [pubkey_hash, service, action, metadata.to_json])
        INSERT INTO usage_log (pubkey_hash, service, action, metadata)
        VALUES ($1, $2, $3, $4)
      SQL
    rescue StandardError => e
      warn "[ServiceGrant] Usage log failed (non-fatal): #{e.message}"
    end
  end
end
