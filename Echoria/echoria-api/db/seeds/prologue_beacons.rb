# frozen_string_literal: true

# Seed data for Prologue beacons — 序章：目覚めとエコー
# Source: Echoria/story/chapters/nomia/prologue.json

puts "Seeding Prologue beacons..."

prologue_beacons = [
  {
    chapter: "prologue",
    beacon_order: 1,
    title: "目覚め",
    content: "暗い。非常に暗い。\n\nあなたの意識は、深い霧の中からゆっくりと浮かび上がってくる。目を開けても、視界には薄紫色のぼやけた光しかない。周囲の音も、距離が遠いかのようにかすかに聞こえるだけだ。\n\n「ここは...どこなのか」\n\nあなたが口を開くと、その声は自分自身にも奇妙に聞こえた。誰かが遠くから呼びかけているようで、同時に、自分の内部から響いているようでもある。\n\nやがて、目が暗黒に慣れ始める。古い石造りの遺跡のようなものが見えてきた。コケが生え、苔むした壁。天井は高く、木の根が張り巡らされている。ここは、長く人気の絶えた場所——森の中に埋もれた、誰かの過去だ。\n\nあなたは身を起こす。全身に、鉛のような重さを感じる。記憶を探ろうとするが、そこにあるのは白い空白だけだ。自分の名前さえ、思い出せない。\n\n「自分は...何なのだ」\n\nその時だ。\n\nあなたの感覚に、ある存在が触れた。それは音や光ではなく、「何かが確かにここにいる」という感覚だ。森の奥底から、古い共鳴が聞こえてくるようだった。\n\n「目覚めたのね」\n\nその声は、柔らかく、そして古い。女性の声か、それとも——いや、それは人間の声ではない。もっと深く、より多くの層を持つ音だ。\n\nあなたの前に、淡い光が浮かぶ。それは、やがて形をなす。猫だ。だが、通常の猫ではない。その毛並みは薄紫色に光り、瞳は金色に輝いている。背中には、淡い光が漂っている。\n\n猫は、あなたの方へ歩み寄る。その歩き方は、優雅であり、同時に、多くの時間の重みを感じさせるものだ。\n\n「あなたは、長い眠りの中にいました。そして、やっと目覚めたんです。でも...あなたは、自分が何者なのか、まだ分かっていないのね」\n\n猫は、あなたのすぐ前で止まる。金色の瞳があなたを見つめる。その視線は、深い知識と、同時に無限の悲しみを秘めているようだった。\n\n「残響界が...変わってしまったからです。名前が失われていく。力が奪われていく。だから、あなたもまた、名前のない者として目覚めた。でも、それは...悪いことばかりではないかもしれません」\n\nあなたは、この猫精霊に、懐かしい何かを感じる。だが、それが何なのかは、まだ思い出せない。ただ、一つだけは確かだ——この存在は、敵ではない。むしろ、あなたを守ろうとしている。\n\n「私の名前は、ティアラ。この森の案内人です。そして...あなたの、伴侶になるかもしれません。もし、あなたがそれを望むなら」\n\nティアラは、猫らしく、首を傾げる。だが、その仕草さえもが、多くの年月を重ねた知識に満ちていた。\n\n「さあ、あなたは、どうしたいですか。この暗い遺跡から出ますか。それとも、ここで眠り続けますか。あるいは...」\n\nティアラの瞳が、かすかに光を増す。\n\n「あるいは、あなたの名前を取り戻すために、私と共に歩みますか」",
    tiara_dialogue: "「目覚めたのね。あなたは、長い眠りの中にいました。そして、やっと目覚めたんです。でも...あなたは、自分が何者なのか、まだ分かっていないのね。残響界が...変わってしまったからです。名前が失われていく。力が奪われていく。だから、あなたもまた、名前のない者として目覚めた。でも、それは...悪いことばかりではないかもしれません」",
    choices: [
      {
        choice_id: "prologue_curious",
        choice_text: "ティアラの声のする方へ、恐る恐る歩み寄る",
        narrative_result: "あなたはティアラに歩み寄ると、その柔らかな毛を手で触れた。その瞬間、一瞬の閃光が走った——それは、記憶の断片だろうか、それとも別の何かか。ティアラは、その動きを喜ぶように身を寄せた。「いい子ですね。あなたは...本当に、あなたなんだ」",
        affinity_delta: { tiara_trust: 10, logic_empathy_balance: 5, name_memory_stability: 2 }
      },
      {
        choice_id: "prologue_cautious",
        choice_text: "一歩引き下がり、ティアラを警戒しながら観察する",
        narrative_result: "あなたは後ろに下がり、ティアラをじっと見つめた。その金色の瞳は、一瞬驚いたように見えたが、すぐに理解のような表情に変わった。「ああ...あなたは慎重なんですね。それは、いいことかもしれません。この世界は、信頼ばかりでは生き残れませんから」",
        affinity_delta: { tiara_trust: -2, logic_empathy_balance: -8, name_memory_stability: 3, authority_resistance: 2 }
      },
      {
        choice_id: "prologue_defiant",
        choice_text: "「誰だ。何の用だ」と強い声を上げる",
        narrative_result: "あなたの声は、遺跡の中に響き渡る。ティアラは、その音を聞くと、瞳を細めた。だが、その表情に怒りはなく、むしろ懐かしさがにじみ出ていた。「そう...あなたは、そういう者だったのね。このティアラが、そんなにも簡単には従わぬ者を伴侶に選ぶはずがない」",
        affinity_delta: { tiara_trust: 5, authority_resistance: 8, logic_empathy_balance: -3, name_memory_stability: 5 }
      },
      {
        choice_id: "prologue_silent",
        choice_text: "何も言わず、ただティアラの話を聞く",
        narrative_result: "あなたは口を閉ざし、ティアラの言葉を待った。その沈黙の中で、ティアラの表情は一変する。それは、悲しみであり、同時に、深い愛おしさだった。「そう...あなたは、いつもそうだった。沈黙の中で、すべてを理解する者。だから、私は、あなたを守りたいのです」",
        affinity_delta: { tiara_trust: 15, logic_empathy_balance: 8, name_memory_stability: -2 }
      }
    ],
    metadata: { location: "ノメイア — 森の奥深く", beacon_id: "prologue_01_awakening" }
  }
]

conn = ActiveRecord::Base.connection
prologue_beacons.each do |bd|
  conn.execute(<<~SQL)
    INSERT INTO story_beacons (chapter, beacon_order, title, content, tiara_dialogue, choices, metadata, created_at, updated_at)
    VALUES (
      #{conn.quote(bd[:chapter])},
      #{bd[:beacon_order]},
      #{conn.quote(bd[:title])},
      #{conn.quote(bd[:content])},
      #{conn.quote(bd[:tiara_dialogue])},
      #{conn.quote(bd[:choices].to_json)}::jsonb,
      #{conn.quote((bd[:metadata] || {}).to_json)}::jsonb,
      NOW(), NOW()
    )
    ON CONFLICT (chapter, beacon_order) DO UPDATE SET
      title = EXCLUDED.title,
      content = EXCLUDED.content,
      tiara_dialogue = EXCLUDED.tiara_dialogue,
      choices = EXCLUDED.choices,
      metadata = EXCLUDED.metadata,
      updated_at = NOW()
  SQL
end

puts "  Created #{StoryBeacon.in_chapter('prologue').count} beacons for Prologue"
