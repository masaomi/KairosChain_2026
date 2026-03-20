# frozen_string_literal: true

require 'set'
require_relative 'trust_identity'

module Synoptis
  class TrustScorer
    DEFAULT_WEIGHTS = {
      quality: 0.25,
      freshness: 0.20,
      diversity: 0.20,
      velocity: 0.10,
      bridge: 0.15,
      revocation_penalty: 0.10
    }.freeze

    # Anti-collusion bootstrap policy.
    # Agents with no external attestation get zero attestation weight —
    # their attestations have no effect on others' scores.
    BOOTSTRAP_POLICY = {
      min_external_attesters: 1,
      floor_with_external: 0.01,
      floor_without_external: 0.0
    }.freeze

    # Attestation source weights for quality dimension.
    # Human outcomes (paper accepted, patent filed) carry maximum weight
    # because they represent real-world validation that is costly to forge.
    # These are configurable defaults; robustness is evaluated via sensitivity analysis.
    ACTOR_ROLE_WEIGHTS = {
      'human'     => 1.0,
      'peer'      => 0.7,
      'automated' => 0.3
    }.freeze
    DEFAULT_ACTOR_WEIGHT = 0.3

    def initialize(registry:, config: {})
      @registry = registry
      weights_config = config[:score_weights] || config['score_weights'] || {}
      @weights = DEFAULT_WEIGHTS.merge(weights_config.transform_keys(&:to_sym))

      ac_config = config[:anti_collusion] || config['anti_collusion'] || {}
      @anti_collusion_enabled = ac_config.fetch('enabled', ac_config.fetch(:enabled, true))
      @pagerank_iterations = ac_config.fetch('pagerank_iterations', ac_config.fetch(:pagerank_iterations, 20))
      @pagerank_damping = ac_config.fetch('pagerank_damping', ac_config.fetch(:pagerank_damping, 0.85))

      @network_scores_cache = nil
      @network_scores_at = nil
      @cache_ttl = ac_config.fetch('cache_ttl', ac_config.fetch(:cache_ttl, 300))
    end

    def calculate(subject_ref)
      normalized_ref = TrustIdentity.normalize(subject_ref)
      proofs = @registry.list_proofs(filter: { subject_ref: subject_ref })
      # Also check canonical form for legacy compat
      if proofs.empty? && normalized_ref != subject_ref
        proofs = @registry.list_proofs(filter: { subject_ref: normalized_ref })
      end

      if proofs.empty?
        return { subject_ref: subject_ref, score: 0.0, details: {}, attestation_count: 0, active_count: 0 }
      end

      active_proofs = proofs.reject { |p| @registry.revoked?(p.proof_id) || p.expired? }

      ns = @anti_collusion_enabled ? network_scores : nil
      q = @anti_collusion_enabled ? quality_score_weighted(active_proofs, ns) : quality_score(active_proofs)
      f = freshness_score(active_proofs)
      d = diversity_score(active_proofs)
      v = velocity_score(proofs)
      b = @anti_collusion_enabled ? bridge_score(subject_ref, active_proofs) : 0.0
      r = revocation_penalty(proofs)

      raw = (q * @weights[:quality]) +
            (f * @weights[:freshness]) +
            (d * @weights[:diversity]) +
            (v * @weights[:velocity]) +
            (b * (@weights[:bridge] || 0.0)) -
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
          bridge: b.round(4),
          revocation_penalty: r.round(4)
        },
        attestation_count: proofs.size,
        active_count: active_proofs.size
      }
    end

    private

    # Quality score weighted by attestation source (actor_role).
    # Each proof's base quality (evidence + merkle + signature) is multiplied
    # by the actor_role weight: human outcomes > peer verification > automated checks.
    def quality_score(proofs)
      return 0.0 if proofs.empty?
      weighted_sum = proofs.sum do |p|
        base = proof_base_quality(p)
        role = p.respond_to?(:actor_role) ? p.actor_role : nil
        role_weight = ACTOR_ROLE_WEIGHTS.fetch(role.to_s, DEFAULT_ACTOR_WEIGHT)
        base * role_weight
      end
      weighted_sum / proofs.size
    end

    def proof_base_quality(proof)
      score = 0.0
      score += 1.0 if proof.evidence && !proof.evidence.to_s.empty?
      score += 1.0 if proof.merkle_root
      score += 1.0 if proof.signature
      score / 3.0
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

    # --- Anti-Collusion (Phase 2A-back) ---

    # PageRank-weighted quality: attestation value depends on attester's network score.
    def quality_score_weighted(proofs, network_scores)
      return 0.0 if proofs.empty?
      weighted_sum = proofs.sum do |p|
        base = proof_base_quality(p)
        role = p.respond_to?(:actor_role) ? p.actor_role : nil
        role_weight = ACTOR_ROLE_WEIGHTS.fetch(role.to_s, DEFAULT_ACTOR_WEIGHT)
        attester_weight = attestation_weight(p.attester_id, network_scores)
        base * role_weight * attester_weight
      end
      weighted_sum / proofs.size
    end

    # Attestation weight based on attester's network score + bootstrap policy.
    # Agents without external attestation get ZERO weight — their attestations
    # have no effect on others' scores, regardless of PageRank teleportation mass.
    def attestation_weight(attester_ref, network_scores)
      return BOOTSTRAP_POLICY[:floor_with_external] unless network_scores
      has_ext = has_external_attestation?(attester_ref, graph: @active_graph_cache)
      return 0.0 unless has_ext  # No external attestation = zero influence, period.

      score = network_scores[TrustIdentity.normalize(attester_ref)] ||
              network_scores[attester_ref] || 0.0
      [score, BOOTSTRAP_POLICY[:floor_with_external]].max
    end

    # Does this attester have attestations from agents outside their own attester set?
    # Uses pre-loaded active proofs graph when available (from network_scores).
    def has_external_attestation?(attester_ref, graph: nil)
      graph ||= build_active_graph
      norm_ref = TrustIdentity.normalize(attester_ref)

      # Who attests FOR this attester (their trust sources)
      own_attesters = graph[:subject_to_attesters][norm_ref] || Set.new
      return false if own_attesters.empty?

      # Check if any of THEIR attesters come from outside this set
      own_attesters.any? do |a|
        a_sources = graph[:subject_to_attesters][a] || Set.new
        (a_sources - own_attesters).any?
      end
    end

    # Bridge score: measures cross-cluster trust.
    # An attester is "external" if they have trust from agents outside
    # the subject's strongly connected component (SCC).
    #
    # In a closed clique (A←B←C←A), all nodes are in the same SCC → bridge = 0.
    # In A←B, A←X, X←Y: B and X are NOT in A's SCC (no path back from B/X to A
    # unless reciprocated). Y is external to the entire graph.
    def bridge_score(subject_ref, proofs, graph: nil)
      subject_attesters = Set.new(proofs.map { |p| TrustIdentity.normalize(p.attester_id) })
      return 0.0 if subject_attesters.empty?

      graph ||= build_active_graph
      norm_subject = TrustIdentity.normalize(subject_ref)

      # Find subject's SCC: all nodes mutually reachable via attestation edges
      scc = find_scc(norm_subject, graph)

      # An attester is "external" if they have trust from OUTSIDE the SCC
      external_count = subject_attesters.count do |attester|
        attester_sources = graph[:subject_to_attesters][attester] || Set.new
        (attester_sources - scc).any?
      end

      external_count.to_f / subject_attesters.size
    end

    # Find the strongly connected component containing start_node.
    # A node X is in the SCC if: start_node can reach X AND X can reach start_node.
    # Uses two BFS passes: forward (follow attestation edges) and reverse.
    def find_scc(start_node, graph)
      forward = bfs_reachable(start_node, graph[:attester_to_subjects])
      reverse = bfs_reachable(start_node, graph[:subject_to_attesters])
      forward & reverse  # intersection = SCC
    end

    # BFS from start_node following edges in the given adjacency map.
    def bfs_reachable(start_node, adjacency)
      visited = Set.new([start_node])
      queue = [start_node]
      while queue.any?
        next_queue = []
        queue.each do |node|
          (adjacency[node] || Set.new).each do |neighbor|
            unless visited.include?(neighbor)
              visited << neighbor
              next_queue << neighbor
            end
          end
        end
        queue = next_queue
      end
      visited
    end

    # Build a graph of active (non-revoked, non-expired) proofs.
    # Pre-computes normalized refs for performance.
    def build_active_graph
      all_proofs = @registry.list_proofs(filter: {})
      active = all_proofs.reject { |p| @registry.revoked?(p.proof_id) || p.expired? }

      subject_to_attesters = {}
      attester_to_subjects = {}
      attester_to_outgoing = Hash.new(0)

      active.each do |p|
        norm_subject = TrustIdentity.normalize(p.subject_ref)
        norm_attester = TrustIdentity.normalize(p.attester_id)

        subject_to_attesters[norm_subject] ||= Set.new
        subject_to_attesters[norm_subject] << norm_attester

        attester_to_subjects[norm_attester] ||= Set.new
        attester_to_subjects[norm_attester] << norm_subject

        attester_to_outgoing[norm_attester] += 1
      end

      all_nodes = Set.new(subject_to_attesters.keys)
      subject_to_attesters.each_value { |attesters| all_nodes.merge(attesters) }

      { subject_to_attesters: subject_to_attesters,
        attester_to_subjects: attester_to_subjects,
        attester_to_outgoing: attester_to_outgoing,
        all_nodes: all_nodes }
    end

    # Iterative PageRank-style network scores.
    # Uses only active (non-revoked, non-expired) proofs.
    # Cached with TTL to avoid recomputation on every request.
    def network_scores
      if @network_scores_cache && @network_scores_at && (Time.now - @network_scores_at) < @cache_ttl
        return @network_scores_cache
      end

      graph = build_active_graph
      all_nodes = graph[:all_nodes]
      n = all_nodes.size
      return {} if n == 0

      scores = all_nodes.each_with_object({}) { |s, h| h[s] = 1.0 / n }

      @pagerank_iterations.times do
        new_scores = {}
        all_nodes.each do |subject|
          attesters = graph[:subject_to_attesters][subject] || Set.new

          incoming = attesters.sum do |a|
            outgoing = [graph[:attester_to_outgoing][a] || 1, 1].max
            (scores[a] || 0.0) / outgoing.to_f
          end

          new_scores[subject] = (1 - @pagerank_damping) / n + @pagerank_damping * incoming
        end
        scores = new_scores
      end

      @network_scores_cache = scores
      @network_scores_at = Time.now
      @active_graph_cache = graph
      scores
    end
  end
end
