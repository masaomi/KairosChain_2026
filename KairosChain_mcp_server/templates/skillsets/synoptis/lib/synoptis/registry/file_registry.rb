# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

module Synoptis
  module Registry
    # Append-only JSONL storage with hash-chaining (PHIL-C1: constitutive recording).
    # Each entry's _prev_entry_hash links to the hash of the previous entry,
    # forming an immutable chain that makes the recording constitutive, not evidential.
    class FileRegistry
      def initialize(data_dir:)
        @data_dir = data_dir
        FileUtils.mkdir_p(@data_dir)
        @mutex = Mutex.new
      end

      # --- Proofs ---

      def store_proof(envelope)
        record = envelope.to_h.merge(
          _type: 'proof',
          _stored_at: Time.now.utc.iso8601,
          _prev_entry_hash: last_entry_hash(:proofs)
        )
        append_record(:proofs, record)
        envelope.proof_id
      end

      def find_proof(proof_id)
        records = read_records(:proofs)
        record = records.find { |r| r[:proof_id] == proof_id }
        record ? ProofEnvelope.from_h(record) : nil
      end

      def list_proofs(filter: {})
        records = read_records(:proofs)
        apply_filter(records, filter).map { |r| ProofEnvelope.from_h(r) }
      end

      # --- Revocations ---

      def store_revocation(revocation)
        record = revocation.merge(
          _type: 'revocation',
          _stored_at: Time.now.utc.iso8601,
          _prev_entry_hash: last_entry_hash(:revocations)
        )
        append_record(:revocations, record)
      end

      def find_revocation(proof_id)
        records = read_records(:revocations)
        records.find { |r| r[:proof_id] == proof_id }
      end

      def revoked?(proof_id)
        !find_revocation(proof_id).nil?
      end

      # --- Challenges ---

      def store_challenge(challenge)
        record = challenge.merge(
          _type: 'challenge',
          _stored_at: Time.now.utc.iso8601,
          _prev_entry_hash: last_entry_hash(:challenges)
        )
        append_record(:challenges, record)
      end

      def find_challenge(challenge_id)
        records = read_records(:challenges)
        records.reverse.find { |r| r[:challenge_id] == challenge_id }
      end

      def list_challenges(filter: {})
        records = read_records(:challenges)
        apply_filter(records, filter)
      end

      # --- Chain verification (Proposition 5) ---

      def verify_chain(type)
        records = read_records(type)
        return { valid: true, length: 0 } if records.empty?

        prev_hash = nil
        records.each_with_index do |record, idx|
          expected = record[:_prev_entry_hash]
          if expected != prev_hash
            return { valid: false, broken_at: idx, expected: prev_hash, got: expected }
          end
          prev_hash = compute_record_hash(record)
        end
        { valid: true, length: records.size }
      end

      private

      def file_path(type)
        File.join(@data_dir, "#{type}.jsonl")
      end

      # S-C3 fix: Use File.open with flock for atomic appends instead of Tempfile.
      def append_record(type, record)
        @mutex.synchronize do
          path = file_path(type)
          File.open(path, 'a') do |f|
            f.flock(File::LOCK_EX)
            f.puts(JSON.generate(record))
          end
        end
      end

      def read_records(type)
        path = file_path(type)
        return [] unless File.exist?(path)

        File.readlines(path).filter_map do |line|
          line = line.strip
          next if line.empty?
          JSON.parse(line, symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
      end

      def last_entry_hash(type)
        records = read_records(type)
        return nil if records.empty?
        compute_record_hash(records.last)
      end

      def compute_record_hash(record)
        Digest::SHA256.hexdigest(JSON.generate(record, sort_keys: true))
      end

      def apply_filter(records, filter)
        return records if filter.nil? || filter.empty?
        records.select do |r|
          filter.all? { |k, v| r[k.to_sym] == v }
        end
      end
    end
  end
end
