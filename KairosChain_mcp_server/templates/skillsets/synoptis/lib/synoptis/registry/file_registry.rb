# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tempfile'

module Synoptis
  module Registry
    class FileRegistry < Base
      PROOFS_FILE = 'attestation_proofs.jsonl'
      REVOCATIONS_FILE = 'attestation_revocations.jsonl'
      CHALLENGES_FILE = 'attestation_challenges.jsonl'

      def initialize(storage_path:)
        @storage_path = storage_path
        FileUtils.mkdir_p(@storage_path)
      end

      def save_proof(proof_hash)
        append_jsonl(proofs_path, normalize_hash(proof_hash))
      end

      def find_proof(proof_id)
        with_file_lock(proofs_path, shared: true) do
          read_jsonl_unlocked(proofs_path).find { |p| p[:proof_id] == proof_id }
        end
      end

      def list_proofs(filters = {})
        with_file_lock(proofs_path, shared: true) do
          proofs = read_jsonl_unlocked(proofs_path)

          if filters[:agent_id]
            proofs = proofs.select { |p| p[:attester_id] == filters[:agent_id] || p[:attestee_id] == filters[:agent_id] }
          end

          if filters[:claim_type]
            proofs = proofs.select { |p| p[:claim_type] == filters[:claim_type] }
          end

          if filters[:status]
            proofs = proofs.select { |p| p[:status] == filters[:status] }
          end

          proofs
        end
      end

      def update_proof_status(proof_id, status, revoke_ref = nil)
        with_file_lock(proofs_path) do
          proofs = read_jsonl_unlocked(proofs_path)
          updated = proofs.map do |p|
            if p[:proof_id] == proof_id
              p[:status] = status
              p[:revoke_ref] = revoke_ref if revoke_ref
            end
            p
          end
          write_jsonl_atomic(proofs_path, updated)
        end
      end

      def save_revocation(revocation_hash)
        append_jsonl(revocations_path, normalize_hash(revocation_hash))
      end

      def find_revocation(proof_id)
        with_file_lock(revocations_path, shared: true) do
          read_jsonl_unlocked(revocations_path).find { |r| r[:proof_id] == proof_id }
        end
      end

      def save_challenge(challenge_hash)
        append_jsonl(challenges_path, normalize_hash(challenge_hash))
      end

      def find_challenge(challenge_id)
        with_file_lock(challenges_path, shared: true) do
          read_jsonl_unlocked(challenges_path).find { |c| c[:challenge_id] == challenge_id }
        end
      end

      def list_challenges(**filters)
        with_file_lock(challenges_path, shared: true) do
          challenges = read_jsonl_unlocked(challenges_path)

          if filters[:challenger_id]
            challenges = challenges.select { |c| c[:challenger_id] == filters[:challenger_id] }
          end

          if filters[:challenged_proof_id]
            challenges = challenges.select { |c| c[:challenged_proof_id] == filters[:challenged_proof_id] }
          end

          if filters[:status]
            challenges = challenges.select { |c| c[:status] == filters[:status] }
          end

          challenges
        end
      end

      def update_challenge(challenge_id, updated_hash)
        with_file_lock(challenges_path) do
          challenges = read_jsonl_unlocked(challenges_path)
          updated = challenges.map do |c|
            if c[:challenge_id] == challenge_id
              normalize_hash(updated_hash)
            else
              c
            end
          end
          write_jsonl_atomic(challenges_path, updated)
        end
      end

      private

      def proofs_path
        File.join(@storage_path, PROOFS_FILE)
      end

      def revocations_path
        File.join(@storage_path, REVOCATIONS_FILE)
      end

      def challenges_path
        File.join(@storage_path, CHALLENGES_FILE)
      end

      # File-level lock helper (replaces in-process Mutex)
      def with_file_lock(path, shared: false)
        lock_path = "#{path}.lock"
        FileUtils.touch(lock_path) unless File.exist?(lock_path)
        mode = shared ? File::LOCK_SH : File::LOCK_EX
        File.open(lock_path, 'r') do |lock_file|
          lock_file.flock(mode)
          yield
        end
      end

      def append_jsonl(path, hash)
        with_file_lock(path) do
          File.open(path, 'a') { |f| f.puts(JSON.generate(hash)) }
        end
      end

      # Read without acquiring lock (caller must hold lock)
      def read_jsonl_unlocked(path)
        return [] unless File.exist?(path)

        File.readlines(path).filter_map do |line|
          line = line.strip
          next if line.empty?

          JSON.parse(line, symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
      end

      # Atomic write: write to temp file then rename
      def write_jsonl_atomic(path, records)
        dir = File.dirname(path)
        tmp = Tempfile.new(File.basename(path), dir)
        begin
          records.each { |r| tmp.puts(JSON.generate(r)) }
          tmp.close
          File.rename(tmp.path, path)
        rescue StandardError
          tmp.close
          tmp.unlink rescue nil
          raise
        end
      end

      def normalize_hash(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
