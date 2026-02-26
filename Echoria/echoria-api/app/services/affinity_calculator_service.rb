# Calculates and applies affinity changes based on player choices
# and AI-generated scenes.
#
# Echoria 5-axis affinity system:
#   - tiara_trust (0-100): Bond strength with Tiara
#   - logic_empathy_balance (-50 to +50): Analytical vs emotional approach
#   - name_memory_stability (0-100): Echo's identity coherence
#   - authority_resistance (-50 to +50): Compliance vs rebellion
#   - fragment_count (0+): Collected memory fragments (カケラ)
#
class AffinityCalculatorService
  AXIS_RANGES = {
    "tiara_trust"           => { min: 0,   max: 100 },
    "logic_empathy_balance" => { min: -50,  max: 50  },
    "name_memory_stability" => { min: 0,   max: 100 },
    "authority_resistance"  => { min: -50,  max: 50  },
    "fragment_count"        => { min: 0,   max: nil  }  # unbounded upper
  }.freeze

  VALID_AXES = AXIS_RANGES.keys.freeze

  attr_reader :newly_evolved_skills

  def initialize(story_session)
    @session = story_session
    @newly_evolved_skills = []
  end

  # Apply a delta from a beacon choice (pre-defined in seed data)
  def apply_beacon_delta(selected_choice)
    delta = extract_delta(selected_choice)
    apply_delta(delta)
  end

  # Apply a delta from AI-generated content (from StoryGeneratorService)
  def apply_generated_delta(generated_result)
    delta = generated_result[:affinity_delta] || generated_result["affinity_delta"] || {}
    sanitized = sanitize_delta(delta)
    apply_delta(sanitized)
  end

  # Combine beacon choice delta + AI-generated delta
  def apply_combined(selected_choice, generated_result)
    beacon_delta = extract_delta(selected_choice)
    generated_delta = sanitize_delta(generated_result[:affinity_delta] || {})

    # Beacon deltas are authoritative; generated deltas are supplementary
    # Weight: beacon = 1.0, generated = 0.5
    combined = {}
    VALID_AXES.each do |axis|
      beacon_val = (beacon_delta[axis] || 0).to_i
      generated_val = ((generated_delta[axis] || 0).to_i * 0.5).round
      combined[axis] = beacon_val + generated_val
    end

    apply_delta(combined)
  end

  # Get the current affinity state
  def current_affinity
    @session.affinity || StorySession::DEFAULT_AFFINITY.dup
  end

  # Compute Tiara's trust tier (for character voice calibration)
  def tiara_trust_tier
    trust = current_affinity["tiara_trust"] || 50

    case trust
    when 0..20   then :distant      # Tiara observes, tests
    when 21..40  then :cautious     # Shares minor details, shows humor
    when 41..60  then :open         # Speaks freely, asks about Echo
    when 61..80  then :intimate     # Shares truths, physically affectionate
    when 81..100 then :merged       # Speaks as one entity
    else :open
    end
  end

  # Returns a narrative-friendly summary of the affinity state
  def affinity_summary
    aff = current_affinity

    {
      tiara_relationship: tiara_trust_tier,
      thinking_style: aff["logic_empathy_balance"].to_i > 0 ? :empathetic : :analytical,
      identity_stability: identity_tier(aff["name_memory_stability"].to_i),
      authority_stance: aff["authority_resistance"].to_i > 0 ? :resistant : :compliant,
      fragments_collected: aff["fragment_count"].to_i,
      total_resonance: compute_resonance_score(aff)
    }
  end

  # Check if crystallization threshold is met
  # Requires: tiara_trust >= 60, fragment_count >= 10, at least 15 scenes
  def crystallization_ready?
    aff = current_affinity
    aff["tiara_trust"].to_i >= 60 &&
      aff["fragment_count"].to_i >= 10 &&
      @session.scene_count >= 15
  end

  private

  def extract_delta(choice)
    return {} unless choice.is_a?(Hash)

    raw = choice["affinity_delta"] || choice[:affinity_delta] || {}
    sanitize_delta(raw)
  end

  def sanitize_delta(delta)
    return {} unless delta.is_a?(Hash)

    VALID_AXES.each_with_object({}) do |axis, result|
      val = delta[axis] || delta[axis.to_sym]
      result[axis] = val.to_i if val
    end
  end

  def apply_delta(delta)
    return current_affinity if delta.empty?

    @session.add_affinity_delta(delta)
    @session.save!

    # Record on KairosChain for blockchain integrity
    record_affinity_change(delta)

    # Check for skill evolution based on new affinity state
    check_skill_evolution

    current_affinity
  end

  def check_skill_evolution
    @newly_evolved_skills = SkillEvolutionService.new(@session).evolve!
  rescue StandardError => e
    Rails.logger.warn("[AffinityCalculator] Skill evolution check failed: #{e.message}")
    @newly_evolved_skills = []
  end

  def record_affinity_change(delta)
    bridge = @session.echo.kairos_chain
    return unless bridge&.available?

    bridge.record_action(
      "affinity_update",
      {
        session_id: @session.id,
        delta: delta,
        resulting_affinity: current_affinity,
        scene_count: @session.scene_count
      }
    )
  rescue StandardError => e
    Rails.logger.warn("[AffinityCalculator] KairosChain record failed: #{e.message}")
  end

  def identity_tier(stability)
    case stability
    when 0..25   then :fragmented
    when 26..50  then :uncertain
    when 51..75  then :forming
    when 76..100 then :stable
    else :uncertain
    end
  end

  # Composite score reflecting overall resonance strength (0-100)
  def compute_resonance_score(affinity)
    trust = affinity["tiara_trust"].to_i
    stability = affinity["name_memory_stability"].to_i
    fragments = [affinity["fragment_count"].to_i, 50].min  # cap at 50 for scoring

    # Weighted average: trust 40%, stability 30%, fragments 30%
    ((trust * 0.4) + (stability * 0.3) + (fragments * 0.6)).round(1)
  end
end
