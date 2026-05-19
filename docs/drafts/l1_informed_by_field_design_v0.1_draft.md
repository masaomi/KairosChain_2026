---
title: L1 frontmatter informed_by field (minimal scope)
version: v0.1
status: draft (for multi-LLM review)
date: 2026-05-19
author: Masaomi Hatakeyama (orchestrator: Claude Opus 4.7)
scope: minimal — skills_promote path only; manual authoring optional; Meeting Place path deferred
---

# L1 frontmatter `informed_by` field — minimal scope design

## 1. Why this exists

KairosChain の L1 SkillSet は様々な経路で立ち上がる: (i) L2 からの promotion、(ii) 直接起こし、(iii) Meeting Place 経由取得、(iv) 外部資料を参照した手作業など。現状、L1 entry の frontmatter には立ち上がりの **由来 (provenance)** が記録されない。

副作用として、後から「この L1 はなぜ・どの蓄積から立ち上がったか」を解釈しようとすると、blockchain 履歴と人間の記憶に依存することになる。命題 5 (構成的記録) の精神からは、由来の痕跡を L1 自身が部分的にでも保持しているのが望ましい。

本設計は、L1 frontmatter に optional な `informed_by` field を導入し、`skills_promote` 経路では自動付与する最小スコープの変更を扱う。

## 2. Scope

| 含む | 含まない |
|------|---------|
| L1 frontmatter schema に optional field `informed_by` を追加 | L1 entry に対する強制 (validation で reject しない) |
| L2 → L1 promotion 経路で `informed_by` を自動付与 | Meeting Place 由来の自動付与 (将来別 PR) |
| 直接 L1 起こし時の手動記入を許容 | 既存 L1 entry の backfill |
| Field の不在を valid 扱いとする | `informed_by` を読んで解釈する SkillSet (案 3、将来別 PR) |
| L2 frontmatter の `relations.informed_by` との形式整合 | L2 / blockchain 側の schema 変更 |

## 3. Design invariants

設計を機構ではなく性質で規定する。各不変条件は実装側の自由度を残し、将来の拡張を排除しない。

### Inv 1 — Field 性質: optional hint

L1 frontmatter の `informed_by` field は optional である。存在しない L1 entry は valid であり、不在自体が違反ではない。Field が存在する場合、それは「由来の手がかり」であって権威的な因果の主張ではない。Downstream consumer はこの field を **advisory** として扱い、不在を欠陥として扱ってはならない。

### Inv 2 — 形式の開放性: tagged identifier

`informed_by` の各 element は、由来種別を識別可能な形式の文字列である。種別の集合は閉じず、未知種別を受け入れ、verbatim に保持する性質を持つ。L2 frontmatter `relations.informed_by` と同一の syntactic shape を共有する。

未知種別の出現を「破損」として扱う実装は本設計に反する。新しい由来経路 (federation、外部 registry 等) が将来増える可能性を schema が排除してはならない。

### Inv 3 — Promotion 経路での自動性

L2 → L1 promotion 経路を経由する L1 entry 生成においては、source L2 を識別可能な値が `informed_by` に **自動的に付与される**。Promotion を実行する者が手作業で書く必要はない。

自動付与が成立する条件: 当該 promotion が単一以上の identifiable な L2 ancestor を持つこと。Ancestor が identify できない promotion 経路は本不変条件の射程外とする。

### Inv 4 — 不完全性の明示

`informed_by` field は完全性を主張しない。書かれている由来は **その時点で記録可能だった** 由来であり、書かれていない由来 (口頭議論、忘却された context、潜在的影響等) の存在を否定しない。

この性質は doctrine として表明される必要がある。Field の semantics を「完全な因果リスト」と誤解させる documentation / tool 応答は本不変条件に反する。

### Inv 5 — Forward-only

既存の L1 entry に対し、過去の由来を後から推測して書き込む操作 (backfill) は本設計の射程外であり、推奨されない。記録は **forward-only** に積まれ、未記録の過去はそのまま「未記録」として残る。

この性質は命題 5 の「記録は構成的であり遡及的に捏造されない」を尊重する。

### Inv 6 — Recall doctrine との互換性

`informed_by` を anchor として L2 / 他資源を traverse する behavior は、既存の `context_graph_recall` doctrine の射程に **そのまま収まる** か、収まらない場合は doctrine 側の拡張で吸収される。本設計は新たな traversal 機構を導入しない。

## 4. Why these invariants and not others

- **強制しないことを明示する理由**: L1 を直接起こす運用 (Meeting Place 取得、手書き doctrine 等) を阻害しないため。強制すれば masa mode § Scaffolding Stance が想定する「複数の正当な経路」と衝突する。
- **形式を開放しておく理由**: 命題 4 (構造が可能性空間を開き、設計が実現する) に倣い、未来の由来種別を先回りで列挙しない。Anti-enumeration を schema 層にも適用する。
- **自動性を promotion 経路だけに限定する理由**: 自動付与が確実に意味を持つのは ancestor が機械的に identify できる場合のみ。それ以外の経路で自動化を試みると、誤った由来を権威的に書き込む害が便益を上回る。
- **不完全性を doctrine として明示する理由**: Field の存在が「完全な因果記録がここにある」という錯覚を生むのを防ぐ。命題 6 の不完全性は隠すのではなく明示することで生産的になる。
- **Backfill を排除する理由**: 解釈と記録の混同を避ける。Backfill は構成的記録ではなく解釈の固定化であり、後の読み返しで別の解釈が立ち上がる余地を奪う。

## 5. Out of scope (deferred)

以下は本設計に含めない。別 PR / 別 SkillSet として後続で扱う:

- Meeting Place 取得経路での自動付与
- 直接 L1 起こし時の `informed_by` を促す UI / hint
- `informed_by` を読んで解釈する SkillSet (仮称 `l1_provenance_recall`)
- Blockchain 側の promotion event schema 拡張 (現状の chain record に source L2 が含まれているかの確認は本 PR の前提調査として実施するが、schema 変更はしない)
- 既存 L1 entry の backfill
- `informed_by` を anchor とした reverse-search (L1 → L2) の最適化

## 6. Open questions

設計確定前に解決が望ましい点:

1. **Field の階層**: L2 と同じく `relations.informed_by` とするか、flat に `informed_by` とするか。L2 frontmatter との対称性を取るなら前者、L1 の簡潔性を優先するなら後者。
2. **Promotion path での source identification 失敗時の挙動**: `informed_by` を空 list で書くか、field 自体を書かないか。Inv 1 (不在を valid とする) との整合からは後者が自然。
3. **手動記入時の妥当性検証**: 形式が壊れている場合 (例: prefix なしの素文字列) を warn するか silent に受け入れるか。Inv 2 の「未知種別を受け入れる」と緊張する可能性。

## 7. Success criteria

本設計が「成立した」とみなされる条件:

- L2 → L1 promotion を実行した結果、生成された L1 frontmatter に source L2 を指す `informed_by` が記録される
- 既存 L1 entry (Field 不在) が引き続き valid に load される
- 手動で `informed_by` を書いた L1 entry が valid に load される
- 未知 prefix を含む `informed_by` が破棄されずに保持される
- `informed_by` 不在を理由とした警告 / エラーが発生しない

## 8. Backlog (mechanism choices, not for this design)

実装段階で決める事項 (本ドラフトの議論対象ではない):

- Field 値の正規化規則
- Promotion tool 内での source L2 取得経路
- Frontmatter parser の field 認識位置
- Test fixture の置き場所
- Documentation 更新箇所

これらは設計 invariants から逸脱しない範囲で実装者が決定する。
