---
name: kairos_hook_projector_design_v0.2_draft
type: design_draft
version: 0.2
status: frozen_v0.2_2026-05-12 (round 2 residuals → implementation phase per L2 kairos_hook_projector_v0.2_freeze_and_loop_observation_20260512)
date: 2026-05-12
author: Claude Opus 4.7 (1M context), interactive session with masaomi
prior_version: kairos_hook_projector_design_v0.1_draft
revision_basis: round 1 multi-LLM review (14 (a)+(b) findings)
related:
  - kairos_hook_projector_v0.1_stage0_handoff_to_kairoschain_project_20260510
  - plugin_projector_v5_hooks_projection_design_draft_20260510
  - routines_x_kairoschain_autonomous_growth_design_discussion_20260504
---

# `kairos_hook_projector` v0.2 — Design Draft

## §1. Problem statement (invariant form)

**Inv-1.** KairosChain MCP tool 群の起動経路は、harness 上での LLM judgment に依存しない決定論的経路を **少なくとも一つ** 持たねばならない。

現状: instruction mode への projection は assistant judgment 依存で確率的。Prop 5 の要請する transparency は、tool が呼ばれること自体が確率的である限り構造的に達成不能。Inv-1 は runtime 起動経路の話であり、コンパイル時の判断 (§4 参照) は別レイヤーに属する。

## §2. Design invariants

| # | Invariant | 根拠 |
|---|---|---|
| Inv-1 | 決定論的 tool 起動経路の存在（runtime 層）| §1 |
| Inv-2 | 新規 projection 経路を作らない（既存 plugin_projector パイプラインに乗る） | Prop 1 + core 最小化原則 |
| Inv-3 | hook 編成ポリシーは SkillSet 単位で分離可能 | Prop 4 + Meeting Place 交換可能性 |
| Inv-4 | composition は projection interface 上で primitive と区別不能 | Prop 1: 同一構造で表現される |
| Inv-5 | 衝突解決の default は人間判断強制。自動解決は明示 opt-in、かつ初回活性化前に operator consent が chain_record される | masa mode § Process and Speed + Prop 10 procedural floor |
| Inv-6 | 段階 0 は副作用ゼロであり、これは boot-time 構造的検証で保証される（convention に依存しない）| Prop 3 structural impossibility |
| Inv-7 | hook 編成の変化は、それを引き起こす経路（compile / project / unproject / evolve）に依らず blockchain 記録対象 | Prop 5 constitutive recording |
| Inv-8 | 現在の hook composition は session start で operator に surface される | masa mode § Layer Awareness + Prop 10 contestability |

## §3. Layered structure (invariant form)

| Layer | 責務 invariant |
|---|---|
| Base (compiler) | mode 定義から hook 出力を導く決定論的写像（同入力→同出力）|
| Primitive variant | event × tool の hook 集合を、単一ポリシー観点で表現する SkillSet |
| Composite variant | 複数 variant を入力とし衝突解決を経て新たな variant を導く SkillSet |
| Projection | 既存 plugin_projector の経路を不変として再利用 |

**Inv-3.1 (interface indistinguishability)**: primitive と composite は projection interface（コンパイル出力 shape + ポリシー記述 grammar）において identical でなければならない。同じ grammar で記述され、同じ shape の hook 出力を生み、同じ projection 経路を通る。これが Prop 1 の object-level instance である。

## §4. Composition semantics (invariant form)

- **Inv-C1**: 合成結果は入力 variant 群の hook 集合の解決済み出力である（順序の意味は Inv-O1 参照）
- **Inv-C2**: 合成における衝突は決定論的に分類・解決される。具体的な分類体系（taxonomy）は §11 backlog
- **Inv-C3**: 衝突解決はコンパイル時に確定する。実行時は解決済み配置で発火する
- **Inv-C4**: 衝突解決ポリシーは composition 単位で宣言可能であり、宣言内容と解決結果は chain_record される。ポリシーの具体的選択肢は §11 backlog
- **Inv-C5**: コンパイル時 LLM 判断を採用する composition は、入力から再生可能な決定論的コンパイル成果物を持つ（LLM 判断の出力は chain_record され、後続コンパイルでは記録済み判断を再利用する）
- **Inv-C6**: composite が他の composite の入力になれる（合成の閉包性）
- **Inv-C7**: `extends` の dangling reference（参照先 variant 不在）は compile-time error である。silent skip / 部分適用は許容されない
- **Inv-C8**: composition graph は DAG であり、最大深度は有界である。循環参照と無限再帰は compile-time error である
- **Inv-C9**: hook の発火対象（tool 呼び出し記述）は構造化された引数配列として表現される。shell 解釈を経由する文字列補間は許容されない。補間トークンは閉じた allow-list から取られ、compile-time に検証される
- **Inv-C10**: 自動解決ポリシー（人間判断を経由しないポリシー）の活性化は、composition 単位の operator consent が初回活性化前に chain_record されていることを必要十分条件とする

### Ordering sub-invariant

- **Inv-O1**: 同 event に複数 hook が刺さる場合、実行順序は composition 出力時点で完全に決定されている。順序決定の具体的規則は §11 backlog だが、「同入力→同順序」が保証される

## §5. Self-evolution invariants

- **Inv-E1**: hook 編成の進化単位は SkillSet である
- **Inv-E2**: 進化提案は dream_propose → multi-LLM review (persona 3/3 APPROVE) → skills_promote → chain_record の既存パスを通る
- **Inv-E3**: 進化の決定根拠は L2 contexts として保存される
- **Inv-E4**: promotion された variant は、単一の文書化された operation により直前の chain-recorded state へ revertible である。rollback は upstream gate（Inv-E2）と独立した経路として常に利用可能でなければならない

## §6. Stage decomposition (invariant form)

各段階は前段階の invariant を保ったまま機能を追加する。invariant の後退は revision を要する。

| 段階 | 達成すべき invariant |
|---|---|
| 0 | base skeleton + schema (composition フィールド予約と validate) + read-only status tool。Inv-6 を boot-time assertion で構造的に保証 |
| 1 | コンパイル経路の確立（primitive variant に限定）と Inv-O1 の具体化 |
| 2 | projection 経路の活性化（既存 plugin_projector への組み込み）と Inv-7 の compile/project/unproject 各経路への enforcement |
| 3 | canonical primitive variant の登場（具体的 variant 名は §11 backlog）|
| 4 | composition 実装（Inv-C1 から Inv-C10 + Inv-O1 全ての満足）|
| 5 | dry-run period（具体期間は §11 backlog）|
| 6 | 本 projection 試運転（具体期間は §11 backlog）|
| 7 | reverse projection 設計 (v0.2 系列の next)|
| 8 | plugin_projector への統合 |

## §7. Stage 0 specification (invariant form)

### §7.1 Stage 0 DoD invariants

- **DoD-0-1**: skillset が MCP server に認識される
- **DoD-0-2**: mode_hooks schema が self-validating である
- **DoD-0-3**: composition 関連フィールドは schema validation の対象となる。文法的に正しい記述は accept される一方、文法違反は reject される。段階 0 では accept された記述が hook 出力に影響しないことが保証されるが、accept は silent ではなく status tool で可視化される
- **DoD-0-4**: read-only status tool が boot-time assertion 込みで副作用ゼロを構造的に保証する（projection target ファイル群の hash と mtime を tool 起動前後で比較し、差分発生時は fail-fast）
- **DoD-0-5**: 既存 plugin_projector test suite に regression なし
- **DoD-0-6**: `.claude/settings.json` および projection target 一式は段階 0 全期間で構造的に未 touch である（convention ではなく Inv-6 / DoD-0-4 の機械的検証によって）

### §7.2 Stage 0 schema invariants

- mode_name と version は required
- hooks は optional（composite-only variant を許容するため）
- composition 関連フィールドは optional 予約であり、文法的に正しい記述は schema validation を通る
- 自動解決ポリシーの宣言（Inv-C10 が要求する operator consent 未取得状態のもの）は段階 0 では schema レベルで warn-but-accept とし、status tool に明示される

## §8. Failure modes and invariant-form mitigations

| Failure mode | 該当 invariant |
|---|---|
| 合成衝突の silent 解決 | Inv-5 |
| hook 編成変化が後追い不能 | Inv-7（全変化経路で enforcement）|
| 自己進化の暴走 | Inv-E2 + Inv-E4（gate + rollback 二重）|
| 段階 0 での副作用混入 | Inv-6 + DoD-0-4（boot-time assertion）|
| 既存 instruction_mode 経路の破壊 | Inv-2（新規 projection 経路を作らない） |
| hook 経由の任意コード実行 | Inv-C9（構造化引数配列、補間 allow-list）|
| dangling extends による未定義動作 | Inv-C7（compile-time error）|
| composition graph の無限再帰 | Inv-C8（DAG + 深度有界）|
| hook composition の不可視化 | Inv-8（session start surface）|
| 自動解決ポリシーの silent escalation | Inv-C10（operator consent 必須）|
| 自己進化結果の不可逆性 | Inv-E4（single-operation rollback）|

## §9. Open questions (stage 1 以降で決める)

| # | 内容 | 決定段階 |
|---|---|---|
| OQ-1 | hook 環境変数の実機検証 | 段階 1 |
| OQ-2 | Inv-O1 を満たす具体的順序規則（宣言順 / 明示優先度 / その他）| 段階 1 |
| OQ-3 | mode_hooks 不在 mode の default 動作 | 段階 1 |
| OQ-4 | composition での variant 発見経路（自動 / explicit enable list）| 段階 4 |
| OQ-5 | Inv-C5 の chain_record 内容範囲（最小化と秘匿）| 段階 4 |
| OQ-6 | reverse projection の data model | 段階 7 |

## §10. Non-goals

- 段階 0〜2 は単一 instance 動作。Meeting Place 経由の variant 交換は段階 7 以降の検討対象
- v0.1 系列は observation のための metrics を持たない（v0.2 系列以降で別個に検討）
- v0.1 系列は dry-run の自動承認を持たない

## §11. Mechanism backlog (intentionally deferred)

以下は invariant ではなく mechanism のため本体に書かない:

- ファイル配置の具体パス（mode body と hooks の関係を含む）
- 各 SkillSet の具体名前
- CLI subcommand 構造
- YAML フィールド名の最終確定
- test の具体本数と naming
- commit 分割案
- Inv-C2 が要求する衝突分類体系の具体内容
- Inv-C4 が許容する解決ポリシーの具体選択肢
- Inv-O1 が要求する順序規則の具体内容
- Inv-C8 が要求する最大深度の具体値
- Inv-C9 の補間 allow-list の具体内容
- 段階 5/6 の dry-run / 試運転の具体期間

これらは「§2-§8 の invariant を満たす実装」の自由度として残す。

## §12. Round 1 review に対する応答（appendix, 非 invariant）

| Round 1 finding | v0.2 での対応 |
|---|---|
| (a1) command injection | Inv-C9 追加 |
| (a2) dangling extends | Inv-C7 追加 |
| (a3) DoD-0-6 verifiability | Inv-6 + DoD-0-4 で boot-time 構造化 |
| (a4) composition graph termination | Inv-C8 追加 |
| (a5) hook execution order | Inv-O1 追加 |
| (a6) accept-and-ignore 問題 | DoD-0-3 / §7.2 で validate + status 可視化に変更 |
| (b1) Inv-C2 4-class enumeration | Inv-C2 を「決定論的分類」一文に圧縮、taxonomy を §11 へ |
| (b2) Inv-C4 5-value enum | Inv-C4 を「宣言可能かつ記録される」へ圧縮、enum を §11 へ |
| (b3) Inv-4 rhetoric リスク | Inv-3.1 として projection interface invariant に再定置 |
| (b4) rollback 経路 invariant 不在 | Inv-E4 追加 |
| (b5) llm_arbitrated silent escalation | Inv-C10 追加（operator consent + chain_record 必須）|
| (b6) session start surface | Inv-8 追加 |
| (b7) α 案 mechanism in §8 | §8 を invariant 参照表に書き直し、α 案は §11 backlog へ |
| (b8) chain_record と project/unproject | Inv-7 を「全変化経路」に拡張、§6 段階 2 で enforcement を要求 |
