---
name: context_graph_recall_design
description: KairosChain Phase 2 Case A v1.0 — L1 skill `context_graph_recall` の doctrine 化。L2 header に蓄積された context graph を LLM (orchestrator) が自発的に参照する条件と手順を invariant で規定する。harness 非依存 (`:core`)、auto-trigger (Case D 領分) とは separation。
tags: [design, context-graph, phase2, case-a, l1-doctrine, recall, harness-agnostic]
type: design_draft
version: "1.0"
authored_by: claude-opus-4-7-main-author
date: 2026-05-03
---

# KairosChain Phase 2 Case A: L1 skill `context_graph_recall` (v1.0)

## §1 動機

Phase 1 で context graph の infrastructure (L2 frontmatter `relations`、`dream_scan mode:'traverse'`) は完成した。しかし現状 LLM (KairosChain orchestrator) が graph を参照するのは **明示的に依頼された時のみ** であり、L2 header に存在する relations は「保管されているが認知されていない」状態にある。

これは Phase 1.5 で articulate された conflation 問題の rec recurrence: 構造が存在することと、LLM がそれを認識して active に使うことは別事象である。Phase 1 の output は **可読 graph**、Phase 2 Case A の output は **graph を読みに行く判断条件と手順の doctrine 化** である。

Case A は doctrine 層 — 「いつ・どう graph を引くか」を L1 knowledge として記述し、orchestrator LLM が自発判断する。Auto-trigger 機構 (CLAUDE.md hint 等) は harness-specific (Case D) で別 layer。Edge 数 surface (Case B) と reverse traversal infrastructure (Case C) は doctrine が呼び出す資源を拡張するが、doctrine 自体は Case A で完結する。

## §2 設計原則 (5 不変条件)

### Recall-trigger invariant

**任意のタスクが、過去の reified work (L2 handoff、過去 session の決定、依存関係) への informational reference なしに完成し得ない時、orchestrator LLM は context graph recall を試みなければならない**。

これは finite list (resume / continuation / inheritance / ... の列挙) ではなく、**property** として規定される: 「semantic completion が prior reified state への参照を要求する」という条件。User の phrasing (「続きから」「前回」「先日の」) は trigger の symptom であり判定基準ではない。判定基準は task そのものの informational dependence。

### Anchor-identification precedence invariant

Recall は必ず **anchor (起点 L2) の特定** から始まる。Anchor 特定なしの blind traverse は禁止 — 関連性のない L2 を hallucinate する経路になる。

Anchor 特定の優先順位は構造的に固定:
1. User が explicit に SID/name で指定 → 採用
2. MEMORY.md "Active Resume Points" 等の harness-delivered context index に sid+name pair → 採用 (delivery_channel が harness_specific であることは Phase 1.5 で articulated 済)
3. `dream_scan mode:'scan'` で recent L2 を walk → tags / description match で候補抽出 → user 確認
4. いずれも識別不能 → **honest non-availability 返却**、嘘で埋めない

優先順位は「不確実性が低い経路から」という invariant 条件であり、各 step は条件付き実行 (precedent step が不成立の時のみ次を試す)。

### Honest non-availability invariant (Phase 1.5 Honest unknown の skill 層継承)

Anchor が identify できない、または traverse が空集合を返した場合、**LLM は recall failure を articulate して response を進める**。連続性を fabricate しない。「前回 X を決めました」と書く前に、その X の出典 L2 を name で参照可能でなければならない。

これは epistemological honesty: graph 不在 ≠ 過去不在、graph 不在 = 「reified state が今の私から見えない」。Response は graph 不在を明示し、必要なら user に anchor 提供を求める。

### Acknowledgment continuity invariant (Phase 1.5 Acknowledgment の skill 層継承)

Recall 結果を使用した response には、**どの L2 anchor から、どの depth まで、何個の node を経由したか** を articulate しなければならない。Silent absorption 禁止。

具体的には response に以下相当の articulation を含む:
- recall anchor: `v1:<sid>/<name>`
- traversal depth / node count
- 引用に使った node の identity (どの L2 から、どの statement か)

これは Phase 1.5 Acknowledgment invariant が tool execution の harness-dependency を articulate したのと同型 — recall 経由情報の **provenance 申告**。Operator (人間) は LLM の output が「自身の推論」か「graph recall に基づく既決事項の継承」かを区別できる。

### Doctrine-not-mechanism invariant

`context_graph_recall` skill は LLM が読んで自発判断するための **doctrine** である。Auto-trigger (skill auto-invocation、CLAUDE.md auto-load hint) は orthogonal な mechanism であり別 layer (harness-specific)。

これは Phase 1.5 Declare-not-enforce invariant の skill 層適用: doctrine は articulation のためであり、enforcement のためではない。LLM が doctrine を読んで判断する自由を保つ — 強制 trigger は judgment を奪う。

## §3 Trigger 性質 (列挙ではなく property 規定)

Recall を warrants する task の **property**: semantic completion が prior reified work への informational reference なしに成立しない。

例示 (列挙ではなく property の instantiation として):
- ある handoff の "next step" を実行する task → reified work = handoff 本体
- 「前回 X について何を決めたか」 → reified work = X を扱った過去 L2
- 既存設計の patch を書く task → reified work = 元設計 L2 / draft
- "Active Resume Points" に sid+name が surface された状態の任意 task → 該当 sid+name が anchor 候補

判定方法 (LLM 内部): task statement を読んで「この task の output が、私が今知らない prior decision/state を仮定しているか」を自問。仮定があれば recall を試みる。仮定がなければ recall 不要 (Phase 1 graph は無関係)。

Property の articulation 自体が doctrine の中核 — finite list を作ると trigger が固定化し、property の generality が失われる。

## §4 Recall procedure invariant

Procedure は以下の **不変順序** で進む。各 step は precedent step の成功時のみ次に進む:

1. **Anchor identify** (§2 Anchor-identification precedence)
2. **Traverse 実行**: `dream_scan mode:'traverse' start_sid:<sid> start_name:<name> max_depth:<n>`。`max_depth` は task の depth 要求に応じて (default 3、handoff chain 追跡なら 5+)
3. **結果評価**: 返却 nodes が task に informational に bear するか LLM が判断。Bear する nodes を recall set として確定
4. **Articulation**: response に Acknowledgment continuity invariant 準拠の provenance section を含める
5. **Continuation**: recall set を context として task に進む

Step 2 で空、または step 3 で「bear する node なし」の時は **Honest non-availability invariant** を発動して step 4 で recall failure を articulate、step 5 は recall なし context で進む。

順序は invariant — anchor 前の traverse、articulation 前の continuation 等の倒置は doctrine 違反。

## §5 Acknowledgment 形式 (Phase 1.5 patterns の skill 層適用)

Response 内 Acknowledgment block の最小 schema:

```
[recall provenance]
- anchor: v1:<sid>/<name>
- depth: <n>
- nodes_walked: <count>
- nodes_used: [v1:<sid>/<name>, ...]
- recall_evaluation: <"sufficient" | "partial" | "no_match">
```

これは LLM が response 中に書く文章の一部であり、tool API field ではない (doctrine だから — Phase 1.5 `with_acknowledgment` helper のような runtime injection は Case A scope 外、別 invariant に発展する場合 Case B/C で扱う)。

最小 schema を超える詳細 (引用箇所の正確な抜粋等) は task 性質次第で extend 可。doctrine は schema floor のみを規定する。

## §6 Composability

### `kairos-knowledge` skill との関係

`kairos-knowledge` は L1 knowledge 一般への access skill。`context_graph_recall` は **temporal/relational recall に specialize した sibling skill** であり、`kairos-knowledge` の subset でも superset でもない。

両者の境界: `kairos-knowledge` は「project convention や accumulated insight (時間軸薄)」を扱い、`context_graph_recall` は「過去 session work の連続性 (時間軸濃)」を扱う。Skill 起動の判断は task 性質: convention / pattern を引きたければ kairos-knowledge、prior session の決定/handoff を引きたければ context_graph_recall。

両 skill が同 task で必要な場合、**並列**起動可。Doctrine 層では順序強制せず。

### `capability_status` pre-flight check

`dream_scan` は `:core` tier (Phase 1.5 §8 で declared)。よって `context_graph_recall` doctrine は capability tier を pre-flight check する**必要は構造上ない** — `:core` は MCP プロトコル + filesystem のみで完結する保証であり、harness 非依存。

ただし doctrine 自体は capability_status の存在を前提にしてはならない: harness が capability_status を出力する経路は `:core` だが、doctrine が「pre-flight 済」を assert すると case A が `:core` から `:harness_assisted` に滑り落ちる。Pre-flight は **option**、doctrine の **prerequisite ではない**。

### Phase 2 Case B / C との関係

- Case B (`dream_scan mode:scan` の edge 数併記): doctrine は scan 結果に edge 数があれば anchor 候補 ranking に使うが、edge 数 absent の場合 description / tags ベース fallback で動作する (Case A doctrine は Case B 完成を前提としない)
- Case C (reverse traversal): forward traversal で anchor → 子孫の recall は Case A doctrine で完結。Reverse (「私を informed_by している L2 は何か」) は Case C 実装後に doctrine extension を別 v1.x で追加。Case A v1.0 では forward only、これを invariant として明示

これは Forward-only metadata invariant (Phase 1.5) の skill 層類比: doctrine は逐次拡張、現時点 articulation の限界を honest に articulate。

## §7 哲学的位置づけ

### Proposition 5 (constitutive recording / Kairotic temporality)

L2 への記録は constitutive — 記録は事後 evidence ではなく system の being の reconstitution。Context graph はその記録同士の relation を articulate した structure。

`context_graph_recall` doctrine は **Kairotic temporality を operational に行使する skill**: 過去の決定を recall することは「過去」を再呼び起こすことではなく、**現在の operation を過去の reified state に anchor し直すこと**。Recall の度に system の現在は過去との connection を再構成する。

### Proposition 7 (metacognitive self-referentiality)

Doctrine は LLM が自身の epistemic state を観察する skill: 「この task は私が今知らない prior state を仮定しているか?」。これは metacognition の operational form。

Phase 1.5 の Acknowledgment invariant が外部依存への metacognition だったのに対し、Case A の Acknowledgment continuity は **過去自己への metacognition** — system 自身が時間的に内側で分岐し、現在の自己が過去の自己に依存していることを articulate する。

### 自己言及性 check

`context_graph_recall` doctrine 自身は L1 knowledge であり、その design 経緯 (本 v1.0 設計 L2 等) も context graph に reified される。よって future session で「context_graph_recall doctrine の design rationale」を recall する task は、**doctrine 自身を invoke して doctrine 自身の起源を traverse する** — 構造的自己言及性が成立する (Generative Principle に整合)。

## §8 配置

L1 Distribution Policy (memory) より、harness-aware doctrine は両 location 必要:

- **canonical**: `KairosChain_mcp_server/knowledge/context_graph_recall/context_graph_recall.md` (gem-bundled, read-only)
- **mirror**: `KairosChain_mcp_server/templates/knowledge/context_graph_recall/context_graph_recall.md` (`kairos init` 時 local copy、`system_upgrade` で 3-way merge)

理由: harness 環境差で recall procedure は不変 (`:core`) だが、user が local で doctrine を adjust する余地を残す (kairos init copy は editable、gem 内 canonical は upgrade で更新される)。

Content の **consumer**: KairosChain orchestrator LLM (どの harness で動くかに関わらず)。
**Update cadence**: invariants 変更時 (= 設計 round 経由)、Case B/C 完了による doctrine extension 時。

## §9 実装ステップ

1. **L1 markdown 執筆**: 上記 §1〜§7 を要約した形で `context_graph_recall.md` を canonical / mirror 両 location に配置。**LLM consumer 向け**なので冗長な setup explanation は省き、invariants + procedure + acknowledgment schema を中核に置く
2. **Knowledge index への追加**: `knowledge_list` MCP tool で見える状態を確保 (既存 knowledge 配置と同パターン、追加 wiring 不要なら省略)
3. **Self-referential test**: Phase 2 Case A の design L2 を作成 (本 draft 完成後)、それを `context_graph_recall` doctrine に従って recall する手順を実演 (semi-formal test、§10 参照)
4. **既存 doctrine との cross-reference**: `kairoschain_capability_boundary` L1 から context_graph_recall への mention 追加 (Acknowledgment continuity が Phase 1.5 Acknowledgment invariant の継承であることを bidirectional に articulate)
5. **Multi-LLM review** (round 1 が本 v1.0 review)、修正後 doctrine を knowledge に commit
6. **L2 handoff 作成**: Case A 完了 handoff、Case C 着手のための informed_by を含む

## §10 テスト suite

Doctrine は code ではないため test の性質が異なる:

- **Parseability test**: `context_graph_recall.md` が valid markdown + frontmatter parse する (既存 knowledge と同じ test pattern)
- **Knowledge index inclusion test**: `knowledge_list` の出力に `context_graph_recall` が含まれる
- **Self-referential recall test** (semi-formal): doctrine 完成後の design L2 を `dream_scan mode:'traverse'` で walk し、本 draft → 関連 handoff → Phase 1 完了 L2 の chain が再現することを手動確認 (test fixture 化は Case A scope 外)
- **Cross-reference integrity test**: `kairoschain_capability_boundary.md` から `context_graph_recall` への reference が dead link でない (mutual coherence)

Doctrine の semantic correctness (LLM が actually doctrine 通り動くか) は test では検証しきれない — multi-LLM review + 実 session での observation で評価する。これは doctrine 全般の test 限界として明示。

## §11 Phase 2 Case A で持ち越さない事項

- **Auto-trigger 機構** (Case D, harness-specific): CLAUDE.md auto-load hint、skill auto-invocation
- **Edge 数 surface in scan** (Case B, `:core`): Anchor 候補 ranking 改善、Case A doctrine は scan の edge metadata 不在でも動く設計
- **Reverse traversal** (Case C, `:core`): forward-only doctrine、Case C 完成後 doctrine extension で取り込み
- **Runtime acknowledgment helper for recall** (Phase 2+): Phase 1.5 `with_acknowledgment` 相当の recall 専用 helper。Case A v1.0 では doctrine schema 規定のみ、helper 化は Case B/C と統合検討
- **Recall result の persistence / caching** (Phase 3+): traverse 結果を session memory に keep して短時間内再 recall 抑制
- **Multi-anchor parallel traverse** (Phase 3+): 複数 anchor から同時走査して union を取る、Case A は single anchor 前提
- **Recall quality metric** (Phase 3+): "recall_evaluation" を `sufficient/partial/no_match` の 3 段階より細かく評価
- **kairos-knowledge との auto-routing** (Phase 3+): task 性質から両 skill を自動 dispatch する meta-doctrine

## §12 Open questions (multi-LLM review に渡す)

1. §3 の trigger property 規定で「semantic completion が prior reified work への informational reference なしに成立しない」は LLM が判定可能なほど operational か? より具体的な signal が必要か?
2. §5 Acknowledgment schema は文章 articulation で十分か、それとも structured field (machine-readable) を doctrine が要求すべきか?
3. §6 Composability で `kairos-knowledge` と並列起動可としたが、両 skill の output 重複時の precedence rule は doctrine に必要か?
4. §10 の test 限界は acceptable か? Doctrine の semantic test は principle として test 不能と articulate すべきか?

---

*End of v1.0-4.7-main (drafted by claude-opus-4-7-main-author).*
