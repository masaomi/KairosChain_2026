# frozen_string_literal: true

require 'time'
require 'set'

module Synoptis
  class GraphAnalyzer
    attr_reader :config, :registry

    def initialize(registry:, config: nil)
      @registry = registry
      @config = config || Synoptis.default_config
      @cluster_threshold = @config.dig('trust', 'cluster_threshold') || 0.8
      @min_diversity = @config.dig('trust', 'min_diversity') || 0.3
      @velocity_threshold = @config.dig('trust', 'velocity_threshold_24h') || 10
    end

    # Analyze the attestation graph for an agent and return anomaly flags
    # Returns { metrics:, anomaly_flags: [] }
    def analyze(agent_id)
      all_proofs = @registry.list_proofs({})
      flags = []

      cc = cluster_coefficient(agent_id, all_proofs)
      ecr = external_connection_ratio(agent_id, all_proofs)
      va = velocity_anomaly(agent_id, all_proofs)

      flags << {
        type: 'high_cluster_coefficient',
        value: cc,
        threshold: @cluster_threshold,
        message: "Mutual attestation rate (#{cc.round(3)}) exceeds threshold (#{@cluster_threshold})"
      } if cc > @cluster_threshold

      flags << {
        type: 'low_external_connections',
        value: ecr,
        threshold: @min_diversity,
        message: "External connection ratio (#{ecr.round(3)}) below minimum (#{@min_diversity})"
      } if ecr < @min_diversity

      flags << {
        type: 'velocity_anomaly',
        value: va,
        threshold: @velocity_threshold,
        message: "24h attestation count (#{va}) exceeds threshold (#{@velocity_threshold})"
      } if va > @velocity_threshold

      {
        agent_id: agent_id,
        metrics: {
          cluster_coefficient: cc.round(4),
          external_connection_ratio: ecr.round(4),
          velocity_24h: va
        },
        anomaly_flags: flags
      }
    end

    private

    # Cluster coefficient: rate of mutual attestation among agent's attesters
    # High value (>0.8) suggests closed group / possible collusion
    def cluster_coefficient(agent_id, all_proofs)
      # Get agents who attested this agent
      attesters = all_proofs
        .select { |p| p[:attestee_id] == agent_id && p[:status] == 'active' }
        .map { |p| p[:attester_id] }
        .uniq

      return 0.0 if attesters.size < 2

      # Count mutual attestations among attesters
      mutual_pairs = 0
      possible_pairs = 0

      attesters.combination(2).each do |a, b|
        possible_pairs += 1
        # Check if a attested b or b attested a
        a_to_b = all_proofs.any? { |p| p[:attester_id] == a && p[:attestee_id] == b && p[:status] == 'active' }
        b_to_a = all_proofs.any? { |p| p[:attester_id] == b && p[:attestee_id] == a && p[:status] == 'active' }
        mutual_pairs += 1 if a_to_b || b_to_a
      end

      return 0.0 if possible_pairs == 0

      mutual_pairs.to_f / possible_pairs
    end

    # External connection ratio: ratio of attesters outside the mutual attestation cluster
    # Low value (<0.2) suggests isolation / echo chamber
    def external_connection_ratio(agent_id, all_proofs)
      # Build mutual cluster: agents with bidirectional attestation with agent_id
      mutual_cluster = Set.new
      all_proofs.each do |p|
        if p[:attester_id] == agent_id && p[:status] == 'active'
          other = p[:attestee_id]
          # Check if the other agent also attests agent_id (mutual)
          if all_proofs.any? { |q| q[:attester_id] == other && q[:attestee_id] == agent_id && q[:status] == 'active' }
            mutual_cluster << other
          end
        end
      end

      received = all_proofs.select { |p| p[:attestee_id] == agent_id && p[:status] == 'active' }
      return 0.0 if received.empty?

      total_attesters = received.map { |p| p[:attester_id] }.uniq
      return 1.0 if total_attesters.size <= 1  # Single attester = no cluster concern

      external_attesters = total_attesters.reject { |a| mutual_cluster.include?(a) }
      external_attesters.size.to_f / total_attesters.size
    end

    # Number of attestations issued by this agent in the last 24 hours
    def velocity_anomaly(agent_id, all_proofs)
      now = Time.now.utc
      cutoff = now - 86400

      all_proofs.count do |p|
        p[:attester_id] == agent_id &&
          p[:issued_at] &&
          begin
            Time.parse(p[:issued_at].to_s) >= cutoff
          rescue ArgumentError
            false
          end
      end
    end
  end
end
