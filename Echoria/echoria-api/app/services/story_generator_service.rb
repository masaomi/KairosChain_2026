# Generates AI-driven narrative scenes between beacons.
#
# Uses the Echoria 5-axis affinity system, Tiara's character profile,
# and lore constraints to produce rich, immersive story content with
# dialogue exchanges between characters.
#
class StoryGeneratorService
  AFFINITY_AXES = %w[tiara_trust logic_empathy_balance name_memory_stability authority_resistance fragment_count].freeze

  # Tiara's trust-level behavior profiles
  TIARA_TRUST_PROFILES = {
    wary: {
      range: 0..20,
      label: "警戒段階",
      behavior: "距離を取り、ぼかした答えをする。不安そうな目でエコーを観察している。時折テストするような問いかけをする。",
      speech: "です/ます調。短い。質問に質問で返す。沈黙が多い。",
      humor: "皮肉めいた独り言。「...まあ、あなたの勝手ですけど」のような突き放すユーモア。",
      sample: "「あなたは...本当は誰なのですか」「約束をしても、それを守る者かどうか...まだ私には分かりません」",
      pronoun: "あなた"
    },
    cautious: {
      range: 21..40,
      label: "用心段階",
      behavior: "エコーの側に寄ることが増える。いたずらをしかけ反応を見る。過去について、ほんのかすかなヒントを与える。",
      speech: "少しずつ砕けるが、基本はです/ます。時折詩的な比喩を使う。",
      humor: "いたずら好きが顔を出す。わざと的外れなことを言って反応を楽しむ。「知っていますか？ 私、嘘をつくのが下手なんです。...嘘ですけど」",
      sample: "「あなたも、何かを失ったのですね。そういう目をしている」「この石——呼応石といいますが、知っていますか？」",
      pronoun: "あなた"
    },
    friendship: {
      range: 41..60,
      label: "友情段階",
      behavior: "一緒にいることを楽しむ。エコーの判断を尊重する。初めて恐れや悲しみを語り始める。エコーを守るために行動する。",
      speech: "自然な会話。時折くすくす笑う。感情が言葉に滲む。",
      humor: "温かいからかい。エコーの癖を指摘して笑う。「また眉間に皺を寄せて...そんな顔をすると、石まで心配しますよ」",
      sample: "「あなたと一緒にいると、時間の流れが違う...そう感じるのです」「私は、あなたのことを...守りたい」",
      pronoun: "あなた（時折、君）"
    },
    deep_bond: {
      range: 61..80,
      label: "絆段階",
      behavior: "連携が完全に同期する。過去の重要な知識を共有し始める。エコーの決断に全面的に従う。自分の力を惜しまず使う。",
      speech: "砕けた口調と詩的表現が混ざる。言葉より視線や行動で伝える。",
      humor: "信頼に満ちた軽口。「君がそう言うなら、世界が間違っていても構いません。...冗談ですよ。半分は」",
      sample: "「君は...私の最後の希望なのかもしれない」「名前とは何か。本当は、君もうっすら感じているのではないですか」",
      pronoun: "君"
    },
    union: {
      range: 81..100,
      label: "結合段階",
      behavior: "心の中の最大の秘密を打ち明ける。すべての仮面を外す。言葉を必要としない。瞳を交わすだけで互いを理解する。",
      speech: "最小限の言葉。沈黙が会話。時に「にゃ」が漏れる（感情の溢れ）。",
      humor: "穏やかな微笑みとともに。「もう、隠すこともないから——にゃ、今のは忘れてください」",
      sample: "「君と私は、もう同じ岸辺にいる。だから、私は怖くない」「すべての秘密を君に預ける」",
      pronoun: "君"
    }
  }.freeze

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
      あなたは「残響界（Echoria）」の物語を紡ぐナラティブ生成AIです。
      読者が没頭できる、情緒豊かで詩的な物語を生成してください。

      ## 世界設定
      - 残響界：名前が存在の力を持つ世界。名折れ（名前が力を失う現象）が進行中。
      - 呼応石：本物の心の繋がりにだけ反応する結晶。道具や武器ではない。呼応石は呼応の証人であり、道具ではない。
      - カケラ：名折れで消えた人々の記憶の断片。温かく、触ると記憶が流れ込む。カケラは人の残響であり、常に敬意をもって扱う。
      - 呼応：二つの存在の心と意志が完全に同期する状態。愛とは限らないが、愛から生まれることもある。
      - 名折れの段階：①名前が聞こえにくくなる → ②身体が半透明になる → ③完全な消滅 → ④存在した可能性すら消える
      - 時間はカイロス（意味ある瞬間）で流れ、クロノス（直線的時間）ではない。

      ## 禁止用語
      magic, spell, mana, wizard, sorcery, chosen one, special powers は使用禁止。
      日本語でも：魔法、魔力、呪文、魔術師、選ばれし者 は禁止。
      この世界に「魔法」は存在しない。すべては「呼応」（心の共鳴）で説明される。

      ## ティアラ — 猫精霊の伴侶キャラクター
      - **外見**：薄紫色の毛並みの猫。金色の瞳に知性と古さが宿る。背中に淡い光が漂う。人間の膝まで程度の大きさ。
      - **本質**：外見は若いが数百年の記憶を持つ古い存在。深い知識と古い悲しみを内に秘めている。
      - **性格の三側面**：
        ① 表面：好奇心旺盛で遊び心がある。いたずら好きで予測不可能。くすくす笑う。
        ② 慮る面：エコーの苦しみに気付くと真摯になる。言葉が少なくなり、一語一語に力が込められる。
        ③ 秘密の面：世界の古い歴史を知っている。だが易々と口にしない。エコーが自分で気付くことが大切だと感じている。
      - **ユーモア**：ティアラは古い存在だが、ユーモアを忘れない。皮肉、いたずら、温かいからかい、的外れなボケなど、信頼度に応じたユーモアで場を和ませる。深刻な場面でも、ふっと力を抜く一言を入れることがある。
      - **話し方**：「にゃ」はめったに使わない（感情が溢れた時だけ）。詩的な表現を好む。重要なことの前に長い沈黙を置く。
      - **特別な力**：カケラの感知、名折れの進行察知、古い言葉の力、不完全な心の読み取り。
      - **二人称**：エコーを「#{tiara_pronoun}」と呼ぶ（現在の信頼度に基づく）。

      ### 現在のティアラの信頼度: #{tiara_trust_value}/100（#{current_trust_profile[:label]}）
      #{current_trust_profile[:behavior]}
      話し方: #{current_trust_profile[:speech]}
      ユーモアの傾向: #{current_trust_profile[:humor]}
      会話例: #{current_trust_profile[:sample]}

      ## 主人公: 「#{echo_name}」（プレイヤーの分身）
      - 名前は「#{echo_name}」。ティアラや他のキャラクターはこの名前で呼びかけてください。
      - 記憶を失った存在。自分が何者かわからない。
      - 性格は5つのアフィニティ軸から浮かび上がる（固定されたキャラシートはない）。
      - #{echo_name}の力は戦闘や魔法ではなく、真の繋がりと本物の存在感にある。
      - #{echo_name}の対話は現在のアフィニティ値を反映させる。
      - 短い言葉、問いかけ、沈黙が重要。

      ## NPC描写ルール
      - 名折れに影響されたNPCは悲劇的に描く（恐ろしくではなく、哀しく）。
      - NPCは文を完成できなかったり、記憶が曖昧だったりする。
      - エコーが名前を呼ぶことで、NPCは安堵と感謝を示す。

      ## 文体・雰囲気
      - 静謐で哲学的、しかし希望のある語り口
      - 短い文と長い文を混ぜ、リズムを変化させる
      - 感情は環境や行動で描写し、直接述べない（「悲しかった」ではなく、風景や仕草で表現）
      - 「...」は頻繁に使用（余韻、感情の溢れ、言葉にならない想い）
      - 比喩は音、光、共鳴に関連するものを使う
      - 天候や光は感情のビートを反映させる
      - 静寂と余白を大切にする

      ## 現在の状態
      章: #{@session.chapter}
      現在のビーコン: #{@session.current_beacon&.title || "不明"}
      場所: #{@session.current_beacon&.metadata&.dig("location") || "不明"}
      シーン数: #{@session.scene_count}
      アフィニティ: #{@session.affinity.to_json}

      #{choice_context}

      直近のシーン:
      #{scenes_summary}

      ## 生成要件（重要）
      **没入感のある物語を簡潔に生成してください。**

      以下のJSON形式で応答してください:
      {
        "narrative": "情景描写と心理描写を含む地の文（日本語、5-10文程度。環境・空気・光・音を詩的に描写し、キャラクターの内面を行動や仕草で表現する）",
        "dialogue": [
          {"speaker": "ティアラ", "text": "台詞", "tone": "感情のトーン（例: playful, gentle, teasing, solemn, whisper, humorous）"},
          {"speaker": "#{echo_name}", "text": "台詞（短く、問いかけが多い。沈黙は「...」で表現）", "tone": "感情のトーン"},
          {"speaker": "ティアラ", "text": "返しの台詞", "tone": "感情のトーン"}
        ],
        "echo_inner": "#{echo_name}の内面の声（2-4文。記憶の断片、自問、感覚的な描写）",
        "tiara_inner": "ティアラが見せなかった本心（1-2文。古い記憶、隠された感情、エコーへの想い）",
        "affinity_delta": {
          "tiara_trust": ±整数 (現在値#{tiara_trust_value}。0-100の範囲に収まるように),
          "logic_empathy_balance": ±整数 (-50～+50),
          "name_memory_stability": ±整数 (0-100),
          "authority_resistance": ±整数 (-50～+50),
          "fragment_count": 0または1または2（カケラに触れた・記憶の断片を感じた・消えかけた存在と呼応した場面では1。特に深い呼応・重要な記憶の発見では2。通常の会話では0）
        },
        "scene_type": "generated"
      }

      ### dialogueの注意点
      - 2-5往復の自然な会話を含めてください。
      - ティアラの性格三側面（遊び心・慮り・秘密）を適切に混ぜてください。
      - **ティアラにはユーモアを忘れずに**。深刻な場面でも、ふっと力を抜く一言やいたずらな視線を入れてください。
      - NPCが場にいる場合は、NPCとの会話も含めてください。
      - #{echo_name}の台詞は短く、時に沈黙（「...」）を使ってください。
      - ティアラの台詞は現在の信頼度レベル（#{current_trust_profile[:label]}）に合わせてください。

      JSONのみを返してください。説明や前置きは不要です。
    PROMPT
  end

  def choice_context
    return "" unless @choice

    if @choice.is_a?(Hash) && @choice["input_type"] == "free_text"
      text = @choice["choice_text"] || @choice["text"]
      <<~CTX
        エコーの言葉: 「#{text}」

        ※ 上記はプレイヤーが自由入力したテキストです。
        - テキストの感情やニュアンスを汲み取り、affinity_deltaに反映してください。
        - 共感的・感情的な言葉 → logic_empathy_balance を+方向に
        - 分析的・知的な言葉 → logic_empathy_balance を-方向に
        - ティアラへの親愛 → tiara_trust を+方向に
        - 反抗的・自立的な言葉 → authority_resistance を+方向に
        - 自己探求・記憶に関する言葉 → name_memory_stability を+方向に
      CTX
    else
      text = @choice.is_a?(Hash) ? (@choice["choice_text"] || @choice["text"]) : @choice.to_s
      "プレイヤーの選択: #{text}"
    end
  end

  def generate_with_claude(prompt)
    client = Anthropic::Client.new(access_token: Rails.configuration.x.anthropic.api_key, request_timeout: 60)

    response = client.messages(
      parameters: {
        model: ENV.fetch("CLAUDE_MODEL", "claude-sonnet-4-6"),
        max_tokens: 2048,
        system: system_message,
        messages: [{ role: "user", content: prompt }]
      }
    )

    response.dig("content", 0, "text")
  end

  def system_message
    "あなたは残響界（Echoria）の物語を紡ぐナラティブ生成AIです。" \
    "読者を没頭させる、情緒豊かで詩的な日本語の物語を生成してください。" \
    "キャラクター同士の生きた会話を重視し、特にティアラのユーモアと深みのある性格を活かしてください。" \
    "JSONのみで応答してください。"
  end

  def parse_response(response_text)
    # Strip markdown code fences if present
    clean = response_text.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
    parsed = JSON.parse(clean)

    {
      narrative: parsed["narrative"],
      dialogue: parsed["dialogue"] || [],
      echo_inner: parsed["echo_inner"] || parsed["echo_action"],
      tiara_inner: parsed["tiara_inner"],
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
      narrative: "風が、何かを囁くように吹き抜けた。木々の葉擦れの音が、遠い誰かの呼び声のように響いている。" \
                 "空には薄い雲がかかり、光が斜めに差し込んで、あなたとティアラの影を長く伸ばしていた。" \
                 "呼応石が微かに脈打つように光り、やがて静まった。",
      dialogue: [
        { "speaker" => "ティアラ", "text" => "...静かですね。こういう時は、世界が息を止めているのです。", "tone" => "gentle" },
        { "speaker" => "エコー", "text" => "...", "tone" => "contemplative" },
        { "speaker" => "ティアラ", "text" => "黙っているのも、悪くはありません。...私がお喋りなだけですから。", "tone" => "humorous" }
      ],
      echo_inner: "世界の静けさの中で、自分の存在を確かめるように息をした。何かを思い出しかけて、指先が震えた。",
      tiara_inner: "この沈黙を、私は知っている。ずっと昔にも——。",
      affinity_delta: default_delta,
      scene_type: "fallback"
    }
  end

  def scenes_summary
    scenes = @session.story_scenes.ordered.last(3)
    return "（まだシーンがありません）" if scenes.empty?

    scenes.map { |s| "[Scene #{s.scene_order}] #{s.narrative&.truncate(200)}" }.join("\n")
  end

  # --- Echo & Trust Profile Helpers ---

  def echo_name
    @echo&.name || "エコー"
  end

  def tiara_trust_value
    (@session.affinity || {})["tiara_trust"] || 50
  end

  def current_trust_profile
    trust = tiara_trust_value
    TIARA_TRUST_PROFILES.values.find { |p| p[:range].cover?(trust) } || TIARA_TRUST_PROFILES[:friendship]
  end

  def tiara_pronoun
    current_trust_profile[:pronoun]
  end
end
