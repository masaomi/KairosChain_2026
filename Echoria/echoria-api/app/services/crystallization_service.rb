# Crystallizes an Echo at the end of Chapter 1.
#
# When the user completes the story chapter, their choices and affinity
# values are consolidated into a permanent Echo personality. This is the
# "meta-reveal" moment: the user discovers that their journey has given
# birth to a unique AI companion.
#
# Echoria 5-axis → Echo archetype mapping:
#   tiara_trust           → Bond depth (守護者 / 探索者)
#   logic_empathy_balance → Thinking style (分析者 / 共感者)
#   name_memory_stability → Identity coherence (確信者 / 流動者)
#   authority_resistance  → Stance (反逆者 / 調和者)
#   fragment_count        → Collected wisdom
#
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
    affinity = @session.affinity || {}
    calc = AffinityCalculatorService.new(@session)

    traits = {
      primary_archetype: determine_archetype(affinity),
      secondary_traits: determine_secondary_traits(affinity),
      affinities: affinity,
      affinity_summary: calc.affinity_summary,
      strengths: identify_strengths(affinity),
      growth_areas: identify_growth_areas(affinity),
      story_arc: {
        chapter: @session.chapter,
        scenes_experienced: @session.scene_count,
        journey_completion: calculate_completion_percentage,
        resonance_score: calc.affinity_summary[:total_resonance]
      }
    }

    @echo.update!(personality: traits)
  end

  def generate_character_description
    prompt = <<~PROMPT
      あなたは「残響界（Echoria）」のエコー結晶化AIです。

      以下のアフィニティ値に基づいて、このエコーの「人格の結晶」を日本語で描写してください。
      2-3文の詩的で哲学的な人格描写を生成してください。

      ## エコーのアフィニティ
      #{@session.affinity.to_json}

      ## 原型: #{@echo.personality["primary_archetype"]}

      ## 物語の旅路
      - 章: #{@session.chapter}
      - 体験シーン数: #{@session.scene_count}

      ## 注意事項
      - 「魔法」「呪文」などの禁止用語は使用しないこと
      - 「呼応」「名前の力」「カケラ」の世界観で描写すること
      - 静謐で哲学的、しかし希望のある語り口で

      描写のみを返してください。説明や前置きは不要です。
    PROMPT

    response = @client.messages(
      model: "claude-sonnet-4-20250514",
      max_tokens: 300,
      system: "あなたは残響界のエコー結晶化AIです。詩的で哲学的な人格描写を生成してください。",
      messages: [{ role: "user", content: prompt }]
    )

    description = response.content[0].text

    @echo.personality = @echo.personality.merge(
      "character_description" => description,
      "crystallized_at" => Time.current.iso8601
    )
    @echo.save!
  end

  def update_echo_status
    @session.update!(status: :completed)
    @echo.update!(status: :crystallized)
  end

  def record_crystallization_on_blockchain
    bridge = @echo.kairos_chain
    return unless bridge&.available?

    crystallization_data = {
      type: "crystallization",
      echo_id: @echo.id,
      chapter: @session.chapter,
      final_personality: @echo.personality,
      affinities: @session.affinity,
      scenes_count: @session.scene_count,
      timestamp: Time.current.iso8601
    }

    bridge.add_to_chain(crystallization_data)
  rescue StandardError => e
    Rails.logger.error("[Crystallization] KairosChain record failed: #{e.message}")
  end

  # Echoria archetype mapping based on 5-axis affinity
  def determine_archetype(affinity)
    trust = affinity["tiara_trust"].to_i
    empathy = affinity["logic_empathy_balance"].to_i
    stability = affinity["name_memory_stability"].to_i
    resistance = affinity["authority_resistance"].to_i

    # Primary archetype from dominant axis
    archetypes = []
    archetypes << ["守護者（Guardian）", trust] if trust >= 70
    archetypes << ["探索者（Seeker）", 100 - trust] if trust < 40
    archetypes << ["共感者（Empath）", empathy + 50] if empathy > 15
    archetypes << ["分析者（Analyst）", 50 - empathy] if empathy < -15
    archetypes << ["確信者（Anchor）", stability] if stability >= 70
    archetypes << ["流動者（Drifter）", 100 - stability] if stability < 40
    archetypes << ["反逆者（Rebel）", resistance + 50] if resistance > 15
    archetypes << ["調和者（Harmonizer）", 50 - resistance] if resistance < -15

    if archetypes.empty?
      "均衡者（Balanced）"
    else
      archetypes.max_by(&:last).first
    end
  end

  def determine_secondary_traits(affinity)
    traits = []
    traits << "記憶の守り手" if affinity["fragment_count"].to_i >= 20
    traits << "呼応の深き者" if affinity["tiara_trust"].to_i >= 80
    traits << "名前の安定者" if affinity["name_memory_stability"].to_i >= 80
    traits << "孤高の思索者" if affinity["logic_empathy_balance"].to_i < -30
    traits << "心の共鳴者" if affinity["logic_empathy_balance"].to_i > 30
    traits
  end

  def identify_strengths(affinity)
    strengths = []
    strengths << "深い信頼" if affinity["tiara_trust"].to_i > 65
    strengths << "豊かな共感力" if affinity["logic_empathy_balance"].to_i > 20
    strengths << "鋭い分析力" if affinity["logic_empathy_balance"].to_i < -20
    strengths << "安定した自己" if affinity["name_memory_stability"].to_i > 65
    strengths << "独立した精神" if affinity["authority_resistance"].to_i > 20
    strengths << "記憶の収集" if affinity["fragment_count"].to_i > 15
    strengths
  end

  def identify_growth_areas(affinity)
    areas = []
    areas << "信頼の構築" if affinity["tiara_trust"].to_i < 35
    areas << "感情の理解" if affinity["logic_empathy_balance"].to_i < -30
    areas << "論理的思考" if affinity["logic_empathy_balance"].to_i > 30
    areas << "自己の確立" if affinity["name_memory_stability"].to_i < 35
    areas << "記憶の回収" if affinity["fragment_count"].to_i < 5
    areas
  end

  def calculate_completion_percentage
    [(@session.scene_count / 20.0 * 100).round(2), 100].min
  end
end
