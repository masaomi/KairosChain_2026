# frozen_string_literal: true

module Kairomone
  class Instance
    ARCHIVE_LIMIT = 32 * 1024 * 1024
    TOTAL_LIMIT = 20 * 1024 * 1024
    LEDGER_LIMIT = 16 * 1024 * 1024
    ARCHIVE_FORMAT = 'kairomone-owned-backup'

    def create_backup
      autonomy.synchronize do
        with_lock do
          ensure_initialized!
          raise Error, 'Restored targets are read-only' if @restored
          snapshot = status
          backup_ready!(snapshot)
          paths = ['profile.json']
          paths << MEMORY_GATE_PATH if File.exist?(Paths.checked(root, MEMORY_GATE_PATH))
          paths << COMPANION_PATH if File.exist?(Paths.checked(root, COMPANION_PATH))
          paths += entry_ids("context/#{CHAT_SESSION}", optional: true).map { |id| "context/#{CHAT_SESSION}/#{id}/#{id}.md" }
          paths << 'profession.json' if File.exist?(Paths.checked(root, 'profession.json'))
          paths << Autonomy::STATE_PATH if File.exist?(Paths.checked(root, Autonomy::STATE_PATH))
          paths += entry_ids('knowledge').map { |id| "knowledge/#{id}/#{id}.md" }
          paths += entry_ids("context/#{L2_SESSION}", optional: true).map { |id| "context/#{L2_SESSION}/#{id}/#{id}.md" }
          paths << 'storage/blockchain.json' if File.exist?(Paths.checked(root, 'storage/blockchain.json'))
          total = 0
          files = paths.sort.map do |relative|
            bytes = Paths.read(root, relative, limit: relative == 'storage/blockchain.json' ? LEDGER_LIMIT : 1_048_576)
            total += bytes.bytesize
            raise Error, 'Owned backup exceeds 20 MiB total limit' if total > TOTAL_LIMIT
            { 'path' => relative, 'size' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'content_base64' => Base64.strict_encode64(bytes) }
          end
          archive = { 'format' => ARCHIVE_FORMAT, 'version' => 1, 'created_at' => Time.now.utc.iso8601,
                      'scope' => BACKUP_SCOPE, 'excluded' => BACKUP_EXCLUDED, 'files' => files,
                      'manifest_sha256' => manifest_hash(files) }
          bytes = JSON.pretty_generate(archive) + "\n"
          raise Error, 'Encoded backup exceeds 32 MiB limit' if bytes.bytesize > ARCHIVE_LIMIT
          name = "kairomone-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}.kairomone.json"
          path = Paths.write(root, "backups/#{name}", bytes)
          # Verify the bytes just delivered, not only the in-memory source.
          verify_backup(file: name).merge(success: true, file: name, path: path, scope: BACKUP_SCOPE, excluded: BACKUP_EXCLUDED)
        end
      end
    end

    # Explicit portable recovery into a fresh active host. The caller selects
    # KAIROS_DATA_DIR outside tool arguments and deliberately places an archive
    # in its fixed inbox; no arbitrary read or write path is accepted.
    def restore_new(file:, dot_id:)
      Paths.id!(dot_id)
      raise Error, 'Restored inspection targets cannot activate another instance' if @restored
      FileUtils.mkdir_p(host_root, mode: 0o700)
      lock_path = Paths.checked(host_root, '.kairomone-restore.lock')
      Paths.regular_file!(lock_path, optional: true, limit: 1_048_576)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        raise Error, 'Active Kairomone path already exists; fresh-host restore never overwrites it' if File.exist?(Paths.checked(host_root, 'kairomone'))
        archive, files = load_archive(file, inbox: true)
        outcome = nil
        stage_archive(files) do |staged|
          snapshot = staged.status
          backup_ready!(snapshot)
          raise Error, 'Backup dot_id does not match the explicitly expected dot_id' unless snapshot[:profile]['dot_id'] == dot_id
          raise Error, 'Active Kairomone path already exists; no data was overwritten' if File.exist?(Paths.checked(host_root, 'kairomone'))
          staged.send(:reset_restored_growth!)
          File.rename(staged.root, root)
          l0 = snapshot[:integrity][:host_l0]
          outcome = { success: true, restored: true, active: true, dot_id: dot_id, path: root,
                      source: 'fixed kairomone-inbox', manifest_sha256: archive['manifest_sha256'],
                      integrity: snapshot[:integrity],
                      warning: 'Backup is unencrypted and may contain private user-authored text. Original L0 baseline is preserved; host L0 is not installed or modified.' }
          outcome[:l0_warning] = "Current host L0 comparison is #{l0[:state]}; review the two-file fingerprint scope before continuing" unless l0[:state] == 'unchanged'
        end
        outcome
      end
    end

    def verify_backup(file:)
      archive, files = load_archive(file)
      # Verification is offline and uses a temporary owned staging directory.
      # It does not alter the live profile, knowledge, context or ledger.
      result = stage_archive(files) do |staged|
        snapshot = staged.status
        backup_ready!(snapshot)
        { success: true, verified: true, file: file, file_count: files.length,
          manifest_sha256: archive['manifest_sha256'], integrity: snapshot[:integrity],
          authenticity: 'Local SHA-256 consistency only; this archive is not signed or encrypted' }
      end
      result
    end

    def restore_backup(file:, target_id:)
      Paths.id!(target_id)
      with_lock do
        ensure_initialized!
        raise Error, 'Restored targets are read-only' if @restored
        target = Paths.checked(host_root, "kairomone-restored/#{target_id}")
        raise Error, 'Restore target already exists; no data was overwritten' if File.exist?(target)
        archive, files = load_archive(file)
        restored = nil
        stage_archive(files) do |staged|
          snapshot = staged.status
          backup_ready!(snapshot)
          # The target name is fixed beneath the host; archive entries cannot
          # choose it. A restore is a separate, read-only recovery copy.
          raise Error, 'Restore target already exists; no data was overwritten' if File.exist?(target)
          staged.send(:reset_restored_growth!)
          File.rename(staged.root, target)
          restored = { success: true, restored: true, target_id: target_id, path: target,
                       active_instance_changed: false, file_count: files.length,
                       manifest_sha256: archive['manifest_sha256'],
                       instruction: 'Inspect with status --instance TARGET_ID. Activation or migration is a separate operator decision.' }
        end
        restored
      end
    end

    private

    def reset_restored_growth!
      return unless File.exist?(Paths.checked(root, Autonomy::STATE_PATH))
      original = JSON.parse(Paths.read(root, Autonomy::STATE_PATH))
      value = Autonomy.restore_state(original)
      Paths.write(root, Autonomy::STATE_PATH, JSON.pretty_generate(value) + "\n", replace: true)
    end

    def manifest_hash(files)
      Digest::SHA256.hexdigest(JSON.generate(files.map { |entry| entry.slice('path', 'size', 'sha256') }))
    end

    def load_archive(file, inbox: false)
      raise Error, 'Backup filename must be a basename ending in .kairomone.json' unless file.is_a?(String) && Paths::BACKUP_NAME.match?(file)
      bytes = inbox ? Paths.read(host_root, "kairomone-inbox/#{file}", limit: ARCHIVE_LIMIT) : Paths.read(root, "backups/#{file}", limit: ARCHIVE_LIMIT)
      archive = JSON.parse(bytes)
      raise Error, 'Unsupported backup format' unless archive.is_a?(Hash) && archive['format'] == ARCHIVE_FORMAT && archive['version'] == 1
      files = archive['files']
      raise Error, 'Invalid backup file count' unless files.is_a?(Array) && files.length.between?(1, MAX_ENTRIES * 2 + 206)
      seen = {}
      total = 0
      decoded = files.map do |entry|
        raise Error, 'Invalid archive entry' unless entry.is_a?(Hash) && entry.keys.sort == %w[content_base64 path sha256 size]
        relative = entry['path']
        raise Error, 'Forbidden or duplicate archive path' unless allowed_backup_path?(relative) && !seen[relative]
        seen[relative] = true
        size = entry['size']
        maximum = relative == 'storage/blockchain.json' ? LEDGER_LIMIT : 1_048_576
        raise Error, 'Invalid archive entry size' unless size.is_a?(Integer) && size.between?(0, maximum)
        total += size
        raise Error, 'Backup expands beyond 20 MiB limit' if total > TOTAL_LIMIT
        encoded = entry['content_base64']
        raise Error, 'Invalid base64 payload' unless encoded.is_a?(String) && encoded.bytesize <= ((maximum + 2) / 3) * 4
        contents = Base64.strict_decode64(encoded)
        raise Error, 'Backup checksum or size mismatch' unless contents.bytesize == size && Digest::SHA256.hexdigest(contents) == entry['sha256']
        [relative, contents]
      end
      raise Error, 'Backup profile is missing' unless seen['profile.json']
      raise Error, 'Backup manifest checksum mismatch' unless manifest_hash(files) == archive['manifest_sha256']
      [archive, decoded]
    rescue JSON::ParserError, ArgumentError => e
      raise Error, "Invalid backup: #{e.message}"
    end

    def allowed_backup_path?(relative)
      return false unless relative.is_a?(String)
      return true if %w[profile.json profession.json growth/state.json storage/blockchain.json companion/state.json companion/memory-gate.json].include?(relative)
      parts = relative.split('/')
      if parts.length == 3 && parts[0] == 'knowledge'
        id = parts[1]
        return Paths::ID.match?(id) && parts[2] == "#{id}.md"
      end
      if parts.length == 4 && parts[0] == 'context' && [L2_SESSION, CHAT_SESSION].include?(parts[1])
        id = parts[2]
        return Paths::ID.match?(id) && parts[3] == "#{id}.md"
      end
      false
    end

    def stage_archive(files)
      # No OS archive extractor is invoked: no symlinks, hardlinks, devices,
      # executable entries, traversal paths, or archive-selected directories.
      Paths.mkdir(host_root, 'kairomone-restored')
      stage_id = "stage_#{SecureRandom.hex(16)}"
      stage_path = Paths.checked(host_root, "kairomone-restored/#{stage_id}")
      Dir.mkdir(stage_path, 0o700)
      begin
        %w[knowledge context storage backups exports].each { |dir| Paths.mkdir(stage_path, dir) }
        files.each { |relative, bytes| Paths.write(stage_path, relative, bytes) }
        staged = self.class.new(host_root: host_root, restored_id: stage_id)
        # Parsing profile, knowledge and ledger happens after containment and
        # byte limits, before publishing a target directory.
        yield staged
      ensure
        FileUtils.remove_entry_secure(stage_path) if File.directory?(stage_path) && !File.symlink?(stage_path)
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
end
