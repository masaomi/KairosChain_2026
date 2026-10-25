# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

module SecureMmp
  # Refused introduces, kept so the operator can see who knocked and pin a key
  # by copying its full hash. Not a decision and never chain-recorded. Every
  # field has a fixed shape; claimed_name is peer-supplied and unverified.
  module Knocks
    MAX_ENTRIES = 20
    MAX_NAME = 64
    RATE_WINDOW_SECONDS = 60
    KEY_PATTERN = /\A[0-9a-f]{64}\z/
    INSTANCE_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    ADDR_PATTERN = /\A[0-9A-Fa-f:.]{1,64}\z/

    @last_by_addr = {}
    @rate_mutex = Mutex.new

    class << self
      def path
        File.join(KairosMcp.storage_dir, 'secure_mmp', 'knocks.json')
      end

      # Record one refused introduce. At most one write per remote address per
      # minute; the list keeps the newest MAX_ENTRIES keys.
      def record(candidate, now: Time.now.utc)
        key = candidate[:key_sha256].to_s
        return false unless KEY_PATTERN.match?(key)

        addr = candidate[:remote_addr].to_s
        addr = 'unknown' unless ADDR_PATTERN.match?(addr)
        return false unless rate_ok?(addr, now)

        instance_id = candidate[:instance_id].to_s
        instance_id = nil unless INSTANCE_ID_PATTERN.match?(instance_id)
        name = candidate[:claimed_name].to_s.gsub(/[^ -~]/, '')[0, MAX_NAME]

        with_lock do |entries|
          existing = entries.find { |e| e['key_sha256'] == key }
          if existing
            existing['last_seen'] = now.iso8601
            existing['count'] = existing['count'].to_i + 1
            existing['remote_addr'] = addr
            existing['claimed_name'] = name
            existing['instance_id'] = instance_id
            entries.delete(existing)
            entries << existing
          else
            entries << { 'key_sha256' => key, 'instance_id' => instance_id, 'remote_addr' => addr,
                         'claimed_name' => name, 'first_seen' => now.iso8601, 'last_seen' => now.iso8601,
                         'count' => 1 }
          end
          entries.shift while entries.size > MAX_ENTRIES
          entries
        end
        true
      rescue StandardError => e
        warn "[SecureMmp::Knocks] could not record a knock: #{e.class}: #{e.message}"
        false
      end

      def list
        read_entries.reverse
      end

      def dismiss(key_sha256)
        removed = false
        with_lock do |entries|
          before = entries.size
          entries.reject! { |e| e['key_sha256'] == key_sha256.to_s }
          removed = entries.size < before
          entries
        end
        removed
      end

      private

      def rate_ok?(addr, now)
        @rate_mutex.synchronize do
          last = @last_by_addr[addr]
          return false if last && now - last < RATE_WINDOW_SECONDS

          @last_by_addr.delete_if { |_a, t| now - t >= RATE_WINDOW_SECONDS }
          @last_by_addr[addr] = now
          true
        end
      end

      def read_entries
        return [] unless File.exist?(path)

        data = JSON.parse(File.read(path))
        data.is_a?(Array) ? data.select { |e| e.is_a?(Hash) } : []
      rescue JSON::ParserError, SystemCallError
        []
      end

      # Exclusive lock on a sidecar file, re-read under it, write a temp file
      # and rename, so the listener and the interactive process never lose
      # each other's updates.
      def with_lock
        FileUtils.mkdir_p(File.dirname(path))
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          entries = yield(read_entries)
          tmp = "#{path}.tmp.#{Process.pid}"
          File.write(tmp, JSON.pretty_generate(entries))
          File.rename(tmp, path)
        end
      end
    end
  end
end
