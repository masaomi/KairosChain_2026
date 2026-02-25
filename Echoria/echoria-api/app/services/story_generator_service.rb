# Generates AI-driven narrative scenes between beacons.
#
# Uses the Echoria 5-axis affinity system and lore constraints
# to produce consistent, world-authentic story content.
#
class StoryGeneratorService
  AFFINITY_AXES = %w[tiara_trust logic_empathy_balance name_memory_stability authority_resistance fragment_count].freeze

  def initialize(story_session, user_choice = nil)
    @session = story_session
    @choice = user_choice
    @echo = story_session.echo
  end

  def call
    prompt = build_prompt
    response = generate_with_claude(prompt)
    parse_response(response)
  rescue StandardError => e
    Rails.logger.error("[StoryGenerator] #{e.class}: #{e.message}")
    fallback_response
  end

  private

  def build_prompt
    <<~PROMPT
      あなたは「残響界（Echoria）」のナラティブ生成AIです。

      ## 世界設定
      - 残響界：名前が存在の力を持つ世界。名折れ（名前が力を失う現象）が進行中。
      - 呼応石：本物の心の繋がりにだけ反応する結晶。道具や武器ではない。
      - カケラ：名折れで消えた人々の記憶の断片。温かく、触ると記憶が流れ込む。

      ## 禁止用語
      magic, spell, mana, wizard, sorcery, chosen one, special powers は使用禁止。
      この世界に「魔法」は存在しない。すべては「呼応」（心の共鳴）で説明される。

      ## 文体
      - 静謐で哲学的、しかし希望のある語り口
      - 短い文と長い文を混ぜ、リズムを変化させる
      - 感情は環境や行動で描写し、直接述べない
      - 「...」は頻繁に使用（余韻、感情の溢れ）

      ## 現在の状態
      章: #{@session.chapter}
      現在のビーコン: #{@session.current_beacon&.title || "不明"}
      シーン数: #{@session.scene_count}
      アフィニティ: #{@session.affinity.to_json}

      #{choice_context}

      直近のシーン:
      #{scenes_summary}

      ## 生成要件
      以下のJSON形式で応答してください:
      {
        "narrative": "物語の続き（日本語、3-5文）",
        "echo_action": "エコーの内面の反応（日本語、1-2文）",
        "affinity_delta": {
          "tiara_trust": ±整数 (0-100の範囲に収まるように),
          "logic_empathy_balance": ±整数 (-50～+50),
          "name_memory_stability": ±整数 (0-100),
          "authority_resistance": ±整数 (-50～+50),
          "fragment_count": 0以上の整数
        },
        "scene_type": "generated"
      }

      JSONのみを返してください。説明や前置きは不要です。
    PROMPT
  end

  def choice_context
    return "" unless @choice
    text = @choice.is_a?(Hash) ? (@choice["choice_text"] || @choice["text"]) : @choice.to_s
    "プレイヤーの選択: #{text}"
  end

  def generate_with_claude(prompt)
    client = Anthropic::Client.new(api_key: Rails.configuration.x.anthropic.api_key)

    response = client.messages(
      model: "claude-sonnet-4-20250514",
      max_tokens: 1024,
      system: "あなたは残響界（Echoria）のナラティブ生成AIです。JSONのみで応答してください。",
      messages: [{ role: "user", content: prompt }]
    )

    response.content[0].text
  end

  def parse_response(response_text)
    # Strip markdown code fences if present
    clean = response_text.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
    parsed = JSON.parse(clean)

    {
      narrative: parsed["narrative"],
      echo_action: parsed["echo_action"],
      affinity_delta: sanitize_affinity_delta(parsed["affinity_delta"]),
      scene_type: "generated"
    }
  rescue JSON::ParserError => e
    Rails.logger.error("[StoryGenerator] JSON parse error: #{e.message}\nRaw: #{response_text}")
    fallback_response
  end

  def sanitize_affinity_delta(delta)
    return default_delta unless delta.is_a?(Hash)

    AFFINITY_AXES.each_with_object({}) do |axis, result|
      result[axis] = delta[axis].to_i
    end
  end

  def default_delta
    AFFINITY_AXES.each_with_object({}) { |axis, h| h[axis] = 0 }
  end

  def fallback_response
    {
      narrative: "風が、何かを囁くように吹き抜けた。あなたとティアラは、静かにその場に立っていた。",
      echo_action: "世界の静けさの中で、あなたは自分の存在を確かめるように息をした。",
      affinity_delta: default_delta,
      scene_type: "fallback"
    }
  end

  def scenes_summary
    scenes = @session.story_scenes.ordered.last(3)
    return "（まだシーンがありません）" if scenes.empty?

    scenes.map { |s| "[Scene #{s.scene_order}] #{s.narrative&.truncate(100)}" }.join("\n")
  end
end
