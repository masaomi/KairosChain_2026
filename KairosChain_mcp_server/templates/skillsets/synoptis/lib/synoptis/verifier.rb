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

      if envelope.signature
        if public_key
          unless verify_signature(envelope, public_key)
            errors << 'invalid_signature'
          end
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
