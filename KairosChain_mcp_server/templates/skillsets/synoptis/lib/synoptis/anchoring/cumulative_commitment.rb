# frozen_string_literal: true

require 'digest'

module Synoptis
  module Anchoring
    # The anchored cumulative commitment (auditability_head_anchor_design_v0.3,
    # §3b) and its proof arithmetic (MPR-2/3/8/9).
    #
    # A single root commits to the ENTIRE ordered sequence of record commitments
    # of the internal chain up to the anchor moment — not to any one block or
    # sub-range. Inclusion proofs bind one record commitment to a definite
    # position within that sequence (MPR-8); consistency proofs demonstrate that
    # a later root commits to an extension of the sequence an earlier root
    # commits to (MPR-9).
    #
    # Construction follows the RFC 6962 / RFC 9162 Merkle tree exactly:
    #   leaf hash     = SHA-256(0x00 || leaf_bytes)
    #   interior hash = SHA-256(0x01 || left || right)
    #   split point   = largest power of two strictly less than n
    # The 0x00/0x01 domain prefixes realize MPR-3's ambiguity exclusion: no
    # interior node can verify as a record commitment or vice versa. The
    # existing KairosChain::MerkleTree (per-block, unprefixed, odd-leaf
    # duplication) is deliberately NOT reused — it lacks role separation and its
    # duplication rule admits distinct sequences with equal roots.
    #
    # Leaves are record commitments: fixed-size hex digests (§3a). No record
    # content enters this module, and proofs carry only hashes plus structural
    # data (MPR-2).
    #
    # The verify_* functions are the auditor side (MPR-4): pure functions of
    # (proof, root(s), leaf, positions) with no chain, log, or filesystem
    # dependency, so they can ship in an offline verifier.
    module CumulativeCommitment
      LEAF_PREFIX = "\x00".b
      NODE_PREFIX = "\x01".b
      HEX_DIGEST = /\A[a-f0-9]{64}\z/

      class ProofError < StandardError; end

      module_function

      # Root over an ordered sequence of record commitments (hex digests).
      # Deterministic under the committed convention (MPR-3): same sequence,
      # same root. Empty sequence commits to SHA-256("") per RFC 6962.
      def root(record_commitments)
        mth(record_commitments.map { |c| leaf_bytes(c) }).unpack1('H*')
      end

      # Audit path for the record at +index+ within the full sequence.
      # Returns an array of hex sibling hashes, leaf-to-root order.
      def inclusion_proof(record_commitments, index)
        n = record_commitments.size
        raise ProofError, "index must be an Integer, got #{index.class}" unless index.is_a?(Integer)
        raise ProofError, "index #{index} out of range for #{n} records" unless index >= 0 && index < n

        path(index, record_commitments.map { |c| leaf_bytes(c) }).map { |h| h.unpack1('H*') }
      end

      # Consistency path from the prefix of size +first_size+ to the full
      # sequence. Returns hex hashes. Empty when first_size == n (same tree).
      def consistency_proof(record_commitments, first_size)
        n = record_commitments.size
        raise ProofError, "first_size must be an Integer, got #{first_size.class}" unless first_size.is_a?(Integer)
        unless first_size >= 1 && first_size <= n
          raise ProofError, "first_size #{first_size} out of range for #{n} records"
        end
        return [] if first_size == n

        subproof(first_size, record_commitments.map { |c| leaf_bytes(c) }, true)
          .map { |h| h.unpack1('H*') }
      end

      # Auditor-side inclusion verification (RFC 9162 §2.1.3.2). Inputs are
      # exactly the MPR-4 trust base slice this artifact needs: the record
      # commitment, its committed position, the committed extent, the path, and
      # the published root. True only when the recomputed root matches.
      def verify_inclusion(record_commitment:, index:, tree_size:, path:, root:)
        return false unless index.is_a?(Integer) && tree_size.is_a?(Integer)
        return false unless index >= 0 && index < tree_size
        return false unless valid_hex?(record_commitment) && valid_hex?(root)
        return false unless path.is_a?(Array) && path.all? { |p| valid_hex?(p) }

        fn = index
        sn = tree_size - 1
        r = hash_leaf(leaf_bytes(record_commitment))
        path.each do |p|
          return false if sn.zero?

          pb = hex_bytes(p)
          if fn.odd? || fn == sn
            r = hash_children(pb, r)
            if fn.even?
              until fn.odd? || fn.zero?
                fn >>= 1
                sn >>= 1
              end
            end
          else
            r = hash_children(r, pb)
          end
          fn >>= 1
          sn >>= 1
        end
        sn.zero? && r.unpack1('H*') == root.downcase
      end

      # Auditor-side consistency verification (RFC 9162 §2.1.4.2). Establishes
      # that +second_root+ commits to an extension of the sequence +first_root+
      # commits to (MPR-9). A verified FAILURE of an operator-supplied proof is
      # not an inconsistency witness by itself (design §11); this returns
      # true/false only.
      def verify_consistency(first_root:, first_size:, second_root:, second_size:, path:)
        return false unless first_size.is_a?(Integer) && second_size.is_a?(Integer)
        return false unless valid_hex?(first_root) && valid_hex?(second_root)
        return false unless path.is_a?(Array) && path.all? { |p| valid_hex?(p) }
        return false unless first_size >= 1 && first_size <= second_size

        if first_size == second_size
          return path.empty? && first_root.downcase == second_root.downcase
        end

        work = path.map { |p| hex_bytes(p) }
        # An exact power-of-two prefix is a complete subtree: its root is
        # already known to the verifier, so the path omits it.
        work.unshift(hex_bytes(first_root)) if power_of_two?(first_size)
        return false if work.empty?

        fn = first_size - 1
        sn = second_size - 1
        while fn.odd?
          fn >>= 1
          sn >>= 1
        end

        fr = sr = work.shift
        work.each do |c|
          return false if sn.zero?

          if fn.odd? || fn == sn
            fr = hash_children(c, fr)
            sr = hash_children(c, sr)
            if fn.even?
              until fn.odd? || fn.zero?
                fn >>= 1
                sn >>= 1
              end
            end
          else
            sr = hash_children(sr, c)
          end
          fn >>= 1
          sn >>= 1
        end
        sn.zero? &&
          fr.unpack1('H*') == first_root.downcase &&
          sr.unpack1('H*') == second_root.downcase
      end

      # --- internal tree arithmetic (binary domain) ---

      def mth(leaves)
        return Digest::SHA256.digest('') if leaves.empty?
        return hash_leaf(leaves.first) if leaves.size == 1

        k = split_point(leaves.size)
        hash_children(mth(leaves[0...k]), mth(leaves[k..]))
      end

      def path(m, leaves)
        return [] if leaves.size == 1

        k = split_point(leaves.size)
        if m < k
          path(m, leaves[0...k]) + [mth(leaves[k..])]
        else
          path(m - k, leaves[k..]) + [mth(leaves[0...k])]
        end
      end

      def subproof(m, leaves, complete)
        n = leaves.size
        if m == n
          return complete ? [] : [mth(leaves)]
        end

        k = split_point(n)
        if m <= k
          subproof(m, leaves[0...k], complete) + [mth(leaves[k..])]
        else
          subproof(m - k, leaves[k..], false) + [mth(leaves[0...k])]
        end
      end

      def split_point(n)
        k = 1
        k <<= 1 while (k << 1) < n
        k
      end

      def hash_leaf(leaf)
        Digest::SHA256.digest(LEAF_PREFIX + leaf)
      end

      def hash_children(left, right)
        Digest::SHA256.digest(NODE_PREFIX + left + right)
      end

      def leaf_bytes(record_commitment)
        c = record_commitment.to_s.downcase
        raise ProofError, "record commitment must be 64-char hex, got #{record_commitment.inspect}" unless c.match?(HEX_DIGEST)

        [c].pack('H*')
      end

      def hex_bytes(hex)
        [hex.to_s.downcase].pack('H*')
      end

      def valid_hex?(value)
        value.is_a?(String) && value.downcase.match?(HEX_DIGEST)
      end

      def power_of_two?(n)
        n.positive? && (n & (n - 1)).zero?
      end
    end
  end
end
