# frozen_string_literal: true

require_relative 'entry'

module Synoptis
  module Anchoring
    # Write-path containment (ANC-2; hestia_anchor_attestation_design_v0.5).
    #
    # Every write to the anchor log carries only inert, bounded fields: a
    # self-describing digest (fixed-size, over a committed algorithm), a bounded
    # set of short inert metadata fields, and at most one safe-scheme external
    # reference. No anchored *content* travels with any write — per-entry storage
    # is constant and illegal-content hosting is excluded at the type level rather
    # than by moderation.
    #
    # This is the sole intake gate: the Log's append methods call it before
    # building an entry, so the store structurally cannot hold arbitrary content.
    # Inertness here constrains *capability* (no nested payload, no oversized or
    # active content); navigable rendering of the safe reference is a separate
    # concern owned by ANC-7 (the public view).
    module Containment
      # Committed digest algorithms and their fixed hex lengths. Scope X commits
      # sha256 only; adding an algorithm is a §11 decision, not a caller choice.
      ALLOWED_ALGORITHMS = { 'sha256' => 64 }.freeze

      MAX_METADATA_KEYS = 8
      MAX_KEY_LENGTH = 64
      MAX_VALUE_LENGTH = 256
      MAX_METADATA_BYTES = 1024
      MAX_EXTERNAL_REF_LENGTH = 512
      MAX_REASON_LENGTH = 256
      MAX_NOTE_LENGTH = 256

      # BRD-3: an attestation body is typed claim fields, never free prose. The
      # claim_type is one of a fixed set; a reader must not read any field as an
      # unbounded content channel.
      ATTESTATION_CLAIM_TYPES = %w[correspondence review vouch].freeze

      KEY_PATTERN = /\A[a-z0-9_]{1,#{MAX_KEY_LENGTH}}\z/
      # Only https and doi are safe, resolvable schemes. http (cleartext),
      # javascript/data/file/etc. are excluded by allowlist, not blocklist.
      SAFE_REFERENCE_PATTERN = %r{\A(https://|doi:)[^\s]+\z}
      CONTROL_CHARS = /[\x00-\x1f\x7f]/

      # Raised when a write violates a containment rule. +code+ is a stable
      # machine-readable reason (structured rejection, testable).
      class ContainmentError < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

      module_function

      # Validate an anchor deposit. Returns the normalized digest on success.
      def validate_anchor!(digest:, algorithm: Entry::DIGEST_ALGORITHM, metadata: {}, external_reference: nil)
        norm = validate_digest!(digest, algorithm)
        validate_metadata!(metadata)
        validate_external_reference!(external_reference)
        norm
      end

      # Validate a withdrawal. Its only depositor-supplied field is the reason.
      def validate_withdrawal!(reason: nil)
        validate_reason!(reason)
        true
      end

      def validate_digest!(digest, algorithm)
        len = ALLOWED_ALGORITHMS[algorithm.to_s]
        unless len
          raise ContainmentError.new(:unknown_algorithm,
                                     "Unknown digest algorithm: #{algorithm.inspect} " \
                                     "(allowed: #{ALLOWED_ALGORITHMS.keys.join(', ')})")
        end
        norm = Entry.normalize_digest(digest)
        unless norm.match?(/\A[a-f0-9]{#{len}}\z/)
          raise ContainmentError.new(:digest_format,
                                     "digest must be a #{len}-char hex string for #{algorithm}, " \
                                     "got #{digest.inspect}")
        end
        norm
      end

      def validate_metadata!(metadata)
        return if metadata.nil?

        unless metadata.is_a?(Hash)
          raise ContainmentError.new(:metadata_type, "metadata must be a Hash, got #{metadata.class}")
        end
        if metadata.size > MAX_METADATA_KEYS
          raise ContainmentError.new(:metadata_too_many_keys,
                                     "metadata has #{metadata.size} keys (max #{MAX_METADATA_KEYS})")
        end

        metadata.each do |key, value|
          k = key.to_s
          unless k.match?(KEY_PATTERN)
            raise ContainmentError.new(:metadata_key,
                                       "metadata key #{key.inspect} must match #{KEY_PATTERN.source}")
          end
          validate_metadata_value!(k, value)
        end

        bytes = JSON.generate(metadata).bytesize
        if bytes > MAX_METADATA_BYTES
          raise ContainmentError.new(:metadata_too_large,
                                     "metadata is #{bytes} bytes (max #{MAX_METADATA_BYTES})")
        end
      end

      def validate_metadata_value!(key, value)
        case value
        when String
          if value.length > MAX_VALUE_LENGTH
            raise ContainmentError.new(:metadata_value_too_long,
                                       "metadata[#{key}] is #{value.length} chars (max #{MAX_VALUE_LENGTH})")
          end
          if value.match?(CONTROL_CHARS)
            raise ContainmentError.new(:metadata_value_active,
                                       "metadata[#{key}] contains control characters")
          end
        when Float
          # A non-finite float (Infinity/NaN) passes as Numeric but would raise
          # JSON::GeneratorError deep in the store; reject it as a structured
          # containment failure instead of an ungraceful abort.
          unless value.finite?
            raise ContainmentError.new(:metadata_value_nonfinite,
                                       "metadata[#{key}] must be a finite number, got #{value}")
          end
        when Numeric, true, false, nil
          # inert scalars are fine
        else
          # Hash / Array / anything nested is a content-smuggling channel.
          raise ContainmentError.new(:metadata_nested,
                                     "metadata[#{key}] must be an inert scalar, got #{value.class}")
        end
      end

      def validate_external_reference!(ref)
        return if ref.nil?

        unless ref.is_a?(String)
          raise ContainmentError.new(:reference_type, "external_reference must be a String, got #{ref.class}")
        end
        r = ref.strip
        if r.length > MAX_EXTERNAL_REF_LENGTH
          raise ContainmentError.new(:reference_too_long,
                                     "external_reference is #{r.length} chars (max #{MAX_EXTERNAL_REF_LENGTH})")
        end
        if r.match?(CONTROL_CHARS)
          raise ContainmentError.new(:reference_active, 'external_reference contains control characters')
        end
        unless r.match?(SAFE_REFERENCE_PATTERN)
          raise ContainmentError.new(:reference_unsafe_scheme,
                                     "external_reference must use a safe scheme (https:// or doi:), got #{ref.inspect}")
        end
      end

      # BRD-3 attestation body: typed, bounded, content-inert claim fields only.
      def validate_attestation!(claim_type:, note: nil, reference: nil, bound_digest: nil)
        unless ATTESTATION_CLAIM_TYPES.include?(claim_type.to_s)
          raise ContainmentError.new(:attestation_claim_type,
                                     "claim_type must be one of #{ATTESTATION_CLAIM_TYPES.join(', ')}, " \
                                     "got #{claim_type.inspect}")
        end
        validate_inert_text!(note, field: 'attestation note', max: MAX_NOTE_LENGTH)
        validate_external_reference!(reference)
        validate_digest!(bound_digest, Entry::DIGEST_ALGORITHM) unless bound_digest.nil?
        true
      end

      def validate_inert_text!(value, field:, max:)
        return if value.nil?

        unless value.is_a?(String)
          raise ContainmentError.new(:text_type, "#{field} must be a String, got #{value.class}")
        end
        if value.length > max
          raise ContainmentError.new(:text_too_long, "#{field} is #{value.length} chars (max #{max})")
        end
        if value.match?(CONTROL_CHARS)
          raise ContainmentError.new(:text_active, "#{field} contains control characters")
        end
      end

      def validate_reason!(reason)
        return if reason.nil?

        unless reason.is_a?(String)
          raise ContainmentError.new(:reason_type, "withdrawal reason must be a String, got #{reason.class}")
        end
        if reason.length > MAX_REASON_LENGTH
          raise ContainmentError.new(:reason_too_long,
                                     "withdrawal reason is #{reason.length} chars (max #{MAX_REASON_LENGTH})")
        end
        if reason.match?(CONTROL_CHARS)
          raise ContainmentError.new(:reason_active, 'withdrawal reason contains control characters')
        end
      end
    end
  end
end
