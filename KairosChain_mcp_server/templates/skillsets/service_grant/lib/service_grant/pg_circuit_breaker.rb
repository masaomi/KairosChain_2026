# frozen_string_literal: true

module ServiceGrant
  class PgCircuitBreaker
    FAILURE_THRESHOLD = 3
    RECOVERY_TIMEOUT  = 30

    attr_reader :state

    def initialize(policy:)
      validate_policy!(policy)
      @policy = policy
      @state = :closed
      @failure_count = 0
      @last_failure_at = nil
      @mutex = Mutex.new
    end

    def call(&block)
      @mutex.synchronize do
        case @state
        when :closed
          execute_closed(&block)
        when :open
          handle_open(&block)
        when :half_open
          execute_half_open(&block)
        end
      end
    end

    private

    def validate_policy!(policy)
      valid = [:deny_all, :allow_readonly]
      if policy == :allow_all
        unless ENV['KAIROS_DEV_MODE']
          raise ConfigValidationError,
            "pg_unavailable_policy: allow_all is only permitted when " \
            "KAIROS_DEV_MODE environment variable is set. " \
            "Use deny_all or allow_readonly for production."
        end
        warn "[ServiceGrant] WARNING: allow_all PG policy active (DEV MODE ONLY)"
      end
      unless valid.include?(policy) || (policy == :allow_all && ENV['KAIROS_DEV_MODE'])
        raise ConfigValidationError, "Invalid pg_unavailable_policy: #{policy}"
      end
    end

    def execute_closed(&block)
      result = block.call
      @failure_count = 0
      result
    rescue PG::Error => e
      @failure_count += 1
      if @failure_count >= FAILURE_THRESHOLD
        @state = :open
        @last_failure_at = Time.now
      end
      apply_policy(e)
    end

    def handle_open(&block)
      if Time.now - (@last_failure_at || Time.now) > RECOVERY_TIMEOUT
        @state = :half_open
        execute_half_open(&block)
      else
        apply_policy(nil)
      end
    end

    def execute_half_open(&block)
      result = block.call
      @state = :closed
      @failure_count = 0
      result
    rescue PG::Error => e
      @state = :open
      @last_failure_at = Time.now
      apply_policy(e)
    end

    def apply_policy(error)
      case @policy
      when :deny_all
        raise PgUnavailableError, "PostgreSQL unavailable (policy: deny_all)"
      when :allow_all
        warn "[ServiceGrant] PG unavailable -- allowing request (DEV MODE)"
        nil
      when :allow_readonly
        raise PgReadonlyError, "PostgreSQL unavailable (policy: allow_readonly)"
      end
    end
  end
end
