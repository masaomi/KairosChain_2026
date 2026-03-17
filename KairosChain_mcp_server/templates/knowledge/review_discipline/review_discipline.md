---
type: review_discipline
version: "0.1"
scope: all_development
origin: autonomos_round4_meta_analysis
---

# Review Discipline: LLM共通の注意機構限界への対策

## Background

4ラウンドのマルチLLMレビュー（Claude Opus 4.6, Codex/GPT-5.4, Cursor Premium）で
確認されたLLM全般に共通する認知バイアスと、その制度的対策。

## Identified Biases

### 1. Caller-side Bias（出力契約の未確認）

API呼び出しコードを書く際、呼び出し先の**入力シグネチャ**は確認するが、
**出力契約**（戻り値の型、エラー表現方法）を十分に確認しない。

Example: `save_context(session_id, name, content)` のシグネチャは正しく使ったが、
戻り値が `{ success: true/false }` であることを確認せず、例外前提で `rescue` を書いた。

**対策チェックリスト**（修正実装時に必ず確認）:
- [ ] 呼び出し先メソッドの入力シグネチャ ✓
- [ ] 呼び出し先メソッドの**戻り値の型**（Hash? Object? nil?）
- [ ] エラー表現方法（例外 vs 戻り値 `{ success: false }` vs nil）
- [ ] 正常系・異常系の両方のテストモック

### 2. Fix-what-was-flagged Bias（隣接同種バグの未スキャン）

レビュー指摘の箇所だけを修正し、同種の問題が隣接コードにないかを
自発的にスキャンしない。

Example: `load_goal` の ContextManager API を修正したが、
同じファイルの `load_l2_context` が同じ誤ったAPIパターンを使っていた。

**対策**: 修正完了後に必ず以下を実行:
- [ ] 修正対象のAPI/パターンをgrep → 同ファイル・同SkillSet内の全使用箇所を確認
- [ ] 隣接メソッドが同じ外部依存を使っていないか確認
- [ ] 修正の「型」（API修正、エラーハンドリング修正等）を特定し、同型の問題を検索

### 3. Mock Fidelity Bias（テストモックの忠実度不足）

テストモックが「正常系で値を返す」ことのみ模倣し、
呼び出し先の失敗契約をモックに反映しない。

**対策**:
- [ ] モックに正常系と異常系の両方を含める
- [ ] 呼び出し先が返す具体的な型をモックに反映（Hash, Struct, nil等）
- [ ] 失敗時の戻り値パターン（`{ success: false }` 等）もテスト

## Usage in Autonomos

autonomos orient phase でこの knowledge を参照し、
修正提案の gap に「同パターンスキャン」を含めること。
autonomos reflect phase で「上記チェックリストを適用したか」を learnings に記録すること。

## Multi-LLM Review Workflow (v0.1 manual)

1. autonomos cycle → propose fix
2. Human runs fix implementation
3. Human runs 3+ independent LLM reviews on the fix
4. Human feeds consolidated findings via `autonomos_reflect(feedback: "...")`
5. Next cycle incorporates cross-review findings
6. Repeat until no blockers

This manual workflow will be automated via MCP meeting in v0.3.
