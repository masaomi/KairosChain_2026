# frozen_string_literal: true

require 'digest'
require 'json'
require_relative '../kairos_chain/chain'

module KairosMcp
  module DriftDetection
    # CorrespondenceChecker — INV-A detection floor (Cycle 1, toward by-construction).
    #
    # Checks whether a live L0/L1 artifact still corresponds to its *current
    # recorded provenance*: the content digest stored for that artifact at the
    # head of the constitutive record (the hash chain). This is detection only —
    # it surfaces divergence; it does not prevent edits or gate writes. Those are
    # later cycles (single-source enforcement, record-as-gate).
    #
    # Provenance is rooted in the hash chain, not in the SQLite knowledge_meta
    # cache: INV-A names the chain head as the non-editable anchor. The chain is
    # therefore the single source consulted here; the meta table (when present)
    # is a derived view and is intentionally not used for the comparison.
    #
    # The digest is computed over the *raw file content* (frontmatter included),
    # matching exactly how it was recorded on create/update (a verbatim write,
    # no normalization). Comparing the parsed/stripped body would never match.
    class CorrespondenceChecker
      # Result of a single correspondence check.
      #
      # status:
      #   :match            live artifact corresponds to recorded provenance
      #   :mismatch         live content diverged from recorded provenance (silent edit)
      #   :missing_record   live artifact relied upon, but no recorded provenance exists
      #   :missing_artifact recorded/expected artifact is absent at the reliance point
      #   :error            the check itself could not complete (not a correspondence claim)
      Result = Struct.new(
        :status, :name, :active_digest, :recorded_digest, :message,
        keyword_init: true
      ) do
        def corresponds?
          status == :match
        end

        # A surfaced non-correspondence per INV-A (divergence, not an internal error).
        def divergence?
          %i[mismatch missing_record missing_artifact].include?(status)
        end
      end

      class << self
        # Check an L1 knowledge artifact against its recorded provenance.
        #
        # @param name [String] knowledge id (knowledge_id on the chain record)
        # @param md_file_path [String, nil] path to the live .md file relied upon
        # @param storage_backend [Storage::Backend, nil] backend for chain access
        # @return [Result]
        def check_l1(name:, md_file_path:, storage_backend: nil)
          unless md_file_path && File.file?(md_file_path)
            # Relied upon but absent — a missing artifact is itself a
            # non-correspondence under INV-A (the expected set is recorded).
            return Result.new(
              status: :missing_artifact, name: name,
              active_digest: nil, recorded_digest: nil,
              message: "L1 '#{name}': artifact missing at the point of reliance"
            )
          end

          active = Digest::SHA256.hexdigest(File.read(md_file_path))
          recorded = recorded_digest_for(name, storage_backend)

          if recorded.nil?
            return Result.new(
              status: :missing_record, name: name,
              active_digest: active, recorded_digest: nil,
              message: "L1 '#{name}': live artifact has no recorded provenance on the chain"
            )
          end

          if active == recorded
            Result.new(
              status: :match, name: name,
              active_digest: active, recorded_digest: recorded, message: nil
            )
          else
            Result.new(
              status: :mismatch, name: name,
              active_digest: active, recorded_digest: recorded,
              message: "L1 '#{name}': live content diverged from recorded provenance " \
                       "(active #{short(active)} ≠ recorded #{short(recorded)})"
            )
          end
        rescue StandardError => e
          Result.new(
            status: :error, name: name,
            active_digest: nil, recorded_digest: nil,
            message: "L1 '#{name}': correspondence check could not complete: #{e.message}"
          )
        end

        private

        # The current recorded content digest for a knowledge_id: the next_hash of
        # the most recent knowledge_update record, scanning the chain from head
        # backward. Returns nil when the most recent relevant record removed the
        # artifact (next_hash nil — delete/archive) or when none exists.
        def recorded_digest_for(name, storage_backend)
          chain = KairosChain::Chain.new(storage_backend: storage_backend)
          chain.chain.reverse_each do |block|
            Array(block.data).each do |entry|
              record = parse_entry(entry)
              next unless record.is_a?(Hash)
              next unless record['type'] == 'knowledge_update'
              next unless record['knowledge_id'] == name

              # First match from the head is the current provenance (may be nil
              # if the artifact was removed — caller treats nil as no record).
              return record['next_hash']
            end
          end
          nil
        end

        def parse_entry(entry)
          return entry if entry.is_a?(Hash)
          return JSON.parse(entry) if entry.is_a?(String)

          nil
        rescue JSON::ParserError
          nil
        end

        def short(digest)
          digest ? digest[0, 12] : '-'
        end
      end
    end
  end
end
