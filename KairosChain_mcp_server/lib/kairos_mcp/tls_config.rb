# frozen_string_literal: true

require 'uri'
require 'openssl'

module KairosMcp
  # TlsConfig: resolves optional TLS settings for the HTTP transport.
  #
  # Design intent (Prop 2, partial autopoiesis): transport encryption is an
  # execution-substrate concern, not a self-referential core capability.
  # KairosChain does NOT implement crypto here. It delegates to Puma/OpenSSL
  # and only decides the bind scheme (tcp:// vs ssl://) from config. The only
  # logic in this class is path resolution and fail-closed validation.
  #
  # Config shape (under the 'http' key of skills/config.yml):
  #   http:
  #     tls:
  #       enabled: false
  #       cert: "storage/tls/cert.pem"
  #       key:  "storage/tls/key.pem"
  #
  class TlsConfig
    DEFAULT_CERT = 'storage/tls/cert.pem'
    DEFAULT_KEY  = 'storage/tls/key.pem'

    attr_reader :cert_path, :key_path

    # @param http_config [Hash] the 'http' section of the loaded config
    # @param data_dir [String] base dir for resolving relative cert/key paths
    # @param force_enabled [Boolean, nil] CLI override; nil = use config value
    def initialize(http_config, data_dir:, force_enabled: nil)
      tls = (http_config || {})['tls'] || {}
      @data_dir = data_dir
      @enabled = force_enabled.nil? ? (tls['enabled'] == true) : force_enabled
      # An empty-string path in config falls back to the default rather than
      # resolving to nil (which would crash the --gen-cert path).
      @cert_path = resolve(present_or(tls['cert'], DEFAULT_CERT))
      @key_path  = resolve(present_or(tls['key'], DEFAULT_KEY))
    end

    def enabled?
      @enabled
    end

    # Fail-closed validation. When TLS is enabled, the cert and key must exist,
    # be readable, and parse as valid material — otherwise abort rather than
    # start plain HTTP or crash later inside Puma with an opaque error.
    def validate!
      return unless @enabled

      problems = []
      problems << "certificate is missing (#{@cert_path})" unless @cert_path && File.exist?(@cert_path)
      problems << "private key is missing (#{@key_path})" unless @key_path && File.exist?(@key_path)

      if problems.empty?
        problems << "certificate is not readable (#{@cert_path})" unless File.readable?(@cert_path)
        problems << "private key is not readable (#{@key_path})" unless File.readable?(@key_path)
      end

      if problems.empty?
        cert = safe_parse { OpenSSL::X509::Certificate.new(File.read(@cert_path)) }
        key  = safe_parse { OpenSSL::PKey.read(File.read(@key_path)) }
        problems << "certificate is not valid PEM (#{@cert_path})" if cert.nil?
        problems << "private key is not valid (#{@key_path})" if key.nil?
        # A parseable cert + parseable key that do not form a pair would pass
        # independent checks but fail opaquely inside Puma's SSL setup.
        if cert && key && !cert.check_private_key(key)
          problems << "certificate and private key do not match (#{@cert_path} / #{@key_path})"
        end
      end

      return if problems.empty?

      raise TlsConfigError, <<~MSG.strip
        TLS is enabled but its material is unusable:
          - #{problems.join("\n  - ")}

        Generate a self-signed certificate for single-operator use:
          kairos-chain --gen-cert

        Or point http.tls.cert / http.tls.key at a valid certificate.
      MSG
    end

    # Build a Puma bind URI. Encryption params are passed to Puma, which
    # performs the TLS handshake via OpenSSL.
    def bind_uri(host, port)
      h = bracket_ipv6(host)
      return "tcp://#{h}:#{port}" unless @enabled

      query = URI.encode_www_form('key' => @key_path, 'cert' => @cert_path)
      "ssl://#{h}:#{port}?#{query}"
    end

    def scheme
      @enabled ? 'https' : 'http'
    end

    # Expiry (not_after) of the configured certificate, or nil if it cannot be
    # read/parsed. Used to surface silent-expiry breakage at startup.
    def certificate_not_after
      return nil unless @cert_path && File.exist?(@cert_path)

      OpenSSL::X509::Certificate.new(File.read(@cert_path)).not_after
    rescue StandardError
      nil
    end

    # Whole days until the certificate expires (negative if already expired),
    # or nil if the cert cannot be read. now is injectable for testing.
    def days_until_expiry(now = Time.now)
      not_after = certificate_not_after
      return nil unless not_after

      ((not_after - now) / 86_400).floor
    end

    private

    # An IPv6 literal host must be bracketed in a URI authority
    # (ssl://[::1]:8443), otherwise Puma's binder misparses the colons.
    def bracket_ipv6(host)
      s = host.to_s
      return s if s.empty? || s.start_with?('[') || !s.include?(':')

      "[#{s}]"
    end

    def present_or(value, default)
      s = value.to_s.strip
      s.empty? ? default : s
    end

    def resolve(path)
      return nil if path.nil? || path.to_s.empty?

      File.absolute_path?(path) ? path : File.join(@data_dir, path)
    end

    def safe_parse
      yield
    rescue StandardError
      nil
    end
  end

  # Raised when TLS is enabled but its material cannot be located or used.
  class TlsConfigError < StandardError; end
end
