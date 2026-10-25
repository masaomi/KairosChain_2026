# frozen_string_literal: true

require 'json'
require 'digest'
require 'openssl'
require 'base64'
require 'time'
require 'fileutils'
require 'set'

module KairosMcp
  # Admission and publication records (secure MMP v1, design v0.4 I4).
  #
  # Who may be admitted through MMP direct mode and which SkillSets are
  # published are not stored anywhere but the chain: each decision is a block
  # whose single entry is a JSON record signed by this instance's MMP key. The
  # records of one type form their own sequence — every record names the one
  # before it (seq, prev) — so a copy of an earlier record, appended again
  # through chain_record, extends nothing and counts for nothing.
  #
  # Core owns this fold so that an old or absent mmp SkillSet cannot change
  # what counts. Reading never writes; appending is for operator commands (and
  # revocation from the peer_pin tool).
  class AdmissionRecords
    PROTOCOL = 'kairos-mmp-record/1'
    PIN = 'mmp_admission_pin'
    PUBLICATION = 'mmp_skillset_publication'
    TYPES = [PIN, PUBLICATION].freeze
    GENESIS = 'genesis'

    ALIAS_PATTERN = /\A[a-z0-9_-]{1,32}\z/
    HEX64 = /\A[0-9a-f]{64}\z/
    ORIGIN_PATTERN = %r{\Ahttps?://[^\s/?#]+\z}
    SKILLSET_NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
    TIME_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

    KEYPAIR_RELATIVE = File.join('keys', 'mmp_keypair.pem')

    class Error < StandardError; end

    # status: :ok, :no_key, :unreadable, :unsupported_backend, :rolled_back
    State = Struct.new(:status, :cause, :pin_by_key, :alias_key, :publications,
                       :heads, :ignored, :accepted, :block_count, keyword_init: true) do
      def ok? = status == :ok
    end

    @instances = {}
    @instances_mutex = Mutex.new

    # One reader per data dir, so its cache and rollback watermark persist for
    # the life of the process.
    def self.for_data_dir(data_dir = KairosMcp.data_dir)
      key = File.expand_path(data_dir)
      @instances_mutex.synchronize { @instances[key] ||= new(data_dir: key) }
    end

    def self.reset_instances!
      @instances_mutex.synchronize { @instances = {} }
    end

    def self.key_sha256_of(public_key)
      Digest::SHA256.hexdigest(public_key.public_to_der)
    end

    # The exact bytes a record signature covers: protocol, type, and the record
    # without its type and signature, keys sorted.
    def self.message(type, record)
      fields = record.reject { |k, _| %w[type signature].include?(k) }
      [PROTOCOL, type, JSON.generate(fields.sort.to_h)].join("\n")
    end

    def self.sign(private_key, type, record)
      sig = private_key.sign_pss('SHA256', message(type, record), salt_length: :digest, mgf1_hash: 'SHA256')
      Base64.strict_encode64(sig)
    end

    def self.verify(public_key, type, record)
      raw = Base64.strict_decode64(record['signature'].to_s)
      public_key.verify_pss('SHA256', raw, message(type, record), salt_length: :digest, mgf1_hash: 'SHA256')
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      false
    end

    # nil when the record is well-formed for its type, else a reason.
    def self.shape_error(type, record)
      return 'not_a_record' unless record.is_a?(Hash)
      return 'bad_seq' unless record['seq'].is_a?(Integer) && record['seq'] >= 1
      return 'bad_prev' unless record['prev'] == GENESIS || HEX64.match?(record['prev'].to_s)
      return 'bad_signed_at' unless TIME_PATTERN.match?(record['signed_at'].to_s)
      return 'bad_signature' unless record['signature'].is_a?(String) && !record['signature'].empty?

      case type
      when PIN
        return 'bad_action' unless %w[add revoke].include?(record['action'])
        return 'bad_alias' unless ALIAS_PATTERN.match?(record['alias'].to_s)
        return 'bad_key' unless HEX64.match?(record['key_sha256'].to_s)
        if record['action'] == 'add'
          return 'bad_url' unless ORIGIN_PATTERN.match?(record['url'].to_s)
          return 'bad_replaces' unless record['replaces'].nil? || HEX64.match?(record['replaces'].to_s)
        end
      when PUBLICATION
        return 'bad_action' unless %w[publish unpublish].include?(record['action'])
        return 'bad_name' unless SKILLSET_NAME_PATTERN.match?(record['name'].to_s)
        return 'bad_content_hash' unless HEX64.match?(record['content_hash'].to_s)
      else
        return 'unknown_type'
      end
      nil
    end

    def self.load_private_key(data_dir)
      path = File.join(data_dir, KEYPAIR_RELATIVE)
      raise Error, "no MMP keypair at #{path} (records are signed with it; it is never generated here)" unless File.file?(path)

      OpenSSL::PKey::RSA.new(File.read(path))
    rescue OpenSSL::PKey::PKeyError => e
      raise Error, "MMP keypair at #{path} is unreadable: #{e.message}"
    end

    attr_reader :data_dir

    def initialize(data_dir: KairosMcp.data_dir, backend: nil)
      @data_dir = File.expand_path(data_dir)
      @backend = backend
      @mutex = Mutex.new
      @cache_key = nil
      @state = nil
      @max_seq = Hash.new(0)
      @rolled_back = nil
    end

    # Current state, re-folded when the ledger or the key changed.
    def state
      @mutex.synchronize do
        key = cache_key
        if @state.nil? || key != @cache_key
          @state = compute_state
          @cache_key = key
        end
        @state
      end
    end

    # Alias of an admitted key, or nil. Nothing is admitted unless the state is ok.
    # Pass the state a caller already checked, so one decision reads one snapshot.
    def admitted_alias(key_sha256, st = state)
      return nil unless st.ok?

      pin = st.pin_by_key[key_sha256.to_s]
      return nil unless pin && pin['action'] == 'add'
      return nil unless st.alias_key[pin['alias']] == key_sha256

      pin['alias']
    end

    def published?(name, content_hash)
      st = state
      return false unless st.ok?

      pub = st.publications[name.to_s]
      pub && pub['action'] == 'publish' && pub['content_hash'] == content_hash.to_s
    end

    # Admitted pins: [{ alias, key_sha256, url, added_at }]. Like
    # admitted_alias, takes the state a caller already checked.
    def admitted_pins(st = state)
      return [] unless st.ok?

      st.alias_key.filter_map do |al, key|
        pin = st.pin_by_key[key]
        next unless pin && pin['action'] == 'add' && pin['alias'] == al

        { 'alias' => al, 'key_sha256' => key, 'url' => pin['url'], 'added_at' => pin['signed_at'] }
      end
    end

    def pin_for_alias(alias_name)
      admitted_pins.find { |p| p['alias'] == alias_name.to_s }
    end

    # Append a signed record. Raises Error, and admits nothing, when the
    # ledger cannot hold records or another writer got there first.
    def append(type, fields, private_key:)
      raise Error, "unknown record type #{type}" unless TYPES.include?(type)

      own = own_public_key
      raise Error, 'no MMP keypair; records cannot be signed' unless own
      unless private_key.public_key.to_der == own.to_der
        raise Error, 'the signing key is not this instance\'s MMP key'
      end
      raise Error, 'storage backend cannot hold records (file ledger only)' unless file_backend?

      before = refresh!
      raise Error, "ledger not usable for records: #{before.status} #{before.cause}" unless before.ok?

      head = before.heads[type]
      record = fields.transform_keys(&:to_s).merge(
        'seq' => head[:seq] + 1,
        'prev' => head[:prev],
        'signed_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
      )
      record['signature'] = 'pending'
      reason = self.class.shape_error(type, record)
      raise Error, "invalid record: #{reason}" if reason

      record['signature'] = self.class.sign(private_key, type, record)
      entry = JSON.generate({ 'type' => type }.merge(record))
      require 'kairos_mcp/kairos_chain/chain'
      KairosChain::Chain.new(storage_backend: backend).add_block([entry])

      after = refresh!
      unless after.ok? && after.accepted.include?(Digest::SHA256.hexdigest(record['signature']))
        raise Error, 'another record was appended at the same time; nothing changed by this one — re-run'
      end

      record.merge('type' => type)
    end

    def refresh!
      @mutex.synchronize do
        key = cache_key # before reading: a later append then shows as a changed key
        @state = compute_state
        @cache_key = key
        @state
      end
    end

    def ledger_path
      backend.respond_to?(:blockchain_file) ? backend.blockchain_file : nil
    rescue StandardError
      nil
    end

    def own_key_sha256
      key = own_public_key
      key && self.class.key_sha256_of(key)
    end

    private

    def backend
      @backend ||= begin
        require 'kairos_mcp/storage/backend'
        Storage::Backend.default
      end
    end

    def file_backend?
      path = ledger_path
      path.is_a?(String) && File.absolute_path?(path)
    end

    def keypair_path
      File.join(@data_dir, KEYPAIR_RELATIVE)
    end

    def own_public_key
      path = keypair_path
      return nil unless File.file?(path)

      OpenSSL::PKey::RSA.new(File.read(path)).public_key
    rescue OpenSSL::PKey::PKeyError, SystemCallError
      nil
    end

    def stat_key(path)
      s = File.stat(path)
      [s.ino, s.size, s.mtime.to_r]
    rescue Errno::ENOENT
      :absent
    rescue SystemCallError
      :unstatable
    end

    def cache_key
      ledger = ledger_path
      [ledger && stat_key(ledger), stat_key(keypair_path)]
    end

    def empty_heads
      TYPES.to_h { |t| [t, { seq: 0, prev: GENESIS }] }
    end

    def blank_state(status, cause)
      State.new(status: status, cause: cause, pin_by_key: {}, alias_key: {}, publications: {},
                heads: empty_heads, ignored: [], accepted: Set.new, block_count: 0)
    end

    def compute_state
      return blank_state(:rolled_back, @rolled_back) if @rolled_back
      return blank_state(:unsupported_backend, 'storage backend declares no ledger file') unless file_backend?

      own = own_public_key
      return blank_state(:no_key, "no MMP keypair at #{keypair_path}") unless own

      blocks, load_state = read_blocks
      return blank_state(:unreadable, "ledger #{load_state}") unless %i[readable absent].include?(load_state)

      st = fold(blocks, own)
      st.heads.each do |type, head|
        if head[:seq] < @max_seq[type]
          @rolled_back = "#{type} head went from #{@max_seq[type]} back to #{head[:seq]}; restart the listener after checking `kairos-chain peer pin list`"
          return blank_state(:rolled_back, @rolled_back)
        end
      end
      st.heads.each { |type, head| @max_seq[type] = head[:seq] }
      st
    end

    # Read under a shared lock on the appenders' lock file, so an append in
    # another process (truncate, then write) is never seen half-written.
    def read_blocks
      require 'kairos_mcp/kairos_chain/chain'
      path = ledger_path
      lock = begin
        canonical = File.exist?(path) ? File.realpath(path) : File.realdirpath(path)
        FileUtils.mkdir_p(File.dirname(canonical))
        File.open("#{canonical}.lock", File::RDWR | File::CREAT, 0o644)
      rescue SystemCallError
        nil
      end
      begin
        lock&.flock(File::LOCK_SH)
        chain = KairosChain::Chain.new(storage_backend: backend)
        [chain.chain, chain.load_state]
      ensure
        lock&.close
      end
    rescue StandardError => e
      [[], "unreadable (#{e.class})"]
    end

    # A typed record that does not count is said once per process, so a forged
    # or foreign record leaves a trace in the listener log. It does not close
    # admission: one chain_record call would otherwise switch admission off
    # for good (design v0.4 §10 erratum, 2026-10-25).
    def log_ignored(ignored)
      @logged_ignored ||= Set.new
      ignored.each do |i|
        key = [i['block'], i['type'], i['reason']]
        next if @logged_ignored.include?(key)

        @logged_ignored << key
        warn "[AdmissionRecords] ignored #{i['type']} record in block #{i['block']}: #{i['reason']}"
      end
    end

    def fold(blocks, own)
      heads = empty_heads
      pin_by_key = {}
      alias_key = {}
      publications = {}
      ignored = []
      accepted = Set.new

      blocks.each do |block|
        Array(block.data).each do |entry|
          next unless entry.is_a?(String) && entry.start_with?('{')

          record = begin
            JSON.parse(entry)
          rescue JSON::ParserError
            nil
          end
          next unless record.is_a?(Hash) && TYPES.include?(record['type'])

          type = record['type']
          reason = self.class.shape_error(type, record)
          reason ||= 'signature' unless self.class.verify(own, type, record)
          head = heads[type]
          reason ||= 'out_of_sequence' unless record['seq'] == head[:seq] + 1 && record['prev'] == head[:prev]
          if reason
            ignored << { 'block' => block.index, 'type' => type, 'reason' => reason }
            next
          end

          sig_hash = Digest::SHA256.hexdigest(record['signature'])
          heads[type] = { seq: record['seq'], prev: sig_hash }
          accepted << sig_hash
          case type
          when PIN
            pin_by_key[record['key_sha256']] = record
            alias_key[record['alias']] = record['key_sha256'] if record['action'] == 'add'
          when PUBLICATION
            publications[record['name']] = record
          end
        end
      end

      log_ignored(ignored)
      State.new(status: :ok, cause: nil, pin_by_key: pin_by_key, alias_key: alias_key,
                publications: publications, heads: heads, ignored: ignored, accepted: accepted,
                block_count: blocks.size)
    end
  end
end
