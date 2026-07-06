# frozen_string_literal: true

require 'openssl'
require 'securerandom'
require 'fileutils'
require 'ipaddr'

module KairosMcp
  # TlsCertGenerator: produce a self-signed certificate + key for the
  # single-operator remote-access case.
  #
  # Design intent (Prop 2): this uses Ruby's OpenSSL stdlib to *generate* key
  # material — it does not implement any cryptography of its own. It exists so
  # that "kairos-chain --gen-cert" gives a one-shot path to HTTPS for a single
  # operator. For a public, multi-user service, use a CA-issued certificate
  # (e.g. behind a reverse proxy) instead of a self-signed one.
  module TlsCertGenerator
    module_function

    # Hostnames/IPs always covered by the generated certificate's SAN so that
    # loopback access verifies without --cert-host. Remote names are added by
    # the caller (system hostname, config host, --cert-host entries).
    DEFAULT_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

    # @param hosts [Array<String>] hostnames/IPs to place in the SAN. Each entry
    #   is auto-classified as IP: or DNS:. The common_name is always included.
    # @return [Hash] { cert_path:, key_path:, not_after:, san: }
    def generate(cert_path:, key_path:, common_name: 'kairos-chain',
                 hosts: DEFAULT_HOSTS, days: 825, key_size: 2048)
      key = OpenSSL::PKey::RSA.new(key_size)

      name = OpenSSL::X509::Name.parse("/CN=#{common_name}")
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      # Positive, non-zero serial. RFC 5280 requires a positive integer;
      # SecureRandom.random_number(1 << 64) can return 0, so add 1.
      cert.serial = OpenSSL::BN.new(SecureRandom.random_number(1 << 64) + 1)
      cert.subject = name
      cert.issuer = name
      cert.public_key = key.public_key

      now = Time.now
      cert.not_before = now - 3600            # tolerate minor clock skew
      cert.not_after  = now + (days * 24 * 3600)

      san = san_value(common_name, hosts)

      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate = cert
      # Leaf SERVER certificate — explicitly NOT a CA, scoped to serverAuth so
      # strict clients (macOS Secure Transport, Chromium) accept it.
      cert.add_extension(ef.create_extension('basicConstraints', 'CA:FALSE', true))
      cert.add_extension(ef.create_extension('keyUsage', 'digitalSignature,keyEncipherment', true))
      cert.add_extension(ef.create_extension('extendedKeyUsage', 'serverAuth', false))
      cert.add_extension(ef.create_extension('subjectAltName', san, false))
      cert.sign(key, OpenSSL::Digest.new('SHA256'))

      write_secure(cert_path, cert.to_pem, 0o644)
      write_secure(key_path, key.to_pem, 0o600)

      { cert_path: cert_path, key_path: key_path, not_after: cert.not_after, san: san }
    end

    # Build a subjectAltName value from a host list, auto-classifying each
    # entry as IP: or DNS:. The common_name is always included as DNS.
    def san_value(common_name, hosts)
      entries = []
      add_san(entries, common_name)
      Array(hosts).each { |h| add_san(entries, h) }
      entries.uniq.join(',')
    end

    def add_san(entries, host)
      return if host.nil? || host.to_s.strip.empty?

      h = host.to_s.strip
      # Reject injection: a raw entry must be a single hostname/IP, not a
      # comma-separated list or a pre-formatted "DNS:/IP:" token — otherwise
      # --cert-host "a,DNS:evil" would silently mint extra SAN names.
      if h.include?(',') || h =~ /\A(DNS|IP):/i
        raise ArgumentError, "invalid SAN host #{h.inspect}: must be a single hostname or IP"
      end

      begin
        IPAddr.new(h)
        entries << "IP:#{h}"
      rescue IPAddr::InvalidAddressError, ArgumentError
        entries << "DNS:#{h}"
      end
    end

    # Deterministic half of the --gen-cert overwrite guard: in non-interactive
    # mode, refuse to clobber an existing cert/key (which could break a live
    # deployment). Interactive mode prompts the operator instead. Extracted so
    # the refusal branch is unit-testable.
    def overwrite_refused_noninteractive?(exists:, tty:)
      exists && !tty
    end

    def write_secure(path, content, mode)
      FileUtils.mkdir_p(File.dirname(path))
      # Open with target mode (new files) AND chmod the descriptor BEFORE
      # writing, so on OVERWRITE of a pre-existing world-readable file the key
      # bytes are never written while the old permissive mode is still in
      # effect. Closes the umask/overwrite window on both create and overwrite.
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, mode) do |f|
        f.chmod(mode)
        f.write(content)
      end
    end
  end
end
