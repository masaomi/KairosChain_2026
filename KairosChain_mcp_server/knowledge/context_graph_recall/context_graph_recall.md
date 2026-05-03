---
name: context_graph_recall
description: "KairosChain orchestrator LLM が context graph (L2 frontmatter relations.informed_by) を自発的に参照する条件と手順の doctrine。Phase 2 Case A v1.3、harness 非依存 (core tier)。Phase 1 (Context Graph infrastructure) と Phase 1.5 (Capability Boundary) を前提とする。"
tags: [context-graph, recall, l2-traversal, dream-scan, phase2, case-a, doctrine, harness-agnostic]
version: "1.0"
date: 2026-05-03
consumer: KairosChain orchestrator LLM (どの harness で動くかに関わらず)
---

# context_graph_recall

KairosChain の orchestrator LLM が、過去の reified work (L2 handoff、過去 session の決定、依存関係) を必要とする task で、自発的に context graph を参照するための doctrine。

`dream_scan mode:'traverse'` を呼び出す判断条件、anchor 特定の優先順位、recall 結果の articulation 形式を 5 つの不変条件で規定する。Auto-trigger (skill auto-invocation、CLAUDE.md auto-load hint 等) は本 doctrine の射程外、harness-specific (Phase 2 Case D) で扱う。

## 5 つの不変条件

Phase 1.5 の 8 invariants を継承する形で、recall 層に specialize した 3 invariants と recall-specific 真新規 2 invariants を併せた 5 つの doctrine。

### Invariant 1: Informational dependence trigger (recall-specific 真新規)

任意のタスクの semantic completion が、現在 context にない情報、かつその情報が prior reified work に存在し得る場合、LLM は recall を **judgmentally must** 試みる。

「judgmentally must」: doctrine は強い義務を declare するが、Inv 5 により runtime enforcement なし。LLM が doctrine を内面化した上で自発判断する義務、mechanism-free。Observable 性は Inv 4 acknowledgment articulation を通じてのみ確保。

**Two-prong 判定**:
1. **Plausibility prong**: project に prior L2 history が存在し当該情報が reify されている可能性。判定は **cheap surface signals のみで行う** — CLAUDE.md / MEMORY.md / Active Resume Points / handoff phrasing 等、recall 自身を呼び出さずに観察できる signal で判定する。Surface signal で判定不能なら **plausibility false** (recursion 回避 fail-safe、recall 不要側に倒す)
2. **Absence prong**: 現在 context (CLAUDE.md / MEMORY.md / active L2) に当該情報が含まれない

両 prong 真の時のみ trigger 成立。

判定は finite list ではなく property 規定。User の phrasing (「続きから」「前回」「先日の」) は trigger の symptom であり判定基準ではない。判定基準は task そのものの informational dependence。

**Non-trigger 条件**: 現在の context が既に必要な情報を含む場合、recall は不要。重複 traverse はコストのみで informational value を持たない。

### Invariant 2: Anchor-before-traverse (recall-specific 真新規)

`dream_scan mode:'traverse'` の呼び出し前に、開始 anchor が **literal sid + name の形で identify** されなければならない。Anchor 不特定 / stale anchor (sid+name が `dream_scan` で resolve しない) は blind traverse と等価扱い、Inv 3 発動。

**Stale anchor 時の anchor 名 inference は本 invariant の含意として禁止** — anchor name 文字列から内容を推論することは Inv 2 違反、anchor 解決の次経路を試行するか Inv 3 で停止する。

Anchor 解決の推奨優先順位 (mechanism、不変条件ではない):

1. User explicit に SID/name 指定
2. MEMORY.md "Active Resume Points" 等の context index に sid+name pair
3. `dream_scan mode:'scan'` で recent L2 を walk → tags / description match で候補抽出 → user 確認
4. いずれも不成立なら Inv 3 cause `anchor_not_identified` 発動

LLM judgment で逸脱可。

### Invariant 3: Honest absence (Phase 1.5 Honest unknown specialization)

Anchor 不特定、traverse 空集合、tool error、stale anchor 解決失敗 — いずれの場合も **recall failure を articulate して response を進める**。連続性を fabricate しない。

これは epistemological honesty: graph 不在 ≠ 過去不在、graph 不在 = 「reified state が今の私から見えない」。Response は graph 不在を明示し、必要なら user に anchor 提供を求める。

**Failure cause taxonomy** (doctrine-binding closed set、新 cause 追加は doctrine 改訂を要する):

Anchor-resolved 系 (anchor literal が valid に identify された後の failure):
- `traverse_empty` — anchor は得たが traverse 結果が空集合

Anchor-unresolved 系 (anchor literal が valid に得られなかった failure):
- `anchor_not_identified` — どの anchor 解決経路も成功せず
- `stale_anchor` — sid+name が `dream_scan` で resolve しない
- `tool_error` — `dream_scan` runtime error / filesystem 不在等

Cause 区別の operational necessity: operator (人間) が「どの種類の不在か」で次手 (anchor 提供 / tool 修復 / topic 再考) を判断するため。§5 template 配分は anchor-resolved/unresolved 区別に従う。

### Invariant 4: Recall-source acknowledgment (Phase 1.5 Acknowledgment specialization)

Recall 結果を使用した response には、以下を **literal identifier 形式で** articulate しなければならない:

- Anchor: literal `v1:<sid>/<name>` (省略不可、anchor-resolved 系のみ)
- Traversal depth + nodes_walked: integer (anchor-resolved 系のみ)
- Recall set: 引用に使った node identity の literal `v1:<sid>/<name>` list
- Evaluation: `sufficient` / `partial` / `no_match` literal token
- Cause (空-recall 系で必須、forgery cross-coupling): Inv 3 cause taxonomy の anchor 状態に整合する literal token

これは Phase 1.5 Acknowledgment invariant の skill 層継承: 外部依存 articulation と同型に、recall 経由情報の **provenance 申告** を義務化する。Operator は LLM の output が「自身の推論」か「graph recall に基づく既決事項の継承」かを区別できる。

**Forgery 防止 cross-floor coupling**: 空-recall 系を emit する response は Inv 3 cause field 必須。Cause なしの空-recall は Inv 4 違反。Forger は self-incriminating cause を選ばざるを得ない (post-hoc audit 強度)。Success-template での fabrication 検出は doctrine 層の射程外 (mechanism-free ceiling、Phase 3+ runtime evidence territory)。

**Non-recall articulation 範囲**: Inv 1 property 評価を実施したが trigger 不成立 (= plausibility または absence prong false) と判定した場合、`[no-recall] reason=<one-line>` 要求。Inv 1 property 評価をそもそも考慮しなかった通常 task は宣言義務なし。

### Invariant 5: Doctrine-not-mechanism (Phase 1.5 Declare-not-enforce specialization)

`context_graph_recall` skill は LLM が読んで自発判断するための **doctrine** である。Auto-trigger (skill auto-invocation、CLAUDE.md auto-load hint) は orthogonal な mechanism であり別 layer (Phase 2 Case D, harness-specific)。

Doctrine は宣言する。LLM は判断する。Mechanism は強制しない。Inv 1 の "judgmentally must" と整合 — observable 性は Inv 4 acknowledgment articulation を通じてのみ確保される。

## Recall 手順 (ordering invariant)

**Recall ordering invariant**: Anchor identification ≺ traverse execution ≺ result evaluation ≺ articulation ≺ continuation。

**Articulation は order 上の収束点であり全 path 必達** — success path では evaluation 成功後に articulation、failure path では Inv 3 cause taxonomy が成立した時点で articulation に直接合流、continuation はその後で recall set または empty context のいずれかで進行。順序逸脱 / 段階 skip / articulation の bypass は doctrine 違反。

Failure mode 分類は Inv 3 cause taxonomy が doctrine-binding に保持。各 cause 発生時の合流点は同一 (articulation step)、cause 種類による branch 構造は手順内に enumerate しない。

`max_depth` heuristic (soft guidance): default 3、handoff chain 追跡のように深い informed_by 連鎖を要する task では 5+。これは Inv 5 を保つ soft guidance であり、LLM が task に応じて判断する。

**Trust boundary**: Recall set を context として継続使用する際、recall set は system 自身の memory として trust。L2 の semantic correctness は記録時点判断 — 現在 context と矛盾する場合、矛盾検出 protocol は doctrine 提供せず LLM 判断に依存。Multi-user / 外部 source からの L2 受け入れは別 layer (Phase 3+)。

## Acknowledgment 形式 (schema floor + 4 templates)

Inv 4 schema floor (literal 必須、省略不可):

- Anchor: literal `v1:<sid>/<name>`
- Depth + walked: integer
- Recall set: literal list
- Evaluation: `sufficient` / `partial` / `no_match`
- Cause: Inv 3 cause taxonomy の literal token (空-recall 系で必須)

形式自由度: 自然言語可、structured block 可。Doctrine が固定するのは schema floor、formatting ではない。

### 最小行 template (drift 防止 fallback)

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

Floor を満たさない fluent-only acknowledgment ("I checked some prior context") は Inv 4 違反。空-recall で cause 不在も Inv 4 違反 (forgery cross-coupling)。Cause/template 不整合 (例: 空-recall template に `cause=anchor_not_identified` を emit) も Inv 4 違反。

## 隣接 skill との関係

### `kairos-knowledge` との境界

`kairos-knowledge` は L1 knowledge 一般への access skill (project convention や accumulated insight、時間軸薄)。`context_graph_recall` は temporal/relational recall に specialize した同格 sibling skill (過去 session work の連続性、時間軸濃)。

Skill 起動の判断は task 性質: convention / pattern → kairos-knowledge、prior session の決定 / handoff → context_graph_recall。両 skill が同 task で必要な場合、並列起動可。Doctrine 層では順序強制せず、LLM が両 source articulate して synthesis 判断する。

### `capability_status` pre-flight

`dream_scan` は `:core` tier (Phase 1.5 declared)、`capability_status` 自身も `:core`。Doctrine が capability_status 呼び出しを **prerequisite として要求しない** — pre-flight を doctrine 内部に組み込むと、doctrine の意味論が capability articulation 機構と coupled になる coherence concern が生じる。Pre-flight は best practice として LLM の選択自由はあるが、doctrine が invariant として要求しない。Doctrine は capability_status 不在環境でも動作する。

## 哲学的位置づけ

### 命題 5 (constitutive recording / Kairotic temporality)

L2 への記録は constitutive — 記録は事後 evidence ではなく system の being の reconstitution。Context graph はその記録同士の relation を articulate した structure。

`context_graph_recall` doctrine は Kairotic temporality を operational に行使する skill: 過去の決定を recall することは「過去」を再呼び起こすことではなく、現在の operation を過去の reified state に anchor し直すこと。Recall の度に system の現在は過去との connection を再構成する。

### 命題 7 (metacognitive self-referentiality)

Doctrine は LLM が自身の epistemic state を観察する skill: 「この task は私が今知らない prior state を仮定しているか?」。これは metacognition の operational form。

Phase 1.5 の Acknowledgment invariant が外部依存への metacognition だったのに対し、本 doctrine の Recall-source acknowledgment (Inv 4) は **過去自己への metacognition** — system 自身が時間的に内側で分岐し、現在の自己が過去の自己に依存していることを articulate する。

### 自己言及性

本 doctrine 自身は L1 knowledge であり、design 経緯は context graph に reified される。よって future session で「context_graph_recall doctrine の design rationale」を recall する task は、**doctrine 自身を invoke して doctrine 自身の起源を traverse する** — 構造的自己言及性が成立する (Generative Principle に整合)。

この自己言及性は §10 mandatory self-referential test (実装版設計 doc 参照) で実機検証される。

## L2 philosophy との整合

KairosChain の L2 layer は L1/L0 とは異なる緩い制約で運用される:

- L0 (philosophy / governance) と L1 (knowledge / doctrine) は完全 blockchain 保証
- L2 (session work / handoff) は **書き手 LLM の責任、verify しない、壊れたら壊れる** (relational ontology + DEE 哲学整合)

本 doctrine は L2 graph を参照する skill だが、graph の整合性検証は doctrine の射程外。書き手が relations を壊した場合は traverse が失敗するか (Inv 3 cause `traverse_empty` or `stale_anchor`) 不完全な結果を返すが、いずれも honest articulation で対応する。L2 完全性保証を求めると complex verification checker が必要になり、それは本 doctrine の意図ではない。

「辿れたら使う、辿れなかったら諦める」 — graceful degradation を design intent として採用する。

## 関連 doctrine

- `kairoschain_capability_boundary` (Phase 1.5): 8 invariants (Honest unknown / Acknowledgment / Declare-not-enforce 等) を本 doctrine が specialization で継承
- `kairos-knowledge`: 同格 sibling skill (上記境界参照)

## 関連 design doc

設計経緯は `docs/drafts/context_graph_recall_design_v1.3.md` (canonical) を参照。Round 1〜4 multi-LLM review 結果と patch log §13 で各 invariant の決定根拠を articulate。
