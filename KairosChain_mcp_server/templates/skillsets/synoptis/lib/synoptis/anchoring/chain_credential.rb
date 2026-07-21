# frozen_string_literal: true

require 'digest'
require 'json'
require 'openssl'
require_relative 'entry'

module Synoptis
  module Anchoring
    # Chain identity credential (aud_l2_mutual_anchoring_design v0.5 §3b,
    # MAP-2), computed under the map-1 convention: a self-authenticating
    # identifier composed of the content-derived committed identity (khab-1 §5)
    # and an Ed25519 signature capability. Verification needs the credential,
    # the attestation, and material derivable from them — no registry, no
    # network. The binding signature is a SELF-attestation (map-1 §1); that the
    # credential speaks for the chain is established only by the chain
    # committing the credential digest (map-1 §2).
    module ChainCredential
      CONVENTION_ID = 'map-1'
      CONVENTION_PATH = File.expand_path('conventions/map-1.md', __dir__)
      FORMAT = 'map-1/credential'
      ALGORITHM = 'ed25519'
      HEX_DIGEST = /\A[a-f0-9]{64}\z/
      HEX_PUBKEY = /\A[a-f0-9]{64}\z/
      HEX_SIG = /\A[a-f0-9]{128}\z/
      CHAIN_IDENTITY = /\Ablock1-sha256:[a-f0-9]{64}\z/

      # Exactly these keys (map-1 §1); extensibility is a new convention.
      FIELDS = %w[
        format convention_sha256 chain_identity algorithm public_key binding_sig
      ].freeze

      # Raw Ed25519 public keys are 32 bytes; OpenSSL DER wraps them in a
      # 12-byte SubjectPublicKeyInfo prefix. The raw key is the LAST 32 bytes.
      RAW_KEY_BYTES = 32
      DER_PREFIX_BYTES = 12

      class CredentialError < StandardError; end

      module_function

      # SHA-256 of the shipped convention definition's raw bytes (MAP-2 via the
      # MPR-3 pattern: the identifier resolves to a checkable definition).
      def convention_sha256
        @convention_sha256 ||= begin
          Digest::SHA256.hexdigest(File.binread(CONVENTION_PATH))
        rescue SystemCallError => e
          raise CredentialError, "map-1 convention definition unreadable at #{CONVENTION_PATH}: #{e.message}"
        end
      end

      # Generate a fresh Ed25519 keypair. Returns the OpenSSL::PKey object;
      # persistence (under the project's .kairos/keys/, never mirrored to
      # templates) is the CALLER's decision — this module holds no paths to
      # private material.
      def generate_key
        OpenSSL::PKey.generate_key('ED25519')
      end

      def public_key_hex(key)
        der = key.public_to_der
        raise CredentialError, "unexpected Ed25519 DER length #{der.bytesize}" unless der.bytesize == DER_PREFIX_BYTES + RAW_KEY_BYTES

        der[-RAW_KEY_BYTES..].unpack1('H*')
      end

      # Build the credential for +chain_identity+ under +key+ (map-1 §1).
      def build(chain_identity, key)
        ci = chain_identity.to_s
        raise CredentialError, "chain_identity must match khab-1 §5 form, got #{ci.inspect}" unless ci.match?(CHAIN_IDENTITY)

        pub = public_key_hex(key)
        {
          'format' => FORMAT,
          'convention_sha256' => convention_sha256,
          'chain_identity' => ci,
          'algorithm' => ALGORITHM,
          'public_key' => pub,
          'binding_sig' => key.sign(nil, binding_string(ci, pub)).unpack1('H*')
        }
      end

      # Structural + cryptographic validation of a credential. Raises
      # CredentialError with a stable message on the first violation.
      def validate!(credential)
        raise CredentialError, "credential must be a Hash, got #{credential.class}" unless credential.is_a?(Hash)

        c = credential.transform_keys(&:to_s)
        keys = c.keys.sort
        unless keys == FIELDS.sort
          raise CredentialError, "credential fields must be exactly #{FIELDS.sort.join(', ')}, got #{keys.join(', ')}"
        end
        raise CredentialError, "unknown format #{c['format'].inspect} (#{FORMAT} only)" unless c['format'] == FORMAT
        unless c['convention_sha256'] == convention_sha256
          raise CredentialError,
                "convention_sha256 #{c['convention_sha256'].inspect} does not match the shipped " \
                "map-1 definition (#{convention_sha256}); credential would be unresolvable"
        end
        raise CredentialError, "unknown algorithm #{c['algorithm'].inspect} (#{ALGORITHM} only)" unless c['algorithm'] == ALGORITHM
        unless c['chain_identity'].is_a?(String) && c['chain_identity'].match?(CHAIN_IDENTITY)
          raise CredentialError, 'credential.chain_identity must be block1-sha256:<64-hex>'
        end
        unless c['public_key'].is_a?(String) && c['public_key'].match?(HEX_PUBKEY)
          raise CredentialError, 'credential.public_key must be 64-char lowercase hex (32 raw bytes)'
        end
        unless c['binding_sig'].is_a?(String) && c['binding_sig'].match?(HEX_SIG)
          raise CredentialError, 'credential.binding_sig must be 128-char lowercase hex (64 raw bytes)'
        end
        unless verify_raw(c['public_key'], c['binding_sig'], binding_string(c['chain_identity'], c['public_key']))
          raise CredentialError, 'binding_sig does not verify under public_key (map-1 §1)'
        end
        true
      end

      # SHA-256 of the credential's canonical JSON (map-1 §1).
      def credential_digest(credential)
        validate!(credential)
        Digest::SHA256.hexdigest(Entry.canonical_json(credential.transform_keys(&:to_s)))
      end

      # The credential-commitment record string (map-1 §2) a chain commits to
      # adopt the credential.
      def commitment_record(credential)
        Entry.canonical_json(
          'format' => 'map-1/credential-commitment',
          'credential_digest' => credential_digest(credential)
        )
      end

      # Sign an attestation payload (map-1 §1.1) under +key+ for +credential+.
      # Returns the signature hex. The payload is committed by digest, so no
      # payload content enters the signed string beyond its hash.
      def sign_attestation(credential, key, payload)
        digest = credential_digest(credential)
        unless public_key_hex(key) == credential.transform_keys(&:to_s)['public_key']
          raise CredentialError, 'signing key does not match credential.public_key'
        end

        key.sign(nil, attestation_string(digest, payload)).unpack1('H*')
      end

      # Verify an attestation signature with NOTHING but credential + payload +
      # signature (MAP-2 self-authentication). Returns true/false; malformed
      # credential raises (a verdict about a credential that cannot be resolved
      # would be noise dressed as judgment).
      def verify_attestation(credential, payload, signature_hex)
        digest = credential_digest(credential)
        c = credential.transform_keys(&:to_s)
        return false unless signature_hex.is_a?(String) && signature_hex.match?(HEX_SIG)

        verify_raw(c['public_key'], signature_hex, attestation_string(digest, payload))
      end

      # -- internal helpers (deterministic strings, map-1 §1/§1.1) --

      def binding_string(chain_identity, public_key_hex)
        "#{FORMAT}|#{chain_identity}|#{public_key_hex}"
      end

      def attestation_string(credential_digest, payload)
        # Payloads are byte strings only (map-1 §1.1): hashing a Ruby object's
        # to_s rendering would sign a representation no other implementation
        # can reproduce.
        raise CredentialError, "attestation payload must be a String, got #{payload.class}" unless payload.is_a?(String)

        "map-1/attestation|#{credential_digest}|#{Digest::SHA256.hexdigest(payload)}"
      end

      def verify_raw(public_key_hex, signature_hex, message)
        pub = openssl_public_key(public_key_hex)
        pub.verify(nil, [signature_hex].pack('H*'), message)
      rescue OpenSSL::PKey::PKeyError
        false
      end

      # Rebuild an OpenSSL public key from the raw 32-byte hex by re-wrapping
      # it in the fixed Ed25519 SubjectPublicKeyInfo DER prefix.
      def openssl_public_key(public_key_hex)
        raw = [public_key_hex].pack('H*')
        raise CredentialError, 'public key must decode to 32 bytes' unless raw.bytesize == RAW_KEY_BYTES

        prefix = ["302a300506032b6570032100"].pack('H*')
        OpenSSL::PKey.read(prefix + raw)
      end
    end
  end
end
