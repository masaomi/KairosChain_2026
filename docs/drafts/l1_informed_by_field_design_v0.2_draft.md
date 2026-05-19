---
title: L1 frontmatter informed_by field (minimal scope)
version: v0.2
status: draft (for multi-LLM review, round 2)
date: 2026-05-19
author: Masaomi Hatakeyama (orchestrator: Claude Opus 4.7)
scope: minimal — skills_promote path only; manual authoring optional; Meeting Place path deferred
prior_round: v0.1 → REVISE (3 P0). v0.2 closes all three by pinning shape, narrowing Inv 6, and reconciling Inv 3 with Success Criterion #1.
---

# L1 frontmatter `informed_by` field — minimal scope design (v0.2)

## 1. Why this exists

KairosChain の L1 SkillSet は様々な経路で立ち上がる: (i) L2 からの promotion、(ii) 直接起こし、(iii) Meeting Place 経由取得、(iv) 外部資料を参照した手作業など。現状、L1 entry の frontmatter には立ち上がりの **由来 (provenance)** が記録されない。

副作用として、後から「この L1 はなぜ・どの蓄積から立ち上がったか」を解釈しようとすると、blockchain 履歴と人間の記憶に依存することになる。命題 5 (構成的記録) の精神からは、由来の痕跡を L1 自身が部分的にでも保持しているのが望ましい。

本設計は、L1 frontmatter に optional な `relations.informed_by` field を導入し、`skills_promote` 経路で identifiable な L2 ancestor が存在する場合に自動付与する最小スコープの変更を扱う。

## 2. Scope

| 含む | 含まない |
|------|---------|
| L1 frontmatter schema に optional field `relations.informed_by` を追加 | L1 entry に対する強制 (validation で reject しない) |
| L2 → L1 promotion 経路で identifiable な ancestor がある場合の自動付与 | Meeting Place 由来の自動付与 (将来別 PR) |
| 直接 L1 起こし時の手動記入を許容 | 既存 L1 entry の backfill |
| Field の不在を valid 扱いとする | `informed_by` を読んで解釈する SkillSet (案 3、将来別 PR) |
| L2 frontmatter `relations.informed_by` と同一名前空間 | L2 / blockchain 側の schema 変更 |

## 3. Design invariants

設計を機構ではなく性質で規定する。各不変条件は実装側の自由度を残し、将来の拡張を排除しない。

### Inv 1 — Field 性質: optional hint

L1 frontmatter の `relations.informed_by` field は optional である。存在しない L1 entry は valid であり、不在自体が違反ではない。Field が存在する場合、それは「由来の手がかり」であって権威的な因果の主張ではない。Downstream consumer はこの field を **advisory** として扱い、不在を欠陥として扱ってはならない。

### Inv 2 — 形式と配置: L2 frontmatter との対称性

`informed_by` は `relations` 名前空間配下に配置され、L2 frontmatter の `relations.informed_by` と **同一の配置・同一の syntactic shape** を共有する。各 element は由来種別を識別可能な形式の文字列リストであり、種別の集合は閉じず、未知種別を受け入れ verbatim に保持する性質を持つ。

L1 を flat な `informed_by:` 直下に置く実装、または L2 と異なる element 形式を要求する実装は、本不変条件に反する。未知種別の出現を「破損」として扱う実装も同様に反する。

### Inv 3 — Promotion 経路での条件付き自動性

L2 → L1 promotion 経路において、source L2 ancestor が機械的に identify 可能な場合に限り、当該 ancestor 識別子が `relations.informed_by` に **自動的に付与される**。

Ancestor が identify できない promotion 経路 (例: source L2 が消失している、複数候補が機械判別不能、promotion tool が ancestor 情報を保持していない等) では、field を書かないことが許容される (Inv 1 に従う)。この場合、promotion 自体は阻害されない。

### Inv 4 — 不完全性の明示

`relations.informed_by` field は完全性を主張しない。書かれている由来は **その時点で記録可能だった** 由来であり、書かれていない由来 (口頭議論、忘却された context、潜在的影響、identify 不能だった ancestor 等) の存在を否定しない。

この性質は doctrine として表明される必要がある。Field の semantics を「完全な因果リスト」と誤解させる documentation / tool 応答は本不変条件に反する。

### Inv 5 — Forward-only

既存の L1 entry に対し、過去の由来を後から推測して書き込む操作 (backfill) は本設計の射程外であり、推奨されない。記録は **forward-only** に積まれ、未記録の過去はそのまま「未記録」として残る。

この性質は命題 5 の「記録は構成的であり遡及的に捏造されない」を尊重する。

### Inv 6 — 既存 traversal の不変

本設計は新たな traversal 機構を導入しない。`relations.informed_by` の存在は既存の `context_graph_recall` doctrine の動作を変更せず、当該 doctrine が `informed_by` を anchor として使用するか否かは別 PR の射程である。

## 4. Why these invariants and not others

- **強制しないことを明示する理由**: L1 を直接起こす運用 (Meeting Place 取得、手書き doctrine 等) を阻害しないため。強制すれば masa mode § Scaffolding Stance が想定する「複数の正当な経路」と衝突する。
- **L2 と同一名前空間に固定する理由**: Inv 2 が要求する syntactic shape parity を frontmatter 配置レベルで satisfiable にするため。Flat vs nested を未決にすると Inv 2 が空 invariant になる (v0.1 round 1 で指摘された矛盾)。
- **自動性を「条件付き」とする理由**: 自動付与が確実に意味を持つのは ancestor が機械的に identify できる場合のみ。それ以外の経路で自動化を試みると、誤った由来を権威的に書き込む害が便益を上回る。Inv 1 (不在を valid とする) と整合させるため、識別失敗時は field 不在を許容する。
- **不完全性を doctrine として明示する理由**: Field の存在が「完全な因果記録がここにある」という錯覚を生むのを防ぐ。命題 6 の不完全性は隠すのではなく明示することで生産的になる。
- **Backfill を排除する理由**: 解釈と記録の混同を避ける。Backfill は構成的記録ではなく解釈の固定化であり、後の読み返しで別の解釈が立ち上がる余地を奪う。
- **本 PR で traversal を扱わない理由**: 記録 (write-side) と解釈 (read-side) は別関心。書き込みなしには読み込みが意味を持たず、書き込みが安定する前に読み込みを設計すると先回り設計になる。命題 4 の「構造が可能性空間を開く」に倣い、まず痕跡を残す substrate のみを最小で導入する。

## 5. Out of scope (deferred)

以下は本設計に含めない。別 PR / 別 SkillSet として後続で扱う:

- Meeting Place 取得経路での自動付与
- 直接 L1 起こし時の `informed_by` を促す UI / hint
- `context_graph_recall` doctrine による `informed_by` anchor の利用 (read-side)
- `informed_by` を読んで解釈する SkillSet (仮称 `l1_provenance_recall`)
- Blockchain 側の promotion event schema 拡張
- 既存 L1 entry の backfill
- `informed_by` を anchor とした reverse-search (L1 → L2) の最適化
- 手動記入時の妥当性検証ポリシー (warn / silent / strict) の確定

## 6. Open questions (round 2: resolved)

v0.1 round 1 で残っていた 3 件は本 v0.2 で解決済み:

- ~~Field の階層 (flat vs nested)~~: **Inv 2 で `relations.informed_by` に確定**
- ~~Promotion failure 時の挙動~~: **Inv 3 で「ancestor identify 不能時は field 不在が許容される」と確定**
- ~~手動記入時の妥当性検証~~: **§5 deferred に移動 (本 PR の射程外)**

現時点で本ドラフトに対する Open question はない。

## 7. Success criteria

本設計が「成立した」とみなされる条件:

- L2 → L1 promotion を実行した結果、**ancestor が identify 可能だった場合に限り**、生成された L1 frontmatter の `relations.informed_by` に source L2 を指す識別子が記録される
- Ancestor identify 不能だった promotion では `relations.informed_by` が不在のまま L1 が生成され、promotion 自体は成功する
- 既存 L1 entry (Field 不在) が引き続き valid に load される
- 手動で `relations.informed_by` を書いた L1 entry が valid に load される
- 未知種別を含む `relations.informed_by` element が破棄されずに保持される
- `relations.informed_by` 不在を理由とした警告 / エラーが発生しない

## 8. Backlog (mechanism choices, not for this design)

実装段階で決める事項 (本ドラフトの議論対象ではない):

- Identifier 文字列の正規化規則
- Promotion tool 内での source L2 取得経路
- Frontmatter parser の field 認識位置
- Test fixture の置き場所
- Documentation 更新箇所
- Element の cardinality 表現 (単一値 vs 配列) の具体 syntax — Inv 2 の「list」性は保ったまま、YAML 上の許容 shape は実装裁量

これらは設計 invariants から逸脱しない範囲で実装者が決定する。

## 9. Changes from v0.1

| 変更 | 反映先 | 解決した P0 |
|------|--------|-------------|
| Field の階層を `relations.informed_by` に確定 | Inv 2, §2 scope, §7 success criteria 全体 | P0-A |
| Inv 6 を「新 traversal 機構を導入しない」の一行に縮約、doctrine 拡張の話は §5 deferred へ | Inv 6, §5 | P0-B |
| Inv 3 を「ancestor identify 可能時に限り自動付与」と明示、Success Criterion #1 を条件付きに修正 | Inv 3, §7 #1, §7 #2 (新規) | P0-C |
| Open questions 3 件をすべて解決 (2 件は invariants で確定、1 件は deferred に移動) | §6 | — |
