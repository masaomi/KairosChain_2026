# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'time'
require_relative 'skills_config'

module KairosMcp
  # Content-addressed store for restorable L1 bodies.
  #
  # Key = sha256 hex of the exact bytes of an L1 markdown body -- the same
  # digest the knowledge provider records as prev_hash/next_hash. Objects live
  # at <root>/objects/<first 2 hex>/<hash>. The root sits beside the knowledge
  # directory, never inside it, so it is never scanned as an entry and it
  # follows whatever knowledge directory the provider writes to.
  class L1History
    HASH_PATTERN = /\A[0-9a-f]{64}\z/
    STATE_FILE = 'state.json'

    # Raised when a write could not be verified after the fact.
    class Error < StandardError; end

    # Enabled by default: absent config enables, only {'enabled' => false}
    # disables. A non-Hash value is not a disable switch.
    def self.enabled?
      cfg = SkillsConfig.load['l1_history']
      return true unless cfg.is_a?(Hash)

      cfg['enabled'] != false
    end

    attr_reader :root

    def initialize(knowledge_dir)
      @root = File.join(File.dirname(File.expand_path(knowledge_dir)), 'l1_history')
    end

    # Store a body. Idempotent, atomic and verified. Returns the sha256 hex.
    # Raises on any failure, so the caller can refuse the change.
    def store(body)
      raise ArgumentError, 'body must be a String' unless body.is_a?(String)

      bytes = body.dup.force_encoding(Encoding::BINARY)
      hash = Digest::SHA256.hexdigest(bytes)
      path = object_path(hash)

      # Already stored and intact -> nothing to do. A mismatch means the
      # stored object is damaged, so fall through and rewrite it.
      return hash if File.file?(path) && digest_of(path) == hash

      write_atomic(path, bytes)
      raise Error, "verification failed after write: #{hash}" unless digest_of(path) == hash

      hash
    end

    # => body String (UTF-8), or nil when nothing is stored under the hash.
    def fetch(hash)
      path = object_path(hash)
      return nil unless File.file?(path)

      raw = File.binread(path)

      # A stored object is retrievable only while its bytes still hash to the
      # hash they were asked for. Damaged or edited bytes are not a body for
      # that hash, so report them as absent instead of returning them.
      expected = hash.to_s.sub(/\Asha256:/, '').downcase
      return nil unless Digest::SHA256.hexdigest(raw) == expected

      raw.force_encoding('UTF-8')
    end

    def retrievable?(hash)
      File.file?(object_path(hash))
    end

    # Remove exactly one stored body. => true when one was removed.
    # Never touches the chain: the caller records the erasure.
    def erase(hash)
      path = object_path(hash)
      return false unless File.file?(path)

      File.unlink(path)
      true
    end

    # The recorded state, not the configured one. False when never recorded.
    def active?
      state = read_state
      state.is_a?(Hash) ? state['active'] == true : false
    end

    # Reconcile the recorded activation point with the configured one.
    # On a difference: append one block, THEN record the new state. If the
    # append raises, state.json is left alone and the error propagates.
    # Returns the configured state.
    def sync_activation!(chain)
      configured = self.class.enabled?
      return configured if active? == configured

      block = {
        type: 'l1_history_activation',
        layer: 'L1',
        active: configured,
        timestamp: Time.now.utc.iso8601
      }.to_json
      chain.add_block([block])
      write_state(configured)
      configured
    end

    ERASE_ID_PATTERN = /\A[0-9a-f]{16}\z/
    QUARANTINE_MARK = '.erasing-'

    # One erasure at a time per store, across threads and processes. The lock
    # file is opened fresh on every call: flock belongs to the open file
    # description, so a shared handle would not exclude two threads.
    def with_erase_lock
      FileUtils.mkdir_p(@root)
      File.open(File.join(@root, 'erase.lock'), File::CREAT | File::RDWR, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    # Rename the stored object aside so that the erasure record can be appended
    # before the bytes are actually removed. Returns the erase id that names the
    # quarantine -- the erasure record carries the same id, which is how a
    # leftover quarantine is later matched to its record -- or nil when nothing
    # is stored for this hash. object_path raises ArgumentError on a non-sha256.
    def begin_erase(hash)
      path = object_path(hash)
      return nil unless File.exist?(path)

      erase_id = SecureRandom.hex(8)
      File.rename(path, quarantine_path(hash, erase_id))
      erase_id
    end

    # Undo begin_erase: put the quarantined object back where it was. Used when
    # the erasure record is known not to be on the chain. If the hash has been
    # stored again meanwhile and that copy is intact, it stands and the
    # quarantine is dropped: both are the same content address. A copy there
    # that does not hash to its address is replaced by the quarantined bytes.
    def abort_erase(hash, erase_id)
      quarantined = quarantine_path(hash, erase_id)
      return false unless File.exist?(quarantined)

      canonical = object_path(hash)
      if File.file?(canonical) && digest_of(canonical) == hash
        File.unlink(quarantined)
      else
        File.rename(quarantined, canonical)
      end
      true
    end

    # The record has landed, so drop the quarantined object for good.
    def commit_erase(hash, erase_id)
      quarantined = quarantine_path(hash, erase_id)
      return false unless File.exist?(quarantined)

      File.unlink(quarantined)
      true
    end

    # Every quarantine left on disk, as [hash, erase_id] pairs. Names that do
    # not parse are not ours and are left alone.
    def quarantined
      Dir.glob(File.join(@root, 'objects', '*', "*#{QUARANTINE_MARK}*")).filter_map do |path|
        hash, erase_id = File.basename(path).split(QUARANTINE_MARK, 2)
        next unless HASH_PATTERN.match?(hash.to_s) && ERASE_ID_PATTERN.match?(erase_id.to_s)

        [hash, erase_id]
      end
    end

    # Settle quarantines that an interrupted erasure left behind. recorded_ids
    # is the set of erase ids that appear in erasure records on the chain, or
    # nil when the chain could not be read. A recorded quarantine is deleted, an
    # unrecorded one is put back; with nil nothing is decided. Call it under
    # with_erase_lock, so an erasure in flight is never mistaken for a leftover.
    # => number of quarantines settled.
    def reconcile_quarantine!(recorded_ids)
      return 0 if recorded_ids.nil?

      quarantined.count do |hash, erase_id|
        if recorded_ids.include?(erase_id)
          commit_erase(hash, erase_id)
        else
          abort_erase(hash, erase_id)
        end
      end
    end

    private

    def quarantine_path(hash, erase_id)
      raise ArgumentError, "not an erase id: #{erase_id.inspect}" unless ERASE_ID_PATTERN.match?(erase_id.to_s)

      "#{object_path(hash)}#{QUARANTINE_MARK}#{erase_id}"
    end

    def object_path(hash)
      File.join(@root, 'objects', validate_hash!(hash)[0, 2], hash)
    end

    # Validated before any path is built, so nothing outside the root is ever
    # read, written or removed. Fails closed rather than returning nil.
    def validate_hash!(hash)
      return hash if hash.is_a?(String) && HASH_PATTERN.match?(hash)

      raise ArgumentError, "not a sha256 hex digest: #{hash.inspect}"
    end

    def digest_of(path)
      Digest::SHA256.hexdigest(File.binread(path))
    end

    def state_path
      File.join(@root, STATE_FILE)
    end

    # An unreadable state.json counts as absent (never active).
    def read_state
      return nil unless File.file?(state_path)

      JSON.parse(File.read(state_path))
    rescue JSON::ParserError
      nil
    end

    def write_state(active)
      payload = JSON.pretty_generate('active' => active, 'changed_at' => Time.now.utc.iso8601)
      write_atomic(state_path, payload.b)
    end

    # Temp file in the same directory, then rename.
    def write_atomic(path, bytes)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".tmp-#{SecureRandom.hex(8)}")
      begin
        File.open(tmp, 'wb') do |f|
          f.write(bytes)
          f.flush
          f.fsync
        end
        File.rename(tmp, path)
      ensure
        File.unlink(tmp) if File.exist?(tmp)
      end
    end
  end
end
