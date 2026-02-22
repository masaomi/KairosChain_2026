# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

module Hestia
  module Chain
    module Core
      class Anchor
        STANDARD_TYPES = %w[
          meeting
          generic
          genomics
          research
          agreement
          audit
          release
          philosophy_declaration
          observation_log
        ].freeze

        attr_reader :anchor_type,
                    :source_id,
                    :data_hash,
                    :participants,
                    :metadata,
                    :timestamp,
                    :previous_anchor_ref

        def initialize(anchor_type:, source_id:, data_hash:, **options)
          validate_type!(anchor_type)
          validate_data_hash!(data_hash)
          validate_source_id!(source_id)

          @anchor_type = anchor_type
          @source_id = source_id.to_s
          @data_hash = normalize_hash(data_hash)
          @participants = Array(options[:participants]).map(&:to_s).compact
          @metadata = options[:metadata] || {}
          @timestamp = options[:timestamp] || Time.now.utc.iso8601
          @previous_anchor_ref = options[:previous_anchor_ref]
        end

        def anchor_hash
          @anchor_hash ||= Digest::SHA256.hexdigest(canonical_payload.to_json)
        end

        def to_h
          {
            anchor_type: @anchor_type,
            source_id: @source_id,
            data_hash: @data_hash,
            participants: @participants,
            metadata: @metadata,
            timestamp: @timestamp,
            previous_anchor_ref: @previous_anchor_ref,
            anchor_hash: anchor_hash
          }.compact
        end

        def to_json(*args)
          to_h.to_json(*args)
        end

        def self.from_h(hash)
          hash = hash.transform_keys(&:to_sym)
          new(
            anchor_type: hash[:anchor_type],
            source_id: hash[:source_id],
            data_hash: hash[:data_hash],
            participants: hash[:participants],
            metadata: hash[:metadata],
            timestamp: hash[:timestamp],
            previous_anchor_ref: hash[:previous_anchor_ref]
          )
        end

        def valid?
          anchor_hash == Digest::SHA256.hexdigest(canonical_payload.to_json)
        end

        def ==(other)
          return false unless other.is_a?(Anchor)
          anchor_hash == other.anchor_hash
        end
        alias eql? ==

        def hash
          anchor_hash.hash
        end

        def inspect
          "#<Hestia::Chain::Anchor type=#{@anchor_type} source=#{@source_id} hash=#{anchor_hash[0, 16]}...>"
        end

        private

        def canonical_payload
          {
            t: @anchor_type,
            s: @source_id,
            d: @data_hash,
            p: @participants.sort,
            m: @metadata.sort.to_h,
            ts: @timestamp,
            prev: @previous_anchor_ref
          }
        end

        def validate_type!(type)
          return if STANDARD_TYPES.include?(type)
          return if type.to_s.start_with?('custom.')
          raise ArgumentError,
                "Invalid anchor_type: '#{type}'. " \
                "Use one of #{STANDARD_TYPES.join(', ')} or 'custom.your_type'"
        end

        def validate_data_hash!(hash)
          normalized = normalize_hash(hash)
          return if normalized.match?(/\A[a-f0-9]{64}\z/)
          raise ArgumentError,
                "Invalid data_hash format. Expected 64-character hex string (SHA256), " \
                "got: #{hash.inspect}"
        end

        def validate_source_id!(id)
          return unless id.nil? || id.to_s.strip.empty?
          raise ArgumentError, 'source_id cannot be empty'
        end

        def normalize_hash(hash)
          hash.to_s.downcase.sub(/\A0x/, '')
        end
      end
    end
  end
end
