# Evolves Echo skills based on affinity thresholds during story play.
#
# Called after affinity changes are applied. Checks if any affinity
# axis has crossed a threshold that unlocks a new skill. This surfaces
# KairosChain's philosophy: skills grow from lived experience.
#
# Skill tiers:
#   L1 — Base skills (seeded at creation)
#   L2 — Awakened skills (unlocked via affinity thresholds)
#   L3 — Resonance skills (unlocked at high affinity, rare)
#
class SkillEvolutionService
  # Each entry: affinity_axis, threshold, direction (:above/:below), skill definition
  EVOLUTION_RULES = [
    # L2 awakenings — moderate thresholds
    {
      axis: "tiara_trust", threshold: 65, direction: :above,
      skill: { skill_id: "empathic_resonance_L2", title: "Empathic Resonance",
               content: "The ability to sense and share in the emotions of others through resonance.",
               layer: "L2" }
    },
    {
      axis: "name_memory_stability", threshold: 70, direction: :above,
      skill: { skill_id: "identity_anchor_L2", title: "Identity Anchor",
               content: "A stable sense of self that resists the erosion of name-fading.",
               layer: "L2" }
    },
    {
      axis: "authority_resistance", threshold: 25, direction: :above,
      skill: { skill_id: "independent_will_L2", title: "Independent Will",
               content: "The courage to question authority and choose one's own path.",
               layer: "L2" }
    },
    {
      axis: "logic_empathy_balance", threshold: 25, direction: :above,
      skill: { skill_id: "heart_reading_L2", title: "Heart Reading",
               content: "The capacity to understand unspoken feelings through intuition.",
               layer: "L2" }
    },
    {
      axis: "logic_empathy_balance", threshold: -25, direction: :below,
      skill: { skill_id: "pattern_sight_L2", title: "Pattern Sight",
               content: "The ability to perceive hidden structures and logical connections.",
               layer: "L2" }
    },
    {
      axis: "fragment_count", threshold: 5, direction: :above,
      skill: { skill_id: "memory_weaving_L2", title: "Memory Weaving",
               content: "The skill to connect scattered fragments into coherent memory.",
               layer: "L2" }
    },

    # L3 resonance skills — high thresholds, rare
    {
      axis: "tiara_trust", threshold: 85, direction: :above,
      skill: { skill_id: "soul_bridge_L3", title: "Soul Bridge",
               content: "A profound connection that transcends words — understanding through shared existence.",
               layer: "L3" }
    },
    {
      axis: "fragment_count", threshold: 15, direction: :above,
      skill: { skill_id: "echo_of_echoes_L3", title: "Echo of Echoes",
               content: "The resonance of all collected memories, forming a chorus of lost voices.",
               layer: "L3" }
    }
  ].freeze

  def initialize(story_session)
    @session = story_session
    @echo = story_session.echo
    @affinity = story_session.affinity || {}
  end

  # Check all rules and unlock any newly qualified skills.
  # Returns array of newly unlocked skill definitions (empty if none).
  def evolve!
    newly_unlocked = []

    EVOLUTION_RULES.each do |rule|
      next if already_has_skill?(rule[:skill][:skill_id])
      next unless threshold_met?(rule)

      skill = unlock_skill!(rule[:skill])
      newly_unlocked << skill if skill
    end

    record_evolutions_on_chain(newly_unlocked) if newly_unlocked.any?

    newly_unlocked
  end

  private

  def already_has_skill?(skill_id)
    @echo.echo_skills.exists?(skill_id: skill_id)
  end

  def threshold_met?(rule)
    value = @affinity[rule[:axis]].to_i

    case rule[:direction]
    when :above then value >= rule[:threshold]
    when :below then value <= rule[:threshold]
    else false
    end
  end

  def unlock_skill!(skill_def)
    EchoSkill.create!(
      echo_id: @echo.id,
      skill_id: skill_def[:skill_id],
      title: skill_def[:title],
      content: skill_def[:content],
      layer: skill_def[:layer]
    )
  rescue ActiveRecord::RecordNotUnique
    # Race condition guard — skill already exists
    nil
  end

  def record_evolutions_on_chain(skills)
    bridge = @echo.kairos_chain
    return unless bridge&.available?

    skills.each do |skill|
      bridge.record_skill(skill.skill_id, skill.content, skill.layer)
    end
  rescue StandardError => e
    Rails.logger.warn("[SkillEvolution] KairosChain record failed: #{e.message}")
  end
end
