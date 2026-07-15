# frozen_string_literal: true

require_relative 'entry'
require_relative 'containment'
require 'json'
require 'fileutils'

module Hestia
  module Anchoring
    # Raised when a withdrawal's author is neither the target entry's depositor
    # nor the operator (ANC-5). Rejected at write time rather than appended as a
    # no-effect line, so the log cannot be griefed with unauthorized takedowns.
    class UnauthorizedWithdrawal < StandardError; end

    # The append-only, hash-chained, headed anchor log (ANC-1).
    #
    # Invariants realized here (scope X):
    #   - Append-only: entries are only ever pushed; never edited or deleted.
    #   - Hash-chained + headed: each entry binds the prior head; +head+ exposes
    #     the current chain head; +verify+ recomputes the chain from genesis and
    #     detects reorder / in-place edit / deletion.
    #   - Withdrawal-by-append: a withdrawal is a separate appended entry that
    #     marks its target withdrawn while keeping the target readable and the
    #     lineage recomputable (nothing committed is hidden or removed).
    #
    # Read cost is kept independent of chain length (ANC-9) via in-memory indices
    # (digest -> positions, source_id -> positions, entry_hash -> position,
    # target -> withdrawal positions) rebuilt on load.
    #
    # Out of scope here (seams for later slices):
    #   - ANC-2 field bounding / inertness validation (2B) — this store accepts
    #     what it is given; the write tool validates.
    #   - ANC-5 authentication and withdrawal authority (2C) — the withdrawer is
    #     recorded but authority is not enforced here.
    class Log
      DEFAULT_STORAGE_PATH = 'storage/hestia_anchor_log.json'
      STORAGE_VERSION = '1.0'

      # Depositor-supplied fields suppressed from an entry's public view once the
      # entry is withdrawn (ANC-1). The digest, algorithm, canonicalization,
      # moment, depositor, and chain position always remain visible.
      SURFACED_FIELDS = %w[source_id external_reference metadata].freeze
      EMPTY = [].freeze

      attr_reader :operator_id

      # +operator_id+ is the canonical identity of the place operator (ANC-5 /
      # ANC-8). It is the one identity permitted to withdraw any entry (operator
      # takedown duty); nil means no operator is designated, so only a depositor's
      # self-withdrawal is authorized.
      def initialize(storage_path: DEFAULT_STORAGE_PATH, operator_id: nil)
        # A blank operator id means "no operator designated", not an operator
        # named "" (which would make the authority guard misbehave).
        @operator_id = operator_id.to_s.strip.empty? ? nil : operator_id.to_s
        @storage_path = storage_path
        @mutex = Mutex.new
        @entries = []
        @by_hash = {}
        @by_digest = Hash.new { |h, k| h[k] = [] }
        @by_source = Hash.new { |h, k| h[k] = [] }
        @withdrawals_for = Hash.new { |h, k| h[k] = [] }
        load_storage
      end

      # Append an anchor entry. Returns the created Entry.
      def append_anchor(digest:, anchor_type:, source_id:, depositor:,
                        external_reference: nil, metadata: {}, moment: nil)
        # ANC-2 containment: the only intake gate. A rejected write never
        # reaches the store, so the log structurally cannot hold content.
        Containment.validate_anchor!(digest: digest, metadata: metadata,
                                     external_reference: external_reference)
        # ANC-5 attribution guarantee: every anchor is attributable. The
        # authenticated peer identity is bound by the WritePath; here we refuse an
        # anonymous deposit as defense-in-depth even on a direct call.
        require_identity!(depositor, 'depositor')
        @mutex.synchronize do
          entry = Entry.anchor(
            position: @entries.size,
            prev: current_head,
            digest: digest,
            anchor_type: anchor_type,
            source_id: source_id,
            depositor: depositor,
            external_reference: external_reference,
            metadata: metadata,
            moment: moment
          )
          commit(entry)
        end
      end

      # Append a withdrawal entry referencing +target+ (an anchor entry_hash).
      # 2A records the withdrawer but does NOT enforce authority (ANC-5 = 2C).
      def append_withdrawal(target:, withdrawer:, reason: nil, moment: nil)
        # ANC-2 also covers withdrawals: the reason is the sole depositor-supplied
        # field and must be inert and bounded.
        Containment.validate_withdrawal!(reason: reason)
        require_identity!(withdrawer, 'withdrawer')
        @mutex.synchronize do
          target = target.to_s
          existing = @by_hash[target]
          raise ArgumentError, "Unknown target entry: #{target}" unless existing
          raise ArgumentError, "Target is not an anchor entry: #{target}" unless existing.anchor?

          # ANC-5 authority: only the target's own depositor (self-correction) or
          # the operator (takedown duty) may withdraw. Anyone else is rejected.
          unless authorized_withdrawer?(withdrawer.to_s, existing)
            raise UnauthorizedWithdrawal,
                  "#{withdrawer} may not withdraw entry #{target} " \
                  '(only its depositor or the operator may)'
          end

          entry = Entry.withdrawal(
            position: @entries.size,
            prev: current_head,
            target: target,
            withdrawer: withdrawer,
            reason: reason,
            moment: moment
          )
          commit(entry)
        end
      end

      def head
        @mutex.synchronize { current_head }
      end

      def length
        @mutex.synchronize { @entries.size }
      end

      def entries
        @mutex.synchronize { @entries.dup }
      end

      def get(entry_hash)
        @mutex.synchronize { @by_hash[entry_hash.to_s] }
      end

      def find_by_digest(digest)
        d = Entry.normalize_digest(digest)
        @mutex.synchronize { @by_digest[d].map { |i| @entries[i] } }
      end

      def find_by_source_id(source_id)
        @mutex.synchronize { @by_source[source_id.to_s].map { |i| @entries[i] } }
      end

      def withdrawn?(entry_hash)
        @mutex.synchronize { !@withdrawals_for.fetch(entry_hash.to_s, EMPTY).empty? }
      end

      # Recompute the whole chain from genesis. Detects reorder (prev/position
      # mismatch), in-place edit (hash mismatch), and deletion (chain break).
      def verify
        @mutex.synchronize do
          prev = nil
          @entries.each_with_index do |entry, i|
            return failure(i, 'position_mismatch') unless entry.position == i
            return failure(i, 'prev_mismatch') unless entry.prev == prev
            recomputed = Entry.compute_hash(entry.canonical_content)
            return failure(i, 'hash_mismatch') unless recomputed == entry.entry_hash

            prev = entry.entry_hash
          end
          { valid: true, length: @entries.size, head: prev }
        end
      end

      # Public presentation of a single entry (ANC-7 shape; the unauthenticated
      # WebRouter view is slice 2, but the suppression logic lives here so both
      # the authenticated read (2E) and the public view (2S3) share it).
      # A withdrawn anchor entry keeps its digest/algorithm/canonicalization/
      # moment/depositor/position; its depositor-supplied surfaced fields are
      # suppressed.
      def view(entry_hash)
        @mutex.synchronize do
          entry = @by_hash[entry_hash.to_s]
          return nil unless entry

          withdrawn = !@withdrawals_for.fetch(entry.entry_hash, EMPTY).empty?
          out = {
            'entry_hash' => entry.entry_hash,
            'position' => entry.position,
            'kind' => entry.kind,
            'withdrawn' => withdrawn
          }
          if entry.anchor?
            body = entry.body.dup
            if withdrawn
              SURFACED_FIELDS.each { |f| body.delete(f) }
            end
            out['body'] = body
          else
            out['body'] = entry.body
          end
          out
        end
      end

      private

      def require_identity!(identity, role)
        return unless identity.nil? || identity.to_s.strip.empty?

        raise ArgumentError, "#{role} identity is required (writes must be attributable)"
      end

      def authorized_withdrawer?(withdrawer, target_entry)
        return true if withdrawer == target_entry.depositor
        return true if @operator_id && withdrawer == @operator_id

        false
      end

      def current_head
        @entries.empty? ? nil : @entries.last.entry_hash
      end

      # Commit an entry durably: mutate memory, then persist. If the durable
      # write fails, roll the in-memory append back so a caller told the write
      # failed cannot have it silently resurrected by the next successful append
      # (the entry is always the last one, so rollback is deterministic).
      def commit(entry)
        push(entry)
        begin
          save_storage
        rescue StandardError
          unpush_last!(entry)
          raise
        end
        entry
      end

      def push(entry)
        i = @entries.size
        @entries << entry
        index(entry, i)
      end

      def unpush_last!(entry)
        @entries.pop
        @by_hash.delete(entry.entry_hash)
        if entry.anchor?
          @by_digest[entry.digest].pop
          @by_source[entry.source_id].pop
        elsif entry.withdrawal?
          @withdrawals_for[entry.target].pop
        end
      end

      def index(entry, i)
        @by_hash[entry.entry_hash] = entry
        if entry.anchor?
          @by_digest[entry.digest] << i
          @by_source[entry.source_id] << i
        elsif entry.withdrawal?
          @withdrawals_for[entry.target] << i
        end
      end

      def failure(idx, reason)
        { valid: false, broken_at: idx, reason: reason, length: @entries.size }
      end

      def load_storage
        return unless File.exist?(@storage_path)

        raw = JSON.parse(File.read(@storage_path))
        (raw['entries'] || []).each_with_index do |h, i|
          entry = Entry.from_h(h)
          @entries << entry
          index(entry, i)
        end
      rescue StandardError
        # Corrupt store (bad JSON, invalid kind, missing field): degrade to empty
        # rather than crash on load. Reset every structure so a partial load does
        # not leave dangling indices. verify will then report length 0.
        reset_state!
      end

      def reset_state!
        @entries = []
        @by_hash = {}
        @by_digest = Hash.new { |h, k| h[k] = [] }
        @by_source = Hash.new { |h, k| h[k] = [] }
        @withdrawals_for = Hash.new { |h, k| h[k] = [] }
      end

      def save_storage
        FileUtils.mkdir_p(File.dirname(@storage_path))
        data = {
          'metadata' => {
            'version' => STORAGE_VERSION,
            'updated_at' => Time.now.utc.iso8601,
            'length' => @entries.size,
            'head' => current_head
          },
          'entries' => @entries.map(&:to_h)
        }
        content = JSON.pretty_generate(data)
        temp_path = "#{@storage_path}.tmp"
        File.write(temp_path, content)
        File.rename(temp_path, @storage_path)
      end
    end
  end
end
