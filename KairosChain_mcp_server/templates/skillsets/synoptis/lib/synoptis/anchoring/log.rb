# frozen_string_literal: true

require_relative 'entry'
require_relative 'containment'
require_relative 'attestation_types'
require 'json'
require 'fileutils'

module Synoptis
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
      # The persisted shape is append-line (AHM-5 / design §M3): one JSON entry
      # per line, so a commit appends a single line (O(1)) instead of rewriting
      # the whole store (O(n)). STORAGE_VERSION tags the superseded single-object
      # `.json` shape, which +load_storage+ still reads for backward compatibility
      # (AHM-9 i). The append-line shape is header-less by design: a leading
      # version line would break "1 line = 1 entry" and the torn-tail recovery, so
      # the format is instead detected from content shape on load.
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
      # +legacy_governing_identity+ (AHM-3/AHM-7) is the governing identity to
      # backfill onto old-format anchor entries (those persisted before the
      # per-entry governing_identity field existed). All pre-migration entries
      # were committed under a single owning identity, so a uniform backfill is
      # sound. When nil, it defaults to @operator_id (the current owning identity).
      def initialize(storage_path: DEFAULT_STORAGE_PATH, operator_id: nil,
                     legacy_governing_identity: nil)
        # A blank operator id means "no operator designated", not an operator
        # named "" (which would make the authority guard misbehave).
        @operator_id = operator_id.to_s.strip.empty? ? nil : operator_id.to_s
        @legacy_governing_identity =
          legacy_governing_identity.nil? ? @operator_id : legacy_governing_identity.to_s
        @storage_path = storage_path
        @mutex = Mutex.new
        @entries = []
        @by_hash = {}
        @by_digest = Hash.new { |h, k| h[k] = [] }
        @by_source = Hash.new { |h, k| h[k] = [] }
        @withdrawals_for = Hash.new { |h, k| h[k] = [] }
        # Append-line durability bookkeeping. @appendable means the on-disk file is
        # in append-line shape and reflects the first @persisted_count entries, so
        # the next commit can append a single line. It is cleared when a legacy
        # `.json` was loaded or a torn tail was recovered, forcing the next write to
        # rewrite the whole store atomically before O(1) appends resume.
        @appendable = true
        @persisted_count = 0
        load_storage
      end

      # Append an anchor entry. Returns the created Entry.
      # +head_binding+ (MPR-1): optional committed internal-chain state binding;
      # validated by Containment, carried inside the committed body, attached
      # only to this newly appended entry (AHM-4 untouched for prior entries).
      def append_anchor(digest:, anchor_type:, source_id:, depositor:,
                        external_reference: nil, metadata: {}, moment: nil,
                        head_binding: nil, attestation_type: nil)
        # ANC-2 containment: the only intake gate. A rejected write never
        # reaches the store, so the log structurally cannot hold content.
        Containment.validate_anchor!(digest: digest, metadata: metadata,
                                     external_reference: external_reference,
                                     head_binding: head_binding)
        # MAP-4 (map-1 §3): a declared attestation type must come from the
        # vocabulary, and a retraction must reference its target unambiguously.
        # Untyped (nil) stays valid — pre-map-1 provenance, not a defect.
        AttestationTypes.validate_intake!(attestation_type, metadata)
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
            moment: moment,
            governing_identity: @operator_id,
            head_binding: head_binding,
            attestation_type: attestation_type
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
        @mutex.synchronize { verify_unlocked }
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
      #
      # A failed append may have flushed a partial (torn) line onto the file's
      # tail. Clearing @appendable forces the next write down rewrite_all, which
      # atomically overwrites those stale bytes — without this, the next append
      # would write PAST the torn tail, producing an unrecoverable mid-file torn
      # line (and either silently dropping the committed entry or degrading the
      # whole store to empty on the following load). This restores the old
      # whole-file-rewrite guarantee of "fully-old or fully-new".
      def commit(entry)
        push(entry)
        begin
          save_storage
        rescue StandardError
          unpush_last!(entry)
          @appendable = false
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

      # Recompute the whole chain from genesis without taking the mutex, so it can
      # be reused by +verify+ (which locks) and by +load_storage+ (which runs
      # single-threaded during construction) for torn-tail detection.
      def verify_unlocked
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

      # Load the persisted chain. Two on-disk shapes are accepted (AHM-9 i):
      #   - append-line (current): one JSON entry per line. Load reads every line
      #     and rebuilds the indices; a torn final line is recovered.
      #   - legacy `.json` (pre-S2): a single pretty-printed {metadata, entries:[…]}
      #     object. Read for backward compatibility; the first durable write after
      #     such a load rewrites the file in append-line form.
      # A corrupt store degrades to empty (verify then reports length 0) rather
      # than crashing on load.
      def load_storage
        return unless File.exist?(@storage_path)

        content = File.read(@storage_path)
        if legacy_json?(content)
          load_legacy_json(content)
        else
          load_append_lines(content)
        end
      rescue StandardError
        # Corrupt store (bad JSON, invalid kind, missing field): degrade to empty
        # rather than crash on load. Reset every structure so a partial load does
        # not leave dangling indices. verify will then report length 0.
        reset_state!
      end

      # A legacy store is a single JSON object carrying an +entries+ array. A
      # multi-line append-line store is not parseable as one object (the parser
      # errors after the first line), and a lone append-line entry parses to an
      # object WITHOUT +entries+ — both fall through to the append-line loader.
      def legacy_json?(content)
        parsed = JSON.parse(content)
        parsed.is_a?(Hash) && parsed.key?('entries')
      rescue JSON::ParserError
        false
      end

      def load_legacy_json(content)
        raw = JSON.parse(content)
        (raw['entries'] || []).each { |h| ingest_entry(h) }
        # The on-disk shape is legacy; force the next durable write to rewrite the
        # whole file in append-line form rather than appending onto the old object.
        @appendable = false
        @persisted_count = 0
      end

      def load_append_lines(content)
        lines = content.split("\n")
        last_nonempty = nil
        lines.each_with_index { |l, i| last_nonempty = i unless l.strip.empty? }

        parsed = []
        torn = false
        lines.each_with_index do |line, i|
          s = line.strip
          next if s.empty?

          begin
            parsed << JSON.parse(s)
          rescue JSON::ParserError
            # A parse failure on the last non-empty line is a torn append (a crash
            # mid-write left a truncated final line): drop only that line and keep
            # every fully-written entry before it. A parse failure anywhere earlier
            # is real corruption -> propagate -> degrade to empty. Because O_APPEND
            # only ever extends the file, a torn write can corrupt the tail alone.
            raise unless i == last_nonempty

            torn = true
            break
          end
        end

        parsed.each { |h| ingest_entry(h) }

        # Load stays lenient — it never validates the chain. A truncated final line
        # is a torn append and is dropped above (its bytes fail to parse); an
        # in-place edit / reorder / deletion parses fine and loads intact, leaving
        # +verify+ as the sole integrity oracle (it recomputes from genesis and
        # reports the break). This keeps durability recovery and integrity checking
        # separate: load recovers a torn tail, verify detects tampering.
        #
        # A recovered torn tail leaves stale bytes on disk, so force a clean atomic
        # rewrite on the next write. An intact append-line file stays in O(1) mode.
        @appendable = !torn
        @persisted_count = @entries.size
      end

      # Reconstruct one entry from its persisted hash and append it to the in-memory
      # chain, backfilling the governing identity of an old-format anchor
      # (AHM-3/AHM-7): such an anchor loads with nil governing_identity, so rebuild
      # it under the legacy governing identity for correct per-entry relation and
      # withdrawal authority. Because governing_identity is excluded from
      # canonical_content and from_h passes the stored entry_hash through unchanged,
      # entry_hash is preserved (AHM-4).
      def ingest_entry(h)
        entry = Entry.from_h(h)
        if entry.anchor? && entry.governing_identity.nil?
          entry = Entry.from_h(h.merge('governing_identity' => @legacy_governing_identity))
        end
        i = @entries.size
        @entries << entry
        index(entry, i)
      end

      def reset_state!
        @entries = []
        @by_hash = {}
        @by_digest = Hash.new { |h, k| h[k] = [] }
        @by_source = Hash.new { |h, k| h[k] = [] }
        @withdrawals_for = Hash.new { |h, k| h[k] = [] }
        # This runs only on the corrupt-degrade path (load_storage rescue): a file
        # exists on disk but could not be parsed, so its stale bytes remain. Force
        # the next write down rewrite_all (which atomically overwrites the file)
        # rather than appending onto the corrupt bytes — the same protection the
        # legacy-load path relies on. A genuinely empty store (no file) never
        # reaches here; load_storage returns early and initialize's @appendable
        # default handles the clean first append.
        @appendable = false
        @persisted_count = 0
      end

      # Durably persist the most recent commit. In steady state exactly one entry
      # has been appended in memory since the last save, so a single line is
      # appended to the file (O(1)) and fsync'd. When the on-disk shape is stale
      # (a legacy `.json` was loaded, a torn tail was recovered, or the counts
      # diverged) the whole chain is rewritten atomically in append-line form,
      # which also re-establishes O(1) appends afterwards.
      def save_storage
        if @appendable && @persisted_count == @entries.size - 1
          append_last_line
        else
          rewrite_all
        end
      end

      # Append one line for the last committed entry. If the write fails, roll the
      # file back to its pre-append byte length before re-raising: because this
      # branch runs only when the file is a clean append-line prefix of exactly
      # @persisted_count entries, that length is the last durable state. This
      # prevents an UNACKNOWLEDGED line from surviving to disk and being read as
      # committed after a process restart — not only a torn partial line but also a
      # COMPLETE line whose fsync failed (the close still flushes it to the page
      # cache). It restores the append path's "fully-old or fully-new" guarantee,
      # matching the whole-file rewrite it replaced. Truncation is best-effort; the
      # commit rescue additionally clears @appendable so the next write rewrites
      # the whole file atomically regardless.
      def append_last_line
        FileUtils.mkdir_p(File.dirname(@storage_path))
        size_before = File.exist?(@storage_path) ? File.size(@storage_path) : 0
        begin
          write_entry_line(@entries.last)
        rescue StandardError
          truncate_storage(size_before)
          raise
        end
        @persisted_count += 1
      end

      def write_entry_line(entry)
        File.open(@storage_path, 'a') do |f|
          f.puts(JSON.generate(entry.to_h))
          f.fsync
        end
      end

      def truncate_storage(size)
        File.open(@storage_path, 'r+') do |f|
          f.truncate(size)
          f.fsync
        end
      rescue StandardError
        nil
      end

      # Atomic full rewrite: build the append-line file under a temp path, fsync,
      # then rename over the target. A crash leaves either the intact old file or
      # the intact new one — never a half-written store.
      def rewrite_all
        FileUtils.mkdir_p(File.dirname(@storage_path))
        temp_path = "#{@storage_path}.tmp"
        File.open(temp_path, 'w') do |f|
          @entries.each { |e| f.puts(JSON.generate(e.to_h)) }
          f.fsync
        end
        File.rename(temp_path, @storage_path)
        @appendable = true
        @persisted_count = @entries.size
      end
    end
  end
end
