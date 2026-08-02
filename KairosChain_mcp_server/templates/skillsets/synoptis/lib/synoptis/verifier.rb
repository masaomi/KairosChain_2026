# frozen_string_literal: true

module Synoptis
  class Verifier
    def initialize(config: {})
      @require_signature = config.fetch(:require_signature, true)
    end

    # S-C5 fix: Signature verification is mandatory when require_signature is true.
    # Proofs without a valid signature are always invalid — no soft-fail path.
    def verify(envelope, public_key: nil)
      errors = []

      errors << 'missing_attester_id' unless envelope.attester_id
      errors << 'missing_subject_ref' unless envelope.subject_ref
      errors << 'missing_claim' unless envelope.claim
      errors << 'expired' if envelope.expired?
      errors << 'identity_outside_signature' if envelope.identity_outside_signature?

      if envelope.signature
        # The verifying key comes from the caller and only from the caller.
        # Reading it out of the envelope would make the record self-certifying:
        # the version field selects the canonical field set and is itself a field
        # of the record, so a forger could label a record 1.1.0, name any
        # attester, sign with their own key, record that key alongside, and have
        # a key-less verification return valid: true (measured, 2026-08-02).
        # Ruling of 2026-08-02 (option A2): no key is ever taken from the record.
        #
        # An empty string is treated as "no key supplied" rather than passed
        # through: MCP clients routinely send '' for an omitted optional string,
        # and handing that to the crypto layer would report invalid_signature —
        # a claim about the signature, when nothing about the signature is known.
        supplied = public_key.to_s.strip.empty? ? nil : public_key

        if supplied
          errors << 'invalid_signature' unless verify_signature(envelope, supplied)
        else
          errors << 'no_public_key_for_verification'
        end
      elsif @require_signature
        errors << 'missing_signature'
      end

      {
        valid: errors.empty?,
        errors: errors,
        content_hash: envelope.content_hash,
        checked_at: Time.now.utc.iso8601
      }
    end

    private

    def verify_signature(envelope, public_key)
      return false unless defined?(::MMP::Crypto)

      crypto = MMP::Crypto.new(auto_generate: false)
      crypto.verify_signature(envelope.canonical_json, envelope.signature, public_key)
    rescue StandardError
      false
    end
  end
end
