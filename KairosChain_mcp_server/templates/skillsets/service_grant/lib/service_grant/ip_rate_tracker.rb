# frozen_string_literal: true

module ServiceGrant
  class IpRateTracker
    def initialize(max:, window:)
      @max = max
      @window = window
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
    # Holds mutex across both check and record to eliminate TOCTOU.
    def record_if_allowed(ip)
      @mutex.synchronize do
        cleanup(ip)
        count = @records[ip]&.size || 0
        return false if count >= @max
        @records[ip] ||= []
        @records[ip] << Time.now
        true
      end
    end

    private

    def cleanup(ip)
      return unless @records[ip]
      cutoff = Time.now - @window
      @records[ip].reject! { |t| t < cutoff }
      @records.delete(ip) if @records[ip].empty?
    end
  end
end
