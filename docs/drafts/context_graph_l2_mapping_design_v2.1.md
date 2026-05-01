---
name: context_graph_l2_mapping_design
description: Context Graph v2.1 — v2.0 (L2 evidential, design-by-invariant 撤回) を multi-LLM review (round 1, REVISE) で発見された P0 (a) deployment-grounded 指摘に対し最小 patch。security 由来制約と durability invariant の区別を明示。
tags: [design, context-graph, L2, minimum, evidential]
type: design_draft
version: "2.1"
authored_by: claude-opus-4-7-with-masaomi
supersedes: context_graph_l2_mapping_design_v2.0
date: 2026-05-01
---

# Context Graph × KairosChain v2.1

## v2.0 → v2.1 の patch 範囲

v2.0 multi-LLM review (5 reviewers, REVISE) で残った真の P0 (a) deployment-grounded 指摘のみ最小 patch。哲学姿勢 (L2-evidential、design-by-invariant 撤回) は維持。

### Patch 動機の整理

v2.0 で **「security 由来制約」と「L0 級 durability invariant」を区別しきれていなかった**。具体的には:

| 制約 | v2.0 | v2.1 | 理由 |
|------|------|------|------|
| 直列化 (flock 等) | 持たない | 持たない | L0 durability の category error、L2 では last-writer-wins で OK |
| Atomic rename | 持たない | **持つ** | crash 中の File.write が valid YAML を truncate する → これは lost-update でなく **既存記録の破壊** = security 由来 |
| YAML type whitelist | 不問 | **持つ** | Ruby object dump が non-safe loader 攻撃面を作る = security 由来 |
| Symlink rejection | 暗黙 | **明示** | realpath + start_with? は TOCTOU 脆弱、lstat 必要 = security 由来 |
| Strip system-managed | 持たない | 持たない | `_resolution`/`asserted_by` を持たないので不要 |

→ **「他者の有効記録を破壊しない」「攻撃面を作らない」は L0 durability ではなく security**。残す。

## 設計原則 (4 つ、v2.0 から不変)

1. **L2-evidential**: relation は事実の主張、真偽判定は traverse 側に委ねる
2. **Forward-only**: 既存 L2 (relations[] 不在) は触らない、空配列扱い
3. **Phase 1 scope**: L2 単独、L0/L1 不変、`informed_by` のみ
4. **Rail only, semantics open**: 制約は parse 可能性 + security のみ。意味的整合性は強制しない

## §1 エッジ schema

```yaml
relations_schema: 1
relations:
  - type: informed_by
    target: v1:session_20260420_051349_c68d4622/multi_llm_review_session
    # observed_at 等の任意 metadata を user/system が書いてもよい (descriptive)
```

**§1.1 Schema rule**:

- `relations` は Array、各 item は Hash (これに反する場合は §4 で MalformedRelationsError)
- 各 item は `type: String` と `target: String` を必須 (欠損時は MalformedRelationsError)
- `type` は現在 `informed_by` のみ recognized。それ以外は **書き込み許容、traverse 時 skip** (Phase 2 拡張余地)
- `target` は §2 canonical regex に match (失敗時は MalformedTargetError)
- それ以外の任意 key (observed_at 等) は **descriptive、validate しない、保持はする**

**§1.2 Authorship 位置づけ (Phase 1 stance)**:

L2-evidential ontology では、relation は **その frontmatter を持つ session の主張** である。「session A が `informed_by: session_B` と書く」のは A の claim であり、B の同意は不要 (forward reference は L2 で常に許容される)。Cross-file spoofing (B の file を直接編集して fake edge を仕込む) は filesystem-level access control の範疇であり、application-level 設計の対象外。Phase 2 で federation や cross-instance exchange を扱う際に `asserted_by` 等の明示 binding を再検討。

## §2 Target canonical regex

```
\Av1:(?<sid>[A-Za-z0-9_][A-Za-z0-9_.\-]{0,127})/(?<name>[A-Za-z0-9_][A-Za-z0-9_.\-]{0,127})\z
```

**v2.0 → v2.1 緩和**: v2.0 regex は session_id を `session_\d{8}_\d{6}_[0-9a-f]{8}` 固定としていたが、既存 L2 は混在 (canonical 231 件 + human-readable 15 件: `coaching_insights_20260327`, `received_skills`, `service_grant_fix_plan_review_2026-03-19` 等)。実体に合わせ緩和。

**Constraints**:
- 各 segment 1〜128 chars
- 先頭文字は `[A-Za-z0-9_]` (leading `.` `-` を禁止 → `..`, `-rf` 等の path tricks 防止)
- 後続は `[A-Za-z0-9_.\-]` (alphanumeric + `_` `.` `-`)
- `/`, `\0`, control chars, whitespace は不許可
- session_id と name の **同一 character class** (異形を作らない)

→ 既存全 L2 が `v1:` で参照可能。Path traversal 攻撃 (`../`) は char class で阻止。

JSON Schema は **descriptive** (validate を強制しない、書いても hint)。Ruby 側のみ enforce。

## §3 Path containment (security 由来)

`resolve_target(target_str)` は以下を順に行う:

1. §2 canonical regex で match — 失敗 → `MalformedTargetError`
2. `context_root = KairosMcp.context_dir(user_context: @safety&.current_user)` を取得し、**call 時 realpath**
3. 構成 path: `<context_root_real>/<sid>/<name>/<name>.md`
4. `File.realpath` で解決 — ENOENT は捕捉して **dangling 扱い** (= traverse 側で「target 未存在」)、その他 fs エラーは `PathResolutionError`
5. 解決後 path が `context_root_real + File::SEPARATOR` で始まることを確認 — 違反は `PathEscapeError` (security hard fail)
6. **Symlink rejection**: 構成 path の **最終 component** に対し `File.lstat` を実行 (call 時、realpath 解決後)。`symlink?` が真なら `SymlinkRejectedError` (security hard fail) — TOCTOU 緩和のため、open 前 check を採用
7. 解決後 path を返す

**§3.1 PathEscape / Symlink の扱い (write/read 非対称)**:

| エラー | Write path (§4) | Read path (§5) |
|--------|----------------|----------------|
| MalformedTargetError | hard fail (write 拒否) | skip + warn |
| ENOENT (dangling) | accept (forward reference 許容) | skip + 観測 |
| PathEscapeError | **hard fail (両方)** | **hard fail (両方)** |
| SymlinkRejectedError | **hard fail (両方)** | **hard fail (両方)** |
| PathResolutionError | hard fail | skip + warn |

**§3.2 Filesystem case-sensitivity assumption**:

`context_root` は **case-sensitive filesystem 上にあること** を要求する (Linux ext4 default ✓、macOS APFS は volume 設定により case-sensitive 化が必要)。Case-insensitive fs では `Foo`/`foo` 衝突が起き得るが、Phase 1 は document-only で検出機構は持たない。Boot 時の health check で `context_root` の case sensitivity を probe し warning を emit する程度に留める (実装判断、§9 backlog なし)。

## §4 Write path: context_save

**§4.1 Validation 配置**: `KairosMcp::ContextManager#save_context` 内で実施。Tool layer (`tools/context_save.rb`) は `{success: false, error: ...}` を surface するのみ。

**§4.2 処理 flow**:

```
1. frontmatter parse (YAML.safe_load(permitted_classes: [Date, Time]))
   parse 失敗 → InvalidFrontmatterError、write 中止
2. relations: が存在すれば validate:
   2a. relations が Array でない → MalformedRelationsError
   2b. 各 item が Hash でない → MalformedRelationsError
   2c. 各 item に type または target キーが無い → MalformedRelationsError
   2d. type が String でない、または target が String でない → MalformedRelationsError
   2e. target を §2 canonical regex で match → 失敗 → MalformedTargetError
   2f. resolve_target を call (PathEscape / Symlink は hard fail、ENOENT は許容)
3. Type whitelist enforcement: relations[] item 内のすべての value が
   {String, Integer, Float, TrueClass, FalseClass, NilClass, Hash, Array, Time, Date}
   のいずれかであること。違反は UnsafeRelationValueError
4. atomic rename write:
   - Tempfile を <target>.tmp.<pid>.<rand> として同一 directory に作成
   - 全内容を write
   - File.rename(tempfile, target) で atomic 置換
   - crash 中 / concurrent writer 衝突時、target は pre-rename か post-rename のどちらか
   - fsync sequence は要求しない (durability は L0 概念、ここは "valid YAML を truncate しない" だけ保証)
```

**§4.3 「Type whitelist」「Atomic rename」「Symlink rejection」を残す理由 (再掲)**:

これらは v2.0 で「持たない」とした機構だが、v2.1 で復活。理由は **L0 durability invariant ではなく security 由来** だから:

- **Type whitelist**: Ruby object を YAML.dump すると anchor/alias を含む output になり、downstream の non-safe loader を攻撃可能。これは「他者を攻撃しない」原則
- **Atomic rename**: 既存の valid YAML を crash で truncate すると、§5 read で skip+warn となり恒久的 dangling 化 = **既存記録の破壊**。lost-update (= concurrent write が一方の更新を上書き) は L2-evidential で許容するが、**破壊** は許容しない
- **Symlink rejection**: realpath + start_with? のみでは TOCTOU 攻撃 (check-then-use の間に symlink 入替) で context_root 外を読み書きされる

これらは durability ではなく **integrity (改竄/攻撃に対する耐性)** 由来。

## §5 Read path: dream_scan traverse_informed_by

**§5.1 配置**: `KairosMcp::SkillSets::Dream::Scanner` に新メソッド `#traverse_informed_by(start_sid:, start_name:, max_depth: 3)` を追加。Tool 側は `dream_scan` に新 arg `mode: 'traverse'` (+ `start_sid`, `start_name`) を追加して呼び出す (`mode: 'scan'` が現行 default、Phase 1 では default 不変)。

**§5.2 BFS 動作**:

- visited set で cycle 防止
- `max_depth ≤ 3` (default 3、caller が override 可)
- 各 node load は §3 path containment guard を経由
- target frontmatter の `relations:` が無い、または `relations_schema` が未知 version → skip + warn (この node の outgoing edges を辿らない)
- target frontmatter parse 失敗 → skip + warn
- ENOENT (dangling) → skip + 観測
- 各 item validation は **read-side minimal** (§1.1 と同じ rule、subset)

**§5.3 Return shape**:

```ruby
{
  root: "v1:<sid>/<name>",
  nodes: [
    { target: "v1:<sid>/<name>", depth: <int>, status: :ok | :dangling | :skipped, reason: <String|nil> },
    ...
  ],
  warnings: [<String>, ...]
}
```

- `nodes` は **visit 順** (root を含む、depth 0 = root)
- `status: :ok` = 正常 visit、`:dangling` = ENOENT、`:skipped` = parse 失敗 / 未知 version / Malformed
- `warnings` は **return payload に積む** (stderr 経由でない理由: caller が LLM の場合 stderr が観測できない)

**§5.4 dream_scan tool との独立性**: Phase 1 では `traverse_informed_by` の結果を blockchain に記録しない (現行 `dream_scan mode: 'scan'` の `record_findings` 経路と分離)。Phase 2 で promotion 候補解析に使う場合に統合判断する。

## §6 哲学的位置づけ

- L2-evidential、edge-relational ontology (v2.0 §6 から継承)
- 解釈は traverse 側 (未来の LLM + 人間) に委ねる: 命題 8 (co-dependent ontology) + 命題 9 (metacognitive dynamic process)
- 構造を opens、design は最小、可能性空間は traverse 側で実現: 命題 4 (Structure opens possibility space; design realizes it)
- **Synthesis prohibition (明示)**: `context_save` は **system-derived field を `relations[]` に inject してはならない**。具体的には mtime-based observed_at、自動 resolved 判定の永続化、authorship binding 等の system 自動生成値の永続化は禁止 (命題 5 constitutive recording の L2 適用)。User/LLM が明示的に書いた値の保持は問題ない (descriptive field として透過)
- **Authorship spoofing への stance**: L2-evidential では relation は writer の claim、真偽は traverse 側判断。Cross-file spoofing は filesystem ACL の範疇 (Phase 1 single-user 環境では non-issue、Phase 2 federation で再考)

## §7 Phase 1→2 gate (定性のみ)

- maintainer (masaomi) が「この実装で informed_by の運用が見えた」と書面で articulate
- 結果を **L2 として保存** + **明示的に supersede 候補として multi-LLM review に投入** (silent promotion 禁止)
- 定量 floor は持たない

## §8 Phase 2/3 stub

- **Phase 2**: supersedes / led_to / derived edges、reverse traversal、dangling GC、authorship binding (`asserted_by`)、edges.jsonl export (inspection 用 dump)
- **Phase 3**: L0 波及、命題 8

cache (edges.jsonl) 導入判断は **観測ベース** (full walk + BFS が遅くなったら検討、L2 件数 1,000 程度までは不要)。

## §9 実装ステップ

1. `KairosChain_mcp_server/lib/kairos_mcp/context_graph.rb` 新規:
   - `TARGET_RE` (§2 canonical regex)
   - `resolve_target` (§3 path containment、symlink rejection、PathEscape)
   - error class 群: `MalformedTargetError`, `MalformedRelationsError`, `UnsafeRelationValueError`, `PathEscapeError`, `SymlinkRejectedError`, `PathResolutionError`, `InvalidFrontmatterError`
2. `ContextManager#save_context` 改修: §4 validation + atomic rename
3. `Scanner#traverse_informed_by` 新規 + `dream_scan` tool に `mode: 'traverse'` arg 追加
4. テスト suite (`KairosChain_mcp_server/test_context_graph.rb`):
   - canonical regex match / non-match (canonical & human-readable session_id 両形式)
   - path containment (`../` escape attempt, symlink swap, ENOENT dangling, PathEscape hard-fail)
   - atomic rename: crash mid-write simulation (kill -9 between write and rename) で target unchanged
   - YAML type whitelist (Ruby object 拒否)
   - Malformed relations (非 Array、non-Hash item、type/target 欠損)
   - BFS visited set + depth limit (cycle, depth-3 cutoff)
   - dangling target の skip + warn (warnings array に積まれる)
   - parse 失敗 target の skip + warn
   - 未知 relations_schema の skip + warn
   - return shape の正しさ (root, nodes, warnings)
5. 実装 multi-LLM review (1 round)、orchestrator-model = caller 自身の self-id
6. commit + L2 に `context_graph_phase1_implementation_complete` を保存

## §10 v1.0-f-high から **持ち越さない** もの (v2.1 更新)

- §1.1 `_resolution` system-managed key + strip invariant (持たない)
- §2 JSON Schema **強制** + read-validate subset invariant (descriptive にする)
- §3 Validator pinning (`json_schemer ~> 2.0`) (不要)
- §4.1 CONTEXT_ROOT_REAL boot snapshot + StaleContextRootError (call 時 realpath で十分)
- §5 8-step ordering (簡略化)
- §5 Write serialization invariant (P0-α、flock 等) (last-writer-wins で OK)
- ~~§5 Atomic write invariant~~ → **v2.1 で復活 (security 由来)**
- §5 Mode/owner invariant (fs default 任せ)
- §5 Edges.jsonl best-effort scope invariant (P0-iv) — edges.jsonl 自体を持たない
- §5.1 Frontmatter parse fail-closed (P0-β) (普通の error return)
- §5.2 Unknown-version step 8 取り扱い (P0-γ)
- §5b kairos reindex + merge invariant + bounded-pass invariant + pending dir
- §11 Implementation Decisions Backlog 全 13 件
- 真P0-D regex dialect probe boot-time assertion (Schema 強制しないので不要)
- 真P0-E unknown-version edges.jsonl handling (edges.jsonl 自体不在)

→ 設計行数: 251 → v2.0 約 100 → v2.1 約 180 行 (security 明示分追加)、実装行数の見積もり: v2.0 2-4 h → v2.1 3-5 h

---

*End of v2.1.*
