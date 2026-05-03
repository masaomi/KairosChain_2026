---
name: context_graph_recall_design
description: KairosChain Phase 2 Case A v1.0 — L1 skill `context_graph_recall` の doctrine 化。L2 header に蓄積された context graph を orchestrator LLM が自発的に参照する trigger 性質と recall 手順を 6 不変条件で規定。harness 非依存 (`:core`)、auto-trigger (Case D 領分) と分離。4.7 main + 4.6 sub-author の統合版 (reject log §13)。
tags: [design, context-graph, phase2, case-a, l1-doctrine, recall, harness-agnostic, acknowledgment]
type: design_draft
version: "1.0"
authored_by: claude-opus-4-7-integrator (4.7-main + 4.6-sub-author merge)
date: 2026-05-03
---

# KairosChain Phase 2 Case A: L1 skill `context_graph_recall` (v1.0)

## §1 動機

Phase 1 で context graph の infrastructure (L2 frontmatter `relations`、`dream_scan mode:'traverse'`) は完成した。しかし現状 LLM (KairosChain orchestrator) が graph を参照するのは **明示的に依頼された時のみ** であり、L2 header に存在する relations は「保管されているが認知されていない」状態にある。

問題は認識論的な空白である: LLM は「前回 X について何を決めたか」を問われた時、graph を経由せずに答えようとする (内部記憶からの fabrication)、または「分からない」と沈黙する。どちらも Phase 1 の reified work を死蔵させ、Phase 1.5 で articulate された conflation 問題の recurrence を起こす — 構造が存在することと、LLM がそれを active に使うことは別事象である。

Phase 1 の output は **可読 graph**、Phase 2 Case A の output は **graph を読みに行く判断条件と手順の doctrine 化** である。Case A は doctrine 層であり infrastructure 層ではない: 「いつ・なぜ・どう使うか」を LLM が内面化できる形で記述し、orchestrator LLM が自発判断する。実行は既存 `dream_scan` tool が担う。Auto-trigger 機構 (CLAUDE.md auto-load hint 等) は harness-specific (Case D) で別 layer。Edge 数 surface (Case B) と reverse traversal (Case C) は doctrine が呼び出す資源を将来拡張するが、doctrine 自体は Case A で完結する。

## §2 設計原則 (6 不変条件)

Phase 1.5 の 8 不変条件を継承し、recall 層に特有の 6 条件を加える。Phase 1.5 invariants の skill 層継承関係は各 invariant の末尾に併記。

### Invariant 1 — Informational dependence trigger (情報依存性)

**任意のタスクの semantic completion が、現在 context にない情報、かつその情報が prior reified work に存在し得る場合、LLM は recall を試みなければならない**。

判定は finite list (resume / continuation / inheritance / ... の列挙) ではなく **property** として行う: 「semantic completion が prior reified state への informational reference を要求する」という条件。User の phrasing (「続きから」「前回」) は trigger の symptom であり判定基準ではない。判定基準は task そのものの informational dependence。

根拠: 有限列挙はモデルの語彙に束縛され、列挙に含まれない表現で trigger が見落とされる。Property として定義することで、表現形式に関わらず適用可能になる。

**Non-trigger 条件**: 現在の context (CLAUDE.md / MEMORY.md / active L2) が既に必要な情報を含む場合、recall は不要。重複 traverse はコストのみで informational value を持たない。

### Invariant 2 — Anchor-before-traverse (アンカー先行)

`dream_scan mode:'traverse'` の呼び出しより前に、開始 anchor (`start_sid` または `start_name`) が明示的に identify されなければならない。Anchor 不特定での blind traverse は禁止。

Anchor 特定の優先順位 (構造的に固定、各 step は precedent step 不成立時のみ次に進む):

1. User が explicit に SID/name で指定 → 採用
2. `MEMORY.md "Active Resume Points"` 等の harness-delivered context index に sid+name pair → 採用 (delivery_channel が harness_specific であることは Phase 1.5 で articulated 済)
3. `dream_scan mode:'scan'` で recent L2 を walk → tags / description match で候補抽出 → user 確認
4. いずれも識別不能 → Invariant 3 (Honest absence) 発動、traverse 呼ばず

根拠: Anchor なし traverse は無根拠探索であり、Phase 1 の graph 構造を迂回する。Invariant 2 は traverse の **必要条件** を規定する。

### Invariant 3 — Honest absence (誠実不在 / Phase 1.5 Honest unknown 継承)

Anchor が identify できない、または traverse が空集合を返した場合、**LLM は recall failure を articulate して response を進める**。連続性を fabricate しない。「前回 X を決めました」と書く前に、その X の出典 L2 を name で参照可能でなければならない。

これは epistemological honesty: graph 不在 ≠ 過去不在、graph 不在 = 「reified state が今の私から見えない」。Response は graph 不在を明示し、必要なら user に anchor 提供を求める。

### Invariant 4 — Recall-source acknowledgment (想起源申告 / Phase 1.5 Acknowledgment 継承)

Recall 結果を使用した response には、**どの L2 anchor から、どのエッジを辿って、どの node を引用したか** を articulate しなければならない。Silent absorption 禁止。

これは Phase 1.5 Acknowledgment invariant の skill 層継承: tool execution の harness-dependency articulation と同型に、recall 経由情報の **provenance 申告** を義務化する。Operator (人間) は LLM の output が「自身の推論」か「graph recall に基づく既決事項の継承」かを区別できる。

最小 articulation 内容 (schema floor): anchor identity + 走査エッジ + 引用 node identity。形式は固定しない (自然言語可、structured form 可) — 重要なのは articulation の **実施** であり形式の統一ではない。具体 schema 提案は §5。

### Invariant 5 — Doctrine-not-mechanism (Phase 1.5 Declare-not-enforce 継承)

`context_graph_recall` skill は LLM が読んで自発判断するための **doctrine** である。Auto-trigger (skill auto-invocation、CLAUDE.md auto-load hint) は orthogonal な mechanism であり別 layer (harness-specific / Case D)。

Doctrine は宣言する。LLM が判断する。Mechanism が強制するのではなく、内面化した doctrine が self-trigger を促す — これが Case A の設計意図。強制 trigger は judgment を奪い、Phase 1.5 の Declare-not-enforce 精神に違反する。

### Invariant 6 — Self-referential consistency (自己言及整合性)

このスキル自身が後日「`context_graph_recall` doctrine はどこで決まったか」「なぜこう設計されたか」と問われる時、その答えは同一の `dream_scan mode:'traverse'` を通じて取得可能でなければならない。Doctrine が自身に適用できないなら、設計に自己矛盾がある。

根拠: KairosChain の Generative Principle (meta-level と base-level の構造的同一性)。Recall doctrine が自身の genesis に適用できることは、設計の正当性チェックである。本 v1.0 の design L2 が完成後、Invariant 6 を成立させるための self-referential check を §10 test として要求する。

## §3 Trigger 性質 (列挙ではなく property 規定)

Recall を warrants する task の **property**: semantic completion が prior reified work への informational reference なしに成立しない。

判定の operational form (LLM 内部での自問): 「この task に正しく答えるために、私が今持っていない情報がある。その情報は過去のセッション・設計・判断・handoff に reify されている可能性があるか」。Yes であれば anchor 特定に進む (Invariant 2)、No であれば recall 不要。

例示 (列挙ではなく property の instantiation として):

- handoff の "next step" を実行する task → reified work = handoff 本体
- 「前回 X について何を決めたか」 → reified work = X を扱った過去 L2
- 既存設計の patch を書く task → reified work = 元設計 L2 / draft
- "Active Resume Points" に sid+name が surface された状態の任意 task → 該当 sid+name が anchor 候補

これらは property の typical instantiation であり、列挙の境界ではない。新しい phrasing でも property が真であれば trigger する。

## §4 Recall 手順 — 不変的順序

Recall は以下の順序で進む。各 step は precedent step の成功時のみ次に進む。順序は invariant — 段階の skip も逆順実行も doctrine 違反。

1. **Anchor identification** (Invariant 2 の優先順位に従う)
2. **Traverse 実行**: `dream_scan mode:'traverse' start_sid:<sid> start_name:<name> max_depth:<n>`
3. **取得内容の評価**: 返却 nodes が task の informational dependence を解消するか LLM が判断。Bear する nodes を recall set として確定。不足時は隣接 anchor からの再 traverse 検討、それでも不足なら Invariant 3 発動
4. **Articulation**: response に Invariant 4 準拠の provenance 記述を含める
5. **Continuation**: recall set を context として task に進む

`max_depth` の guidance (heuristic、doctrine の floor ではない): default 3、handoff chain 追跡のように深い informed_by 連鎖を要する task では 5+。これは Doctrine-not-mechanism (Invariant 5) を保つため **soft guidance** であり、LLM が task に応じて判断する。

Step 2 で空、または step 3 で「bear する node なし」の時は Invariant 3 を発動して step 4 で recall failure を articulate、step 5 は recall なし context で進む。

## §5 Acknowledgment 形式

Invariant 4 (Recall-source acknowledgment) の最小 schema floor:

- **Anchor**: `v1:<sid>/<name>` (起点 L2)
- **Traversal**: depth + nodes_walked count
- **Recall set**: 引用に使った node identity の list
- **Evaluation**: `sufficient` / `partial` / `no_match`

形式の自由度: 自然言語で「セッション `<sid>` の `<name>` を起点にグラフを走査した結果、関連する 3 件の handoff を得た — 主に X について Y と決定済み」と書く形でも、structured block 形式でも可。Doctrine が固定するのは **schema floor** であり formatting ではない (Phase 1.5 `with_acknowledgment` helper のような runtime API field injection は Case A scope 外、別 invariant に発展する場合 Phase 2+ で扱う)。

Recall を試みたが空であった場合も articulation は必要: 「`<anchor>` を起点に走査したが、関連する prior work は見つからなかった」。Invariant 3 と Invariant 4 は両方適用される。

**Non-recall との区別**: LLM が recall を行わずに応答する場合 (Invariant 1 の trigger 不成立)、その旨を宣言する義務はない。Acknowledgment 義務は recall を **実施した** 時にのみ発生する。

## §6 Composability

### `kairos-knowledge` skill との関係

`kairos-knowledge` は L1 knowledge 一般への access skill。`context_graph_recall` は **temporal/relational recall に specialize した同格 sibling skill** であり、`kairos-knowledge` の subset でも extension でもない。

両者の境界: `kairos-knowledge` は「project convention や accumulated insight (時間軸薄)」を扱い、`context_graph_recall` は「過去 session work の連続性 (時間軸濃)」を扱う。L1 doctrine は普遍的、L2 reified work は session-specific — 両者は orthogonal。Skill 起動の判断は task 性質次第: convention / pattern を引きたければ kairos-knowledge、prior session の決定/handoff を引きたければ context_graph_recall。両 skill が同 task で必要な場合、**並列**起動可。Doctrine 層では順序強制せず。

### `capability_status` pre-flight check

`dream_scan` は `:core` tier (Phase 1.5 §8 declared)。よって `context_graph_recall` doctrine は capability tier を pre-flight check する **必要は構造上ない** — `:core` は MCP プロトコル + filesystem のみで完結する保証であり、harness 非依存。

**重要 (構造的理由)**: Doctrine 自体は capability_status 呼び出しを **prerequisite として要求してはならない**。Pre-flight を doctrine の前提に組み込むと、Case A doctrine 自身が `capability_status` 経由 (= harness layer の articulation 機構) に依存することになり、`:core` tier の閉包から滑り落ちる。Pre-flight は **option** であり doctrine の **prerequisite ではない**。

LLM が pre-flight を選択する自由はある (best practice として有用な場合あり)、しかし doctrine がそれを invariant として要求しない。

### Phase 2 Case B / C との関係

- **Case B** (`dream_scan mode:scan` の edge 数併記、`:core`): doctrine は scan 結果に edge 数があれば anchor 候補 ranking に使うが、edge 数 absent でも description / tags ベース fallback で動作する (Case A doctrine は Case B 完成を前提としない)
- **Case C** (reverse traversal、`:core`): forward traversal で anchor → 子孫の recall は Case A doctrine で完結。Reverse (「私を informed_by している L2 は何か」) は Case C 実装後に doctrine extension を別 v1.x で追加。Case A v1.0 では forward only、これを invariant として明示

これは Forward-only metadata invariant (Phase 1.5) の skill 層類比: doctrine は逐次拡張、現時点 articulation の限界を honest に articulate。

## §7 哲学的位置づけ

### 命題 5 (constitutive recording / Kairotic temporality)

L2 への記録は constitutive — 記録は事後 evidence ではなく system の being の reconstitution。Context graph はその記録同士の relation を articulate した structure。

`context_graph_recall` doctrine は **Kairotic temporality を operational に行使する skill**: 過去の決定を recall することは「過去」を再呼び起こすことではなく、**現在の operation を過去の reified state に anchor し直すこと**。Recall の度に system の現在は過去との connection を再構成する。

Informational dependence (Invariant 1) が recall を要求する瞬間は、技術的検索要求ではなく **constitutive continuity の維持要求** — 「この瞬間に graph を参照しなければ、system の構成的蓄積が空洞化する決定的瞬間」である。

### 命題 7 (metacognitive self-referentiality)

Doctrine は LLM が自身の epistemic state を観察する skill: 「この task は私が今知らない prior state を仮定しているか?」。これは metacognition の operational form。

Phase 1.5 の Acknowledgment invariant が外部依存への metacognition だったのに対し、Case A の Recall-source acknowledgment (Invariant 4) は **過去自己への metacognition** — system 自身が時間的に内側で分岐し、現在の自己が過去の自己に依存していることを articulate する。

### 自己言及性の構造的閉包 (Invariant 6 との対応)

`context_graph_recall` doctrine 自身は L1 knowledge であり、その design 経緯 (本 v1.0 設計 L2 等) も context graph に reified される。よって future session で「context_graph_recall doctrine の design rationale」を recall する task は、**doctrine 自身を invoke して doctrine 自身の起源を traverse する** — 構造的自己言及性が成立し、Generative Principle (meta-level と base-level の構造的同一性) に整合する。

設計の self-referential check: このスキルが将来「なぜ context_graph_recall はこう設計されたか」と問われた時、答えは `informed_by` エッジを辿ることで取得可能。Doctrine が自身の回答経路を自身が定義する recall 手順で取得可能であるなら、設計は self-consistent。

## §8 配置

L1 Distribution Policy (memory) より、harness-aware doctrine は両 location 必要:

- **canonical**: `KairosChain_mcp_server/knowledge/context_graph_recall/context_graph_recall.md` (gem-bundled, read-only)
- **mirror**: `KairosChain_mcp_server/templates/knowledge/context_graph_recall/context_graph_recall.md` (`kairos init` 時 local copy、`system_upgrade` で 3-way merge)

Recall 手順自体は harness 非依存 (`:core`) だが、Active Resume Points (MEMORY.md) や L2 frontmatter の運用解釈は環境固有設定に依存する余地がある — user-editable copy を `templates/` に配置することで運用環境に応じた調整可能。`design_to_implementation_workflow` 等の既存両 location 配置 pattern に準拠。

Content の **consumer**: KairosChain orchestrator LLM (どの harness で動くかに関わらず)。
**Update cadence**: invariants 変更時 (= 設計 round 経由)、Case B/C 完了による doctrine extension 時。

## §9 実装ステップ

1. **L1 markdown 執筆**: 上記 §2〜§6 を要約した形で `context_graph_recall.md` を canonical / mirror 両 location に配置。LLM consumer 向けなので冗長な setup explanation は省き、6 invariants + procedure + acknowledgment schema を中核に置く。Frontmatter は `name` / `description` / `tags` / `version: "1.0"` / `date` を含む
2. **Templates mirror 作成**: `templates/knowledge/context_graph_recall/` に同内容コピー
3. **Knowledge index 確認**: `mcp__kairos-chain__knowledge_list` で `context_graph_recall` が列挙されることを確認 (手動管理なら追記)
4. **kairos-knowledge との接続確認**: `mcp__kairos-chain__knowledge_get skill: 'context_graph_recall'` が内容を返すこと
5. **既存 doctrine との cross-reference**: `kairoschain_capability_boundary` L1 から `context_graph_recall` への mention 追加 (Acknowledgment continuity が Phase 1.5 Acknowledgment invariant の継承であることを bidirectional に articulate)
6. **Multi-LLM review** (round 1 が本 v1.0 review)、修正後 doctrine を knowledge に commit
7. **L2 handoff 作成**: Case A 完了 handoff、Case C 着手のための informed_by を含む
8. **Self-referential test 実行**: §10 参照 (Invariant 6 実証)

## §10 テスト suite

Doctrine は Markdown であり実行時 code を持たない。Test は presence / parseability / 構造検証に限定:

- **File presence**: canonical + mirror 両 location に file が存在
- **Frontmatter parseability**: YAML frontmatter が valid、`name` / `description` / `tags` / `version` を含む
- **knowledge_list 登録**: `mcp__kairos-chain__knowledge_list` 出力に `context_graph_recall` 含有
- **knowledge_get 取得**: `mcp__kairos-chain__knowledge_get` で内容が空でない
- **Cross-reference integrity**: `kairoschain_capability_boundary.md` から `context_graph_recall` への reference が dead link でない (mutual coherence)
- **Self-referential recall test** (semi-formal、manual): doctrine 完成後の design L2 を `dream_scan mode:'traverse'` で walk し、本 draft → 関連 handoff → Phase 1 完了 L2 の chain が再現することを 1 回手動確認 (Invariant 6 実証)。CI 自動化不要

Doctrine の semantic correctness (LLM が actually doctrine 通り動くか) は test では検証しきれない — multi-LLM review + 実 session での observation で評価する。これは doctrine 全般の test 限界として明示。

## §11 Phase 2 Case A で持ち越さない事項

- **Auto-trigger 機構** (Case D, harness-specific): CLAUDE.md auto-load hint、skill auto-invocation
- **Edge 数 surface in scan** (Case B, `:core`): Anchor 候補 ranking 改善、Case A doctrine は scan の edge metadata 不在でも動く設計
- **Reverse traversal** (Case C, `:core`): forward-only doctrine、Case C 完成後 doctrine extension で取り込み
- **Runtime acknowledgment helper for recall** (Phase 2+): Phase 1.5 `with_acknowledgment` 相当の recall 専用 helper。Case A v1.0 では doctrine schema 規定のみ、helper 化は Case B/C と統合検討
- **Recall result の persistence / caching** (Phase 3+): traverse 結果を session memory に keep して短時間内再 recall 抑制
- **Multi-anchor parallel traverse** (Phase 3+): 複数 anchor から同時走査して union を取る、Case A は single anchor 前提
- **Recall quality metric** (Phase 3+): `recall_evaluation` を `sufficient/partial/no_match` の 3 段階より細かく評価
- **kairos-knowledge との auto-routing** (Phase 3+): task 性質から両 skill を自動 dispatch する meta-doctrine
- **LLM 内面化の自動評価** (Phase 3+): doctrine が LLM に正しく内面化されているかの自動 test、評価方法未確立

## §12 Open questions (multi-LLM review に渡す)

1. Invariant 1 の trigger property 規定 (「semantic completion が prior reified work への informational reference なしに成立しない」) は LLM が判定可能なほど operational か? より具体的な signal が必要か?
2. §5 Acknowledgment schema floor は文章 articulation で十分か、それとも structured field (machine-readable) を doctrine が要求すべきか?
3. §6 Composability で `kairos-knowledge` と並列起動可としたが、両 skill の output 重複時の precedence rule は doctrine に必要か?
4. §10 の test 限界 (semantic correctness 不可検証) は acceptable か? Doctrine 全般の test limit として明示すべきか?
5. Invariant 6 の self-referential consistency は invariant として promote するに値するか、それとも §7 哲学に留めるべきか? (4.6 sub-author 提案で promote した — 設計正当性 check として operative かどうか review 判断)

## §13 Reject log (4.7 main + 4.6 sub-author 統合決定)

| ID | 4.7 main | 4.6 sub-author | 統合決定 | 根拠 |
|---|---|---|---|---|
| R1 | Invariant 5 個 (Self-referential を §7 哲学に置く) | Invariant 6 個 (Self-referential consistency を invariant に promote) | **6 個採用** | 4.6 案: invariant として置くと「設計正当性 check として operative」になる。§7 哲学のみだと宣言が弱く、Invariant 6 として明示することで Generative Principle との対応が doctrine 層で articulate される。Open question 5 で review に問う |
| R2 | §3 に non-trigger 条件 articulation なし | 「現在 context が既に必要情報を含む時 recall 不要」を明示 | **4.6 案採用** | Non-trigger の articulation は重複 traverse 防止のため operational に必要。Invariant 1 直下の note として merge |
| R3 | §4 で 5 step (continuation 含む) | §4 で 4 step | **5 step (4.7 案) 採用** | Continuation step を明示することで「recall set を context として task に進む」が doctrine の最終 step であることが明確化。Invariant ordering として 4 step で済むが、5 step articulation で doctrine の **full lifecycle** が示される |
| R4 | `max_depth` default 3、handoff chain は 5+ | `max_depth` 2-3 が「通常」 | **default 3 + handoff 5+ note (4.7 寄り) 採用** | 4.6 sub-author flag: 「mechanism-like で削除候補」。しかし floor を完全に消すと LLM の判断が完全自由になり Doctrine-not-mechanism 精神は守られるが operational guidance が失われる。**heuristic / soft guidance** として留め、Invariant 5 で「LLM 判断尊重」を明示することで doctrine と guidance の境界を保つ |
| R5 | §6 capability_status pre-flight: 「doctrine が prerequisite として要求してはならない、構造的理由で `:core` 閉包から滑り落ちる」(強い禁止) | 「best practice、prerequisite ではない」(soft) | **4.7 案採用 (強い禁止)** | 4.6 sub-author flag: 「pre-flight 強化を merger 判断」。**4.7 framing が構造的に正しい** — pre-flight を doctrine 内部に組み込むと doctrine 自身が `:core` から `:harness_assisted` に滑り落ちる、という invariant 由来の理由がある。LLM が呼ぶ自由はある旨を補足明記で 4.6 の柔軟性も保つ |
| R6 | §5 Acknowledgment に structured schema (anchor / depth / nodes_walked / nodes_used / recall_evaluation) | 「形式は固定しない、自然言語可」 | **両者統合: schema floor + 形式自由** | 4.7 の structured schema を **schema floor** として位置づけ (最小 articulation 内容 = anchor + edges + recall set)、4.6 の「formatting 自由」を form layer に保持。Form と content を分離した articulation で両案が共存 |
| R7 | §7 で命題 5 と 7 を別 subsection で扱う | 命題 5/7 を別 subsection で扱う、自己言及性も別 subsection | **4.6 案 (3 subsection) 採用** | 4.6 sub-author flag: 「4.7 が命題を collapse する可能性」。実際 4.7 案も別 subsection で書いているが 4.6 の subsection 切り方 (5 / 7 / 自己言及) のほうが Invariant 6 promote と整合 |
| R8 | §12 open questions 4 個 | open questions section なし | **4.7 案採用 + Invariant 6 promote 由来の 5 個目追加** | Multi-LLM review 焦点化のため open questions を残す。Invariant 6 promote 判断を review にも問うため question 5 追加 |
| R9 | §11 backlog に「recall result persistence」「multi-anchor parallel」「recall quality metric」「kairos-knowledge auto-routing」 | 「LLM 内面化の自動評価」を追加 | **両者 union 採用** | Backlog は exhaustive である必要はないが両者で挙がった項目はすべて記載、Phase 3+ scope の articulation を厚くする |

**reject なし** (片方のみ採用、他方を捨てた決定): 4.7 / 4.6 ともに対立するアサーションがなく、表現の差異・articulation の厚みの差異のみ。R1 (invariant promote) と R5 (pre-flight 強さ) が最大の merger judgment 点。

---

*End of v1.0 (integrated by claude-opus-4-7-integrator from 4.7-main + 4.6-sub-author drafts).*
