# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative 'backend'
require_relative '../../kairos_mcp'

module KairosMcp
  module Storage
    # File-based storage backend (default)
    #
    # This is the default storage backend for KairosChain, suitable for
    # individual use. Data is stored in JSON/JSONL files.
    #
    # Storage locations:
    # - Blockchain: storage/blockchain.json
    # - Action logs: skills/action_log.jsonl
    # - Knowledge metadata: extracted from *.md files (no separate storage)
    #
    class FileBackend < Backend
      def initialize(config = {})
        @storage_dir = config[:storage_dir] || KairosMcp.storage_dir
        @blockchain_file = config[:blockchain_file] || KairosMcp.blockchain_path
        @action_log_file = config[:action_log_file] || KairosMcp.action_log_path

        FileUtils.mkdir_p(@storage_dir)
        FileUtils.mkdir_p(File.dirname(@action_log_file))
      end

      # ===========================================================================
      # Block Operations
      # ===========================================================================

      # Read contract (see Backend#load_blocks): nil means the ledger does not
      # exist, and nothing else. A ledger that exists but cannot be opened or
      # parsed — a zero-byte file included — raises Storage::Error. Returning nil
      # there would make a damaged ledger indistinguishable from a fresh install,
      # and the next append would rebuild from genesis over it.
      def load_blocks
        # Absence is decided by stat, not by File.exist?. File.exist? answers
        # false for EVERY stat(2) failure, not only ENOENT — an unsearchable
        # parent directory, a symlink loop, EIO on a network mount, or a macOS
        # ACL denying readattr all read as "no ledger here". Measured on darwin
        # 23.6: with `chmod +a "user deny readattr"` on the ledger, File.exist?
        # is false while File.read and File.write both still succeed, so the
        # ledger classified :absent and the next append rebuilt from genesis
        # over it — 6 blocks became 2. Only ENOENT and ENOTDIR mean the ledger
        # is not there; every other stat failure means we cannot tell.
        begin
          File.stat(@blockchain_file)
        rescue Errno::ENOENT, Errno::ENOTDIR
          return nil
        rescue SystemCallError => e
          raise Storage::Error,
                "cannot determine whether ledger #{@blockchain_file} exists: #{e.message}"
        end

        # FIX E — NEW CLAIM: the bytes on disk alone decide the classification;
        # the process locale never does. The ledger is always written as UTF-8,
        # but File.read without an encoding tags the bytes with the locale-derived
        # default. Started with LANG unset (launchd, cron, plain containers), a
        # ledger holding non-ASCII text then fails the parse and a healthy 705-block
        # ledger reads :corrupt (measured on a copy of a production ledger; the
        # shipped pre-fix code went further and erased it to 2 blocks on the next
        # append). The bytes were never wrong — only the read was.
        json_data = JSON.parse(File.read(@blockchain_file, encoding: Encoding::UTF_8), symbolize_names: true)
        unless json_data.is_a?(Array)
          raise Storage::Error, "ledger #{@blockchain_file} is not a JSON array (got #{json_data.class})"
        end

        json_data.map do |block_data|
          normalize_block_data(block_data)
        end
      rescue Storage::Error
        raise
      rescue JSON::ParserError, ArgumentError, SystemCallError, IOError, NoMethodError, TypeError => e
        raise Storage::Error, "failed to load blocks from #{@blockchain_file}: #{e.message}"
      end

      def save_block(block)
        blocks = load_blocks || []
        blocks << block_to_hash(block)
        save_all_blocks(blocks)
      end

      # Write contract (see Backend#save_all_blocks): failure raises
      # Storage::Error. The previous `false` return collapsed every failure into
      # a value that reads as benign at the call site.
      def save_all_blocks(blocks)
        FileUtils.mkdir_p(File.dirname(@blockchain_file))
        File.write(@blockchain_file, JSON.pretty_generate(blocks.map { |b| block_to_hash(b) }))
        true
      rescue StandardError => e
        raise Storage::Error, "failed to save blocks to #{@blockchain_file}: #{e.message}"
      end

      def all_blocks
        load_blocks || []
      end

      # ===========================================================================
      # Action Log Operations
      # ===========================================================================

      def record_action(entry)
        normalized = {
          timestamp: entry[:timestamp] || Time.now.iso8601,
          action: entry[:action],
          skill_id: entry[:skill_id],
          details: entry[:details]
        }

        FileUtils.mkdir_p(File.dirname(@action_log_file))
        File.open(@action_log_file, 'a') { |f| f.puts(normalized.to_json) }
        true
      rescue StandardError => e
        warn "[FileBackend] Failed to record action: #{e.message}"
        false
      end

      def action_history(limit: 50)
        return [] unless File.exist?(@action_log_file)

        File.readlines(@action_log_file)
            .last(limit)
            .filter_map { |line| JSON.parse(line, symbolize_names: true) rescue nil }
      end

      def clear_action_log!
        File.write(@action_log_file, '')
        true
      rescue StandardError => e
        warn "[FileBackend] Failed to clear action log: #{e.message}"
        false
      end

      # ===========================================================================
      # Knowledge Meta Operations
      # ===========================================================================
      # For FileBackend, metadata is not stored separately.
      # These methods are no-ops or return empty results.
      # The actual metadata is extracted from *.md files by KnowledgeProvider.

      def save_knowledge_meta(_name, _meta)
        # No-op for file backend - metadata is in the files
        true
      end

      def get_knowledge_meta(_name)
        # No separate metadata storage - return nil
        nil
      end

      def list_knowledge_meta
        # No separate metadata storage - return empty array
        []
      end

      def delete_knowledge_meta(_name)
        # No-op for file backend
        true
      end

      def update_knowledge_archived(_name, _archived, reason: nil)
        # No-op for file backend - archiving is folder-based
        true
      end

      # ===========================================================================
      # Utility Methods
      # ===========================================================================

      def ready?
        true
      end

      def backend_type
        :file
      end

      # Get the blockchain file path (for compatibility)
      attr_reader :blockchain_file, :action_log_file, :storage_dir

      private

      def normalize_block_data(data)
        {
          index: data[:index],
          timestamp: data[:timestamp],
          data: data[:data],
          previous_hash: data[:previous_hash],
          merkle_root: data[:merkle_root],
          hash: data[:hash]
        }
      end

      def block_to_hash(block)
        if block.is_a?(Hash)
          normalize_block_data(block)
        elsif block.respond_to?(:to_h)
          normalize_block_data(block.to_h)
        else
          block
        end
      end
    end
  end
end
