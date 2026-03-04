# frozen_string_literal: true

require 'securerandom'
require 'time'

module Synoptis
  class ChallengeManager
    # Challenge statuses
    STATUSES = %w[open resolved_valid resolved_invalid challenged_unresolved].freeze

    attr_reader :config, :registry

    def initialize(registry:, config: nil)
      @registry = registry
      @config = config || Synoptis.default_config
      @response_window_hours = @config.dig('challenge', 'response_window_hours') || 72
      @max_active_challenges = @config.dig('challenge', 'max_active_challenges') || 5
    end

    # Open a challenge against an attestation proof
    def open_challenge(challenged_proof_id, challenger_id, reason, evidence_hash: nil)
      raise ArgumentError, 'challenged_proof_id is required' if challenged_proof_id.nil? || challenged_proof_id.to_s.empty?
      raise ArgumentError, 'challenger_id is required' if challenger_id.nil? || challenger_id.to_s.empty?
      raise ArgumentError, 'reason is required' if reason.nil? || reason.to_s.empty?

      # Verify the proof exists
      proof = @registry.find_proof(challenged_proof_id)
      raise ArgumentError, "Proof #{challenged_proof_id} not found" unless proof

      # Cannot challenge already-revoked or expired proofs
      status = proof[:status]
      raise ArgumentError, "Cannot challenge a #{status} proof" if status == 'revoked'

      # Prevent duplicate open challenges against the same proof
      if @registry.respond_to?(:list_challenges)
        existing = @registry.list_challenges(challenged_proof_id: challenged_proof_id, status: 'open')
        unless existing.empty?
          raise ArgumentError, "An open challenge already exists for proof #{challenged_proof_id}"
        end

        # Check max active challenges for this challenger
        active = @registry.list_challenges(challenger_id: challenger_id, status: 'open')
        if active.size >= @max_active_challenges
          raise ArgumentError, "Maximum active challenges (#{@max_active_challenges}) reached for #{challenger_id}"
        end
      end

      now = Time.now.utc
      deadline = now + (@response_window_hours * 3600)

      challenge = {
        challenge_id: "chl_#{SecureRandom.uuid}",
        challenged_proof_id: challenged_proof_id,
        challenger_id: challenger_id,
        reason: reason,
        evidence_hash: evidence_hash,
        status: 'open',
        response: nil,
        response_at: nil,
        deadline_at: deadline.iso8601,
        resolved_at: nil,
        created_at: now.iso8601
      }

      # Update proof status to challenged
      @registry.update_proof_status(challenged_proof_id, 'challenged') if proof[:status] == 'active'

      # Save challenge
      @registry.save_challenge(challenge) if @registry.respond_to?(:save_challenge)

      challenge
    end

    # Resolve a challenge
    # decision: 'uphold' (attestation remains valid) or 'invalidate' (attestation revoked)
    def resolve_challenge(challenge_id, decision, response: nil)
      raise ArgumentError, 'challenge_id is required' if challenge_id.nil? || challenge_id.to_s.empty?
      raise ArgumentError, "Invalid decision: #{decision}. Must be 'uphold' or 'invalidate'" unless %w[uphold invalidate].include?(decision)

      challenge = find_challenge(challenge_id)
      raise ArgumentError, "Challenge #{challenge_id} not found" unless challenge
      raise ArgumentError, "Challenge #{challenge_id} is already resolved (#{challenge[:status]})" unless challenge[:status] == 'open'

      now = Time.now.utc

      new_status = decision == 'uphold' ? 'resolved_valid' : 'resolved_invalid'

      updated = challenge.merge(
        status: new_status,
        response: response,
        response_at: now.iso8601,
        resolved_at: now.iso8601
      )

      # Update challenge record
      @registry.update_challenge(challenge_id, updated) if @registry.respond_to?(:update_challenge)

      # Update proof status based on decision
      if decision == 'invalidate'
        # Revoke the challenged proof
        @registry.update_proof_status(challenge[:challenged_proof_id], 'revoked',
          { reason: "Invalidated by challenge #{challenge_id}", revoked_at: now.iso8601 })
      elsif decision == 'uphold'
        # Restore proof to active
        @registry.update_proof_status(challenge[:challenged_proof_id], 'active')
      end

      updated
    end

    # Check for expired challenges and transition them to challenged_unresolved
    def check_expired_challenges
      return [] unless @registry.respond_to?(:list_challenges)

      now = Time.now.utc
      expired = []

      @registry.list_challenges(status: 'open').each do |challenge|
        deadline = Time.parse(challenge[:deadline_at].to_s) rescue nil
        next unless deadline && now > deadline

        updated = challenge.merge(
          status: 'challenged_unresolved',
          resolved_at: now.iso8601
        )

        @registry.update_challenge(challenge[:challenge_id], updated) if @registry.respond_to?(:update_challenge)

        # Proof remains in challenged state (not restored to active)
        expired << updated
      end

      expired
    end

    # Find a challenge by ID
    def find_challenge(challenge_id)
      return nil unless @registry.respond_to?(:find_challenge)

      @registry.find_challenge(challenge_id)
    end

    # List challenges with optional filters
    def list_challenges(filters = {})
      return [] unless @registry.respond_to?(:list_challenges)

      @registry.list_challenges(**filters)
    end
  end
end
