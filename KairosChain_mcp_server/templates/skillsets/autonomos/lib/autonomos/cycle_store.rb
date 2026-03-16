# frozen_string_literal: true

module Autonomos
  # Persists cycle state and manages concurrency locks.
  # Uses file-based storage under .kairos/autonomos/cycles/ (L2-equivalent).
  # Follows autoexec PlanStore lock pattern (PID-based, atomic CREAT|EXCL).
  class CycleStore
    LOCK_FILE = 'autonomos.lock'

    VALID_STATES = %w[
      observing orienting decided
      approved rejected no_action
      executed reflected cycle_complete
    ].freeze

    # --- Cycle State ---

    def self.save(cycle_id, state)
      validate_cycle_id!(cycle_id)
      cycles_dir = Autonomos.storage_path('cycles')
      path = File.join(cycles_dir, "#{cycle_id}.json")

      state[:updated_at] = Time.now.iso8601
      File.write(path, JSON.pretty_generate(state))
    end

    def self.load(cycle_id)
      cycles_dir = Autonomos.storage_path('cycles')
      path = File.join(cycles_dir, "#{cycle_id}.json")
      return nil unless File.exist?(path)

      JSON.parse(File.read(path), symbolize_names: true)
    end

    def self.load_latest
      cycles_dir = Autonomos.storage_path('cycles')
      files = Dir.glob(File.join(cycles_dir, '*.json')).sort_by { |f| File.mtime(f) }
      return nil if files.empty?

      JSON.parse(File.read(files.last), symbolize_names: true)
    rescue JSON::ParserError
      nil
    end

    def self.list(limit: 20)
      cycles_dir = Autonomos.storage_path('cycles')
      files = Dir.glob(File.join(cycles_dir, '*.json'))
                 .sort_by { |f| File.mtime(f) }
                 .last(limit)

      files.map do |path|
        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end.compact
    end

    def self.update_state(cycle_id, new_state)
      existing = load(cycle_id)
      return false unless existing

      unless VALID_STATES.include?(new_state)
        raise ArgumentError, "Invalid state: #{new_state}. Valid: #{VALID_STATES.join(', ')}"
      end

      existing[:state] = new_state
      existing[:state_history] ||= []
      existing[:state_history] << { state: new_state, at: Time.now.iso8601 }
      save(cycle_id, existing)
      true
    end

    # --- Concurrency Lock (same pattern as autoexec PlanStore) ---

    def self.acquire_lock(cycle_id)
      state_dir = Autonomos.storage_path('state')
      lock_path = File.join(state_dir, LOCK_FILE)

      if File.exist?(lock_path)
        lock_data = JSON.parse(File.read(lock_path)) rescue {}
        pid = lock_data['pid']

        pid_alive = begin
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        if pid_alive
          stale_timeout = Autonomos.config.fetch('stale_lock_timeout', 3600)
          lock_age = Time.now - Time.parse(lock_data['started_at'])
          if lock_age < stale_timeout
            raise "Cycle locked by '#{lock_data['cycle_id']}' (PID #{pid}, " \
                  "started #{lock_data['started_at']}). Use autonomos_status to check."
          end
        end
        File.delete(lock_path) rescue nil
      end

      lock_data = JSON.pretty_generate({
        cycle_id: cycle_id.to_s,
        pid: Process.pid,
        started_at: Time.now.iso8601
      })
      begin
        fd = File.open(lock_path, File::CREAT | File::EXCL | File::WRONLY)
        fd.write(lock_data)
        fd.close
      rescue Errno::EEXIST
        raise "Cycle locked by another process (race condition). Retry shortly."
      end
      true
    end

    def self.release_lock
      state_dir = Autonomos.storage_path('state')
      lock_path = File.join(state_dir, LOCK_FILE)
      return unless File.exist?(lock_path)

      # Verify ownership: only release if we hold the lock
      begin
        lock_data = JSON.parse(File.read(lock_path))
        if lock_data['pid'] == Process.pid
          File.delete(lock_path)
        else
          warn "[autonomos] Lock owned by PID #{lock_data['pid']}, not releasing (our PID: #{Process.pid})"
        end
      rescue JSON::ParserError, Errno::ENOENT
        # Corrupted or already deleted — safe to ignore
      end
    end

    def self.locked?
      state_dir = Autonomos.storage_path('state')
      lock_path = File.join(state_dir, LOCK_FILE)
      return false unless File.exist?(lock_path)

      lock_data = JSON.parse(File.read(lock_path))
      begin
        Process.kill(0, lock_data['pid'])
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
    rescue StandardError
      false
    end

    # --- Helpers ---

    def self.generate_cycle_id
      "cyc_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(3)}"
    end

    def self.validate_cycle_id!(cycle_id)
      unless cycle_id.to_s.match?(/\A[\w\-]+\z/)
        raise ArgumentError, "Invalid cycle_id: must contain only word characters and hyphens"
      end
    end
  end
end
