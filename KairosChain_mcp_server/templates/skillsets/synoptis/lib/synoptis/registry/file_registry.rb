# frozen_string_literal: true

require 'json'
require 'fileutils'

module Synoptis
  module Registry
    class FileRegistry < Base
      PROOFS_FILE = 'attestation_proofs.jsonl'
      REVOCATIONS_FILE = 'attestation_revocations.jsonl'
      CHALLENGES_FILE = 'attestation_challenges.jsonl'

      def initialize(storage_path:)
        @storage_path = storage_path
        @mutex = Mutex.new
        FileUtils.mkdir_p(@storage_path)
      end

      def save_proof(proof_hash)
        @mutex.synchronize do
          append_jsonl(proofs_path, normalize_hash(proof_hash))
        end
      end

      def find_proof(proof_id)
        @mutex.synchronize do
          read_jsonl(proofs_path).find { |p| p[:proof_id] == proof_id }
        end
      end

      def list_proofs(filters = {})
        @mutex.synchronize do
          proofs = read_jsonl(proofs_path)

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
        @mutex.synchronize do
          proofs = read_jsonl(proofs_path)
          updated = proofs.map do |p|
            if p[:proof_id] == proof_id
              p[:status] = status
              p[:revoke_ref] = revoke_ref if revoke_ref
            end
            p
          end
          write_jsonl(proofs_path, updated)
        end
      end

      def save_revocation(revocation_hash)
        @mutex.synchronize do
          append_jsonl(revocations_path, normalize_hash(revocation_hash))
        end
      end

      def find_revocation(proof_id)
        @mutex.synchronize do
          read_jsonl(revocations_path).find { |r| r[:proof_id] == proof_id }
        end
      end

      def save_challenge(challenge_hash)
        @mutex.synchronize do
          append_jsonl(challenges_path, normalize_hash(challenge_hash))
        end
      end

      def find_challenge(challenge_id)
        @mutex.synchronize do
          read_jsonl(challenges_path).find { |c| c[:challenge_id] == challenge_id }
        end
      end

      def list_challenges(**filters)
        @mutex.synchronize do
          challenges = read_jsonl(challenges_path)

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
        @mutex.synchronize do
          challenges = read_jsonl(challenges_path)
          updated = challenges.map do |c|
            if c[:challenge_id] == challenge_id
              normalize_hash(updated_hash)
            else
              c
            end
          end
          write_jsonl(challenges_path, updated)
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

      def append_jsonl(path, hash)
        File.open(path, 'a') { |f| f.puts(JSON.generate(hash)) }
      end

      def read_jsonl(path)
        return [] unless File.exist?(path)

        File.readlines(path).filter_map do |line|
          line = line.strip
          next if line.empty?

          JSON.parse(line, symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
      end

      def write_jsonl(path, records)
        File.open(path, 'w') do |f|
          records.each { |r| f.puts(JSON.generate(r)) }
        end
      end

      def normalize_hash(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
