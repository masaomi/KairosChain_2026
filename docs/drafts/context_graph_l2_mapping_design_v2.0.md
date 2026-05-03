---
name: context_graph_l2_mapping_design
description: Context Graph v2.0 — L2 evidential ontology に整合した薄い設計。design-by-invariant 路線を破棄し、rail (parse + security) のみ規定し解釈は traverse 側に委ねる。
tags: [design, context-graph, L2, minimum, evidential]
type: design_draft
version: "2.0"
authored_by: claude-opus-4-7-with-masaomi
supersedes: context_graph_l2_mapping_design_v1.0-f-high
date: 2026-05-01
---

# Context Graph × KairosChain v2.0 (薄化版)

## v1.0-f-high → v2.0 の方針転換

v1.0-f-high (251 行、design-by-invariant + 不変条件 11 件) を **撤回** し、L2 evidential ontology に整合した最小設計に再起。

### 撤回理由

L2 は blockchain 記録対象でなく、可変であり、解釈は traverse 側に委ねられる ontology である (v1.0-f-high §6 自身の言明)。にもかかわらず write serialization invariant / atomic write / merge invariant / fail-closed parse / bounded-pass / observed_at clamp asymmetry など **L0 級の immutability/durability 保証** を L2 に持ち込んでいた。これは category error。

詳細根拠: memory `feedback_design_by_invariant_scope.md`、L2 `context_graph_v1.2_review_loop_analysis_handoff` の loop drift 分析。

## 設計原則 (4 つ)

1. **L2-evidential**: relation は事実の主張であり、真偽判定は traverse 側 (未来の KairosChain = LLM + 人間) に委ねる
2. **Forward-only**: 既存 L2 (relations[] 不在) は触らない、空配列扱い
3. **Phase 1 scope**: L2 単独、L0/L1 不変、`informed_by` のみ (supersedes 等は Phase 2)
4. **Rail only, semantics open**: 制約は parse 可能性と security のみ。意味的整合性は強制しない

## §1 エッジ schema

```yaml
relations_schema: 1
relations:
  - type: informed_by
    target: v1:session_20260420_051349_c68d4622/multi_llm_review_session
    # observed_at 等の任意 metadata を user/system が書いてもよい (descriptive、強制しない)
```

- `relations_schema`: descriptive hint。未知 version は traverse 側で skip するなどの判断材料
- `type`: 現在は `informed_by` のみ recognized。それ以外は traverse 側で skip
- `target`: 後述の canonical regex で parseable な参照文字列

`_resolution` 等の system-managed key は **持たない** (resolve は traverse 時に都度実行、結果は in-memory のみ)。

## §2 Target canonical regex (parse 可能性のため)

```
\Av1:(?<sid>session_\d{8}_\d{6}_[0-9a-f]{8})/(?<name>[a-z][a-z0-9_]{0,63})\z
```

- session_id segment + name segment の完全形のみ受容
- name 部分は先頭 1 文字 + 後続 0..63 文字 (合計 1〜64 文字)
- Ruby 側のみ enforce。JSON Schema は **descriptive** (validate を強制しない、書いても hint として扱う)

→ v1.0-f-high の 真P0-D (Ruby/Schema dialect probe assertion) は不要。Schema を強制しないので dialect 不一致は問題にならない

## §3 Path containment (security)

`resolve_target(target_str)`:

1. canonical regex で match (失敗 → MalformedTargetError、ただし traverse 側では skip + warn でよい)
2. `<context_root>/<sid>/<name>/<name>.md` を構築
3. `realpath` 解決後、`context_root` の realpath 配下にあることを確認
4. 配下でなければ PathEscapeError (security 制約、これは hard fail)
5. ENOENT は dangling 扱い (= traverse 側で「target 未存在」として扱える)

これは **security 由来の制約** (session 外への path traversal 防止) なので残す。哲学由来の制約ではない。

## §4 Write path: context_save

L2 frontmatter に `relations:` を書く時の処理。

```
1. frontmatter parse (YAML.safe_load)
   - parse 失敗 → エラーを返し書き込み中止 (無効な YAML を上書きしない常識)
   - ただし fail-closed invariant のような大仰な機構は持たない
2. relations: が存在すれば各 item に対して:
   - canonical regex で target を validate (失敗時は user に返す)
   - resolve_target で path containment check (PathEscape は hard fail)
3. 既存の YAML.dump で書き戻す
   - atomic write / fsync sequence / mode preservation 等の特殊機構は不要
   - 通常の File.write で十分 (L2 は editor で常時編集される ontology)
```

**意図的に持たない機構**:
- write serialization (flock 等) — L2 は last-writer-wins で運用される
- atomic rename + fsync sequence — fs default で十分
- mode/owner preservation — 同上
- system-managed keys の strip — `_resolution` を持たないので不要
- observed_at clamp asymmetry — observed_at を system が記録しないので発生しない
- unknown-version path 特殊処理 — schema validate を強制しないので未知 version も普通に通る

## §5 Read path: dream_scan traverse_informed_by

BFS で informed_by edge を辿る:

- visited set で cycle 防止
- depth ≤ 3 (loop / 計算量制御)
- 各 node load は §3 path containment guard を経由
- target の relations_schema が未知 version → skip + warn (traverse は止めない)
- target の frontmatter が parse 失敗 → skip + warn (traverse は止めない)
- ENOENT (dangling) → skip + 観測 (traverse は止めない)

→ traverse は **best-effort で進む**。エラーで全体停止しない。

## §6 哲学的位置づけ

- L2-evidential、edge-relational ontology (v1.0-f-high §6 から継承)
- 解釈は traverse 側 (未来の LLM + 人間) に委ねる: 命題 8 (co-dependent ontology) + 命題 9 (metacognitive dynamic process)
- 構造を opens、design は最小、可能性空間は traverse 側で実現: 命題 4 (Structure opens possibility space; design realizes it)
- mtime からの observed_at 事後 synthesis は禁止 (命題 5 constitutive recording の L2 適用): observed_at を system が書かないことで自動的に成立

## §7 Phase 1→2 gate (定性のみ)

定量 floor (50+/3+ contexts traversed) は **持たない** (= 早期 promotion を妨げる過剰制約)。代わりに:

- maintainer (masaomi) が「この実装で informed_by の運用が見えた」と書面で articulate
- L2 として保存
- supersede 候補で multi-LLM review

Phase 2 に進む条件は **質的判断のみ**。

## §8 Phase 2/3 stub

- **Phase 2**: supersedes / led_to / derived edges、reverse traversal、dangling GC、edges.jsonl export (cache としてではなく inspection 用 dump file として、必要なら)
- **Phase 3**: L0 波及、命題 8

Phase 2 で cache (edges.jsonl) を導入する判断は **観測ベース**: full walk + BFS が体感で遅くなったら検討する。L2 件数 1,000 程度までは不要。

## §9 実装ステップ

1. canonical regex constant + resolve_target (path containment) — `KairosChain_mcp_server/lib/kairos_mcp/context_graph.rb` 新規
2. context_save の relations: 受容部 (既存 tool 改修 or 新規)
3. dream_scan の traverse_informed_by (既存 tool 改修 or 新規)
4. テスト suite:
   - canonical regex match / non-match
   - path containment (escape attempt 拒否)
   - BFS visited set + depth limit
   - dangling target の skip + warn
   - parse 失敗 target の skip + warn
   - 未知 relations_schema の skip + warn
5. 実装 multi-LLM review (1 round、orchestrator-model = claude-opus-4-7)
6. commit + L2 に `context_graph_phase1_implementation_complete` を保存

## §10 v1.0-f-high から **持ち越さない** もの (明示)

- §1.1 System-managed keys / strip invariant
- §2 JSON Schema 強制 + read-validate subset invariant
- §3 Validator pinning (`json_schemer ~> 2.0`)
- §4.1 CONTEXT_ROOT_REAL boot snapshot + StaleContextRootError
- §5 8-step ordering (簡略化)
- §5 Write serialization invariant (P0-α)
- §5 Atomic write invariant + Mode/owner invariant
- §5 Edges.jsonl best-effort scope invariant (P0-iv) — edges.jsonl 自体を持たない
- §5.1 Frontmatter parse fail-closed (P0-β)
- §5.2 Unknown-version step 8 取り扱い (P0-γ)
- §5b kairos reindex + merge invariant + bounded-pass invariant + pending dir
- §11 Implementation Decisions Backlog 全 13 件
- 真P0-D regex dialect probe boot-time assertion
- 真P0-E unknown-version edges.jsonl handling

→ 設計行数: 251 → 約 100 行、実装行数の見積もり: 6-12 h → 2-4 h

---

*End of v2.0.*
