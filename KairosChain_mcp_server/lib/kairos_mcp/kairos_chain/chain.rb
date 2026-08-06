require_relative 'block'
require_relative 'merkle_tree'
require 'json'
require 'time'
require 'fileutils'
require_relative '../storage/backend'
require_relative '../../kairos_mcp'

module KairosMcp
  module KairosChain
    # Raised when the ledger's state on disk forbids appending, when a re-entrant
    # append is attempted, or when the storage backend does not declare the
    # contract of INV-G. Nothing has been written to the ledger; the lock file and
    # its parent directory may have been created.
    #
    # #state carries one of Chain::LOAD_STATES.
    class ChainStateError < StandardError
      attr_reader :state

      def initialize(message, state:)
        super(message)
        @state = state
      end
    end

    # INV-D: an append may only add a block to the end of the sequence that is on
    #        disk at that moment. The in-memory sequence never replaces the one on
    #        disk. When the sequence on disk cannot be determined, nothing is
    #        appended.
    # INV-E: the ledger's state is carried by one entrance that every reader
    #        passes through (#load_state), not by the block sequence.
    # INV-G: under a backend that does not declare its contract, Chain refuses to
    #        append and reads the ledger as unreadable.
    class Chain
      # The five values #load_state can take. Only :readable and :absent permit an
      # append; only :readable makes #chain / #latest_block meaningful.
      LOAD_STATES = %i[absent unreadable empty corrupt readable].freeze

      # Re-entrancy flag. Thread-level (not fiber-level) on purpose: an append may
      # cross fibers, and a nested append would deadlock on its own flock.
      APPEND_FLAG = :kairos_chain_append_in_progress

      EMPTY_CHAIN = [].freeze

      attr_reader :load_state

      # @param chain_file [String, nil] dead argument, kept for call-site compatibility
      # @param storage_backend [Storage::Backend, nil] storage backend to use
      # Constructing the default backend can itself fail — a malformed config
      # scalar, a data directory that cannot be created on a read-only or full
      # mount. That construction is therefore deferred into the protected region
      # of classify_disk; doing it here would put it outside every rescue and
      # break "Chain.new never raises".
      def initialize(chain_file: nil, storage_backend: nil)
        # FIX B — NEW CLAIM: Chain.new resolves no paths of its own, so it
        # returns an object for every input. KairosMcp.blockchain_path here ran
        # outside every rescue and raised for an unresolvable data directory
        # (KAIROS_DATA_DIR='~nosuchuser/…' → ArgumentError; deleted CWD →
        # Errno::ENOENT from Dir.pwd — both measured). @chain_file is dead
        # (assigned, never read); the argument is kept for call-site
        # compatibility only. Path resolution now happens solely inside
        # classify_disk's protected region, where it degrades to :unreadable.
        @chain_file = chain_file
        @storage_backend = storage_backend
        @load_state, @chain = classify_disk
      end

      # The block sequence, but only when the ledger was readable. Every other
      # state yields a frozen empty array: callers must consult #load_state first.
      def chain
        @load_state == :readable ? @chain : EMPTY_CHAIN
      end

      def latest_block
        @load_state == :readable ? @chain.last : nil
      end

      # An alias for "the ledger was readable". Not a separate integrity pass:
      # the four predicates of §3 already ran during classification.
      def valid?
        @load_state == :readable
      end

      # Append one block to whatever is on disk right now.
      #
      # @return [Block] the appended block
      # @raise [ChainStateError] nothing was written to the ledger
      # @raise [Storage::Error] it is unknown whether the write landed; re-read
      def add_block(data)
        # ⓪ flag first, before the lock: a nested append would deadlock on its own
        #    flock. The path question is asked here too, so a backend that answers
        #    a relative path is refused before any file is created.
        if Thread.current.thread_variable_get(APPEND_FLAG)
          raise ChainStateError.new(
            'append already in progress on this thread (nested append is forbidden)',
            state: @load_state
          )
        end
        path = ledger_path

        Thread.current.thread_variable_set(APPEND_FLAG, true)
        begin
          # ① take the key (a file beside the ledger, never the ledger itself)
          with_lock(path) do
            # ② read disk and classify
            state, disk_blocks = classify_disk

            # ③ refuse anything that is neither readable nor absent
            unless %i[readable absent].include?(state)
              raise ChainStateError.new("cannot append: ledger is #{state}", state: state)
            end

            # ④ the base is the disk sequence, or a genesis-only sequence
            base = state == :readable ? disk_blocks : [Block.genesis]

            # ⑤ build on the base's tail and write base + new
            new_block = build_block(base.last, data)
            appended = base + [new_block]
            storage_backend.save_all_blocks(appended.map(&:to_h))

            # ⑥ only a successful write advances this instance's sequence and state
            @chain = appended
            @load_state = :readable

            new_block
          end
        ensure
          # ⑦ lower the flag — reached only by the call that raised it, because ⓪
          #    raises before this begin block
          Thread.current.thread_variable_set(APPEND_FLAG, nil)
        end
      end

      # @return [Symbol] :file, :sqlite, ... or :unavailable when the backend
      #   could not be constructed
      def storage_type
        storage_backend.backend_type
      rescue StandardError
        :unavailable
      end

      private

      # Memoised so the construction is attempted once and its failure is a
      # failure of the read, not of the object.
      def storage_backend
        @storage_backend ||= Storage::Backend.default
      end

      # INV-G's question: "state the absolute path of your ledger". A backend that
      # does not answer cannot be appended to; an answer that is not absolute is a
      # CWD-dependent key, which is a silent loss of exclusion.
      def ledger_path
        backend = begin
          storage_backend
        rescue StandardError => e
          raise ChainStateError.new("storage backend unavailable: #{e.message}", state: @load_state)
        end

        unless backend.respond_to?(:blockchain_file)
          raise ChainStateError.new(
            "storage backend #{backend.class} does not declare its ledger path",
            state: @load_state
          )
        end

        path = backend.blockchain_file
        unless path.is_a?(String) && !path.empty? && File.absolute_path?(path)
          raise Storage::Error, "storage backend answered a non-absolute ledger path: #{path.inspect}"
        end

        path
      end

      # (あ) the key is a separate file — locking the ledger itself makes a fresh
      #      install permanently unwritable.
      # (う) the key file is never unlinked — a deleted key file lets a later
      #      locker take a different inode and exclusion is lost in silence.
      def with_lock(path)
        # Only the key's own I/O is wrapped — a failure inside the yield must
        # not come back wearing the "lock unavailable" label.
        # FIX C — NEW CLAIM: every name that reaches one ledger takes one key.
        # The key path is canonicalised BEFORE ".lock" is appended. The R1
        # withdrawal of exactly this fix rested on a half-refuted premise: its
        # fixture ("dir/x", "dir/./x", a symlinked DIRECTORY) does resolve to
        # one lock inode, because the kernel resolves those inside the lock
        # path itself — but "link.json.lock" is its own name, so a symlink to
        # the ledger FILE split the lock ("real.json.lock" vs "link.json.lock";
        # measured over 8 runs of 2×60 appends: 4 to 21 of 120 blocks lost,
        # every run, silently — it is a race, so the count varies).
        # FIX F — NEW CLAIM: a name reaches one key even while the ledger does
        # not yet exist. R3 refuted FIX C's fallback (four reviewers
        # independently): while the ledger is absent — a fresh install reached
        # through two names — realpath fails with ENOENT, the fallback keyed on
        # the UNRESOLVED basename, and the premise "a ledger realpath cannot
        # resolve is one classify_disk cannot stat either" is false for exactly
        # that state, because :absent permits an append (measured: 51 blocks
        # shrank to 35–49). realdirpath resolves the final component's symlink
        # without requiring its target to exist, so both names converge on the
        # target's spelling before any ledger byte exists. The basename
        # fallback remains only for names realdirpath itself refuses, and no
        # append completes a write through such a name: ELOOP and EPERM fail
        # classify_disk's stat (refused as :unreadable), and a symlink whose
        # target directory is missing classifies :absent but the write through
        # it fails with ENOENT before any ledger byte lands. Hard links to the
        # same ledger remain outside what any path-derived key can reach:
        # realpath cannot distinguish them. The design records this as
        # limitation L-2 in its "what this does not close" section — it is NOT
        # in the §7 scope-exclusion list, so it is an acknowledged open hole
        # rather than a deferred item. An I/O failure while deriving the key
        # (the directory itself unresolvable) still surfaces as Storage::Error,
        # as before.
        lock_path = nil
        handle = begin
          FileUtils.mkdir_p(File.dirname(path))
          canonical = begin
            File.realpath(path)
          rescue SystemCallError
            begin
              File.realdirpath(path)
            rescue SystemCallError
              File.join(File.realpath(File.dirname(path)), File.basename(path))
            end
          end
          lock_path = "#{canonical}.lock"
          File.open(lock_path, File::RDWR | File::CREAT, 0o644)
        rescue SystemCallError, IOError => e
          raise Storage::Error, "ledger lock unavailable (#{lock_path || path}): #{e.message}"
        end

        completed = false
        begin
          begin
            handle.flock(File::LOCK_EX)
          rescue SystemCallError, IOError => e
            raise Storage::Error, "ledger lock unavailable (#{lock_path}): #{e.message}"
          end
          result = yield
          completed = true
          result
        ensure
          # Closing the key must never replace an exception already on its way
          # out: the caller's rule is read off the exception's class, and an
          # IOError from close would erase the Storage::Error that told the
          # caller to re-read. Whether the body finished is tracked explicitly
          # rather than read off $!, which inside an ensure also carries an
          # exception being handled further up the stack — under a caller that
          # wraps add_block in a rescue, $! is non-nil even on the normal path
          # and a close failure would be swallowed.
          begin
            handle.close
          rescue StandardError => e
            raise Storage::Error, "ledger lock close failed (#{lock_path}): #{e.message}" if completed
          end
        end
      end

      def build_block(tail, data)
        normalized_data = data.map { |d| d.is_a?(String) ? utf8_for_ledger(d) : d.to_json }

        Block.new(
          index: tail.index + 1,
          timestamp: Time.now.utc,
          data: normalized_data,
          previous_hash: tail.hash,
          merkle_root: MerkleTree.new(normalized_data).root
        )
      end

      # FIX A — NEW CLAIM: any String add_block accepts round-trips through the
      # ledger byte-identically — the bytes MerkleTree and Block hash are the
      # bytes JSON.pretty_generate writes. Decision: a String already in valid
      # UTF-8 passes unchanged; one in another valid encoding is transcoded to
      # its UTF-8 spelling (which IS its ledger representation); one holding
      # bytes invalid for its own encoding raises EncodingError before anything
      # is written. Before this, hashing the original bytes and writing the
      # transcoded ones made one ISO-8859-1 append classify a healthy 7-block
      # ledger :corrupt on reload (measured) — history unreachable, no raise.
      def utf8_for_ledger(text)
        utf8 = text.encode(Encoding::UTF_8)
        # encode is a no-op when source and destination are both UTF-8, so
        # invalid bytes under a UTF-8 label must be refused explicitly.
        unless utf8.valid_encoding?
          raise EncodingError,
                "block data is not valid #{text.encoding.name}: it cannot round-trip through the ledger"
        end
        utf8
      end

      # The single entrance of INV-E. Never raises: every failure becomes one of
      # the five states.
      #
      # @return [Array(Symbol, Array<Block>)]
      def classify_disk
        # A backend that cannot even be built is a channel we cannot read
        # through, not data we have judged. It is the :unreadable case.
        backend = begin
          storage_backend
        rescue StandardError => e
          note "[Chain] storage backend unavailable: #{e.message}"
          return [:unreadable, []]
        end

        # The dividing line: only a backend that declared the contract has its
        # return read in three shapes. Anything else reads as unreadable.
        return [:unreadable, []] unless backend.respond_to?(:blockchain_file)

        raw = backend.load_blocks
        return [:absent, []] if raw.nil?

        blocks = rebuild(raw)
        return [:empty, []] if blocks.empty?
        return [:corrupt, []] unless well_formed?(blocks)

        [:readable, blocks]
      rescue Storage::Error => e
        note "[Chain] ledger unreadable: #{e.message}"
        [:unreadable, []]
      rescue StandardError => e
        # Totality: an exception raised while rebuilding or while evaluating a
        # predicate is itself corruption, not a crash.
        note "[Chain] ledger corrupt: #{e.message}"
        [:corrupt, []]
      end

      # FIX D — NEW CLAIM: diagnostic output can never change the outcome of a
      # classification. warn writes to $stderr, and these calls sit inside
      # classify_disk's rescue branches: when $stderr has been replaced by a
      # closed or failing writer, warn raises IOError there and escapes
      # Chain.new (measured with a closed StringIO as $stderr; a close of the
      # real STDERR alone does not reproduce — MRI falls back to the C-level
      # stderr). StandardError, not just IOError, because the claim is about
      # any failing writer, not one failure class of the real console.
      def note(message)
        warn message
      rescue StandardError
        # the diagnostic is lost; the classification is not
      end

      # Classification runs on the rebuilt sequence, not on the backend's raw
      # array: timestamps are strings there, and the stored `hash` column is
      # discarded on load, so predicate 3 compares recomputed hashes.
      def rebuild(raw)
        raw.map do |block_data|
          Block.new(
            index: block_data[:index],
            timestamp: parse_timestamp(block_data[:timestamp]),
            data: block_data[:data],
            previous_hash: block_data[:previous_hash],
            merkle_root: block_data[:merkle_root]
          )
        end
      end

      def well_formed?(blocks)
        # 1. block 0 is the canonical genesis. Comparing recomputed hashes covers
        #    exactly the five columns of Block.genesis and nothing else.
        return false unless blocks.first.hash == Block.genesis.hash

        blocks.each_with_index do |block, i|
          # 2. indexes run from 0, one at a time
          return false unless block.index == i
          next if i.zero?

          # 3. each previous_hash matches the recomputed hash before it
          return false unless block.previous_hash == blocks[i - 1].hash

          # 4. from block 1 on, the Merkle root matches recomputation from data.
          #    Genesis is excluded: its merkle_root is the constant filler 0…0.
          return false unless block.merkle_root == MerkleTree.new(block.data).root
        end

        true
      end

      def parse_timestamp(timestamp)
        case timestamp
        when Time
          timestamp
        when String
          Time.parse(timestamp)
        else
          Time.now.utc
        end
      end
    end
  end
end
