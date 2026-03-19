# frozen_string_literal: true

module ServiceGrant
  class ServiceGrantError < StandardError; end

  class AccessDeniedError < ServiceGrantError
    attr_reader :reason, :details
    def initialize(reason, **details)
      @reason = reason
      @details = details
      super(details[:message] || "Access denied: #{reason}")
    end
  end

  class RateLimitError < ServiceGrantError; end
  class ConfigValidationError < ServiceGrantError; end
  class PlanNotFoundError < ServiceGrantError; end
  class InvalidAttestationError < ServiceGrantError; end
  class DuplicatePaymentError < ServiceGrantError; end

  class PgUnavailableError < ServiceGrantError; end
  class PgReadonlyError < PgUnavailableError; end
  class PoolExhaustedError < ServiceGrantError; end
end
