---
name: context_graph_recall_design
description: KairosChain Phase 2 Case A v1.2 — round 2 P0 blocker のみを surgical edit で解消。新 invariant / 新 section / 新 schema field は追加せず、既存条文の narrow patch (§4 ordering 述語修正、§4 failure path → Inv 3 cause taxonomy 吸収、§5 forgery cross-coupling、§10 pass criteria 述語明示、Inv 1 plausibility cheap-signal guard、branch state precondition note) のみ。
tags: [design, context-graph, phase2, case-a, l1-doctrine, recall, harness-agnostic, round3, surgical]
type: design_draft
version: "1.2"
authored_by: claude-opus-4-7-revisor
supersedes: context_graph_recall_design_v1.1
date: 2026-05-03
---

# KairosChain Phase 2 Case A: L1 skill `context_graph_recall` (v1.2)

## v1.1 → v1.2 主要変更 (surgical edit)

Round 2 review (5 reviewers, 0A/1REVISE/4REJECT、persona team 3/3 REVISE) の P0 blocker を **surface 拡張せずに** 解消。原則: 新 invariant / 新 section / 新 schema field 不追加、既存条文への narrow patch のみ。

P0 fixes:
- **§4 ordering 内部 inconsistency** (codex_5.4): "success chain" 述語を「進行は precedent 成功時のみ」から「articulation は order 上の **収束点** であり全 path 必達」に修正、failure path も articulation を経由する論理整合
- **§4 failure path enumeration relocation** (philosophy/skeptical): 4-case prose を **Inv 3 cause taxonomy への参照** に圧縮、§4 自身は ordering invariant + 1 行 "failure modes は Inv 3 が articulate する cause で classified" のみ
- **§5 `[recall]` forgery** (skeptical): `nodes=[]` + `eval=no_match` の組合せを emit する response は **Inv 3 cause field 必須** と cross-floor coupling、forger は self-incriminating cause を選ばざるを得ない
- **§10 pass criteria 述語曖昧** (operator): "expected ⊆ actual" に明示、unexpected node は logged but non-blocking
- **Inv 1 plausibility recursion** (operator/skeptical): "plausibility prong は cheap surface signals (CLAUDE.md / MEMORY.md / handoff phrasing 等) で判定する、recall 自身を要求しない" を Inv 1 直下 prose に明示

P1 (一部取り込み):
- **Branch state precondition** (round 2 で実機判明、cursor finding に応答): §9 implementation step 0 として "Phase 1 (`feature/context-graph-phase1`) を Phase 2 base branch に merge 済" を articulate
- **Non-recall property mismatch** (codex_5.5): Inv 4 の non-recall ack 範囲を "symptom-shape" から "Inv 1 property 評価を実施したが trigger 不成立と判定した時" に拡張 (judgment 履歴の articulation、Inv 1 property base と整合)

その他 P1/P2 は §11 backlog 化または既存 reject log 維持 (round 2 で resolved 確認済の項目は削除せず履歴として §13 patch log に残す)。

## §1 動機 (v1.1 から不変)

Phase 1 で context graph infrastructure (L2 frontmatter `relations`、`dream_scan` の `mode:'traverse'` および anchor 探索用 `mode:'scan'` 両 mode) が完成した。しかし現状 LLM (KairosChain orchestrator) が graph を参照するのは **明示的に依頼された時のみ** であり、L2 header の relations は「保管されているが認知されていない」状態にある。

問題は認識論的空白: LLM は「前回 X について何を決めたか」を問われた時、graph を経由せず内部記憶から fabricate するか沈黙する。どちらも Phase 1 reified work を死蔵させ、Phase 1.5 で articulate された conflation 問題の recurrence を起こす。

Phase 2 Case A の output は **graph を読みに行く判断条件と手順の doctrine 化**。Doctrine 層であり infrastructure 層ではない。

## §2 設計原則 (5 不変条件 + 1 design-correctness criterion、v1.1 から構造不変)

Phase 1.5 の 8 不変条件のうち 3 つを recall 層に specialize し、recall-specific を 2 つ加える (= 5)。Self-referential consistency は §7 + §10 mandatory test に格下げ済 (operational invariant ではなく design-correctness criterion)。

### Invariant 1 — Informational dependence trigger (recall-specific 真新規)

任意のタスクの semantic completion が、現在 context にない情報、かつその情報が prior reified work に存在し得る場合、LLM は recall を **judgmentally must** 試みる。

「judgmentally must」: Doctrine は強い義務を declare するが Inv 5 により runtime enforcement なし、LLM が doctrine を内面化した上で自発判断する義務、mechanism-free。Observable 性は Inv 4 acknowledgment articulation を通じてのみ確保。

Two-prong 判定:
1. **Plausibility prong**: project に prior L2 history が存在し、当該情報が reify されている可能性。**判定は cheap surface signals のみで行う** (v1.2 明示) — CLAUDE.md / MEMORY.md / Active Resume Points / handoff phrasing 等、recall 自身を呼び出さずに観察できる signal で判定する。Plausibility 評価のために recall を呼び出すと recursion が発生するため、surface signal で判定不能なら **plausibility false (= recall 不要側に倒す)** に決定する
2. **Absence prong**: 現在 context (CLAUDE.md / MEMORY.md / active L2) に当該情報が含まれない

両 prong 真の時のみ trigger 成立。

判定は finite list ではなく property 規定。User の phrasing は trigger の symptom であり判定基準ではない。

### Invariant 2 — Anchor-before-traverse (recall-specific 真新規、v1.1 から不変)

`dream_scan mode:'traverse'` 呼び出し前に開始 anchor が **literal sid + name の形で identify** されなければならない。Anchor 不特定 / stale anchor は blind traverse と等価扱い、Inv 3 発動。Invariant は「literal anchor 必須、blind/stale 禁止」のみ。Anchor 解決手順は §6 末尾 implementation note。

### Invariant 3 — Honest absence (Phase 1.5 Honest unknown specialization)

Anchor 不特定、traverse 空集合、tool error、stale anchor 解決失敗 — いずれも recall failure を articulate して response を進める。連続性 fabricate しない。

**Failure cause taxonomy** (Inv 3 が doctrine-binding に保持する closed set、v1.2 で明示位置づけ):
- `anchor_not_identified` — どの anchor 解決経路も成功せず
- `traverse_empty` — anchor は得たが traverse 結果空
- `tool_error` — `dream_scan` runtime error / filesystem 不在
- `stale_anchor` — sid+name が `dream_scan` で resolve しない

これは examples ではなく **doctrine binding closed set** — operator が "どの種類の不在か" で次手判断するために cause を区別する operational necessity (v1.2 明示、round 2 philosophy persona finding 取り込み)。新 cause を後発で加える時は doctrine 改訂が必要 (open set ではない)。§4・§5 はこの taxonomy を参照する。

### Invariant 4 — Recall-source acknowledgment (Phase 1.5 Acknowledgment specialization)

Recall 結果使用 response には literal identifier 形式で articulate しなければならない:

- Anchor: literal `v1:<sid>/<name>` (省略不可)
- Traversal depth + nodes_walked: integer
- Recall set: literal `v1:<sid>/<name>` の list
- Evaluation: `sufficient` / `partial` / `no_match` literal token

形式自由度は文章 vs structured block の意味で残るが literal identifiers は省略不可。

**Forgery 防止 cross-floor coupling** (v1.2 新、skeptical P0 取り込み): `nodes=[]` AND `eval=no_match` の組合せを emit する response は **Inv 3 cause field 必須** とする — `[recall] anchor=... depth=... walked=... nodes=[] eval=no_match cause=<anchor_not_identified|traverse_empty|tool_error|stale_anchor>`。空 recall を articulate するなら cause を選ばざるを得ず、forger が偽装すると self-incriminating cause label を選ぶことになる。Cause なしの empty-recall は Inv 4 違反。

**Non-recall articulation 範囲** (v1.2 修正、codex P1 取り込み): Inv 1 property 評価を実施したが trigger 不成立 (= plausibility または absence prong false) と判定した場合、`[no-recall] reason=<one-line>` を要求。これは "symptom-shape" 限定ではなく **Inv 1 property 評価を実施したか否か** が判定基準 — Inv 1 property base と整合し、judgment 履歴を articulate する。Inv 1 property 評価をそもそも考慮しなかった通常 task (= "私の推論で完結する task") は宣言義務なし。

### Invariant 5 — Doctrine-not-mechanism (Phase 1.5 Declare-not-enforce specialization、v1.1 から不変)

Skill は LLM が読んで自発判断する doctrine。Auto-trigger は orthogonal mechanism で別 layer (Case D)。Doctrine 宣言、LLM judgment、mechanism は強制せず。Inv 1 の "judgmentally must" と整合 — observable 性は Inv 4 acknowledgment articulation を通じてのみ確保。

## §3 Trigger 性質 (v1.1 から不変)

Recall を warrants する task の property: semantic completion が prior reified work への informational reference を要求 (= Inv 1 plausibility + absence の両 prong 真、plausibility は cheap surface signals のみで判定 — Inv 1 直下 prose 参照)。

LLM 内部の自問:
1. この task の正答に必要だが今持っていない情報があるか? (absence)
2. その情報は project の L2 history に reify されている可能性があるか? (plausibility — surface signals で判定)

両 Yes → anchor 特定へ、いずれか No → recall 不要 (Inv 4 non-recall ack 範囲は Inv 4 参照)。

例示 2 件 (列挙ではなく property の instantiation):
- handoff の "next step" を実行する task → property 真 (handoff 本体が reify されている)
- "Active Resume Points" に sid+name surface 状態の任意 task → property 真 (anchor 直接提供)

## §4 Recall 手順 — ordering invariant (v1.2 で convergence point 述語に修正)

**Recall ordering invariant**: Anchor identification ≺ traverse execution ≺ result evaluation ≺ articulation ≺ continuation。**Articulation は order 上の収束点であり全 path 必達** (v1.2 明示、codex P0 取り込み) — success path では evaluation 成功後に articulation、failure path では Inv 3 cause taxonomy が成立した時点で **articulation に直接合流**、continuation はその後で recall set または empty context のいずれかで進行。順序逸脱 / 段階 skip / articulation の bypass は doctrine 違反。

**Failure mode 分類は Inv 3 cause taxonomy が doctrine-binding に保持** (v1.2 で §4 自身の prose enumeration を Inv 3 への参照に圧縮、philosophy/skeptical P0 取り込み)。各 cause 発生時の合流点は同一 (articulation step) であり、cause 種類による branch 構造は §4 invariant 内に enumerate しない — Inv 3 cause field の articulation で operator が next-action 判断する。

**Stale anchor 時の anchor 名 inference 禁止** (v1.1 から sub-rule 維持、ただし articulate 場所を Inv 2 prose に戻す): Inv 2 「literal anchor 必須、blind/stale 禁止」の含意として、stale anchor の name 文字列から内容を推論することは Inv 2 違反 — anchor 解決の次経路を §6 implementation note の優先順位に従い試行するか Inv 3 で停止。

`max_depth` heuristic (Inv 5 soft guidance): default 3、handoff chain 5+ — LLM 判断、floor ではない。

**Trust boundary**: Recall set を context として継続使用する際、recall set は system 自身の memory として trust。但し L2 の semantic correctness は記録時点判断 — 現在 context と矛盾する場合、矛盾検出は LLM 判断に依存し doctrine が operational test を提供しない (v1.2 honest articulation、operator P0 取り込み: 矛盾検出 protocol は §11 backlog)。Multi-user / 外部 source L2 受け入れ (Phase 3+) は §11。

## §5 Acknowledgment 形式 (v1.2 で forgery cross-coupling 追加)

Inv 4 の **schema floor** (literal 必須、省略不可):

- Anchor: literal `v1:<sid>/<name>`
- Traversal depth + nodes walked: integer
- Recall set: literal `v1:<sid>/<name>` list
- Evaluation: `sufficient` | `partial` | `no_match`
- **Cause** (`nodes=[]` AND `eval=no_match` の時のみ必須、Inv 4 forgery cross-coupling): Inv 3 cause taxonomy のいずれか literal token

**最小行 template** (drift 防止 fallback):

成功時:
```
[recall] anchor=v1:<sid>/<name> depth=<n> walked=<m> nodes=[v1:<sid>/<name>, ...] eval=<sufficient|partial>
```

Empty recall (空集合) 時 — cause 必須:
```
[recall] anchor=v1:<sid>/<name> depth=<n> walked=<m> nodes=[] eval=no_match cause=<anchor_not_identified|traverse_empty|tool_error|stale_anchor>
```

Recall failure (anchor 不特定 / tool error 等で traverse 自体未実行) 時:
```
[recall] cause=<anchor_not_identified|traverse_empty|tool_error|stale_anchor> attempted_anchor=<v1:.../... or "n/a">
```

Non-recall (Inv 1 property 評価を実施したが trigger 不成立) 時:
```
[no-recall] reason=<one-line>
```

Floor を満たさない fluent-only ack ("I checked some prior context") は Inv 4 違反。Cause field 不在の `nodes=[] eval=no_match` も Inv 4 違反 (forgery cross-coupling)。

## §6 Composability (v1.1 から不変、Phase 2 Case B/C 段落のみ 1 行に圧縮)

### `kairos-knowledge` skill との関係

`kairos-knowledge` は L1 generic、`context_graph_recall` は temporal/relational specialization。同格 sibling、並列起動可。Output 重複時の precedence rule は doctrine layer に置かない (mechanism creep) — LLM が両 source articulate して synthesis 判断、operator が provenance で解釈。

### `capability_status` pre-flight

`dream_scan` は `:core`、`capability_status` 自身も `:core` (Phase 1.5 §8 declared)。Doctrine が capability_status を prerequisite として要求すると、doctrine の意味論が capability articulation 機構と coupled になる — これは **coherence concern** (毎回 self-check は structural redundancy)。Pre-flight は best practice として LLM 選択の自由はあるが doctrine が **invariant として要求しない**、doctrine は capability_status 不在環境でも動作する。

### Phase 2 Case B / C との関係 (v1.2 で 1 行圧縮、philosophy P2 取り込み)

Doctrine は forward-only、Case B (edge surface) / Case C (reverse traversal) 完成後に doctrine extension で取り込み — Forward-only metadata invariant (Phase 1.5) の skill 層類比。

### Anchor 解決 implementation note (v1.1 から不変)

Inv 2 は「literal anchor で blind/stale でない」のみ要求。実 anchor 解決手順は doctrine ではなく note として推奨優先順位 (mechanism、不変条件ではない):

1. User explicit 指定
2. MEMORY.md "Active Resume Points" sid+name pair
3. `dream_scan mode:'scan'` で recent walk → tags/description match → user 確認
4. いずれも不成立なら Inv 3 cause `anchor_not_identified` 発動

LLM judgment で逸脱可。

## §7 哲学的位置づけ (v1.1 から不変)

### 命題 5 (constitutive recording / Kairotic temporality)

L2 記録は constitutive、context graph は relation の articulation。`context_graph_recall` doctrine は Kairotic temporality を operational に行使する skill: 過去 recall は現在 operation を過去 reified state に anchor し直すこと。Inv 1 が recall を要求する瞬間は constitutive continuity の維持要求。

### 命題 7 (metacognitive self-referentiality)

Doctrine は LLM が epistemic state を観察する skill。Phase 1.5 Acknowledgment が外部依存への metacognition、Inv 4 は **過去自己への metacognition** — 現在自己が過去自己に依存していることの articulation。

### Self-referential consistency (design-correctness criterion)

Doctrine 自身は L1、design 経緯は context graph reified、future session で「design rationale」recall は doctrine 自身を invoke して genesis を traverse — Generative Principle 整合。これは operational invariant ではなく design-correctness criterion (skeptical round 1 P0 取り込み)。格下げ後 operative form: **§10 mandatory self-referential test**。

## §8 配置 (v1.1 から不変)

L1 Distribution Policy より両 location:
- canonical: `KairosChain_mcp_server/knowledge/context_graph_recall/context_graph_recall.md`
- mirror: `KairosChain_mcp_server/templates/knowledge/context_graph_recall/context_graph_recall.md`

Consumer: KairosChain orchestrator LLM。Update cadence: invariants 変更 / Case B/C 完了。

## §9 実装ステップ (v1.2 で step 0 追加)

0. **Branch state precondition** (v1.2 新、cursor P0 取り込み): Phase 2 Case A 実装前提として `feature/context-graph-phase1` (Phase 1 traverse 実装) が Phase 2 base branch に merge されている必要がある。merge されていない場合 §10 mandatory test が実機検証不可能なため、**implementation 着手前に Phase 1 merge を完了する**
1. L1 markdown 執筆 (canonical + mirror、5 invariants + ordering rule + acknowledgment schema floor 中核)
2. Templates mirror 作成
3. `knowledge_list` 登録確認
4. `knowledge_get` 取得確認
5. `kairoschain_capability_boundary` から bidirectional cross-reference
6. Design L2 作成: 本 v1.2 完成後 L2 save、`relations: informed_by` で `phase1_5_complete_phase2_handoff` 等を target 設定
7. Multi-LLM review (round 3 が本)、修正後 commit
8. L2 handoff 作成 (Case A 完了 / Case C 着手用 informed_by)
9. Self-referential test 実行 (mandatory once、§10)

## §10 テスト suite (v1.2 で pass criteria 述語明示)

- File presence (両 location)
- Frontmatter parseability
- `knowledge_list` 登録
- `knowledge_get` 取得
- Cross-reference integrity (mutual)
- **Mandatory self-referential test** (v1.2 述語明示):
  - Starting anchor: 本 design v1.2 の L2 (step 6 で作成済の sid+name)
  - Expected node set (minimum): 本 L2 → `phase1_5_complete_phase2_handoff` → `context_graph_phase1_implementation_complete` の chain (3 nodes)
  - **Pass criteria** (v1.2 明示、operator P0 取り込み): `expected ⊆ actual` — `dream_scan mode:'traverse' max_depth:3` の結果に expected set の 3 node 全てが含まれること、actual に unexpected node が追加されることは許容 (logged but non-blocking)。Expected set のいずれかが missing なら test fail
  - 1 回実機確認、CI 自動化不要

Doctrine の semantic correctness は test 不可検証 — multi-LLM review + 実 session observation で評価 (KairosChain doctrine 全般 limit と整合)。

## §11 Phase 2 Case A で持ち越さない事項 (v1.1 から軽量増加)

- Auto-trigger 機構 (Case D, harness-specific)
- Edge 数 surface in scan (Case B, `:core`)
- Reverse traversal (Case C, `:core`)
- Runtime acknowledgment helper for recall (Phase 2+)
- Recall result persistence / caching (Phase 3+)
- Multi-anchor parallel traverse (Phase 3+)
- Recall quality metric 細分化 (Phase 3+)
- kairos-knowledge との auto-routing (Phase 3+)
- LLM 内面化の自動評価 (Phase 3+, 評価方法未確立)
- Multi-user / 外部 L2 source の trust boundary (Phase 3+)
- Runtime enforcement / observability infrastructure (Phase 3+)
- **Recall set vs current context の矛盾検出 protocol** (v1.2 新、operator P0 honest articulation): §4 trust boundary の "矛盾は LLM 判断" を operational test 化する protocol、現状 doctrine 提供せず Phase 3+

## §12 Open questions (round 3 review に渡す)

1. v1.2 §4 ordering "articulation is convergence point" reframe で v1.1 の internal inconsistency (codex_5.4 P0) は構造的に解消されたか?
2. §4 prose の failure path enumeration を Inv 3 cause taxonomy 参照に圧縮した結果、philosophy/skeptical の round 2 finding (enumeration relocation) は解消されたか?
3. §5 forgery cross-coupling (`nodes=[] AND eval=no_match` で cause 必須) は forgery cost を doctrine-binding 強度まで上げたか?
4. Inv 1 plausibility "cheap surface signals" guard は recursion 懸念を doctrine layer で十分解消したか? それとも plausibility 自体を Phase 3+ に defer すべきか?
5. §10 pass criteria `expected ⊆ actual` 述語は invariant-grade specification として determinate か?

## §13 Patch log (v1.1 → v1.2 surgical edit)

**v1.2 で取り込んだ round 2 P0/P1**:

| Finding | Source | 解決方法 (surface 拡張なし) | §影響 |
|---|---|---|---|
| F24 (P0 codex_5.4) §4 ordering internal inconsistency | codex_5.4 | "articulation is convergence point" reframe、success/failure path 共に articulation 経由 | §4 invariant prose |
| F25 (P0 philosophy/skeptical) §4 failure path enumeration relocation | persona team | 4-case prose を Inv 3 cause taxonomy への参照に圧縮、§4 自身は ordering invariant + 1 行参照のみ | §4 prose |
| F26 (P0 skeptical) §5 `[recall]` forgery | skeptical | `nodes=[] AND eval=no_match` で cause field 必須化 (cross-floor coupling) | Inv 4 prose、§5 template |
| F27 (P0 operator) §10 pass criteria 述語曖昧 | operator | `expected ⊆ actual` 明示、unexpected = non-blocking | §10 |
| F28 (P0 operator/skeptical) Inv 1 plausibility recursion | operator + skeptical | Inv 1 直下 prose に "cheap surface signals only" guard 明示、surface signal 不能なら plausibility false | §2 Inv 1 |
| F29 (P0 cursor branch state) Phase 1 traverse 不在 | cursor | §9 step 0 で Phase 1 merge precondition 明示。実装段階で **branch 上で対応済** (本 design は `feature/context-graph-phase2-case-a` 上、`feature/context-graph-phase1` merge 済) | §9 step 0 |
| F30 (P0 philosophy) Inv 3 cause taxonomy load-bearing 化 | philosophy | "doctrine-binding closed set" として Inv 3 prose に明示、open set ではない旨も併記 | §2 Inv 3 |
| F31 (P1 codex_5.5) Non-recall property base mismatch | codex_5.5 | symptom-shape 限定から "Inv 1 property 評価を実施したが trigger 不成立と判定した時" に拡張 | Inv 4 prose |
| F32 (P1 codex_5.4) §10 self-ref test が genesis chain 証明せず | codex_5.4 | §10 pass criteria に "expected set の chain 全 3 node 含有" 明示、partial traversal は test fail | §10 |
| F33 (P2 philosophy) §6 Case B/C 段落 verbose | philosophy | 1 行 prose に圧縮 | §6 |

**v1.2 で reject (敢えて取り込まない)**:

| Finding | Source | reject 根拠 |
|---|---|---|
| skeptical 「§4 trust boundary single-user precondition を Inv 1-5 に明記」 | skeptical | Inv 5 mechanism-free と整合、precondition は §11 backlog で defer (multi-user は Phase 3+ 領分) — operational 不在のまま invariant 数を増やすと operational invariant 概念の precision を毀損 |
| operator 「§5 success template にも `cause=` field 統一」 | operator (advisory) | Cause は failure / empty 時のみ semantic、success に `cause=ok` を加えると意味のない field を強制、forgery cross-coupling の operational logic も曇る |
| operator 「§4 trust boundary 矛盾検出に operational test」 | operator | Inv 5 mechanism-free 準拠、矛盾検出 protocol は doctrine layer の射程外、§11 backlog (新 invariant 追加で surface 拡張になるため見送り) |
| cursor 「Inv 1-5 が single-user precondition を明記すべき」 | cursor (P2) | 同上、precondition declaration は §11 multi-user backlog で defer |

**v1.2 で取り込まない P2 advisory** (round 2 patch log P2 群): 大半が round 2 で persona team 自身が "(c) value-divergent" 評価、または既に round 1/2 で resolved 確認済の項目を recap したもの。Doctrine の本質変更を要さないため見送り。

## §14 Branch state note (v1.2 新、cursor P0 取り込みの実装側応答)

本 v1.2 design は branch `feature/context-graph-phase2-case-a` 上で execute される前提。Branch ancestry:

```
main (1fb962b)
├── feature/context-graph-phase1 (Phase 1: 829e361 + 76bf073)
├── feature/capability-boundary-phase1.5 (Phase 1.5: a4f5f73)
└── feature/context-graph-phase2-case-a [本 branch]
    ← feature/capability-boundary-phase1.5 から派生
    ← feature/context-graph-phase1 を merge (b741d49)
    → Phase 1 + 1.5 + Case A 設計の base 完備
```

Round 2 で cursor が指摘した「現 branch templates に traverse code 不在」は本 branch 作成時の merge で解消、§9 step 0 と §10 mandatory test の precondition を満たす。

---

*End of v1.2 (surgical revise by claude-opus-4-7-revisor from v1.1 + round 2 multi-LLM review P0 blockers).*
