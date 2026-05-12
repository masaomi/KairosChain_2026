---
name: kairos_hook_projector_design_v0.1_draft
type: design_draft
version: 0.1
status: ready_for_multi_llm_review
date: 2026-05-12
author: Claude Opus 4.7 (1M context), interactive session with masaomi
related:
  - kairos_hook_projector_v0.1_stage0_handoff_to_kairoschain_project_20260510
  - plugin_projector_v5_hooks_projection_design_draft_20260510
  - routines_x_kairoschain_autonomous_growth_design_discussion_20260504
---

# `kairos_hook_projector` v0.1 — Design Draft

## §1. Problem statement (invariant form)

**Invariant Inv-1.** KairosChain MCP tool 群の起動経路は、harness 上での LLM judgment に依存しない決定論的経路を **少なくとも一つ** 持たねばならない。

現状: CLAUDE.md / instruction mode への projection は assistant judgment 依存で確率的。Prop 5（constitutive recording）の要請する transparency は、tool が呼ばれること自体が確率的である限り構造的に達成不能。

## §2. Design invariants

| # | Invariant | 根拠 |
|---|---|---|
| Inv-1 | 決定論的 tool 起動経路の存在 | §1 |
| Inv-2 | 新規 projection 経路を作らない（既存 `plugin_projector` のパイプラインに乗る） | 自己言及性（Prop 1）と core 最小化原則 |
| Inv-3 | hook の編成ポリシーは SkillSet 単位で分離可能でなければならない | Prop 4 (構造が可能性空間を開く) + Meeting Place での交換可能性 |
| Inv-4 | ポリシー間の合成は、合成自体が SkillSet として表現できなければならない | Prop 1 (構造的自己言及性): メタ層と base 層は同じ構造で記述される |
| Inv-5 | 衝突解決の default は人間判断を強制する。自動解決は明示的 opt-in のみ | masa mode § Process and Speed: 不可逆 action は process 優先 |
| Inv-6 | 段階 0 は副作用ゼロでなければならない（`.claude/settings.json` 未 touch） | Inv-5 から派生: 副作用導入の判断は段階を分離して人間 review を経る |
| Inv-7 | hook 編成の変化（add/drop/condition 変更/合成 graph 変化）は blockchain 記録対象 | Prop 5 (constitutive recording) |

## §3. Layered structure (invariant form)

| Layer | 責務 invariant |
|---|---|
| Base (compiler) | mode 定義から `plugin/hooks.json` を導く写像であること。写像は決定論的（同入力→同出力）|
| Primitive variant | event × tool の hook 集合を、単一のポリシー観点で表現する SkillSet |
| Composite variant | 複数 variant を入力とし、衝突解決を経て新たな variant を導く SkillSet |
| Projection | 既存 `plugin_projector` の `collect_hooks!` → `write_hooks_to_settings!` 経路を不変として再利用 |

**重要不変条件**: composite variant も primitive variant も、外部から見て区別がつかない（同じ skillset.json 形式、同じ hook 出力形式）。これは Prop 1 の構造的自己言及性の object-level instance。

## §4. Composition semantics (invariant form)

合成は以下の不変条件を満たす:

- **Inv-C1**: 合成結果は、入力 variant 群の hook 集合の **解決済み union** である
- **Inv-C2**: 衝突は (a) 完全重複, (b) 同 tool 異 condition, (c) 排他 tool 同時刺し, (d) 副作用 tool 重複 の 4 種に分類される
- **Inv-C3**: 衝突解決は **コンパイル時に確定** する。実行時 hook 起動時には解決済み配置で発火する
- **Inv-C4**: `conflict_policy` の選択肢は: `error` / `first_wins` / `last_wins` / `priority` / `llm_arbitrated`
- **Inv-C5**: `llm_arbitrated` 採用時のコンパイル時 LLM 判断は blockchain 記録される（Prop 5 由来）
- **Inv-C6**: composite variant 自身が他の composite variant の入力になれる（合成の閉包性）

## §5. Self-evolution invariants

夜間 growth cycle（既存 `routines_x_kairoschain_autonomous_growth_design_discussion_20260504` の枠組み）との接続:

- **Inv-E1**: hook 編成の進化単位は SkillSet である（YAML 修正、extends list 変更、conflict_policy 変更のいずれも）
- **Inv-E2**: 進化提案は `dream_propose` → multi-LLM review (persona 3/3 APPROVE) → `skills_promote` → `chain_record` の既存パスを通る
- **Inv-E3**: 進化の決定根拠（どの session 観察から、どの pattern が検出されたか）は L2 contexts として保存される

## §6. Stage decomposition

| 段階 | 責務 invariant |
|---|---|
| 0 | base skeleton + schema (composition フィールド予約) + read-only status tool。副作用ゼロ |
| 1 | compile + dry-run diff + validate（primitive variant のみ）|
| 2 | project + unproject（既存 `plugin_projector` パイプライン経由）|
| 3 | canonical primitive variant 3 種（conservative / agent_aggressive / multi_llm_review_proactive）|
| 4 | composition 実装（extends + overrides + conflict_policy）|
| 5 | dry-run period — 1 週間 |
| 6 | 本 projection 試運転 — 2 週間 |
| 7 | reverse projection 設計（v0.2）|
| 8 | `plugin_projector` への A 統合 |

各段階は前段階の invariant を保ったまま機能を追加する。invariant の後退は revision を要する。

## §7. Stage 0 specification (invariant form)

### §7.1 Stage 0 DoD invariants

- **DoD-0-1**: `kairos_hook_projector` skillset が MCP server に認識される
- **DoD-0-2**: mode_hooks JSON Schema が self-validating である
- **DoD-0-3**: `extends` / `overrides` / `conflict_policy` フィールドが optional 予約として schema に存在し、現段階では「書いても無視」が保証される
- **DoD-0-4**: read-only status tool が副作用ゼロで動作する
- **DoD-0-5**: 既存 `plugin_projector` test suite に regression なし
- **DoD-0-6**: `.claude/settings.json` は段階 0 全期間で未 touch である

### §7.2 Stage 0 schema invariants

mode_hooks schema は以下を満たす:
- mode_name と version は required
- hooks は optional（composite-only variant を許容するため）
- composition 関連フィールド（extends / overrides / conflict_policy）は optional 予約
- `conflict_policy` の default は `error`

### §7.3 Stage 0 scope exclusions

以下は段階 0 で **行わない**:
- 実コンパイル（段階 1）
- 実 projection（段階 2）
- composition 実装（段階 4）
- 既存ファイルの修正

## §8. Failure modes and mitigations (invariant form)

| Failure mode | Invariant が保護する条件 |
|---|---|
| 合成衝突を assistant が silently 解決 | Inv-5（default = `error`）|
| hook 編成変化が記録されず後追い不能 | Inv-7（blockchain 記録対象）|
| 自己進化が暴走 | Inv-E2（multi-LLM review persona 3/3 必須）|
| 段階 0 で `.claude/settings.json` を誤 touch | DoD-0-6（副作用ゼロが DoD）|
| 既存 instruction_mode projection 経路の破壊 | α 案: mode body と hooks を別ファイル化 |

## §9. Open questions (stage 1 以降で決める)

| # | 内容 | 決定段階 |
|---|---|---|
| OQ-1 | hook 環境変数の実機検証 | 段階 1 |
| OQ-2 | 同 event 複数 hook の実行順序保証メカニズム | 段階 1 |
| OQ-3 | mode_hooks YAML 不在 mode の default | 段階 1 |
| OQ-4 | composition での variant 発見経路（自動 / explicit enable list）| 段階 4 |
| OQ-5 | `llm_arbitrated` で使う LLM の roster | 段階 4 |
| OQ-6 | reverse projection (v0.2) の data model | 段階 7 |

## §10. Non-goals

- 段階 0〜2 は **単一 instance 動作**。Meeting Place 経由の variant 交換は段階 7 以降
- v0.1 は **observation のための metrics** を持たない。reverse projection (v0.2) で別個に設計
- v0.1 は **dry-run の自動承認** を持たない。masaomi 手動承認のみ

## §11. Mechanism backlog (intentionally deferred)

以下は invariant ではなく mechanism のため本体に書かない。段階 1 以降の implementation phase で具体化する:
- ファイル配置の具体パス
- tool 名の具体名前
- CLI subcommand 構造
- YAML フィールド名の最終確定
- test の具体本数と naming
- commit 分割案

これらは「§7 の invariant を満たす実装」の自由度として残す。
