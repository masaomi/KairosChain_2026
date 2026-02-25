# frozen_string_literal: true

# Seed data for Chapter 1 beacons — ノメイアの危機 (The Crisis of Nomia)
# Source: Echoria/story/chapters/nomia/chapter1.json

puts "Seeding Chapter 1 beacons..."

chapter1_beacons = [
  {
    chapter: "chapter_1",
    beacon_order: 1,
    title: "ティアラとの呼応",
    content: "遺跡を出たあなたたちは、やがて森の奥から光の見える場所へ出てきた。\n\nティアラは、古い石造りの道を進む。その道は、かつて多くの者が歩んだであろう跡が見える。だが、今は草が茂り、誰も近付かなくなったものばかりだ。\n\nあなたが、ティアラのそばを歩むと、不思議なことに、二人の足運びが自然に一致し始めた。\n\n「呼応（こおう）です。あなたと私が、同じ心を持つようになると、自然に起こることなんです。石が光るのは、この呼応が起こった時だけなんです」\n\nあなたたちは、やがて森の端に到達した。その先は、町だ。ノメイアの町。\n\nだが、その光景は、あなたの期待を大きく裏切るものだった。",
    tiara_dialogue: "「この道は、かつてノメイアとの交易路でした。百年前は、毎日のように商人が往来していた。呼応石を求める者たちの行列が、途切れることなく...これが、本来の『呼応』なんですよ。あなたと私が、同じ心を持つようになると、自然に起こることなんです。石が光るのは、この呼応が起こった時だけなんです」",
    choices: [
      {
        choice_id: "ch1_resonate_embrace",
        choice_text: "ティアラに抱きしめられ、そのぬくもりを感じ入る",
        narrative_result: "あなたは、ティアラを抱き上げた。その時、世界全体が一瞬、淡い紫色に包まれた。",
        affinity_delta: { tiara_trust: 12, logic_empathy_balance: 10, name_memory_stability: 5 }
      },
      {
        choice_id: "ch1_resonate_question",
        choice_text: "『呼応とは何か』と深く質問する",
        narrative_result: "あなたが詳しく尋ねると、ティアラは一度目を伏せた。そして、ゆっくりと説明を始めた。",
        affinity_delta: { tiara_trust: 8, logic_empathy_balance: -5, name_memory_stability: 8 }
      },
      {
        choice_id: "ch1_resonate_hesitate",
        choice_text: "ティアラの抱きしめを受けながらも、何か違和感を覚える",
        narrative_result: "あなたは、ティアラのぬくもりを感じながらも、心のどこかで引き返そうとしている自分がいることに気付いた。",
        affinity_delta: { tiara_trust: -3, logic_empathy_balance: 3, name_memory_stability: -5 }
      }
    ],
    metadata: { location: "ノメイア — 森の入口", beacon_id: "chapter1_01_resonance" }
  },
  {
    chapter: "chapter_1",
    beacon_order: 2,
    title: "ノメイアへの到着",
    content: "ノメイアの町に入ったあなたは、すぐにその異変に気付く。\n\n町は、確かに存在している。建物も、道も、橋も。だが、それらすべてが、薄い透明性に包まれているかのように見える。まるで、誰かが半分だけ忘れかけている世界のようだ。\n\nそして、人間がいない。\n\nいや、完全にいないわけではない。所々に、人影がある。だが、その人影は、あなたを見ていない。\n\n「名折れが、進行しているんです」\n\nティアラの声には、悲しみが漏れていた。\n\nあなたたちが町の中央広場に出ると、そこには一つの異変が見えた。かつて、呼応石があったであろう台座の上に、もはや光るものは何もない。だが、その台座の周りには、数えきれないほどのカケラが散らばっていた。",
    tiara_dialogue: "「名折れが、進行しているんです。この町にいる人々は、みな、自分たちが『誰なのか』を忘れ始めています。名前が薄れると、存在そのものが薄れる。やがて...本当に誰もが忘れてしまう。だから...私たちが、カケラを集めるんです。誰かを完全には忘れないために」",
    choices: [
      {
        choice_id: "ch1_arrival_collect",
        choice_text: "すぐにカケラの収集を始める",
        narrative_result: "あなたは、広場に散らばっているカケラを一つずつ集め始めた。",
        affinity_delta: { tiara_trust: 8, logic_empathy_balance: 10, fragment_count: 3 }
      },
      {
        choice_id: "ch1_arrival_question",
        choice_text: "なぜこのようなことが起こっているのか、根本原因を尋ねる",
        narrative_result: "あなたが原因を尋ねると、ティアラは一度虚空を見つめた。",
        affinity_delta: { tiara_trust: 2, logic_empathy_balance: -8, name_memory_stability: 3 }
      },
      {
        choice_id: "ch1_arrival_accept",
        choice_text: "この状況を静かに受け入れ、ティアラに従う",
        narrative_result: "あなたは、深く息を吸った。そして、その悲しみを受け入れることにした。",
        affinity_delta: { tiara_trust: 10, logic_empathy_balance: 8, name_memory_stability: -3, fragment_count: 2 }
      }
    ],
    metadata: { location: "ノメイア — 町の中央広場", beacon_id: "chapter1_02_arrival" }
  },
  {
    chapter: "chapter_1",
    beacon_order: 3,
    title: "名折れの危機",
    content: "あなたたちは、カケラを集めながら、町の奥深くへ進む。\n\nやがて、あなたたちが到達した場所は、古い教会だった。だが、その教会は、もはや『教会』であることをやめかけていた。壁は曖昧に見え、床は不確かに揺らいでいる。\n\nその教会の中心に、一人の人間がいた。\n\nそれは、ノメイアの長老だ。だが、その人は、半分ほど存在が薄れてしまっていた。\n\n「ああ...あなたたちが...来てくれたのね...」\n\n長老の視線があなたに向けられた。\n\n「あなた...あなたなのね...やっと...あなたが...戻ってきた...」\n\n長老は、その言葉を完成させる前に、光へと消えていった。後に残されたのは、一つの大きなカケラだけ。",
    tiara_dialogue: "「長老...」（その後、沈黙。そして、静かに）「あなたの...記憶を...守ります...」",
    choices: [
      {
        choice_id: "ch1_crisis_honor",
        choice_text: "長老の最後の言葉を理解しようと、そのカケラを丁寧に扱う",
        narrative_result: "あなたは、ティアラの手からそのカケラを受け取ると、両手で丁寧に抱きしめた。",
        affinity_delta: { tiara_trust: 15, logic_empathy_balance: 10, fragment_count: 3, name_memory_stability: 5 }
      },
      {
        choice_id: "ch1_crisis_question",
        choice_text: "長老の言葉の『真の意味』を問い詰める",
        narrative_result: "あなたが、長老の言葉について強く追及しようとするが、長老はもう存在しない。",
        affinity_delta: { tiara_trust: 5, logic_empathy_balance: -10, name_memory_stability: -5, fragment_count: 2 }
      },
      {
        choice_id: "ch1_crisis_continue",
        choice_text: "深く考えることをやめて、ティアラと共に前に進む",
        narrative_result: "あなたは、カケラを静かに懐に入れ、ティアラのそばに立った。",
        affinity_delta: { tiara_trust: 12, logic_empathy_balance: 8, name_memory_stability: 3, fragment_count: 3 }
      }
    ],
    metadata: { location: "ノメイア — 旧教会跡", beacon_id: "chapter1_03_crisis" }
  },
  {
    chapter: "chapter_1",
    beacon_order: 4,
    title: "カケラの獲得",
    content: "あなたたちは、町の奥へ奥へと進んでいく。\n\nやがて、あなたたちが到達した場所は、かつての呼応石採掘場だった。大きな穴が、地下へと続いている。\n\nあなたが周囲を見回ると、その穴の奥深くから、一つの淡い光が現れた。それは、かすかだが、確実に『呼応石』の光だ。\n\nあなたは、その光へ向かって歩いた。\n\nすると、地面が揺れ始め、穴の底からゆっくりと、一つの大きな呼応石が浮かび上がってきた。\n\nあなたが石に手を触れると、すべてのカケラが一度に、あなたの心へと流れ込んできた。\n\nあなたは、見た。あなたが、かつてこの石と共にいたこと。あなたが、ノメイアの『守り手』だったこと。",
    tiara_dialogue: "「あの光が応答しているのは...あなたの呼び声に...あなたが、ノメイアのシステムに呼応している...」（後に）「あなた...あなたは...本当に...」",
    choices: [
      {
        choice_id: "ch1_fragment_embrace",
        choice_text: "すべての記憶を受け入れ、ティアラとの呼応をさらに深める",
        narrative_result: "あなたは、ティアラをぎゅっと抱きしめた。その瞬間、光はさらに強くなり、すべてのカケラがあなたたちの周りで回転し始めた。",
        affinity_delta: { tiara_trust: 20, logic_empathy_balance: 12, name_memory_stability: 15, fragment_count: 25 }
      },
      {
        choice_id: "ch1_fragment_hesitate",
        choice_text: "記憶の流入に耐え切れず、一度身を引く",
        narrative_result: "あなたは、記憶の流れに圧倒され、石から手を離した。",
        affinity_delta: { tiara_trust: 8, logic_empathy_balance: 5, name_memory_stability: 5, fragment_count: 15 }
      },
      {
        choice_id: "ch1_fragment_analyze",
        choice_text: "記憶の流れを慎重に分析し、理性的に理解しようとする",
        narrative_result: "あなたは、記憶の流れを一つずつ整理し始めた。",
        affinity_delta: { tiara_trust: 5, logic_empathy_balance: -12, name_memory_stability: 12, fragment_count: 18 }
      }
    ],
    metadata: { location: "ノメイア — 呼応石の遺跡", beacon_id: "chapter1_04_fragment_acquisition" }
  },
  {
    chapter: "chapter_1",
    beacon_order: 5,
    title: "第一章の結末",
    content: "あなたたちは、呼応石の光を携えて、ノメイアの町中央へと戻ってきた。\n\nその光は、町全体に優しく広がり始めた。\n\n薄れていた建物の輪郭が、再び鮮明になり始める。朧げだった人々の顔が、少しずつ確かな形をしていく。\n\nノメイアは、少しずつ、しかし確実に、甦り始めていた。\n\nティアラの瞳には、涙が溜まっていた。\n\n「ありがとう...あなたが戻ってきてくれて...ありがとう...」\n\nあなたは、初めて、自分の声が『ああいう人間の声』だと実感した。記憶の中から、あなた自身の『声』が戻ってきたのだ。",
    tiara_dialogue: "「ありがとう...あなたが戻ってきてくれて...ありがとう...」（後に）「第一章は、終わりました。でも...本当の物語は、ここからです。あなたは、まだ自分が『誰なのか』を、完全には思い出していません」",
    choices: [
      {
        choice_id: "ch1_resolution_commitment",
        choice_text: "ティアラに誓う——『絶対に、また一緒に歩むから。絶対に、約束を守る』",
        narrative_result: "あなたが、その言葉を発した時、ティアラは激しく泣き始めた。二人の絆は、その時、完全に一つになった。",
        affinity_delta: { tiara_trust: 25, logic_empathy_balance: 15 }
      },
      {
        choice_id: "ch1_resolution_question",
        choice_text: "『本当は、何があったのか。全部、教えてくれ』と聞く",
        narrative_result: "ティアラは、一度深く息をついた。「全部は...まだ、いけません。でも...少しずつ、あなたが思い出すたびに、私は真実を添えていきます」",
        affinity_delta: { tiara_trust: 8, logic_empathy_balance: -8, name_memory_stability: 5 }
      },
      {
        choice_id: "ch1_resolution_future",
        choice_text: "ティアラと共に、これからへ目を向ける。『次は、どこへ行く？』",
        narrative_result: "ティアラは、静かに微笑んだ。「東へ...音の砂漠へ。そこには、あなたの『本当の名前』の欠片があるはずです」",
        affinity_delta: { tiara_trust: 12, logic_empathy_balance: 10, name_memory_stability: 8 }
      }
    ],
    metadata: { location: "ノメイア — 町の中央広場（再び）", beacon_id: "chapter1_05_resolution", is_chapter_end: true }
  }
]

chapter1_beacons.each do |beacon_data|
  StoryBeacon.find_or_create_by!(chapter: beacon_data[:chapter], beacon_order: beacon_data[:beacon_order]) do |beacon|
    beacon.title = beacon_data[:title]
    beacon.content = beacon_data[:content]
    beacon.tiara_dialogue = beacon_data[:tiara_dialogue]
    beacon.choices = beacon_data[:choices]
    beacon.metadata = beacon_data[:metadata]
  end
end

puts "  Created #{StoryBeacon.in_chapter('chapter_1').count} beacons for Chapter 1"
