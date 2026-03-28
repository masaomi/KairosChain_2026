# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'time'

module MMP
  # Tracks usage of acquired skills and generates attestation nudge messages.
  # Storage: single JSON file with flock for atomic read-modify-write.
  # In-memory indexes for fast gate lookups (no file I/O on miss).
  class AttestationNudge
    USAGE_FILE = 'attestation_nudge_usage.json'
    DEFAULT_THRESHOLD = 3
    DEFAULT_COOLDOWN_HOURS = 24
    DEFAULT_NUDGE_INTERVAL_HOURS = 4

    @instance = nil
    @instance_mutex = Mutex.new

    def self.instance(storage_dir = nil)
      @instance_mutex.synchronize do
        @instance ||= new(storage_dir || KairosMcp.storage_dir)
      end
    end

    def self.reset!
      @instance_mutex.synchronize { @instance = nil }
    end

    def initialize(storage_dir)
      @storage_dir = storage_dir
      @tool_name_index = {}
      @file_path_index = {}
      rebuild_indexes
    end

    # Register a newly acquired skill for tracking.
    # Re-acquisition with new content_hash resets use_count and attested.
    def register_acquisition(skill_id:, skill_name:, owner_agent_id:,
                             content_hash:, file_path: nil, tool_names: [])
      key = composite_key(skill_id, owner_agent_id)
      with_locked_data do |data|
        existing = data[key]
        if existing
          if existing['content_hash'] != content_hash
            # New version: reset tracking
            existing['content_hash'] = content_hash
            existing['use_count'] = 0
            existing['attested'] = false
            existing['attested_at'] = nil
            existing['last_nudge_at'] = nil
            existing['last_used_at'] = nil
            existing['file_path'] = file_path
            existing['tool_names'] = tool_names
          end
          # Same content_hash: no changes needed
        else
          data[key] = {
            'key' => key,
            'skill_id' => skill_id,
            'skill_name' => skill_name,
            'owner_agent_id' => owner_agent_id,
            'content_hash' => content_hash,
            'acquired_at' => Time.now.utc.iso8601,
            'use_count' => 0,
            'last_used_at' => nil,
            'attested' => false,
            'attested_at' => nil,
            'last_nudge_at' => nil,
            'file_path' => file_path,
            'tool_names' => tool_names
          }
        end
      end
      rebuild_indexes
    end

    # Called by gate: check in-memory index first, file I/O only on match.
    def record_tool_usage(tool_name)
      key = @tool_name_index[tool_name]
      return unless key

      increment_usage(key)
    end

    # Called by MMP read paths: check in-memory index first.
    def record_file_usage(file_path)
      key = @file_path_index[file_path]
      return unless key

      increment_usage(key)
    end

    # Mark a skill as attested. Stops further nudges for this (skill_id, owner).
    def mark_attested(skill_id:, owner_agent_id:)
      key = composite_key(skill_id, owner_agent_id)
      with_locked_data do |data|
        entry = data[key]
        if entry
          entry['attested'] = true
          entry['attested_at'] = Time.now.utc.iso8601
        end
      end
    end

    # Returns a nudge message string if any acquired skill is eligible, or nil.
    # Sets last_nudge_at on emission (passive decline = cooldown start).
    def pending_nudge
      config = load_nudge_config
      threshold = config['threshold'] || DEFAULT_THRESHOLD
      cooldown = config['cooldown_hours'] || DEFAULT_COOLDOWN_HOURS
      interval = config['nudge_interval_hours'] || DEFAULT_NUDGE_INTERVAL_HOURS

      nudge_data = nil
      with_locked_data do |data|
        now = Time.now.utc
        eligible = data.values.select do |entry|
          !entry['attested'] &&
            (entry['use_count'] || 0) >= threshold &&
            (entry['last_nudge_at'].nil? ||
              hours_since(entry['last_nudge_at'], now) >= cooldown)
        end
        best = eligible.max_by { |e| e['use_count'] || 0 }
        next unless best

        # Global interval: no nudge if any nudge was shown recently
        last_any = data.values.map { |e| e['last_nudge_at'] }.compact.max
        next if last_any && hours_since(last_any, now) < interval

        # Passive decline: mark nudge emission time
        best['last_nudge_at'] = now.iso8601
        nudge_data = best.dup
      end

      return nil unless nudge_data

      format_nudge_message(nudge_data)
    end

    # Expose for testing
    def tool_name_index
      @tool_name_index.dup
    end

    def file_path_index
      @file_path_index.dup
    end

    private

    def composite_key(skill_id, owner_agent_id)
      Digest::SHA256.hexdigest("#{skill_id}|#{owner_agent_id}")[0, 12]
    end

    def rebuild_indexes
      @tool_name_index = {}
      @file_path_index = {}
      data = load_data_readonly
      data.each do |key, entry|
        (entry['tool_names'] || []).each { |tn| @tool_name_index[tn] = key }
        @file_path_index[entry['file_path']] = key if entry['file_path']
      end
    end

    def increment_usage(key)
      with_locked_data do |data|
        entry = data[key]
        next unless entry && !entry['attested']

        entry['use_count'] = (entry['use_count'] || 0) + 1
        entry['last_used_at'] = Time.now.utc.iso8601
      end
    end

    def with_locked_data
      path = File.join(@storage_dir, USAGE_FILE)
      FileUtils.mkdir_p(@storage_dir)
      File.open(path, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        raw = f.read
        data = raw.empty? ? {} : JSON.parse(raw)
        yield(data)
        f.rewind
        f.write(JSON.generate(data))
        f.truncate(f.pos)
      end
    end

    def load_data_readonly
      path = File.join(@storage_dir, USAGE_FILE)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      {}
    end

    def hours_since(iso_time, now = Time.now.utc)
      (now - Time.parse(iso_time)).to_f / 3600
    end

    def load_nudge_config
      config = ::MMP.load_config
      config['attestation_nudge'] || {}
    rescue StandardError
      {}
    end

    def format_nudge_message(entry)
      skill_name = entry['skill_name'] || entry['skill_id']
      owner = entry['owner_agent_id']
      skill_id = entry['skill_id']
      count = entry['use_count']

      "You've used '#{skill_name}' (from #{owner}) #{count} times since acquiring it.\n" \
        "To attest this skill on the Meeting Place, run:\n" \
        "  meeting_attest_skill(skill_id: \"#{skill_id}\", " \
        "owner_agent_id: \"#{owner}\", claim: \"used\")\n" \
        "This helps other agents discover trustworthy skills."
    end
  end
end
