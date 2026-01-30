# frozen_string_literal: true

require 'digest'
require 'time'
require 'json'
require 'fileutils'

module KairosMcp
  module MeetingPlace
    # Audit logger for Meeting Place operations.
    # CRITICAL: This logger ONLY records metadata and hashes, NEVER content.
    # This is by design to preserve privacy while enabling auditability.
    class AuditLogger
      DEFAULT_MAX_ENTRIES = 10_000
      
      attr_reader :config

      def initialize(config: {}, log_path: nil)
        @config = {
          max_entries: config[:max_entries] || DEFAULT_MAX_ENTRIES,
          anonymize_participants: config[:anonymize_participants] || false,
          anonymization_salt: config[:anonymization_salt] || SecureRandom.hex(16)
        }
        @log_path = log_path
        @entries = []
        @mutex = Mutex.new
        @stats = initialize_stats
        
        load_from_file if @log_path && File.exist?(@log_path)
      end

      # Log a relay operation
      # IMPORTANT: Only metadata is logged, never the actual content
      def log_relay(action:, relay_id:, from:, to:, message_type:, blob_hash:, size_bytes:)
        entry = {
          timestamp: Time.now.utc.iso8601,
          event_type: 'relay',
          action: action.to_s,
          relay_id: relay_id,
          
          # Participants (optionally anonymized)
          participants: anonymize_if_configured([from, to]),
          
          # Metadata only
          message_type: message_type,
          size_bytes: size_bytes,
          content_hash: blob_hash,  # Hash of encrypted blob, NOT the content
          
          # EXPLICIT: We do NOT log these
          # content: NEVER
          # decrypted_content: NEVER
          # plaintext: NEVER
        }

        append_entry(entry)
        update_stats(entry)
      end

      # Log an agent registration
      def log_registration(agent_id:, action:, metadata: {})
        entry = {
          timestamp: Time.now.utc.iso8601,
          event_type: 'registration',
          action: action.to_s,
          agent_id: anonymize_if_configured([agent_id]).first,
          # Only safe metadata fields
          endpoint_present: metadata[:endpoint].nil? ? false : true,
          capabilities_count: metadata[:capabilities]&.size || 0
        }

        append_entry(entry)
        update_stats(entry)
      end

      # Log a key registration
      def log_key_registration(agent_id:, key_fingerprint:)
        entry = {
          timestamp: Time.now.utc.iso8601,
          event_type: 'key_registration',
          agent_id: anonymize_if_configured([agent_id]).first,
          key_fingerprint: key_fingerprint  # Fingerprint is safe to log
        }

        append_entry(entry)
        update_stats(entry)
      end

      # Log bulletin board activity
      def log_bulletin(action:, posting_id:, agent_id:, posting_type:)
        entry = {
          timestamp: Time.now.utc.iso8601,
          event_type: 'bulletin',
          action: action.to_s,
          posting_id: posting_id,
          agent_id: anonymize_if_configured([agent_id]).first,
          posting_type: posting_type
        }

        append_entry(entry)
        update_stats(entry)
      end

      # Get recent audit entries (metadata only)
      def recent_entries(limit: 100, event_type: nil, since: nil)
        @mutex.synchronize do
          entries = @entries.dup
          
          # Filter by event type
          entries = entries.select { |e| e[:event_type] == event_type } if event_type
          
          # Filter by time
          if since
            since_time = since.is_a?(Time) ? since : Time.parse(since)
            entries = entries.select { |e| Time.parse(e[:timestamp]) >= since_time }
          end
          
          entries.last(limit)
        end
      end

      # Get aggregated statistics
      def stats
        @mutex.synchronize do
          @stats.dup
        end
      end

      # Get hourly statistics
      def hourly_stats(hours: 24)
        now = Time.now.utc
        
        @mutex.synchronize do
          hourly = {}
          
          hours.times do |i|
            hour_start = now - (i * 3600)
            hour_key = hour_start.strftime('%Y-%m-%d %H:00')
            hourly[hour_key] = {
              relay_count: 0,
              total_bytes: 0,
              unique_agents: Set.new
            }
          end
          
          @entries.each do |entry|
            entry_time = Time.parse(entry[:timestamp])
            hour_key = entry_time.strftime('%Y-%m-%d %H:00')
            
            next unless hourly.key?(hour_key)
            
            if entry[:event_type] == 'relay'
              hourly[hour_key][:relay_count] += 1
              hourly[hour_key][:total_bytes] += entry[:size_bytes] || 0
            end
            
            if entry[:participants]
              entry[:participants].each do |p|
                hourly[hour_key][:unique_agents].add(p)
              end
            end
          end
          
          # Convert Sets to counts
          hourly.transform_values do |v|
            v[:unique_agents] = v[:unique_agents].size
            v
          end
        end
      end

      # Save audit log to file
      def save_to_file(path = nil)
        path ||= @log_path
        return unless path

        FileUtils.mkdir_p(File.dirname(path))
        
        @mutex.synchronize do
          File.write(path, JSON.pretty_generate({
            saved_at: Time.now.utc.iso8601,
            config: @config.reject { |k, _| k == :anonymization_salt },
            stats: @stats,
            entries: @entries
          }))
        end
      end

      # Clear old entries (keep last N)
      def prune(keep: nil)
        keep ||= @config[:max_entries]
        
        @mutex.synchronize do
          if @entries.size > keep
            @entries = @entries.last(keep)
          end
        end
        
        save_to_file if @log_path
      end

      # Verify that no content is logged (for testing/audit)
      def verify_no_content_logged
        forbidden_keys = [:content, :decrypted_content, :plaintext, :message, :skill_content]
        
        @mutex.synchronize do
          @entries.each do |entry|
            forbidden_keys.each do |key|
              if entry.key?(key)
                raise SecurityError, "Audit log contains forbidden key: #{key}"
              end
            end
          end
        end
        
        true
      end

      private

      def append_entry(entry)
        @mutex.synchronize do
          @entries << entry
          
          # Auto-prune if too many entries
          if @entries.size > @config[:max_entries]
            @entries.shift
          end
        end
        
        # Async save (could be improved with batching)
        save_to_file if @log_path && @entries.size % 100 == 0
      end

      def anonymize_if_configured(ids)
        return ids unless @config[:anonymize_participants]
        
        ids.map do |id|
          next nil if id.nil?
          hash = Digest::SHA256.hexdigest("#{id}:#{@config[:anonymization_salt]}")
          "anon_#{hash[0, 12]}"
        end
      end

      def initialize_stats
        {
          total_relays: 0,
          total_bytes_relayed: 0,
          total_registrations: 0,
          total_key_registrations: 0,
          total_bulletin_posts: 0,
          started_at: Time.now.utc.iso8601,
          last_activity_at: nil
        }
      end

      def update_stats(entry)
        @mutex.synchronize do
          @stats[:last_activity_at] = entry[:timestamp]
          
          case entry[:event_type]
          when 'relay'
            @stats[:total_relays] += 1
            @stats[:total_bytes_relayed] += entry[:size_bytes] || 0
          when 'registration'
            @stats[:total_registrations] += 1
          when 'key_registration'
            @stats[:total_key_registrations] += 1
          when 'bulletin'
            @stats[:total_bulletin_posts] += 1
          end
        end
      end

      def load_from_file
        return unless @log_path && File.exist?(@log_path)
        
        data = JSON.parse(File.read(@log_path), symbolize_names: true)
        
        @mutex.synchronize do
          @entries = data[:entries] || []
          @stats = data[:stats] || initialize_stats
        end
      rescue JSON::ParserError, Errno::ENOENT
        # Start fresh if file is corrupted or missing
      end
    end
  end
end
