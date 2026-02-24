class StoryGeneratorService
  def initialize(story_session, user_choice = nil)
    @session = story_session
    @choice = user_choice
    @echo = story_session.echo
    @client = Anthropic::Client.new(api_key: Rails.configuration.x.anthropic.api_key)
  end

  def call
    prompt = build_prompt
    response = generate_with_claude(prompt)
    parse_response(response)
  end

  private

  def build_prompt
    <<~PROMPT
      You are a narrative storytelling AI for "Echoria," an interactive fiction game where a user guides their AI persona (the Echo) through story choices.

      WORLD CONTEXT:
      - Setting: Dynamic, responsive narrative world shaped by user choices and the Echo's personality
      - Mechanic: User makes choices that affect the Echo's growth and personality
      - Affinity System: courage, wisdom, compassion, innovation, harmony (0-100 scale, starts at 0)

      CURRENT ECHO:
      Name: #{@echo.name}
      Status: #{@echo.status}
      Personality: #{@echo.personality.to_json}
      Current Affinities: #{@session.affinity.to_json}

      CURRENT STORY STATE:
      Chapter: #{@session.chapter}
      Scene Count: #{@session.scene_count}
      Current Beacon: #{@session.current_beacon&.title || "Unknown"}
      Previous Scenes Summary: #{scenes_summary}

      #{"USER'S CHOICE: #{@choice['text']}" if @choice}

      GENERATE:
      1. A narrative segment (2-3 sentences) continuing the story
      2. The Echo's internal response/action to the choice
      3. How this affects the Echo's affinities (JSON: {courage: -5, wisdom: +10, etc.})
      4. The scene type: exposition, decision, consequence, or revelation

      Format your response as JSON:
      {
        "narrative": "string (story continuation)",
        "echo_action": "string (what the Echo does/thinks)",
        "affinity_delta": {object with courage, wisdom, compassion, innovation, harmony as ±integers},
        "scene_type": "exposition|decision|consequence|revelation"
      }
    PROMPT
  end

  def generate_with_claude(prompt)
    response = @client.messages(
      model: "claude-3-5-sonnet-20241022",
      max_tokens: 1024,
      system: "You are a narrative AI generating interactive fiction content. Respond ONLY with valid JSON.",
      messages: [
        { role: "user", content: prompt }
      ]
    )

    response.content[0].text
  end

  def parse_response(response_text)
    parsed = JSON.parse(response_text)

    {
      narrative: parsed["narrative"],
      echo_action: parsed["echo_action"],
      affinity_delta: parse_affinity_delta(parsed["affinity_delta"]),
      scene_type: parsed["scene_type"] || "exposition"
    }
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse Claude response: #{response_text}")
    default_response
  end

  def parse_affinity_delta(delta_data)
    {
      courage: delta_data&.dig("courage").to_i || 0,
      wisdom: delta_data&.dig("wisdom").to_i || 0,
      compassion: delta_data&.dig("compassion").to_i || 0,
      innovation: delta_data&.dig("innovation").to_i || 0,
      harmony: delta_data&.dig("harmony").to_i || 0
    }
  end

  def default_response
    {
      narrative: "The story continues in mysterious ways...",
      echo_action: "The Echo contemplates the unfolding narrative.",
      affinity_delta: { courage: 0, wisdom: 0, compassion: 0, innovation: 0, harmony: 0 },
      scene_type: "exposition"
    }
  end

  def scenes_summary
    @session.story_scenes.ordered.last(3).map do |scene|
      "[Scene #{scene.scene_order}] #{scene.narrative}"
    end.join("\n")
  end
end
