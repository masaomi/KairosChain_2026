# frozen_string_literal: true

require 'digest'

module KairosMcp
  class Daemon
    # EditKernel — pure-function string replacement + hash computation.
    #
    # Design (P3.2 v0.2 §3):
    #   Shared by ProposedEdit (simulate) and apply path. No I/O —
    #   caller provides content bytes. This eliminates divergence risk
    #   between simulation and actual write.
    module EditKernel
      class NotFoundError  < StandardError; end
      class AmbiguousError < StandardError; end

      # Compute a string replacement and return pre/post hashes.
      #
      # @param content [String] original file bytes (binread)
      # @param old_string [String] text to find
      # @param new_string [String] replacement text
      # @param replace_all [Boolean] replace all occurrences
      # @return [Hash] { new_content:, occurrences:, pre_hash:, post_hash: }
      # @raise [NotFoundError] if old_string not found
      # @raise [AmbiguousError] if occurrences > 1 and !replace_all
      def self.compute(content, old_string:, new_string:, replace_all: false)
        raise ArgumentError, 'old_string must not be empty' if old_string.nil? || old_string.empty?
        raise ArgumentError, 'old_string == new_string (no-op)' if old_string == new_string

        occurrences = content.scan(old_string).size
        raise NotFoundError, 'old_string not found in content' if occurrences.zero?
        if occurrences > 1 && !replace_all
          raise AmbiguousError,
                "old_string not unique (#{occurrences} occurrences); pass replace_all: true"
        end

        new_content = replace_all ? content.gsub(old_string, new_string) : content.sub(old_string, new_string)
        {
          new_content: new_content,
          occurrences: occurrences,
          pre_hash:    hash_bytes(content),
          post_hash:   hash_bytes(new_content)
        }
      end

      # Content-addressed hash of raw bytes.
      # @param bytes [String]
      # @return [String] "sha256:<hex>"
      def self.hash_bytes(bytes)
        "sha256:#{Digest::SHA256.hexdigest(bytes)}"
      end
    end
  end
end
