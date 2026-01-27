# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module KairosMcp
  module StateCommit
    # SnapshotManager: Manages state snapshots (off-chain storage)
    #
    # Snapshots are stored as JSON files in storage/snapshots/
    # Each snapshot contains the full manifest and change history.
    #
    class SnapshotManager
      DEFAULT_SNAPSHOT_DIR = File.expand_path('../../../../storage/snapshots', __dir__)
      DEFAULT_MAX_SNAPSHOTS = 100

      def initialize(snapshot_dir: nil, max_snapshots: nil)
        @snapshot_dir = snapshot_dir || DEFAULT_SNAPSHOT_DIR
        @max_snapshots = max_snapshots || DEFAULT_MAX_SNAPSHOTS
        FileUtils.mkdir_p(@snapshot_dir)
      end

      # Save a new snapshot
      #
      # @param manifest [Hash] Full manifest from ManifestBuilder
      # @param changes [Array<Hash>] Changes since last commit
      # @param reason [String] Reason for the commit
      # @param actor [String] Who created the commit (human/ai/system)
      # @param commit_type [String] Type of commit (explicit/auto/checkpoint)
      # @return [Hash] Snapshot metadata including hash and path
      def save_snapshot(manifest, changes, reason:, actor:, commit_type:)
        timestamp = Time.now
        snapshot_hash = manifest[:combined_hash]

        snapshot = {
          snapshot_hash: snapshot_hash,
          created_at: timestamp.iso8601,
          created_by: actor,
          commit_type: commit_type,
          reason: reason,
          layers: manifest[:layers],
          changes_since_last: changes
        }

        # Generate filename
        filename = "snapshot_#{timestamp.strftime('%Y%m%d_%H%M%S')}_#{snapshot_hash[0..7]}.json"
        filepath = File.join(@snapshot_dir, filename)

        # Save snapshot
        File.write(filepath, JSON.pretty_generate(snapshot))

        # Cleanup old snapshots if needed
        cleanup_old_snapshots

        {
          success: true,
          snapshot_hash: snapshot_hash,
          snapshot_ref: "snapshots/#{filename}",
          filepath: filepath,
          timestamp: timestamp.iso8601
        }
      end

      # Load a snapshot by hash
      #
      # @param snapshot_hash [String] Hash of the snapshot to load
      # @return [Hash, nil] Snapshot data or nil if not found
      def load_snapshot(snapshot_hash)
        snapshot_files.each do |filepath|
          snapshot = load_snapshot_file(filepath)
          return snapshot if snapshot && snapshot['snapshot_hash'] == snapshot_hash
        end
        nil
      end

      # Load a snapshot by filename
      #
      # @param filename [String] Filename of the snapshot
      # @return [Hash, nil] Snapshot data or nil if not found
      def load_snapshot_by_name(filename)
        filepath = File.join(@snapshot_dir, filename)
        load_snapshot_file(filepath)
      end

      # Get the most recent snapshot
      #
      # @return [Hash, nil] Most recent snapshot or nil if none exist
      def get_last_snapshot
        files = snapshot_files
        return nil if files.empty?

        # Files are sorted by modification time descending
        load_snapshot_file(files.first)
      end

      # Get snapshot metadata without loading full content
      #
      # @param filepath [String] Path to snapshot file
      # @return [Hash, nil] Metadata or nil
      def get_snapshot_metadata(filepath)
        snapshot = load_snapshot_file(filepath)
        return nil unless snapshot

        {
          snapshot_hash: snapshot['snapshot_hash'],
          created_at: snapshot['created_at'],
          created_by: snapshot['created_by'],
          commit_type: snapshot['commit_type'],
          reason: snapshot['reason'],
          change_count: snapshot['changes_since_last']&.size || 0
        }
      end

      # List all snapshots (metadata only)
      #
      # @param limit [Integer] Maximum number of snapshots to return
      # @return [Array<Hash>] List of snapshot metadata
      def list_snapshots(limit: 50)
        snapshot_files.first(limit).filter_map do |filepath|
          metadata = get_snapshot_metadata(filepath)
          next unless metadata

          metadata[:filename] = File.basename(filepath)
          metadata
        end
      end

      # Get snapshot count
      #
      # @return [Integer] Number of snapshots
      def count
        snapshot_files.size
      end

      # Check if a snapshot exists
      #
      # @param snapshot_hash [String] Hash to check
      # @return [Boolean] True if snapshot exists
      def exists?(snapshot_hash)
        snapshot_files.any? do |filepath|
          File.basename(filepath).include?(snapshot_hash[0..7])
        end
      end

      # Delete a specific snapshot
      #
      # @param snapshot_hash [String] Hash of snapshot to delete
      # @return [Boolean] True if deleted
      def delete_snapshot(snapshot_hash)
        snapshot_files.each do |filepath|
          if File.basename(filepath).include?(snapshot_hash[0..7])
            FileUtils.rm_f(filepath)
            return true
          end
        end
        false
      end

      # Cleanup old snapshots to maintain max_snapshots limit
      #
      # @param max_count [Integer] Maximum number to keep (uses default if nil)
      # @return [Integer] Number of snapshots deleted
      def cleanup_old_snapshots(max_count = nil)
        max_count ||= @max_snapshots
        files = snapshot_files
        
        return 0 if files.size <= max_count

        # Delete oldest files (files are sorted newest first)
        to_delete = files[max_count..-1]
        to_delete.each { |f| FileUtils.rm_f(f) }
        to_delete.size
      end

      # Get the snapshot directory path
      attr_reader :snapshot_dir

      private

      # Get sorted list of snapshot files (newest first)
      def snapshot_files
        pattern = File.join(@snapshot_dir, 'snapshot_*.json')
        Dir[pattern].sort_by { |f| File.mtime(f) }.reverse
      end

      # Load and parse a snapshot file
      def load_snapshot_file(filepath)
        return nil unless File.exist?(filepath)
        JSON.parse(File.read(filepath))
      rescue JSON::ParserError => e
        warn "[SnapshotManager] Failed to parse #{filepath}: #{e.message}"
        nil
      end
    end
  end
end
