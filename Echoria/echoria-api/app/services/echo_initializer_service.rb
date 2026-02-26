class EchoInitializerService
  def initialize(echo)
    @echo = echo
    @bridge = echo.kairos_chain
  end

  def call
    seed_base_skills
    record_genesis_on_chain
    @echo
  end

  private

  def seed_base_skills
    BASE_SKILLS.each do |skill_data|
      @echo.echo_skills.create!(
        skill_id: skill_data[:skill_id],
        title: skill_data[:title],
        content: skill_data[:content],
        layer: skill_data[:layer]
      )
    end
  rescue ActiveRecord::RecordNotUnique
    # Idempotency: skills already exist (concurrent request)
    Rails.logger.info("[EchoInitializer] Base skills already seeded for Echo #{@echo.id}")
  end

  def record_genesis_on_chain
    return unless @bridge&.available?

    @bridge.add_to_chain(
      type: "echo_initialization",
      name: @echo.name,
      status: @echo.status,
      base_skills: @echo.echo_skills.map { |s| { id: s.skill_id, title: s.title, layer: s.layer } }
    )
  rescue StandardError => e
    Rails.logger.warn("[EchoInitializer] KairosChain genesis record failed: #{e.message}")
  end

  BASE_SKILLS = [
    { skill_id: "perception_L1", title: "Perception",
      content: "The Echo's ability to understand and interpret their world.", layer: "L1" },
    { skill_id: "reflection_L1", title: "Reflection",
      content: "The Echo's capacity for self-examination and introspection.", layer: "L1" },
    { skill_id: "adaptation_L1", title: "Adaptation",
      content: "The Echo's ability to respond to changing circumstances.", layer: "L1" },
    { skill_id: "expression_L2", title: "Expression",
      content: "The Echo's ability to communicate thoughts and feelings.", layer: "L2" },
    { skill_id: "growth_L2", title: "Growth",
      content: "The Echo's capacity to learn and evolve from experiences.", layer: "L2" }
  ].freeze
end
