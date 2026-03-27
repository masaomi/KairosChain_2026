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

    # Does this attester have attestations from agents outside their SCC?
    # Uses SCC-consistent definition (same as bridge_score) to prevent
    # closed cliques from having positive attestation weight.
    def has_external_attestation?(attester_ref, graph: nil)
      graph ||= build_active_graph
      norm_ref = TrustIdentity.normalize(attester_ref)

      # Who attests FOR this attester
      own_attesters = graph[:subject_to_attesters][norm_ref] || Set.new
      return false if own_attesters.empty?

      # Find attester's SCC — all nodes mutually reachable
      scc = find_scc(norm_ref, graph)

      # External = has attesters from OUTSIDE the SCC
      own_attesters.any? { |a| !scc.include?(a) }
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

    # =================================================================
    # Meeting Place Trust (v2) — Client-side computation from raw facts
    # =================================================================

    public

    MEETING_SKILL_WEIGHTS = {
      attestation_quality: 0.50,
      usage: 0.20,
      freshness: 0.15,
      provenance: 0.15
    }.freeze

    MEETING_DEPOSITOR_WEIGHTS = {
      avg_skill_trust: 0.40,
      attestation_breadth: 0.25,
      diversity: 0.25,
      activity: 0.10
    }.freeze

    CLAIM_WEIGHTS = {
      'multi_llm_reviewed' => 0.90,
      'used_in_production' => 0.85,
      'quality_reviewed' => 0.75,
      'integrity_verified' => 0.60
    }.freeze
    DEFAULT_CLAIM_WEIGHT = 0.50

    MEETING_CONFIG_DEFAULTS = {
      self_attestation_weight: 0.15,
      scc_discount: 0.20,
      max_expected_attestations: 5,
      remote_signal_discount: 0.50,
      depositor_shrinkage_threshold: 3,
      combined_min_skill_weight: 0.35,
      combined_max_skill_weight: 0.70
    }.freeze

    # Compute trust score for a skill on a connected Meeting Place.
    # Input: skill_data hash from MeetingTrustAdapter (browse/preview response).
    # Returns: { score:, details:, attestation_summary:, anti_collusion: }
    def calculate_meeting_skill(skill_data, adapter: nil)
      return empty_meeting_result('no_data') unless skill_data

      attestations = skill_data[:attestations] || []
      owner_id = skill_data[:owner_agent_id] || skill_data[:agent_id] || skill_data[:depositor_id]
      config = meeting_config

      # Attestation quality with anti-collusion
      aq = meeting_attestation_quality(attestations, owner_id, config)

      # Usage signal (discounted as unverifiable remote data)
      raw_usage = [
        (skill_data.dig(:trust_metadata, :exchange_count) || 0).to_f / 10.0,
        1.0
      ].min
      usage = raw_usage * config[:remote_signal_discount]

      # Freshness (180-day decay, floor at 0.2)
      first_dep = skill_data.dig(:trust_metadata, :first_deposited)
      freshness = if first_dep
                    begin
                      age_days = (Time.now.utc - Time.parse(first_dep.to_s)) / 86400.0
                      [1.0 - (age_days / 180.0), 0.2].max
                    rescue ArgumentError
                      0.5
                    end
                  else
                    0.5
                  end

      # Provenance (direct is best)
      hop_count = skill_data.dig(:trust_metadata, :provenance, :hop_count) || 0
      provenance = [1.0 - (hop_count * 0.2), 0.4].max

      # Depositor signature gate
      depositor_signed = skill_data.dig(:trust_notice, :depositor_signed) ? 1.0 : 0.5

      w = skill_weights
      raw = (aq[:score] * w[:attestation_quality] +
             usage * w[:usage] +
             freshness * w[:freshness] +
             provenance * w[:provenance]) * depositor_signed

      score = raw.clamp(0.0, 1.0)

      {
        score: score.round(4),
        details: {
          attestation_quality: aq[:score].round(4),
          usage: usage.round(4),
          freshness: freshness.round(4),
          provenance: provenance.round(4),
          depositor_signed: depositor_signed == 1.0
        },
        anti_collusion: aq[:anti_collusion],
        attestation_summary: aq[:summary]
      }
    end

    # Compute trust score for a depositor (agent) based on their portfolio.
    # Input: agent_id + array of all browse skill data.
    def calculate_depositor(agent_id, all_skills_data, adapter: nil)
      depositor_skills = all_skills_data.select do |s|
        (s[:owner_agent_id] || s[:agent_id] || s[:depositor_id]) == agent_id
      end
      return empty_depositor_result(agent_id) if depositor_skills.empty?

      config = meeting_config

      # Per-skill trust scores
      skill_trusts = depositor_skills.map { |s| calculate_meeting_skill(s)[:score] }
      avg_skill_trust = skill_trusts.sum / skill_trusts.size

      # Shrinkage for small portfolios
      n = depositor_skills.size
      threshold = config[:depositor_shrinkage_threshold]
      shrinkage = [n.to_f / threshold, 1.0].min
      neutral_prior = 0.3
      avg_shrunk = avg_skill_trust * shrinkage + neutral_prior * (1.0 - shrinkage)

      # Third-party attestation breadth
      third_party_count = depositor_skills.sum do |s|
        (s[:attestations] || []).count { |a| a[:attester_id] != agent_id }
      end
      attestation_breadth = [third_party_count / 8.0, 1.0].min

      # Attester diversity across portfolio
      unique_attesters = depositor_skills.flat_map do |s|
        (s[:attestations] || [])
          .select { |a| a[:attester_id] != agent_id }
          .map { |a| a[:attester_id] }
      end.uniq.size
      diversity = [unique_attesters / 4.0, 1.0].min

      # Activity
      activity = [n / 8.0, 1.0].min

      w = depositor_weights
      raw = (avg_shrunk * w[:avg_skill_trust] +
             attestation_breadth * w[:attestation_breadth] +
             diversity * w[:diversity] +
             activity * w[:activity])

      score = raw.clamp(0.0, 1.0)

      result = {
        score: score.round(4),
        agent_id: agent_id,
        details: {
          avg_skill_trust: avg_skill_trust.round(4),
          shrinkage_applied: n < threshold,
          attestation_breadth: attestation_breadth.round(4),
          diversity: diversity.round(4),
          activity: activity.round(4)
        },
        portfolio_size: n
      }
      # Warn if browse limit may have truncated the portfolio
      total_available = all_skills_data.size
      if total_available >= 50
        result[:portfolio_truncated] = true
        result[:truncation_warning] = 'Browse limit reached (50). Depositor may have more skills not included in this score.'
      end
      result
    end

    # Combined score: smooth interpolation between skill and depositor trust.
    # At skill_trust=0: 35% skill, 65% depositor (lean on reputation)
    # At skill_trust=1: 70% skill, 30% depositor (stand on own evidence)
    def calculate_combined(skill_trust, depositor_trust)
      alpha = skill_trust.clamp(0.0, 1.0)
      min_w = meeting_config[:combined_min_skill_weight]
      max_w = meeting_config[:combined_max_skill_weight]
      skill_weight = min_w + alpha * (max_w - min_w)
      depositor_weight = 1.0 - skill_weight

      combined = skill_trust * skill_weight + depositor_trust * depositor_weight
      combined.clamp(0.0, 1.0).round(4)
    end

    # Recommendation based on combined score.
    def recommendation(combined_score)
      thresholds = meeting_config[:recommendation_thresholds] || {}
      if combined_score >= (thresholds[:high_confidence] || 0.70)
        { level: 'high_confidence', reason: 'Multiple independent trust signals verified.' }
      elsif combined_score >= (thresholds[:moderate_confidence] || 0.40)
        { level: 'moderate_confidence', reason: 'Some trust evidence present.' }
      elsif combined_score >= (thresholds[:low_confidence] || 0.20)
        { level: 'low_confidence', reason: 'Minimal evidence, proceed with caution.' }
      else
        { level: 'insufficient_evidence', reason: 'No meaningful trust signals found.' }
      end
    end

    private

    def meeting_attestation_quality(attestations, owner_id, config)
      bootstrapped_count = 0
      clique_discounted = 0
      sig_present = 0

      if attestations.empty?
        return {
          score: 0.0,
          anti_collusion: { bootstrapped_attesters: 0, clique_discounted: 0,
                            signatures_present: 0, note: 'no attestations' },
          summary: { total: 0, third_party: 0, self: 0, unique_attesters: 0 }
        }
      end

      # Build a simple attestation graph from browse data for SCC detection
      attester_ids = attestations.map { |a| a[:attester_id] }.compact.uniq
      # For meeting-level SCC: check if any pair of attesters attest each other's skills
      # This is a simplified version — full graph requires attestation_graph API (v2.1)

      total = 0.0
      attestations.each do |a|
        attester = a[:attester_id]
        next unless attester

        # Self-attestation discount
        is_self = (attester == owner_id)
        source_mult = is_self ? config[:self_attestation_weight] : 1.0

        # Bootstrap check: does this attester have any external attestation?
        # In browse context, we approximate: an attester that only attests their own
        # skills has no external validation. This is conservative.
        has_external = !is_self # Third-party attesters are inherently "external" to this skill
        bootstrap_mult = has_external ? 1.0 : 0.1
        bootstrapped_count += 1 if has_external

        # Clique detection (simplified for browse data):
        # If attester == owner (self), it's already discounted.
        # Full mutual-attestation detection requires cross-skill data (v2.1).
        clique_mult = 1.0

        # Claim weight (loaded from YAML, merged with defaults)
        cw = claim_weights
        claim_weight = cw.fetch(a[:claim].to_s, cw.fetch('default', DEFAULT_CLAIM_WEIGHT))

        # Signature presence (browse only exposes boolean; actual verification requires preview)
        # We count "present" not "verified" — honest about what we can confirm from browse data
        if a[:has_signature]
          sig_mult = 0.8 # present but not cryptographically verified from browse
          sig_present += 1
        else
          sig_mult = 0.6
        end

        total += source_mult * bootstrap_mult * clique_mult * claim_weight * sig_mult
      end

      max_expected = config[:max_expected_attestations]
      score = [total / max_expected.to_f, 1.0].min

      third_party = attestations.count { |a| a[:attester_id] != owner_id }

      {
        score: score,
        anti_collusion: {
          bootstrapped_attesters: bootstrapped_count,
          clique_discounted: clique_discounted,
          signatures_present: sig_present,
          note: 'browse-level: signature presence checked, not cryptographically verified'
        },
        summary: {
          total: attestations.size,
          third_party: third_party,
          self: attestations.size - third_party,
          unique_attesters: attester_ids.size
        }
      }
    end

    def meeting_config
      @config_cache = nil if @config_cache_stale # allow invalidation
      @config_cache ||= begin
        raw = synoptis_v2_config
        ac = raw['anti_collusion'] || {}
        comb = raw['combined'] || {}
        {
          self_attestation_weight: ac.fetch('self_attestation_weight',
            MEETING_CONFIG_DEFAULTS[:self_attestation_weight]),
          scc_discount: ac.fetch('scc_discount',
            MEETING_CONFIG_DEFAULTS[:scc_discount]),
          max_expected_attestations: ac.fetch('max_expected_attestations',
            MEETING_CONFIG_DEFAULTS[:max_expected_attestations]),
          remote_signal_discount: raw.fetch('remote_signal_discount',
            MEETING_CONFIG_DEFAULTS[:remote_signal_discount]),
          depositor_shrinkage_threshold: raw.fetch('depositor_shrinkage_threshold',
            MEETING_CONFIG_DEFAULTS[:depositor_shrinkage_threshold]),
          combined_min_skill_weight: comb.fetch('combined_min_skill_weight',
            MEETING_CONFIG_DEFAULTS[:combined_min_skill_weight]),
          combined_max_skill_weight: comb.fetch('combined_max_skill_weight',
            MEETING_CONFIG_DEFAULTS[:combined_max_skill_weight]),
          recommendation_thresholds: {
            high_confidence: raw.dig('recommendation_thresholds', 'high_confidence') || 0.70,
            moderate_confidence: raw.dig('recommendation_thresholds', 'moderate_confidence') || 0.40,
            low_confidence: raw.dig('recommendation_thresholds', 'low_confidence') || 0.20
          }
        }
      end
    end

    def synoptis_v2_config
      config_path = File.join(KairosMcp.skillsets_dir, 'synoptis', 'config', 'synoptis.yml')
      return {} unless File.exist?(config_path)

      full = YAML.safe_load(File.read(config_path)) || {}
      full['trust_v2'] || {}
    rescue StandardError
      {}
    end

    # Load skill weights from YAML, merge with defaults
    def skill_weights
      raw = synoptis_v2_config['skill_weights'] || {}
      MEETING_SKILL_WEIGHTS.merge(
        raw.transform_keys(&:to_sym).slice(*MEETING_SKILL_WEIGHTS.keys)
          .transform_values(&:to_f)
      )
    end

    # Load depositor weights from YAML, merge with defaults
    def depositor_weights
      raw = synoptis_v2_config['depositor_weights'] || {}
      MEETING_DEPOSITOR_WEIGHTS.merge(
        raw.transform_keys(&:to_sym).slice(*MEETING_DEPOSITOR_WEIGHTS.keys)
          .transform_values(&:to_f)
      )
    end

    # Load claim weights from YAML, merge with defaults
    def claim_weights
      raw = synoptis_v2_config['claim_weights'] || {}
      defaults = CLAIM_WEIGHTS.merge('default' => DEFAULT_CLAIM_WEIGHT)
      defaults.merge(raw.transform_values(&:to_f))
    end

    def empty_meeting_result(reason)
      {
        score: 0.0,
        details: { reason: reason },
        anti_collusion: { bootstrapped_attesters: 0, clique_discounted: 0,
                          signatures_present: 0, note: 'no attestations' },
        attestation_summary: { total: 0, third_party: 0, self: 0, unique_attesters: 0 }
      }
    end

    def empty_depositor_result(agent_id)
      {
        score: 0.0,
        agent_id: agent_id,
        details: { reason: 'no_deposits' },
        portfolio_size: 0
      }
    end
  end
end
