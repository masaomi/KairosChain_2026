# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative 'types'

module Hestia
  module Chain
    module Protocol
      class ObservationLog
        attr_reader :observer_id,
                    :observed_id,
                    :interaction_hash,
                    :observation_type,
                    :interpretation,
                    :timestamp,
                    :context_ref,
                    :metadata

        def initialize(observer_id:, observed_id:, interaction_hash:, observation_type:, **options)
          validate_observer_id!(observer_id)
          validate_observed_id!(observed_id)
          validate_interaction_hash!(interaction_hash)
          validate_observation_type!(observation_type)

          @observer_id = observer_id.to_s
          @observed_id = observed_id.to_s
          @interaction_hash = normalize_hash(interaction_hash)
          @observation_type = observation_type.to_s
          @interpretation = options[:interpretation] || {}
          @timestamp = options[:timestamp] || Time.now.utc.iso8601
          @context_ref = options[:context_ref]
          @metadata = options[:metadata] || {}
        end

        def observation_id
          @observation_id ||= begin
            hash_input = "#{@observer_id}_#{@observed_id}_#{@interaction_hash}_#{@timestamp}"
            short_hash = Digest::SHA256.hexdigest(hash_input)[0, 12]
            "obs_#{short_hash}"
          end
        end

        def self_observation?
          @observer_id == @observed_id
        end

        def fadeout?
          @observation_type == 'faded'
        end

        def to_anchor
          require_relative '../core/anchor'
          participants = [@observer_id]
          participants << @observed_id unless self_observation?

          Core::Anchor.new(
            anchor_type: 'observation_log',
            source_id: observation_id,
            data_hash: @interaction_hash,
            participants: participants.uniq,
            metadata: anchor_metadata,
            timestamp: @timestamp,
            previous_anchor_ref: @context_ref
          )
        end

        def to_h
          {
            observer_id: @observer_id,
            observed_id: @observed_id,
            interaction_hash: @interaction_hash,
            observation_type: @observation_type,
            interpretation: @interpretation,
            timestamp: @timestamp,
            context_ref: @context_ref,
            metadata: @metadata,
            observation_id: observation_id
          }.compact
        end

        def to_json(*args)
          to_h.to_json(*args)
        end

        def self.from_h(hash)
          hash = hash.transform_keys(&:to_sym)
          new(
            observer_id: hash[:observer_id],
            observed_id: hash[:observed_id],
            interaction_hash: hash[:interaction_hash],
            observation_type: hash[:observation_type],
            interpretation: hash[:interpretation],
            timestamp: hash[:timestamp],
            context_ref: hash[:context_ref],
            metadata: hash[:metadata]
          )
        end

        def inspect
          relation = self_observation? ? 'self' : "#{@observer_id}->#{@observed_id}"
          "#<Hestia::Chain::Protocol::ObservationLog type=#{@observation_type} relation=#{relation}>"
        end

        private

        def anchor_metadata
          base = {
            observation_type: @observation_type,
            observer_id: @observer_id,
            observed_id: @observed_id
          }
          unless @interpretation.empty?
            base[:interpretation_hash] = Digest::SHA256.hexdigest(@interpretation.to_json)
          end
          base.merge(@metadata)
        end

        def validate_observer_id!(id)
          return unless id.nil? || id.to_s.strip.empty?
          raise ArgumentError, 'observer_id cannot be empty'
        end

        def validate_observed_id!(id)
          return unless id.nil? || id.to_s.strip.empty?
          raise ArgumentError, 'observed_id cannot be empty'
        end

        def validate_observation_type!(type)
          return if Types::OBSERVATION_TYPES.include?(type.to_s)
          return if type.to_s.start_with?('custom.')
          raise ArgumentError,
                "Invalid observation_type: '#{type}'. " \
                "Use one of #{Types::OBSERVATION_TYPES.join(', ')} or 'custom.your_type'"
        end

        def validate_interaction_hash!(hash)
          normalized = normalize_hash(hash)
          return if normalized.match?(/\A[a-f0-9]{64}\z/)
          raise ArgumentError,
                "Invalid interaction_hash format. Expected 64-character hex string (SHA256), " \
                "got: #{hash.inspect}"
        end

        def normalize_hash(hash)
          hash.to_s.downcase.sub(/\A0x/, '')
        end
      end
    end
  end
end
