# frozen_string_literal: true

module Hestia
  # IP-based rate limiter for public web/API endpoints.
  # Bounded memory: TTL eviction + max tracked IPs.
  class PublicRateLimiter
    MAX_REQUESTS_PER_MINUTE = 30
    MAX_TRACKED_IPS = 10_000
    CLEANUP_INTERVAL = 1000
    STALE_SECONDS = 300

    def initialize(max_rpm: MAX_REQUESTS_PER_MINUTE)
      @max_rpm = max_rpm
      @requests = {}
      @mutex = Mutex.new
      @total_requests = 0
    end

    def allow?(ip)
      @mutex.synchronize do
        @total_requests += 1
        cleanup! if (@total_requests % CLEANUP_INTERVAL).zero?

        now = Time.now.to_f
        @requests[ip] = (@requests[ip] || []).select { |t| now - t < 60 }

        return false if @requests[ip].size >= @max_rpm

        @requests[ip] << now
        true
      end
    end

    private

    def cleanup!
      now = Time.now.to_f
      @requests.delete_if { |_ip, timestamps| timestamps.all? { |t| now - t >= STALE_SECONDS } }

      return unless @requests.size > MAX_TRACKED_IPS

      sorted = @requests.sort_by { |_ip, ts| ts.last || 0 }
      excess = @requests.size - MAX_TRACKED_IPS
      sorted.first(excess).each { |ip, _| @requests.delete(ip) }
    end
  end
end
