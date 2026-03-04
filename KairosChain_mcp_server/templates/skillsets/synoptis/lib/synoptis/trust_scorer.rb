# frozen_string_literal: true

require 'time'

module Synoptis
  class TrustScorer
    attr_reader :config, :registry

    def initialize(registry:, config: nil)
      @registry = registry
      @config = config || Synoptis.default_config
      @half_life_days = @config.dig('trust', 'score_half_life_days') || 90
      @velocity_threshold = @config.dig('trust', 'velocity_threshold_24h') || 10
      @min_diversity = @config.dig('trust', 'min_diversity') || 0.3
    end

    # Calculate trust score for an agent
    # Returns { score:, breakdown:, anomaly_flags: [] }
    def score(agent_id, window_days: 180)
      now = Time.now.utc
      cutoff = now - (window_days * 86400)

      # Gather all proofs where this agent is the attestee (received attestations)
      all_proofs = @registry.list_proofs(agent_id: agent_id)
      proofs = all_proofs.select do |p|
        p[:attestee_id] == agent_id &&
          p[:issued_at] &&
          parse_time(p[:issued_at]) >= cutoff
      end

      return zero_score if proofs.empty?

      # Pre-fetch all proofs issued by this agent (for penalties)
      issued_proofs = @registry.list_proofs(agent_id: agent_id).select { |p| p[:attester_id] == agent_id }

      quality = quality_score(proofs)
      freshness = freshness_score(proofs, now)
      diversity = diversity_score(proofs)
      revocation = revocation_penalty_from(issued_proofs)
      velocity = velocity_penalty_from(issued_proofs, now)

      score = quality * freshness * diversity * (1.0 - revocation) * (1.0 - velocity)
      score = [[score, 0.0].max, 1.0].min  # clamp 0..1

      {
        score: score.round(4),
        breakdown: {
          quality: quality.round(4),
          freshness: freshness.round(4),
          diversity: diversity.round(4),
          revocation_penalty: revocation.round(4),
          velocity_penalty: velocity.round(4)
        },
        attestation_count: proofs.size,
        anomaly_flags: []
      }
    end

    private

    # Weighted average of claim type weights × evidence completeness
    def quality_score(proofs)
      return 0.0 if proofs.empty?

      total_weight = proofs.sum do |p|
        weight = ClaimTypes.weight_for(p[:claim_type])
        completeness = evidence_completeness(p)
        weight * completeness
      end

      total_weight / proofs.size
    end

    # Time-decayed freshness using exponential decay
    def freshness_score(proofs, now)
      return 0.0 if proofs.empty?

      total_freshness = proofs.sum do |p|
        age_days = (now - parse_time(p[:issued_at])) / 86400.0
        Math.exp(-age_days * Math.log(2) / @half_life_days)
      end

      total_freshness / proofs.size
    end

    # Ratio of unique attesters to total attestations
    def diversity_score(proofs)
      return 0.0 if proofs.empty?

      unique_attesters = proofs.map { |p| p[:attester_id] }.uniq.size
      unique_attesters.to_f / proofs.size
    end

    # Ratio of revoked attestations issued by this agent
    def revocation_penalty_from(issued_proofs)
      return 0.0 if issued_proofs.empty?

      revoked = issued_proofs.count { |p| p[:status] == 'revoked' }
      revoked.to_f / issued_proofs.size
    end

    # Penalty for issuing too many attestations in 24h
    def velocity_penalty_from(issued_proofs, now)
      cutoff_24h = now - 86400
      recent = issued_proofs.select do |p|
        p[:issued_at] && parse_time(p[:issued_at]) >= cutoff_24h
      end

      count = recent.size
      if count > @velocity_threshold
        (count - @velocity_threshold).to_f / count
      else
        0.0
      end
    end

    def evidence_completeness(proof)
      # Based on min_evidence_fields config
      min_fields = @config.dig('attestation', 'min_evidence_fields') || 2
      evidence = proof[:evidence]
      return 1.0 if evidence.is_a?(Hash) && evidence.size >= min_fields
      return 0.5 if evidence  # Some evidence present but may be incomplete

      # No evidence but existence_only disclosure is valid
      proof[:disclosure_level] == 'existence_only' ? 0.7 : 0.3
    end

    def zero_score
      {
        score: 0.0,
        breakdown: {
          quality: 0.0,
          freshness: 0.0,
          diversity: 0.0,
          revocation_penalty: 0.0,
          velocity_penalty: 0.0
        },
        attestation_count: 0,
        anomaly_flags: []
      }
    end

    def parse_time(time_str)
      Time.parse(time_str.to_s)
    rescue ArgumentError
      Time.at(0)
    end
  end
end
