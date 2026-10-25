# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'uri'
require 'time'
require 'securerandom'

module MMP
  # Registration proof: the one definition of what a Meeting Place registration
  # signs, shared by the client (PlaceClient) and the server (Hestia PlaceRouter)
  # so the two sides cannot drift.
  #
  # A proof binds four things under the agent's key: the origin the client
  # dialed (audience), the agent id, the issue time and a single-use nonce.
  # It is signed with RSA-PSS; every other MMP signature is PKCS#1 v1.5, so no
  # other use of the key (deposit content, attestation payloads, identity) can
  # yield a valid registration signature.
  module RegistrationProof
    PROTOCOL = 'kairos-mmp-register/1'
    # Direct-mode admission proof (secure MMP v1): same fields, a different
    # first line, so a registration proof never verifies as a direct proof
    # and the reverse.
    DIRECT_PROTOCOL = 'kairos-mmp-direct/1'
    PROTOCOLS = [PROTOCOL, DIRECT_PROTOCOL].freeze
    MIN_RSA_BITS = 2048
    RSA_EXPONENT = 65_537
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1] ::1].freeze
    DEFAULT_PORTS = { 'https' => 443, 'http' => 80 }.freeze

    AGENT_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    NONCE_PATTERN = /\A[0-9a-f]{32}\z/
    ISSUED_AT_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
    ORIGIN_PATTERN = %r{\Ahttps?://[^\s/]+\z}

    module_function

    # Normalize a URL or origin to "scheme://host[:port]": scheme and host
    # lowercased, default port dropped. Returns nil for anything unparseable
    # or not http(s).
    def normalize_origin(url)
      uri = URI.parse(url.to_s.strip)
      scheme = uri.scheme&.downcase
      return nil unless DEFAULT_PORTS.key?(scheme) && uri.host && !uri.host.empty?

      host = uri.host.downcase
      host = "[#{host}]" if host.include?(':') && !host.start_with?('[')
      port = uri.port
      port && port != DEFAULT_PORTS[scheme] ? "#{scheme}://#{host}:#{port}" : "#{scheme}://#{host}"
    rescue URI::InvalidURIError
      nil
    end

    # Normalize a configured host ("meeting.example" or "meeting.example:8443")
    # to the https origin the Place answers for.
    def origin_for_host(place_host)
      host = place_host.to_s.strip
      # A bare host name or [IPv6] literal with an optional port — not a URL.
      return nil unless host.match?(/\A(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(:\d{1,5})?\z/)

      normalize_origin("https://#{host}")
    end

    def loopback?(origin)
      host = URI.parse(origin.to_s).host.to_s.downcase
      LOOPBACK_HOSTS.include?(host)
    rescue URI::InvalidURIError
      false
    end

    # Build the proof fields for a registration.
    def build(audience:, agent_id:, issued_at: Time.now.utc, nonce: SecureRandom.hex(16))
      {
        'audience' => audience,
        'agent_id' => agent_id,
        'issued_at' => issued_at.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'nonce' => nonce
      }
    end

    # @return [String, nil] error code when a field is malformed
    def field_error(fields)
      return 'registration_proof_invalid' unless fields.is_a?(Hash)
      return 'registration_proof_invalid' unless %w[audience agent_id issued_at nonce].all? { |k| fields[k].is_a?(String) }

      audience = fields['audience'].to_s
      return 'registration_proof_invalid' unless ORIGIN_PATTERN.match?(audience) && normalize_origin(audience) == audience
      return 'registration_proof_invalid' unless AGENT_ID_PATTERN.match?(fields['agent_id'].to_s)
      return 'registration_proof_invalid' unless ISSUED_AT_PATTERN.match?(fields['issued_at'].to_s)
      return 'registration_proof_invalid' unless NONCE_PATTERN.match?(fields['nonce'].to_s)

      nil
    end

    # The exact bytes that are signed. Raises ArgumentError on malformed fields
    # so that no field can smuggle a newline into the message, and on a
    # protocol outside PROTOCOLS so this is never a generic signer.
    def message(fields, protocol: PROTOCOL)
      raise ArgumentError, "unknown proof protocol #{protocol.inspect}" unless PROTOCOLS.include?(protocol)
      raise ArgumentError, 'malformed registration proof fields' if field_error(fields)

      [protocol, fields['audience'], fields['agent_id'], fields['issued_at'], fields['nonce']].join("\n")
    end

    def issued_at_time(fields)
      Time.iso8601(fields['issued_at'].to_s)
    rescue ArgumentError
      nil
    end

    # Sign with RSA-PSS (SHA-256, MGF1 SHA-256, salt length = digest length).
    def sign(private_key, fields, protocol: PROTOCOL)
      sig = private_key.sign_pss('SHA256', message(fields, protocol: protocol), salt_length: :digest, mgf1_hash: 'SHA256')
      Base64.strict_encode64(sig)
    end

    def verify(public_key_pem, fields, signature, protocol: PROTOCOL)
      key = parse_key(public_key_pem)
      return false unless key

      raw = Base64.strict_decode64(signature.to_s)
      key.verify_pss('SHA256', raw, message(fields, protocol: protocol), salt_length: :digest, mgf1_hash: 'SHA256')
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      false
    end

    # RSA public key with exponent 65537 and at least 2048 bits, or nil.
    def parse_key(pem)
      key = OpenSSL::PKey::RSA.new(pem.to_s)
      return nil unless key.e.to_i == RSA_EXPONENT && key.n.num_bits >= MIN_RSA_BITS

      key
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      nil
    end

    def key_acceptable?(pem)
      !parse_key(pem).nil?
    end

    # The canonical PEM of a public key: what MMP::Crypto#export_public_key
    # produces for the same key, independent of whitespace in the input.
    def canonical_pem(pem)
      key = parse_key(pem)
      key&.public_key&.to_pem
    end

    def same_key?(pem_a, pem_b)
      a = parse_key(pem_a)
      b = parse_key(pem_b)
      return false unless a && b

      a.public_key.to_der == b.public_key.to_der
    end
  end
end
