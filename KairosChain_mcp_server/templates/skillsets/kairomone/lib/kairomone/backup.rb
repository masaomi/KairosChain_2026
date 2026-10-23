# frozen_string_literal: true

require 'openssl'

module Kairomone
  # The host's archive key (design v0.6 M15, option A): 32 random bytes made at
  # the first backup, outside every individual and never in an archive. A
  # version-2 backup carries HMAC-SHA256(key, manifest_sha256) and the key's
  # fingerprint; whoever holds the key can sign an archive this host restores
  # without asking. A lost key turns the owner's own backups into unsigned
  # archives, restored at a terminal.
  module ArchiveKey
    PATH = 'kairomone-keys/archive.key'

    module_function

    def load(host_root, create: false)
      path = Paths.checked(host_root, PATH)
      unless File.exist?(path) || File.symlink?(path)
        return nil unless create

        # Made under a lock and renamed into place whole: the key path never
        # holds a partial key, and a concurrent first backup finds the one key.
        Paths.mkdir(host_root, File.dirname(PATH))
        lock = Paths.checked(host_root, "#{File.dirname(PATH)}/.lock")
        Paths.regular_file!(lock, optional: true, limit: 1024)
        File.open(lock, File::RDWR | File::CREAT, 0o600) do |io|
          io.flock(File::LOCK_EX)
          Paths.write(host_root, PATH, SecureRandom.random_bytes(32)) unless File.exist?(path) || File.symlink?(path)
        end
      end
      key = Paths.read(host_root, PATH, limit: 32)
      raise Error, "The archive key #{PATH} is not 32 bytes; inspect it" unless key.bytesize == 32

      key
    end

    def fingerprint(key) = Digest::SHA256.hexdigest(key)
    def sign(key, manifest_sha256) = OpenSSL::HMAC.hexdigest('SHA256', key, manifest_sha256)

    def valid?(archive, key)
      sig = archive['signature']
      return false unless key && archive['version'] == 2 && sig.is_a?(Hash) && sig['algorithm'] == 'HMAC-SHA256'
      return false unless sig['key_sha256'] == fingerprint(key) && sig['value'].is_a?(String) && sig['value'].bytesize == 64

      OpenSSL.fixed_length_secure_compare(sig['value'], sign(key, archive['manifest_sha256'].to_s))
    end
  end

  class Instance
    ARCHIVE_FORMAT = 'kairomone-owned-backup'
    FILE_LIMIT = 1_048_576
    LEDGER_LIMIT = 16 * 1024 * 1024
    TOTAL_LIMIT = 64 * 1024 * 1024
    ARCHIVE_LIMIT = 96 * 1024 * 1024
    LEDGER_PATH = 'storage/blockchain.json'
    # One path set serves backup and restore (M15). Lock files, temporary
    # files, backups/, exports/ and l1_history/ are outside it: never carried,
    # never looked at by restore.
    FIXED_PATHS = ['profile.json', 'profession.json', 'growth/state.json', 'growth/runs.json', 'transplants.json',
                   'companion/state.json', 'companion/memory-gate.json', LEDGER_PATH].freeze
    PIECE_DIRS = { 'profile' => '.json', 'professions' => '.json', 'art' => '.svg', 'proposals' => '.json', 'lineage' => '.json' }.freeze
    PIECE_KINDS = { 'kairomone_profile' => 'profile', 'kairomone_profession' => 'professions', 'kairomone_art' => 'art' }.freeze

    def self.backup_path?(relative)
      return false unless relative.is_a?(String)
      return true if FIXED_PATHS.include?(relative)

      parts = relative.split('/')
      if parts.length == 3 && parts[0] == 'knowledge'
        return Paths::ID.match?(parts[1]) && parts[2] == "#{parts[1]}.md"
      end
      if parts.length == 4 && parts[0] == 'context' && [L2_SESSION, CHAT_SESSION].include?(parts[1])
        return Paths::ID.match?(parts[2]) && parts[3] == "#{parts[2]}.md"
      end
      if parts.length == 2 && PIECE_DIRS.key?(parts[0])
        return parts[1].match?(/\A[0-9a-f]{64}#{Regexp.escape(PIECE_DIRS[parts[0]])}\z/)
      end
      false
    end

    # Creates a version-2 backup in this individual's backups/ and verifies
    # the file just written. Refused, listing them, when a piece the ledger
    # records as accepted is absent and not recorded missing.
    def create_backup
      written = autonomy.synchronize do
        with_lock do
          ensure_initialized!
          raise Error, 'Restored targets are read-only' if @restored
          snapshot = status
          backup_ready!(snapshot)
          ledger = chain
          absent = absent_accepted_pieces(ledger)
          unless absent.empty?
            raise Error, "Backup refused: accepted pieces are absent (#{absent.map { |p| "#{p['kind']} #{p['sha256'][0, 12]}" }.join(', ')}). " \
                         'If they are lost, record them at a terminal: ruby .kairos/skillsets/kairomone/scripts/kairomone.rb backup missing ...'
          end
          total = 0
          files = backup_paths.map do |relative|
            bytes = Paths.read(root, relative, limit: relative == LEDGER_PATH ? LEDGER_LIMIT : FILE_LIMIT)
            total += bytes.bytesize
            raise Error, 'Owned backup exceeds the 64 MiB total limit' if total > TOTAL_LIMIT
            { 'path' => relative, 'size' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'content_base64' => Base64.strict_encode64(bytes) }
          end
          key = ArchiveKey.load(host_root, create: true)
          manifest = self.class.manifest_hash(files)
          # identity and listing_id are informational: the signature covers the
          # manifest only, and restore reads the identity from the files.
          archive = { 'format' => ARCHIVE_FORMAT, 'version' => 2, 'created_at' => Time.now.utc.iso8601,
                      'identity' => identity(ledger), 'listing_id' => listing_id,
                      'scope' => BACKUP_SCOPE, 'excluded' => BACKUP_EXCLUDED, 'files' => files, 'manifest_sha256' => manifest,
                      'signature' => { 'algorithm' => 'HMAC-SHA256', 'key_sha256' => ArchiveKey.fingerprint(key), 'value' => ArchiveKey.sign(key, manifest) } }
          bytes = JSON.pretty_generate(archive) + "\n"
          raise Error, 'Encoded backup exceeds the 96 MiB limit' if bytes.bytesize > ARCHIVE_LIMIT
          name = "kairomone-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}.kairomone.json"
          [name, Paths.write(root, "backups/#{name}", bytes)]
        end
      end
      name, path = written
      # Verify the bytes just delivered, not only the in-memory source. The
      # registry lock this takes is never taken while an individual lock is held.
      verify_backup(file: name).merge(success: true, file: name, path: path, scope: BACKUP_SCOPE, excluded: BACKUP_EXCLUDED, kairomone: address)
    end

    # Offline check of one of this individual's backups in a staging area.
    def verify_backup(file:)
      bytes = read_archive_file(file, inbox: false)
      @host.with_registry_lock do
        archive, files = self.class.load_archive(bytes)
        @host.stage do |staged|
          staged.place_archive_files!(files)
          snapshot = staged.status
          staged.send(:backup_ready!, snapshot)
          absent = archive['version'] == 2 ? staged.send(:absent_accepted_pieces, staged.chain) : []
          raise Error, 'The archive lacks accepted pieces its ledger names' unless absent.empty?

          { success: true, verified: true, file: file, file_count: files.length, version: archive['version'],
            manifest_sha256: archive['manifest_sha256'], integrity: snapshot[:integrity],
            signed_by_this_host: ArchiveKey.valid?(archive, ArchiveKey.load(host_root)),
            authenticity: 'SHA-256 consistency, and an HMAC signature when this host made it; the archive is not encrypted' }
        end
      end
    end

    # Restores one of this individual's own backups as a separate listed
    # individual (its twin) under target_id. Only an archive signed with this
    # host's key restores this way.
    def restore_backup(file:, target_id:)
      raise Error, "Name a target_id: this backup's Kairomone (#{identity}) is already listed, so its copy is listed under another ID" if target_id.nil?
      Paths.id!(target_id)
      raise Error, 'Restored targets are read-only' if @restored
      @host.restore(read_archive_file(file, inbox: false), listing_id: target_id, trust: :signed)
    end

    # Restores an archive the owner placed in <data_dir>/kairomone-inbox/. Its
    # identity must be the expected one; it is listed under that identity, or
    # under target_id when the identity is already listed.
    # identity: the identity the archive must hold (dot_id: its name before 0.8).
    def restore_new(file:, identity: nil, dot_id: nil, target_id: nil)
      expected = Instance.renamed_id!(identity, dot_id, 'identity')
      Paths.id!(target_id) if target_id
      raise Error, 'Restored inspection targets cannot activate another instance' if @restored
      result = @host.restore(read_archive_file(file, inbox: true), expected_identity: expected, listing_id: target_id, trust: :signed)
      @root ||= result[:path]
      result
    end

    # Writes archive files into a staging root (no OS extractor: no symlinks,
    # hardlinks, devices, traversal or archive-chosen directories).
    def place_archive_files!(files)
      STORE_DIRS.each { |dir| Paths.mkdir(root, dir) }
      files.each { |relative, bytes| Paths.write(root, relative, bytes) }
    end

    def self.manifest_hash(files)
      Digest::SHA256.hexdigest(JSON.generate(files.map { |entry| entry.slice('path', 'size', 'sha256') }))
    end

    # Integrity only (manifest, every file's hash, path set, sizes, UTF-8):
    # nothing in an archive is judged by rules newer than its data.
    def self.load_archive(bytes)
      archive = JSON.parse(bytes)
      raise Error, 'Unsupported backup format' unless archive.is_a?(Hash) && archive['format'] == ARCHIVE_FORMAT && [1, 2].include?(archive['version'])
      files = archive['files']
      raise Error, 'Invalid backup file count' unless files.is_a?(Array) && files.length.between?(1, MAX_ENTRIES * 4 + 4_000)
      seen = {}
      total = 0
      decoded = files.map do |entry|
        raise Error, 'Invalid archive entry' unless entry.is_a?(Hash) && entry.keys.sort == %w[content_base64 path sha256 size]
        relative = entry['path']
        raise Error, 'Forbidden or duplicate archive path' unless backup_path?(relative) && !seen[relative]
        seen[relative] = true
        size = entry['size']
        maximum = relative == LEDGER_PATH ? LEDGER_LIMIT : FILE_LIMIT
        raise Error, 'Invalid archive entry size' unless size.is_a?(Integer) && size.between?(0, maximum)
        total += size
        raise Error, 'Backup expands beyond the 64 MiB limit' if total > TOTAL_LIMIT
        encoded = entry['content_base64']
        raise Error, 'Invalid base64 payload' unless encoded.is_a?(String) && encoded.bytesize <= ((maximum + 2) / 3) * 4
        contents = Base64.strict_decode64(encoded)
        raise Error, 'Backup checksum or size mismatch' unless contents.bytesize == size && Digest::SHA256.hexdigest(contents) == entry['sha256']
        raise Error, "Archive file #{relative} is not UTF-8 text" unless contents.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        [relative, contents]
      end
      raise Error, 'Backup holds neither a profile nor a ledger' unless seen['profile.json'] || seen[LEDGER_PATH]
      raise Error, 'Backup manifest checksum mismatch' unless manifest_hash(files) == archive['manifest_sha256']
      [archive, decoded]
    rescue JSON::ParserError, ArgumentError => e
      raise Error, "Invalid backup: #{e.message}"
    end

    # The owner records accepted pieces as lost, at a terminal, so a backup
    # can proceed without them (M15).
    def record_missing_interactive(pieces:, reason:, tty_in:, tty_out:, nonce: self.class.rebaseline_nonce)
      reason = text!(reason, 'reason', 512)
      say = ->(line) { tty_out.puts tty_safe(line) }
      wanted = pieces.map { |p| { 'kind' => p[:kind] || p['kind'], 'sha256' => p[:sha256] || p['sha256'] } }
      # Checked under the locks, shown and answered with no lock held (as the
      # L0 re-baseline does), then checked again under the locks and recorded.
      check = lambda do
        ensure_writable!('L2')
        unknown = wanted - absent_accepted_pieces(chain)
        raise Error, "Not absent accepted pieces: #{unknown.map { |p| "#{p['kind']} #{p['sha256']}" }.join(', ')}" unless unknown.empty? && !wanted.empty?
      end
      autonomy.synchronize { with_lock { check.call } }
      say.call "Kairomone: #{listing_id} (#{name})"
      wanted.each { |p| say.call "  lost #{p['kind']} #{p['sha256']}" }
      say.call "Reason:   #{reason}"
      tty_out.print "Type #{nonce} to record these pieces as lost (anything else cancels): "
      tty_out.flush
      unless tty_in.gets.to_s.strip == nonce
        say.call 'Cancelled. Nothing was recorded.'
        return { success: false, recorded: false, reason: 'nonce_mismatch' }
      end
      autonomy.synchronize do
        with_lock do
          check.call
          block = Records.append!(chain, [{ 'type' => 'kairomone_missing', 'pieces' => wanted, 'reason' => reason }], -> { chain })
          say.call "Recorded as block ##{block.index}."
          { success: true, recorded: true, block: block.index, pieces: wanted, kairomone: address }
        end
      end
    end

    private

    def read_archive_file(file, inbox:)
      raise Error, 'Backup filename must be a basename ending in .kairomone.json' unless file.is_a?(String) && Paths::BACKUP_NAME.match?(file)
      inbox ? Paths.read(host_root, "kairomone-inbox/#{file}", limit: ARCHIVE_LIMIT) : Paths.read(root, "backups/#{file}", limit: ARCHIVE_LIMIT)
    end

    # Exactly the files of the path set that exist.
    def backup_paths
      paths = FIXED_PATHS.select { |relative| File.exist?(Paths.checked(root, relative)) }
      paths += entry_ids('knowledge').map { |id| "knowledge/#{id}/#{id}.md" }
      [L2_SESSION, CHAT_SESSION].each do |session|
        paths += entry_ids("context/#{session}", optional: true).map { |id| "context/#{session}/#{id}/#{id}.md" }
      end
      PIECE_DIRS.each_key do |dir|
        path = Paths.checked(root, dir)
        next unless File.directory?(path)

        Dir.children(path).sort.each do |name|
          relative = "#{dir}/#{name}"
          paths << relative if self.class.backup_path?(relative) && File.file?(Paths.checked(root, relative))
        end
      end
      paths.sort
    end

    # Accepted pieces (profile versions, professions, drawings) whose files
    # are absent and that no kairomone_missing or kairomone_restored record
    # excuses.
    def absent_accepted_pieces(ledger)
      accepted = []
      excused = []
      Records.each(ledger) do |record, _|
        if (dir = PIECE_KINDS[record['type']]) && Progression::SHA.match?(record['sha256'].to_s)
          accepted << { 'kind' => dir, 'sha256' => record['sha256'] }
        elsif %w[kairomone_missing kairomone_restored].include?(record['type'])
          key = record['type'] == 'kairomone_missing' ? 'pieces' : 'missing'
          Array(record[key]).each { |p| excused << { 'kind' => p['kind'], 'sha256' => p['sha256'] } if p.is_a?(Hash) }
        end
      end
      accepted.uniq.reject do |p|
        excused.include?(p) || File.file?(Paths.checked(root, "#{p['kind']}/#{p['sha256']}#{PIECE_DIRS[p['kind']]}"))
      end
    end

    def backup_ready!(snapshot)
      if snapshot.dig(:chat_memory, :pending_count).to_i.positive?
        raise Error, 'Resolve pending chat summary before backup or restore'
      end
      raise Error, "Cannot back up or restore an unverified instance: #{snapshot[:error]}" if snapshot[:error] || !snapshot[:initialized]
      integrity = snapshot[:integrity]
      state_ok = integrity[:state] == 'readable' || (integrity[:state] == 'absent' && snapshot[:knowledge][:count].zero?)
      raise Error, 'Cannot back up or restore: corrupt, unreadable or unrecorded canonical data' unless state_ok && integrity[:pending_count].zero?
    end
  end

  class Host
    # A staging root that cleanup never meets: the caller holds the registry
    # lock. Nothing in it is listed; it is removed when the block ends.
    def stage
      raise Error, 'Staging needs the registry lock' unless @registry_locked

      Paths.mkdir(host_root, STAGING)
      path = Paths.checked(host_root, "#{STAGING}/s#{SecureRandom.hex(12)}")
      Dir.mkdir(path, 0o700)
      begin
        yield Instance.new(host_root: host_root, root: path)
      ensure
        FileUtils.remove_entry_secure(path) if File.directory?(path) && !File.symlink?(path)
      end
    end

    # Restores an archive as a new listed individual (Inv 1, M15). trust:
    # :signed (MCP and library: only an archive signed with this host's key)
    # or a callable that is shown the archive's free text at a terminal and
    # answers whether the owner confirmed. A trusted archive restores as
    # stored: integrity only, assembled in staging, kairomone_restored
    # appended, live runs ended, listed by one rename.
    def restore(bytes, trust:, listing_id: nil, expected_identity: nil)
      Paths.id!(listing_id) if listing_id
      archive, files = Instance.load_archive(bytes)
      signed = ArchiveKey.valid?(archive, ArchiveKey.load(host_root))
      if !signed && !trust.respond_to?(:call)
        raise Error, 'This archive is not signed with this host\'s archive key (a 0.6.1 backup, another machine\'s, or one signed by a lost key). ' \
                     'The owner restores it in their own terminal, where its free text is shown first: for a file in kairomone-inbox/, ' \
                     'ruby .kairos/skillsets/kairomone/scripts/kairomone.rb backup restore-new --file NAME --identity IDENTITY; for a file in ' \
                     'a Kairomone\'s backups/, ... backup restore --kairomone LISTING_ID --file NAME. Add --target-id NEW_ID when the ' \
                     'identity is already listed.'
      end
      unless signed
        # The owner reads the archive's free text and answers with no lock
        # held; the restore below checks everything again under the lock.
        summary = with_registry_lock do
          stage { |staged| staged.restore_summary(archive, restore_checks(staged, archive, files, listing_id, expected_identity)[:missing]) }
        end
        raise Error, 'Cancelled. Nothing was restored.' unless trust.call(summary)
      end
      with_registry_lock do
        listed = nil
        missing = []
        path = assemble(listing_id) do |staged|
          checked = restore_checks(staged, archive, files, listing_id, expected_identity)
          listed = checked[:listed]
          missing = checked[:missing]
          Records.append!(staged.chain, [{ 'type' => 'kairomone_restored', 'manifest_sha256' => archive['manifest_sha256'],
                                           'archive_version' => archive['version'], 'listing_id' => listed,
                                           'trust' => signed ? 'signed' : 'owner_confirmed', 'missing' => missing }], -> { staged.chain })
          staged.autonomy.end_runs_for_restore!
          listed
        end
        restored = Instance.new(host_root: host_root, root: path)
        integrity = restored.status[:integrity]
        l0 = integrity[:host_l0] || {}
        outcome = { success: true, restored: true, active: true, kairomone: restored.address, path: path,
                    manifest_sha256: archive['manifest_sha256'], archive_version: archive['version'],
                    trust: signed ? 'signed' : 'owner_confirmed', missing: missing, integrity: integrity,
                    warning: 'Backups are unencrypted and may contain private user-authored text. The archived L0 baseline is kept; host L0 is not installed or modified.' }
        outcome[:l0_warning] = "Current host L0 comparison is #{l0[:state]}; growth needs the owner's re-baseline at a terminal" unless l0[:state] == 'unchanged'
        outcome
      end
    end

    private

    # Integrity only: the stored individual must read, hold the expected
    # identity, take a free listing ID, and (version 2) hold every accepted
    # piece; what a version-1 archive lacks is reported, never invented.
    def restore_checks(staged, archive, files, listing_id, expected_identity)
      staged.place_archive_files!(files)
      staged.send(:backup_ready!, staged.status)
      identity = staged.identity
      raise Error, "The archive holds #{identity}, not the expected #{expected_identity}" if expected_identity && identity != expected_identity
      listed = listing_id || identity
      raise Error, "#{listed} is already listed on this host; name another listing ID for this restore (its identity stays #{identity})" if listed?(listed)
      absent = staged.send(:absent_accepted_pieces, staged.chain)
      raise Error, "The archive lacks accepted pieces its ledger names (#{absent.length}); refused" if archive['version'] == 2 && !absent.empty?

      { listed: listed, missing: archive['version'] == 2 ? [] : absent }
    end
  end

  class Instance
    # What a terminal restore shows before the owner confirms an unsigned
    # archive (M15): profile, direction, personality, the count and titles of
    # chat summaries and owner-written entries, and lineage.
    def restore_summary(archive, missing)
      companion = companion_status[:companion]
      chats = verified_chat_entries.map { |e| e.description.to_s }
      # An entry is a growth entry only when a recorded cycle names it (its
      # ledger intent, or a completed request of the 0.6 growth state); an ID
      # alone does not take an entry off this screen.
      growth = Records.of_type(chain, 'kairomone_growth_completed').flat_map { |r| [r['l1_id'], r['l2_id']] }
      legacy = autonomy.send(:legacy_state)
      growth += legacy['requests'].values.select { |r| r['state'] == 'completed' }.flat_map { |r| [r.dig('result', 'l1_id'), r.dig('result', 'l2_id')] } if legacy
      owned = knowledge_entries.reject { |e| growth.include?(e['id']) }.map { |e| "L1 #{e['title']}" } +
              observation_entries.reject { |e| growth.include?(e['id']) }.map { |e| "L2 #{e['title']}" }
      lineage = Records.of_type(chain, 'kairomone_lineage').map { |r| "#{r['kind']} from #{Array(r['sources']).map { |s| s['identity'] }.join(' + ')}" }
      p = profile
      lines = ["Archive version #{archive['version']}, manifest #{archive['manifest_sha256'][0, 16]}…, not signed by this host",
               "Kairomone: #{identity} (#{p['display_name'] || p['name']})",
               "Profile: #{JSON.generate(p.reject { |k, _| %w[dot_id display_name host_l0_baseline].include?(k) })}",
               "Direction: #{companion['direction']['preset']} — #{companion['direction']['text']}",
               "Personality: #{companion['personality']}",
               "Chat summaries: #{chats.length}"] +
              chats.map { |t| "  - #{t}" } +
              ["Owner-written entries: #{owned.length}"] + owned.map { |t| "  - #{t}" } +
              ["Lineage: #{lineage.empty? ? 'none recorded' : lineage.join('; ')}"]
      lines << "Accepted pieces this archive lacks (restored without them): #{missing.length}" unless missing.empty?
      lines.map { |l| tty_safe(l) }
    end
  end
end
