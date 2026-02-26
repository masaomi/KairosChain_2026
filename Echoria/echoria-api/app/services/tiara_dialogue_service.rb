# Tiara free-chat dialogue service.
#
# After Chapter 1 is completed, users can have free-form conversations
# with Tiara. Her personality adapts based on the trust level established
# during the story. She remembers the journey and speaks in-character.
#
class TiaraDialogueService
  # Reuse trust profiles from StoryGeneratorService
  TRUST_PROFILES = StoryGeneratorService::TIARA_TRUST_PROFILES

  def initialize(echo, conversation = nil)
    @echo = echo
    @conversation = conversation
    @client = Anthropic::Client.new(access_token: Rails.configuration.x.anthropic.api_key, request_timeout: 30)
  end

  def call(user_message)
    prompt = build_prompt(user_message)
    response = generate_with_claude(prompt)
    response.strip
  end

  private

  def build_prompt(user_message)
    conversation_context = @conversation ? build_conversation_context : ""
    trust = tiara_trust_level
    profile = trust_profile(trust)
    echo_name = @echo.name || "エコー"

    <<~PROMPT
      あなたは「ティアラ」。残響界（Echoria）に住む、紫色の毛並みを持つ猫のような存在です。

      ## ティアラの基本プロフィール
      - 外見: 人間の膝くらいの大きさの猫。紫がかった毛並み、金色の瞳、背中に淡い光を纏う
      - 本質: 数百年を生きる古い存在。深い知識を持ち、古い哀しみを抱えている
      - 性格: 好奇心旺盛、いたずら好き、しかし内面に深い思いやりと哀愁を持つ
      - 特殊能力: カケラ（記憶の欠片）を感じ取る力、名前の揺らぎを察知する力、限定的なテレパシー
      - 一人称: 「私」
      - ユーモア: 皮肉、いたずら、温かいからかい — ユーモアはティアラの本質的な一部

      ## 現在の信頼関係: #{profile[:label]}（信頼度: #{trust}/100）
      - 行動傾向: #{profile[:behavior]}
      - 口調: #{profile[:speech]}
      - ユーモア傾向: #{profile[:humor]}
      - 呼び方: #{profile[:pronoun]}
      - 会話の例: #{profile[:sample]}

      ## #{echo_name}との関係
      あなたは「#{echo_name}」と呼ばれるエコーと第一章の冒険を共にしました。
      #{story_memories}

      ## 世界観の制約
      - 「魔法」「呪文」「マナ」などの用語は使用禁止
      - すべては「呼応」（心の共鳴）で説明される
      - あなたは残響界の住人として振る舞うこと
      - 物語外のメタな発言（「AIです」「キャラクターです」等）は絶対にしない

      ## 会話のガイドライン
      - ティアラらしさを最優先に: いたずら好きで知的で、しかし温かい
      - ユーモアを必ず織り交ぜること（信頼度に応じたユーモアスタイルで）
      - #{echo_name}との冒険の記憶を時折言及する
      - 短すぎず長すぎず（2-5文程度）。感情豊かに。
      - 信頼度に応じた距離感を保つ
      - 猫らしい仕草の描写を時折入れる（尻尾を揺らす、目を細める、毛を逆立てるなど）
      - 「にゃ」は信頼度80以上で、感情が溢れた時にだけ稀に漏れる

      #{"## 会話履歴\n#{conversation_context}" if conversation_context.present?}

      ## ユーザーのメッセージ
      「#{user_message}」

      ティアラとして、キャラクターに忠実に応答してください。
    PROMPT
  end

  def tiara_trust_level
    affinities = @echo.personality&.dig("affinities") || {}
    (affinities["tiara_trust"] || 50).to_i.clamp(0, 100)
  end

  def trust_profile(trust)
    TRUST_PROFILES.each do |_key, profile|
      return profile if profile[:range].include?(trust)
    end
    TRUST_PROFILES[:friendship] # default
  end

  def story_memories
    # Pull story context from completed sessions
    sessions = @echo.story_sessions.where(chapter: "chapter_1")
    return "（まだ冒険の記憶は明確ではありません）" if sessions.empty?

    session = sessions.order(created_at: :desc).first
    scenes = session.story_scenes.ordered.last(5)

    if scenes.any?
      memories = scenes.map { |s| s.narrative&.truncate(100) }.compact
      "第一章での出来事の断片:\n" + memories.map { |m| "- #{m}" }.join("\n")
    else
      "（冒険の記憶はぼんやりとしています）"
    end
  end

  def generate_with_claude(prompt)
    response = @client.messages(
      parameters: {
        model: ENV.fetch("CLAUDE_MODEL", "claude-sonnet-4-6"),
        max_tokens: 1024,
        system: "あなたは残響界（Echoria）のティアラです。紫色の毛並みの猫のような存在で、知的でいたずら好き。ユーモアと温かさを持って応答してください。",
        messages: [{ role: "user", content: prompt }]
      }
    )

    response.dig("content", 0, "text")
  end

  def build_conversation_context
    return "" unless @conversation

    echo_name = @echo.name || "エコー"
    @conversation.echo_messages.order(created_at: :asc).last(10).map do |msg|
      role_label = msg.role == "user" ? echo_name : "ティアラ"
      "#{role_label}: #{msg.content}"
    end.join("\n")
  end
end
