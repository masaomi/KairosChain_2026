# frozen_string_literal: true

module ServiceGrant
  # Resolves the real client IP from a Rack env hash.
  #
  # IMPORTANT: X-Forwarded-For is NOT used — it is client-spoofable unless
  # the reverse proxy strips/overwrites it. X-Real-IP is preferred because
  # nginx sets it from $remote_addr (not appendable by the client).
  #
  # Deployment requirement: This resolver assumes nginx (or equivalent) is
  # in front of the application and sets X-Real-IP to the true client address.
  # For direct Puma deployments (no proxy), REMOTE_ADDR is used as fallback.
  class ClientIpResolver
    def initialize(config = {})
      @header = config['header'] || config[:header] || 'X-Real-IP'
    end

    # @param env [Hash] Rack environment
    # @return [String, nil] Client IP address
    def resolve(env)
      rack_header = "HTTP_#{@header.upcase.tr('-', '_')}"
      env[rack_header] || env['REMOTE_ADDR']
    end
  end
end
