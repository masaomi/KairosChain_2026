# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative 'types'

module Hestia
  module Chain
    module Protocol
      class PhilosophyDeclaration
        attr_reader :agent_id,
                    :philosophy_type,
                    :philosophy_hash,
                    :compatible_with,
                    :version,
                    :timestamp,
                    :previous_declaration_ref,
                    :metadata

        def initialize(agent_id:, philosophy_type:, philosophy_hash:, **options)
          validate_agent_id!(agent_id)
          validate_philosophy_type!(philosophy_type)
          validate_philosophy_hash!(philosophy_hash)

          @agent_id = agent_id.to_s
          @philosophy_type = philosophy_type.to_s
          @philosophy_hash = normalize_hash(philosophy_hash)
          @compatible_with = Array(options[:compatible_with]).map(&:to_s).compact
          @version = options[:version]&.to_s || '1.0'
          @timestamp = options[:timestamp] || Time.now.utc.iso8601
          @previous_declaration_ref = options[:previous_declaration_ref]
          @metadata = options[:metadata] || {}
        end

        def declaration_id
          @declaration_id ||= "philo_#{@agent_id}_#{@philosophy_type}_#{@version}_#{@timestamp.gsub(/[^0-9]/, '')}"
        end

        def to_anchor
          require_relative '../core/anchor'
          Core::Anchor.new(
            anchor_type: 'philosophy_declaration',
            source_id: declaration_id,
            data_hash: @philosophy_hash,
            participants: [@agent_id],
            metadata: anchor_metadata,
            timestamp: @timestamp,
            previous_anchor_ref: @previous_declaration_ref
          )
        end

        def to_h
          {
            agent_id: @agent_id,
            philosophy_type: @philosophy_type,
            philosophy_hash: @philosophy_hash,
            compatible_with: @compatible_with,
            version: @version,
            timestamp: @timestamp,
            previous_declaration_ref: @previous_declaration_ref,
            metadata: @metadata,
            declaration_id: declaration_id
          }.compact
        end

        def to_json(*args)
          to_h.to_json(*args)
        end

        def self.from_h(hash)
          hash = hash.transform_keys(&:to_sym)
          new(
            agent_id: hash[:agent_id],
            philosophy_type: hash[:philosophy_type],
            philosophy_hash: hash[:philosophy_hash],
            compatible_with: hash[:compatible_with],
            version: hash[:version],
            timestamp: hash[:timestamp],
            previous_declaration_ref: hash[:previous_declaration_ref],
            metadata: hash[:metadata]
          )
        end

        def inspect
          "#<Hestia::Chain::Protocol::PhilosophyDeclaration " \
            "agent=#{@agent_id} type=#{@philosophy_type} version=#{@version}>"
        end

        private

        def anchor_metadata
          {
            philosophy_type: @philosophy_type,
            compatible_with: @compatible_with,
            version: @version
          }.merge(@metadata)
        end

        def validate_agent_id!(id)
          return unless id.nil? || id.to_s.strip.empty?
          raise ArgumentError, 'agent_id cannot be empty'
        end

        def validate_philosophy_type!(type)
          return if Types::PHILOSOPHY_TYPES.include?(type.to_s)
          return if type.to_s.start_with?('custom.')
          raise ArgumentError,
                "Invalid philosophy_type: '#{type}'. " \
                "Use one of #{Types::PHILOSOPHY_TYPES.join(', ')} or 'custom.your_type'"
        end

        def validate_philosophy_hash!(hash)
          normalized = normalize_hash(hash)
          return if normalized.match?(/\A[a-f0-9]{64}\z/)
          raise ArgumentError,
                "Invalid philosophy_hash format. Expected 64-character hex string (SHA256), " \
                "got: #{hash.inspect}"
        end

        def normalize_hash(hash)
          hash.to_s.downcase.sub(/\A0x/, '')
        end
      end
    end
  end
end
