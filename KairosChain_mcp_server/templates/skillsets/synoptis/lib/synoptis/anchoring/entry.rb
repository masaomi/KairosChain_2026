# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

module Synoptis
  # Anchoring realizes ANC-1 (hestia_anchor_attestation_design_v0.5):
  # an append-only, hash-chained, headed anchor log with withdrawal-by-append.
  # It is a NEW store, deliberately not a reuse of Chain::Backend's flat hash map
  # (design §11: "realizing ANC-1 requires actual chaining, not reuse of the
  # present structure").
  module Anchoring
    # An immutable line in the anchor log. Two kinds (design §3):
    #   - :anchor      commits a self-describing digest + inert bounded metadata.
    #   - :withdrawal  references a target anchor entry, marking it withdrawn
    #                  while keeping it readable; commits no new digest.
    #
    # Each entry binds the prior head (its +prev+ = the previous entry's
    # +entry_hash+), so the entries form a single ordered hash chain whose
    # integrity is recomputable from any later head. No content ever travels
    # with an entry — only a fixed-size digest and inert fields.
    class Entry
      KINDS = %w[anchor withdrawal].freeze

      # The committed self-description for scope-X anchoring (ANC-2). The digest
      # is SHA-256 over the artifact's raw bytes; the artifact itself is
      # author-normalized to LF + UTF-8 NFC before hashing (option B). Kept as a
      # constant so the canonicalization rule is committed, not implied.
      DIGEST_ALGORITHM = 'sha256'
      CANONICALIZATION = 'file-raw-bytes; author-normalized LF + UTF-8 NFC'

      attr_reader :position, :prev, :kind, :body, :entry_hash, :governing_identity

      # +governing_identity+ (AHM-3) is the governing identity in effect when the
      # entry was committed; it fixes per-entry same_party/foreign and withdrawal
      # authority and is deliberately kept OUT of canonical_content so it never
      # perturbs entry_hash (AHM-4). nil means old-format (pre-migration) entry;
      # the Log backfills it from the legacy governing identity on load.
      def initialize(position:, prev:, kind:, body:, entry_hash: nil, governing_identity: nil)
        raise ArgumentError, "Invalid kind: #{kind.inspect}" unless KINDS.include?(kind.to_s)

        @position = Integer(position)
        @prev = prev.nil? ? nil : prev.to_s
        @kind = kind.to_s
        @body = deep_stringify(body)
        @governing_identity = governing_identity.nil? ? nil : governing_identity.to_s
        @entry_hash = entry_hash || self.class.compute_hash(canonical_content)
      end

      # Build an anchor entry. +source_id+ is the content-independent
      # verification address (ANC-8 / design §4): it is supplied by the caller
      # BEFORE the digest is computed and is never derived from the artifact.
      #
      # +head_binding+ (MPR-1, auditability_head_anchor_design_v0.3) is the
      # committed internal-chain state binding, present only when the depositor
      # supplies one. It lives INSIDE the committed body — covered by
      # entry_hash and hence the log's hash chain — unlike governing_identity,
      # which is deliberately non-committed. Entries without a binding build a
      # body without the key, so every pre-existing entry's hash is unchanged
      # (AHM-4: binding attaches only to newly appended entries).
      def self.anchor(position:, prev:, digest:, anchor_type:, source_id:, depositor:,
                      external_reference: nil, metadata: {}, moment: nil,
                      governing_identity: nil, head_binding: nil)
        body = {
          'digest' => normalize_digest(digest),
          'digest_algorithm' => DIGEST_ALGORITHM,
          'canonicalization' => CANONICALIZATION,
          'anchor_type' => anchor_type.to_s,
          'source_id' => source_id.to_s,
          'depositor' => depositor.to_s,
          'external_reference' => external_reference,
          'metadata' => metadata || {},
          'moment' => moment || Time.now.utc.iso8601
        }
        body['head_binding'] = head_binding unless head_binding.nil?
        new(position: position, prev: prev, kind: 'anchor', body: body,
            governing_identity: governing_identity)
      end

      # Build a withdrawal entry referencing a target anchor entry by its
      # +entry_hash+. The withdrawer identity is recorded so ANC-5 (2C) can later
      # enforce authority; 2A records but does not enforce it.
      def self.withdrawal(position:, prev:, target:, withdrawer:, reason: nil, moment: nil)
        body = {
          'target' => target.to_s,
          'withdrawer' => withdrawer.to_s,
          'reason' => reason,
          'moment' => moment || Time.now.utc.iso8601
        }
        new(position: position, prev: prev, kind: 'withdrawal', body: body)
      end

      def self.from_h(hash)
        h = hash.transform_keys(&:to_s)
        new(
          position: h['position'],
          prev: h['prev'],
          kind: h['kind'],
          body: h['body'],
          entry_hash: h['entry_hash'],
          governing_identity: h['governing_identity']
        )
      end

      def anchor?
        @kind == 'anchor'
      end

      def withdrawal?
        @kind == 'withdrawal'
      end

      def digest
        @body['digest']
      end

      def source_id
        @body['source_id']
      end

      def depositor
        @body['depositor']
      end

      def target
        @body['target']
      end

      # The committed head binding, or nil for an ordinary anchor entry
      # (absence is a statement of provenance, design §3f).
      def head_binding
        @body['head_binding']
      end

      def to_h
        {
          'position' => @position,
          'prev' => @prev,
          'kind' => @kind,
          'body' => @body,
          'entry_hash' => @entry_hash,
          'governing_identity' => @governing_identity
        }
      end

      # The content that the entry_hash commits to. Note it excludes entry_hash
      # itself and binds +prev+ (the prior head), which is what makes reorder,
      # in-place edit, and deletion detectable on recompute.
      def canonical_content
        {
          'position' => @position,
          'prev' => @prev,
          'kind' => @kind,
          'body' => @body
        }
      end

      # Recompute the entry_hash from a stored entry's committed content. Used by
      # the log's verify pass; a mismatch means the entry was edited in place.
      def self.compute_hash(content)
        Digest::SHA256.hexdigest(canonical_json(content))
      end

      # Deterministic JSON: recursively sort hash keys so the digest is
      # insertion-order independent.
      def self.canonical_json(value)
        JSON.generate(canonicalize(value))
      end

      def self.canonicalize(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |k, acc|
            raw = value.key?(k) ? value[k] : value[k.to_sym]
            acc[k] = canonicalize(raw)
          end
        when Array
          value.map { |v| canonicalize(v) }
        else
          value
        end
      end

      def self.normalize_digest(digest)
        digest.to_s.downcase.sub(/\A0x/, '')
      end

      private

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
        when Array
          value.map { |v| deep_stringify(v) }
        else
          value
        end
      end
    end
  end
end
