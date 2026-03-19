# frozen_string_literal: true

module ServiceGrant
  class CycleManager
    CYCLE_UNITS = %w[monthly weekly daily].freeze

    def initialize(plan_registry:)
      @plan_registry = plan_registry
    end

    # @param service [String]
    # @return [Array<Time, Time>] [cycle_start, cycle_end] in UTC
    def current_cycle(service)
      unit = @plan_registry.cycle_unit(service)
      now = Time.now.utc
      case unit
      when 'monthly'
        start = Time.utc(now.year, now.month, 1)
        next_month = now.month == 12 ? Time.utc(now.year + 1, 1, 1) : Time.utc(now.year, now.month + 1, 1)
        [start, next_month]
      when 'weekly'
        days_since_monday = (now.wday - 1) % 7
        start = Time.utc(now.year, now.month, now.day) - (days_since_monday * 86_400)
        [start, start + (7 * 86_400)]
      when 'daily'
        start = Time.utc(now.year, now.month, now.day)
        [start, start + 86_400]
      else
        raise ConfigValidationError, "Unknown cycle unit: #{unit}"
      end
    end

    def current_cycle_start(service)
      current_cycle(service).first
    end

    def current_cycle_end(service)
      current_cycle(service).last
    end
  end
end
