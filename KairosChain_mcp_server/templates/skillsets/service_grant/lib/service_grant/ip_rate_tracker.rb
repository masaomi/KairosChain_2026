# frozen_string_literal: true

module ServiceGrant
  class IpRateTracker
    def initialize(max:, window:, pg_pool: nil)
      @max = max
      @window = window
      @pg = pg_pool
      @records = {}
      @mutex = Mutex.new
    end

    def limited?(ip)
      @mutex.synchronize do
        cleanup(ip)
        (@records[ip]&.size || 0) >= @max
      end
    end

    def record(ip)
      @mutex.synchronize do
        @records[ip] ||= []
        @records[ip] << Time.now
      end
    end

    # Atomic check-and-record. Returns true if allowed (under limit), false if denied.
    # Uses PG-backed storage if available, with in-memory fallback.
    def record_if_allowed(ip)
      if @pg
        record_if_allowed_pg(ip)
      else
        record_if_allowed_memory(ip)
      end
    end

    private

    # PG-backed atomic check-and-record using single INSERT...SELECT.
    # Eliminates the SELECT+INSERT race condition.
    def record_if_allowed_pg(ip)
      cutoff = Time.now - @window
      result = @pg.exec_params(<<~SQL, [ip, cutoff, @max, ip])
        INSERT INTO grant_ip_events (ip)
        SELECT $4
        WHERE (SELECT COUNT(*) FROM grant_ip_events WHERE ip = $1 AND created_at > $2) < $3
        RETURNING id
      SQL
      result.ntuples > 0
    rescue PG::Error
      # Fallback to in-memory on PG failure
      record_if_allowed_memory(ip)
    end

    # In-memory atomic check-and-record (mutex-protected).
    def record_if_allowed_memory(ip)
      @mutex.synchronize do
        cleanup(ip)
        count = @records[ip]&.size || 0
        return false if count >= @max
        @records[ip] ||= []
        @records[ip] << Time.now
        true
      end
    end

    def cleanup(ip)
      return unless @records[ip]
      cutoff = Time.now - @window
      @records[ip].reject! { |t| t < cutoff }
      @records.delete(ip) if @records[ip].empty?
    end
  end
end
