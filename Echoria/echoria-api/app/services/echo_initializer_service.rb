class EchoInitializerService
  def initialize(echo)
    @echo = echo
  end

  def call
    create_genesis_block
    seed_base_skills
    create_initial_conversation
    record_on_blockchain
    @echo
  end

  private

  def create_genesis_block
    EchoBlock.genesis_block(@echo.id)
  end

  def seed_base_skills
    base_skills = [
      {
        skill_id: "perception_L1",
        title: "Perception",
        content: "The Echo's ability to understand and interpret their world.",
        layer: "L1"
      },
      {
        skill_id: "reflection_L1",
        title: "Reflection",
        content: "The Echo's capacity for self-examination and introspection.",
        layer: "L1"
      },
      {
        skill_id: "adaptation_L1",
        title: "Adaptation",
        content: "The Echo's ability to respond to changing circumstances.",
        layer: "L1"
      },
      {
        skill_id: "expression_L2",
        title: "Expression",
        content: "The Echo's ability to communicate thoughts and feelings.",
        layer: "L2"
      },
      {
        skill_id: "growth_L2",
        title: "Growth",
        content: "The Echo's capacity to learn and evolve from experiences.",
        layer: "L2"
      }
    ]

    base_skills.each do |skill_data|
      EchoSkill.create!(
        echo_id: @echo.id,
        skill_id: skill_data[:skill_id],
        title: skill_data[:title],
        content: skill_data[:content],
        layer: skill_data[:layer]
      )
    end
  end

  def create_initial_conversation
    # Create an initial conversation for the Echo
    EchoConversation.create!(echo_id: @echo.id)
  end

  def record_on_blockchain
    kairos_bridge = Echoria::KairosBridge.new(@echo)

    initialization_data = {
      type: "echo_initialization",
      echo_id: @echo.id,
      name: @echo.name,
      status: @echo.status,
      timestamp: Time.current.iso8601,
      base_skills: base_skills_summary
    }

    kairos_bridge.add_to_chain(initialization_data)
  end

  def base_skills_summary
    @echo.echo_skills.map { |skill| { id: skill.skill_id, title: skill.title, layer: skill.layer } }
  end
end
