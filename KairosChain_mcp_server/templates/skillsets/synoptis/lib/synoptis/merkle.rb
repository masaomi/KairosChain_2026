# frozen_string_literal: true

require 'digest'

module Synoptis
  class MerkleTree
    attr_reader :leaves, :root

    def initialize(leaves)
      raise ArgumentError, 'At least one leaf is required' if leaves.nil? || leaves.empty?

      @leaves = leaves.map { |l| leaf_hash(l) }
      @tree = build_tree(@leaves)
      @root = @tree.last.first
    end

    # Generate proof path for a given leaf index
    def proof_for(index)
      raise IndexError, "Index #{index} out of range (0..#{@leaves.size - 1})" if index < 0 || index >= @leaves.size

      proof = []
      current_level = @tree.first
      idx = index

      @tree[0...-1].each do |level|
        if idx.even?
          sibling_idx = idx + 1
          side = :right
        else
          sibling_idx = idx - 1
          side = :left
        end

        if sibling_idx < level.size
          proof << { hash: level[sibling_idx], side: side }
        else
          # Odd level: last node is duplicated (same as build_tree)
          proof << { hash: level[idx], side: side }
        end

        idx /= 2
      end

      proof
    end

    # Verify a leaf against a proof and expected root
    def self.verify(leaf, proof, expected_root)
      current = Digest::SHA256.hexdigest(leaf.to_s)

      proof.each do |step|
        if step[:side] == :right
          current = Digest::SHA256.hexdigest(current + step[:hash])
        else
          current = Digest::SHA256.hexdigest(step[:hash] + current)
        end
      end

      current == expected_root
    end

    private

    def leaf_hash(data)
      Digest::SHA256.hexdigest(data.to_s)
    end

    def build_tree(leaves)
      tree = [leaves.dup]

      current_level = leaves.dup
      while current_level.size > 1
        next_level = []
        current_level.each_slice(2) do |left, right|
          right ||= left # duplicate last node if odd
          next_level << Digest::SHA256.hexdigest(left + right)
        end
        tree << next_level
        current_level = next_level
      end

      tree
    end
  end
end
