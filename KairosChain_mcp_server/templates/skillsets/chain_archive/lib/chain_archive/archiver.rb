# frozen_string_literal: true

require 'json'
require 'zlib'
require 'fileutils'
require 'digest'
require 'time'

module KairosMcp
  module SkillSets
    module ChainArchive
      # Core archiving engine.
      #
      # Strategy: when the live chain (blockchain.json) exceeds a threshold,
      # compress all current blocks into a numbered segment file and replace
      # the live chain with a single checkpoint block that anchors the archive.
      #
      # The checkpoint block is a valid index-0 block (like genesis), so
      # Chain#valid? passes without any core changes. Full-history integrity
      # is verified separately via verify_archives.
      class Archiver
        DEFAULT_THRESHOLD = 1000
        CHECKPOINT_TYPE = "archive_checkpoint"
        GENESIS_PREVIOUS_HASH = "0" * 64

        def initialize(threshold: nil)
          @threshold = threshold || DEFAULT_THRESHOLD
        end

        # Returns a status hash describing the current archive state.
        def status
          live_blocks = load_live_blocks
          manifest = load_manifest

          total_archived = manifest['segments'].sum { |s| s['block_count'] || 0 }

          {
            live_block_count: live_blocks.size,
            archive_segment_count: manifest['segments'].size,
            total_archived_blocks: total_archived,
            total_blocks: live_blocks.size + total_archived,
            threshold: @threshold,
            should_archive: live_blocks.size > @threshold,
            archives_dir: archives_dir
          }
        end

        # Archives the live chain if it exceeds the threshold.
        #
        # Steps:
        #   1. Compress all live blocks to a numbered segment file.
        #   2. Update the manifest (archives_dir/manifest.json).
        #   3. Replace blockchain.json with a single checkpoint block.
        #
        # Returns a result hash. If the chain is below the threshold,
        # returns { success: false, skipped: true, ... }.
        def archive!(reason: nil, threshold: nil)
          effective_threshold = threshold || @threshold
          live_blocks = load_live_blocks

          if live_blocks.size <= effective_threshold
            return {
              success: false,
              skipped: true,
              reason: "Live chain has #{live_blocks.size} blocks; threshold is #{effective_threshold}"
            }
          end

          FileUtils.mkdir_p(archives_dir)
          manifest = load_manifest
          segment_num = manifest['segments'].size
          segment_filename = format("segment_%06d.json.gz", segment_num)
          seg_path = File.join(archives_dir, segment_filename)

          write_segment(seg_path, live_blocks)
          segment_hash = Digest::SHA256.file(seg_path).hexdigest
          last_block = live_blocks.last
          last_hash = last_block[:hash] || last_block['hash']
          last_index = last_block[:index] || last_block['index']
          first_index = live_blocks.first[:index] || live_blocks.first['index']

          manifest['segments'] << {
            'segment_num'       => segment_num,
            'filename'          => segment_filename,
            'block_count'       => live_blocks.size,
            'first_block_index' => first_index,
            'last_block_index'  => last_index,
            'last_block_hash'   => last_hash,
            'segment_hash'      => segment_hash,
            'archived_at'       => Time.now.utc.iso8601,
            'reason'            => reason
          }
          save_manifest(manifest)

          checkpoint_data = {
            type:              CHECKPOINT_TYPE,
            segment_num:       segment_num,
            segment_filename:  segment_filename,
            segment_hash:      segment_hash,
            blocks_archived:   live_blocks.size,
            last_archived_hash: last_hash,
            total_segments:    manifest['segments'].size,
            archived_at:       Time.now.utc.iso8601,
            reason:            reason
          }
          checkpoint = create_checkpoint_block(checkpoint_data)
          save_live_chain([checkpoint.to_h])

          {
            success:              true,
            blocks_archived:      live_blocks.size,
            segment_filename:     segment_filename,
            segment_hash:         segment_hash,
            new_live_chain_length: 1,
            checkpoint_hash:      checkpoint.hash
          }
        end

        # Verifies integrity of all archive segments.
        def verify_archives
          manifest = load_manifest
          segments = manifest['segments']

          if segments.empty?
            return { valid: true, segments_verified: 0, message: "No archive segments found" }
          end

          results = segments.map { |seg| verify_segment(seg) }
          {
            valid:              results.all? { |r| r[:valid] },
            segments_verified:  results.size,
            segments:           results
          }
        end

        private

        def archives_dir
          File.join(KairosMcp.storage_dir, 'archives')
        end

        def manifest_path
          File.join(archives_dir, 'manifest.json')
        end

        def load_live_blocks
          path = KairosMcp.blockchain_path
          return [] unless File.exist?(path)

          JSON.parse(File.read(path), symbolize_names: true)
        rescue JSON::ParserError
          []
        end

        def save_live_chain(blocks)
          path = KairosMcp.blockchain_path
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate(blocks))
        end

        def write_segment(path, blocks)
          serializable = blocks.map { |b| b.transform_keys(&:to_s) }
          Zlib::GzipWriter.open(path) do |gz|
            gz.write(JSON.generate(serializable))
          end
        end

        def create_checkpoint_block(data)
          data_str = data.to_json
          merkle_root = KairosMcp::KairosChain::MerkleTree.new([data_str]).root
          KairosMcp::KairosChain::Block.new(
            index:         0,
            timestamp:     Time.now.utc,
            data:          [data_str],
            previous_hash: GENESIS_PREVIOUS_HASH,
            merkle_root:   merkle_root
          )
        end

        def load_manifest
          return { 'segments' => [] } unless File.exist?(manifest_path)

          JSON.parse(File.read(manifest_path))
        rescue JSON::ParserError
          { 'segments' => [] }
        end

        def save_manifest(manifest)
          File.write(manifest_path, JSON.pretty_generate(manifest))
        end

        def verify_segment(seg_meta)
          filename = seg_meta['filename']
          path = File.join(archives_dir, filename)

          return { valid: false, filename: filename, error: "Segment file not found" } unless File.exist?(path)

          actual_hash = Digest::SHA256.file(path).hexdigest
          if actual_hash != seg_meta['segment_hash']
            return { valid: false, filename: filename, error: "Hash mismatch" }
          end

          begin
            blocks = JSON.parse(Zlib::GzipReader.open(path, &:read), symbolize_names: true)
          rescue StandardError => e
            return { valid: false, filename: filename, error: "Decompress failed: #{e.message}" }
          end

          if blocks.size != seg_meta['block_count']
            return { valid: false, filename: filename, error: "Block count mismatch: expected #{seg_meta['block_count']}, got #{blocks.size}" }
          end

          chain_result = verify_block_chain(blocks)
          return { valid: false, filename: filename, error: chain_result[:error] } unless chain_result[:valid]

          { valid: true, filename: filename, block_count: blocks.size }
        end

        def verify_block_chain(blocks)
          blocks.each_with_index do |block, i|
            next if i == 0

            prev = blocks[i - 1]
            if block[:previous_hash] != prev[:hash]
              return { valid: false, error: "Block index #{block[:index]}: previous_hash mismatch" }
            end

            recalc = recalculate_block_hash(block)
            if block[:hash] != recalc
              return { valid: false, error: "Block index #{block[:index]}: hash integrity failure" }
            end
          end
          { valid: true }
        end

        # Recomputes a block hash using the same algorithm as Block#calculate_hash.
        def recalculate_block_hash(block)
          payload = [
            block[:index],
            block[:timestamp],
            block[:previous_hash],
            block[:merkle_root],
            block[:data].to_json
          ].join
          Digest::SHA256.hexdigest(payload)
        end
      end
    end
  end
end
