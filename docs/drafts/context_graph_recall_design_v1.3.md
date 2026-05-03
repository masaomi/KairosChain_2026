---
name: context_graph_recall_design
description: KairosChain Phase 2 Case A v1.3 — round 3 で残った real (a) P0 (§5 schema cause/anchor 内部矛盾) を surgical fix。新 invariant / 新 section 追加なし、§5 既存 2 template を cause taxonomy に整合する形で再 split (anchor 解決済 vs 未解決の semantic 区別)、frontmatter honest accounting に修正、§10 ordering scope 外を honest articulate。
tags: [design, context-graph, phase2, case-a, l1-doctrine, recall, harness-agnostic, round4, surgical-v2]
type: design_draft
version: "1.3"
authored_by: claude-opus-4-7-revisor
supersedes: context_graph_recall_design_v1.2
date: 2026-05-03
---

# KairosChain Phase 2 Case A: L1 skill `context_graph_recall` (v1.3)

## v1.2 → v1.3 主要変更 (surgical edit v2)

Round 3 の persona unanimity gate 通過 (3/3 APPROVE) を維持しつつ、subprocess 3 機種 (codex 5.4 / 5.5 / cursor) の真の (a)/(P1) finding に narrow patch で応答。新 invariant / 新 section 追加なし。

P0 fixes:
- **§5 schema 内部矛盾** (codex_5.5 P0、real (a) deployment-grounded bug): 空-recall template が `cause=anchor_not_identified|stale_anchor` を許容しつつ `anchor=v1:<sid>/<name>` literal を要求していた contradiction を解消。Cause taxonomy を **anchor-resolved 系** (`traverse_empty`) と **anchor-unresolved 系** (`anchor_not_identified`/`stale_anchor`/`tool_error`) に semantic 区別、各 template の cause 許容集合を限定 (新 cause 追加ではなく既存 cause の template 配分修正)
- **frontmatter "新 schema field 不追加" の不整合** (cursor P1、skeptical P2 共通指摘): v1.2 で `cause=` 条件付き field を Inv 4 forgery cross-coupling として追加した事実を frontmatter で **honest accounting** に修正 — "新 invariant / 新 section / 新 invariant 追加なし、`cause=` 条件付き field は Inv 4 forgery cross-coupling 由来の P0 fix であり surface 拡張ではない (既存 schema floor の bite 強化)" と articulate

P1 fixes:
- **§10 genesis chain ordering scope** (codex_5.4 P1): `expected ⊆ actual` が co-reachability のみで chain ordering を proof しないことを §10 末尾で **honest articulate** (mandatory test の scope を doctrine 的に明示、test 自体は v1.2 仕様で不変)
- **§11 success-template forgery residual** (cursor P1): `eval=sufficient` で fabricated nodes を emit する forgery が schema floor を満たし得る件を §11 backlog に **明示 articulate** (mechanism-free doctrine ceiling、Phase 3+ runtime evidence territory)

Persona unanimity gate (3/3 APPROVE) で resolved 確認済の P0/P1 は本 v1.3 で **不変**:
- §4 ordering convergence-point reframe (round 3 philosophy/operator/skeptical 全 APPROVE)
- Inv 1 plausibility cheap-signal guard (round 3 全 APPROVE)
- §5 forgery cross-coupling for empty-recall (round 3 doctrine-binding strength achieved)
- Inv 3 cause taxonomy doctrine-binding closed set (round 3 philosophy 認定)
- §10 `expected ⊆ actual` 述語明示 (round 3 operator mechanically runnable 認定)

## §1 動機 (v1.2 から不変)

Phase 1 で context graph infrastructure (`mode:'traverse'` + `mode:'scan'`) 完成。LLM が graph を参照するのは明示依頼時のみ、relations は保管されているが認知されていない。Case A は doctrine 層で「いつ・どう graph を引くか」を規定。

## §2 設計原則 (5 不変条件 + 1 design-correctness criterion、v1.2 から不変)

Phase 1.5 の 8 不変条件のうち 3 つを recall 層に specialize、recall-specific を 2 つ加える (= 5)。Self-referential consistency は §7 + §10 mandatory test に格下げ。

### Invariant 1 — Informational dependence trigger

任意のタスクの semantic completion が、現在 context にない情報、かつその情報が prior reified work に存在し得る場合、LLM は recall を **judgmentally must** 試みる。Mechanism-free obligation、observable 性は Inv 4 articulation のみ。

Two-prong:
1. **Plausibility prong**: cheap surface signals (CLAUDE.md / MEMORY.md / Active Resume Points / handoff phrasing 等) のみで判定、recall 自身を呼び出さない。Surface signal 不能 → plausibility false (recursion 回避 fail-safe)
2. **Absence prong**: 現在 context に当該情報が含まれない

両 prong 真の時のみ trigger 成立。

### Invariant 2 — Anchor-before-traverse

`dream_scan mode:'traverse'` 呼び出し前に開始 anchor が literal sid + name で identify されなければならない。Anchor 不特定 / stale anchor は blind と等価扱い、Inv 3 発動。Stale anchor 時の anchor 名 inference は本 invariant の含意として禁止。

### Invariant 3 — Honest absence

Anchor 不特定、traverse 空集合、tool error、stale anchor 解決失敗 — いずれも recall failure を articulate。連続性 fabricate しない。

**Failure cause taxonomy** (doctrine-binding closed set):

Anchor-resolved 系 (anchor literal が valid に identify された後の failure):
- `traverse_empty` — anchor は得たが traverse 結果空

Anchor-unresolved 系 (anchor literal が valid に得られなかった failure、v1.3 で semantic 区別を明示):
- `anchor_not_identified` — どの anchor 解決経路も成功せず
- `stale_anchor` — sid+name が `dream_scan` で resolve しない
- `tool_error` — `dream_scan` runtime error / filesystem 不在

これは examples ではなく **doctrine binding closed set**。新 cause 追加は doctrine 改訂を要する (open set ではない)。§4・§5 はこの taxonomy を参照、特に §5 の template 配分は anchor-resolved/unresolved 区別に従う (v1.3 で明示)。

### Invariant 4 — Recall-source acknowledgment

Recall 結果使用 response には literal identifier 形式で articulate (Anchor / depth / walked / nodes / evaluation literal)。

**Forgery 防止 cross-floor coupling** (v1.2 から不変、template split は §5): 空-recall 系を emit する response は Inv 3 cause field 必須。Cause なしの空-recall は Inv 4 違反。Forger は self-incriminating cause を選ばざるを得ない (post-hoc audit 強度、real-time 強制ではない、§11 backlog で Phase 3+ runtime evidence と分離)。

**Non-recall articulation 範囲**: Inv 1 property 評価を実施したが trigger 不成立 (= plausibility または absence prong false) と判定した場合 `[no-recall] reason=...` 要求。Symptom-shape 限定ではなく Inv 1 property 評価実施を判定基準。Inv 1 評価をそもそも考慮しなかった通常 task は宣言義務なし。

### Invariant 5 — Doctrine-not-mechanism

Skill は LLM 自発判断 doctrine。Auto-trigger は別 layer (Case D)。Doctrine 宣言、LLM judgment、mechanism 強制せず。Observable 性は Inv 4 articulation のみ。

## §3 Trigger 性質 (v1.2 から不変)

Recall を warrants する task の property: semantic completion が prior reified work への informational reference を要求 (両 prong 真、plausibility は cheap surface signals のみ判定)。

LLM 内部の自問:
1. この task の正答に必要だが今持っていない情報があるか? (absence)
2. その情報は project の L2 history に reify されている可能性があるか? (plausibility — surface signals)

両 Yes → anchor 特定、いずれか No → recall 不要。

例示 2 件: handoff "next step" 実行 / Active Resume Points sid+name surface 状態 task。

## §4 Recall 手順 — ordering invariant (v1.2 から不変)

**Recall ordering invariant**: Anchor identification ≺ traverse execution ≺ result evaluation ≺ articulation ≺ continuation。**Articulation は order 上の収束点であり全 path 必達** — success path では evaluation 成功後 articulation、failure path では Inv 3 cause taxonomy が成立した時点で articulation に直接合流、continuation はその後で recall set または empty context で進行。順序逸脱 / 段階 skip / articulation の bypass は doctrine 違反。

Failure mode 分類は Inv 3 cause taxonomy が doctrine-binding に保持。各 cause 発生時の合流点は同一 (articulation step)、cause 種類による branch 構造は §4 内に enumerate しない。

`max_depth` heuristic (Inv 5 soft guidance): default 3、handoff chain 5+ — LLM 判断。

**Trust boundary**: Recall set を context として継続使用する際、recall set は system 自身の memory として trust。L2 semantic correctness は記録時点判断 — 現在 context との矛盾検出 protocol は doctrine 提供せず LLM 判断に依存 (§11 backlog)。

## §5 Acknowledgment 形式 (v1.3 で template split を Inv 3 cause taxonomy semantic に整合)

Inv 4 schema floor (literal 必須):
- Anchor: literal `v1:<sid>/<name>` (anchor-resolved 系のみ)
- Depth + walked: integer (anchor-resolved 系のみ)
- Recall set: literal list
- Evaluation: `sufficient` / `partial` / `no_match`
- **Cause** (空-recall 系で必須、Inv 4 forgery cross-coupling): Inv 3 cause taxonomy の **anchor 状態に整合する** literal token

最小行 template (v1.3 で cause taxonomy 配分を明示):

**成功時** (anchor identified, traverse non-empty):
```
[recall] anchor=v1:<sid>/<name> depth=<n> walked=<m> nodes=[v1:<sid>/<name>, ...] eval=<sufficient|partial>
```

**Empty recall** (anchor identified, traverse executed and returned empty) — anchor-resolved 系 cause のみ:
```
[recall] anchor=v1:<sid>/<name> depth=<n> walked=<m> nodes=[] eval=no_match cause=traverse_empty
```

**Recall failure** (anchor unresolved or tool unavailable) — anchor-unresolved 系 cause のみ:
```
[recall] cause=<anchor_not_identified|stale_anchor|tool_error> attempted_anchor=<v1:.../... or "n/a">
```

**Non-recall** (Inv 1 property 評価実施、trigger 不成立):
```
[no-recall] reason=<one-line>
```

**v1.3 schema 内部整合性 (codex_5.5 P0 fix)**: 空-recall template は **anchor literal + cause=traverse_empty 限定** (anchor 解決済の状態でのみ意味を持つ)、Recall failure template は **anchor literal なし + cause=anchor_not_identified|stale_anchor|tool_error 限定** (anchor 解決失敗の状態のみ)。両者の cause 集合は disjoint で、Inv 3 cause taxonomy の anchor-resolved/unresolved 区別 (§2) と完全整合。

Floor を満たさない fluent-only ack は Inv 4 違反。空-recall で cause 不在も Inv 4 違反 (forgery cross-coupling)。Cause/template 不整合 (例: 空-recall template に `cause=anchor_not_identified` を emit) も Inv 4 違反 (v1.3 明示)。

## §6 Composability (v1.2 から不変)

`kairos-knowledge` 同格 sibling、並列起動可。`capability_status` pre-flight は coherence concern (tier slippage ではない)、doctrine prerequisite として要求しない。Phase 2 Case B/C 完成後 doctrine extension で取り込み (forward-only)。

Anchor 解決 implementation note (mechanism、不変条件ではない):
1. User explicit
2. MEMORY.md "Active Resume Points" sid+name pair
3. `dream_scan mode:'scan'` recent walk → tags/description match → user 確認
4. いずれも不成立なら Inv 3 cause `anchor_not_identified`

## §7 哲学的位置づけ (v1.2 から不変)

命題 5 (Kairotic temporality)、命題 7 (metacognitive self-referentiality)、Self-referential consistency (§10 mandatory test に格下げ)。

## §8 配置 (v1.2 から不変)

L1 Distribution Policy より両 location:
- canonical: `KairosChain_mcp_server/knowledge/context_graph_recall/context_graph_recall.md`
- mirror: `KairosChain_mcp_server/templates/knowledge/context_graph_recall/context_graph_recall.md`

## §9 実装ステップ (v1.2 から不変)

0. **Branch state precondition**: Phase 2 Case A 実装前提として `feature/context-graph-phase1` が Phase 2 base branch に merge されている (本 design は branch `feature/context-graph-phase2-case-a` 上で execute、merge 済 §14 参照)
1. L1 markdown 執筆
2. Templates mirror 作成
3. `knowledge_list` 登録確認
4. `knowledge_get` 取得確認
5. `kairoschain_capability_boundary` から bidirectional cross-reference
6. Design L2 作成 (relations: informed_by 設定)
7. Multi-LLM review、修正後 commit
8. L2 handoff 作成
9. Self-referential test 実行 (§10)

## §10 テスト suite (v1.3 で ordering scope 外を honest articulate)

- File presence (両 location)
- Frontmatter parseability
- `knowledge_list` 登録
- `knowledge_get` 取得
- Cross-reference integrity
- **Mandatory self-referential test**:
  - Starting anchor: 本 design v1.3 L2 (step 6 で作成済の sid+name)
  - Expected node set: 本 L2 → `phase1_5_complete_phase2_handoff` → `context_graph_phase1_implementation_complete` (3 nodes)
  - **Pass criteria**: `expected ⊆ actual` — `dream_scan mode:'traverse' max_depth:3` 結果に expected 3 node 全含有、unexpected node 追加は許容 (logged but non-blocking)
  - 1 回実機確認、CI 自動化不要

**Test scope の honest articulation** (v1.3、codex_5.4 P1 取り込み): `expected ⊆ actual` は **co-reachability** (3 node が graph 上で start anchor から reachable であること) を proof する。**Edge ordering / genesis chain の単一連鎖性 / informed_by 方向の sequential preservation は本 mandatory test の scope 外**。Doctrine 層が proof するのは「genesis nodes が graph 上に存在し traverse 可能」までで、ordering proof は Phase 3+ test extension (§11) に defer する — `:core` tier mandatory test の minimal sufficient condition として set membership で十分、ordering 不在による false-positive (= chain ordering 壊れているが 3 node は到達可能) は §11 で追加 test を装着するまでは LLM 観察で対応。

Doctrine semantic correctness は test 不可検証 (KairosChain doctrine 全般 limit と整合)。

## §11 Phase 2 Case A で持ち越さない事項 (v1.3 で 2 項目 articulate 追加)

- Auto-trigger 機構 (Case D)
- Edge 数 surface in scan (Case B)
- Reverse traversal (Case C)
- Runtime acknowledgment helper for recall (Phase 2+)
- Recall result persistence / caching (Phase 3+)
- Multi-anchor parallel traverse (Phase 3+)
- Recall quality metric 細分化 (Phase 3+)
- kairos-knowledge との auto-routing (Phase 3+)
- LLM 内面化の自動評価 (Phase 3+)
- Multi-user / 外部 L2 source の trust boundary (Phase 3+)
- Runtime enforcement / observability infrastructure (Phase 3+)
- Recall set vs current context の矛盾検出 protocol (Phase 3+)
- **Success-template forgery residual** (v1.3 新、cursor P1 articulate): `eval=sufficient|partial` かつ fabricated `nodes=[v1:fake/...]` を emit する forgery は schema floor (literal 形式) を技術的に満たし得る — Inv 4 forgery cross-coupling (§5) は **空-recall 系のみ** に bite し、success path は doctrine 層では検出不能。これは **mechanism-free doctrine の ceiling** (Inv 5 由来)、runtime evidence binding (実 traverse 結果との照合) は Phase 3+ runtime enforcement infrastructure と統合
- **§10 genesis chain edge-ordering test** (v1.3 新、codex_5.4 P1 articulate): mandatory self-ref test の scope 拡張、edge label / informed_by 方向 / 単一連鎖性 verification は Phase 3+ test extension で実装

## §12 Open questions (round 4 review に渡す)

1. v1.3 §5 template split (anchor-resolved 系 cause vs anchor-unresolved 系 cause の disjoint 配分) は schema 内部矛盾 (codex_5.5 P0) を構造的に解消したか?
2. §10 末尾の "ordering scope 外" honest articulation は genesis chain test 完全性懸念 (codex_5.4 P1) への適切な doctrine 層回答か? それとも mandatory test 自体の拡張が必要か?
3. §11 success-template forgery articulation は cursor P1 の "述語的拘束に traverse 実績は結び付いていない" 懸念への適切な doctrine 層位置づけか?
4. v1.3 frontmatter の honest accounting は v1.2 prologue の自己整合性問題を完全解消したか?
5. Persona unanimity (3/3 APPROVE) を round 3 で達成済、本 v1.3 surgical fix は unanimity を保持しつつ subprocess 残課題を解消したか?

## §13 Patch log (v1.2 → v1.3 surgical edit v2)

主要採用 (P0 + P1 blocker):
- F34 (P0 codex_5.5、real (a) deployment-grounded) §5 schema 内部矛盾: 空-recall template / Recall failure template の cause 集合を Inv 3 cause taxonomy の anchor-resolved/unresolved 区別と整合する disjoint 配分に修正、Inv 3 §2 にも anchor-resolved/unresolved subgrouping 明示
- F35 (P1 cursor、P2 skeptical 共通) frontmatter "新 schema field 不追加" 不整合: honest accounting に修正 (`cause=` は forgery cross-coupling fix の bite 強化、surface 拡張ではない invariant identity)
- F36 (P1 codex_5.4) §10 ordering scope: honest articulate (`expected ⊆ actual` は co-reachability proof、edge-ordering / 単一連鎖性 verification は §11 に defer)
- F37 (P1 cursor) success-template forgery residual: §11 backlog で mechanism-free doctrine ceiling として明示、Phase 3+ runtime evidence と分離

Reject (取り込まない):
- codex_5.5 「Inv 3 cause taxonomy doctrine-binding closed list は anti-enumeration 違反」: round 3 philosophy persona が "F30 Inv 3 cause closed set is philosophically correct, load-bearing not decorative" と APPROVE 認定済、Inv 3 が cause vocabulary を定義する legitimate doctrinal home — operational necessity (§5 forgery cross-coupling、§4 failure path 合流) を支える load-bearing closed set は doctrine-by-enumeration ではなく doctrine-binding taxonomy (philosophically distinct)
- codex_5.4 「§10 genesis chain ordering を mandatory test 内に組み込む」: `:core` tier mandatory test の minimal sufficient condition は set membership、ordering test 拡張は §11 (Phase 3+ test extension) に defer (mandatory test の scope 拡張は Inv 5 mechanism-free / surface preservation と緊張)
- cursor 「success template にも literal traverse 実績結合」: doctrine 層では unrealizable (mechanism-free)、§11 で runtime evidence territory として articulate

## §14 Branch state note (v1.2 から不変)

本 v1.3 design は branch `feature/context-graph-phase2-case-a` 上で execute される前提:

```
main (1fb962b)
├── feature/context-graph-phase1 (Phase 1: 829e361 + 76bf073)
├── feature/capability-boundary-phase1.5 (Phase 1.5: a4f5f73)
└── feature/context-graph-phase2-case-a [本 branch]
    ← feature/capability-boundary-phase1.5 から派生
    ← feature/context-graph-phase1 を merge (b741d49)
    → Phase 1 + 1.5 + Case A 設計の base 完備
```

§14 は Phase 2 完了で main merge 後に削除候補 (round 3 philosophy/skeptical advisory: 設計 timeless 性回復のため)。

---

*End of v1.3 (surgical revise v2 from v1.2 + round 3 subprocess P0/P1 findings).*
