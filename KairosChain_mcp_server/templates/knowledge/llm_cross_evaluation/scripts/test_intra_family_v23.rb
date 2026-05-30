# frozen_string_literal: true
#
# Unit tests for llm_cross_evaluation v2.3 invariant-enforcement core.
# Pure logic, no CLI. Run: ruby scripts/test_intra_family_v23.rb

require "minitest/autorun"
require_relative "lib/intra_family_v23"

# Named lineup: three Anthropic (4.8/4.7/4.6), one OpenAI, one opaque (Cursor).
LINEAGE = {
  "claude_opus48" => :anthropic,
  "claude_opus47" => :anthropic,
  "claude_opus46" => :anthropic,
  "codex_gpt55"   => :openai,
  "cursor"        => nil # opaque => :unknown
}.freeze

class TestFamilyResolver < Minitest::Test
  def setup
    @r = V23::FamilyResolver.new(LINEAGE)
  end

  def test_family_of_known_and_unknown
    assert_equal :anthropic, @r.family_of("claude_opus48")
    assert_equal :openai, @r.family_of("codex_gpt55")
    assert_equal :unknown, @r.family_of("cursor")
    assert_equal :unknown, @r.family_of("never_seen")
  end

  def test_unknown_family_predicate
    assert @r.unknown_family?("cursor")
    refute @r.unknown_family?("claude_opus47")
  end

  def test_near_kin_same_known_family
    assert @r.near_kin?("claude_opus48", "claude_opus47")
    refute @r.near_kin?("claude_opus48", "codex_gpt55")
  end

  def test_unknown_is_never_near_kin
    refute @r.near_kin?("cursor", "cursor")
    refute @r.near_kin?("cursor", "claude_opus48")
  end

  def test_conflicted_by_identity_and_family
    assert @r.conflicted?("claude_opus48", %w[claude_opus48 codex_gpt55])
    assert @r.conflicted?("claude_opus46", %w[claude_opus48 codex_gpt55])
    refute @r.conflicted?("codex_gpt55", %w[claude_opus48 claude_opus47])
    refute @r.conflicted?("cursor", %w[claude_opus48 claude_opus47])
  end

  def test_conflicted_malformed_pair_is_conservative
    assert @r.conflicted?("codex_gpt55", nil)
  end

  def test_families_groups_only_known_size2plus
    fams = @r.families(LINEAGE.keys)
    assert_equal %i[anthropic], fams.keys
    assert_equal 3, fams[:anthropic].length
    refute fams.key?(:openai)
    refute fams.key?(:unknown)
  end
end

class TestNoiseFloor < Minitest::Test
  def test_explicit_floor
    nf = V23::NoiseFloor.new(floor: 0.5)
    assert nf.established?
    assert nf.claimable?(0.6)
    refute nf.claimable?(0.5)   # strictly greater
    refute nf.claimable?(-0.4)
    assert nf.claimable?(-0.7)  # magnitude
  end

  def test_delta_equal_to_floor_not_claimable
    nf = V23::NoiseFloor.new(floor: 1.0)
    refute nf.claimable?(1.0)
    refute nf.claimable?(-1.0)
    assert nf.claimable?(1.0001)
  end

  def test_negative_floor_rejected
    assert_raises(V23::Error) { V23::NoiseFloor.new(floor: -0.1) }
  end

  def test_infinite_floor_rejected
    assert_raises(V23::Error) { V23::NoiseFloor.new(floor: Float::INFINITY) }
  end

  def test_non_positive_k_rejected
    assert_raises(V23::Error) { V23::NoiseFloor.new(samples: [1.0, 2.0], k: 0) }
    assert_raises(V23::Error) { V23::NoiseFloor.new(samples: [1.0, 2.0], k: -1) }
  end

  def test_non_numeric_samples_rejected
    assert_raises(V23::Error) { V23::NoiseFloor.new(samples: [1.0, nil]) }
    assert_raises(V23::Error) { V23::NoiseFloor.new(samples: [1.0, "x"]) }
  end

  def test_floor_and_samples_both_rejected
    assert_raises(V23::Error) { V23::NoiseFloor.new(floor: 0.5, samples: [1.0, 2.0]) }
  end

  def test_samples_with_variance
    nf = V23::NoiseFloor.new(samples: [4.0, 6.0], k: 1.0)
    assert nf.established?
    assert nf.floor > 0
  end

  def test_zero_variance_samples_not_established
    nf = V23::NoiseFloor.new(samples: [5.0, 5.0, 5.0], k: 2.0)
    refute nf.established?           # cannot bound noise from identical samples
    refute nf.claimable?(100.0)
  end

  def test_no_floor_means_nothing_claimable
    nf = V23::NoiseFloor.new
    refute nf.established?
    refute nf.claimable?(1000.0)
  end

  def test_nil_nan_inf_delta_safe
    nf = V23::NoiseFloor.new(floor: 0.5)
    refute nf.claimable?(nil)
    refute nf.claimable?(Float::NAN)
    refute nf.claimable?(Float::INFINITY)
    refute nf.claimable?(-Float::INFINITY)
    refute nf.claimable?("0.9")
  end
end

class TestResolutionScreen < Minitest::Test
  def test_all_correct_passes
    s = V23::ResolutionScreen.new
    ctrl = [{ expected: :a, judged: :a }, { expected: :b, judged: :b }]
    assert s.passes?(ctrl)
  end

  def test_any_wrong_fails_default
    s = V23::ResolutionScreen.new
    ctrl = [{ expected: :a, judged: :a }, { expected: :b, judged: :a }]
    refute s.passes?(ctrl)
  end

  def test_threshold_fraction
    s = V23::ResolutionScreen.new(required_fraction: 0.5)
    ctrl = [{ expected: :a, judged: :a }, { expected: :b, judged: :a }]
    assert s.passes?(ctrl)
  end

  def test_empty_does_not_pass
    refute V23::ResolutionScreen.new.passes?([])
    refute V23::ResolutionScreen.new.passes?(nil)
  end

  def test_required_fraction_out_of_range_rejected
    assert_raises(V23::Error) { V23::ResolutionScreen.new(required_fraction: 1.5) }
    assert_raises(V23::Error) { V23::ResolutionScreen.new(required_fraction: -0.1) }
  end

  def test_malformed_control_not_counted_correct
    s = V23::ResolutionScreen.new
    # missing keys => nil == nil must NOT count as correct
    refute s.passes?([{}])
    refute s.passes?([{ expected: :a }]) # judged missing
    # one good, one malformed => 1/2, fails default 1.0
    refute s.passes?([{ expected: :a, judged: :a }, {}])
  end
end

class TestAdmissibilityGate < Minitest::Test
  def setup
    @r = V23::FamilyResolver.new(LINEAGE)
    @floor = V23::NoiseFloor.new(floor: 0.5)
    @gate = V23::AdmissibilityGate.new(noise_floor: @floor, resolver: @r)
  end

  def claim(**over)
    base = {
      pair: %w[claude_opus48 claude_opus47], axis: "logic:accuracy",
      delta: 1.0, judge: "codex_gpt55",
      blinded: true, screen_passed: true, corroborating_judges: []
    }
    V23::DifferenceClaim.new(**base.merge(over))
  end

  def test_admissible_clean_out_of_family_judge
    res = @gate.evaluate(claim)
    assert res[:admissible]
    assert_nil res[:reason]
  end

  def test_below_noise_floor
    assert_equal :below_noise_floor, @gate.evaluate(claim(delta: 0.4))[:reason]
  end

  def test_not_blinded
    assert_equal :not_blinded, @gate.evaluate(claim(blinded: false))[:reason]
  end

  def test_resolution_unverified
    assert_equal :resolution_unverified, @gate.evaluate(claim(screen_passed: false))[:reason]
  end

  def test_conflicted_uncorroborated_rejected
    res = @gate.evaluate(claim(judge: "claude_opus46", corroborating_judges: []))
    assert_equal :conflicted_uncorroborated, res[:reason]
  end

  def test_conflicted_with_unconflicted_screened_corroborator_admissible
    res = @gate.evaluate(claim(
      judge: "claude_opus46",
      corroborating_judges: [{ judge: "codex_gpt55", screen_passed: true }]
    ))
    assert res[:admissible]
  end

  def test_corroboration_from_conflicted_judge_rejected
    # corroborator is itself Anthropic => still conflicted on an Anthropic pair
    res = @gate.evaluate(claim(
      judge: "claude_opus46",
      corroborating_judges: [{ judge: "claude_opus47", screen_passed: true }]
    ))
    assert_equal :conflicted_uncorroborated, res[:reason]
  end

  def test_corroboration_unscreened_rejected
    res = @gate.evaluate(claim(
      judge: "claude_opus46",
      corroborating_judges: [{ judge: "codex_gpt55", screen_passed: false }]
    ))
    assert_equal :conflicted_uncorroborated, res[:reason]
  end

  def test_malformed_claim_nil_delta
    assert_equal :malformed_claim, @gate.evaluate(claim(delta: nil))[:reason]
  end

  def test_malformed_claim_bad_pair
    assert_equal :malformed_claim, @gate.evaluate(claim(pair: nil))[:reason]
    assert_equal :malformed_claim, @gate.evaluate(claim(pair: %w[only_one]))[:reason]
    assert_equal :malformed_claim, @gate.evaluate(claim(pair: %w[same same]))[:reason]
  end

  def test_non_claim_object_is_malformed_not_crash
    assert_equal :malformed_claim, @gate.evaluate(nil)[:reason]
    assert_equal :malformed_claim, @gate.evaluate({ pair: %w[a b] })[:reason]
  end

  def test_noise_floor_unestablished_distinct_reason
    gate = V23::AdmissibilityGate.new(noise_floor: V23::NoiseFloor.new, resolver: @r)
    assert_equal :noise_floor_unestablished, gate.evaluate(claim)[:reason]
  end

  def test_nil_judge_axis_pair_endpoint_are_malformed
    assert_equal :malformed_claim, @gate.evaluate(claim(judge: nil))[:reason]
    assert_equal :malformed_claim, @gate.evaluate(claim(axis: nil))[:reason]
    assert_equal :malformed_claim, @gate.evaluate(claim(pair: [nil, "claude_opus47"]))[:reason]
  end

  def test_non_boolean_blinded_screen_rejected
    assert_equal :not_blinded, @gate.evaluate(claim(blinded: "yes"))[:reason]
    assert_equal :resolution_unverified, @gate.evaluate(claim(screen_passed: 1))[:reason]
  end

  def test_corroborator_must_differ_from_primary
    # primary conflicted; "corroborator" is the primary itself => not valid corroboration
    res = @gate.evaluate(claim(
      judge: "claude_opus46",
      corroborating_judges: [{ judge: "claude_opus46", screen_passed: true }]
    ))
    assert_equal :conflicted_uncorroborated, res[:reason]
  end
end

class TestConsistencyChecker < Minitest::Test
  def test_acyclic_is_consistent
    c = V23::ConsistencyChecker.new([%w[a b], %w[b c], %w[a c]])
    assert c.consistent?
    assert_empty c.cyclic_nodes
  end

  def test_three_cycle_detected
    c = V23::ConsistencyChecker.new([%w[a b], %w[b c], %w[c a]])
    refute c.consistent?
    assert_equal %w[a b c].sort, c.cyclic_nodes.sort
  end

  def test_partial_cycle_isolated
    c = V23::ConsistencyChecker.new([%w[a b], %w[b c], %w[c a], %w[d e]])
    refute c.consistent?
    assert_equal %w[a b c].sort, c.cyclic_nodes.sort
  end
end

class TestIndependenceWeighting < Minitest::Test
  def setup
    @r = V23::FamilyResolver.new(LINEAGE)
    @w = V23::IndependenceWeighting.new(@r)
  end

  def test_same_family_trio_counts_as_one
    assert_equal 1.0, @w.agreement_weight(%w[claude_opus48 claude_opus47 claude_opus46])
  end

  def test_two_distinct_families_count_two
    assert_equal 2.0, @w.agreement_weight(%w[claude_opus48 codex_gpt55])
  end

  def test_full_lineup_is_two_unknown_zero
    assert_equal 2.0, @w.agreement_weight(LINEAGE.keys)
  end

  def test_unknown_only_is_zero
    assert_equal 0.0, @w.agreement_weight(%w[cursor])
  end

  # ── independent_mean (INV-3/6/9 consensus removal) ──
  def test_independent_mean_collapses_same_family_redundancy
    # three Anthropic agreeing on 9.0 must NOT outweigh one OpenAI at 3.0:
    # family means {anthropic: 9.0, openai: 3.0} => 6.0, not the instance mean 7.5.
    vals = { "claude_opus48" => 9.0, "claude_opus47" => 9.0, "claude_opus46" => 9.0, "codex_gpt55" => 3.0 }
    assert_in_delta 6.0, @w.independent_mean(vals), 1e-9
  end

  def test_independent_mean_unknown_each_counts_independently
    # two opaque evaluators are NOT collapsed (opaque ≠ redundant): each its own vote.
    vals = { "cursor" => 8.0, "cursor2" => 4.0 }
    assert_in_delta 6.0, @w.independent_mean(vals), 1e-9
  end

  def test_independent_mean_drops_nonfinite_and_empty_is_nil
    assert_nil @w.independent_mean({})
    assert_nil @w.independent_mean(nil)
    assert_nil @w.independent_mean({ "claude_opus48" => Float::NAN })
    assert_in_delta 9.0, @w.independent_mean({ "claude_opus48" => 9.0, "claude_opus47" => Float::INFINITY }), 1e-9
  end
end

class TestSampleStddev < Minitest::Test
  def test_zero_for_fewer_than_two
    assert_equal 0.0, V23.sample_stddev([])
    assert_equal 0.0, V23.sample_stddev([5.0])
  end

  def test_zero_variance
    assert_equal 0.0, V23.sample_stddev([2.0, 2.0, 2.0])
  end

  def test_known_sample_sd
    # sample sd of [1, -1] = sqrt(((1-0)^2 + (-1-0)^2)/(2-1)) = sqrt(2)
    assert_in_delta Math.sqrt(2), V23.sample_stddev([1.0, -1.0]), 1e-9
  end
end

class TestStanding < Minitest::Test
  def test_clean_standing_is_rankable
    s = V23::Standing.new({ "a" => 9.0, "b" => 7.0 }, saturated_components: [])
    assert_equal :ranking_ok, s.label
    assert_equal %w[a b], s.as_ranking!
  end

  def test_tie_break_is_deterministic
    s = V23::Standing.new({ "b" => 9.0, "a" => 9.0, "c" => 1.0 }, saturated_components: [])
    assert_equal %w[a b c], s.as_ranking! # equal 9.0 => key ascending a before b
  end

  def test_saturated_standing_refuses_ranking
    s = V23::Standing.new({ "a" => 9.0, "b" => 9.0 }, saturated_components: ["logic:accuracy"])
    assert_equal :not_a_ranking, s.label
    err = assert_raises(V23::Error) { s.as_ranking! }
    assert_match(/INV-3/, err.message)
  end

  # ── from_scores: auto-detected saturation (2b-1) ──
  def test_from_scores_separated_scores_rankable
    s = V23::Standing.from_scores({ "a" => 9.0, "b" => 7.0, "c" => 5.0 }, epsilon: 0.0)
    assert_empty s.saturated_components
    assert_equal %w[a b c], s.as_ranking!
  end

  def test_from_scores_exact_tie_saturates
    s = V23::Standing.from_scores({ "a" => 9.0, "b" => 9.0, "c" => 5.0 }, epsilon: 0.0)
    assert_equal [%w[a b]], s.saturated_components
    assert_raises(V23::Error) { s.as_ranking! }
  end

  def test_from_scores_epsilon_chains_near_ties
    # gaps 0.05 and 0.05 both ≤ 0.1 => a,b,c chain into one saturated component
    s = V23::Standing.from_scores({ "a" => 9.0, "b" => 8.95, "c" => 8.90, "d" => 1.0 }, epsilon: 0.1)
    assert_equal [%w[a b c]], s.saturated_components
  end

  def test_from_scores_singletons_not_saturated
    s = V23::Standing.from_scores({ "a" => 9.0, "b" => 1.0 }, epsilon: 0.1)
    assert_empty s.saturated_components
  end

  def test_saturated_clusters_rejects_bad_epsilon
    assert_raises(V23::Error) { V23::Standing.saturated_clusters({ "a" => 1.0 }, -1) }
  end
end

class TestLimitsReport < Minitest::Test
  def test_empty_report_is_valid_and_empty
    r = V23::LimitsReport.new
    assert r.empty?
    assert_equal [], r.to_h[:saturated_components]
  end

  def test_collects_and_dedups_all_categories
    r = V23::LimitsReport.new
    r.add_saturated_component("logic:accuracy")
     .add_saturated_component("logic:accuracy")
     .add_unresolved(pair: %w[claude_opus48 claude_opus47], axis: "philosophy:depth", reason: :no_resolved_judge)
     .add_unresolved(pair: %w[claude_opus48 claude_opus47], axis: "philosophy:depth", reason: :no_resolved_judge)
     .note_unknown_family_judge("cursor")
     .note_unknown_family_judge("cursor")
    refute r.empty?
    h = r.to_h
    assert_equal ["logic:accuracy"], h[:saturated_components]
    assert_equal 1, h[:unresolved_claims].length    # deduped
    assert_equal ["cursor"], h[:unknown_family_judges]
  end
end

class TestDifferenceEvaluator < Minitest::Test
  def setup
    @r = V23::FamilyResolver.new(LINEAGE)
    @gate = V23::AdmissibilityGate.new(noise_floor: V23::NoiseFloor.new(floor: 0.5), resolver: @r)
    @eval = V23::DifferenceEvaluator.new(gate: @gate, resolver: @r)
  end

  def mk(pair, delta, judge: "codex_gpt55", **over)
    base = { pair: pair, axis: "logic:accuracy", delta: delta, judge: judge,
             blinded: true, screen_passed: true, corroborating_judges: [] }
    V23::DifferenceClaim.new(**base.merge(over))
  end

  def test_clean_claims_all_confirmed
    claims = [mk(%w[claude_opus48 claude_opus47], 1.0), mk(%w[claude_opus47 claude_opus46], 0.9)]
    out = @eval.run(claims)
    assert_equal 2, out[:confirmed].length
    assert out[:limits].empty?
  end

  def test_inadmissible_goes_to_limits
    claims = [mk(%w[claude_opus48 claude_opus47], 0.1)] # below floor
    out = @eval.run(claims)
    assert_empty out[:confirmed]
    assert_equal :below_noise_floor, out[:limits].to_h[:unresolved_claims].first[:reason]
  end

  def test_cycle_marked_indeterminate
    # a>b (delta+), b>c (+), c>a (+) => cycle; all out-of-family judge, above floor
    claims = [
      mk(%w[claude_opus48 claude_opus47], 1.0),
      mk(%w[claude_opus47 claude_opus46], 1.0),
      mk(%w[claude_opus46 claude_opus48], 1.0)
    ]
    out = @eval.run(claims)
    assert_empty out[:confirmed]
    reasons = out[:limits].to_h[:unresolved_claims].map { |u| u[:reason] }
    assert_includes reasons, :intransitive
  end

  def test_unknown_family_judge_noted
    claims = [mk(%w[claude_opus48 claude_opus47], 1.0, judge: "cursor")]
    out = @eval.run(claims)
    assert_includes out[:limits].to_h[:unknown_family_judges], "cursor"
  end

  def test_cross_axis_opposite_prefs_not_a_cycle
    # a≻b on accuracy, b≻a on clarity: different axes, NOT intransitive
    claims = [
      mk(%w[claude_opus48 claude_opus47], 1.0, axis: "logic:accuracy"),
      mk(%w[claude_opus48 claude_opus47], -1.0, axis: "logic:clarity")
    ]
    out = @eval.run(claims)
    assert_equal 2, out[:confirmed].length
    assert_empty out[:indeterminate]
  end

  def test_cross_component_edge_not_dropped
    # cycle {a,b,c} on accuracy, plus a clean d≻e on the same axis: d,e survive
    claims = [
      mk(%w[claude_opus48 claude_opus47], 1.0),
      mk(%w[claude_opus47 claude_opus46], 1.0),
      mk(%w[claude_opus46 claude_opus48], 1.0),
      mk(%w[codex_gpt55 cursor], 1.0, judge: "claude_opus48") # judge not in this pair
    ]
    out = @eval.run(claims)
    confirmed_pairs = out[:confirmed].map(&:pair)
    assert_includes confirmed_pairs, %w[codex_gpt55 cursor] # not in the cycle
    assert_equal 3, out[:indeterminate].length
  end

  def test_malformed_claim_does_not_crash_evaluator
    out = @eval.run([nil, mk(%w[claude_opus48 claude_opus47], 1.0)])
    assert_equal 1, out[:confirmed].length
    reasons = out[:limits].to_h[:unresolved_claims].map { |u| u[:reason] }
    assert_includes reasons, :malformed_claim
  end

  def test_run_nil_or_non_array_is_safe
    out = @eval.run(nil)
    assert_empty out[:confirmed]
    assert out[:limits].empty?
  end
end
