# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'cumulative_commitment'

module Synoptis
  module Anchoring
    # Head binding construction and coherence (auditability_head_anchor_design
    # v0.3 §3c, MPR-1/3): the committed material an anchor entry carries about
    # internal-chain state at anchor time, computed under the khab-1 convention.
    #
    # This module is the OPERATOR side: it derives record commitments from
    # internal-chain blocks, builds bindings, and generates proof artifacts.
    # The auditor side needs none of this — verification lives in
    # CumulativeCommitment.verify_* plus the khab-1 definition (MPR-4).
    #
    # Determinism (MPR-3): every derivation here is a pure function of the
    # block sequence; the same chain state always yields the same binding.
    module HeadBinding
      CONVENTION_ID = 'khab-1'
      CONVENTION_PATH = File.expand_path('conventions/khab-1.md', __dir__)
      CHAIN_IDENTITY_PREFIX = 'block1-sha256:'
      HEX_DIGEST = CumulativeCommitment::HEX_DIGEST
      # Exclusive JSON-safe integer bound: khab-1 artifacts are JSON, and
      # integers beyond 2**53 - 1 lose precision in standard JSON consumers
      # (ANC-2 boundedness). Values must be strictly below this bound.
      JSON_SAFE_BOUND = 2**53

      # The committed field set (khab-1 §4). Exactly these keys, no others —
      # extensibility is a new convention, not a new field.
      FIELDS = %w[
        convention convention_sha256 chain_identity
        cumulative_root tree_size chain_head_index chain_head_hash
      ].freeze

      class BindingError < StandardError; end

      module_function

      # SHA-256 of the shipped convention definition's raw bytes (MPR-3: the
      # identifier resolves to a definition whose own integrity is checkable).
      # Memoized: the definition is immutable by rule (a change is khab-2).
      # A missing definition file is a deployment defect surfaced as a
      # structured BindingError, not a bare Errno, so the Containment gate
      # converts it instead of leaking an unstructured error.
      def convention_sha256
        @convention_sha256 ||= begin
          Digest::SHA256.hexdigest(File.binread(CONVENTION_PATH))
        rescue SystemCallError => e
          raise BindingError, "khab-1 convention definition unreadable at #{CONVENTION_PATH}: #{e.message}"
        end
      end

      # khab-1 §1: ordered record commitments across all blocks from genesis.
      # +blocks+ is the persisted chain shape: an ordered array of hashes with
      # 'data' (array of record strings) and 'hash'/'index' fields.
      # khab-1 §1 defines records as STRINGS: a non-string record is malformed
      # chain state and is refused rather than silently coerced — coercion
      # would anchor a commitment the convention does not define.
      def record_commitments(blocks)
        blocks.flat_map do |b|
          records_of(b).map do |r|
            raise BindingError, "record must be a String (khab-1 §1), got #{r.class}" unless r.is_a?(String)

            Digest::SHA256.hexdigest(r)
          end
        end
      end

      # khab-1 §5: content-derived committed identity from block index 1.
      # Genesis is identical across instances by construction, so identity
      # requires at least one real block; a genesis-only chain has no
      # committed identity yet and cannot carry a head binding.
      def chain_identity(blocks)
        b1 = blocks.find { |b| field(b, 'index') == 1 }
        raise BindingError, 'chain identity requires a block at index 1 (genesis-only chain has none)' unless b1

        h = field(b1, 'hash').to_s.downcase
        # Self-consistency: a malformed block-1 hash would interpolate into an
        # identity that build's own validator refuses.
        raise BindingError, "block-1 hash must be 64-char hex, got #{h.inspect}" unless h.match?(HEX_DIGEST)

        "#{CHAIN_IDENTITY_PREFIX}#{h}"
      end

      # Build the head binding for the chain state +blocks+ (khab-1 §4).
      def build(blocks)
        raise BindingError, 'cannot bind an empty chain' if blocks.nil? || blocks.empty?

        commitments = record_commitments(blocks)
        # Self-consistency: build must never return a binding its own
        # validator refuses (a chain whose blocks all carry empty data arrays
        # has no records to commit).
        raise BindingError, 'cannot bind a chain with no records' if commitments.empty?
        if commitments.size >= JSON_SAFE_BOUND
          raise BindingError, 'chain has more records than the JSON-safe bound'
        end

        head = blocks.last
        # Strict Integer, matching chain_identity's strict index match: a
        # string-typed index is malformed chain state, refused not coerced.
        head_index = field(head, 'index')
        unless head_index.is_a?(Integer) && head_index >= 0 && head_index < JSON_SAFE_BOUND
          raise BindingError,
                "head block index must be a non-negative JSON-safe Integer, got #{head_index.inspect}"
        end
        head_hash = field(head, 'hash').to_s.downcase
        raise BindingError, "head block hash must be 64-char hex, got #{head_hash.inspect}" unless head_hash.match?(HEX_DIGEST)

        {
          'convention' => CONVENTION_ID,
          'convention_sha256' => convention_sha256,
          'chain_identity' => chain_identity(blocks),
          'cumulative_root' => CumulativeCommitment.root(commitments),
          'tree_size' => commitments.size,
          'chain_head_index' => head_index,
          'chain_head_hash' => head_hash
        }
      end

      # Structural validation of a binding (the shape khab-1 §4 commits).
      # Raises BindingError with a stable message on the first violation.
      def validate!(binding)
        raise BindingError, "head_binding must be a Hash, got #{binding.class}" unless binding.is_a?(Hash)

        keys = binding.keys.map(&:to_s).sort
        unless keys == FIELDS.sort
          raise BindingError, "head_binding fields must be exactly #{FIELDS.sort.join(', ')}, got #{keys.join(', ')}"
        end

        b = binding.transform_keys(&:to_s)
        unless b['convention'] == CONVENTION_ID
          raise BindingError, "unknown convention #{b['convention'].inspect} (khab-1 only)"
        end
        %w[convention_sha256 cumulative_root chain_head_hash].each do |k|
          unless b[k].is_a?(String) && b[k].match?(HEX_DIGEST)
            raise BindingError, "head_binding.#{k} must be 64-char lowercase hex"
          end
        end
        # MPR-3 (after shape checks, so a malformed value gets the accurate
        # type message): a binding naming khab-1 with a digest that does not
        # match the shipped definition would be committed as permanently
        # unresolvable on an append-only log; refuse it at intake.
        unless b['convention_sha256'] == convention_sha256
          raise BindingError,
                "convention_sha256 #{b['convention_sha256'].inspect} does not match the shipped " \
                "khab-1 definition (#{convention_sha256}); binding would be unresolvable"
        end
        unless b['chain_identity'].is_a?(String) &&
               b['chain_identity'].match?(/\A#{Regexp.escape(CHAIN_IDENTITY_PREFIX)}[a-f0-9]{64}\z/)
          raise BindingError, "head_binding.chain_identity must be #{CHAIN_IDENTITY_PREFIX}<64-hex>"
        end
        unless b['tree_size'].is_a?(Integer) && b['tree_size'].positive? && b['tree_size'] < JSON_SAFE_BOUND
          raise BindingError, 'head_binding.tree_size must be a positive integer below 2**53'
        end
        unless b['chain_head_index'].is_a?(Integer) && b['chain_head_index'] >= 0 &&
               b['chain_head_index'] < JSON_SAFE_BOUND
          raise BindingError, 'head_binding.chain_head_index must be a non-negative integer below 2**53'
        end
        true
      end

      # Operator/L3-side coherence check (MPR-1): every verifiable component of
      # +binding+ is re-derivable from +blocks+ under the committed convention.
      # Returns { coherent:, mismatches: [...] }; informational components are
      # compared too but reported separately — their mismatch does not borrow
      # or lend proof-grade credibility.
      # Diagnostic: never raises on malformed chain state — an operator asking
      # "is this binding coherent with this chain?" gets an incoherent verdict
      # with the reason, not an exception.
      def coherence(binding, blocks)
        rebuilt = begin
          build(blocks)
        rescue BindingError => e
          return { coherent: false, mismatches: ["build_failed: #{e.message}"], informational_mismatches: [] }
        end
        verifiable = %w[convention convention_sha256 cumulative_root tree_size chain_identity]
        informational = %w[chain_head_index chain_head_hash]
        b = binding.transform_keys(&:to_s)
        mism = verifiable.reject { |k| b[k] == rebuilt[k] }
        info_mism = informational.reject { |k| b[k] == rebuilt[k] }
        { coherent: mism.empty?, mismatches: mism, informational_mismatches: info_mism }
      end

      # Inclusion-proof artifact (khab-1 §3) for the record at +index+ of the
      # state +blocks+, targeted at +binding+. Carries only hashes and
      # structural data (MPR-2).
      def inclusion_proof_artifact(blocks, index, binding)
        validate!(binding)
        commitments = record_commitments(blocks)
        b = binding.transform_keys(&:to_s)
        require_state_match!(commitments, b, 'binding')

        # Range-checks index (ProofError) before any element access.
        path = CumulativeCommitment.inclusion_proof(commitments, index)
        {
          'format' => 'khab-1/inclusion',
          'chain_identity' => b['chain_identity'],
          'record_commitment' => commitments.fetch(index),
          'index' => index,
          'tree_size' => b['tree_size'],
          'path' => path,
          'cumulative_root' => b['cumulative_root']
        }
      end

      # Consistency-proof artifact (khab-1 §3) from +earlier_binding+ to
      # +later_binding+, generated from the current state +blocks+ (which must
      # realize the later binding). MPR-9: demonstrates the later commitment
      # includes the earlier's entire sequence unchanged as a prefix.
      def consistency_proof_artifact(blocks, earlier_binding, later_binding)
        validate!(earlier_binding)
        validate!(later_binding)
        e = earlier_binding.transform_keys(&:to_s)
        l = later_binding.transform_keys(&:to_s)
        unless e['chain_identity'] == l['chain_identity']
          raise BindingError, 'consistency relates bindings committing the same chain identity (MPR-9)'
        end
        unless e['tree_size'] <= l['tree_size']
          raise BindingError,
                "earlier binding commits tree_size #{e['tree_size']} > later #{l['tree_size']}; " \
                'not an extension'
        end

        commitments = record_commitments(blocks)
        require_state_match!(commitments, l, 'later binding')
        # The earlier binding must root the actual size-first_size prefix of
        # this state; otherwise the emitted artifact could pair genuine roots
        # with a path derived from an unrelated sequence and fail opaquely at
        # verification instead of loudly at generation.
        prefix_root = CumulativeCommitment.root(commitments[0...e['tree_size']])
        unless prefix_root == e['cumulative_root']
          raise BindingError,
                "earlier binding's cumulative_root does not derive from this chain state's " \
                "first #{e['tree_size']} records; not a prefix of this history"
        end

        {
          'format' => 'khab-1/consistency',
          'chain_identity' => l['chain_identity'],
          'first_root' => e['cumulative_root'],
          'first_size' => e['tree_size'],
          'second_root' => l['cumulative_root'],
          'second_size' => l['tree_size'],
          'path' => CumulativeCommitment.consistency_proof(commitments, e['tree_size'])
        }
      end

      # Load the persisted chain shape from a blockchain.json path (the
      # append-side convenience used by tools and the inaugural script).
      # A proof artifact pairs a binding's committed root with structural data
      # derived from +commitments+; both must describe the same state, by
      # extent AND by recomputed root (equal count with divergent content must
      # fail loudly at generation, not opaquely at verification).
      def require_state_match!(commitments, b, label)
        unless commitments.size == b['tree_size']
          raise BindingError,
                "chain state has #{commitments.size} records but #{label} commits tree_size #{b['tree_size']}"
        end
        recomputed = CumulativeCommitment.root(commitments)
        return if recomputed == b['cumulative_root']

        raise BindingError,
              "#{label}'s cumulative_root #{b['cumulative_root']} does not derive from this " \
              "chain state (recomputed #{recomputed})"
      end

      def load_blocks(path)
        parsed = JSON.parse(File.read(path))
        blocks = parsed.is_a?(Hash) ? (parsed['blocks'] || parsed['chain']) : parsed
        raise BindingError, "no block array found in #{path}" unless blocks.is_a?(Array)

        blocks
      end

      def records_of(block)
        data = field(block, 'data')
        raise BindingError, "block data must be an Array of records, got #{data.class}" unless data.is_a?(Array)

        data
      end

      # Key-presence lookup, not `||` fallback: a legitimately falsy value under
      # the string key must not fall through to the symbol key.
      def field(block, name)
        raise BindingError, "block must be a Hash, got #{block.class}" unless block.is_a?(Hash)
        return block[name] if block.key?(name)

        block[name.to_sym]
      end
    end
  end
end
