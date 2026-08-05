# frozen_string_literal: true

require 'bigdecimal'

module AccountManager
  # A refusal the tools pass straight through. Defined here because this is the
  # first file loaded and amounts are the first thing refused; the store
  # re-opens it. Every refusal names the invariant it follows from, because a
  # refusal whose reason is not legible is indistinguishable from a bug.
  class Refused < StandardError; end

  # Amounts are integer minor units, everywhere, without exception.
  #
  # A float amount is a rounding hazard that only shows up once the books are
  # large enough to matter, which is after they are worth keeping. Input may
  # arrive as a JSON number (Float), a string, or an integer of major units'
  # decimal text; all three go through BigDecimal and land as an integer.
  module Money
    MINOR_PER_MAJOR = 100

    module_function

    # Returns integer minor units. Refuses anything it cannot read exactly.
    #
    # "Exactly" includes precision: 10.005 is not a number of minor units, and
    # rounding it silently invents or loses a cent. Review R1 caught the old
    # version claiming exactness while rounding — so an amount finer than one
    # minor unit is now refused, and the caller decides what it meant.
    def to_minor(value)
      raise Refused, 'amount is required' if value.nil?

      decimal =
        begin
          case value
          when Integer    then BigDecimal(value)
          when BigDecimal then value
          when Float      then BigDecimal(value.to_s)
          when String     then BigDecimal(value.strip)
          else raise Refused, "amount must be a number or a decimal string, got #{value.class}"
          end
        rescue ArgumentError, TypeError => e
          raise Refused, "unreadable amount: #{value.inspect} (#{e.message})"
        end

      raise Refused, "amount #{value.inspect} is not a finite number" unless decimal.finite?

      scaled = decimal * MINOR_PER_MAJOR
      unless scaled.frac.zero?
        raise Refused, "amount #{value.inspect} is finer than one minor unit; " \
                       'round it yourself so the ledger records the figure you chose'
      end

      scaled.to_i
    end

    # Minor units back to the decimal text a human reads. Never a float.
    def render(minor)
      minor = minor.to_i
      sign  = minor.negative? ? '-' : ''
      major, rest = minor.abs.divmod(MINOR_PER_MAJOR)
      "#{sign}#{major}.#{rest.to_s.rjust(2, '0')}"
    end
  end
end
