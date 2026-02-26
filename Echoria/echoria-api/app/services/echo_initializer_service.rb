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
      EchoSkill.find_or_create_by!(
        echo_id: @echo.id,
        skill_id: skill_data[:skill_id]
      ) do |skill|
        skill.title = skill_data[:title]
        skill.content = skill_data[:content]
        skill.layer = skill_data[:layer]
      end
    end
  end

  def record_genesis_on_chain
    @bridge.add_to_chain(
      type: "echo_initialization",
      name: @echo.name,
      status: @echo.status,
      base_skills: @echo.echo_skills.map { |s| { id: s.skill_id, title: s.title, layer: s.layer } }
    )
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
