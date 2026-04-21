# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'fileutils'
require 'time'
require 'digest'

module KairosMcp
  class Daemon
    # ApprovalGate — pending-file based approval system for code-gen proposals.
    #
    # Design (P3.2 v0.2 §4):
    #   Proposals are staged as JSON files in .kairos/run/proposals/.
    #   Human approval/rejection is recorded as a separate .decision.json file.
    #   proposal_hash binds reviewed content to applied content cryptographically.
    class ApprovalGate
      DEFAULT_TTL   = 28_800  # 8 hours (daemon mode)
      MAX_PENDING   = 16

      def initialize(dir:, clock: -> { Time.now.utc }, logger: nil)
        @dir    = dir
        @clock  = clock
        @logger = logger
        FileUtils.mkdir_p(@dir, mode: 0o700)
      end

      # Stage a pending-approval proposal. Returns the stored Hash.
      def stage(proposal)
        id = proposal[:proposal_id] || proposal['proposal_id']
        raise ArgumentError, 'proposal_id required' if id.to_s.empty?
        check_backpressure!

        now = @clock.call
        ttl = proposal[:ttl_seconds] || proposal['ttl_seconds'] || DEFAULT_TTL

        # Compute proposal_hash from canonical content (excludes mutable fields)
        canonical = proposal.reject { |k, _| mutable_key?(k) }
        p_hash = canonical_hash(canonical)

        p = proposal.merge(
          status:        'pending_approval',
          proposal_hash: p_hash,
          created_at:    now.iso8601,
          expires_at:    (now + ttl).iso8601
        )
        write_atomic(file_for(id), JSON.pretty_generate(stringify_keys(p)))
        p
      end

      # Auto-approve (fast path for L2 scopes).
      def auto_approve(proposal)
        id = proposal[:proposal_id] || proposal['proposal_id']
        raise ArgumentError, 'proposal_id required' if id.to_s.empty?

        now = @clock.call
        ttl = proposal[:ttl_seconds] || proposal['ttl_seconds'] || DEFAULT_TTL

        canonical = proposal.reject { |k, _| mutable_key?(k) }
        p_hash = canonical_hash(canonical)

        p = proposal.merge(
          status:        'auto_approved',
          proposal_hash: p_hash,
          created_at:    now.iso8601,
          expires_at:    (now + ttl).iso8601
        )
        write_atomic(file_for(id), JSON.pretty_generate(stringify_keys(p)))
        write_decision(id,
                       decision: 'approve',
                       reviewer: 'policy:auto_approve',
                       proposal_hash: p_hash,
                       granted_at: now.iso8601,
                       reason: "scope=#{proposal.dig(:scope, :scope) || proposal.dig('scope', 'scope')} auto-approved")
        p
      end

      # Non-blocking status check.
      # @return [Symbol] :pending | :approved | :rejected | :expired | :not_found
      def status_of(proposal_id)
        p = read_proposal(proposal_id)
        return :not_found unless p
        return :expired if Time.parse(p['expires_at']) < @clock.call
        d = read_decision(proposal_id)
        return :pending unless d
        d['decision'] == 'approve' ? :approved : :rejected
      end

      # Record a human decision (via AttachServer mailbox).
      def record_decision(proposal_id, decision:, reviewer:, reason: nil)
        raise ArgumentError, 'decision must be approve|reject' unless %w[approve reject].include?(decision)
        p = read_proposal(proposal_id)
        raise NotFoundError, "proposal not found: #{proposal_id}" unless p
        raise ConflictError, "already decided: #{proposal_id}" if File.exist?(decision_file(proposal_id))
        raise ExpiredError, "expired: #{proposal_id}" if Time.parse(p['expires_at']) < @clock.call

        write_decision(proposal_id,
                       decision: decision,
                       reviewer: reviewer,
                       proposal_hash: p['proposal_hash'],
                       granted_at: @clock.call.iso8601,
                       reason: reason)
      end

      # For cycle re-entry: returns ApprovalGrant or nil. Never blocks.
      def consume_grant(proposal_id)
        case status_of(proposal_id)
        when :approved
          ApprovalGrant.new(
            proposal_id: proposal_id,
            decision:    read_decision(proposal_id),
            proposal:    read_proposal(proposal_id)
          )
        else
          nil
        end
      end

      # Verify proposal content integrity at apply time.
      # @return [Boolean]
      def verify_proposal_integrity(proposal_id)
        p = read_proposal(proposal_id)
        return false unless p
        d = read_decision(proposal_id)
        return false unless d

        canonical = p.reject { |k, _| mutable_key?(k) }
        recomputed = canonical_hash(canonical)
        recomputed == p['proposal_hash'] && d['proposal_hash'] == p['proposal_hash']
      end

      # List pending proposals.
      def pending_proposals
        Dir.glob(File.join(@dir, '*.json')).filter_map do |f|
          next if f.end_with?('.decision.json') || f.end_with?('.applied.json')
          p = safe_read_json(f)
          next unless p
          next if p['status'] == 'auto_approved' && File.exist?(decision_file(p['proposal_id']))
          s = status_of(p['proposal_id'])
          s == :pending ? p : nil
        end
      end

      # Read a proposal record.
      def read_proposal(proposal_id)
        safe_read_json(file_for(proposal_id))
      end

      # Read a decision record.
      def read_decision(proposal_id)
        safe_read_json(decision_file(proposal_id))
      end

      ApprovalGrant = Struct.new(:proposal_id, :decision, :proposal, keyword_init: true)
      class NotFoundError < StandardError; end
      class ConflictError < StandardError; end
      class ExpiredError  < StandardError; end
      class BackpressureError < StandardError; end

      private

      def file_for(id)      ; File.join(@dir, "#{id}.json") end
      def decision_file(id) ; File.join(@dir, "#{id}.decision.json") end

      MUTABLE_KEYS = %w[status proposal_hash created_at expires_at ttl_seconds].freeze

      def mutable_key?(k)
        MUTABLE_KEYS.include?(k.to_s)
      end

      # Sorted-key canonical JSON for deterministic hashing (R2 residual fix).
      def canonical_hash(obj)
        "sha256:#{Digest::SHA256.hexdigest(canonical_json(obj))}"
      end

      def canonical_json(obj)
        case obj
        when Hash
          '{' + obj.keys.map(&:to_s).sort.map { |k|
            # Look up by both string and symbol to handle mixed-key hashes
            val = obj.key?(k) ? obj[k] : obj[k.to_sym]
            k.to_json + ':' + canonical_json(val)
          }.join(',') + '}'
        when Array
          '[' + obj.map { |v| canonical_json(v) }.join(',') + ']'
        when Symbol
          obj.to_s.to_json
        else
          obj.to_json
        end
      end

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end

      def write_decision(proposal_id, **fields)
        write_atomic(decision_file(proposal_id), JSON.pretty_generate(fields))
      end

      def write_atomic(path, data)
        tmp = "#{path}.tmp.#{SecureRandom.hex(4)}"
        File.open(tmp, 'wb', 0o600) do |f|
          f.write(data)
          f.flush
          f.fsync rescue nil
        end
        File.rename(tmp, path)
      ensure
        File.unlink(tmp) if tmp && File.exist?(tmp)
      end

      def safe_read_json(path)
        return nil unless File.file?(path)
        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end

      def check_backpressure!
        count = Dir.glob(File.join(@dir, '*.json')).count do |f|
          !f.end_with?('.decision.json') && !f.end_with?('.applied.json')
        end
        raise BackpressureError, "max pending proposals (#{MAX_PENDING}) exceeded" if count >= MAX_PENDING
      end
    end
  end
end
