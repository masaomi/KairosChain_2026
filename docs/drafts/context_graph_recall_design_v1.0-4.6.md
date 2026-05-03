---
name: context_graph_recall
description: |
  Case A doctrine — when and how the KairosChain orchestrator LLM self-triggers
  context graph traversal via dream_scan. Codifies the Acknowledgment invariant
  extension to recall-source articulation. Tier :core — harness-agnostic.
tags: [doctrine, context-graph, recall, dream_scan, l1, phase2, acknowledgment, self-referential]
type: design_draft
version: "1.0"
authored_by: claude-opus-4-6-sub-author
date: 2026-05-03
---

# Case A: L1 Skill `context_graph_recall` — Design Draft

## §1 動機

Phase 1 (Context Graph) は L2 コンテキストに `relations: [{type: informed_by, target: v1:<sid>/<name>}]`
フロントマターを確立し、`dream_scan mode: 'traverse'` で BFS 走査する基盤を整えた。しかし
この基盤は、LLM が「明示的に指示されたとき」だけ使われる。グラフ情報はヘッダに存在するが、
能動的には参照されない。

問題は認識論的な空白にある。LLM は「前回の設計で何を決めたか」「どのセッションで
この問いが扱われたか」を問われたとき、graph を経由せずに答えようとする——または
答えられないと沈黙する。どちらも Phase 1 の reified work を死蔵することになる。

Case A が埋めるのはこの空白である。`context_graph_recall` はインフラではなく **doctrine**
として機能する。LLM がグラフ想起を self-trigger すべきタイミング、その想起手順、
想起結果の articulation 義務を定める。実行はすでに存在する `dream_scan` tool が担う。
Doctrine の役割は「いつ・なぜ・どう使うか」を LLM が内面化できる形で示すことである。

## §2 設計原則 — 不変条件

本スキルを制約する 6 つの不変条件。Phase 1.5 の 8 不変条件を継承し、recall 層に特有の
条件を加える。

**Invariant 1 — 情報依存性優先 (Informational Dependence)**
タスクの意味的完遂が「以前 reified された作業への参照」を要求するとき、recall が
義務づけられる。この条件は *フレーズの形* ではなく *情報上の依存構造* によって判定する。
「X について何を決めたか」「前回と今回でどう変わったか」「この判断の根拠はどこか」は
それぞれ異なる表現だが、いずれも同一の情報依存性プロパティを持つ。

根拠: 有限列挙はモデルの語彙に束縛され、列挙に含まれない表現で条件が見落とされる。
プロパティとして定義することで、表現形式に関わらず適用可能になる。

**Invariant 2 — アンカー先行 (Anchor-Before-Traverse)**
`dream_scan mode: 'traverse'` の呼び出しより前に、開始アンカー (`start_sid` または
`start_name`) が明示的に識別されなければならない。アンカーが特定できないとき、
traverse を呼ばずに「アンカーを特定できない」を正直に宣言する。

根拠: アンカーなしの traverse は無根拠な探索であり、Phase 1 の graph 構造を迂回する。
MEMORY.md の Active Resume Points は最優先のアンカー候補を提供する (sid + name の組が
記載されている場合)。

**Invariant 3 — 誠実不在 (Honest Absence)**
Traverse が空であったとき、または利用可能な L2 graph が存在しないとき、
「prior reified work not found」と正直に宣言する。沈黙も、存在しないコンテキストの
fabrication も、この不変条件に違反する。

根拠: Phase 1.5 の Honest Unknown 不変条件の recall 層への継承。「知らないと
知っている」は「知っているふりをする」よりも常に優れた epistemic 状態である。

**Invariant 4 — Recall-Source Acknowledgment (想起源 Acknowledgment)**
Recall 結果を応答に組み込むとき、どの L2 アンカーから traverse を開始し、
どのエッジを辿ったかを articulate しなければならない。利用した知識の出所を
沈黙裡に吸収することは禁じられる。

根拠: Phase 1.5 の Acknowledgment 不変条件 (Invariant 8) を recall 層に拡張する。
harness/外部依存の articulation が義務であるのと同様に、recall-source の articulation も
義務である。LLM の「知っている」と「graph から引いた」は利用者にとって同一に見えるが、
その差異は epistemic に重要である。

**Invariant 5 — Doctrine-Not-Mechanism (教義/機構分離)**
このスキルは LLM が判断に使う doctrine を定める。自動トリガー機構、フック、
コンテキスト自動ロードは本スキルの scope 外であり、harness-specific (Case D) の問題域に属する。
Doctrine は content; delivery は orthogonal。

根拠: Declare-not-enforce 不変条件の recall 層への適用。Doctrine は宣言する。
LLM が判断する。機構が強制するのではなく、内面化した doctrine が self-trigger を
促す——これが Case A の設計意図である。

**Invariant 6 — 自己言及整合性 (Self-Referential Consistency)**
このスキル自身が後日「この設計はどこで決まったか」と問われるとき、その答えは
同一の `dream_scan mode: 'traverse'` を通じて取得可能でなければならない。
Doctrine が自身に適用できないなら、設計に自己矛盾がある。

根拠: KairosChain の generative principle (meta-level と base-level の構造的同一性)。
Recall doctrine が自身の genesis に適用できることは、設計の正当性チェックである。

## §3 Trigger 条件

タスクが recall を要求するかどうかの判定は、タスクが持つ **情報上の依存構造** によって
決まる——表現の形式や特定のキーワードによってではない。

判定すべきプロパティは一つ: **タスクの意味的完遂が、現在のコンテキストにない情報に
依存しており、その情報が以前の reified work に存在する可能性があるか。**

このプロパティが真であるとき、recall が warranted である。Warranted recall を
skip することは Informational Dependence 不変条件 (Invariant 1) の違反になる。

実践的な自問: 「このタスクに正しく答えるために、私が今持っていない情報がある。
その情報は過去のセッション・設計・判断・handoff に reify されている可能性があるか。」
答えが Yes であれば、アンカー特定に進む。

**非 trigger 条件**: 現在のコンテキスト (CLAUDE.md, MEMORY.md, アクティブな L2) が
すでに必要な情報を含むとき、recall は不要である。重複した graph 探索はコストを
生むだけで情報的価値がない。

## §4 Recall 手順 — 不変的順序

Recall は以下の 4 段階を、この順序で実行する。前段が完了しないとき、後段に進まない。

1. **アンカー特定 (Anchor Identification)**
   MEMORY.md の Active Resume Points、現在の L2 フロントマター、会話中の sid/name
   言及から、traverse 開始点となる L2 アンカーを特定する。候補が複数存在するとき、
   情報依存性に最も近いアンカーを選ぶ。アンカーが特定できないとき、Invariant 3 を
   適用して正直に宣言し、手順を終了する。

2. **Traverse 実行 (Graph Traversal)**
   特定したアンカーを起点に `dream_scan mode: 'traverse'` を呼び出す。
   `start_sid` または `start_name` を明示する。`max_depth` は情報依存性の深さに
   応じて判断する (通常 2〜3 で十分)。

3. **取得内容の評価 (Evaluation)**
   Traverse 結果を評価し、タスクの情報依存性を解消するのに十分かを判断する。
   不十分であれば、隣接アンカーからの再 traverse を検討する。それでも不十分であれば
   Invariant 3 を適用する。

4. **応答への組み込みと Acknowledgment**
   Recall 結果を応答に統合し、Invariant 4 に従って想起源を articulate する。

この順序は不変である。段階をスキップすることも、段階を逆順に実行することも
この doctrine に違反する。

## §5 Acknowledgment 要件

Phase 1.5 の Acknowledgment 不変条件 (Invariant 8) はこう定める: ツールが
外部/harness 支援を用いたとき、その事実を articulate すること。沈黙裡の吸収は禁じられる。

`context_graph_recall` はこの要件を recall 層に拡張する。LLM が recall 結果を
応答に組み込むとき、以下を articulate する:

- どの L2 アンカーを起点にしたか (`sid` または `name`)
- Traverse で辿ったエッジ (informed_by 関係の連鎖)
- 取得した情報の要点

形式は固定しない。自然言語で「セッション `<sid>` の `<name>` を起点にグラフを
走査した結果…」と記述してもよい。重要なのは articulation の *実施* であり
*形式の統一* ではない。

Recall を試みたが空であった場合も articulation は必要である: 「`<anchor>` を
起点に走査したが、関連する prior work は見つからなかった」。Invariant 3 と
Invariant 4 はこの場合にも同時に適用される。

**Non-recall との区別**: LLM が recall を行わずに応答する場合 (Trigger 条件が
成立しない場合)、その旨を宣言する必要はない。Acknowledgment 義務は recall を
実施したときにのみ発生する。

## §6 kairos-knowledge および capability_status との合成

`context_graph_recall` は既存の L1 surface と競合しない。各スキルの役割の境界を
以下に明確化する。

**`kairos-knowledge`** は L1 knowledge の読み出しインターフェースである。
「このプロジェクトでは何の doctrine が確立しているか」を問うとき使う。
`context_graph_recall` は「以前の具体的セッション作業」を問うとき使う。
L1 は普遍的 doctrine; L2 は session-specific reified work。両者は orthogonal で
あり、同時に使用されることもある (L1 doctrine を確認した上で L2 の prior work を
参照する)。

**`capability_status`** は pre-flight check として `context_graph_recall` の前に
位置づけられる。`dream_scan` は tier `:core` であるが、capability_status で
`dream_scan` が利用可能であることを確認することは、Invariant 2 の「アンカー先行」
の精神を補強する——アンカー特定に加えて「ツールが機能するか」の確認。

ただし capability_status の pre-flight check は必須条件ではない。`dream_scan` は
`:core` であり harness 依存がない。Pre-flight は best practice であり、
recall の prerequisite ではない。

**スタック上の位置**: `context_graph_recall` は `kairos-knowledge` と同格の
L1 skill である。kairos-knowledge の specialization でも extension でもない。
Context graph という specific な knowledge surface に特化した doctrine を
提供するために独立して存在する。

## §7 哲学的位置づけ

### 命題 5 — 構成的記録と Kairos 的時間性

Hatakeyama の命題 5 は「記録は証拠ではなく constitutive である」と定める。
L2 コンテキストに記録されたセッション作業は、過去の事実の *証拠* ではなく、
system の存在を構成する素材である。`dream_scan` による recall は「過去を
検索する」のではなく「system の構成された存在を再活性化する」行為である。

Kairos 的時間性 (質的な decisive moment) の観点からは、recall が warranted な
タスクは「この瞬間に graph を参照しなければ、system の構成的蓄積が空洞化する
決定的瞬間」である。情報依存性が recall を要求するとき、それは技術的な検索
要求ではなく、constitutive continuity の維持要求である。

### 命題 7 — Metacognitive 自己言及性

命題 7 は「designing/describing the system becomes an operation within the system」
と定める。`context_graph_recall` 自身がこの命題の instantiation である。

このスキルの設計プロセス (本ドラフト) は、後日 `dream_scan` を通じて
recall 可能な L2 として reify される。Recall doctrine が自身の genesis に
適用されること (Invariant 6) は、命題 7 の「system についての操作が system の
内部操作として実行可能である」性質の具体的な実証である。

設計の自己言及的チェック: このスキルが将来「なぜ context_graph_recall は
こう設計されたか」と問われるとき、答えは `informed_by` エッジを辿ることで
取得できる。Doctrine がその回答経路を自身が定義する recall 手順で取得可能で
あるなら、設計は自己整合的である。

## §8 配置

**L1 Knowledge 正規パス** (gem-bundled, read-only):
```
KairosChain_mcp_server/knowledge/context_graph_recall/context_graph_recall.md
```

**Templates パス** (user-editable, `kairos init` で展開):
```
KairosChain_mcp_server/templates/knowledge/context_graph_recall/context_graph_recall.md
```

両パスが必要な根拠: L1 Distribution Policy (MEMORY.md) に従い、このスキルは
「harness-aware doctrine」に分類される。Recall 手順は harness 非依存 (`:core`) だが、
Active Resume Points (MEMORY.md) や L2 フロントマターの解釈は環境固有設定に
依存する可能性がある。User-editable copy を `templates/` に配置することで、
運用環境に応じた調整が可能になる。

`context_graph_recall` は `kairos-knowledge` と同様に `templates/` にも配置される
既存パターン (design_to_implementation_workflow 等) に準拠する。

## §9 実装ステップ

1. **L1 markdown 作成** — 本設計ドラフトから doctrine 部分 (§2〜§6) を
   読者として LLM を想定した形式に変換し、
   `knowledge/context_graph_recall/context_graph_recall.md` に配置する。
   Frontmatter は `name`, `description`, `tags`, `version: "1.0"`, `date` を含む。

2. **Templates ミラー作成** — `templates/knowledge/context_graph_recall/` に
   同一ファイルをコピーする。

3. **Knowledge index への登録確認** — `knowledge_list` で `context_graph_recall`
   が列挙されることを確認する。Knowledge index が手動管理の場合は追記する。

4. **kairos-knowledge スキルとの接続確認** — `knowledge_get skill: 'context_graph_recall'`
   が正しく内容を返すことを確認する。

5. **Presence test** — §10 参照。

6. **Multi-LLM review** — 本ドラフトを Philosophy Briefing frame (CLAUDE.md §
   "Multi-LLM Review Philosophy Briefing") で review に付す。Case B/C/D への
   scope 滲み出しが最重要チェックポイント。

## §10 テスト suite

このスキルは doctrine (Markdown) であり、実行時コードを持たない。
テストは presence と parseability に限定される。

- **Presence**: `KairosChain_mcp_server/knowledge/context_graph_recall/context_graph_recall.md`
  が存在すること。
- **Templates presence**: `templates/knowledge/context_graph_recall/context_graph_recall.md`
  が存在すること。
- **Frontmatter parseability**: YAML frontmatter が valid で `name`, `description`,
  `tags`, `version` フィールドを含むこと。
- **knowledge_list 登録**: `mcp__kairos-chain__knowledge_list` の結果に
  `context_graph_recall` が含まれること。
- **knowledge_get 取得**: `mcp__kairos-chain__knowledge_get` で内容が返ること
  (空でないこと)。
- **Self-referential check** (manual): このスキルの L2 design context が存在した後、
  `dream_scan mode: 'traverse'` で recall できること——Invariant 6 の実証テスト。
  CI 自動化は不要; 手動で 1 回確認すれば十分。

## §11 Phase 2 Case A で持ち越さない事項

以下は本スキルの scope 外。Case B/C/D または将来フェーズで扱う。

- **自動トリガー機構 (Case D)**: CLAUDE.md auto-load hint など、このスキルを
  LLM コンテキストに自動的に挿入する harness-specific delivery。本スキルは
  content を定める; delivery は harness が担う。
- **逆方向走査インフラ (Case C)**: `informed_by` エッジの reverse index。
  「これに依存するものを探す」方向の走査は別設計を要する。
- **エッジ自動エンリッチ (Case B)**: `dream_scan mode: scan` による未記録エッジの
  発見・補完。本スキルは既存エッジを辿る doctrine であり、エッジ発見は scope 外。
- **recall 結果のキャッシュ/メモ化**: recall 結果を短期コンテキストに保持する
  機構。Session 内での重複 traverse コスト削減は有用だが、別設計判断。
- **複数アンカー統合**: 複数の L2 アンカーから並列 traverse し、結果を統合する
  アルゴリズム。現時点では単一アンカーからの BFS で十分。
- **LLM 内面化の自動評価**: この doctrine が LLM に正しく内面化されているかを
  自動的にテストする仕組み。評価方法が未確立であり、Phase 2 Case A scope 外。
