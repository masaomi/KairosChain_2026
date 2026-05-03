---
name: context_graph_recall_design
description: KairosChain Phase 2 Case A v1.1 — round 1 multi-LLM review (0/5 APPROVE, 4 REJECT, 1 REVISE) で発見された P0/P1 を吸収。Invariant 6 demote (operational vs design-correctness の category 分離)、§4 ordering invariant collapse、§5 schema floor に literal identifier 要求、§2 inheritance honesty 明示。
tags: [design, context-graph, phase2, case-a, l1-doctrine, recall, harness-agnostic, acknowledgment, round2]
type: design_draft
version: "1.1"
authored_by: claude-opus-4-7-revisor
supersedes: context_graph_recall_design_v1.0
date: 2026-05-03
---

# KairosChain Phase 2 Case A: L1 skill `context_graph_recall` (v1.1)

## v1.0 → v1.1 主要変更

Round 1 review (5 reviewers, 0A/1REVISE/4REJECT、persona team 3/3 REVISE) で発見された P0/P1 への構造的応答:

- **Invariant 6 demote** (P0-skeptical, R1 merger 判断の reverse): operational invariant (Inv 1-5) と design-correctness invariant の type 分離、self-referential consistency は §7 哲学 + §10 mandatory test に格下げ
- **§4 ordering invariant collapse** (P0-philosophy/skeptical): 5-step procedure → 1 ordering invariant + 失敗 path 4 ケース prose
- **§5 schema floor に literal identifier 要求** (P0-skeptical): "anchor + traversal + recall set" を fluent prose で satisfy できなくする
- **§6 pre-flight 論証修正** (P0-skeptical): "tier slippage" 論証は誤 (capability_status 自身が `:core`)、"coherence concern" に reframe
- **§2 Invariant 2 priority list demote** (P0-philosophy): doctrine 本体から implementation note に移動
- **§2 inheritance honesty** (P0-skeptical): "8 inherited + 6 new" → "Phase 1.5 から 3 specializations + 2 recall-specific = 5"
- **Trust boundary / tool error / stale anchor** (P0-codex / P0-operator): §4 invariant に 3 failure path を articulate
- **Non-recall articulation hole** (P0-operator): symptom-shape task で non-recall も one-line ack 義務化
- **Inv 1 "must" / Inv 5 "no enforcement" tension** (P0-skeptical): "judgmentally must, mechanism-free" prose 明示

P2 advisory は §13 patch log に取り込み判断を articulate (一部採用、一部 §11 backlog 化、一部 reject)。

## §1 動機 (v1.0 から不変、API 言及補強)

Phase 1 で context graph infrastructure (L2 frontmatter `relations`、`dream_scan` の `mode:'traverse'` および anchor 探索用 `mode:'scan'` 両 mode) が完成した。しかし現状 LLM (KairosChain orchestrator) が graph を参照するのは **明示的に依頼された時のみ** であり、L2 header の relations は「保管されているが認知されていない」状態にある。

問題は認識論的空白: LLM は「前回 X について何を決めたか」を問われた時、graph を経由せず内部記憶から fabricate するか沈黙する。どちらも Phase 1 reified work を死蔵させ、Phase 1.5 で articulate された conflation 問題の recurrence を起こす。

Phase 2 Case A の output は **graph を読みに行く判断条件と手順の doctrine 化**。Doctrine 層であり infrastructure 層ではない。Auto-trigger (Case D)、edge surface (Case B)、reverse traversal (Case C) は別 case で扱う。

## §2 設計原則 (5 不変条件 + 1 design-correctness criterion)

Phase 1.5 の 8 不変条件のうち 3 つを recall 層に specialize し、recall-specific を 2 つ加える。**真新規 invariant は Inv 1 (Informational dependence) と Inv 2 (Anchor-before-traverse) の 2 つ**、Inv 3/4/5 は Phase 1.5 invariants の skill 層特化 — round 1 で指摘された "8+6" 表記の inflation を本 v1.1 で訂正する。

Self-referential consistency (v1.0 の旧 Inv 6) は **operational invariant ではなく design-correctness criterion** と分類し、§7 哲学 + §10 test に格下げ — operational invariants が runtime LLM 行動を律するのに対し、design-correctness criterion は doctrine 自身の well-formedness を律する別 type。

### Invariant 1 — Informational dependence trigger (recall-specific 真新規)

任意のタスクの semantic completion が、現在 context にない情報、かつその情報が prior reified work に存在し得る場合、LLM は recall を **judgmentally must** 試みる。

**「judgmentally must」の意味 (v1.1 明示)**: Doctrine は強い義務を declare するが、Inv 5 (Doctrine-not-mechanism) により runtime enforcement は存在しない — LLM が doctrine を内面化した上で自発判断する義務である。これは「recommendation」ではなく **doctrine-binding obligation**、ただし mechanism-free。Doctrine が「must」と書くのは strictness の performance ではなく、LLM が judgment を下す際の floor を articulate するため。

**Two-prong 判定** (v1.1、operator-persona round 1 P2 取り込み):
1. **Plausibility prong**: project に prior L2 history が存在し、当該情報が reify されている可能性があるか
2. **Absence prong**: 現在 context (CLAUDE.md / MEMORY.md / active L2) に当該情報が含まれていないか

両 prong 真の時のみ trigger 成立。Plausibility なし (= fresh project / 該当 topic の L2 history なし) の場合、判定は「No」で recall 不要。

判定は finite list ではなく property 規定。User の phrasing は trigger の symptom であり判定基準ではない。

### Invariant 2 — Anchor-before-traverse (recall-specific 真新規)

`dream_scan mode:'traverse'` の呼び出し前に、開始 anchor が **literal sid + name の形で identify** されなければならない。Anchor 不特定での blind traverse は禁止。Stale anchor (sid+name が `dream_scan` で resolve しない) も blind traverse と等価扱い — Inv 3 発動。

Anchor 解決の優先順位は **implementation note** として §6 末尾に移動 (round 1 P0-philosophy: 4-step priority list は invariant 本体ではなく resolution mechanism)。Invariant 自体は「literal anchor 必須、blind/stale 禁止」のみを規定。

### Invariant 3 — Honest absence (Phase 1.5 Honest unknown の skill 層 specialization)

Anchor 不特定、traverse 空集合、tool error (filesystem 等)、stale anchor resolve 失敗、いずれの場合も LLM は **recall failure を articulate して response を進める**。連続性を fabricate しない。

**Failure cause を区別して articulate** (v1.1、operator P0 取り込み):
- `anchor_not_identified` — どの優先順位 step も anchor を返さなかった
- `traverse_empty` — anchor は得たが traverse 結果が空
- `tool_error` — `dream_scan` が runtime error / filesystem 不在
- `stale_anchor` — anchor sid+name が resolve しない

これらは epistemological honesty の細分化 — LLM が「どの種類の不在か」を articulate することで operator (人間) が次手 (anchor 提供 / tool 修復 / topic 再考) を判断できる。

### Invariant 4 — Recall-source acknowledgment (Phase 1.5 Acknowledgment の skill 層 specialization)

Recall 結果使用 response には、以下を **literal identifier 形式で** articulate しなければならない (v1.1 強化、skeptical P0 取り込み):

- Anchor: 文字列リテラル `v1:<sid>/<name>` (省略不可、fluent prose で満たせない)
- Traversal: 走査エッジ数 (depth + nodes_walked count、numeric)
- Recall set: 引用に使った node identity の list (各 node は literal `v1:<sid>/<name>`)
- Evaluation: `sufficient` / `partial` / `no_match` のいずれか literal token

形式の自由度は依然あり (自然言語可、structured block 可) が、**literal identifiers (sid/name strings、numeric counts、evaluation token) は省略不可** — これがなければ Inv 4 違反。Provenance の performance ではなく provenance を達成するための floor。

**Non-recall articulation** (v1.1、operator P0 取り込み): Inv 1 trigger property の **symptom shape** に該当する task (handoff / "前回" phrasing / Active Resume Points 提示時等) で recall を実施しなかった場合、one-line non-recall acknowledgment を要求 — `"prior reified work judged absent / not required: <reason>"`。Symptom 不在の通常 task では non-recall 宣言義務なし。

### Invariant 5 — Doctrine-not-mechanism (Phase 1.5 Declare-not-enforce の skill 層 specialization)

`context_graph_recall` skill は LLM が読んで自発判断するための doctrine。Auto-trigger (skill auto-invocation、CLAUDE.md auto-load hint) は orthogonal な mechanism で別 layer (Case D, harness-specific)。

Doctrine は宣言、LLM が judgment、mechanism は強制せず。これは Inv 1 の "judgmentally must" と整合 — doctrine が義務を declare しても enforcement 機構は持たない、observable 性は Inv 4 acknowledgment の articulation を通じてのみ確保される。

## §3 Trigger 性質 (v1.0 から圧縮、Two-prong 規定で operational 化)

Recall を warrants する task の **property**: semantic completion が prior reified work への informational reference を要求 (= Inv 1 plausibility + absence の両 prong 真)。

LLM 内部の自問 (operational form):
1. この task の正答に必要だが私が今持っていない情報があるか? (absence prong)
2. その情報は project の L2 history に reify されている可能性があるか? (plausibility prong)

両者 Yes → anchor 特定へ、いずれか No → recall 不要。

例示 2 件 (列挙ではなく property の instantiation、round 1 P2 取り込みで 4 → 2 に trim):
- handoff の "next step" を実行する task → property 真 (handoff 本体が reify されている)
- "Active Resume Points" に sid+name が surface された状態の任意 task → property 真 (anchor が直接提供されている)

新 phrasing でも両 prong 真であれば trigger。

## §4 Recall 手順 — ordering invariant 1 つ (v1.0 5-step を collapse)

**Recall ordering invariant**: Anchor identification ≺ traverse execution ≺ result evaluation ≺ articulation ≺ continuation。各段階は precedent 段階の成功時のみ次に進む。順序逸脱 / 段階 skip は doctrine 違反。

Failure path (Inv 3 への合流条件):

- **Step 1 失敗** (anchor 不特定): Inv 3 cause `anchor_not_identified` 発動、step 2 不実行、step 4 で failure articulate
- **Step 2 tool error**: Inv 3 cause `tool_error`、step 3 不実行、step 4 で failure articulate
- **Step 2 stale anchor** (resolve 失敗): Inv 3 cause `stale_anchor`、step 4 で failure articulate。**重要 (v1.1、operator P0 取り込み)**: stale anchor 時、anchor name 文字列から内容を **infer してはならない** — step 1 を再実行 (anchor 優先順位の次 step) するか Inv 3 で停止
- **Step 3 で bear する node なし**: Inv 3 cause `traverse_empty` 相当、step 4 で failure articulate。**隣接 anchor 再 traverse は明示的に candidate anchor が literal sid+name で特定されている時のみ可** (v1.1 強化、operator P0 取り込み) — そうでなければ Inv 3 強制発動

`max_depth` heuristic (Inv 5 の soft guidance): default 3、handoff chain では 5+ — LLM が task 性質に応じて判断、doctrine の floor ではない。

**Trust boundary** (v1.1 新、codex P0 取り込み): Recall set を context として step 5 で使う際、recall set 内 node の content は **過去の reified state そのもの** であり信頼すべき (system 自身の memory)。但し L2 内容の semantic correctness は記録時点での判断に基づく — recall 結果が現在 context と矛盾する場合、矛盾を Inv 4 articulation で surface し、判断は LLM が下す (「過去自分が間違っていた」shifted understanding を吸収する余地)。Multi-user / 外部 source からの L2 受け入れ (Phase 3+) は §11 backlog。

## §5 Acknowledgment 形式 (v1.1 で literal identifier 要求強化)

Inv 4 の **schema floor** (literal 必須、省略不可):

- Anchor: literal `v1:<sid>/<name>`
- Traversal depth: integer
- Nodes walked: integer
- Recall set: literal `v1:<sid>/<name>` の list
- Evaluation: `sufficient` | `partial` | `no_match`

**最小行 template** (v1.1、operator P2 取り込み — drift 防止 fallback):
```
[recall] anchor=v1:<sid>/<name> depth=<n> walked=<m> nodes=[v1:<sid>/<name>, ...] eval=<sufficient|partial|no_match>
```

これを response 中の任意位置に literal 含めれば schema floor 満たす。Prose elaboration は optional。Floor を満たさない fluent-only acknowledgment ("I checked some prior context") は Inv 4 違反。

Recall failure 時の最小 template (Inv 3+4 同時適用):
```
[recall] cause=<anchor_not_identified|traverse_empty|tool_error|stale_anchor> attempted_anchor=<v1:.../... or "n/a">
```

Non-recall articulation (Inv 4 末尾項、symptom-shape task で recall 未実施時):
```
[no-recall] reason=<one-line>
```

## §6 Composability

### `kairos-knowledge` skill との関係 (v1.0 から不変)

`kairos-knowledge` は L1 generic access、`context_graph_recall` は temporal/relational specialization。同格 sibling、両者並列起動可。Output 重複時の precedence rule は doctrine layer に置かない (round 1 P2: doctrine forcing precedence = mechanism creep) — LLM が両 source articulate して synthesis 判断、operator が source provenance を見て解釈する。

### `capability_status` pre-flight (v1.1 で論証修正)

`dream_scan` は `:core` tier。`capability_status` 自身も `:core` (Phase 1.5 §8 declared)、よって `capability_status` を呼ぶこと自体は doctrine の tier を slip させない — round 1 P0-skeptical の指摘通り v1.0 の "tier slippage" 論証は誤。

**正しい reasoning (v1.1)**: Doctrine が capability_status を **prerequisite として要求** すると、doctrine の意味論が capability articulation 機構と coupled になる — これは tier slippage ではなく **coherence concern** (doctrine が「自身の前提が articulated か」を毎回 check するのは structural redundancy)。Pre-flight は best practice として LLM が選択する自由はあるが、doctrine が **invariant として要求しない**。Doctrine は capability_status 不在環境でも動作する。

### Phase 2 Case B / C との関係 (v1.0 から圧縮)

Forward-only 採用 (Case A v1.1 では reverse traversal なし、Case C 完成後 doctrine extension で取り込み)。Edge surface (Case B) absent でも description/tags fallback で動作。これは Forward-only metadata invariant (Phase 1.5) の skill 層類比。

### Anchor 解決 implementation note (v1.0 §2 Inv 2 から移動、round 1 P0-philosophy 取り込み)

Inv 2 が要求するのは「literal anchor で blind/stale でない」のみ。実際の anchor 解決手順は doctrine ではなく **implementation note** として推奨優先順位を示す (mechanism、不変条件ではない):

1. User explicit 指定
2. MEMORY.md "Active Resume Points" sid+name pair
3. `dream_scan mode:'scan'` で recent walk → tags/description match → user 確認
4. いずれも不成立なら Inv 3 発動

順序は LLM が judgment で逸脱可 — note。

## §7 哲学的位置づけ

### 命題 5 (constitutive recording / Kairotic temporality) — v1.0 から不変

L2 記録は constitutive、context graph はその relation の articulation。`context_graph_recall` doctrine は Kairotic temporality を operational に行使する skill: 過去 recall は現在 operation を過去 reified state に anchor し直すこと。Informational dependence (Inv 1) が recall を要求する瞬間は constitutive continuity の維持要求。

### 命題 7 (metacognitive self-referentiality) — v1.0 から不変

Doctrine は LLM が epistemic state を観察する skill。Phase 1.5 Acknowledgment が外部依存への metacognition、Case A の Recall-source acknowledgment (Inv 4) は **過去自己への metacognition** — 現在自己が過去自己に依存していることの articulation。

### Self-referential consistency (旧 Inv 6 demote 後の位置づけ)

`context_graph_recall` doctrine 自身は L1 knowledge、design 経緯は context graph に reified される。Future session で「design rationale」を recall する task は doctrine 自身を invoke して doctrine 自身の起源を traverse する。Generative Principle (meta-level と base-level の構造的同一性) との整合。

これは **operational invariant ではなく design-correctness criterion** (round 1 skeptical P0 指摘): Inv 1-5 が runtime LLM 行動を律するのに対し、self-referential consistency は doctrine 自身の well-formedness を律する type の異なる主張。Operational invariant の集合に flatten すると invariant 概念の precision を毀損する。

格下げ後の **operative form**: §10 mandatory self-referential test。Doctrine 完成 + design L2 作成 + relations:informed_by 設定 → `dream_scan mode:'traverse'` で本 design L2 から走査して genesis chain (Phase 1 完了 L2 等) が再現することを **必ず 1 回** 実機確認。Pass criteria は §10 で明示。

## §8 配置 (v1.0 から不変)

L1 Distribution Policy より両 location 必要:
- canonical: `KairosChain_mcp_server/knowledge/context_graph_recall/context_graph_recall.md`
- mirror: `KairosChain_mcp_server/templates/knowledge/context_graph_recall/context_graph_recall.md`

Consumer: KairosChain orchestrator LLM。Update cadence: invariants 変更 / Case B/C 完了。

## §9 実装ステップ (v1.1 で Inv 6 demote と P1 取り込み)

1. **L1 markdown 執筆**: §2-§6 を要約、5 invariants + ordering rule + acknowledgment schema floor を中核
2. Templates mirror 作成
3. `knowledge_list` 登録確認
4. `knowledge_get` 取得確認
5. `kairoschain_capability_boundary` から bidirectional cross-reference
6. **Design L2 作成 (v1.1 新、Inv 6 demote 後の self-ref test 前提)**: 本 v1.1 design 完成後、L2 として save、`relations: informed_by` で `phase1_5_complete_phase2_handoff` および関連 Phase 1 完了 L2 を target に設定。これがないと §10 self-referential test が成立しない (round 1 codex P1 取り込み)
7. Multi-LLM review (round 2 が本 v1.1 review)、修正後 commit
8. L2 handoff 作成 (Case A 完了 / Case C 着手用 informed_by)
9. **Self-referential test 実行 (mandatory once、§10)**

## §10 テスト suite (v1.1 で test 強化、pass criteria 明示)

Doctrine は Markdown、test は presence / parseability / 構造検証 + mandatory self-ref test:

- File presence (両 location)
- Frontmatter parseability
- `knowledge_list` 登録
- `knowledge_get` 取得
- Cross-reference integrity (`kairoschain_capability_boundary` ↔ `context_graph_recall` mutual)
- **Mandatory self-referential test** (v1.1、round 1 philosophy P2 + codex P1 取り込み):
  - Starting anchor: 本 design v1.1 の L2 (step 6 で作成済の sid+name)
  - Expected node set (minimum): 本 design L2 → `phase1_5_complete_phase2_handoff` → `context_graph_phase1_implementation_complete` の chain (3 nodes 以上)
  - Pass criteria: `dream_scan mode:'traverse' max_depth:3` で 3 nodes 以上が結果に含まれ、各 node の name が expected set と一致
  - 実機 1 回確認、CI 自動化不要 (doctrine の self-ref check として 1 度通れば structural commitment 成立)

Doctrine の **semantic correctness** (LLM が doctrine 通り動くか) は test 不可検証 — multi-LLM review + 実 session observation で評価。これは KairosChain doctrine 全般の test limit と整合 (Phase 1.5 にも同 limit)。

## §11 Phase 2 Case A で持ち越さない事項

- Auto-trigger 機構 (Case D, harness-specific)
- Edge 数 surface in scan (Case B, `:core`)
- Reverse traversal (Case C, `:core`)
- Runtime acknowledgment helper for recall (Phase 2+)
- Recall result persistence / caching (Phase 3+)
- Multi-anchor parallel traverse (Phase 3+)
- Recall quality metric 細分化 (Phase 3+)
- kairos-knowledge との auto-routing (Phase 3+)
- LLM 内面化の自動評価 (Phase 3+, 評価方法未確立)
- **Multi-user / 外部 L2 source の trust boundary** (v1.1 新、codex P0 trust boundary 取り込み): single-user 環境では recall set は system 自身の memory として trust、multi-user / Meeting Place からの L2 受け入れ時の authorization / scope boundary は Phase 3+
- **Runtime enforcement / observability infrastructure** (v1.1 新、cursor P1 取り込み): Inv 5 doctrine-not-mechanism により現状 doctrine 層では LLM 遵守に依存、observability は acknowledgment articulation のみ。Audit / replay / drift detection 機構は Phase 3+

## §12 Open questions (round 2 review に渡す)

1. Inv 1 two-prong (plausibility + absence) は v1.0 single-prong より operational か? Plausibility prong の判定 (project に L2 history が存在するか) 自体が recall の前段で必要になる recursion を起こさないか?
2. §4 ordering invariant collapse 後、prose の長さ / failure path 4 ケース articulation で実質 enumeration が戻っていないか? (round 1 philosophy/skeptical 双方の懸念への応答が十分か)
3. §5 literal identifier 要求は schema floor として bite するか? それでも fluent prose で迂回される余地があるか?
4. Inv 6 demote (operational invariant set から外す) は category precision を回復したか? それとも self-referential consistency が doctrine 内で軽量化されすぎたか?
5. §6 pre-flight reasoning 修正 ("tier slippage" → "coherence concern") は構造的に正しいか?

## §13 Patch log (v1.0 → v1.1)

| Finding | Source | 解決方法 | §影響 |
|---|---|---|---|
| F1 (P0-skeptical) Inv 6 category confusion | skeptical persona | demote、§7 + §10 mandatory test 化 | §2 構造、§7、§10 |
| F2 (P0-philosophy/skeptical) §4 5-step enumeration | philosophy + skeptical | ordering invariant 1 つ + failure path prose 4 ケース | §4 |
| F3 (P0-philosophy) §2 Inv 2 priority list enumeration | philosophy | implementation note へ移動 | §2 Inv 2、§6 末尾 |
| F4 (P0-skeptical) §6 pre-flight tier slippage 論証誤 | skeptical | "coherence concern" に reframe、capability_status `:core` を明示認 | §6 |
| F5 (P0-skeptical) §5 schema floor が prose で迂回可 | skeptical | literal identifier 必須化、最小 1 行 template 提供 | §5 |
| F6 (P0-skeptical) Inv 1 "must" vs Inv 5 "no enforcement" tension | skeptical | "judgmentally must, mechanism-free" prose 明示 | §2 Inv 1、Inv 5 |
| F7 (P0-skeptical) §2 inheritance double-counting | skeptical | "8+6" → "Phase 1.5 から 3 specializations + 2 recall-specific" honest 表記 | §2 序文 |
| F8 (P0-codex) §1 traverse only mention、Inv 2 で scan 必要 | codex_5.4 | §1 で Phase 1 が両 mode 提供を明示 | §1 |
| F9 (P0-codex) trust boundary missing | codex_5.4 | §4 末尾 trust boundary 段落、§11 multi-user 課題明示 | §4、§11 |
| F10 (P0-operator) anchor stale fallback / tool error 未規定 | operator | Inv 3 cause 4 種類、§4 failure path 4 ケース articulate | §2 Inv 3、§4 |
| F11 (P0-operator) non-recall silent drift hole | operator | symptom-shape task で one-line non-recall ack 義務化 | §2 Inv 4、§5 |
| F12 (P0-operator) §3 self-question over-trigger | operator | two-prong (plausibility + absence) 化 | §2 Inv 1、§3 |
| F13 (P1-cursor) Inv 5 enforcement / observability 不在 | cursor | §11 backlog で Phase 3+ 課題と articulate | §11 |
| F14 (P1-codex) adoption path 不在 | codex_5.4 | §9 step 6 (design L2 作成 + relations 設定)、§10 mandatory test | §9、§10 |
| F15 (P1-codex) §10 self-ref test に node/relation 作成 step なし | codex_5.5 | §9 step 6 で明示、§10 pass criteria 明示 | §9、§10 |
| F16 (P1-cursor) Inv 6 と §10 が同 traverse API 依存で循環 | cursor | Inv 6 demote で operational invariant 不依存化 | §2、§10 |
| F17 (P1-codex) authorization / scope boundary | codex_5.5 | §11 multi-user backlog で defer | §11 |
| F18 (P2-philosophy) §10 test を semi-formal → mandatory once に格上げ | philosophy | §10 で mandatory + pass criteria | §10 |
| F19 (P2-operator) self-question two-prong | operator | §2 Inv 1 で取り込み (F12 と統合) | §2 |
| F20 (P2-operator) min line template (drift 防止) | operator | §5 で `[recall] ...` 1 行 template 追加 | §5 |
| F21 (P2-skeptical) §3 4 examples → 2 trim | skeptical | trim 採用 | §3 |
| F22 (P2-skeptical) §11 backlog の invariant framing 欠如 | skeptical | backlog は性質上 enumeration、framing 強要せず (philosophy persona 同見解) | (no change) |
| F23 (P2-various) `kairos-knowledge` precedence rule | persona team unanimous | doctrine layer に置かず (mechanism creep)、LLM synthesis 判断に委ねる | (no change) |

**Reject (採用せず)**:
- skeptical 「§4 を 1 invariant + prose に圧縮しても failure path 4 ケースで実質 enumeration」: 認めるが、failure path articulation は trust boundary / tool error / stale anchor / bear-なし の **operational safety** 確保のため必須 (operator P0 で要求あり)。Round 2 open question 2 で review に問う
- skeptical 「Inv 1 を obligation-shaped recommendation に rename」: rename ではなく "judgmentally must, mechanism-free" の prose 明示で対応 (rename は prescriptive force を弱めすぎる)

---

*End of v1.1 (revised by claude-opus-4-7-revisor from v1.0 + round 1 multi-LLM review findings).*
