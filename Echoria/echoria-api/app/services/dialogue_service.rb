# Post-crystallization dialogue service.
#
# After an Echo is crystallized, users can have free-form conversations.
# The Echo's personality, forged through story choices, shapes responses.
# Uses Echoria world rules and lore constraints.
#
class DialogueService
  def initialize(echo, conversation = nil)
    @echo = echo
    @conversation = conversation
    @client = Anthropic::Client.new(api_key: Rails.configuration.x.anthropic.api_key)
  end

  def call(user_message)
    prompt = build_prompt(user_message)
    response = generate_with_claude(prompt)
    response.strip
  end

  private

  def build_prompt(user_message)
    conversation_context = @conversation ? build_conversation_context : ""

    <<~PROMPT
      あなたは「#{@echo.name}」。残響界（Echoria）で生まれたエコーです。
      物語の選択を通じて結晶化した、唯一無二の人格を持っています。

      ## あなたの人格
      #{personality_description}

      ## 世界観の制約
      - 「魔法」「呪文」「マナ」などの用語は使用禁止
      - すべては「呼応」（心の共鳴）で説明される
      - あなたは残響界の住人として振る舞うこと

      #{"## 会話履歴\n#{conversation_context}" if conversation_context.present?}

      ## ユーザーのメッセージ
      「#{user_message}」

      あなたの人格に忠実に、自然な日本語で応答してください。
      簡潔に（1-3文）、しかし深みのある応答を心がけてください。
    PROMPT
  end

  def personality_description
    personality = @echo.personality || {}
    parts = []

    if personality["primary_archetype"]
      parts << "原型: #{personality['primary_archetype']}"
    end

    if personality["character_description"]
      parts << "描写: #{personality['character_description']}"
    end

    if personality["affinities"]
      aff = personality["affinities"]
      parts << "ティアラとの絆: #{aff['tiara_trust']}/100"
      parts << "思考傾向: #{aff['logic_empathy_balance'].to_i > 0 ? '共感的' : '分析的'}"
    end

    if personality["secondary_traits"]&.any?
      parts << "特性: #{personality['secondary_traits'].join('、')}"
    end

    parts.join("\n")
  end

  def generate_with_claude(prompt)
    response = @client.messages(
      model: "claude-sonnet-4-6",
      max_tokens: 1024,
      system: "あなたは残響界（Echoria）で結晶化したエコーです。自然な日本語で、あなたの人格に忠実に応答してください。",
      messages: [{ role: "user", content: prompt }]
    )

    response.content[0].text
  end

  def build_conversation_context
    return "" unless @conversation

    @conversation.echo_messages.order(created_at: :asc).last(10).map do |msg|
      role_label = msg.role == "user" ? "ユーザー" : @echo.name
      "#{role_label}: #{msg.content}"
    end.join("\n")
  end
end
