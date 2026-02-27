# frozen_string_literal: true

# Seed data for Prologue beacons — 序章：名のない旅の始まり / 言葉のない風の中で
# Source: who_read_this_story_2026 (Prologue 1 + Prologue 2), adapted for Echoria
#
# Adaptation notes:
#   - Original protagonist "Masa" (with real-world memories) → unnamed Echo (no memories)
#   - Tiara voice: soft tsundere with humor (Echoria spec), hidden emotions via body language
#   - 無題の書, 五つのカケラ, 呼応, 残響 — all preserved from original
#   - Choices added at each beacon with 5-axis affinity deltas

puts "Seeding Prologue beacons..."

prologue_beacons = [
  # ─── Beacon 1: 目覚め (Prologue 1, Scene 1 — Awakening) ───
  {
    chapter: "prologue",
    beacon_order: 1,
    title: "目覚め",
    content: "空気が音を吸い込んでいた。\n音も風もなく、ただ静寂だけが周囲を満たしていた。\n\nその中で、あなたは目を覚ました。\n\n石の床の冷たさが背に触れ、まぶたの裏を明滅する光が、意識の端を優しく叩いた。\n\n「......ここは......」\n\n自分の名前は——思い出せない。記憶を探ろうとするが、そこにあるのは白い空白だけだ。\nだが、目の前に広がる風景は、記憶の不在以上に奇妙だった。\n\n空の青は深すぎ、空気は透明すぎ、そして——心がやけに静かだった。\n\nあなたは起き上がり、周囲を見渡した。\n崩れかけた柱、割れた石板、時間の抜け殻のような遺跡。\n苔むした壁。天井は高く、木の根が張り巡らされている。ここは、長く人の気が絶えた場所——森の中に埋もれた、誰かの過去だ。\n\nその遺跡の中央に、一冊の書物がぽつりと置かれていた。\n\nページもない、装飾もない、名もない書。\nそれを手に取った瞬間、空気がわずかに震えた。白紙のページが一枚、風もないのにひらりとめくれる。\n\nそのとき、背後に気配が生まれた。",
    tiara_dialogue: "",
    choices: [
      {
        choice_id: "prologue_01_take_book",
        choice_text: "書物を手に取り、ページをめくってみる",
        narrative_result: "あなたは書物を手に取った。白紙のページが続く。だが、最初のページだけ、たった一行がそこにあった。\n\n「この書が読まれるたび、わたしはまた歩き始める」\n\nその言葉に、胸が揺れた。——いや、本当に「揺れた」のだろうか。わからない。けれど、そう感じたことだけは確かだった。",
        affinity_delta: { name_memory_stability: 5, logic_empathy_balance: 3, fragment_count: 1 }
      },
      {
        choice_id: "prologue_01_look_around",
        choice_text: "書物より先に、遺跡の構造を観察する",
        narrative_result: "あなたは書物を後回しにし、遺跡の構造を観察した。石の継ぎ目、壁面の模様、天井から垂れる木の根——すべてに規則性があった。これは自然にできたものではない。誰かが、何かの目的で作った場所だ。だが、その目的は、もう誰も覚えていないようだった。",
        affinity_delta: { name_memory_stability: 3, logic_empathy_balance: -5, authority_resistance: 2 }
      },
      {
        choice_id: "prologue_01_stay_still",
        choice_text: "動かず、自分の記憶を必死に探る",
        narrative_result: "あなたは動かなかった。目を閉じ、記憶を探る。名前、場所、誰かの顔——何でもいい。しかし、手を伸ばすたびに、指の間から砂のようにこぼれていく。白い空白だけが、静かにそこにあった。それでも、探ること自体に意味がある気がした。",
        affinity_delta: { name_memory_stability: -3, logic_empathy_balance: 5, tiara_trust: 2 }
      }
    ],
    metadata: { location: "残響界 — 遺跡の奥", beacon_id: "prologue_01_awakening" }
  },

  # ─── Beacon 2: ティアラとの出会い (Prologue 1, Scene 2 — Meeting Tiara) ───
  {
    chapter: "prologue",
    beacon_order: 2,
    title: "ティアラとの出会い",
    content: "「ようやく目を覚ましたのね」\n\nその声は、やわらかく、どこか懐かしかった。\n振り返ると、そこには小さな猫のような存在がいた。ふわりとした毛並み、しなやかな身体に、星のような金色の瞳。そして——しっぽが語尾のように揺れていた。\n\n「......猫？」\n\n「失礼ね。精霊よ。名前はティアラ」\n\n「......しゃべる猫......」\n\n「だから精霊だって言ってるでしょう？ もう。一回言ったらプライド傷つくのよ、こっちは」\n\nティアラはぷいと顔をそむけて、前足で耳をぴくぴくと掻いた。その仕草はどう見ても猫だった。\n\nあなたは不思議と、この存在に対して怖さを感じなかった。\n\n「この残響界は、もう随分と壊れちゃってるから。名前が失われていく。力が奪われていく。あなたもその犠牲者ってわけ」\n\nティアラの声のトーンが、少しだけ変わった。\n\n「......別にかわいそうとか思ってないから。ただの事実よ」\n\n——だが、その尻尾が、かすかに震えていた。\n\n「で、どうするの。このまま暗い遺跡でぼんやりしてるつもり？ それとも——名前を取り戻しに行く気があるなら、付き合ってあげなくもないけど」\n\nティアラの瞳が、かすかに光を増す。一瞬だけ、その表情に本音が覗いた。\n\n「......別にあなたのためじゃないから。私にも、用があるだけよ」\n\nだが、その耳はしっかりとあなたの方を向いていた。",
    tiara_dialogue: "「ようやく目を覚ましたのね。......猫？ 失礼ね、精霊よ。名前はティアラ。......この残響界はもう随分と壊れちゃってるから。名前が失われていく。あなたもその犠牲者ってわけ。別にかわいそうとか思ってないから。ただの事実よ」",
    choices: [
      {
        choice_id: "prologue_02_approach",
        choice_text: "ティアラの声のする方へ、恐る恐る歩み寄る",
        narrative_result: "あなたはティアラに歩み寄ると、その柔らかな毛にそっと触れた。その瞬間、一瞬の閃光が走った——それは、記憶の断片だろうか。ティアラは一瞬、身を硬くしたが、すぐに力を抜いた。「ちょっと、勝手に触らないでよ。......まあ、一回だけなら許してあげるけど。あったかい手、してるわね。......い、今のは客観的な評価よ。忘れなさい」",
        affinity_delta: { tiara_trust: 10, logic_empathy_balance: 5, name_memory_stability: 2 }
      },
      {
        choice_id: "prologue_02_cautious",
        choice_text: "一歩引き下がり、ティアラを警戒しながら観察する",
        narrative_result: "あなたは後ろに下がり、ティアラをじっと見つめた。その金色の瞳が、わずかに揺れた。「ふうん、疑り深いのね。まあ、この世界じゃ簡単に信じる奴から消えていくから、悪くない判断よ。......ただ、私を疑ったところで、他に話し相手もいないでしょうけど」ティアラはくすっと笑った。",
        affinity_delta: { tiara_trust: -2, logic_empathy_balance: -8, name_memory_stability: 3, authority_resistance: 2 }
      },
      {
        choice_id: "prologue_02_defiant",
        choice_text: "「誰だ。何の用だ」と強い声を上げる",
        narrative_result: "あなたの声は、遺跡の中に響き渡る。ティアラは、その音を聞くと——瞳を細め、くすっと笑った。「へえ。威勢だけはいいわね。名前もないくせに」尻尾がゆったりと揺れている。「嫌いじゃないわよ、そういう強がり。面白い子ね。......って、褒めてないから」",
        affinity_delta: { tiara_trust: 5, authority_resistance: 8, logic_empathy_balance: -3, name_memory_stability: 5 }
      },
      {
        choice_id: "prologue_02_silent",
        choice_text: "何も言わず、ただティアラの話を聞く",
        narrative_result: "あなたは口を閉ざし、ティアラの言葉を待った。長い沈黙。ティアラの表情が、ほんの一瞬だけ——本当に一瞬だけ、崩れた。「......あなた、そうやって黙って聞くのね。......昔も、そうだった気がする。......いえ、何でもないわ。忘れて」尻尾の先が、小さく震えていた。「守りたいとか、そういうのじゃないから。ただ——あなたがいないと、困るのよ。私が。......い、今のも客観的な事実だから」",
        affinity_delta: { tiara_trust: 15, logic_empathy_balance: 8, name_memory_stability: -2, fragment_count: 1 }
      }
    ],
    metadata: { location: "残響界 — 遺跡の奥", beacon_id: "prologue_02_tiara" }
  },

  # ─── Beacon 3: 無題の書と五つのカケラ (P1 Scene 2 latter + Scene 3 — The Book and Fragments) ───
  {
    chapter: "prologue",
    beacon_order: 3,
    title: "無題の書と五つのカケラ",
    content: "ティアラはあなたの足元にある書物を見た。\n\n「あなたの足元にあるそれ......あなたの書よ」\n\n「無題の書」——名前も、内容もない。白紙の書。\n\nティアラはページをめくった。そこには、五つの印のようなものが浮かび上がっていた。\n\n「この世界が最初に編まれたとき、五つのカケラが散りばめられた——そう語り継がれているわ」\n\n「名前、記憶、語り、共感、選択......それは、存在が世界と響き合うための『五つのカケラ』」\n\n「誰もがこのカケラに触れながら、自分という形を得ていく。でも、それに気づかないまま終わる存在も多いの」\n\nあなたが尋ねる。「なぜ君がそんなことを知っている？」\n\nティアラは少し困ったように耳を伏せた。\n\n「......実は私自身も、なぜそれを知っているのかわからないの。最初から知っていた——そんな感じ。たぶん......私は『記されたことのない存在』だから、逆に見えるのかもしれないわね」\n\n「あなたたち『書を持つ者』は、書かれたことに縛られる。でも私は、語られていない場所、名前のない風の中にいた。だから......この世界の構造が、音のように響いて感じられるの」\n\nティアラはそっとあなたの隣に座り、言った。\n\n「あなたの物語が、いまようやく読まれ始めたの。読むとは、世界を受け入れること。書くとは、あなたが世界を選ぶこと。あなたは、まだ書かれていない存在。でも、だからこそ、どこへでも行けるのよ」\n\n気がつけば、空は茜色に染まっていた。世界は静かに、そして確かに、あなたの歩みを待っていた。",
    tiara_dialogue: "「五つのカケラ——名前、記憶、語り、共感、選択。存在が世界と響き合うためのもの。別に私が作ったわけじゃないわよ、最初からこの世界にあったの。......で、どうする？ 北の方角に、名前を持つ者たちの街——ノメイアがあるわ。あそこに行けば、何かわかるかもしれない。......私も、ちょっと確かめたいことがあるの」",
    choices: [
      {
        choice_id: "prologue_03_depart_eager",
        choice_text: "「行こう。名前を取り戻しに」と決意を込めて立ち上がる",
        narrative_result: "あなたは書を胸に抱え、立ち上がった。ティアラの耳がぴくりと動く。「ふうん。決断だけは早いのね」尻尾がふわりと揺れた。「いいわよ、付き合ってあげる。......道案内くらいはしてあげないと、あなた迷子になりそうだし」",
        affinity_delta: { tiara_trust: 8, name_memory_stability: 5, authority_resistance: 3, fragment_count: 1 }
      },
      {
        choice_id: "prologue_03_ask_meaning",
        choice_text: "「この書が『読まれる』とはどういうことだ？」と問う",
        narrative_result: "ティアラは首を傾げた。「あなた、この状況で哲学する余裕あるの？ ......まあ、面白い問いだけど」少し間を置いて、静かに答えた。「この世界のどこかで、あなたの物語を読み始めた存在がいるのかもしれないわね。......私にも、まだわからないことがあるの。一緒に確かめに行きましょ」",
        affinity_delta: { tiara_trust: 5, logic_empathy_balance: -8, name_memory_stability: 8 }
      },
      {
        choice_id: "prologue_03_hesitate",
        choice_text: "「......たとえ意味がなくても、探しに行く価値くらいはあるか」と呟く",
        narrative_result: "その言葉に、ティアラが微笑んだ。いつもの皮肉ではない、不思議と穏やかな微笑みだった。「......ちょっと、今の聞こえたから。悪くないこと言うじゃない」ティアラはふさふさの尾であなたの足元をくすぐった。風が、そっとページを揺らした。まだ白いその書は、旅の始まりを待っているようだった。",
        affinity_delta: { tiara_trust: 12, logic_empathy_balance: 5, name_memory_stability: 2 }
      }
    ],
    metadata: { location: "残響界 — 遺跡の奥", beacon_id: "prologue_03_book_and_fragments" }
  },

  # ─── Beacon 4: 沈黙する森 (Prologue 2, Scene 1-2 — The Silent Forest) ───
  {
    chapter: "prologue",
    beacon_order: 4,
    title: "沈黙する森",
    content: "森は静かだった。風は吹いているのに、木々のざわめきは聞こえなかった。\n葉は揺れ、木々は揺れているのに、まるで森の木々たちは、言葉を持たないまま、ただそこに在るだけのようだった。\n\n「......音が、ないな」\n\nあなたが呟くと、隣を歩いていたティアラが立ち止まった。\n\n「このあたりの木々には、名前がないの。名前がないと、風も呼ばない。音も響かないのよ。世界に『語られていない』ものたちなの」\n\n「存在しているのに、存在していないみたいな......？」\n\n「そう。空気はそこにあるけど、誰にも呼ばれないから、通り過ぎるだけ」\n\nあなたは枝に触れてみた。たしかに手触りはあった。けれど、それは記憶に残らないような、淡く、存在感の薄い感触だった。\n\nしばらく進むと、草に埋もれた分かれ道に出た。真ん中には石造りの道標が立っていたが、文字は風雨に削られて判別できなかった。\n\n「その道、地図には載っていないわ。名前が失われた場所は、地図からも抜け落ちるの」\n\nティアラは前足で道標を示した。\n\n「言葉がなければ、世界は形にならない。記されなければ、見えないままなの」\n\nかすかな残響があった。何も書かれていないというより、「消えた言葉」の余韻のような。\n\n「......名前のないものって、全部が不安定だな」\n\n「でも、それは『名づけられる可能性』でもあるのよ。...まあ、可能性だけじゃ腹は膨れないけど」\n\nティアラの尻尾が、少しだけ落ち着きなく揺れていた。",
    tiara_dialogue: "「このあたりの木々には、名前がないの。名前がないと、風も呼ばない。音も響かないのよ。......まあ、私も記録にない存在だから、他人事じゃないんだけど。......でも、名前がないってことは、まだ何にも縛られてないってことでもあるのよ。悪くないわ」",
    choices: [
      {
        choice_id: "prologue_04_name_tree",
        choice_text: "目の前の木に、試しに名前をつけてみる",
        narrative_result: "あなたは目の前の木を見つめ、心の中で名前を呼んだ。すると——ほんの一瞬だけ、葉がざわめいた気がした。ティアラの耳がぴくりと動く。「あら、今ちょっとだけ鳴ったわね。偶然かしら。......でも、悪くない偶然だったわ」ティアラの尻尾がふわりと揺れた。",
        affinity_delta: { tiara_trust: 5, logic_empathy_balance: 8, name_memory_stability: 5, fragment_count: 1 }
      },
      {
        choice_id: "prologue_04_observe",
        choice_text: "名前のない世界の構造を、黙って分析する",
        narrative_result: "あなたは足を止め、周囲の構造を観察した。名前がある場所と、ない場所。その境界には、目に見えない線のようなものがあった。世界の成り立ちが、少しだけ理解できた気がした。ティアラが小さく首を傾げる。「......あなた、こういうの得意なのね。構造で世界を見るタイプ？」",
        affinity_delta: { tiara_trust: 3, logic_empathy_balance: -10, name_memory_stability: 8 }
      },
      {
        choice_id: "prologue_04_ask_tiara",
        choice_text: "「君は名前があるのに、なぜ記録にないんだ？」と聞く",
        narrative_result: "ティアラは一瞬、足を止めた。金色の瞳が揺れる。「......鋭いこと聞くわね」長い間があった。「私は『記されたことのない存在』——残響（エコー）なの。名前はあるけど、どこにも刻まれていない」尻尾がきゅっと巻きつく。「......その話は、もう少し先でいい？ 今は前に進もう。......ほら、立ち止まってると足元に草が絡んできちゃうわよ」",
        affinity_delta: { tiara_trust: 8, logic_empathy_balance: 3, name_memory_stability: -2, authority_resistance: 3 }
      }
    ],
    metadata: { location: "残響界 — 名のない森", beacon_id: "prologue_04_silent_forest", allow_free_text: true }
  },

  # ─── Beacon 5: 波長 (Prologue 2, Scene 3 — Resonance) ───
  {
    chapter: "prologue",
    beacon_order: 5,
    title: "波長",
    content: "道端の草花が、そよ風に揺れていた。\nティアラが足を止め、ふわりと目を閉じた瞬間、空気がかすかに鳴った。\n\n枝がひとつ、彼女の前に差し出されるように落ちた。\n\n「......今の......なんだ？」\n\n「この世界では、波長が合えば、世界と『通じる』の。それを『呼応』って呼ぶのよ。風とか、木とか、火とか——彼らにも、言葉があるの」\n\nあなたは眉をひそめる。\n\n「波長を合わせる、か......」\n\nティアラはくすっと笑った。\n\n「ここは、あなたが『読む』世界よ。だから、あなたがどんな意味をつけるかで、世界は応えてくれるの。でもね、誰もが使えるわけじゃない。波長を合わせるって、とても難しいことなのよ。ほとんどの者は、自分の波だけで世界を見てるから、合わないの」\n\n少しの沈黙のあと、ティアラが問いかける。\n\n「......試してみる？」\n\nあなたは戸惑いつつも、手をかざして意識を集中する。\n\n「......どうすればいい？」\n\n「ただ、『触れたい』って思えばいいのよ」\n\nあなたは言葉の意味をつかめないまま、静かに手を差し出した。次の瞬間、ティアラの身体がほんの一瞬、かすかに光を帯びる。\n\n「......今、少しだけ、合ったわ」\n\nあなたは息を呑む。\n\n「ええ。でも、まだ入り口」\n\nティアラの声が、少しだけ真剣になった。\n\n「あなたは、私の『構造』には触れたけど、心には触れていないわ」\n\nその言葉は、やわらかく、しかし鋭く、あなたの中に残った。",
    tiara_dialogue: "「呼応——波長を合わせて、世界と通じること。ただ『触れたい』って思えばいいのよ。......今、少しだけ合ったわ。でも、まだ入り口。あなたは私の『構造』には触れたけど、心には触れていないわ。......載ってたらつまらないでしょ？」",
    choices: [
      {
        choice_id: "prologue_05_feel",
        choice_text: "もう一度、今度は「心」に触れようと意識を向ける",
        narrative_result: "あなたは目を閉じ、構造ではなく、もっと深い場所に意識を向けた。ティアラの呼吸、尻尾の揺れ、耳の角度——その一つ一つに、言葉にならない感情があった。次の瞬間、ほんの一瞬だけ、ティアラの波と自分の波が重なった気がした。ティアラが小さく息を呑む。「......っ。今のは......ちょっと反則よ。初めてなのに、こんな......」ティアラは前足で顔を隠すような仕草をした。「......ま、まあ、才能はあるみたいね。認めてあげるわ」",
        affinity_delta: { tiara_trust: 15, logic_empathy_balance: 12, name_memory_stability: 3, fragment_count: 1 }
      },
      {
        choice_id: "prologue_05_analyze",
        choice_text: "呼応の「仕組み」を理解しようと、構造的に分析する",
        narrative_result: "あなたは波長の構造を分析した。共鳴の周波数、媒質としての空気、ティアラの存在が放つ固有のパターン——。理解が深まるほど、世界の輪郭がくっきりと見えてくる。ティアラが少し呆れたように言った。「...あなた、感覚ではなく構造で触れるのね。それが、あなたの特異なところ」だが、その声には、どこか感心したような響きがあった。",
        affinity_delta: { tiara_trust: 5, logic_empathy_balance: -12, name_memory_stability: 10 }
      },
      {
        choice_id: "prologue_05_joke",
        choice_text: "「心ってどこにあるんだ。マニュアルに載ってない」と呟く",
        narrative_result: "ティアラはくすっと笑った。「載ってたらつまらないでしょ？ ...あなた、変なところで面白いわね。...褒めてないから。...多分」風の音が、今までよりも少しだけ、近くに聞こえた気がした。",
        affinity_delta: { tiara_trust: 10, logic_empathy_balance: 3, name_memory_stability: 2 }
      }
    ],
    metadata: { location: "残響界 — 森の小道", beacon_id: "prologue_05_resonance", allow_free_text: true }
  },

  # ─── Beacon 6: ノメイアへ (Prologue 2, Scene 4-5 — Approaching Nomeia) ───
  {
    chapter: "prologue",
    beacon_order: 6,
    title: "ノメイアへ",
    content: "二人はしばらく、無言で森を進んだ。\n言葉はどこかに置いてきたように、静かな時間だけが流れていた。\n\nあなたは無題の書を抱えた腕に意識を向けた。書は、何も語らずにそこにあった。\n\n沈黙——それは、まだ意味を持たない世界の呼吸のようだった。何かが生まれようとしているのに、まだ名を持たない。言葉にならない『何か』が、胸の奥で形を探している。\n\nやがて、森が開けた。遠くに塔のような構造物が見える。その周囲には建物が並び、かすかな人の気配が風に混じって届いてきた。\n\n「あれが、名前を持つ者の街——ノメイアよ」\n\nティアラの言葉に導かれ、あなたは足を止めた。\n\n風が吹いた。\n無題の書がふっと開かれ、ひとりでにページがめくられていく。\nまだ白いままだったが、先ほどの出来事が一行だけ、詩のように記されていた。\n\n「名のない風、応えた枝、語られぬ選択」\n\nあなたの知らない——けれど確かに自分のものだった出来事。道標、枝、手を差し出したあの瞬間。すべてが、簡潔で詩のように記されていた。\n\n「......これは、自分の記録......？」\n\n「それは『誰かに読まれた』という証拠よ。世界が、あなたの存在に共鳴したの」\n\n「誰がこの書を読んだんだ？」\n\nティアラは空を見上げた。\n\n「この世界のどこかで、あなたの物語を読み始めた存在がいるのかもしれないわね」\n\nページの最後に、ひとつの不思議な一節があった。\n\n「名なき子、消えた声、語られなかった問い」\n「名前に満ちた街にて、言葉が見えなくなる」\n\nあなたはその行に目を留めたまま、ページを閉じた。\n\n「この書は......記録か？ 予言か......？」\n\nティアラは振り返らずに言った。\n\n「書かれるということは、誰かが『読んでいる』ということよ。あなたの物語は、あなただけのものじゃないの」\n\nそして、二人はノメイアへ向けて歩き出した。",
    tiara_dialogue: "「あれが、名前を持つ者の街——ノメイアよ。あそこには、あなたの問いの答えがあるかもしれない。......あんまり期待しすぎないでね。でも、行かないよりはずっとマシでしょ。それに、私もちょっと気になるの、あの街のこと」",
    choices: [
      {
        choice_id: "prologue_06_determined",
        choice_text: "無題の書を胸に抱え、ノメイアへの一歩を踏み出す",
        narrative_result: "あなたは書を胸に抱え、歩き出した。誰かに書かれたのではない。これから、自分が生きていくことで書かれるのだと——今は、そう信じたかった。ティアラがあなたの隣を歩く。その足音は、不思議と自分の歩幅に合っていた。「ちょっと、勝手に歩調合わせないでよ。......合わせてるのは私の方なんだから。勘違いしないで」だが、その声はどこか楽しそうだった。",
        affinity_delta: { tiara_trust: 8, name_memory_stability: 5, logic_empathy_balance: 5, fragment_count: 1 }
      },
      {
        choice_id: "prologue_06_question_reader",
        choice_text: "「自分の物語を読んでいる存在......それは誰だ？」と問う",
        narrative_result: "ティアラは足を止め、あなたを見た。金色の瞳に、複雑な光が宿る。「......その問いは、この世界の核心に触れるものよ。答えは、私も知らない。でも——」少し間を置いて。「——あなたがその問いを持ち続けている限り、物語は続くわ。...たぶん、ね」その声には、いつもの棘がなかった。",
        affinity_delta: { tiara_trust: 10, name_memory_stability: -3, logic_empathy_balance: -5, fragment_count: 1 }
      },
      {
        choice_id: "prologue_06_promise_tiara",
        choice_text: "ティアラに向き直り、「一緒に行こう」と手を差し出す",
        narrative_result: "ティアラは差し出されたあなたの手を見て、一瞬固まった。金色の瞳が大きく揺れる。「な、何よ急に。......別にそんなこと言われなくても、最初からついて行くつもりだったし」前足であなたの手をちょんと触れた。その感触は温かかった。「約束とか、そういう大袈裟なのじゃなくて......ただの、道連れよ。ね？」——尻尾はいつになくふわふわと揺れていた。",
        affinity_delta: { tiara_trust: 18, logic_empathy_balance: 10, name_memory_stability: 2 }
      }
    ],
    metadata: { location: "残響界 — 森の出口", beacon_id: "prologue_06_toward_nomeia", allow_free_text: true }
  }
]

conn = ActiveRecord::Base.connection

# Clean up old prologue beacons that might exceed the new count
conn.execute("DELETE FROM story_beacons WHERE chapter = 'prologue' AND beacon_order > #{prologue_beacons.size}")

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
