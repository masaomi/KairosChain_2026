# frozen_string_literal: true

require 'securerandom'

module Synoptis
  class ChallengeManager
    def initialize(registry:, config: {})
      @registry = registry
      @config = config
      @response_timeout = (config[:response_timeout] || config['response_timeout'] || 3600).to_i
      @max_active = (config[:max_active_per_subject] || config['max_active_per_subject'] || 5).to_i
    end

    def create_challenge(proof_id:, challenger_id:, challenge_type:, details: nil,
                         actor_user_id: nil, actor_role: nil)
      envelope = @registry.find_proof(proof_id)
      return { status: 'error', message: 'Proof not found' } unless envelope

      pending_count = count_pending_challenges(proof_id)
      if pending_count >= @max_active
        return { status: 'error', message: "Too many active challenges (max: #{@max_active})" }
      end

      challenge = {
        challenge_id: SecureRandom.uuid,
        proof_id: proof_id,
        challenger_id: challenger_id.to_s,
        challenge_type: challenge_type,
        details: details,
        status: 'pending',
        actor_user_id: actor_user_id,
        actor_role: actor_role,
        expires_at: (Time.now.utc + @response_timeout).iso8601,
        timestamp: Time.now.utc.iso8601
      }

      @registry.store_challenge(challenge)
      { status: 'created', challenge: challenge }
    end

    def respond_to_challenge(challenge_id:, responder_id:, response:, evidence: nil,
                             actor_user_id: nil, actor_role: nil)
      current_status = current_challenge_status(challenge_id)
      return { status: 'error', message: 'Challenge not found' } unless current_status

      if current_status != 'pending'
        return { status: 'error', message: "Challenge is #{current_status}, not pending" }
      end

      challenge = @registry.find_challenge(challenge_id)

      envelope = @registry.find_proof(challenge[:proof_id])
      unless responder_id.to_s == envelope&.attester_id.to_s
        return { status: 'error', message: 'Only the original attester can respond to challenges' }
      end

      response_record = {
        challenge_id: challenge_id,
        proof_id: challenge[:proof_id],
        responder_id: responder_id.to_s,
        response: response,
        evidence: evidence,
        status: 'responded',
        actor_user_id: actor_user_id,
        actor_role: actor_role,
        timestamp: Time.now.utc.iso8601
      }

      @registry.store_challenge(response_record)
      { status: 'responded', challenge_id: challenge_id, response: response_record }
    end

    private

    # In append-only storage, a challenge_id may have multiple records.
    # The latest record's status is the current status.
    def current_challenge_status(challenge_id)
      all = @registry.list_challenges(filter: { challenge_id: challenge_id })
      return nil if all.empty?
      all.last[:status]
    end

    # Count challenges for a proof whose current status is still 'pending'.
    def count_pending_challenges(proof_id)
      all = @registry.list_challenges(filter: { proof_id: proof_id })
      grouped = all.group_by { |c| c[:challenge_id] }
      grouped.count { |_id, records| records.last[:status] == 'pending' }
    end
  end
end
