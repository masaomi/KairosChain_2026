# frozen_string_literal: true

module Synoptis
  class TrustScorer
    DEFAULT_WEIGHTS = {
      quality: 0.3,
      freshness: 0.25,
      diversity: 0.25,
      velocity: 0.1,
      revocation_penalty: 0.1
    }.freeze

    def initialize(registry:, config: {})
      @registry = registry
      weights_config = config[:score_weights] || config['score_weights'] || {}
      @weights = DEFAULT_WEIGHTS.merge(weights_config.transform_keys(&:to_sym))
    end

    def calculate(subject_ref)
      proofs = @registry.list_proofs(filter: { subject_ref: subject_ref })
      if proofs.empty?
        return { subject_ref: subject_ref, score: 0.0, details: {}, attestation_count: 0, active_count: 0 }
      end

      active_proofs = proofs.reject { |p| @registry.revoked?(p.proof_id) || p.expired? }

      q = quality_score(active_proofs)
      f = freshness_score(active_proofs)
      d = diversity_score(active_proofs)
      v = velocity_score(proofs)
      r = revocation_penalty(proofs)

      raw = (q * @weights[:quality]) +
            (f * @weights[:freshness]) +
            (d * @weights[:diversity]) +
            (v * @weights[:velocity]) -
            (r * @weights[:revocation_penalty])

      score = [[raw, 0.0].max, 1.0].min

      {
        subject_ref: subject_ref,
        score: score.round(4),
        details: {
          quality: q.round(4),
          freshness: f.round(4),
          diversity: d.round(4),
          velocity: v.round(4),
          revocation_penalty: r.round(4)
        },
        attestation_count: proofs.size,
        active_count: active_proofs.size
      }
    end

    private

    def quality_score(proofs)
      return 0.0 if proofs.empty?
      with_evidence = proofs.count { |p| p.evidence && !p.evidence.to_s.empty? }
      with_merkle = proofs.count { |p| p.merkle_root }
      with_sig = proofs.count { |p| p.signature }
      (with_evidence + with_merkle + with_sig).to_f / (proofs.size * 3)
    end

    def freshness_score(proofs)
      return 0.0 if proofs.empty?
      now = Time.now.utc
      ages = proofs.map do |p|
        age_hours = (now - Time.parse(p.timestamp)) / 3600.0
        [1.0 - (age_hours / 720.0), 0.0].max
      rescue ArgumentError
        0.0
      end
      ages.sum / ages.size
    end

    def diversity_score(proofs)
      return 0.0 if proofs.empty?
      unique_attesters = proofs.map(&:attester_id).uniq.size
      [unique_attesters.to_f / [proofs.size, 10].min, 1.0].min
    end

    def velocity_score(proofs)
      return 0.0 if proofs.size < 2
      timestamps = proofs.filter_map { |p| Time.parse(p.timestamp) rescue nil }.sort
      return 0.0 if timestamps.size < 2
      span_days = (timestamps.last - timestamps.first) / 86400.0
      return 1.0 if span_days < 1
      rate = proofs.size / span_days
      [rate / 5.0, 1.0].min
    end

    def revocation_penalty(proofs)
      return 0.0 if proofs.empty?
      revoked = proofs.count { |p| @registry.revoked?(p.proof_id) }
      revoked.to_f / proofs.size
    end
  end
end
