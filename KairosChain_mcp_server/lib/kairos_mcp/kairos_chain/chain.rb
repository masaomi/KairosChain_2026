require_relative 'block'
require_relative 'merkle_tree'
require 'json'
require 'fileutils'

module KairosMcp
  module KairosChain
    class Chain
      attr_reader :chain

      DEFAULT_CHAIN_FILE = File.expand_path('../../../storage/blockchain.json', __dir__)

      def initialize(chain_file: DEFAULT_CHAIN_FILE)
        @chain_file = chain_file
        @chain = load_chain || [Block.genesis]
      end

      def latest_block
        @chain.last
      end

      def add_block(data)
        # Ensure data is array of strings (serialize if needed)
        normalized_data = data.map { |d| d.is_a?(String) ? d : d.to_json }

        # 1. Create Merkle Root from data
        merkle_tree = MerkleTree.new(normalized_data)
        merkle_root = merkle_tree.root

        # 2. Create new block
        new_block = Block.new(
          index: latest_block.index + 1,
          timestamp: Time.now.utc,
          data: normalized_data,
          previous_hash: latest_block.hash,
          merkle_root: merkle_root
        )

        # 3. Add to chain
        @chain << new_block
        
        # 4. Persist
        save_chain
        
        new_block
      end

      def valid?
        @chain.each_with_index do |block, i|
          next if i == 0 # Skip genesis block

          previous_block = @chain[i - 1]

          # 1. Check previous_hash reference
          return false if block.previous_hash != previous_block.hash

          # 2. Check block hash integrity
          return false if block.hash != block.calculate_hash
          
          # 3. Check Merkle Root integrity
          calculated_merkle_root = MerkleTree.new(block.data).root
          return false if block.merkle_root != calculated_merkle_root
        end

        true
      end

      def save_chain
        FileUtils.mkdir_p(File.dirname(@chain_file))
        File.write(@chain_file, JSON.pretty_generate(@chain.map(&:to_h)))
      end

      private

      def load_chain
        return nil unless File.exist?(@chain_file)

        json_data = JSON.parse(File.read(@chain_file), symbolize_names: true)
        
        json_data.map do |block_data|
          Block.new(
            index: block_data[:index],
            timestamp: Time.parse(block_data[:timestamp]),
            data: block_data[:data],
            previous_hash: block_data[:previous_hash],
            merkle_root: block_data[:merkle_root]
          )
        end
      rescue JSON::ParserError, ArgumentError
        nil
      end
    end
  end
end
