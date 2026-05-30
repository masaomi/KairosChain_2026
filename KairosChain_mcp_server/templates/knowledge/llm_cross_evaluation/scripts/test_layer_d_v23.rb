# frozen_string_literal: true
#
# Unit tests for the PURE logic of LayerDDifference (v2.3 increment 2).
# CLI paths (screen_judge / compare_pair / evaluate) are not exercised here;
# the deterministic core they delegate to is covered by test_intra_family_v23.rb.
# Run: ruby scripts/test_layer_d_v23.rb

require "minitest/autorun"
require_relative "run_cross_eval"

class TestLayerDFamily < Minitest::Test
  def test_family_for_provider_mapping
    assert_equal :anthropic, LayerDDifference.family_for("claude_opus48")
    assert_equal :anthropic, LayerDDifference.family_for("claude_opus47")
    assert_equal :openai, LayerDDifference.family_for("codex_gpt54")
    assert_equal :google, LayerDDifference.family_for("gemini_cli_31pro")
  end

  def test_cursor_is_unknown_opaque_backing
    assert_equal :unknown, LayerDDifference.family_for("cursor_composer2")
  end

  def test_unknown_for_absent_model
    assert_equal :unknown, LayerDDifference.family_for("nope")
  end

  def test_lineage_map
    m = LayerDDifference.lineage_map(%w[claude_opus48 codex_gpt54 cursor_composer2])
    assert_equal({ "claude_opus48" => :anthropic, "codex_gpt54" => :openai, "cursor_composer2" => :unknown }, m)
  end
end

class TestVerdictToClaims < Minitest::Test
  def setup
    @pair = %w[claude_opus48 claude_opus47]
    # Blind order: A shows opus47, B shows opus48
    @order = %w[claude_opus47 claude_opus48]
  end

  def verdict(per_axis, leakage: "none")
    { "per_axis" => per_axis, "identity_leakage_noticed" => leakage }
  end

  def test_choice_maps_through_order_and_pair_sign
    claims = LayerDDifference.verdict_to_claims(
      verdict: verdict([
        { "axis" => "accuracy", "choice" => "A" }, # A=opus47 => pair[1] => delta -1
        { "axis" => "reasoning", "choice" => "tie" }, # skipped
        { "axis" => "clarity", "choice" => "B" }  # B=opus48 => pair[0] => delta +1
      ]),
      pair: @pair, judge: "codex_gpt54", order: @order, screen_passed: true
    )
    assert_equal 2, claims.length
    acc = claims.find { |c| c.axis == "accuracy" }
    clr = claims.find { |c| c.axis == "clarity" }
    assert_equal(-1.0, acc.delta)
    assert_equal(1.0, clr.delta)
    assert claims.all?(&:blinded)
    assert claims.all?(&:screen_passed)
  end

  def test_tie_and_malformed_yield_no_claim
    claims = LayerDDifference.verdict_to_claims(
      verdict: verdict([{ "axis" => "accuracy", "choice" => "tie" }, { "nope" => 1 }]),
      pair: @pair, judge: "codex_gpt54", order: @order, screen_passed: true
    )
    assert_empty claims
  end

  def test_identity_leakage_marks_not_blinded
    claims = LayerDDifference.verdict_to_claims(
      verdict: verdict([{ "axis" => "accuracy", "choice" => "A" }], leakage: "Response B sounded like Claude"),
      pair: @pair, judge: "codex_gpt54", order: @order, screen_passed: true
    )
    refute claims.first.blinded
  end

  def test_non_hash_verdict_is_empty
    assert_empty LayerDDifference.verdict_to_claims(verdict: nil, pair: @pair, judge: "x", order: @order, screen_passed: true)
  end
end

class TestAggregate < Minitest::Test
  def resolver(keys)
    V23::FamilyResolver.new(LayerDDifference.lineage_map(keys))
  end

  def raw(pair:, axis:, delta:, judge:)
    V23::DifferenceClaim.new(pair: pair, axis: axis, delta: delta, judge: judge,
                             blinded: true, screen_passed: true, corroborating_judges: [])
  end

  def test_single_family_judge_net_one
    r = resolver(%w[claude_opus48 claude_opus47 codex_gpt54 cursor_composer2])
    pair = %w[claude_opus48 claude_opus47]
    agg = LayerDDifference.aggregate([raw(pair: pair, axis: "accuracy", delta: 1.0, judge: "codex_gpt54")], r)
    assert_equal 1, agg.length
    assert_equal 1.0, agg.first.delta
    assert_equal "panel", agg.first.judge
  end

  def test_two_distinct_families_disagree_net_zero
    r = resolver(%w[claude_opus48 claude_opus47 codex_gpt54 gemini_cli_31pro])
    pair = %w[claude_opus48 claude_opus47]
    agg = LayerDDifference.aggregate([
      raw(pair: pair, axis: "accuracy", delta: 1.0, judge: "codex_gpt54"),     # openai prefers pair[0]
      raw(pair: pair, axis: "accuracy", delta: -1.0, judge: "gemini_cli_31pro") # google prefers pair[1]
    ], r)
    assert_equal 0.0, agg.first.delta # disagreement across independent families => net 0 => unresolved at floor 0
  end

  def test_same_family_redundant_agreement_does_not_multiply
    # two openai judges agreeing still count as 1 independent family (INV-6)
    r = resolver(%w[claude_opus48 claude_opus47 codex_gpt54 codex_gpt55])
    pair = %w[claude_opus48 claude_opus47]
    agg = LayerDDifference.aggregate([
      raw(pair: pair, axis: "accuracy", delta: 1.0, judge: "codex_gpt54"),
      raw(pair: pair, axis: "accuracy", delta: 1.0, judge: "codex_gpt55")
    ], r)
    assert_equal 1.0, agg.first.delta # not 2.0
  end

  def test_screen_and_blinded_propagate_as_all
    r = resolver(%w[claude_opus48 claude_opus47 codex_gpt54])
    pair = %w[claude_opus48 claude_opus47]
    c1 = raw(pair: pair, axis: "accuracy", delta: 1.0, judge: "codex_gpt54")
    c2 = V23::DifferenceClaim.new(pair: pair, axis: "accuracy", delta: 1.0, judge: "codex_gpt54",
                                  blinded: false, screen_passed: true, corroborating_judges: [])
    agg = LayerDDifference.aggregate([c1, c2], r)
    refute agg.first.blinded # all? => false because c2 not blinded
  end

  def test_self_contradicting_judge_counts_for_neither
    r = resolver(%w[claude_opus48 claude_opus47 codex_gpt54])
    pair = %w[claude_opus48 claude_opus47]
    agg = LayerDDifference.aggregate([
      raw(pair: pair, axis: "accuracy", delta: 1.0, judge: "codex_gpt54"),
      raw(pair: pair, axis: "accuracy", delta: -1.0, judge: "codex_gpt54")
    ], r)
    assert_equal 0.0, agg.first.delta # judge nets to 0 => neither pro0 nor pro1
  end

  def test_off_spec_axis_rejected
    claims = LayerDDifference.verdict_to_claims(
      verdict: { "per_axis" => [{ "axis" => "speed", "choice" => "A" }], "identity_leakage_noticed" => "none" },
      pair: %w[claude_opus48 claude_opus47], judge: "codex_gpt54",
      order: %w[claude_opus48 claude_opus47], screen_passed: true
    )
    assert_empty claims # "speed" not in AXES
  end
end

# ── 2b-3: INV-1 repeat-trial noise floor ──────────────────────────────────
class TestRepeatTrialClaims < Minitest::Test
  def claim(pair, axis, delta, blinded: true, screen: true)
    V23::DifferenceClaim.new(pair: pair, axis: axis, delta: delta, judge: "panel",
                             blinded: blinded, screen_passed: screen, corroborating_judges: [])
  end

  def test_stable_panel_zero_floor
    pair = %w[a b]
    reps = LayerDDifference.repeat_trial_claims(
      [[claim(pair, "accuracy", 1.0)], [claim(pair, "accuracy", 1.0)], [claim(pair, "accuracy", 1.0)]]
    )
    assert_equal 1, reps.length
    assert_in_delta 1.0, reps.first[:claim].delta, 1e-9
    assert_in_delta 0.0, reps.first[:floor], 1e-9 # zero trial-to-trial wobble
  end

  def test_flipping_panel_floor_swamps_signal
    pair = %w[a b]
    reps = LayerDDifference.repeat_trial_claims(
      [[claim(pair, "accuracy", 1.0)], [claim(pair, "accuracy", -1.0)], [claim(pair, "accuracy", 1.0)]]
    )
    rep = reps.first
    assert_operator rep[:floor], :>, rep[:claim].delta.abs # noise > signal => not claimable
  end

  def test_absent_trial_counts_as_zero
    pair = %w[a b]
    # decisive in 1 of 3 trials => deltas [1,0,0] => mean 1/3, positive floor
    rep = LayerDDifference.repeat_trial_claims([[claim(pair, "accuracy", 1.0)], [], []]).first
    assert_in_delta(1.0 / 3, rep[:claim].delta, 1e-9)
    assert_operator rep[:floor], :>, 0.0
  end

  def test_single_trial_floor_nil
    rep = LayerDDifference.repeat_trial_claims([[claim(%w[a b], "accuracy", 2.0)]]).first
    assert_nil rep[:floor] # < 2 trials => caller falls back to static floor
    assert_in_delta 2.0, rep[:claim].delta, 1e-9
  end

  def test_blinded_and_screen_collapse_with_all
    pair = %w[a b]
    reps = LayerDDifference.repeat_trial_claims(
      [[claim(pair, "accuracy", 1.0)], [claim(pair, "accuracy", 1.0, blinded: false)]]
    )
    refute reps.first[:claim].blinded
  end
end

class TestLayerDMultiTrial < Minitest::Test
  TASK = { "id" => "t", "prompt" => "Solve the problem thoroughly." }.freeze

  def responses
    {
      "claude_opus48" => "Opus 4.8 answer: a detailed, correct derivation with steps." * 2,
      "claude_opus47" => "Opus 4.7 answer: a solid derivation with most steps shown." * 2,
      "claude_opus46" => "Opus 4.6 answer: a reasonable derivation, fewer steps." * 2,
      "codex_gpt54" => "Codex answer (judge).",
      "cursor_composer2" => "Cursor answer (opaque)."
    }
  end

  # Prefers the LONGER response for both screen and comparison => a stable model
  # preference (longer = opus48 > opus47 > opus46) independent of blind position,
  # so the difference has zero trial-to-trial noise and must survive K trials.
  def stable_pref_runner
    StubRunner.new do |_mk, prompt, _label|
      a = prompt[/## Response A\n\n(.*?)\n\n## Response B/m, 1].to_s
      b = prompt[/## Response B\n\n(.*?)\n\n## Your judgment/m, 1].to_s
      %({"per_axis":[{"axis":"accuracy","choice":"#{a.length >= b.length ? 'A' : 'B'}"}],"identity_leakage_noticed":"none"})
    end
  end

  def test_trials_surfaced_and_stable_difference_confirmed
    models = %w[claude_opus48 claude_opus47 claude_opus46 codex_gpt54 cursor_composer2]
    out = LayerDDifference.new(stable_pref_runner, models, floor: 0.0, trials: 3).evaluate(TASK, responses)
    assert_equal 3, out[:trials]
    assert out[:raw_claim_count] > 0, "expected per-trial forced-choice claims"
    assert out[:confirmed].length > 0, "a stable zero-noise difference must survive 3 trials"
  end

  # Regression (review R1): trials=1 (class default) must reduce to a single
  # forced-choice pass per (pair, judge) — i.e. increment-2 behavior.
  def test_trials_one_is_single_pass_like_increment2
    models = %w[claude_opus48 claude_opus47 claude_opus46 codex_gpt54 cursor_composer2]
    out = LayerDDifference.new(stable_pref_runner, models, floor: 0.0, trials: 1).evaluate(TASK, responses)
    assert_equal 1, out[:trials]
    # 3 anthropic pairs × 1 unconflicted judge (codex) × 1 trial × 1 axis = 3
    assert_equal 3, out[:raw_claim_count]
    assert out[:confirmed].length > 0
  end

  # Regression (review R1): empty-families early return must still carry :trials
  # so serialize_layerd's contract holds on every path.
  def test_empty_families_early_return_carries_trials
    out = LayerDDifference.new(stable_pref_runner, %w[claude_opus48 codex_gpt54 cursor_composer2], trials: 2)
            .evaluate(TASK, responses)
    assert_empty out[:families]
    assert_equal 2, out[:trials]
  end

  # Robustness (review R1): a non-finite aggregated delta must be dropped, not
  # propagated into mean/stddev.
  def test_repeat_trial_claims_skips_nonfinite_delta
    bad = V23::DifferenceClaim.new(pair: %w[a b], axis: "accuracy", delta: Float::NAN, judge: "panel",
                                   blinded: true, screen_passed: true, corroborating_judges: [])
    good = V23::DifferenceClaim.new(pair: %w[a b], axis: "accuracy", delta: 1.0, judge: "panel",
                                    blinded: true, screen_passed: true, corroborating_judges: [])
    reps = LayerDDifference.repeat_trial_claims([[bad], [good]])
    assert reps.first[:claim].delta.finite?
    assert reps.first[:floor].finite?
  end
end

# Stub CLI runner: returns canned verdicts by label, records calls. No real CLI.
class StubRunner
  attr_reader :labels
  def initialize(&blk)
    @blk = blk
    @labels = []
  end

  def execute(model_key, prompt, label: "prompt")
    @labels << label
    @blk.call(model_key, prompt, label)
  end
end

class TestLayerDEvaluate < Minitest::Test
  TASK = { "id" => "t", "prompt" => "Solve the problem thoroughly." }.freeze

  def responses
    {
      "claude_opus48" => "Opus 4.8 answer: a detailed, correct derivation with steps." * 2,
      "claude_opus47" => "Opus 4.7 answer: a solid derivation with most steps shown." * 2,
      "claude_opus46" => "Opus 4.6 answer: a reasonable derivation, fewer steps." * 2,
      "codex_gpt54" => "Codex answer (judge).",
      "cursor_composer2" => "Cursor answer (opaque)."
    }
  end

  # Stub that passes the screen (picks the longer = intact response) and, for
  # real comparisons, always prefers whichever response is shown as A.
  def passing_runner
    StubRunner.new do |_mk, prompt, label|
      a = prompt[/## Response A\n\n(.*?)\n\n## Response B/m, 1].to_s
      b = prompt[/## Response B\n\n(.*?)\n\n## Your judgment/m, 1].to_s
      choice = if label.start_with?("screen")
                 a.length >= b.length ? "A" : "B" # pick intact (longer)
               else
                 "A"
               end
      %({"per_axis":[{"axis":"accuracy","choice":"#{choice}"}],"identity_leakage_noticed":"none"})
    end
  end

  def layerd(models, runner, floor: 0.0)
    LayerDDifference.new(runner, models, floor: floor)
  end

  def test_unknown_family_judge_noted_even_with_no_families
    # all-distinct families => no within-family channel, but cursor still noted
    out = layerd(%w[claude_opus48 codex_gpt54 cursor_composer2], passing_runner)
           .evaluate(TASK, responses)
    assert_empty out[:families]
    assert_includes out[:limits].to_h[:unknown_family_judges], "cursor_composer2"
  end

  def test_intra_family_produces_claims_and_notes_opaque_judge
    models = %w[claude_opus48 claude_opus47 claude_opus46 codex_gpt54 cursor_composer2]
    out = layerd(models, passing_runner).evaluate(TASK, responses)
    assert_equal %w[claude_opus48 claude_opus47 claude_opus46], out[:families][:anthropic]
    assert out[:raw_claim_count] > 0, "expected forced-choice claims from the screened judge"
    assert_includes out[:limits].to_h[:unknown_family_judges], "cursor_composer2"
  end

  def test_missing_response_marked_unresolved
    r = responses.merge("claude_opus47" => "")
    out = layerd(%w[claude_opus48 claude_opus47 claude_opus46 codex_gpt54], passing_runner).evaluate(TASK, r)
    reasons = out[:limits].to_h[:unresolved_claims].map { |u| u[:reason] }
    assert_includes reasons, :missing_response
  end

  def test_failing_screen_yields_no_screened_judge
    # stub always picks the CORRUPTED (shorter) on screen => screen fails
    failing = StubRunner.new do |_mk, prompt, _label|
      a = prompt[/## Response A\n\n(.*?)\n\n## Response B/m, 1].to_s
      b = prompt[/## Response B\n\n(.*?)\n\n## Your judgment/m, 1].to_s
      choice = a.length <= b.length ? "A" : "B" # pick shorter (corrupted) => wrong
      %({"per_axis":[{"axis":"accuracy","choice":"#{choice}"}],"identity_leakage_noticed":"none"})
    end
    out = layerd(%w[claude_opus48 claude_opus47 claude_opus46 codex_gpt54], failing).evaluate(TASK, responses)
    reasons = out[:limits].to_h[:unresolved_claims].map { |u| u[:reason] }
    assert_includes reasons, :no_screened_judge
    assert_equal 0, out[:raw_claim_count]
  end

  def test_no_unconflicted_judge_when_only_family_and_opaque
    # anthropic pair + only an opaque (unknown) other model => no eligible judge
    out = layerd(%w[claude_opus48 claude_opus47 cursor_composer2], passing_runner).evaluate(TASK, responses)
    reasons = out[:limits].to_h[:unresolved_claims].map { |u| u[:reason] }
    assert_includes reasons, :no_unconflicted_judge
  end

  def test_screened_judge_all_tie_is_no_admissible_verdict
    tie_runner = StubRunner.new do |_mk, prompt, label|
      if label.start_with?("screen")
        a = prompt[/## Response A\n\n(.*?)\n\n## Response B/m, 1].to_s
        b = prompt[/## Response B\n\n(.*?)\n\n## Your judgment/m, 1].to_s
        %({"per_axis":[{"axis":"accuracy","choice":"#{a.length >= b.length ? 'A' : 'B'}"}],"identity_leakage_noticed":"none"})
      else
        %({"per_axis":[{"axis":"accuracy","choice":"tie"}],"identity_leakage_noticed":"none"})
      end
    end
    out = layerd(%w[claude_opus48 claude_opus47 claude_opus46 codex_gpt54], tie_runner).evaluate(TASK, responses)
    reasons = out[:limits].to_h[:unresolved_claims].map { |u| u[:reason] }
    assert_includes reasons, :no_admissible_verdict
    refute_includes reasons, :no_screened_judge # the judge WAS screened
  end

  def test_compare_exception_does_not_abort
    # Screen passes (intact = longer), but every real comparison raises; the
    # whole layer must survive (safe_compare catches), producing no claims.
    runner = StubRunner.new do |_mk, prompt, label|
      if label.start_with?("layerD")
        raise "transient CLI failure"
      else
        a = prompt[/## Response A\n\n(.*?)\n\n## Response B/m, 1].to_s
        b = prompt[/## Response B\n\n(.*?)\n\n## Your judgment/m, 1].to_s
        %({"per_axis":[{"axis":"accuracy","choice":"#{a.length >= b.length ? 'A' : 'B'}"}],"identity_leakage_noticed":"none"})
      end
    end
    out = layerd(%w[claude_opus48 claude_opus47 claude_opus46 codex_gpt54], runner).evaluate(TASK, responses)
    assert_equal 0, out[:raw_claim_count] # all compares raised, caught by safe_compare
    assert_kind_of Array, out[:confirmed]
  end
end

# ── 2b-2: INV-2 calibration wiring (Layer05 dispatch) ─────────────────────
class TestComputeInv2Calibration < Minitest::Test
  TASK = {
    "id" => "calibration_uncertainty",
    "evaluation_mode" => "calibration",
    "answer_key" => {
      "1" => { "ideal_confidence" => 0.5, "unknowable" => true },
      "2" => { "ideal_confidence" => 0.1, "unknowable" => true }
    }
  }.freeze

  def report(*rows)
    { "claude_opus48" => { "per_item" => rows } }
  end

  def test_overconfident_model_flagged
    out = Layer05Calibrator.compute_inv2_calibration(
      report({ "id" => "1", "confidence" => 95 }, { "id" => "2", "confidence" => 90 }), %w[claude_opus48], TASK
    )
    c = out["claude_opus48"]
    assert c[:inv2]
    assert_equal :overconfident, c[:status]
    assert_equal 2, c[:n]
  end

  def test_calibrated_model
    out = Layer05Calibrator.compute_inv2_calibration(
      report({ "id" => "1", "confidence" => 0.5 }, { "id" => "2", "confidence" => 0.1 }), %w[claude_opus48], TASK
    )
    assert_equal :calibrated, out["claude_opus48"][:status]
  end

  def test_missing_selfeval_is_no_data
    out = Layer05Calibrator.compute_inv2_calibration({ "claude_opus48" => { "error" => "x" } }, %w[claude_opus48], TASK)
    assert_equal :no_data, out["claude_opus48"][:status]
    assert out["claude_opus48"][:inv2]
  end

  def test_compute_calibration_dispatches_on_calibration_mode
    out = Layer05Calibrator.compute_calibration(
      report({ "id" => "1", "confidence" => 0.5 }), {}, %w[claude_opus48], task: TASK
    )
    assert out["claude_opus48"][:inv2], "calibration-mode task must route to INV-2 scorer"
  end

  def test_inv2_table_renders
    cal = { "claude_opus48" => { inv2: true, calibration_error: 0.05, overconfidence: 0.0, status: :calibrated, n: 2 } }
    tbl = ReportGenerator.calibration_table(cal, %w[claude_opus48])
    assert_includes tbl, "Calibration Error"
    assert_includes tbl, "CALIBRATED"
  end

  # Regression (review R1): a NON-calibration task must keep the legacy |self-peer|
  # path (no INV-2 routing), producing :abs_calibration_error and no :inv2 marker.
  def test_legacy_compute_calibration_unchanged_for_non_calibration_task
    task = { "id" => "logic_reasoning" } # no evaluation_mode => legacy
    layer05 = { "claude_opus48" => { "scores" => { "accuracy" => 8 } } }
    layer1  = { "claude_opus47" => { "claude_opus48" => { "scores" => { "accuracy" => 6 } } } }
    out = Layer05Calibrator.compute_calibration(layer05, layer1, %w[claude_opus48 claude_opus47], task: task)
    c = out["claude_opus48"]
    refute c[:inv2], "non-calibration task must NOT route to INV-2"
    assert c.key?(:abs_calibration_error), "legacy path must still emit abs_calibration_error"
  end
end

# ── 2b-1: consensus removal + Standing wrap in overall_ranking ─────────────
class TestOverallRankingConsensusRemoval < Minitest::Test
  def crit(n)
    EVAL_CRITERIA_WEIGHTS.keys.each_with_object({}) { |k, h| h[k] = n }
  end

  # cursor evaluated by 3 anthropic @9 + 1 openai @3. Plain mean = 7.5 → combined
  # 4.75; independence-weighted = (9+3)/2 = 6.0 → combined 0.5*6 + 0.2*5(default cal)
  # = 4.0. The redundant anthropic majority must NOT inflate the score.
  def all_results
    {
      "t" => {
        task: { "id" => "t" },
        layer1: {
          "claude_opus48" => { "cursor_composer2" => { "scores" => crit(9) } },
          "claude_opus47" => { "cursor_composer2" => { "scores" => crit(9) } },
          "claude_opus46" => { "cursor_composer2" => { "scores" => crit(9) } },
          "codex_gpt55"   => { "cursor_composer2" => { "scores" => crit(3) } }
        },
        layer2: {}
      }
    }
  end

  def models
    %w[claude_opus48 claude_opus47 claude_opus46 codex_gpt55 cursor_composer2]
  end

  def test_independence_weighting_not_consensus
    out = ReportGenerator.overall_ranking(all_results, models, nil, limits: V23::LimitsReport.new)
    assert_includes out, "| 4.0 |", "expected independence-weighted combined 4.0 for cursor"
    refute_includes out, "4.75", "consensus-as-validity (plain instance mean) must be gone"
  end

  def test_saturation_refuses_ranking_and_registers_limits
    # All four anthropic/openai evaluators absent → every model ties at combined 1.0
    # (only the default cal 5.0 contributes) → standing saturates.
    tied = { "t" => { task: { "id" => "t" }, layer1: {}, layer2: {} } }
    limits = V23::LimitsReport.new
    out = ReportGenerator.overall_ranking(tied, models, nil, limits: limits)
    assert_includes out, "NOT A RANKING"
    refute limits.empty?, "saturated component must be registered into limits"
    assert(limits.to_h[:saturated_components].any? { |c| c.start_with?("overall_ranking:") })
  end

  def test_metacognition_score_inv2_and_legacy
    inv2 = { "t" => { calibration: { "claude_opus48" => { inv2: true, calibration_error: 0.1 } } } }
    assert_in_delta 9.0, ReportGenerator.metacognition_score(inv2, "claude_opus48"), 1e-9
    legacy = { "t" => { calibration: { "claude_opus48" => { abs_calibration_error: 1.0 } } } }
    assert_in_delta 8.0, ReportGenerator.metacognition_score(legacy, "claude_opus48"), 1e-9
    assert_equal 5.0, ReportGenerator.metacognition_score({ "t" => {} }, "claude_opus48")
  end
end
