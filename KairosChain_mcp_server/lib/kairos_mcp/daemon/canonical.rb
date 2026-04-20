# frozen_string_literal: true

require 'json'
require 'digest'

module KairosMcp
  class Daemon
    # Canonical — deterministic object serialization for WAL & idempotency key derivation.
    #
    # Design (v0.2 §5.3, [FIX: CF-15]):
    #   Two tool invocations with "the same intent" must produce identical bytes
    #   (and therefore identical hashes and idempotency keys) even if their
    #   inputs arrived in different key order or included volatile bookkeeping
    #   fields (timestamps, trace_ids, nonces).
    #
    # Rules:
    #   1. Volatile keys in STRIP_KEYS are removed recursively from Hashes.
    #   2. Remaining Hash keys are sorted by their stringified form.
    #   3. Array order is preserved (order is semantically meaningful).
    #   4. Serialization uses JSON.generate (stable because keys are sorted).
    #
    # Edge cases:
    #   - Hash keys may be Symbols or Strings; STRIP_KEYS matches on to_s.
    #   - Nested Hashes/Arrays are fully traversed.
    #   - Non-container scalars pass through unchanged.
    module Canonical
      STRIP_KEYS = %w[timestamp ts request_id trace_id nonce].freeze

      module_function

      # Deeply strip volatile keys and sort Hash keys. Returns a new structure.
      def canonicalize(obj)
        deep_sort(strip_volatile(obj))
      end

      # Recursively remove STRIP_KEYS entries from every Hash in obj.
      def strip_volatile(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), acc|
            next if STRIP_KEYS.include?(k.to_s)

            acc[k] = strip_volatile(v)
          end
        when Array
          obj.map { |v| strip_volatile(v) }
        else
          obj
        end
      end

      # Recursively sort Hash keys by their stringified form.
      # Array order is preserved.
      def deep_sort(obj)
        case obj
        when Hash
          obj.keys.sort_by(&:to_s).each_with_object({}) do |k, acc|
            acc[k] = deep_sort(obj[k])
          end
        when Array
          obj.map { |v| deep_sort(v) }
        else
          obj
        end
      end

      # Canonical JSON string for obj.
      def serialize(obj)
        JSON.generate(canonicalize(obj))
      end

      # SHA-256 hash of canonicalized obj, prefixed "sha256-".
      def sha256_json(obj)
        "sha256-#{Digest::SHA256.hexdigest(serialize(obj))}"
      end

      # SHA-256 hash of an arbitrary string, prefixed "sha256-".
      def sha256(str)
        "sha256-#{Digest::SHA256.hexdigest(str.to_s)}"
      end
    end
  end
end
