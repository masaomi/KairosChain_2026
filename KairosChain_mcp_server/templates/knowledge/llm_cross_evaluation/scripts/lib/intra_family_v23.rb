# frozen_string_literal: true
#
# llm_cross_evaluation v2.3 — invariant-enforcement core
#
# Implements the deterministic logic of the v2.3 design freeze
# (docs/drafts/llm_cross_evaluation_v2.3_design_v1.0_freeze.md). Pure logic:
# NO CLI, NO network. CLI-driven forced-choice execution wires these together
# (CrossEvalPipeline integration, increment 2), but decision logic lives here.
#
# Invariant coverage (freeze §3): INV-1 NoiseFloor; INV-3 Standing; INV-4
# LimitsReport; INV-6 IndependenceWeighting; INV-7 via AdmissibilityGate +
# NoiseFloor; INV-8 FamilyResolver / ResolutionScreen / AdmissibilityGate /
# ConsistencyChecker, orchestrated by DifferenceEvaluator.
#
# Revised after implementation review rounds 1–2: finite-number guards (NaN AND
# Infinity), malformed-claim/sample validation, structural corroboration
# (INV-8 iii), per-axis same-SCC cycle isolation (INV-8 iv), deterministic
# ranking tie-break, dedup, typed errors, and a distinct noise_floor_unestablished
# reason.

module V23
  class Error < StandardError; end

  module_function

  # Finite => Numeric, not NaN, not +/-Infinity. (Float#finite? / Integer#finite?
  # both exist and return the right thing; finite? is false for NaN and Infinity.)
  def numeric_finite?(x)
    x.is_a?(Numeric) && x.respond_to?(:finite?) && x.finite?
  end

  # Sample (n-1) standard deviation. < 2 values => 0.0 (no spread estimable).
  # Caller is responsible for passing finite numbers.
  def sample_stddev(xs)
    xs = Array(xs).map(&:to_f)
    n = xs.length
    return 0.0 if n < 2
    mean = xs.sum / n
    Math.sqrt(xs.sum { |x| (x - mean)**2 } / (n - 1))
  end

  # ── Family classification (Definitions; INV-6; INV-8 iii) ──────────────
  class FamilyResolver
    def initialize(lineage_map = {})
      @lineage = lineage_map || {}
    end

    def family_of(model_key)
      fam = @lineage[model_key]
      fam.nil? ? :unknown : fam
    end

    def unknown_family?(model_key)
      family_of(model_key) == :unknown
    end

    def near_kin?(a, b)
      fa = family_of(a)
      fa != :unknown && fa == family_of(b)
    end

    # Conflicted iff judge IS a member of the pair or shares a known family with
    # either member. Malformed (non-enumerable) pair => conservative true.
    def conflicted?(judge, pair)
      return true unless pair.respond_to?(:any?)
      pair.any? { |m| judge == m || near_kin?(judge, m) }
    end

    def families(model_keys)
      groups = Hash.new { |h, k| h[k] = [] }
      model_keys.each do |k|
        fam = family_of(k)
        groups[fam] << k unless fam == :unknown
      end
      groups.select { |_, members| members.length >= 2 }
    end
  end

  # ── Noise floor (INV-1) ────────────────────────────────────────────────
  class NoiseFloor
    attr_reader :floor

    def initialize(floor: nil, samples: nil, k: 2.0)
      raise Error, "k must be a positive finite number" unless V23.numeric_finite?(k) && k > 0
      raise Error, "provide either floor or samples, not both" if !floor.nil? && samples
      if samples && !samples.all? { |s| V23.numeric_finite?(s) }
        raise Error, "samples must all be finite numbers"
      end

      @floor =
        if !floor.nil?
          unless V23.numeric_finite?(floor) && floor >= 0
            raise Error, "floor must be a finite, non-negative number (got #{floor.inspect})"
          end
          floor.to_f
        elsif samples && samples.length >= 2
          sd = V23.sample_stddev(samples)
          sd > 0 ? k * sd : nil # zero variance cannot bound noise => not established
        end
    end

    def established?
      !@floor.nil?
    end

    # Claimable iff established AND |delta| strictly exceeds the floor. A nil /
    # non-numeric / NaN / Infinity delta is NOT claimable (never raises).
    def claimable?(delta)
      return false unless established?
      return false unless V23.numeric_finite?(delta)
      delta.to_f.abs > @floor
    end
  end

  # ── Coarse-to-fine resolution screen (INV-8 ii) ────────────────────────
  class ResolutionScreen
    def initialize(required_fraction: 1.0)
      unless V23.numeric_finite?(required_fraction) && required_fraction >= 0 && required_fraction <= 1
        raise Error, "required_fraction must be within [0, 1]"
      end
      @required = required_fraction
    end

    # A control row missing either key (or with a nil value) is malformed and
    # counts as NOT correct. Empty / nil => does not pass.
    def passes?(control_results)
      return false if control_results.nil? || control_results.empty?
      correct = control_results.count do |c|
        c.is_a?(Hash) && !c[:expected].nil? && !c[:judged].nil? && c[:judged] == c[:expected]
      end
      (correct.to_f / control_results.length) >= @required
    end
  end

  # ── Difference claim + admissibility gate (INV-8 i/ii/iii) ─────────────
  DifferenceClaim = Struct.new(
    :pair, :axis, :delta, :judge,
    :blinded, :screen_passed, :corroborating_judges,
    keyword_init: true
  )

  class AdmissibilityGate
    def initialize(noise_floor:, resolver:)
      @floor = noise_floor
      @resolver = resolver
    end

    def evaluate(claim)
      return reject(:malformed_claim) unless valid_claim?(claim)
      return reject(:noise_floor_unestablished) unless @floor.established?
      return reject(:below_noise_floor) unless @floor.claimable?(claim.delta)
      return reject(:not_blinded) unless claim.blinded == true
      return reject(:resolution_unverified) unless claim.screen_passed == true
      if @resolver.conflicted?(claim.judge, claim.pair) && !corroborated?(claim)
        return reject(:conflicted_uncorroborated)
      end
      { admissible: true, reason: nil }
    end

    private

    def valid_claim?(c)
      c.is_a?(DifferenceClaim) &&
        c.pair.is_a?(Array) && c.pair.length == 2 &&
        c.pair.none?(&:nil?) && c.pair[0] != c.pair[1] &&
        !c.judge.nil? && !c.axis.nil? &&
        V23.numeric_finite?(c.delta)
    end

    # INV-8(iii): a conflicted primary judge needs corroboration from a DISTINCT,
    # unconflicted, screen-passed judge — verified structurally, not trusted.
    def corroborated?(claim)
      list = claim.corroborating_judges
      list = [list] if list.is_a?(Hash)
      Array(list).any? do |cj|
        next false unless cj.is_a?(Hash)
        j = cj[:judge]
        j.is_a?(String) && !j.empty? && j != claim.judge &&
          cj[:screen_passed] == true && !@resolver.conflicted?(j, claim.pair)
      end
    end

    def reject(reason)
      { admissible: false, reason: reason }
    end
  end

  # ── Pairwise consistency / cycle detection (INV-8 iv) ──────────────────
  class ConsistencyChecker
    def initialize(prefs)
      @prefs = prefs
    end

    def consistent?
      cyclic_components.empty?
    end

    # All cyclic strongly-connected components (each an array of nodes). A
    # component is cyclic if size > 1 or it has a self-loop.
    def cyclic_components
      adj = Hash.new { |h, k| h[k] = [] }
      nodes = []
      @prefs.each do |winner, loser|
        adj[winner] << loser
        nodes << winner << loser
      end
      nodes.uniq!

      index = {}
      low = {}
      on_stack = {}
      stack = []
      counter = 0
      result = []

      strongconnect = lambda do |v|
        index[v] = counter
        low[v] = counter
        counter += 1
        stack.push(v)
        on_stack[v] = true

        adj[v].each do |w|
          if !index.key?(w)
            strongconnect.call(w)
            low[v] = [low[v], low[w]].min
          elsif on_stack[w]
            low[v] = [low[v], index[w]].min
          end
        end

        if low[v] == index[v]
          scc = []
          loop do
            w = stack.pop
            on_stack[w] = false
            scc << w
            break if w == v
          end
          result << scc if scc.length > 1 || adj[scc.first].include?(scc.first)
        end
      end

      nodes.each { |v| strongconnect.call(v) unless index.key?(v) }
      result
    end

    def cyclic_nodes
      cyclic_components.flatten.uniq
    end
  end

  # ── Independence-weighted agreement (INV-6) ────────────────────────────
  class IndependenceWeighting
    def initialize(resolver)
      @resolver = resolver
    end

    def agreement_weight(evaluators)
      families_seen = {}
      evaluators.each do |e|
        fam = @resolver.family_of(e)
        next if fam == :unknown
        families_seen[fam] = true
      end
      families_seen.size.to_f
    end

    # INV-3/6/9: family-independent mean. Replaces consensus-as-validity (a plain
    # mean over evaluator instances, which lets a redundant same-family majority
    # inflate a score). Group values by family (each KNOWN family = one vote),
    # average within family, then average across the family means. Unknown-family
    # evaluators each count as their own independent vote (opaque ≠ redundant).
    #   values_by_evaluator : { evaluator_key => finite number }
    # Non-finite values are dropped; all-empty / all-dropped => nil.
    def independent_mean(values_by_evaluator)
      return nil if values_by_evaluator.nil? || values_by_evaluator.empty?
      groups = Hash.new { |h, k| h[k] = [] }
      values_by_evaluator.each do |ev, val|
        next unless V23.numeric_finite?(val)
        fam = @resolver.family_of(ev)
        bucket = fam == :unknown ? [:unknown, ev] : [:family, fam]
        groups[bucket] << val
      end
      return nil if groups.empty?
      family_means = groups.values.map { |vs| vs.sum.to_f / vs.size }
      family_means.sum / family_means.size
    end
  end

  # ── Standing vs ranking guard (INV-3) ──────────────────────────────────
  class Standing
    attr_reader :scores, :saturated_components

    def initialize(scores, saturated_components: [])
      @scores = scores
      @saturated_components = saturated_components || []
    end

    # Build a Standing with saturation auto-detected from score dispersion. Keys
    # whose scores chain together within `epsilon` form a saturated component —
    # the evidence cannot order them, so the whole standing refuses to read as a
    # ranking (INV-3). Single-key clusters are not saturated. Conservative by
    # design: adjacent gaps ≤ epsilon chain, biasing toward "unresolved" over a
    # falsely confident order. epsilon 0.0 => only exact ties saturate.
    def self.from_scores(scores, epsilon: 0.0)
      new(scores, saturated_components: saturated_clusters(scores, epsilon))
    end

    def self.saturated_clusters(scores, epsilon)
      return [] unless scores.is_a?(Hash) && !scores.empty?
      return [] unless scores.values.all? { |v| V23.numeric_finite?(v) }
      raise V23::Error, "epsilon must be finite and non-negative" unless V23.numeric_finite?(epsilon) && epsilon >= 0
      sorted = scores.sort_by { |k, v| [-v, k] }
      clusters = []
      current = []
      sorted.each do |k, v|
        if current.empty? || (current.last[1] - v).abs <= epsilon
          current << [k, v]
        else
          clusters << current
          current = [[k, v]]
        end
      end
      clusters << current unless current.empty?
      clusters.select { |c| c.length >= 2 }.map { |c| c.map(&:first) }
    end

    def label
      @saturated_components.empty? ? :ranking_ok : :not_a_ranking
    end

    # Deterministic: descending score, ties broken by key ascending.
    def as_ranking!
      unless @saturated_components.empty?
        raise V23::Error, "INV-3 violation: standing carries saturated components " \
                          "#{@saturated_components.inspect}; it may not be read as a ranking."
      end
      unless @scores.is_a?(Hash) && @scores.values.all? { |v| V23.numeric_finite?(v) }
        raise V23::Error, "standing scores must be a hash of finite numbers"
      end
      @scores.sort_by { |k, v| [-v, k] }.map { |k, _v| k }
    end
  end

  # ── Per-run limits report (INV-4) ──────────────────────────────────────
  class LimitsReport
    def initialize
      @saturated = []
      @unresolved = []
      @unknown_family_judges = []
    end

    def add_saturated_component(component)
      @saturated << component
      self
    end

    def add_unresolved(pair:, axis:, reason:)
      @unresolved << { pair: pair, axis: axis, reason: reason }
      self
    end

    def note_unknown_family_judge(judge)
      @unknown_family_judges << judge
      self
    end

    def empty?
      @saturated.empty? && @unresolved.empty? && @unknown_family_judges.empty?
    end

    def to_h
      {
        saturated_components: @saturated.uniq,
        unresolved_claims: @unresolved.uniq,
        unknown_family_judges: @unknown_family_judges.uniq
      }
    end
  end

  # ── End-to-end difference evaluation (wires INV-8 i–iv + INV-4) ─────────
  #
  # Cycle detection is per-axis (different axes are independent comparisons) and
  # a claim is reported intransitive only when BOTH endpoints lie in the SAME
  # cyclic component on that axis — so a claim merely incident to a cycle, or
  # spanning two distinct components, is not falsely dropped.
  class DifferenceEvaluator
    def initialize(gate:, resolver:)
      @gate = gate
      @resolver = resolver
    end

    def run(claims, limits: LimitsReport.new)
      claims = [] unless claims.is_a?(Array)
      valid = []
      claims.each do |claim|
        res = @gate.evaluate(claim) # validates first; never crashes on malformed
        if res[:admissible]
          limits.note_unknown_family_judge(claim.judge) if @resolver.unknown_family?(claim.judge)
          valid << claim
        else
          pair = claim.is_a?(DifferenceClaim) ? claim.pair : nil
          axis = claim.is_a?(DifferenceClaim) ? claim.axis : nil
          limits.add_unresolved(pair: pair, axis: axis, reason: res[:reason])
        end
      end

      confirmed = []
      indeterminate = []
      valid.group_by(&:axis).each_value do |axis_claims|
        components = ConsistencyChecker.new(axis_claims.map { |c| pref_edge(c) }).cyclic_components
        axis_claims.each do |c|
          if components.any? { |sc| sc.include?(c.pair[0]) && sc.include?(c.pair[1]) }
            limits.add_unresolved(pair: c.pair, axis: c.axis, reason: :intransitive)
            indeterminate << c
          else
            confirmed << c
          end
        end
      end

      { confirmed: confirmed, indeterminate: indeterminate, limits: limits }
    end

    private

    # Positive delta => pair[0] preferred. (delta == 0 is unreachable: the gate's
    # strict noise-floor test excludes it.)
    def pref_edge(claim)
      claim.delta >= 0 ? [claim.pair[0], claim.pair[1]] : [claim.pair[1], claim.pair[0]]
    end
  end
end
