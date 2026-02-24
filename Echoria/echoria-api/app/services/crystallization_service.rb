class CrystallizationService
  def initialize(story_session)
    @session = story_session
    @echo = story_session.echo
    @client = Anthropic::Client.new(api_key: Rails.configuration.x.anthropic.api_key)
  end

  def call
    compute_final_personality
    generate_character_description
    update_echo_status
    record_crystallization_on_blockchain
    @echo
  end

  private

  def compute_final_personality
    # Consolidate affinity scores into personality traits
    affinity = @session.affinity || {}

    traits = {
      primary_archetype: determine_archetype(affinity),
      affinities: affinity,
      strengths: identify_strengths(affinity),
      growth_areas: identify_growth_areas(affinity),
      story_arc: {
        chapter: @session.chapter,
        scenes_experienced: @session.scene_count,
        journey_completion: calculate_completion_percentage
      }
    }

    @echo.update(personality: traits)
  end

  def generate_character_description
    prompt = <<~PROMPT
      Based on this Echo's story journey, generate a brief character description (2-3 sentences):

      Personality Traits: #{@echo.personality.to_json}
      Story Chapter: #{@session.chapter}
      Scenes Experienced: #{@session.scene_count}
      Final Affinities: #{@session.affinity.to_json}

      Create a vivid, narrative description of who this Echo has become.
    PROMPT

    response = @client.messages(
      model: "claude-3-5-sonnet-20241022",
      max_tokens: 300,
      system: "You are a character development AI. Generate vivid, authentic character descriptions.",
      messages: [{ role: "user", content: prompt }]
    )

    description = response.content[0].text

    @echo.personality = @echo.personality.merge({
      character_description: description,
      crystallized_at: Time.current.iso8601
    })

    @echo.save
  end

  def update_echo_status
    @session.update(status: :completed)
    @echo.update(status: :crystallized)
  end

  def record_crystallization_on_blockchain
    kairos_bridge = Echoria::KairosBridge.new(@echo)

    crystallization_data = {
      type: "crystallization",
      echo_id: @echo.id,
      chapter: @session.chapter,
      final_personality: @echo.personality,
      affinities: @session.affinity,
      scenes_count: @session.scene_count,
      timestamp: Time.current.iso8601
    }

    kairos_bridge.add_to_chain(crystallization_data)
  end

  def determine_archetype(affinity)
    return "Balanced" if affinity.values.all? { |v| v.abs <= 10 }

    max_key = affinity.max_by { |_k, v| v }&.first
    archetype_map = {
      "courage" => "Warrior",
      "wisdom" => "Sage",
      "compassion" => "Healer",
      "innovation" => "Creator",
      "harmony" => "Diplomat"
    }

    archetype_map[max_key] || "Seeker"
  end

  def identify_strengths(affinity)
    affinity.select { |_k, v| v > 15 }.keys.map(&:to_s)
  end

  def identify_growth_areas(affinity)
    affinity.select { |_k, v| v < -15 }.keys.map(&:to_s)
  end

  def calculate_completion_percentage
    # Assuming 20 scenes is a full chapter completion
    [(@session.scene_count / 20.0 * 100).round(2), 100].min
  end
end
