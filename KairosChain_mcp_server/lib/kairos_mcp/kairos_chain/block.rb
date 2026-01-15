require 'digest'
require 'json'
require 'time'

module KairosMcp
  module KairosChain
    class Block
      attr_reader :index, :timestamp, :data, :previous_hash, :merkle_root, :hash

      def initialize(index:, timestamp: Time.now.utc, data:, previous_hash:, merkle_root:)
        @index = index
        @timestamp = timestamp
        @data = data
        @previous_hash = previous_hash
        @merkle_root = merkle_root
        @hash = calculate_hash
      end

      def calculate_hash
        # Combine all attributes to generate a unique hash
        payload = [
          @index,
          @timestamp.iso8601(6),
          @previous_hash,
          @merkle_root,
          @data.to_json
        ].join

        Digest::SHA256.hexdigest(payload)
      end

      def self.genesis
        new(
          index: 0,
          timestamp: Time.at(0).utc, # Fixed timestamp for genesis
          data: ["Genesis Block"],
          previous_hash: "0" * 64,
          merkle_root: "0" * 64
        )
      end

      def to_h
        {
          index: @index,
          timestamp: @timestamp.iso8601(6),
          data: @data,
          previous_hash: @previous_hash,
          merkle_root: @merkle_root,
          hash: @hash
        }
      end

      def to_json(*args)
        to_h.to_json(*args)
      end
    end
  end
end
