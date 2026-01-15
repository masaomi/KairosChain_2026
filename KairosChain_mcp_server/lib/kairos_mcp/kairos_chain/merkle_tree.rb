require 'digest'

module KairosMcp
  module KairosChain
    class MerkleTree
      attr_reader :leaves, :root

      def initialize(data)
        @leaves = data.map { |d| Digest::SHA256.hexdigest(d) }
        @root = calculate_root(@leaves)
      end

      def calculate_root(hashes)
        return "" if hashes.empty?
        return hashes.first if hashes.length == 1

        next_level = []
        
        hashes.each_slice(2) do |left, right|
          if right
            combined = left + right
            next_level << Digest::SHA256.hexdigest(combined)
          else
            # If odd number of leaves, duplicate the last one
            combined = left + left
            next_level << Digest::SHA256.hexdigest(combined)
          end
        end

        calculate_root(next_level)
      end

      # Generate Merkle Proof for a specific data item
      def get_proof(data)
        target_hash = Digest::SHA256.hexdigest(data)
        index = @leaves.index(target_hash)
        return nil unless index

        proof = []
        current_hashes = @leaves

        while current_hashes.length > 1
          level_proof = []
          next_level = []

          current_hashes.each_slice(2) do |left, right|
            if right
              # Pair found
              if left == target_hash
                proof << { position: 'right', data: right }
                target_hash = Digest::SHA256.hexdigest(left + right)
              elsif right == target_hash
                proof << { position: 'left', data: left }
                target_hash = Digest::SHA256.hexdigest(left + right)
              end
              next_level << Digest::SHA256.hexdigest(left + right)
            else
              # Odd number, duplicate last
              if left == target_hash
                proof << { position: 'right', data: left }
                target_hash = Digest::SHA256.hexdigest(left + left)
              end
              next_level << Digest::SHA256.hexdigest(left + left)
            end
          end
          current_hashes = next_level
        end

        proof
      end

      # Verify a proof
      def self.verify(root, data, proof)
        current_hash = Digest::SHA256.hexdigest(data)

        proof.each do |node|
          if node[:position] == 'left'
            current_hash = Digest::SHA256.hexdigest(node[:data] + current_hash)
          else
            current_hash = Digest::SHA256.hexdigest(current_hash + node[:data])
          end
        end

        current_hash == root
      end
    end
  end
end
